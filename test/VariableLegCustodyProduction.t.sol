// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title VariableLegCustodyProductionTest
///
/// @notice The P-L2-3/4 acceptance suite: variable-leg custody, the unified provisional lifecycle,
///         and the removal of `BEFORE_SWAP_RETURNS_DELTA`, exercised against production.
///
/// @dev WHAT THIS FILE ADDS THAT THE MIGRATED SUITES DO NOT.
///
///      The existing suites were written for the previous custody model and were migrated in
///      place, which keeps their original questions intact but means they ask those questions of
///      the new code rather than asking the new code's own questions. This file covers what only
///      exists because of this migration:
///
///        - the FOUR token-flow modes as one matrix, each with complete conservation;
///        - eligibility on the ACTUAL consumed input at the exact boundary (INV-L2-13);
///        - the provisional lifecycle leaving nothing behind on any outcome (INV-L2-11);
///        - a partial-fill ladder at five fill fractions;
///        - a ROUTER-FREE caller, which is the only setting where INV-NOOP-VL is load-bearing;
///        - collateral recomputation being exact to the wei, since the record stores the leg.
///
///      Where a claim is about arithmetic rather than integration it is proven as a pure function
///      in `ModelLReferenceAgreement.t.sol` instead, on the grounds that a pure function deserves
///      an exhaustive sweep rather than whatever values a pool happened to produce.
contract VariableLegCustodyProductionTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;
    uint16 internal constant REFUND_TOL = 5;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    /// @dev See `BondCustody.t.sol` for the full reasoning on depth. 1e19 puts a 1e16 swap at
    ///      roughly 19 ticks of impact: clear of the zero-impact floor, far below the 397-tick cap.
    int128 internal constant POOL_LIQUIDITY = 1e19;

    uint256 internal constant SWAP_SIZE = 1e16;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    function _swap(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _swapLimited(int256 amountSpecified, uint160 limit, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _tick() internal view returns (int24 tick) {
        // slither-disable-next-line unused-return
        (, tick,,) = manager.getSlot0(id_);
    }

    function _maturityOfNow() internal view returns (uint32) {
        return uint32(block.number) + hook.OBSERVATION_BLOCKS();
    }

    function _bondIdAt(uint32 maturityBlock, uint32 index) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, index));
    }

    /// @dev Slot of the `bonds` mapping, pinned by `test/StorageLayout.t.sol`.
    uint256 internal constant SLOT_BONDS = 4;

    /// @dev Byte offset of `Bond.state` within the record's second slot, pinned by the same file.
    uint256 internal constant BOND_STATE_BYTE_OFFSET = 30;

    /// @dev Reads a bond's lifecycle state straight from storage, bypassing every public reader.
    ///
    ///      Needed because ADR-0004 Rule 1 deliberately hides PROVISIONAL from the public
    ///      interface -- see the note in `_sweepBucketAfter` for why that makes raw access the
    ///      only way to check the invariant.
    ///
    ///      Returns 0 NONE, 1 PROVISIONAL, 2 FINALIZED, 3 SETTLED.
    function _rawBondState(bytes32 bondId) internal view returns (uint8) {
        bytes32 slot1 = bytes32(uint256(keccak256(abi.encode(bondId, SLOT_BONDS))) + 1);

        return uint8(uint256(vm.load(address(hook), slot1)) >> (8 * BOND_STATE_BYTE_OFFSET));
    }

    /*//////////////////////////////////////////////////////////////
              THE FOUR TOKEN-FLOW MODES, AS ONE MATRIX
    //////////////////////////////////////////////////////////////*/

    /// @notice All four (kind x direction) combinations, each with full conservation.
    ///
    /// @dev ONE TEST RATHER THAN FOUR, DELIBERATELY.
    ///
    ///      The property that matters after this migration is not that any single mode works -- it
    ///      is that all four reduce to ONE custody path with no special cases left. Four separate
    ///      tests can each pass while the mapping between them is inconsistent; a matrix driven by
    ///      a single loop over `(exactInput, zeroForOne)` cannot, because every row runs the same
    ///      assertions with only the currency roles rotated.
    ///
    ///      Each row asserts, in the currencies that row implies:
    ///
    ///        1. the SPECIFIED leg is exactly as specified -- untouched by custody. This is the
    ///           heart of dropping `BEFORE_SWAP_RETURNS_DELTA`: the hook has no way to alter it.
    ///        2. the collateral lands in the variable leg's currency, and only there;
    ///        3. the collateral equals the independent Model L prediction on the realized leg;
    ///        4. nothing leaks -- every token leaving one party arrives at another;
    ///        5. INV-NOOP-VL holds strictly.
    function test_fourModes_conserveAndBondTheVariableLeg() public {
        for (uint256 i = 0; i < 4; i++) {
            bool exactInput = i < 2;
            bool zeroForOne = (i % 2) == 0;

            uint256 snapshot = vm.snapshotState();

            _assertOneMode(exactInput, zeroForOne);

            vm.revertToState(snapshot);
        }
    }

    /// @dev The currencies and pre-swap balances for one row of the matrix.
    ///
    ///      A struct rather than a dozen locals, and that is a compile-time necessity: one row
    ///      needs both currencies, four balances and two ticks, which is past the EVM stack limit
    ///      under this project's non-viaIR settings.
    struct Mode {
        Currency variableCurrency;
        Currency fixedCurrency;
        uint256 traderFixed;
        uint256 traderVar;
        uint256 hookVar;
        uint256 hookFixed;
        uint256 mgrVar;
        int24 tickBefore;
    }

    /// @dev One row of the matrix. Split out so the loop above stays inside the EVM stack limit.
    function _assertOneMode(bool exactInput, bool zeroForOne) internal {
        Mode memory b = _openMode(exactInput, zeroForOne);

        _swap(exactInput ? -int256(SWAP_SIZE) : int256(SWAP_SIZE), zeroForOne, _hookData());

        _closeMode(b, exactInput, zeroForOne);
    }

    /// @dev Resolves the row's currency roles and captures every balance it will need.
    function _openMode(bool exactInput, bool zeroForOne) internal view returns (Mode memory b) {
        (Currency inputCurrency, Currency outputCurrency) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        // ADR-0006: the KIND picks the variable leg, the direction picks its currency.
        b.variableCurrency = exactInput ? outputCurrency : inputCurrency;
        b.fixedCurrency = exactInput ? inputCurrency : outputCurrency;

        b.traderFixed = b.fixedCurrency.balanceOf(address(this));
        b.traderVar = b.variableCurrency.balanceOf(address(this));
        b.hookVar = b.variableCurrency.balanceOf(address(hook));
        b.hookFixed = b.fixedCurrency.balanceOf(address(hook));
        b.mgrVar = b.variableCurrency.balanceOf(address(manager));

        b.tickBefore = _tick();
    }

    /// @dev The five assertions that must hold for every row.
    function _closeMode(Mode memory b, bool exactInput, bool zeroForOne) internal view {
        uint256 bond = b.variableCurrency.balanceOf(address(hook)) - b.hookVar;

        string memory label =
            string.concat(exactInput ? "exact-input " : "exact-output ", zeroForOne ? "zeroForOne: " : "oneForZero: ");

        // 1. THE SPECIFIED LEG IS EXACTLY AS SPECIFIED.
        //
        //    exact-input  : the trader pays precisely the amount requested.
        //    exact-output : the trader receives precisely the amount requested.
        //
        //    This is the heart of dropping `BEFORE_SWAP_RETURNS_DELTA`: without that permission
        //    the hook has no mechanism to touch the specified leg at all.
        if (exactInput) {
            assertEq(
                b.traderFixed - b.fixedCurrency.balanceOf(address(this)),
                SWAP_SIZE,
                string.concat(label, "the specified INPUT was altered by custody")
            );
        } else {
            assertEq(
                b.fixedCurrency.balanceOf(address(this)) - b.traderFixed,
                SWAP_SIZE,
                string.concat(label, "the specified OUTPUT was altered by custody")
            );
        }

        // 2. Collateral is in the variable leg's currency, and nowhere else.
        assertGt(bond, 0, string.concat(label, "no collateral was taken"));

        assertEq(
            b.fixedCurrency.balanceOf(address(hook)),
            b.hookFixed,
            string.concat(label, "collateral was taken from the FIXED leg")
        );

        assertEq(
            Currency.unwrap(b.variableCurrency),
            Currency.unwrap(ModelLReference.collateralIsCurrency0(zeroForOne, exactInput) ? currency0 : currency1),
            string.concat(label, "the reference disagrees about which currency is the variable leg")
        );

        assertEq(
            hook.getBond(_bondIdAt(_maturityOfNow(), 0)).collateralIsCurrency0,
            ModelLReference.collateralIsCurrency0(zeroForOne, exactInput),
            string.concat(label, "the bond record's currency flag is wrong")
        );

        // 3. The realized variable leg, and the collateral the specification predicts for it.
        //
        //    exact-input  : the pool paid the leg out; the trader got it minus the bond.
        //    exact-output : the pool took the leg in; the trader paid it plus the bond.
        uint256 realizedLeg = exactInput
            ? (b.variableCurrency.balanceOf(address(this)) - b.traderVar) + bond
            : (b.variableCurrency.balanceOf(address(manager)) - b.mgrVar);

        assertEq(
            bond,
            ModelLReference.collateralFor(realizedLeg, b.tickBefore, _tick()),
            string.concat(label, "collateral does not match Model L on the realized leg")
        );

        // 4. Nothing leaked on the variable side.
        if (exactInput) {
            assertEq(
                b.mgrVar - b.variableCurrency.balanceOf(address(manager)),
                (b.variableCurrency.balanceOf(address(this)) - b.traderVar) + bond,
                string.concat(label, "output tokens leaked between the pool, the trader and the hook")
            );
        } else {
            assertEq(
                b.traderVar - b.variableCurrency.balanceOf(address(this)),
                realizedLeg + bond,
                string.concat(label, "input tokens leaked between the trader, the pool and the hook")
            );
        }

        // 5. INV-NOOP-VL, strictly, on a real execution.
        assertLt(bond, realizedLeg, string.concat(label, "INV-NOOP-VL: bond is not strictly inside the leg"));

        // No claim balances left anywhere.
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, string.concat(label, "currency0 claim left"));
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, string.concat(label, "currency1 claim left"));

        console2.log(string.concat(label, "bond"), bond);
    }

    /*//////////////////////////////////////////////////////////////
             INV-L2-13 — ELIGIBILITY ON THE ACTUAL FILL
    //////////////////////////////////////////////////////////////*/

    /// @notice The threshold is tested against the input the pool CONSUMED, at the exact boundary.
    ///
    /// @dev THE BOUNDARY MOVED FROM THE REQUEST TO THE FILL, and that is INV-L2-13's eligibility
    ///      half. The sizing half is covered in `BondCustody.t.sol`; this is the part that decides
    ///      whether a trade participates at all.
    ///
    ///      Constructed so the two readings give OPPOSITE answers, which is the only construction
    ///      that can tell them apart: the swap REQUESTS well above the threshold and FILLS below
    ///      it. Under the old rule -- eligibility on the request -- this bonds. Under the new rule
    ///      it must not.
    ///
    ///      The threshold is then lowered below the realized fill and the identical swap replayed,
    ///      so the test also shows the trade bonding once it genuinely qualifies. Without that
    ///      second half, a hook that simply never bonded would pass.
    function test_inv_L2_13_eligibilityFollowsTheConsumedInput() public {
        // Measure what a tightly limited swap actually fills, with bonding effectively off.
        hook.setPoolConfig(key_, type(uint128).max, type(uint96).max, BOND_BPS, REFUND_TOL);

        uint256 probe = vm.snapshotState();

        // slither-disable-next-line unused-return
        (uint160 sqrtNow,,,) = manager.getSlot0(id_);

        uint160 limit = sqrtNow - uint160((uint256(sqrtNow) * 200) / 1_000_000);

        uint256 mgrBefore = currency0.balanceOf(address(manager));

        _swapLimited(-int256(SWAP_SIZE), limit, _hookData());

        uint256 realizedFill = currency0.balanceOf(address(manager)) - mgrBefore;

        vm.revertToState(probe);

        assertGt(realizedFill, 0, "probe filled nothing");
        assertLt(realizedFill, SWAP_SIZE, "probe was not a partial fill; the two rules would agree");

        // CASE A -- threshold ABOVE the fill but BELOW the request.
        //
        // Requested `SWAP_SIZE`, fills `realizedFill`. A threshold strictly between the two is
        // satisfied by the request and not by the fill, so the two rules disagree here and only
        // here.
        hook.setPoolConfig(key_, uint128(realizedFill + 1), uint96(realizedFill + 1), BOND_BPS, REFUND_TOL);

        assertLt(realizedFill + 1, SWAP_SIZE, "the fixture cannot separate the request from the fill");

        uint256 hookBefore1 = currency1.balanceOf(address(hook));

        _swapLimited(-int256(SWAP_SIZE), limit, _hookData());

        assertEq(
            currency1.balanceOf(address(hook)) - hookBefore1,
            0,
            "INV-L2-13: a swap that FILLED below the threshold was bonded on the strength of its REQUEST"
        );

        vm.revertToState(probe);

        // CASE B -- threshold exactly AT the fill. Eligibility is inclusive, so this bonds.
        hook.setPoolConfig(key_, uint128(realizedFill), uint96(realizedFill), BOND_BPS, REFUND_TOL);

        hookBefore1 = currency1.balanceOf(address(hook));

        _swapLimited(-int256(SWAP_SIZE), limit, _hookData());

        assertGt(
            currency1.balanceOf(address(hook)) - hookBefore1,
            0,
            "a swap filling exactly AT the threshold was not bonded; the boundary is exclusive"
        );

        vm.revertToState(probe);

        // CASE C -- threshold one unit BELOW the fill. Comfortably eligible.
        hook.setPoolConfig(key_, uint128(realizedFill - 1), uint96(realizedFill - 1), BOND_BPS, REFUND_TOL);

        hookBefore1 = currency1.balanceOf(address(hook));

        _swapLimited(-int256(SWAP_SIZE), limit, _hookData());

        assertGt(
            currency1.balanceOf(address(hook)) - hookBefore1, 0, "a swap filling above the threshold was not bonded"
        );
    }

    /// @notice A partial-fill ladder at roughly 75 / 50 / 25 / 10 / 5 percent of the request.
    ///
    /// @dev The single partial fill in `BondCustody.t.sol` proves the bond follows the fill; this
    ///      shows the relationship holding across the whole range, including the deep partial
    ///      fills where the old model was most badly wrong. At a 5% fill the old bond was roughly
    ///      18x oversized relative to the input actually consumed -- the worst case named in
    ///      INV-L2-13 -- so the shallow rungs are the ones that matter most.
    ///
    ///      Each rung asserts the bond against the independent reference AND records the effective
    ///      rate on the consumed input, which is the number the old model let run away.
    function test_partialFillLadder_effectiveRateStaysBounded() public {
        // Chosen to straddle the ~950 ppm of sqrt-price this swap would move unconstrained.
        uint32[5] memory ppm = [uint32(700), 480, 250, 100, 50];

        for (uint256 i = 0; i < ppm.length; i++) {
            uint256 snapshot = vm.snapshotState();

            // slither-disable-next-line unused-return
            (uint160 sqrtNow,,,) = manager.getSlot0(id_);

            uint160 limit = sqrtNow - uint160((uint256(sqrtNow) * ppm[i]) / 1_000_000);

            uint256 mgrBefore = currency0.balanceOf(address(manager));
            uint256 hookBefore = currency1.balanceOf(address(hook));
            uint256 traderBefore = currency1.balanceOf(address(this));

            int24 tickBefore = _tick();

            _swapLimited(-int256(SWAP_SIZE), limit, _hookData());

            int24 tickAfter = _tick();

            uint256 fill = currency0.balanceOf(address(manager)) - mgrBefore;
            uint256 bond = currency1.balanceOf(address(hook)) - hookBefore;
            uint256 leg = (currency1.balanceOf(address(this)) - traderBefore) + bond;

            assertGt(fill, 0, "ladder rung filled nothing");
            assertLt(fill, SWAP_SIZE, "ladder rung was not a partial fill");

            // ELIGIBILITY IS PART OF THE LADDER, not a nuisance to be excluded.
            //
            // The shallowest rungs fill below `MIN_BONDED`, and under INV-L2-13 a swap is judged
            // on what it CONSUMED -- so those rungs are unbonded even though the request was
            // comfortably above the threshold. That is the eligibility half of the same invariant
            // the sizing assertions cover, observed here at real fill fractions rather than at a
            // constructed boundary, so it is asserted rather than skipped.
            if (fill < MIN_BONDED) {
                assertEq(bond, 0, "INV-L2-13: a rung that filled below the threshold was still bonded");

                console2.log("fill (bps of request)", (fill * 10_000) / SWAP_SIZE);
                console2.log("  unbonded: filled below MIN_BONDED", fill);

                vm.revertToState(snapshot);

                continue;
            }

            assertEq(
                bond,
                ModelLReference.collateralFor(leg, tickBefore, tickAfter),
                "ladder rung does not match Model L on its realized leg"
            );

            // The effective rate measured against the input actually consumed. Under Model L this
            // is bounded by construction, because the bond is a capped fraction of a leg that is
            // itself proportional to the fill. Under the old model it grew without bound as the
            // fill shrank, which is the defect being closed.
            if (bond > 0) {
                assertLe(
                    (bond * 10_000) / fill,
                    uint256(ModelLReference.MAX_BOND_BPS) * 2,
                    "the effective rate on the consumed input ran away on a shallow fill"
                );
            }

            console2.log("fill (bps of request)", (fill * 10_000) / SWAP_SIZE);
            console2.log("  bond", bond);

            vm.revertToState(snapshot);
        }
    }

    /*//////////////////////////////////////////////////////////////
                  INV-L2-11 — NO PROVISIONAL SURVIVES
    //////////////////////////////////////////////////////////////*/

    /// @notice No PROVISIONAL record survives a completed callback, on any outcome.
    ///
    /// @dev THE UNIFIED LIFECYCLE MADE THIS REACH FURTHER THAN IT USED TO.
    ///
    ///      Before this stage, `beforeSwap` wrote a provisional header only on the exact-output
    ///      path; exact-input took custody immediately and never had a provisional phase. Now
    ///      BOTH kinds open a provisional record in `beforeSwap`, so every exact-input outcome --
    ///      including the ordinary unbonded ones that happen on most swaps -- is a new opportunity
    ///      to strand one.
    ///
    ///      A stranded provisional is a bond nobody can settle and nobody can see: ADR-0004 Rule 1
    ///      makes `getBond` and `bondExists` report PROVISIONAL as ABSENT, so it would leave no
    ///      trace while still occupying an index in its maturity bucket.
    ///
    ///      Every outcome the callback can reach is driven here, and after each one the whole
    ///      bucket is swept -- not just the index the swap would have used -- so a record written
    ///      to an unexpected slot cannot hide.
    function test_inv_L2_11_noProvisionalSurvivesAnyOutcome() public {
        // 1. Bonded exact-input.
        _sweepBucketAfter(abi.encodeCall(this.exec_bondedExactInput, ()), 1, "bonded exact-input");

        // 2. Bonded exact-output.
        _sweepBucketAfter(abi.encodeCall(this.exec_bondedExactOutput, ()), 1, "bonded exact-output");

        // 3. Unbonded by threshold -- the path that had no provisional phase before this stage.
        _sweepBucketAfter(abi.encodeCall(this.exec_unbondedBelowThreshold, ()), 0, "unbonded below threshold");

        // 4. Unbonded by ZERO IMPACT: eligible on amount, but moved no whole tick.
        //
        //    This case needs staging, and the staging is the interesting part. On this fixture an
        //    amount large enough to clear `MIN_BONDED` also moves about two ticks, so eligibility
        //    and impact cannot both be pushed the right way at once. The threshold is therefore
        //    lowered to 1, which makes a dust swap eligible while leaving it far too small to move
        //    the price.
        //
        //    The warm-up swap matters just as much. The pool initializes at exactly tick 0, and on
        //    a tick BOUNDARY any downward movement at all -- even a few wei -- lands in tick -1 and
        //    registers as one tick of impact. Without nudging the price off the boundary first,
        //    the "zero impact" case is unreachable and this branch would quietly test something
        //    else.
        uint256 zeroImpactSnapshot = vm.snapshotState();

        _prepareZeroImpactCase();

        _sweepBucketAfter(abi.encodeCall(this.exec_unbondedZeroImpact, ()), 0, "unbonded zero impact");

        vm.revertToState(zeroImpactSnapshot);

        // 5. Partially filled and still bonded.
        _sweepBucketAfter(abi.encodeCall(this.exec_partialFill, ()), 1, "partial fill");

        // 6. Reverted by the trader's ceiling. The whole swap unwinds, so nothing may persist.
        _sweepBucketAfter(abi.encodeCall(this.exec_revertedByCeiling, ()), 0, "reverted by ceiling");
    }

    function exec_bondedExactInput() external {
        _swap(-int256(SWAP_SIZE), true, _hookData());
    }

    function exec_bondedExactOutput() external {
        _swap(int256(SWAP_SIZE), true, _hookData());
    }

    function exec_unbondedBelowThreshold() external {
        _swap(-int256(uint256(MIN_BONDED) - 1), true, "");
    }

    /// @dev Stages the zero-impact case: threshold down to 1, price nudged off the tick boundary,
    ///      then a fresh block so the dust swap's maturity bucket is its own.
    function _prepareZeroImpactCase() internal {
        hook.setPoolConfig(key_, 1, 1, BOND_BPS, REFUND_TOL);

        // Move the price into the interior of a tick. This swap bonds, which is why the roll below
        // is needed: its liability belongs to an earlier bucket than the one being swept.
        _swap(-int256(SWAP_SIZE), true, _hookData());

        vm.roll(block.number + 1);
    }

    function exec_unbondedZeroImpact() external {
        int24 tickBefore = _tick();

        // Eligible on amount (the threshold is 1 by now), but far too small against this depth to
        // move a whole tick -- so Model L rates it at zero and the swap is unbonded outright.
        _swap(-1e9, true, _hookData());

        // The premise, asserted rather than assumed. Without this the branch would keep passing if
        // the dust swap started moving a tick, having quietly become a different test.
        assertEq(
            ModelLReference.collateralBps(tickBefore, _tick()),
            0,
            "the dust swap moved a tick after all; this case is not testing zero impact"
        );
    }

    function exec_partialFill() external {
        // slither-disable-next-line unused-return
        (uint160 sqrtNow,,,) = manager.getSlot0(id_);

        _swapLimited(-int256(SWAP_SIZE), sqrtNow - uint160((uint256(sqrtNow) * 200) / 1_000_000), _hookData());
    }

    function exec_revertedByCeiling() external {
        _swap(-int256(SWAP_SIZE), true, HookDataCodec.encode(TRADER, 1));
    }

    /// @dev Runs one outcome, then sweeps its entire maturity bucket for surviving records.
    ///
    ///      `expectedFinalized` is asserted as well as the absence of provisionals, because "no
    ///      provisional survives" is trivially satisfied by a hook that records nothing at all.
    function _sweepBucketAfter(bytes memory call, uint256 expectedFinalized, string memory label) internal {
        uint256 snapshot = vm.snapshotState();

        uint32 m = _maturityOfNow();

        // slither-disable-next-line low-level-calls
        (bool ok,) = address(this).call(call);

        if (!ok) {
            // A reverted swap must leave the bucket exactly as it found it.
            (, uint32 pendingAfterRevert,) = hook.maturity(id_, m);

            assertEq(pendingAfterRevert, 0, string.concat(label, ": a reverted swap left a pending bond"));
        }

        uint256 finalized;

        // Sweep far past any index this outcome could legitimately have used. A provisional record
        // written to an unexpected slot is exactly the failure mode a targeted check would miss.
        //
        // THE STATE IS READ FROM RAW STORAGE, and it has to be.
        //
        // ADR-0004 Rule 1 makes `getBond` REVERT with `BondNotFound` for a PROVISIONAL record,
        // exactly as it does for one that never existed -- that indistinguishability is the rule.
        // It also means no public reader can tell "cleared" from "stranded", so a test asking the
        // public interface would be structurally incapable of detecting the violation it is
        // looking for. `vm.load` is the only instrument that can see it.
        //
        // The slot arithmetic is pinned in `test/StorageLayout.t.sol`, which fails loudly if
        // `bonds` moves or `Bond.state` changes offset -- otherwise this loop would quietly start
        // reading an unrelated word and passing for the wrong reason.
        for (uint32 i = 0; i < 64; i++) {
            bytes32 bondId = _bondIdAt(m, i);

            uint8 state = _rawBondState(bondId);

            // PROVISIONAL is 1. Observing one after the callback has returned is the violation.
            assertTrue(state != 1, string.concat(label, ": a PROVISIONAL record survived the callback"));

            if (state == 2) finalized++;

            // Consistency between the raw state and the public reader, in both directions.
            assertEq(
                hook.bondExists(bondId),
                state == 2 || state == 3,
                string.concat(label, ": bondExists disagrees with the record's actual state")
            );
        }

        assertEq(finalized, expectedFinalized, string.concat(label, ": wrong number of finalized bonds"));

        (, uint32 pending,) = hook.maturity(id_, m);

        assertEq(pending, expectedFinalized, string.concat(label, ": pendingBonds disagrees with the swept bucket"));

        vm.revertToState(snapshot);
    }

    /*//////////////////////////////////////////////////////////////
                    COLLATERAL RECOMPUTATION IS EXACT
    //////////////////////////////////////////////////////////////*/

    /// @notice The collateral recomputed from a bond record equals the collateral physically taken,
    ///         to the wei, with no one-wei difference in either direction.
    ///
    /// @dev WHY THIS NEEDS ITS OWN TEST.
    ///
    ///      ADR-0005 s3.2 has the record store the realized VARIABLE LEG rather than the
    ///      collateral, because storing the collateral breaks INV-L2-4: the obvious way to rescale
    ///      a stored collateral when the rate changes loses a wei, and that lost wei lets a larger
    ///      overshoot pay less than a smaller one. Storing the leg avoids it -- at the cost of
    ///      making every later read of "how much collateral does this bond hold" a RECOMPUTATION.
    ///
    ///      Settlement divides that recomputed figure between the refund and the slash, so if it
    ///      differed from what was actually taken by even one wei the hook would pay out either
    ///      more than it holds (insolvent by a wei per bond) or less (dust accumulating with no
    ///      owner). Both are exactly the kind of slow leak an approximate check would miss, so
    ///      this asserts equality rather than closeness, across all four modes and a size sweep.
    function test_collateral_recomputationIsExact() public {
        uint256[4] memory sizes = [uint256(1e15), 1e16, 1e17, 3e17];

        for (uint256 s = 0; s < sizes.length; s++) {
            for (uint256 i = 0; i < 4; i++) {
                bool exactInput = i < 2;
                bool zeroForOne = (i % 2) == 0;

                uint256 snapshot = vm.snapshotState();

                Currency collateralCurrency =
                    ModelLReference.collateralIsCurrency0(zeroForOne, exactInput) ? currency0 : currency1;

                bytes32 bondId = _bondIdAt(_maturityOfNow(), 0);

                uint256 hookBefore = collateralCurrency.balanceOf(address(hook));

                _swap(exactInput ? -int256(sizes[s]) : int256(sizes[s]), zeroForOne, _hookData());

                uint256 physicallyTaken = collateralCurrency.balanceOf(address(hook)) - hookBefore;

                if (physicallyTaken == 0) {
                    // Unbonded at this size and depth. No record, so nothing to recompute.
                    assertFalse(hook.bondExists(bondId), "an unbonded swap left a record behind");

                    vm.revertToState(snapshot);

                    continue;
                }

                assertEq(
                    uint256(hook.collateralAmountOf(bondId)),
                    physicallyTaken,
                    "recomputed collateral differs from the collateral physically taken"
                );

                // And the recomputation is stable: reading it again cannot drift.
                assertEq(
                    uint256(hook.collateralAmountOf(bondId)),
                    uint256(hook.collateralAmountOf(bondId)),
                    "collateralAmountOf is not deterministic"
                );

                vm.revertToState(snapshot);
            }
        }
    }

    /// @notice Settlement pays out exactly the recomputed collateral -- no more, no less.
    ///
    /// @dev The conservation half of the argument above, observed end to end rather than asserted
    ///      about the arithmetic. `refund + slash` must equal the recomputed collateral, and the
    ///      hook's physical balance must fall by exactly that amount.
    function test_settlement_paysExactlyTheRecomputedCollateral() public {
        uint32 m = _maturityOfNow();

        bytes32 bondId = _bondIdAt(m, 0);

        _swap(-int256(SWAP_SIZE), true, _hookData());

        Currency c = hook.getBond(bondId).collateralIsCurrency0 ? currency0 : currency1;

        uint256 collateral = hook.collateralAmountOf(bondId);

        assertGt(collateral, 0, "no bond was taken");

        vm.roll(uint256(m) + 1);

        _swap(-1e13, true, "");

        uint256 hookBefore = c.balanceOf(address(hook));
        uint256 traderBefore = c.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(id_, c);

        hook.settleBond(bondId);

        uint256 refund = c.balanceOf(TRADER) - traderBefore;
        uint256 slash = hook.insurancePot(id_, c) - potBefore;

        assertEq(refund + slash, collateral, "INV-L2-3: refund + slash != recomputed collateral");

        // The pot is an accounting entry, so the physical balance only falls by the refund.
        assertEq(hookBefore - c.balanceOf(address(hook)), refund, "the hook moved a different amount than it refunded");

        assertGe(c.balanceOf(address(hook)), slash, "the hook does not physically hold its own insurance pot");
    }

    /*//////////////////////////////////////////////////////////////
                    A ROUTER-FREE CALLER (INV-L2-1)
    //////////////////////////////////////////////////////////////*/

    /// @notice A caller that drives `PoolManager.unlock` itself gets the same bond and the same
    ///         bound.
    ///
    /// @dev THIS IS THE ONLY SETTING WHERE INV-NOOP-VL IS ACTUALLY LOAD-BEARING, so it is the only
    ///      test that can prove the hook -- rather than the router -- is enforcing it.
    ///
    ///      `Hooks.sol` bounds `hookDeltaSpecified` at line 277. It bounds `hookDeltaUnspecified`
    ///      NOWHERE. `V4Router` happens to revert on the negative cast that an oversized
    ///      unspecified delta would produce, but nothing obliges a caller to use a router, and a
    ///      security property that depends on the caller's choice of periphery is not a security
    ///      property. This driver calls `poolManager.swap` inside its own `unlock` and settles the
    ///      deltas by hand, so nothing sits between it and the hook.
    ///
    ///      Ported from the research prototype's section 18, which is where the argument was first
    ///      established, and re-run here against PRODUCTION.
    function test_directCaller_getsTheSameBondAndBound() public {
        DirectSwapper d = new DirectSwapper(IPoolManager(address(manager)));

        deal(Currency.unwrap(currency0), address(d), 1e24);
        deal(Currency.unwrap(currency1), address(d), 1e24);

        uint256 hookBefore = currency1.balanceOf(address(hook));

        int24 tickBefore = _tick();

        (int256 amount0, int256 amount1) = d.swap(key_, true, -int256(SWAP_SIZE), _hookData());

        int24 tickAfter = _tick();

        uint256 bond = currency1.balanceOf(address(hook)) - hookBefore;

        assertGt(bond, 0, "the direct caller was not bonded");

        // The delta a caller sees is ALREADY NET of the hook's claim: `PoolManager` credits the
        // hook and debits the caller before returning. So the raw output is what the caller
        // received plus what the hook took.
        assertEq(uint256(-amount0), SWAP_SIZE, "the direct caller did not pay exactly the specified input");

        uint256 rawOutput = uint256(amount1) + bond;

        assertEq(
            bond,
            ModelLReference.collateralFor(rawOutput, tickBefore, tickAfter),
            "the direct caller was charged something other than the Model L collateral"
        );

        // INV-NOOP-VL, with no router anywhere in the path.
        assertLt(bond, rawOutput, "INV-NOOP-VL: the bond was not strictly inside the variable leg");

        assertGt(amount1, int256(0), "the direct caller received no output at all");
    }

    /// @notice The trader ceiling still binds with no router in the path.
    ///
    /// @dev `maxBondAmount` is the trader's own protection and must not depend on periphery either.
    function test_directCaller_traderCeilingStillBinds() public {
        DirectSwapper d = new DirectSwapper(IPoolManager(address(manager)));

        deal(Currency.unwrap(currency0), address(d), 1e24);
        deal(Currency.unwrap(currency1), address(d), 1e24);

        uint256 hookBefore = currency1.balanceOf(address(hook));

        vm.expectRevert();

        d.swap(key_, true, -int256(SWAP_SIZE), HookDataCodec.encode(TRADER, 1));

        assertEq(currency1.balanceOf(address(hook)), hookBefore, "a rejected direct swap still moved collateral");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Every invariant this stage owns, over random size, direction and kind.
    ///
    /// @dev The unit tests above pin specific constructions; this asserts the same properties hold
    ///      wherever the fuzzer lands. Unbonded draws are not discarded -- they are asserted to
    ///      leave no record, which is itself INV-L2-11 over a much wider input space than the
    ///      enumerated outcomes could reach.
    function testFuzz_variableLegCustodyHolds(uint96 rawSize, bool zeroForOne, bool exactInput) public {
        uint256 size = bound(uint256(rawSize), 1e12, 5e17);

        Currency collateralCurrency =
            ModelLReference.collateralIsCurrency0(zeroForOne, exactInput) ? currency0 : currency1;

        bytes32 bondId = _bondIdAt(_maturityOfNow(), 0);

        uint256 hookBefore = collateralCurrency.balanceOf(address(hook));

        _swap(exactInput ? -int256(size) : int256(size), zeroForOne, _hookData());

        uint256 bond = collateralCurrency.balanceOf(address(hook)) - hookBefore;

        if (bond == 0) {
            // Unbonded: below threshold, or moved no whole tick. Either way, no trace.
            assertFalse(hook.bondExists(bondId), "an unbonded swap left a record");

            (, uint32 pending,) = hook.maturity(id_, _maturityOfNow());

            assertEq(pending, 0, "an unbonded swap registered a maturity liability");

            return;
        }

        // INV-L2-7: exactly one liability per finalized bond.
        (, uint32 pendingAfter,) = hook.maturity(id_, _maturityOfNow());

        assertEq(pendingAfter, 1, "INV-L2-7: a finalized bond did not register exactly one liability");

        // The record agrees with what was physically taken.
        assertEq(uint256(hook.collateralAmountOf(bondId)), bond, "recomputed collateral != collateral taken");

        // The currency flag matches the specification.
        assertEq(
            hook.getBond(bondId).collateralIsCurrency0,
            ModelLReference.collateralIsCurrency0(zeroForOne, exactInput),
            "the record's collateral currency is wrong"
        );

        // INV-NOOP-VL and the rate cap, both against the stored leg.
        uint256 leg = uint256(hook.getBond(bondId).variableLegAmount);

        assertGt(leg, 0, "a finalized bond stored a zero variable leg");

        assertLt(bond, leg, "INV-NOOP-VL: bond is not strictly inside the leg");

        assertLe(bond, (leg * ModelLReference.MAX_BOND_BPS) / 10_000, "INV-L2-2: the realized bond exceeded the cap");

        // Nothing left as a claim.
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "currency0 claim left behind");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "currency1 claim left behind");
    }
}

/// @notice A router-free swap driver.
///
/// @dev Calls `poolManager.swap` directly inside `unlock` and settles the resulting deltas by
///      hand, so nothing between the caller and the hook can absorb a bad delta. See
///      `test_directCaller_getsTheSameBondAndBound` for why that matters.
contract DirectSwapper {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        external
        returns (int256 amount0, int256 amount1)
    {
        bytes memory result = manager.unlock(abi.encode(key, zeroForOne, amountSpecified, hookData));

        return abi.decode(result, (int256, int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");

        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData) =
            abi.decode(data, (PoolKey, bool, int256, bytes));

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());

        return abi.encode(int256(delta.amount0()), int256(delta.amount1()));
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);

            MockERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount)));

            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
