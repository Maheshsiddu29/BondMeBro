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
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title BondCustodyTest

/// @notice Integration tests for BondMeBro's exact-input custody path. Every swap runs through a real Uniswap v4 `PoolManager` so the tests verify actual ERC-20 custody and custom-accounting behaviour rather than only checking callback return values.

contract BondCustodyTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;

    /// @dev Both test tokens use 18 decimals, so equal thresholds are appropriate here. Different-decimal threshold behaviour is tested separately in `BondThresholds.t.sol`.
    uint96 internal constant MIN_BONDED_1 = 1e15;

    /// @dev Retained as the ENABLE FLAG, not as a rate.
    ///
    ///      P-L2-3/4 replaced amount-proportional sizing with Model L, so the collateral rate is
    ///      now derived from the realized tick impact and `bondBps` no longer participates in
    ///      sizing at all. It still gates bonding (`cfg.bondBps == 0` means disabled) and is still
    ///      required by the all-or-nothing config rule, so it must still be set. Tests that used
    ///      it to PREDICT a bond have been rewritten against `ModelLReference`; a test that still
    ///      multiplied by this value would be asserting arithmetic the hook no longer performs.
    uint16 internal constant BOND_BPS = 25;

    /// @dev Settlement noise floor, in ticks. Displacement at or below this is never slashed.
    uint16 internal constant REFUND_TOL = 5;

    /// @dev A bonded exact-input amount large enough to avoid rounding in the bond calculation
    ///      AND large enough, against `POOL_LIQUIDITY`, to move the price by a measurable number
    ///      of ticks. The second requirement is new in P-L2-3/4 and is not optional: under Model L
    ///      a swap that moves no tick posts no collateral, so a sizing test run on a pool too deep
    ///      to move would silently become an unbonded-path test that asserts `0 == 0`.
    int256 internal constant BONDED_INPUT = -1e16;

    uint256 internal constant BONDED_GROSS = 1e16;

    /// @dev Below the bonding threshold, so this amount should take the unbonded path.
    int256 internal constant UNBONDED_INPUT = -1e14;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    /// @dev See the comment at the `modifyLiquidity` call in `setUp` for why this specific depth.
    int128 internal constant POOL_LIQUIDITY = 1e19;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // In `forge test`, CREATE2 deployment happens from this test contract.
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        // Liquidity is deep enough that the accounting tests are not accidentally partial-fill
        // tests, and SHALLOW enough that `BONDED_INPUT` actually moves the price.
        //
        // THIS NUMBER IS LOAD-BEARING, AND IT CHANGED IN P-L2-3/4 (1e21 -> 1e19).
        //
        // Model L prices collateral off the realized tick impact, which couples every custody test
        // to the pool's depth for the first time. Measured on this fixture, a 1e16 exact-input
        // swap moves:
        //
        //     liquidity 1e21  ->   1 tick    ->  1 bps   (barely distinguishable from noise)
        //     liquidity 1e19  ->  19 ticks   ->  5 bps
        //     liquidity 1e18  -> 100 ticks   -> 25 bps
        //
        // At the old 1e21 the impact was a single tick, so the bond was ~1 bps of the output and
        // any off-by-one in the ceiling would have been invisible. 1e19 puts the rate in the
        // middle of the curve, well clear of both the zero-impact floor and the 397-tick cap, so
        // a wrong rate shows up as a wrong number rather than as a rounding coincidence.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _swap(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
        swapRouter.swap(
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

    function _swapWithLimit(int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _validHookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /// @dev Everything a variable-leg custody assertion needs, measured rather than assumed.
    ///
    ///      Under the old model the bond was a pure function of a number the test already knew --
    ///      the requested input -- so tests could hard-code it. Under Model L it depends on two
    ///      things only the pool can tell you: the REALIZED variable leg and the REALIZED tick
    ///      impact. Both are captured here so the expected bond can be derived independently
    ///      through `ModelLReference` and compared against what the hook actually took.
    struct Measured {
        int24 tickBefore;
        int24 tickAfter;
        uint256 traderPaid0;
        uint256 traderPaid1;
        uint256 traderGot0;
        uint256 traderGot1;
        uint256 hookGained0;
        uint256 hookGained1;
        uint256 managerGained0;
        uint256 managerGained1;
    }

    /// @dev Runs a swap and reports every balance movement it caused, plus the tick either side.
    ///
    ///      Balances are captured for all three parties in both currencies, because variable-leg
    ///      custody moves collateral to a currency the old tests never watched. A test that only
    ///      measured the input currency would report "the hook took nothing" for a swap that
    ///      bonded correctly -- which is precisely how this migration first showed up.
    function _measuredSwap(int256 amountSpecified, bool zeroForOne, bytes memory hookData)
        internal
        returns (Measured memory m)
    {
        uint256 t0 = currency0.balanceOf(address(this));
        uint256 t1 = currency1.balanceOf(address(this));
        uint256 h0 = currency0.balanceOf(address(hook));
        uint256 h1 = currency1.balanceOf(address(hook));
        uint256 g0 = currency0.balanceOf(address(manager));
        uint256 g1 = currency1.balanceOf(address(manager));

        // slither-disable-next-line unused-return
        (, m.tickBefore,,) = manager.getSlot0(id_);

        _swap(amountSpecified, zeroForOne, hookData);

        // slither-disable-next-line unused-return
        (, m.tickAfter,,) = manager.getSlot0(id_);

        uint256 now0 = currency0.balanceOf(address(this));
        uint256 now1 = currency1.balanceOf(address(this));

        m.traderPaid0 = t0 > now0 ? t0 - now0 : 0;
        m.traderGot0 = now0 > t0 ? now0 - t0 : 0;
        m.traderPaid1 = t1 > now1 ? t1 - now1 : 0;
        m.traderGot1 = now1 > t1 ? now1 - t1 : 0;

        m.hookGained0 = currency0.balanceOf(address(hook)) - h0;
        m.hookGained1 = currency1.balanceOf(address(hook)) - h1;

        uint256 mgr0 = currency0.balanceOf(address(manager));
        uint256 mgr1 = currency1.balanceOf(address(manager));

        m.managerGained0 = mgr0 > g0 ? mgr0 - g0 : 0;
        m.managerGained1 = mgr1 > g1 ? mgr1 - g1 : 0;

        return m;
    }

    /// @dev The impact a measurement observed, in ticks, as a positive magnitude.
    function _impact(Measured memory m) internal pure returns (uint256) {
        int256 d = int256(m.tickAfter) - int256(m.tickBefore);

        return uint256(d < 0 ? -d : d);
    }

    /// @dev Hook reverts are wrapped by Uniswap's hook-calling logic. This helper builds the expected wrapped error so tests verify the exact underlying BondMeBro error rather than accepting any revert.
    function _wrapped(bytes memory innerReason) internal view returns (bytes memory) {
        return _wrappedIn(IHooks.beforeSwap.selector, innerReason);
    }

    /// @dev The same, for a revert raised in a NAMED callback.
    ///
    ///      P-L2-3/4 moved custody from `beforeSwap` to `afterSwap`, and the wrapper records which
    ///      callback failed. So every custody revert -- the trader ceiling, INV-NOOP-VL -- now
    ///      arrives wrapped in `afterSwap.selector` while the hookData and configuration reverts
    ///      still arrive wrapped in `beforeSwap.selector`. Getting this wrong produces a confusing
    ///      "Error != expected error" on two byte strings that differ only in a four-byte
    ///      selector, so the callback is named explicitly at each call site rather than defaulted.
    function _wrappedIn(bytes4 callback, bytes memory innerReason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            innerReason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /*//////////////////////////////////////////////////////////////
                      EXACT-INPUT CUSTODY ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice The complete exact-input custody flow under variable-leg custody.
    ///
    /// @dev THIS IS THE TEST THE MIGRATION INVERTED, so it is worth stating both shapes.
    ///
    ///      Before (collateral carved out of the INPUT):
    ///
    ///          grossInput = poolInput + bond
    ///          the pool received LESS than the trader paid
    ///
    ///      Now (collateral taken from the VARIABLE leg, which for exact-input is the OUTPUT):
    ///
    ///          poolInput  = grossInput                  <- the pool receives the FULL input
    ///          traderOut  = rawOutput - bond            <- the bond is withheld from the output
    ///
    ///      The trader's input is untouched, which is the entire point: the specified leg is left
    ///      exactly as specified, so the hook never needs `BEFORE_SWAP_RETURNS_DELTA` and can
    ///      never turn the swap into a no-op by consuming the specified amount.
    ///
    ///      The expected bond is derived through `ModelLReference` from the REALIZED output and
    ///      the REALIZED impact -- never from the requested input, which no longer determines it.
    function test_bondedSwap_exactCustodyAccounting() public {
        Measured memory m = _measuredSwap(BONDED_INPUT, true, _validHookData());

        // The fixture must actually move the price, or the assertions below are vacuous.
        assertGe(_impact(m), ModelLReference.minimumChargeableImpact(), "fixture moved no tick: nothing would bond");

        // The trader pays exactly the specified input. Not "at most" -- exactly.
        assertEq(m.traderPaid0, BONDED_GROSS, "trader did not pay exactly the specified input");

        // And ALL of it reaches the pool. This is the inversion: there is no longer a carve-out.
        assertEq(m.managerGained0, BONDED_GROSS, "the pool did not receive the full input");

        assertEq(m.hookGained0, 0, "the hook took collateral from the INPUT currency");

        // The raw output is what the trader received plus what the hook withheld.
        uint256 rawOutput = m.traderGot1 + m.hookGained1;

        uint256 expectedBond = ModelLReference.collateralFor(rawOutput, m.tickBefore, m.tickAfter);

        assertGt(expectedBond, 0, "the reference predicts a zero bond: fixture is not exercising custody");

        assertEq(m.hookGained1, expectedBond, "the hook did not take exactly the Model L collateral");

        // Output-side conservation: everything the pool paid out went to exactly one of the two.
        assertEq(m.managerGained1, 0, "the manager gained output currency");

        assertGt(m.traderGot1, 0, "trader received no output at all");

        // The bond is a strict fraction of the leg -- INV-NOOP-VL, observed end to end.
        assertLt(m.hookGained1, rawOutput, "INV-NOOP-VL: bond consumed the entire variable leg");
    }

    /// @notice Bond custody ends as real ERC-20 tokens, with no PoolManager claim left behind.
    ///
    /// @dev `take(..., false)` asks PoolManager to transfer real tokens rather than mint a claim.
    ///      If that flag were ever flipped the hook's balance would look correct to an internal
    ///      accounting check while holding nothing transferable, so both claim balances are
    ///      asserted zero explicitly.
    function test_bondedSwap_hookHoldsNoResidualClaim() public {
        Measured memory m = _measuredSwap(BONDED_INPUT, true, _validHookData());

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds currency0 claims");

        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook holds currency1 claims");

        // Exact-input zeroForOne: the collateral currency is currency1, the OUTPUT.
        uint256 expectedBond = ModelLReference.collateralFor(m.traderGot1 + m.hookGained1, m.tickBefore, m.tickAfter);

        assertGt(expectedBond, 0, "fixture produced no bond");

        assertEq(currency1.balanceOf(address(hook)), expectedBond, "bond is not held as ERC-20 in currency1");

        assertEq(currency0.balanceOf(address(hook)), 0, "hook holds currency0 it should never have taken");
    }

    /// @notice A oneForZero exact-input swap takes collateral in currency0 -- its OUTPUT.
    ///
    /// @dev THE SEMANTIC FLIP, PINNED IN BOTH DIRECTIONS.
    ///
    ///      This test previously asserted the opposite currency, and it was correct then: the
    ///      collateral came from the input, which for oneForZero is currency1. Under ADR-0006 the
    ///      collateral comes from the variable leg, which for an exact-INPUT swap is the OUTPUT,
    ///      so the same swap now bonds in currency0.
    ///
    ///      Both currencies are asserted. Checking only that currency0 grew would still pass if
    ///      the hook took collateral from BOTH sides, which is the failure mode a one-sided
    ///      assertion is least able to see.
    function test_bondedSwap_oneForZero_bondsInCurrency0() public {
        Measured memory m = _measuredSwap(BONDED_INPUT, false, _validHookData());

        assertGe(_impact(m), ModelLReference.minimumChargeableImpact(), "fixture moved no tick");

        uint256 rawOutput = m.traderGot0 + m.hookGained0;

        uint256 expectedBond = ModelLReference.collateralFor(rawOutput, m.tickBefore, m.tickAfter);

        assertGt(expectedBond, 0, "fixture produced no bond");

        assertEq(m.hookGained0, expectedBond, "bond not taken in currency0 (the output)");

        assertEq(m.hookGained1, 0, "currency1 moved to the hook on an exact-input oneForZero swap");

        // The direction predicate itself, stated independently of the balances above.
        assertTrue(
            ModelLReference.collateralIsCurrency0({zeroForOne: false, exactInput: true}),
            "reference disagrees: exact-input oneForZero must bond in currency0"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             PARTIAL FILL
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-L2-13: the bond follows the ACTUAL fill, not the requested amount.
    ///
    /// @dev THIS TEST ASSERTED THE OPPOSITE BEFORE P-L2-3/4, and the inversion is the point.
    ///
    ///      The old model computed the bond in `beforeSwap` from the REQUESTED input, before
    ///      anyone knew how much would fill. A swap that requested 1e16 but stopped at a price
    ///      limit after 5.5% still posted the full 25 bps of the request -- an effective 452 bps
    ///      on the input actually consumed, roughly 18x oversized. The old test recorded that as a
    ///      "known sizing limitation"; `docs/INVARIANTS-L2.md` records it as INV-L2-13, and it is
    ///      one of the three defects this migration exists to remove.
    ///
    ///      Custody now happens in `afterSwap`, where the realized legs are known, so the bond is
    ///      priced off what actually executed. The assertion below is therefore not "the bond is
    ///      still the requested-size bond" but its negation, bounded from both sides.
    function test_inv_L2_13_partialFill_bondFollowsTheActualFill() public {
        // A tight limit relative to the current price, so the swap stops early by design.
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceNow,,,) = manager.getSlot0(id_);

        // 200 ppm below the current sqrt price.
        //
        // The magnitude matters and is easy to get wrong: a 19-tick move is ~0.19% in PRICE but
        // only ~0.095% in SQRT price, and `sqrtPriceLimitX96` is a bound on the latter. A 0.1%
        // limit therefore does not bind at all and the swap fills completely, which shows up as
        // this test reporting that it "did not partially fill" rather than as a wrong number.
        uint160 tightLimit = sqrtPriceNow - uint160((uint256(sqrtPriceNow) * 200) / 1_000_000);

        uint256 t0 = currency0.balanceOf(address(this));
        uint256 t1 = currency1.balanceOf(address(this));
        uint256 h1 = currency1.balanceOf(address(hook));
        uint256 g0 = currency0.balanceOf(address(manager));

        // slither-disable-next-line unused-return
        (, int24 tickBefore,,) = manager.getSlot0(id_);

        _swapWithLimit(BONDED_INPUT, tightLimit, _validHookData());

        // slither-disable-next-line unused-return
        (, int24 tickAfter,,) = manager.getSlot0(id_);

        uint256 filled = currency0.balanceOf(address(manager)) - g0;
        uint256 traderPaid = t0 - currency0.balanceOf(address(this));
        uint256 traderGot = currency1.balanceOf(address(this)) - t1;
        uint256 bond = currency1.balanceOf(address(hook)) - h1;

        // The fixture must genuinely be a partial fill, or this proves nothing.
        assertLt(filled, BONDED_GROSS, "swap did not partially fill; the test is not exercising the case");

        assertGt(filled, 0, "swap filled nothing at all");

        // The input side is untouched by custody: the trader pays exactly what filled.
        assertEq(traderPaid, filled, "trader paid something other than the amount that filled");

        uint256 rawOutput = traderGot + bond;

        // The bond matches the realized output and realized impact, to the wei.
        assertEq(
            bond,
            ModelLReference.collateralFor(rawOutput, tickBefore, tickAfter),
            "INV-L2-13: bond does not match the REALIZED leg and impact"
        );

        // And the old defect is gone, stated as its own bound rather than left implied.
        //
        // The pre-migration bond for this swap would have been `BONDED_GROSS * 25 / 10_000`,
        // sized off the full request. Whatever the fill turns out to be, the bond must now be
        // strictly below the collateral implied by treating the request as the leg -- because the
        // leg that actually materialized is smaller than the one that was asked for.
        uint256 oversizedLegacyBond = (BONDED_GROSS * 25) / 10_000;

        assertLt(bond, oversizedLegacyBond, "the bond is still being sized off the REQUESTED input");
    }

    /// @notice The bond is strictly monotone in the fill: a bigger fill can never bond less.
    ///
    /// @dev The single partial fill above shows the bond moved. This shows it moves the right WAY,
    ///      across a ladder of fills, which is the property a trader actually relies on. A hook
    ///      that priced collateral off something unrelated to execution could still pass a single
    ///      point check by coincidence; it cannot pass an ordered ladder.
    ///
    ///      Fills are produced by tightening the price limit rather than by shrinking the request,
    ///      so the REQUEST is identical on every rung. Under the old model every rung would have
    ///      posted an identical bond, and this test would fail on its first comparison.
    function test_inv_L2_13_bondIsMonotoneInTheFill() public {
        // Rungs in ppm of the sqrt price, all strictly inside the ~950 ppm this swap would move
        // if unconstrained -- otherwise the top rungs stop binding and every one of them fills
        // completely, which makes the ladder flat rather than increasing.
        uint16[5] memory looseness = [uint16(100), 250, 450, 650, 850];

        uint256 previousFill;
        uint256 previousBond;

        for (uint256 i = 0; i < looseness.length; i++) {
            uint256 snapshot = vm.snapshotState();

            // slither-disable-next-line unused-return
            (uint160 sqrtPriceNow,,,) = manager.getSlot0(id_);

            uint160 limit = sqrtPriceNow - uint160((uint256(sqrtPriceNow) * looseness[i]) / 1_000_000);

            uint256 g0 = currency0.balanceOf(address(manager));
            uint256 h1 = currency1.balanceOf(address(hook));

            _swapWithLimit(BONDED_INPUT, limit, _validHookData());

            uint256 fill = currency0.balanceOf(address(manager)) - g0;
            uint256 bond = currency1.balanceOf(address(hook)) - h1;

            if (i > 0) {
                assertGt(fill, previousFill, "the ladder did not actually increase the fill");

                assertGe(bond, previousBond, "INV-L2-13: a larger fill posted a SMALLER bond");
            }

            previousFill = fill;
            previousBond = bond;

            vm.revertToState(snapshot);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INV-NOOP-VL  (INV-L2-1)
    //////////////////////////////////////////////////////////////*/

    /// @notice A variable leg too small to carve collateral from is DECLINED, not reverted.
    ///
    /// @dev THIS TEST USED TO ASSERT A REVERT, and flipping it is the point of the change rather
    ///      than a casualty of it. Reverting here was a real availability defect: the trade that
    ///      gets rejected is an ordinary small one, and on a pool whose two tokens differ in
    ///      decimals it is not small at all in human terms -- only in the raw units of the leg the
    ///      collateral is taken from. Whole size bands of honest trades were unexecutable.
    ///
    ///      There are three ways a bonded swap can end up taking no collateral, and the hook now
    ///      treats the first two the same way:
    ///
    ///        leg < minVariableLeg -- the leg is too small to carve a bond out of. The swap is
    ///                               UNBONDED: it executes in full, pays nothing, records nothing.
    ///
    ///        collateralBps == 0  -- the price did not move a whole tick. No LP-risk signal to
    ///                               price, so again UNBONDED. A normal outcome.
    ///
    ///        leg * bps / 10_000 == 0 with both gates cleared -- NOW UNREACHABLE. A leg of at
    ///                               least `BPS` raw units at a rate of at least one basis point
    ///                               always yields a positive collateral, and `setPoolConfig`
    ///                               refuses a minimum below `BPS`. The revert survives as a
    ///                               last-resort guard; the companion test below proves it can no
    ///                               longer fire.
    ///
    ///      What has NOT changed is the invariant itself: a zero-collateral bond is still never
    ///      finalized. The swap is turned away from bonding instead of being turned away entirely,
    ///      so this test asserts what the declined path must leave behind -- no collateral moved,
    ///      no maturity liability, and a trade that actually executed.
    ///
    ///      The construction still needs a pool thin enough that a sub-10,000-unit swap crosses a
    ///      tick, which is why it builds its own pool rather than using the fixture: on
    ///      `POOL_LIQUIDITY` no amount that small could ever move the price.
    function test_invNoOpVL_bondRoundingToZero_isDeclinedNotReverted() public {
        // A separate pool on the same hook, on a DIFFERENT fee tier so the PoolKey differs from
        // the fixture's, and with almost no liquidity so a few hundred wei still crosses a tick.
        (PoolKey memory thinKey, PoolId thinId) =
            initPool(currency0, currency1, IHooks(address(hook)), 500, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            thinKey,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 4e6, salt: bytes32(0)}),
            ""
        );

        uint256 baseline = vm.snapshotState();

        // PHASE 1 -- search with bonding DISABLED.
        //
        // The pool is left unconfigured while searching so the probe swaps take the unbonded path:
        // they need no hookData and, crucially, cannot revert with the very error this test is
        // trying to provoke. Searching with bonding on would make the target case indistinguishable
        // from a failed probe, because both arrive as a revert.
        uint256 chosen;
        uint256 observedLeg;

        for (uint256 amount = 100; amount <= 9_000; amount += 100) {
            uint256 snapshot = vm.snapshotState();

            // slither-disable-next-line unused-return
            (, int24 before_,,) = manager.getSlot0(thinId);

            uint256 traderBefore1 = currency1.balanceOf(address(this));

            swapRouter.swap(
                thinKey,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            // slither-disable-next-line unused-return
            (, int24 after_,,) = manager.getSlot0(thinId);

            uint256 leg = currency1.balanceOf(address(this)) - traderBefore1;

            bool movedATick = ModelLReference.collateralBps(before_, after_) > 0;

            bool truncatesToZero = leg > 0 && ModelLReference.collateralFor(leg, before_, after_) == 0;

            vm.revertToState(snapshot);

            if (movedATick && truncatesToZero) {
                chosen = amount;
                observedLeg = leg;
                break;
            }
        }

        assertGt(chosen, 0, "could not construct a moved-a-tick-but-truncates-to-zero swap");

        // PHASE 2 -- same pool, same price, bonding ON.
        //
        // Reverting to the baseline restores the pool's price exactly, so the chosen amount
        // reproduces the identical tick move and identical leg measured above.
        vm.revertToState(baseline);

        // The lowest variable-leg minimum the hook will accept. Even at the floor, a leg of
        // `observedLeg` units is below it -- that is precisely what made the collateral truncate.
        hook.setPoolConfig(thinKey, 1, 1, 10_000, 10_000, true);

        assertLt(observedLeg, 10_000, "the leg was not actually below the minimum: the test proves nothing");

        uint256 hookBefore = currency1.balanceOf(address(hook));
        uint256 traderBefore = currency1.balanceOf(address(this));

        // No `expectRevert`: the swap must go through.
        swapRouter.swap(
            thinKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(chosen), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _validHookData()
        );

        // The trade executed and kept its whole output: declined means unbonded, not discounted.
        assertEq(
            currency1.balanceOf(address(this)) - traderBefore,
            observedLeg,
            "the declined swap did not deliver its full output"
        );

        assertEq(currency1.balanceOf(address(hook)), hookBefore, "a declined swap still took collateral");

        // And it left no obligation behind.
        (,,, uint32 pending,) = hook.maturity(thinId, uint32(block.number) + hook.OBSERVATION_BLOCKS());

        assertEq(pending, 0, "a declined swap registered a maturity liability");
    }

    /// @notice ...and the zero-collateral branch the old test drove is now unreachable by
    ///         arithmetic, so the guard behind it can no longer fire.
    ///
    /// @dev The coverage the rewrite above gives up is restated here as what it now is: a fact
    ///      about two enforced bounds rather than a live branch.
    ///
    ///          leg >= BPS            enforced by `setPoolConfig`, which refuses a smaller minimum
    ///          bps >= 1              anything less is the unbonded path, checked before the divide
    ///
    ///          bond = leg * bps / 10_000  >=  10_000 * 1 / 10_000  =  1  >  0
    ///
    ///      If anyone ever lowers the configurable floor below `BPS`, this fails and points at the
    ///      guard that would become reachable again.
    function test_invNoOpVL_lowerBoundIsUnreachableUnderTheLegMinimum() public {
        // The floor is enforced, not merely documented.
        vm.expectRevert(abi.encodeWithSelector(BondMeBro.VariableLegMinimumTooSmall.selector, uint256(9_999), 10_000));

        hook.setPoolConfig(key_, 1, 1, 9_999, 10_000, true);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.VariableLegMinimumTooSmall.selector, uint256(0), 10_000));

        hook.setPoolConfig(key_, 1, 1, 10_000, 0, true);

        // And at the floor, every legal rate still yields at least one raw unit.
        for (uint256 bps = 1; bps <= hook.MAX_BOND_BPS(); bps++) {
            assertGt((uint256(10_000) * bps) / 10_000, 0, "a leg at the enforced floor truncated to zero collateral");
        }
    }

    /// @notice The UPPER half of INV-NOOP-VL cannot be reached, and this proves WHY rather than
    ///         quietly omitting it.
    ///
    /// @dev `bond >= variableLegAmount` is unreachable while `MAX_BOND_BPS` is 100:
    ///
    ///          bond = leg * bps / 10_000   with   bps <= 100
    ///               <= leg / 100
    ///               <  leg                 for every leg >= 1
    ///
    ///      So the guard in `_takeVariableLegBond` is defensive depth, not a live branch, and no
    ///      integration test can drive it. That is a meaningful improvement over the old model,
    ///      where `bondBps` was a configurable rate and a mis-set config really could make the
    ///      bond swallow the whole leg -- the two deleted `_forceBondBps` tests existed precisely
    ///      to cover that risk.
    ///
    ///      Rather than delete the coverage, the claim is restated as what it now is: an
    ///      arithmetic fact about the rate cap, swept exhaustively over every legal rate and a
    ///      wide range of legs. If anyone ever raises `MAX_BOND_BPS` to 10,000, this fails
    ///      immediately and points at the guard that would then become reachable.
    function test_invNoOpVL_upperBoundIsUnreachableUnderTheRateCap() public view {
        assertLe(hook.MAX_BOND_BPS(), 100, "MAX_BOND_BPS was raised: the INV-NOOP-VL upper guard is now REACHABLE");

        uint256[6] memory legs = [uint256(10_000), 10_001, 1e12, 1e18, 1e24, type(uint96).max];

        for (uint256 i = 0; i < legs.length; i++) {
            for (uint256 bps = 1; bps <= hook.MAX_BOND_BPS(); bps++) {
                uint256 bond = (legs[i] * bps) / 10_000;

                assertLt(bond, legs[i], "INV-NOOP-VL upper bound violated by the rate cap arithmetic");
            }
        }
    }

    /// @notice INV-NOOP-VL over random legs and every legal impact, against the reference.
    ///
    /// @dev Fuzzed on the pure relation rather than through a pool, because a pool can only
    ///      produce the impacts its liquidity permits, and the invariant is claimed for all of
    ///      them. Legs below the truncation floor are excluded and asserted separately above --
    ///      lumping them in here would make the test pass by skipping the interesting case.
    function testFuzz_invNoOpVL_holdsForEveryLegAndImpact(uint128 leg, uint32 impactTicks) public pure {
        impactTicks = uint32(bound(impactTicks, 1, 100_000));

        leg = uint128(bound(leg, 1, type(uint128).max));

        uint256 bps = ModelLReference.collateralBps(0, int24(int32(uint32(bound(impactTicks, 1, 800_000)))));

        uint256 bond = (uint256(leg) * bps) / 10_000;

        // The invariant is conditional on the bond being taken at all: a leg small enough to
        // truncate is REJECTED by the hook, not accepted with a zero bond.
        if (bond == 0) return;

        assertGt(bond, 0, "INV-NOOP-VL lower bound violated");

        assertLt(bond, leg, "INV-NOOP-VL upper bound violated");
    }

    /// @dev `_forceBondBps` was REMOVED here, and its removal is recorded rather than silent.
    ///
    ///      It wrote an out-of-range `bondBps` straight into the packed config slot so INV-NOOP's
    ///      upper bound could be driven past the owner-facing cap. Under Model L the collateral
    ///      rate no longer comes from `bondBps` at all -- it is derived from the realized tick
    ///      impact -- so forcing that field can no longer influence the bond by any value. The
    ///      helper would have compiled, run, and asserted nothing.
    ///
    ///      The storage-layout coverage it incidentally provided has NOT been dropped: the packed
    ///      `poolConfig` slot is pinned in `test/StorageLayout.t.sol`, which is where a layout
    ///      assertion belongs.

    /*//////////////////////////////////////////////////////////////
                      maxBondAmount ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice A bond above the trader's ceiling reverts -- and the ceiling is now denominated in
    ///         the COLLATERAL currency.
    ///
    /// @dev The ceiling cannot be predicted from the request any more, so the test measures the
    ///      bond on an identical swap first, reverts the state, and then re-runs it with a ceiling
    ///      one wei below what was measured. That is the only way to hit "exceeds by exactly one"
    ///      when the bond depends on execution.
    ///
    ///      Note the wrapping callback: this revert comes from `afterSwap`, because that is where
    ///      the bond is now known.
    function test_bondExceedsTraderMax_reverts() public {
        uint256 snapshot = vm.snapshotState();

        Measured memory m = _measuredSwap(BONDED_INPUT, true, _validHookData());

        uint256 bond = m.hookGained1;

        assertGt(bond, 1, "fixture bond too small to test a one-wei-under ceiling");

        vm.revertToState(snapshot);

        uint128 tooLow = uint128(bond - 1);

        vm.expectRevert(
            _wrappedIn(
                IHooks.afterSwap.selector, abi.encodeWithSelector(BondMeBro.BondExceedsTraderMax.selector, bond, tooLow)
            )
        );

        _swap(BONDED_INPUT, true, HookDataCodec.encode(TRADER, tooLow));
    }

    /// @notice `maxBondAmount` is inclusive: a ceiling exactly equal to the bond succeeds.
    ///
    /// @dev The `-1` case above and this `==` case are the two sides of one boundary, and a hook
    ///      using `>=` instead of `>` would pass the first and fail this one.
    function test_bondEqualToTraderMax_succeeds() public {
        uint256 snapshot = vm.snapshotState();

        Measured memory m = _measuredSwap(BONDED_INPUT, true, _validHookData());

        uint256 bond = m.hookGained1;

        assertGt(bond, 0, "fixture produced no bond");

        vm.revertToState(snapshot);

        uint256 hookBefore1 = currency1.balanceOf(address(hook));

        _swap(BONDED_INPUT, true, HookDataCodec.encode(TRADER, uint128(bond)));

        assertEq(currency1.balanceOf(address(hook)) - hookBefore1, bond, "a ceiling equal to the bond was rejected");
    }

    /// @notice The ceiling applies to the COLLATERAL, never to the variable leg.
    ///
    /// @dev This is the hookData v2 unit change, observed end to end. The collateral is a small
    ///      fraction of the leg, so a ceiling set just under the LEG would pass trivially if the
    ///      hook compared against the wrong quantity, and a ceiling set just under the COLLATERAL
    ///      must fail. Both are asserted, because only the pair distinguishes the two readings.
    function test_traderCeiling_appliesToCollateralNotToTheLeg() public {
        uint256 snapshot = vm.snapshotState();

        Measured memory m = _measuredSwap(BONDED_INPUT, true, _validHookData());

        uint256 bond = m.hookGained1;
        uint256 leg = m.traderGot1 + m.hookGained1;

        vm.revertToState(snapshot);

        assertLt(bond, leg, "fixture is degenerate: bond is not smaller than the leg");

        // A ceiling below the LEG but comfortably above the COLLATERAL must succeed.
        uint256 hookBefore1 = currency1.balanceOf(address(hook));

        _swap(BONDED_INPUT, true, HookDataCodec.encode(TRADER, uint128(leg - 1)));

        assertEq(
            currency1.balanceOf(address(hook)) - hookBefore1,
            bond,
            "a ceiling below the leg but above the collateral was rejected: the hook is checking the wrong quantity"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          hookData BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /// @notice A bonded swap must provide hookData.
    function test_bondedSwap_missingHookData_reverts() public {
        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.MissingHookData.selector)));

        _swap(BONDED_INPUT, true, "");
    }

    /// @notice A bonded swap rejects unsupported hookData versions.
    /// @dev The probe is a well-formed VERSION 1 payload, which is the case that actually
    ///      matters: v1 and v2 are byte-identical in shape and differ only in the unit of
    ///      `maxBondAmount`, so a stale integration replaying v1 would be expressing its
    ///      ceiling in the wrong token. It must be rejected before the pool executes, not
    ///      quietly accepted.
    function test_bondedSwap_wrongVersionHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(uint8(1), TRADER, GENEROUS_CEILING);

        assertEq(malformed.length, HookDataCodec.ENCODED_LENGTH, "v1 shares v2's length by design");

        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(1))));

        _swap(BONDED_INPUT, true, malformed);
    }

    /// @notice A bonded swap also rejects an unsupported FUTURE hookData version.
    function test_bondedSwap_futureVersionHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(uint8(3), TRADER, GENEROUS_CEILING);

        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(3))));

        _swap(BONDED_INPUT, true, malformed);
    }

    /// @notice A bonded swap rejects truncated hookData.
    function test_bondedSwap_truncatedHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(HookDataCodec.VERSION, TRADER);

        vm.expectRevert(
            _wrapped(
                abi.encodeWithSelector(
                    HookDataCodec.InvalidHookDataLength.selector, HookDataCodec.ENCODED_LENGTH, uint256(21)
                )
            )
        );

        _swap(BONDED_INPUT, true, malformed);
    }

    /// @notice A bonded swap rejects a zero refund recipient.
    function test_bondedSwap_zeroRecipientHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(HookDataCodec.VERSION, address(0), GENEROUS_CEILING);

        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.ZeroRefundRecipient.selector)));

        _swap(BONDED_INPUT, true, malformed);
    }

    /// @notice Invalid hookData must fail closed and move no tokens.
    function test_bondedSwap_missingHookData_movesNoTokens() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 swapperBefore = currency0.balanceOf(address(this));

        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.MissingHookData.selector)));

        _swap(BONDED_INPUT, true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "hook gained tokens on a reverted swap");

        assertEq(currency0.balanceOf(address(this)), swapperBefore, "swapper lost tokens on a reverted swap");
    }

    /*//////////////////////////////////////////////////////////////
                            UNBONDED PATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice A swap below the threshold proceeds normally without hookData or bond custody.
    function test_unbondedSwap_belowThreshold_emptyHookData_proceeds() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 swapperBefore1 = currency1.balanceOf(address(this));

        _swap(UNBONDED_INPUT, true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "unbonded swap moved tokens to the hook");

        assertGt(currency1.balanceOf(address(this)), swapperBefore1, "unbonded swap produced no output");

        // The accumulator confirms both swap callbacks executed. `beforeSwap` advances it
        // unconditionally, before any bonded/unbonded branch; `afterSwap` writes the post-swap
        // tick into it. This replaces the lastTickBefore/lastTickAfter diagnostics removed in T5.1.
        (int24 effectiveTick, uint32 lastUpdate,,) = hook.accumulator(id_);

        assertEq(lastUpdate, uint32(block.number), "beforeSwap did not advance the accumulator");

        assertLt(effectiveTick, 0, "afterSwap did not store the post-swap tick");
    }

    /// @notice A swap exactly equal to the threshold is bonded, and bonds in the OUTPUT currency.
    ///
    /// @dev Eligibility and sizing are now separate concerns and this test is about the first one.
    ///      The threshold is still an absolute amount of the INPUT currency -- Model L did not
    ///      change what makes a trade participate, only what it pays -- so the boundary is
    ///      unchanged even though the collateral moved to the other side of the swap.
    function test_swapExactlyAtThreshold_isBonded() public {
        Measured memory m = _measuredSwap(-int256(uint256(MIN_BONDED)), true, _validHookData());

        assertEq(m.traderPaid0, uint256(MIN_BONDED), "trader did not pay exactly the threshold amount");

        uint256 rawOutput = m.traderGot1 + m.hookGained1;

        assertEq(
            m.hookGained1,
            ModelLReference.collateralFor(rawOutput, m.tickBefore, m.tickAfter),
            "swap at the threshold was not bonded at the Model L rate"
        );

        assertGt(m.hookGained1, 0, "swap at the threshold posted no collateral");
    }

    /// @notice A swap one raw unit below the threshold remains unbonded and requires no hookData.
    function test_swapOneBelowThreshold_isUnbonded() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swap(-int256(uint256(MIN_BONDED) - 1), true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "swap below the threshold was bonded");
    }

    /// @notice A pool with bonding disabled never takes collateral.
    function test_unconfiguredPool_neverBonds() public {
        hook.setPoolConfig(key_, 0, 0, 0, 0, false);

        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swap(BONDED_INPUT, true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "disabled pool still bonded");
    }

    /// @notice An exact-output swap on a bonding-enabled pool must provide valid hookData.

    /// @dev Exact-output custody is tested in `BondCustodyExactOutput.t.sol`. This test only pins the important safety behaviour that exact-output can no longer bypass BondMeBro by omitting hookData.
    function test_exactOutput_onBondingPool_requiresHookData() public {
        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.MissingHookData.selector)));

        _swap(int256(BONDED_GROSS), true, "");
    }

    /// @notice Exact-output swaps on a pool with bonding disabled do not require hookData.
    function test_exactOutput_onDisabledPool_needsNoHookData() public {
        hook.setPoolConfig(key_, 0, 0, 0, 0, false);

        uint256 hookBefore0 = currency0.balanceOf(address(hook));

        uint256 hookBefore1 = currency1.balanceOf(address(hook));

        _swap(int256(BONDED_GROSS), true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore0, "disabled pool bonded currency0");

        assertEq(currency1.balanceOf(address(hook)), hookBefore1, "disabled pool bonded currency1");
    }

    /*//////////////////////////////////////////////////////////////
                      CONFIG & ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Enabling bonding requires BOTH direction thresholds.
    ///
    /// @dev A ZERO THRESHOLD IS NOT "DISABLE THIS DIRECTION". Eligibility is
    ///      `consumedInput >= threshold`, so a zero threshold bonds every positive swap in that
    ///      direction — the most aggressive setting the contract can hold, reachable by omitting a
    ///      field. Requiring both explicitly keeps the most punitive configuration from being the
    ///      easiest typo.
    ///
    ///      This replaced `test_setPoolConfig_rejectsPartialConfigurations` in P-L2-7. That test
    ///      guarded a four-field all-or-nothing rule over `bondBps` and `refundToleranceTicks`;
    ///      both fields are gone, so only the two thresholds remain to be complete about.
    function test_setPoolConfig_enablingRequiresBothThresholds() public {
        _expectIncomplete(0, MIN_BONDED_1);
        _expectIncomplete(MIN_BONDED, 0);
        _expectIncomplete(0, 0);
    }

    /// @dev Asserts one incomplete enable is rejected, reporting both thresholds back.
    function _expectIncomplete(uint128 min0, uint96 min1) internal {
        vm.expectRevert(abi.encodeWithSelector(BondMeBro.IncompleteBondingConfig.selector, min0, min1));

        hook.setPoolConfig(key_, min0, min1, 10_000, 10_000, true);
    }

    /// @notice Disabling ignores the thresholds passed alongside it, and clears what was stored.
    ///
    /// @dev Two claims. First, `false` is a complete instruction on its own — no sentinel value is
    ///      needed and none is checked, so disabling can never fail for an unrelated reason.
    ///      Second, disabling CLEARS the stored thresholds, so a pool that is later re-enabled
    ///      cannot silently inherit numbers set months earlier by someone else.
    function test_setPoolConfig_disablingClearsTheThresholds() public {
        // Enabled with real thresholds first, so there is something to clear.
        (uint128 before0, uint96 before1, bool enabledBefore,,) = hook.poolConfig(id_);

        assertTrue(enabledBefore, "fixture: the pool should start enabled");
        assertGt(before0, 0, "fixture: the pool should start with a currency0 threshold");
        assertGt(before1, 0, "fixture: the pool should start with a currency1 threshold");

        // Non-zero thresholds passed alongside `false` must be ignored, not stored.
        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 0, 0, false);

        (uint128 min0, uint96 min1, bool enabled,,) = hook.poolConfig(id_);

        assertFalse(enabled, "bonding was not disabled");
        assertEq(min0, 0, "currency0 threshold was not cleared on disable");
        assertEq(min1, 0, "currency1 threshold was not cleared on disable");
    }

    /// @notice A disabled pool takes no collateral, in either swap kind.
    function test_disabledPool_bondsNothing() public {
        hook.setPoolConfig(key_, 0, 0, 0, 0, false);

        uint256 hook0 = currency0.balanceOf(address(hook));
        uint256 hook1 = currency1.balanceOf(address(hook));

        _swap(BONDED_INPUT, true, "");
        _swap(int256(BONDED_GROSS), true, "");

        assertEq(currency0.balanceOf(address(hook)), hook0, "a disabled pool took currency0");
        assertEq(currency1.balanceOf(address(hook)), hook1, "a disabled pool took currency1");
    }

    /// @notice Deployment rejects a zero owner because ownership is immutable and nobody could configure pools afterward.
    function test_constructor_rejectsZeroOwner() public {
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(0)));

        vm.expectRevert(BondMeBro.ZeroOwner.selector);

        new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(0));
    }

    /// @notice Only the immutable owner can change pool bonding configuration.
    function test_setPoolConfig_onlyOwner() public {
        vm.prank(address(0xBAD));

        vm.expectRevert(BondMeBro.NotOwner.selector);

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);
    }

    /// @notice Swap callbacks cannot be called directly by arbitrary addresses.

    /// @dev BondMeBro's swap accounting is valid only inside PoolManager's unlock lifecycle, so `BaseHook` must reject direct callback calls.
    function test_directCallback_reverts() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: BONDED_INPUT, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.expectRevert(BaseHook.NotPoolManager.selector);

        hook.beforeSwap(address(this), key_, params, _validHookData());

        vm.expectRevert(BaseHook.NotPoolManager.selector);

        hook.afterSwap(address(this), key_, params, BalanceDeltaLibrary.ZERO_DELTA, _validHookData());
    }

    /*//////////////////////////////////////////////////////////////
                                 GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Isolated bonded swap used for callback gas measurement.
    function test_gas_bondedSwap() public {
        _swap(BONDED_INPUT, true, _validHookData());
    }

    /// @dev Isolated unbonded swap used for callback gas measurement.
    function test_gas_unbondedSwap() public {
        _swap(UNBONDED_INPUT, true, "");
    }
}
