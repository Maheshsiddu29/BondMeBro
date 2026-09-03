// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";
import {TickAccumulatorLib} from "../src/libraries/TickAccumulatorLib.sol";

/// @notice T5B — settlement: refund, slash, insurance pot.
///
/// @dev THE PROPERTY EVERYTHING HERE SERVES. Settlement is permissionless, so both the caller and
///      the block are adversarially chosen. If the outcome moved with either, whoever picked them
///      would pick the answer, and the mechanism would be a game about transaction timing rather
///      than a measurement of what the price did. Hence ADR-0003 § 1:
///
///          settlement at M == settlement at M+1 == settlement at M+10,000
///
///      Every test here either establishes that or checks something the guarantee rests on.
contract SettlementTest is Test, Deployers {
    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);
    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;
    uint16 internal constant REFUND_TOL = 5;
    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    int256 internal constant BONDED_INPUT = -1e16;
    uint128 internal constant BONDED_OUTPUT = 1e16;

    /// @dev The fixture pool is deliberately THIN (1e18 liquidity) so an ordinary bonded swap
    ///      moves the tick well beyond `REFUND_TOL`. On a deep pool a 1e16 swap moves one tick,
    ///      which the noise floor correctly treats as nothing — a correct outcome, but useless for
    ///      exercising the persistence curve.
    int256 internal constant BIG_SWAP = -1e16;

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
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e18, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, true);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _swap(int256 amountSpecified, bool zeroForOne, bytes memory data) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    function _bondIdAt(uint32 maturityBlock, uint32 index) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, index));
    }

    function _maturityOfNow() internal view returns (uint32) {
        return uint32(block.number) + hook.OBSERVATION_BLOCKS();
    }

    /// @dev The currency a bond's collateral is actually held in, READ FROM THE RECORD.
    ///
    ///      INV-L2-10 states this as a rule rather than a convenience: *"The collateral currency
    ///      must be READ from the bond record, never inferred from the swap direction. Under
    ///      variable-leg custody the direction alone gives the wrong answer for half of all bonds,
    ///      because the swap kind also decides."*
    ///
    ///      This suite previously hard-coded `currency0` throughout, which was right while
    ///      collateral always came from the input of a zeroForOne swap. It is now wrong for every
    ///      exact-input bond, and wrong in the worst possible way: a settlement measured in the
    ///      other currency reports a refund of zero and a pot delta of zero, so a conservation
    ///      assertion comparing them becomes `0 == 0` and PASSES while proving nothing. Several
    ///      tests in this file were doing exactly that. Reading the record removes the failure
    ///      mode instead of correcting it case by case.
    function _collateralCurrencyOf(bytes32 bondId) internal view returns (Currency) {
        return hook.getBond(bondId).collateralIsCurrency0 ? currency0 : currency1;
    }

    /// @dev The currency a bond is NOT held in, for cross-currency isolation checks.
    function _otherCurrencyOf(bytes32 bondId) internal view returns (Currency) {
        return hook.getBond(bondId).collateralIsCurrency0 ? currency1 : currency0;
    }

    /// @dev Opens one bonded exact-input swap and returns its id and maturity.
    function _openBond() internal returns (bytes32 bondId, uint32 maturityBlock) {
        maturityBlock = _maturityOfNow();
        bondId = _bondIdAt(maturityBlock, 0);
        _swap(BONDED_INPUT, true, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT CORRECTNESS
    //////////////////////////////////////////////////////////////*/

    /// @notice A reverted price refunds in full: the displacement did not survive, so the LP was
    ///         not harmed and the trader owes nothing.
    function test_settle_fullRefundWhenPriceReverted() public {
        (bytes32 bondId, uint32 m) = _openBond();

        uint128 collateral = hook.collateralAmountOf(bondId);
        assertGt(collateral, 0, "no bond was taken");

        // Arbitrage pushes the price back — and slightly past. The overshoot matters and is not a
        // trick: the observation window STARTS at the post-swap tick, so the displaced block is
        // inside the average (a bias `TickAccumulatorLib` documents). A reversion that lands
        // exactly on the opening tick therefore still leaves a small surviving average. Real
        // arbitrage overshoots routinely, and here it brings the window average back to or above
        // the opening reference, which is what a genuinely reverted trade looks like.
        vm.roll(block.number + 1);
        _swap(-4e16, false, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        Currency c = _collateralCurrencyOf(bondId);

        uint256 recipientBefore = c.balanceOf(TRADER);

        hook.settleBond(bondId);

        assertEq(c.balanceOf(TRADER) - recipientBefore, collateral, "reverted price did not refund in full");
        assertEq(hook.insurancePot(id_, c), 0, "a reverted price credited the insurance pot");
        assertEq(uint8(hook.getBond(bondId).state), 3, "bond is not SETTLED");
    }

    /// @notice A displacement that persists slashes: the LP ate the adverse selection.
    function test_settle_slashesWhenPricePersisted() public {
        (bytes32 bondId, uint32 m) = _openBond();

        uint128 collateral = hook.collateralAmountOf(bondId);

        // Leave the price where the swap put it, and let the window elapse quietly.
        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        Currency c = _collateralCurrencyOf(bondId);

        uint256 recipientBefore = c.balanceOf(TRADER);

        hook.settleBond(bondId);

        uint256 refund = c.balanceOf(TRADER) - recipientBefore;
        uint256 slash = hook.insurancePot(id_, c);

        assertGt(slash, 0, "a persistent displacement did not slash");
        assertEq(refund + slash, collateral, "refund + slash != collateral");
    }

    /// @notice Conservation is exact on every path: no wei is created or stranded.
    /// @dev The reason `split` computes one side and subtracts: independent bps arithmetic on both
    ///      sides would leave rounding dust unaccounted for.
    function test_settle_conservesCollateralExactly() public {
        (bytes32 bondId, uint32 m) = _openBond();

        uint128 collateral = hook.collateralAmountOf(bondId);

        vm.roll(block.number + 3);
        _swap(-4e15, false, _hookData()); // partial reversion

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        Currency c = _collateralCurrencyOf(bondId);

        uint256 recipientBefore = c.balanceOf(TRADER);
        hook.settleBond(bondId);

        uint256 refund = c.balanceOf(TRADER) - recipientBefore;
        uint256 slash = hook.insurancePot(id_, c);

        assertEq(refund + slash, collateral, "collateral was not conserved exactly");
    }

    /// @notice Exact-input settles in both directions, with the bond in the correct currency.
    function test_settle_exactInput_oneForZero() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(BONDED_INPUT, false, _hookData());

        uint128 collateral = hook.collateralAmountOf(bondId);
        assertGt(collateral, 0);

        // THE FLIP. This swap is exact-INPUT oneForZero, so its input is currency1 and its OUTPUT
        // is currency0. Collateral now comes from the variable leg, which for exact-input is the
        // output -- so this bond is held in currency0, the opposite of what it was before
        // P-L2-3/4. Both the record's flag and the reference are asserted, so a hook that flipped
        // only one of them cannot pass.
        assertTrue(hook.getBond(bondId).collateralIsCurrency0, "exact-input oneForZero must bond in currency0");

        assertTrue(
            ModelLReference.collateralIsCurrency0({zeroForOne: false, exactInput: true}),
            "reference disagrees on the exact-input oneForZero collateral currency"
        );

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        Currency c = _collateralCurrencyOf(bondId);

        uint256 before = c.balanceOf(TRADER);
        hook.settleBond(bondId);

        assertEq(
            c.balanceOf(TRADER) - before + hook.insurancePot(id_, c),
            collateral,
            "settlement did not conserve in the collateral currency"
        );

        // And nothing leaked into the other side.
        assertEq(hook.insurancePot(id_, _otherCurrencyOf(bondId)), 0, "a slash credited the wrong currency");
    }

    /// @notice Exact-output settles too, in both directions.
    function test_settle_exactOutput_bothDirections() public {
        uint32 m = _maturityOfNow();
        bytes32 first = _bondIdAt(m, 0);
        bytes32 second = _bondIdAt(m, 1);

        _swap(int256(uint256(BONDED_OUTPUT)), true, _hookData());
        _swap(int256(uint256(BONDED_OUTPUT)), false, _hookData());

        uint128 c0 = hook.collateralAmountOf(first);
        uint128 c1 = hook.collateralAmountOf(second);

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        uint256 b0 = currency0.balanceOf(TRADER);
        uint256 b1 = currency1.balanceOf(TRADER);

        hook.settleBond(first);
        hook.settleBond(second);

        assertEq(currency0.balanceOf(TRADER) - b0 + hook.insurancePot(id_, currency0), c0, "currency0 did not conserve");
        assertEq(currency1.balanceOf(TRADER) - b1 + hook.insurancePot(id_, currency1), c1, "currency1 did not conserve");
    }

    /*//////////////////////////////////////////////////////////////
                             REJECTIONS
    //////////////////////////////////////////////////////////////*/

    function test_settle_beforeMaturityReverts() public {
        (bytes32 bondId, uint32 m) = _openBond();

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotMature.selector, bondId, m, block.number));
        hook.settleBond(bondId);
    }

    /// @notice Double settlement is impossible — the second attempt sees SETTLED.
    function test_settle_twiceReverts() public {
        (bytes32 bondId, uint32 m) = _openBond();

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        hook.settleBond(bondId);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotSettleable.selector, bondId, uint8(3)));
        hook.settleBond(bondId);
    }

    function test_settle_nonexistentBondReverts() public {
        bytes32 ghost = keccak256("no such bond");

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotSettleable.selector, ghost, uint8(0)));
        hook.settleBond(ghost);
    }

    /// @notice A PROVISIONAL record cannot be settled — ADR-0004 Rule 1 holds at the settlement
    ///         boundary too, and the error is the same one an absent bond produces.
    function test_settle_provisionalReverts() public {
        // An unbonded exact-output swap writes a provisional header and clears it. Its id is never
        // settleable — before, during, or after.
        uint32 m = _maturityOfNow();
        bytes32 provisionalId = _bondIdAt(m, 0);

        _swap(1e13, true, _hookData());

        vm.roll(uint256(m) + 1);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotSettleable.selector, provisionalId, uint8(0)));
        hook.settleBond(provisionalId);
    }

    /// @notice A matured bond whose checkpoint is missing AND unrecoverable must revert, never
    ///         approximate from live state.
    ///
    /// @dev Constructed by storage-corrupting only the CHECKPOINT — clearing its frozen flag —
    ///      after the cursor has legitimately advanced past M. That reproduces exactly the state
    ///      NO-MISSED-MATURITY forbids, without weakening any production invariant. Settlement
    ///      must treat it as an invariant violation, because the value at M is genuinely gone.
    function test_settle_missingCheckpointAndCursorPastM_reverts() public {
        (bytes32 bondId, uint32 m) = _openBond();

        vm.roll(uint256(m) + 5);
        _swap(-1e13, true, ""); // freezes M and advances the cursor past it

        (,,, uint32 pending, uint8 frozenMask) = hook.maturity(id_, m);

        bool frozen = frozenMask & hook.FROZEN_C10() != 0;
        assertTrue(frozen, "fixture precondition: M should have frozen");

        // Corrupt only the checkpoint: keep pendingBonds, clear every endpoint and the whole mask.
        // `maturity` is at slot 3; the inner mapping key is the maturity block.
        //
        // OFFSETS UPDATED IN P-L2-5. The bucket carries three endpoints now, so the field this
        // test has to preserve moved:
        //
        //     before: cumulative 0, pendingBonds 7, checkpointed 11
        //     after:  C6 0, C8 7, C10 14, pendingBonds 21, frozenMask 25
        //
        // Writing `pending << 168` puts `pendingBonds` back at byte 21 and leaves all three
        // cumulatives and the mask zero — the bucket still counts a live liability but has no
        // frozen value for any endpoint, which is the state this test needs.
        //
        // The shift is derived from `test/StorageLayout.t.sol`, which fails first and by name if
        // these offsets ever move again.
        bytes32 slot = keccak256(abi.encode(uint256(m), keccak256(abi.encode(id_, uint256(2)))));
        vm.store(address(hook), slot, bytes32(uint256(pending) << 168));

        (,,, uint32 pendingAfter, uint8 frozenAfterMask) = hook.maturity(id_, m);

        bool frozenAfter = frozenAfterMask & hook.FROZEN_C10() != 0;
        assertEq(pendingAfter, pending, "fixture: pendingBonds must survive the corruption");
        assertFalse(frozenAfter, "fixture: checkpoint should now read unfrozen");

        (, uint32 lastUpdate,,) = hook.accumulator(id_);
        assertGt(lastUpdate, m, "fixture: cursor must be past M for this to be unrecoverable");

        // THE NAMED ENDPOINT CHANGED IN P-L2-6, and the change is the point.
        //
        // While settlement read C10 alone, the endpoint it could not recover was M itself. Model
        // L2 needs two late windows, so `settleBond` now resolves C6, then C8, then C10 -- and the
        // revert names the EARLIEST unrecoverable endpoint, which is the one whose value is
        // actually lost. For a bucket wiped clean that is C6 at `M - 4`, not M.
        //
        // Reporting M here would send an operator looking at the wrong block: C10 is merely the
        // last casualty, C6 is where the loss began.
        vm.expectRevert(
            abi.encodeWithSelector(
                BondMeBro.MaturityCheckpointMissing.selector, bondId, m - hook.C6_OFFSET_FROM_MATURITY(), lastUpdate
            )
        );
        hook.settleBond(bondId);
    }

    /*//////////////////////////////////////////////////////////////
              THE GOVERNING INVARIANT — TIME INDEPENDENCE
    //////////////////////////////////////////////////////////////*/

    /// @notice SETTLEMENT AT M, M+1 AND M+10,000 PRODUCE IDENTICAL OUTCOMES.
    ///
    /// @dev THE TEST THIS WHOLE TASK EXISTS FOR (ADR-0003 § 1). Each branch starts from the SAME
    ///      economic state via snapshot/revert — not by settling one bond three times, which would
    ///      only prove double-settlement is blocked.
    ///
    ///      The late branch performs PRICE-MOVING SWAPS after maturity before settling. Those are
    ///      the whole point: they prove post-maturity market activity is not a settlement input.
    ///      An implementation reading live state would diverge here and nowhere else.
    function test_settlementIsIndependentOfWhenItIsCalled() public {
        (bytes32 bondId, uint32 m) = _openBond();

        // Move the price during the window so the outcome is a non-trivial partial result.
        vm.roll(block.number + 2);
        _swap(-4e15, false, _hookData());

        // Reach maturity and freeze the checkpoint identically for all three branches.
        vm.roll(uint256(m));
        _swap(-1e13, true, "");

        uint256 baseline = vm.snapshotState();

        // --- settle at M ---
        (uint256 refundAtM, uint256 potAtM, uint16 bpsAtM) = _settleAndMeasure(bondId);
        vm.revertToState(baseline);

        // --- settle at M + 1 ---
        vm.roll(block.number + 1);
        (uint256 refundAtM1, uint256 potAtM1, uint16 bpsAtM1) = _settleAndMeasure(bondId);
        vm.revertToState(baseline);

        // --- settle at M + 10,000, after real post-maturity price movement ---
        vm.roll(block.number + 10_000);
        _swap(-1e16, true, _hookData());
        _swap(-8e15, false, _hookData());
        vm.roll(block.number + 500);
        _swap(-9e15, true, _hookData());
        (uint256 refundLate, uint256 potLate, uint16 bpsLate) = _settleAndMeasure(bondId);

        console2.log("persistence bps  @M / @M+1 / @M+10000:", bpsAtM, bpsAtM1, bpsLate);
        console2.log("refund           @M / @M+1 / @M+10000:", refundAtM, refundAtM1, refundLate);
        console2.log("insurance pot    @M / @M+1 / @M+10000:", potAtM, potAtM1, potLate);

        assertEq(bpsAtM1, bpsAtM, "persistence changed between M and M+1");
        assertEq(bpsLate, bpsAtM, "persistence changed by M+10,000 and post-maturity swaps");

        assertEq(refundAtM1, refundAtM, "refund changed between M and M+1");
        assertEq(refundLate, refundAtM, "refund changed by M+10,000 and post-maturity swaps");

        assertEq(potAtM1, potAtM, "pot increment changed between M and M+1");
        assertEq(potLate, potAtM, "pot increment changed by M+10,000 and post-maturity swaps");
    }

    /// @dev Settles and returns the recipient's balance delta, the pot increment, and the
    ///      persistence result read from the emitted event.
    function _settleAndMeasure(bytes32 bondId)
        internal
        returns (uint256 refund, uint256 potDelta, uint16 persistenceBps)
    {
        Currency c = _collateralCurrencyOf(bondId);

        uint256 recipientBefore = c.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(id_, c);

        vm.recordLogs();
        hook.settleBond(bondId);

        refund = c.balanceOf(TRADER) - recipientBefore;
        potDelta = hook.insurancePot(id_, c) - potBefore;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BondMeBro.BondSettled.selector) {
                (,,,, persistenceBps) = abi.decode(logs[i].data, (Currency, uint128, uint128, uint128, uint16));
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        QUIET-POOL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice A bond opens, nothing swaps through maturity, and settlement derives and freezes M
    ///         itself — no keeper, no transaction at M.
    ///
    /// @dev The frozen value must equal the mathematically expected cumulative at M, computed by
    ///      hand from the accumulator state left by the opening swap.
    function test_quietPool_settlementDerivesAndFreezesM() public {
        (bytes32 bondId, uint32 m) = _openBond();

        (int24 tickAfterOpen, uint32 lastUpdate,, int56 cumAtOpen) = hook.accumulator(id_);

        // Nothing happens at all, well past maturity.
        vm.roll(uint256(m) + 3_000);

        (,,,, uint8 frozenBeforeMask) = hook.maturity(id_, m);

        bool frozenBefore = frozenBeforeMask & hook.FROZEN_C10() != 0;
        assertFalse(frozenBefore, "nothing should have frozen M");

        hook.settleBond(bondId);

        (,, int56 frozen,, uint8 frozenAfterMask) = hook.maturity(id_, m);

        bool frozenAfter = frozenAfterMask & hook.FROZEN_C10() != 0;

        assertTrue(frozenAfter, "settlement did not freeze M on the quiet path");
        assertEq(
            frozen,
            cumAtOpen + int56(tickAfterOpen) * int56(uint56(m - lastUpdate)),
            "quiet-path freeze is not the exact cumulative at M"
        );
        assertEq(uint8(hook.getBond(bondId).state), 3, "bond not SETTLED");
    }

    /// @notice The quiet path and the swap-crossed path produce the SAME outcome.
    /// @dev Otherwise "settle whenever you like" would still hide an economic difference.
    function test_quietPool_matchesTheCheckpointedPath() public {
        (bytes32 bondId, uint32 m) = _openBond();

        uint256 baseline = vm.snapshotState();

        // Branch A: a swap crosses M and freezes it, then settle.
        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");
        (uint256 refundA, uint256 potA,) = _settleAndMeasure(bondId);

        vm.revertToState(baseline);

        // Branch B: nothing at all until settlement, which freezes M itself.
        vm.roll(uint256(m) + 1);
        (uint256 refundB, uint256 potB,) = _settleAndMeasure(bondId);

        assertEq(refundB, refundA, "quiet-path refund differs from the checkpointed path");
        assertEq(potB, potA, "quiet-path pot increment differs from the checkpointed path");
    }

    /*//////////////////////////////////////////////////////////////
                               settleMany
    //////////////////////////////////////////////////////////////*/

    function test_settleMany_settlesABatch() public {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](4);
        for (uint32 i = 0; i < 4; i++) {
            ids[i] = _bondIdAt(m, i);
            _swap(BONDED_INPUT, true, _hookData());
        }

        uint128 total;
        for (uint256 i = 0; i < 4; i++) {
            total += hook.collateralAmountOf(ids[i]);
        }

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        // All four bonds are identical exact-input zeroForOne swaps, so they share one collateral
        // currency; it is still read from a record rather than assumed.
        Currency c = _collateralCurrencyOf(ids[0]);

        for (uint256 i = 1; i < 4; i++) {
            assertEq(
                Currency.unwrap(_collateralCurrencyOf(ids[i])),
                Currency.unwrap(c),
                "the batch does not share one collateral currency; the total below would be meaningless"
            );
        }

        uint256 before = c.balanceOf(TRADER);
        hook.settleMany(ids);

        assertEq(c.balanceOf(TRADER) - before + hook.insurancePot(id_, c), total, "batch did not conserve collateral");

        for (uint256 i = 0; i < 4; i++) {
            assertEq(uint8(hook.getBond(ids[i]).state), 3, "a batched bond is not SETTLED");
        }

        (,,, uint32 pending,) = hook.maturity(id_, m);
        assertEq(pending, 0, "batch did not decrement pendingBonds to zero");
    }

    /// @notice ATOMIC: one bad entry reverts the whole batch, leaving the good ones unsettled.
    /// @dev Skip-and-continue was rejected so a successful batch reads as "all of these settled".
    function test_settleMany_isAtomic_oneBadEntryRevertsAll() public {
        uint32 m = _maturityOfNow();

        bytes32 good = _bondIdAt(m, 0);
        _swap(BONDED_INPUT, true, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        // Settle it once, so its id is now an invalid batch entry.
        hook.settleBond(good);

        bytes32 second = _bondIdAt(m, 1);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = second; // does not exist
        ids[1] = good; // already settled

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotSettleable.selector, second, uint8(0)));
        hook.settleMany(ids);
    }

    function test_settleMany_revertsPastTheCap() public {
        uint256 cap = hook.MAX_SETTLE_BATCH();

        bytes32[] memory ids = new bytes32[](cap + 1);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.SettleBatchTooLarge.selector, cap + 1, cap));
        hook.settleMany(ids);
    }

    function test_settleMany_acceptsExactlyTheCap() public {
        uint256 cap = hook.MAX_SETTLE_BATCH();
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](cap);
        for (uint32 i = 0; i < cap; i++) {
            ids[i] = _bondIdAt(m, i);
            _swap(BONDED_INPUT, true, _hookData());
        }

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        hook.settleMany(ids);

        (,,, uint32 pending,) = hook.maturity(id_, m);
        assertEq(pending, 0, "cap-sized batch did not settle every bond");
    }

    /*//////////////////////////////////////////////////////////////
                            INSURANCE POT
    //////////////////////////////////////////////////////////////*/

    /// @notice The pot accrues across several slashed bonds.
    function test_pot_accruesAcrossBonds() public {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](3);
        for (uint32 i = 0; i < 3; i++) {
            ids[i] = _bondIdAt(m, i);
            _swap(BONDED_INPUT, true, _hookData());
        }

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        Currency c = _collateralCurrencyOf(ids[0]);

        uint256 running;
        for (uint256 i = 0; i < 3; i++) {
            hook.settleBond(ids[i]);
            uint256 pot = hook.insurancePot(id_, c);
            assertGe(pot, running, "the pot went down");
            running = pot;
        }

        assertGt(running, 0, "no slash accrued at all");
    }

    /// @notice Currencies are accounted separately: a currency0 slash never credits currency1.
    function test_pot_currenciesAreSeparate() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(BONDED_INPUT, true, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        hook.settleBond(bondId);

        // Stated relative to the bond's OWN collateral currency rather than to currency0. Under
        // variable-leg custody an exact-input zeroForOne bond is held in currency1, so naming the
        // currencies literally here would assert the isolation backwards -- and would pass, since
        // the untouched side is trivially zero.
        assertGt(
            hook.insurancePot(id_, _collateralCurrencyOf(bondId)), 0, "the collateral currency's pot did not accrue"
        );

        assertEq(hook.insurancePot(id_, _otherCurrencyOf(bondId)), 0, "the slash credited the wrong currency");
    }

    /*//////////////////////////////////////////////////////////////
                       pendingBonds LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Settlement decrements `pendingBonds` exactly once per bond, and reaching zero does
    ///         NOT delete the checkpoint.
    /// @dev ADR-0003 § 5.4. A deleted bucket would destroy the settlement input of any bond still
    ///      pointing at it, and the checkpoint costs nothing to keep.
    function test_pendingBonds_decrementsOnceAndCheckpointSurvivesZero() public {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](3);
        for (uint32 i = 0; i < 3; i++) {
            ids[i] = _bondIdAt(m, i);
            _swap(BONDED_INPUT, true, _hookData());
        }

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        (,, int56 frozenCumulative, uint32 pending, uint8 checkpointedMask) = hook.maturity(id_, m);

        bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;
        assertEq(pending, 3, "three bonds should be pending");
        assertTrue(checkpointed);

        for (uint256 i = 0; i < 3; i++) {
            hook.settleBond(ids[i]);

            (,,, uint32 remaining,) = hook.maturity(id_, m);
            assertEq(remaining, 3 - (i + 1), "pendingBonds did not decrement exactly once");
        }

        // Zero pending, and the checkpoint is untouched.
        (,, int56 stillFrozen, uint32 zero, uint8 stillCheckpointedMask) = hook.maturity(id_, m);
        bool stillCheckpointed = stillCheckpointedMask & hook.FROZEN_C10() != 0;
        assertEq(zero, 0);
        assertTrue(stillCheckpointed, "checkpoint was deleted at zero pending");
        assertEq(stillFrozen, frozenCumulative, "checkpoint changed at zero pending");

        // And later swaps still cannot touch it.
        vm.roll(block.number + 50);
        _swap(-5e15, true, _hookData());

        (,, int56 afterMore,, uint8 stillThereMask) = hook.maturity(id_, m);

        bool stillThere = stillThereMask & hook.FROZEN_C10() != 0;
        assertTrue(stillThere, "checkpoint lost after later swaps");
        assertEq(afterMore, frozenCumulative, "checkpoint changed after later swaps");
    }

    /*//////////////////////////////////////////////////////////////
                            DEMO TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice DEMO — a trade whose price impact reverted gets its collateral back in full.
    ///
    /// @dev The story, end to end, on the real PoolManager with real ERC-20 balances:
    ///
    ///        1. A trader makes a large swap. The price moves.
    ///        2. BondMeBro holds back a refundable bond, carved out of their own input.
    ///        3. Other traders push the price back where it started.
    ///        4. The observation window closes and the maturity checkpoint freezes.
    ///        5. Anyone at all calls `settleBond` — it is permissionless.
    ///        6. The price displacement did not survive, so the trader gets everything back.
    function test_demo_RevertRefunds() public {
        // 1-2. The trader swaps, and BondMeBro takes the bond.
        (bytes32 bondId, uint32 maturityBlock) = _openBond();

        uint128 collateral = hook.collateralAmountOf(bondId);
        assertGt(collateral, 0, "the bond was never taken");

        console2.log("collateral held (raw units of the COLLATERAL currency):", collateral);

        // 3. Arbitrage pushes the price back where it started — and a little past, as real
        //    arbitrage does. That matters: the observation window starts at the post-swap tick, so
        //    the displaced block is inside the average and an exact-to-the-tick reversion would
        //    still leave a sliver surviving.
        vm.roll(block.number + 1);
        _swap(-4e16, false, _hookData());

        // 4. The window closes and the checkpoint freezes.
        vm.roll(uint256(maturityBlock) + 1);
        _swap(-1e13, true, "");

        (,,,, uint8 checkpointedMask) = hook.maturity(id_, maturityBlock);

        bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;
        assertTrue(checkpointed, "the maturity checkpoint never froze");

        // 5. A completely unrelated address settles it.
        Currency c = _collateralCurrencyOf(bondId);

        uint256 traderBefore = c.balanceOf(TRADER);

        vm.prank(address(0xDEADBEEF));
        hook.settleBond(bondId);

        // 6. Full refund, nothing retained.
        uint256 refunded = c.balanceOf(TRADER) - traderBefore;
        uint256 pot = hook.insurancePot(id_, c);

        console2.log("refunded to trader             :", refunded);
        console2.log("retained as LP protection      :", pot);

        assertEq(refunded, collateral, "the trader did not get the full collateral back");
        assertEq(pot, 0, "collateral was retained despite the price reverting");
        assertEq(uint8(hook.getBond(bondId).state), 3, "bond is not SETTLED");
    }

    /// @notice DEMO — a trade whose price impact persisted has its collateral retained for LPs.
    ///
    /// @dev The mirror story:
    ///
    ///        1. A trader makes a large swap. The price moves.
    ///        2. BondMeBro holds back the same refundable bond.
    ///        3. Nobody pushes the price back — it stays where the trade left it.
    ///        4. The window closes and the checkpoint freezes.
    ///        5. Anyone calls `settleBond`.
    ///        6. The displacement survived in full, so the collateral becomes LP protection.
    ///
    ///      This is the canonical adverse-selection case: the price moved and stayed moved, and
    ///      the liquidity providers wore it.
    function test_demo_PersistSlashes() public {
        // 1-2.
        (bytes32 bondId, uint32 maturityBlock) = _openBond();

        uint128 collateral = hook.collateralAmountOf(bondId);
        assertGt(collateral, 0, "the bond was never taken");

        console2.log("collateral held (raw units of the COLLATERAL currency):", collateral);

        // 3. Nothing pushes it back. The window elapses with the price still displaced.
        vm.roll(uint256(maturityBlock) + 1);
        _swap(-1e13, true, "");

        // 4.
        (,,,, uint8 checkpointedMask) = hook.maturity(id_, maturityBlock);
        bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;
        assertTrue(checkpointed, "the maturity checkpoint never froze");

        // 5.
        Currency c = _collateralCurrencyOf(bondId);

        uint256 traderBefore = c.balanceOf(TRADER);

        vm.prank(address(0xDEADBEEF));
        hook.settleBond(bondId);

        // 6.
        uint256 refunded = c.balanceOf(TRADER) - traderBefore;
        uint256 pot = hook.insurancePot(id_, c);

        console2.log("refunded to trader             :", refunded);
        console2.log("retained as LP protection      :", pot);

        assertEq(pot, collateral, "a fully persistent displacement did not retain the whole bond");
        assertEq(refunded, 0, "collateral was refunded despite the displacement persisting");
        assertEq(refunded + pot, collateral, "refund + slash != collateral");
        assertEq(uint8(hook.getBond(bondId).state), 3, "bond is not SETTLED");
    }

    /*//////////////////////////////////////////////////////////////
                            SETTLEMENT GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Settlement is a standalone transaction, so no callback ceiling governs it. These are
    ///      reported measurements rather than gates. The frozen-checkpoint path and the quiet
    ///      derive-and-freeze path are separated because the latter pays an extra cold SSTORE to
    ///      write the checkpoint settlement itself discovered was missing.
    function test_gas_settleBond_refundPath() public {
        (bytes32 bondId, uint32 m) = _openBond();

        vm.roll(block.number + 1);
        _swap(-4e16, false, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        hook.settleBond(bondId);
    }

    function test_gas_settleBond_slashPath() public {
        (bytes32 bondId, uint32 m) = _openBond();

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        hook.settleBond(bondId);
    }

    /// @dev The quiet path: no swap ever crossed M, so settlement must derive and freeze it.
    function test_gas_settleBond_quietDeriveAndFreeze() public {
        (bytes32 bondId, uint32 m) = _openBond();

        vm.roll(uint256(m) + 100);

        hook.settleBond(bondId);
    }

    function test_gas_settleMany_1() public {
        _measureBatch(1);
    }

    function test_gas_settleMany_8() public {
        _measureBatch(8);
    }

    function test_gas_settleMany_32() public {
        _measureBatch(32);
    }

    /// @dev Opens `count` bonds sharing one maturity, crosses it, and settles them in one batch.
    function _measureBatch(uint32 count) internal {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](count);
        for (uint32 i = 0; i < count; i++) {
            ids[i] = _bondIdAt(m, i);
            _swap(BONDED_INPUT, true, _hookData());
        }

        vm.roll(uint256(m) + 1);
        _swap(-1e13, true, "");

        hook.settleMany(ids);
    }
}
