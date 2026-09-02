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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockV4Router} from "@uniswap/v4-periphery/test/mocks/MockV4Router.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title BondCustodyExactOutputTest

/// @notice Integration tests for BondMeBro's exact-output custody path. Exact-output bonds are calculated from the actual input consumed by the pool and taken in `afterSwap`.

/// @dev Exact-output cannot use the exact-input custody model because `amountSpecified` represents the requested OUTPUT, while the actual INPUT required by the pool is only known after execution. BondMeBro therefore calculates the bond in `afterSwap` and adds it on top of the pool input so the requested output remains unchanged.

/// These tests derive `poolInput` from real token movements instead of hardcoding it. This proves the accounting relationship between the trader, PoolManager, and BondMeBro even if pool liquidity or execution price changes.

contract BondCustodyExactOutputTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;
    MockV4Router internal router;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;

    uint16 internal constant BOND_BPS = 25;

    /// @dev Settlement noise floor, in ticks. Displacement at or below this is never slashed.
    uint16 internal constant REFUND_TOL = 5;
    uint256 internal constant BPS = 10_000;

    /// @dev Large enough for the resulting gross input to exceed the bonding threshold.
    uint128 internal constant BONDED_OUTPUT = 1e16;

    /// @dev Small enough for the resulting gross input to remain below the bonding threshold.
    uint128 internal constant UNBONDED_OUTPUT = 1e13;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    /// @dev See the comment at the `modifyLiquidity` call in `setUp`.
    int128 internal constant POOL_LIQUIDITY = 1e19;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        // Deep enough that exact-output swaps fill without stopping at a price limit, SHALLOW
        // enough that they move the price by a measurable number of ticks.
        //
        // Reduced from 1e21 in P-L2-3/4 for the reason given at length in `BondCustody.t.sol`:
        // Model L prices collateral off the realized impact, so at 1e21 a 1e16 swap moved a single
        // tick and every sizing assertion here would have been testing a 1-bps rounding edge
        // rather than the rate curve.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);

        // MockV4Router inherits the real V4Router exact-output and
        // amountInMaximum logic. It only provides the test payment plumbing.
        router = new MockV4Router(manager);

        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);

        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Executes an exact-output swap through PoolSwapTest. This path does not provide the router-level `amountInMaximum` protection tested separately below.
    function _swapExactOut(uint128 amountOut, bool zeroForOne, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(uint256(amountOut)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Executes an exact-output swap through V4Router so `amountInMaximum` is enforced against the final trader input.
    function _routerExactOut(uint128 amountOut, uint128 amountInMaximum, bool zeroForOne, bytes memory hookData)
        internal
    {
        (Currency inputCurrency, Currency outputCurrency) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        Plan memory plan = Planner.init();

        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: key_,
                    zeroForOne: zeroForOne,
                    amountOut: amountOut,
                    amountInMaximum: amountInMaximum,
                    minHopPriceX36: 0,
                    hookData: hookData
                })
            )
        );

        router.executeActions(plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER));
    }

    function _validHookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /// @dev Hook errors are wrapped by Uniswap's hook-calling logic. Exact-output custody failures can occur in either `beforeSwap` validation or `afterSwap` custody, so the expected callback selector is supplied explicitly.
    function _wrapped(bytes4 callbackSelector, bytes memory innerReason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callbackSelector,
            innerReason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Recomputes the exact-output bond from what the pool actually consumed and how far it
    ///      actually moved the price.
    ///
    ///      THE FORMULA CHANGED SHAPE IN P-L2-3/4, not just its constant, so the old one is worth
    ///      stating next to the new one:
    ///
    ///          before : bond = poolInput * bondBps / (10_000 - bondBps)
    ///          now    : bond = poolInput * collateralBps / 10_000
    ///
    ///      The old expression was a GROSS SOLVE. Because the bond was charged on top of the pool
    ///      input, dividing by `10_000 - bondBps` made `bondBps` the rate on the trader's TOTAL
    ///      input, so exact-output and exact-input quoted the same headline rate on comparable
    ///      quantities. Model L abandons that framing: the rate applies to the VARIABLE LEG, which
    ///      for exact-output is the pool input itself, and it is derived from impact rather than
    ///      configured. There is nothing left to solve for, so the closed form is a plain
    ///      proportion.
    ///
    ///      The bond is still charged ON TOP of the pool input -- that part is unchanged, and it
    ///      is what keeps the requested output exact.
    function _expectedBond(uint256 poolInput, int24 tickBefore, int24 tickAfter) internal pure returns (uint256) {
        return ModelLReference.collateralFor(poolInput, tickBefore, tickAfter);
    }

    /// @dev Balances and tick captured before a swap.
    struct Snapshot {
        uint256 traderIn;
        uint256 traderOut;
        uint256 hookIn;
        uint256 managerIn;
        int24 tick;
    }

    /// @dev The pool tick, for capturing either side of a swap.
    function _tick() internal view returns (int24 tick) {
        // slither-disable-next-line unused-return
        (, tick,,) = manager.getSlot0(id_);
    }

    /*//////////////////////////////////////////////////////////////
                        CORE EXACT-OUTPUT CUSTODY
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies exact-output custody for a zeroForOne swap.

    /// @dev The requested output must remain exact, the hook must receive the calculated bond in the input currency, and total trader input must equal:
    ///
    /// `grossInput = poolInput + bond`
    function test_exactOutput_zeroForOne_exactCustodyAccounting() public {
        uint256 traderIn0 = currency0.balanceOf(address(this));

        uint256 traderIn1 = currency1.balanceOf(address(this));

        uint256 hookIn0 = currency0.balanceOf(address(hook));

        uint256 managerIn0 = currency0.balanceOf(address(manager));

        int24 tickBefore = _tick();

        _swapExactOut(BONDED_OUTPUT, true, _validHookData());

        int24 tickAfter = _tick();

        uint256 traderSpent = traderIn0 - currency0.balanceOf(address(this));

        uint256 traderReceived = currency1.balanceOf(address(this)) - traderIn1;

        uint256 hookGained = currency0.balanceOf(address(hook)) - hookIn0;

        uint256 poolInput = currency0.balanceOf(address(manager)) - managerIn0;

        // Exact-output means the trader receives exactly the requested amount.
        assertEq(traderReceived, BONDED_OUTPUT, "trader did not receive the exact requested output");

        assertGt(poolInput, 0, "pool consumed no input");

        uint256 expectedBond = _expectedBond(poolInput, tickBefore, tickAfter);

        assertGt(expectedBond, 0, "test is not exercising a bonded swap");

        // Hook receives exactly the calculated bond in the input currency. For exact-output the
        // INPUT is the variable leg, so unlike exact-input the collateral currency is unchanged
        // by this migration -- only its size is.
        assertEq(hookGained, expectedBond, "hook did not take exactly the computed bond");

        // Exact-output still adds the bond on top of pool input, which is what keeps the
        // requested output exactly as requested.
        assertEq(traderSpent, poolInput + hookGained, "gross input is not poolInput + bond");

        assertGt(traderSpent, poolInput, "bond was not charged on top of pool input");

        // The rate now applies to the VARIABLE LEG (the pool input), not to the trader's gross
        // input. The old gross-solve made those two framings coincide; Model L does not, so the
        // relation is asserted against the leg and the difference from the gross framing is
        // pinned rather than left ambiguous.
        assertEq(
            hookGained,
            (poolInput * ModelLReference.collateralBps(tickBefore, tickAfter)) / BPS,
            "bond is not collateralBps of the POOL INPUT"
        );

        assertLt(
            hookGained,
            (traderSpent * ModelLReference.collateralBps(tickBefore, tickAfter)) / BPS + 1,
            "bond is being computed off the gross input rather than the variable leg"
        );

        // No residual PoolManager claims remain after the accounting cycle.
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds currency0 claims");

        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook holds currency1 claims");
    }

    /// @notice Verifies the opposite swap direction: oneForZero exact-output custody must take the bond in currency1.
    function test_exactOutput_oneForZero_bondsInCurrency1() public {
        uint256 traderIn1 = currency1.balanceOf(address(this));

        uint256 traderIn0 = currency0.balanceOf(address(this));

        uint256 hookIn0 = currency0.balanceOf(address(hook));

        uint256 hookIn1 = currency1.balanceOf(address(hook));

        uint256 managerIn1 = currency1.balanceOf(address(manager));

        int24 tickBefore = _tick();

        _swapExactOut(BONDED_OUTPUT, false, _validHookData());

        int24 tickAfter = _tick();

        uint256 traderSpent = traderIn1 - currency1.balanceOf(address(this));

        uint256 traderReceived = currency0.balanceOf(address(this)) - traderIn0;

        uint256 hookGained = currency1.balanceOf(address(hook)) - hookIn1;

        uint256 poolInput = currency1.balanceOf(address(manager)) - managerIn1;

        assertEq(traderReceived, BONDED_OUTPUT, "trader did not receive the exact requested output");

        assertEq(hookGained, _expectedBond(poolInput, tickBefore, tickAfter), "bond not taken in currency1");

        assertGt(hookGained, 0, "test is not exercising a bonded swap");

        // The currency predicate, stated independently. Exact-OUTPUT oneForZero keeps collateral
        // in currency1 -- the same currency as before the migration, but for a different reason:
        // it is the input, and for exact-output the input is the variable leg.
        assertFalse(
            ModelLReference.collateralIsCurrency0({zeroForOne: false, exactInput: false}),
            "reference disagrees: exact-output oneForZero must bond in currency1"
        );

        assertEq(traderSpent, poolInput + hookGained, "gross input is not poolInput + bond");

        // The output currency must not be taken as collateral.
        assertEq(currency0.balanceOf(address(hook)), hookIn0, "currency0 moved on a oneForZero swap");
    }

    /*//////////////////////////////////////////////////////////////
                              THRESHOLD
    //////////////////////////////////////////////////////////////*/

    /// @notice An exact-output swap below the bonding threshold succeeds without taking collateral.

    /// @dev Valid hookData is still required on a bonding-enabled pool because the actual input, and therefore whether the threshold is crossed, is not known until after execution.
    function test_exactOutput_belowThreshold_succeedsWithZeroBond() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 traderIn1 = currency1.balanceOf(address(this));

        _swapExactOut(UNBONDED_OUTPUT, true, _validHookData());

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "sub-threshold swap took a bond");

        assertEq(
            currency1.balanceOf(address(this)) - traderIn1, UNBONDED_OUTPUT, "sub-threshold swap changed the output"
        );
    }

    /// @notice Verifies that exact-output threshold checks use gross INPUT rather than the output-denominated `amountSpecified`.
    function test_exactOutput_thresholdComparesGrossInput_notAmountSpecified() public {
        // Probe the actual gross input, rewind, then set the threshold one unit above it.
        uint256 managerIn0 = currency0.balanceOf(address(manager));

        uint256 snap = vm.snapshotState();

        _swapExactOut(BONDED_OUTPUT, true, _validHookData());

        uint256 grossProbe = (currency0.balanceOf(address(manager)) - managerIn0) + currency0.balanceOf(address(hook));

        vm.revertToState(snap);

        hook.setPoolConfig(key_, uint128(grossProbe + 1), uint96(grossProbe + 1), BOND_BPS, REFUND_TOL);

        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swapExactOut(BONDED_OUTPUT, true, _validHookData());

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "threshold was compared against the wrong quantity");
    }

    /// @notice A swap too small to move a tick is UNBONDED, not reverted.
    ///
    /// @dev This replaces the old `test_exactOutput_bondRoundingToZero_reverts`, which expected a
    ///      `BondRoundsToZero` revert for a 100-unit exact-output swap. That error no longer
    ///      exists, and more importantly the behaviour it guarded has split in two.
    ///
    ///      Under the old model any bonded-but-tiny swap produced a zero bond and had to revert.
    ///      Under Model L the two causes are distinguished:
    ///
    ///        the price did not move a whole tick  -> the swap is UNBONDED (this test).
    ///                                                There is no LP-risk signal to price, so no
    ///                                                obligation is created and nothing reverts.
    ///
    ///        the price moved but the leg is tiny  -> INV-NOOP-VL rejects it (the next test).
    ///
    ///      Collapsing these would be wrong in the expensive direction: reverting every sub-tick
    ///      swap would make the hook fail closed on ordinary dust trades that pose no risk at all.
    function test_exactOutput_subTickSwap_isUnbondedNotReverted() public {
        // NUDGE THE POOL OFF THE TICK BOUNDARY FIRST, and this is not incidental setup.
        //
        // The fixture initializes at exactly tick 0. Sitting on a boundary, ANY downward price
        // movement -- even one of a few wei -- lands in tick -1, so the impact is 1 tick and the
        // rate is 1 bps no matter how small the trade. A "sub-tick" swap is therefore impossible
        // at a boundary, and without this warm-up the dust swap below reverts on INV-NOOP-VL
        // rather than passing unbonded.
        //
        // That edge is real, not an artifact: on a pool configured with a threshold of 1, a dust
        // trade executed while the price sits exactly on a boundary WILL revert, because it owes
        // a bond that truncates to zero. It is unreachable in any realistic deployment, where
        // `minBondedAmount` is many orders of magnitude above dust and such a trade is unbonded
        // long before it reaches the rate. `test_exactOutput_bondTruncatingToZero_reverts` covers
        // the case deliberately; here it is only in the way.
        _swapExactOut(1e16, true, _validHookData());

        hook.setPoolConfig(key_, 1, 1, BOND_BPS, REFUND_TOL);

        uint256 hookBefore = currency0.balanceOf(address(hook));
        uint256 traderBefore1 = currency1.balanceOf(address(this));

        int24 tickBefore = _tick();

        _swapExactOut(100, true, _validHookData());

        assertEq(ModelLReference.collateralBps(tickBefore, _tick()), 0, "fixture DID move a tick; test is misaimed");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "a sub-tick swap took collateral");

        assertEq(currency1.balanceOf(address(this)) - traderBefore1, 100, "the swap did not deliver its output");
    }

    /// @notice INV-NOOP-VL on the exact-output path: a moved tick with a leg too small to charge
    ///         must revert rather than finalize a zero-collateral bond.
    ///
    /// @dev Mirrors the exact-input case in `BondCustody.t.sol`, and needs the same construction:
    ///      a pool thin enough that a few hundred units still cross a tick. On the fixture's
    ///      liquidity no amount small enough to truncate could ever move the price, so the case
    ///      would be unreachable and the test would silently prove nothing.
    ///
    ///      The search runs with bonding DISABLED so probe swaps cannot revert with the very error
    ///      being provoked, then the state is rewound and the chosen amount replayed with bonding
    ///      on. Rewinding restores the price exactly, so the replay reproduces the same leg.
    function test_exactOutput_bondTruncatingToZero_reverts() public {
        (PoolKey memory thinKey, PoolId thinId) =
            initPool(currency0, currency1, IHooks(address(hook)), 500, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            thinKey,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 4e6, salt: bytes32(0)}),
            ""
        );

        uint256 baseline = vm.snapshotState();

        uint256 chosenOut;
        uint256 observedLeg;

        for (uint256 amountOut = 100; amountOut <= 9_000; amountOut += 100) {
            uint256 snapshot = vm.snapshotState();

            // slither-disable-next-line unused-return
            (, int24 before_,,) = manager.getSlot0(thinId);

            uint256 managerBefore0 = currency0.balanceOf(address(manager));

            swapRouter.swap(
                thinKey,
                SwapParams({
                    zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            // slither-disable-next-line unused-return
            (, int24 after_,,) = manager.getSlot0(thinId);

            // For exact-output the variable leg is the POOL INPUT.
            uint256 leg = currency0.balanceOf(address(manager)) - managerBefore0;

            bool movedATick = ModelLReference.collateralBps(before_, after_) > 0;

            bool truncatesToZero = leg > 0 && ModelLReference.collateralFor(leg, before_, after_) == 0;

            vm.revertToState(snapshot);

            if (movedATick && truncatesToZero) {
                chosenOut = amountOut;
                observedLeg = leg;
                break;
            }
        }

        assertGt(chosenOut, 0, "could not construct a moved-a-tick-but-truncates-to-zero exact-output swap");

        vm.revertToState(baseline);

        hook.setPoolConfig(thinKey, 1, 1, BOND_BPS, REFUND_TOL);

        vm.expectRevert(
            _wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BondMeBro.BondViolatesNoOpVLBound.selector, uint256(0), observedLeg)
            )
        );

        swapRouter.swap(
            thinKey,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(chosenOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _validHookData()
        );
    }

    /*//////////////////////////////////////////////////////////////
                         hookData VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Missing hookData is rejected in `beforeSwap` before the pool executes.
    function test_exactOutput_missingHookData_reverts() public {
        vm.expectRevert(
            _wrapped(IHooks.beforeSwap.selector, abi.encodeWithSelector(HookDataCodec.MissingHookData.selector))
        );

        _swapExactOut(BONDED_OUTPUT, true, "");
    }

    /// @notice Truncated exact-output hookData is rejected before execution.
    function test_exactOutput_malformedHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(HookDataCodec.VERSION, TRADER);

        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(
                    HookDataCodec.InvalidHookDataLength.selector, HookDataCodec.ENCODED_LENGTH, uint256(21)
                )
            )
        );

        _swapExactOut(BONDED_OUTPUT, true, malformed);
    }

    /// @notice Unsupported hookData versions are rejected before execution.
    /// @dev Probed with a well-formed VERSION 1 payload — see the note on the exact-input
    ///      equivalent in `BondCustody.t.sol`. v1 and v2 differ only in the unit of
    ///      `maxBondAmount`, so only the version byte can separate them.
    function test_exactOutput_unsupportedHookDataVersion_reverts() public {
        bytes memory wrongVersion = abi.encodePacked(uint8(1), TRADER, GENEROUS_CEILING);

        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(1))
            )
        );

        _swapExactOut(BONDED_OUTPUT, true, wrongVersion);
    }

    /// @notice Even a sub-threshold exact-output swap requires hookData on a bonding-enabled pool.
    function test_exactOutput_belowThreshold_stillRequiresHookData() public {
        vm.expectRevert(
            _wrapped(IHooks.beforeSwap.selector, abi.encodeWithSelector(HookDataCodec.MissingHookData.selector))
        );

        _swapExactOut(UNBONDED_OUTPUT, true, "");
    }

    /// @notice A rejected exact-output swap must move no tokens.
    function test_exactOutput_rejectedSwap_movesNoTokens() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 traderBefore = currency0.balanceOf(address(this));

        uint256 managerBefore = currency0.balanceOf(address(manager));

        vm.expectRevert(
            _wrapped(IHooks.beforeSwap.selector, abi.encodeWithSelector(HookDataCodec.MissingHookData.selector))
        );

        _swapExactOut(BONDED_OUTPUT, true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "hook gained tokens on a reverted swap");

        assertEq(currency0.balanceOf(address(this)), traderBefore, "trader lost tokens on a reverted swap");

        assertEq(currency0.balanceOf(address(manager)), managerBefore, "pool moved on a reverted swap");
    }

    /*//////////////////////////////////////////////////////////////
                       maxBondAmount ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Executes the swap once to measure the exact bond, then restores state so boundary tests can use the measured amount precisely.
    function _probeBond(uint128 amountOut, bool zeroForOne) internal returns (uint256 bond) {
        uint256 snap = vm.snapshotState();

        Currency inputCurrency = zeroForOne ? currency0 : currency1;

        uint256 hookBefore = inputCurrency.balanceOf(address(hook));

        _swapExactOut(amountOut, zeroForOne, _validHookData());

        bond = inputCurrency.balanceOf(address(hook)) - hookBefore;

        vm.revertToState(snap);
    }

    /// @notice A bond below the trader-provided `maxBondAmount` succeeds.
    function test_exactOutput_bondBelowMaxBondAmount_succeeds() public {
        uint256 bond = _probeBond(BONDED_OUTPUT, true);

        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swapExactOut(BONDED_OUTPUT, true, HookDataCodec.encode(TRADER, uint128(bond + 1)));

        assertEq(currency0.balanceOf(address(hook)) - hookBefore, bond, "swap under the ceiling did not bond");
    }

    /// @notice A bond exactly equal to `maxBondAmount` succeeds.
    function test_exactOutput_bondEqualToMaxBondAmount_succeeds() public {
        uint256 bond = _probeBond(BONDED_OUTPUT, true);

        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swapExactOut(BONDED_OUTPUT, true, HookDataCodec.encode(TRADER, uint128(bond)));

        assertEq(currency0.balanceOf(address(hook)) - hookBefore, bond, "swap exactly at the ceiling did not bond");
    }

    /// @notice A bond above `maxBondAmount` reverts the entire transaction.

    /// @dev The failure occurs in `afterSwap`, after the pool calculation has run, but EVM atomicity must unwind the pool swap, trader balances, and hook custody together.
    function test_exactOutput_bondAboveMaxBondAmount_revertsWholeSwap() public {
        uint256 bond = _probeBond(BONDED_OUTPUT, true);

        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 traderBefore = currency0.balanceOf(address(this));

        uint256 managerBefore = currency0.balanceOf(address(manager));

        uint256 traderOutBefore = currency1.balanceOf(address(this));

        vm.expectRevert(
            _wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BondMeBro.BondExceedsTraderMax.selector, bond, uint128(bond - 1))
            )
        );

        _swapExactOut(BONDED_OUTPUT, true, HookDataCodec.encode(TRADER, uint128(bond - 1)));

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "hook kept a bond on a reverted swap");

        assertEq(currency0.balanceOf(address(this)), traderBefore, "trader paid on a reverted swap");

        assertEq(currency0.balanceOf(address(manager)), managerBefore, "pool state changed on a reverted swap");

        assertEq(currency1.balanceOf(address(this)), traderOutBefore, "trader received output on a reverted swap");
    }

    /*//////////////////////////////////////////////////////////////
                         ROUTER MAX INPUT
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that V4Router's `amountInMaximum` includes both pool input and BondMeBro collateral.

    /// @dev The successful exact boundary and the failing one-wei-lower boundary together prove that the router checks:
    ///
    /// `requiredInput = poolInput + bond`
    function test_router_maxInput_includesBond() public {
        uint256 snap = vm.snapshotState();

        uint256 traderProbe = currency0.balanceOf(address(this));

        uint256 managerProbe = currency0.balanceOf(address(manager));

        uint256 hookProbe = currency0.balanceOf(address(hook));

        _routerExactOut(BONDED_OUTPUT, GENEROUS_CEILING, true, _validHookData());

        uint256 requiredIn = traderProbe - currency0.balanceOf(address(this));

        uint256 poolInput = currency0.balanceOf(address(manager)) - managerProbe;

        uint256 bond = currency0.balanceOf(address(hook)) - hookProbe;

        vm.revertToState(snap);

        assertGt(bond, 0, "test is not exercising a bonded swap");

        assertEq(requiredIn, poolInput + bond, "router input is not poolInput + bond");

        uint256 traderBefore = currency0.balanceOf(address(this));

        // Exactly the full bond-inclusive input is accepted.
        _routerExactOut(BONDED_OUTPUT, uint128(requiredIn), true, _validHookData());

        assertEq(traderBefore - currency0.balanceOf(address(this)), requiredIn, "router charged an unexpected amount");
    }

    /// @notice A router input ceiling one raw unit below `poolInput + bond` must revert.
    function test_router_maxInput_belowPoolInputPlusBond_reverts() public {
        uint256 snap = vm.snapshotState();

        uint256 traderProbe = currency0.balanceOf(address(this));

        _routerExactOut(BONDED_OUTPUT, GENEROUS_CEILING, true, _validHookData());

        uint256 requiredIn = traderProbe - currency0.balanceOf(address(this));

        vm.revertToState(snap);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, uint256(requiredIn - 1), requiredIn)
        );

        _routerExactOut(BONDED_OUTPUT, uint128(requiredIn - 1), true, _validHookData());
    }

    /// @notice A router input ceiling equal only to the bond-free pool input must fail because it does not include BondMeBro collateral.
    function test_router_maxInput_setToPoolInputAlone_reverts() public {
        uint256 snap = vm.snapshotState();

        uint256 managerProbe = currency0.balanceOf(address(manager));

        uint256 traderProbe = currency0.balanceOf(address(this));

        _routerExactOut(BONDED_OUTPUT, GENEROUS_CEILING, true, _validHookData());

        uint256 poolInput = currency0.balanceOf(address(manager)) - managerProbe;

        uint256 requiredIn = traderProbe - currency0.balanceOf(address(this));

        vm.revertToState(snap);

        assertGt(requiredIn, poolInput, "bond is not increasing the router-visible input");

        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, poolInput, requiredIn));

        _routerExactOut(BONDED_OUTPUT, uint128(poolInput), true, _validHookData());
    }

    /// @notice The V4Router path still delivers exactly the requested output.
    function test_router_exactOutput_deliversExactOutput() public {
        uint256 traderOutBefore = currency1.balanceOf(address(this));

        _routerExactOut(BONDED_OUTPUT, GENEROUS_CEILING, true, _validHookData());

        assertEq(
            currency1.balanceOf(address(this)) - traderOutBefore, BONDED_OUTPUT, "router path lost the exact output"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          ZERO INPUT EDGE CASE
    //////////////////////////////////////////////////////////////*/

    /// @notice An exact-output swap against a bonding-enabled pool with no liquidity consumes no input and therefore takes no bond.

    /// @dev `_afterSwap` checks `inputDelta >= 0` before negating the signed value. This avoids interpreting a zero or positive delta as a huge unsigned input amount and passing it into the bond formula.
    function test_exactOutput_poolWithNoLiquidity_bondsNothing() public {
        PoolKey memory emptyKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 10_000, tickSpacing: 200, hooks: IHooks(address(hook))
        });

        manager.initialize(emptyKey, TickMath.getSqrtPriceAtTick(0));

        hook.setPoolConfig(emptyKey, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);

        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 traderBefore = currency0.balanceOf(address(this));

        swapRouter.swap(
            emptyKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(uint256(BONDED_OUTPUT)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _validHookData()
        );

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "empty pool produced a bond");

        assertEq(currency0.balanceOf(address(this)), traderBefore, "empty pool charged the trader");
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS / HOSTILE POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice An arbitrary user may initialize a pool pointing at BondMeBro, but an unconfigured pool cannot take bonds because only the owner can configure bonding parameters.
    function test_hostilePool_cannotBond() public {
        address attacker = address(0xBAD);

        PoolKey memory hostileKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });

        vm.prank(attacker);

        manager.initialize(hostileKey, TickMath.getSqrtPriceAtTick(0));

        vm.prank(attacker);

        vm.expectRevert(BondMeBro.NotOwner.selector);

        hook.setPoolConfig(hostileKey, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);

        (uint128 minBonded0, uint96 minBonded1, uint16 bondBps,) = hook.poolConfig(hostileKey.toId());

        assertEq(minBonded0, 0, "hostile pool has a currency0 threshold");

        assertEq(minBonded1, 0, "hostile pool has a currency1 threshold");

        assertEq(bondBps, 0, "hostile pool has a bond rate");
    }

    /// @notice The exact-output `afterSwap` callback cannot be called directly by arbitrary addresses.
    function test_directAfterSwapCallback_reverts() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(uint256(BONDED_OUTPUT)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.expectRevert(BaseHook.NotPoolManager.selector);

        hook.afterSwap(address(this), key_, params, BalanceDeltaLibrary.ZERO_DELTA, _validHookData());
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzzes exact-output custody across swap sizes and both directions.

    /// @dev Every successful bonded swap must deliver the exact requested output, take the expected input-currency bond, satisfy `grossInput = poolInput + bond`, and leave no PoolManager claim balance.
    function testFuzz_exactOutput_accountingHolds(uint96 rawAmountOut, bool zeroForOne) public {
        // Upper bound lowered from 1e19 to 1e18 in P-L2-3/4, because `POOL_LIQUIDITY` came down to
        // 1e19 in the same stage. Requesting an output of the same order as the pool's liquidity
        // makes the swap stop at its price limit, so the assertion that fails is "trader did not
        // receive the exact requested output" -- a partial fill, not an accounting defect. 1e18
        // still spans roughly 2% to 20% price impact, which crosses the 397-tick cap and so
        // exercises both sides of the rate curve.
        uint128 amountOut = uint128(bound(uint256(rawAmountOut), 1e16, 1e18));

        (Currency inputCurrency, Currency outputCurrency) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        // Grouped into a struct rather than held as separate locals: adding the two tick readings
        // that Model L needs pushes this frame past the EVM stack limit under the project's
        // non-viaIR settings.
        Snapshot memory before = Snapshot({
            traderIn: inputCurrency.balanceOf(address(this)),
            traderOut: outputCurrency.balanceOf(address(this)),
            hookIn: inputCurrency.balanceOf(address(hook)),
            managerIn: inputCurrency.balanceOf(address(manager)),
            tick: _tick()
        });

        _swapExactOut(amountOut, zeroForOne, _validHookData());

        int24 tickAfter = _tick();

        uint256 bond = inputCurrency.balanceOf(address(hook)) - before.hookIn;

        uint256 poolInput = inputCurrency.balanceOf(address(manager)) - before.managerIn;

        assertEq(
            outputCurrency.balanceOf(address(this)) - before.traderOut,
            amountOut,
            "trader did not receive the exact requested output"
        );

        assertEq(
            bond,
            _expectedBond(poolInput, before.tick, tickAfter),
            "bond does not match the Model L rate on the realized pool input"
        );

        assertGt(bond, 0, "a bonded swap took no bond");

        assertEq(
            before.traderIn - inputCurrency.balanceOf(address(this)),
            poolInput + bond,
            "gross input is not poolInput + bond"
        );

        assertEq(manager.balanceOf(address(hook), inputCurrency.toId()), 0, "hook left an unresolved claim");

        // INV-NOOP-VL, observed on every fuzz draw: the collateral sits strictly inside the leg.
        assertLt(bond, poolInput, "INV-NOOP-VL: bond reached or exceeded the variable leg");

        // And the cap holds end to end, whatever impact the draw happened to produce.
        assertLe(
            bond,
            (poolInput * ModelLReference.MAX_BOND_BPS) / BPS,
            "INV-L2-2: realized bond exceeded the 1% cap on the variable leg"
        );
    }

    /// @notice Fuzzes `maxBondAmount` enforcement across sizes and both swap directions.

    /// @dev A ceiling exactly one raw unit below the required bond must always revert.
    function testFuzz_exactOutput_maxBondAmountAlwaysEnforced(uint96 rawAmountOut, bool zeroForOne) public {
        uint128 amountOut = uint128(bound(uint256(rawAmountOut), 1e16, 1e19));

        uint256 bond = _probeBond(amountOut, zeroForOne);

        vm.assume(bond > 0);

        vm.expectRevert(
            _wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BondMeBro.BondExceedsTraderMax.selector, bond, uint128(bond - 1))
            )
        );

        _swapExactOut(amountOut, zeroForOne, HookDataCodec.encode(TRADER, uint128(bond - 1)));
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Isolated bonded exact-output swap used for callback gas measurement.
    function test_gas_exactOutputBonded() public {
        _swapExactOut(BONDED_OUTPUT, true, _validHookData());
    }

    /// @dev Isolated unbonded exact-output swap used for callback gas measurement.
    function test_gas_exactOutputUnbonded() public {
        _swapExactOut(UNBONDED_OUTPUT, true, _validHookData());
    }
}
