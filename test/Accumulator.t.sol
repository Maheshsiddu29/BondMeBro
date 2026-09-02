// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @notice T5.1 Stage 1 — the per-pool tick accumulator that replaced the `lastTickBefore` /
///         `lastTickAfter` diagnostics.
///
/// @dev DEDICATED NON-ZERO-TICK FIXTURE, ON PURPOSE. Every other suite starts its pool at tick 0,
///      which is right for those suites — it keeps both swap directions symmetric so threshold
///      selection is the only variable. But it cannot detect the bug this file exists to catch:
///      at tick 0, an accumulator that wrongly initialised from Solidity's default `0` is
///      indistinguishable from one that correctly read the pool's real tick. Both look identical.
///
///      This pool starts at a large non-zero tick so the two are distinguishable. The T3C tick-0
///      fixtures are deliberately left alone.
contract AccumulatorTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal id_;

    /// @dev A tick far from zero, and a multiple of the fee-3000 tick spacing of 60.
    int24 internal constant INIT_TICK = 191_940;

    address internal constant TRADER = address(0xB0B);
    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;

    /// @dev Settlement noise floor, in ticks. Displacement at or below this is never slashed.
    uint16 internal constant REFUND_TOL = 5;
    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));
        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));
        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(INIT_TICK)
        );

        // Liquidity spanning the starting tick so swaps in both directions fill.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: INIT_TICK - 60_000,
                tickUpper: INIT_TICK + 60_000,
                liquidityDelta: 1e21,
                salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);
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

    function _validHookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    function _acc() internal view returns (int24 lastTick, uint32 lastUpdate, int56 tickCumulative) {
        return hook.accumulator(id_);
    }

    function _poolTick() internal view returns (int24 tick) {
        // slither-disable-next-line unused-return
        (, tick,,) = manager.getSlot0(id_);
    }

    /*//////////////////////////////////////////////////////////////
                        FIRST-TOUCH INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The accumulator seeds from the pool's REAL starting tick, not Solidity's default 0.
    ///
    /// @dev The whole point of the non-zero fixture. If `_afterInitialize` had seeded from a
    ///      default-initialised variable, `lastTick` would read 0 here and every observation window
    ///      opened before the first swap would integrate a price the pool never had.
    function test_firstTouch_seedsFromRealTick_notDefaultZero() public view {
        (int24 lastTick, uint32 lastUpdate, int56 tickCumulative) = _acc();

        assertEq(lastTick, INIT_TICK, "accumulator did not seed from the real initialization tick");
        assertTrue(lastTick != 0, "fixture is not exercising a non-zero tick");
        assertEq(lastUpdate, uint32(block.number), "accumulator was not stamped at the init block");

        // And no history was invented for blocks before the pool existed.
        assertEq(tickCumulative, int56(0), "accumulator credited time before initialization");
    }

    /// @notice No historical cumulative time is credited before initialization, even if the chain
    ///         is already thousands of blocks old.
    /// @dev `update`'s first-touch branch returns before crediting anything. Had it credited
    ///      `lastTick * block.number`, this pool would open with an enormous bogus cumulative.
    function test_firstTouch_creditsNoTimeBeforeInitialization() public {
        vm.roll(block.number + 5_000);

        // A fresh pool on the same hook, initialised far into the chain's life.
        PoolKey memory freshKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        manager.initialize(freshKey, TickMath.getSqrtPriceAtTick(INIT_TICK));

        (int24 lastTick, uint32 lastUpdate, int56 tickCumulative) = hook.accumulator(freshKey.toId());

        assertEq(lastTick, INIT_TICK, "fresh pool did not seed from its real tick");
        assertEq(lastUpdate, uint32(block.number), "fresh pool not stamped at its init block");
        assertEq(tickCumulative, int56(0), "fresh pool invented history before it existed");
    }

    /*//////////////////////////////////////////////////////////////
                              ADVANCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice `beforeSwap` credits elapsed blocks at the OLD tick, and `afterSwap` then moves the
    ///         effective tick without crediting anything twice.
    ///
    /// @dev This is the two-phase update ADR-0003 § 13.1 predicts falls out of the existing
    ///      library. Crediting at the new tick would apply the swap's own price impact backwards
    ///      over blocks in which it had not yet happened.
    function test_advance_creditsOldTick_thenMovesEffectiveTick() public {
        (int24 tickAtInit,, int56 cumAtInit) = _acc();
        assertEq(cumAtInit, int56(0));

        uint256 elapsed = 10;
        vm.roll(block.number + elapsed);

        _swap(-1e16, true, _validHookData());

        (int24 lastTick, uint32 lastUpdate, int56 cumulative) = _acc();

        // Elapsed time was credited at the tick live across it — the pre-swap tick.
        assertEq(
            cumulative,
            int56(tickAtInit) * int56(uint56(elapsed)),
            "elapsed blocks were not credited at the pre-swap tick"
        );

        // And the effective tick is now the post-swap tick, which zeroForOne moved down.
        assertEq(lastUpdate, uint32(block.number), "accumulator not advanced to the current block");
        assertEq(lastTick, _poolTick(), "effective tick does not match the pool's post-swap tick");
        assertLt(lastTick, tickAtInit, "zeroForOne should have moved the tick down");
    }

    /// @notice `afterSwap` must not double-credit: it runs in the same block `beforeSwap` already
    ///         advanced to, so its elapsed interval is zero.
    /// @dev Proven by comparing against a hand-computed cumulative. If `afterSwap` credited a
    ///      second interval, or credited at the new tick, this differs.
    function test_afterSwap_doesNotDoubleCreditTime() public {
        (int24 tickAtInit,,) = _acc();

        vm.roll(block.number + 7);
        _swap(-1e16, true, _validHookData());
        (,, int56 afterFirst) = _acc();
        assertEq(afterFirst, int56(tickAtInit) * int56(uint56(7)), "first swap credited the wrong amount");

        // A second swap in the SAME block must credit nothing further.
        _swap(-1e16, true, _validHookData());
        (,, int56 afterSecond) = _acc();
        assertEq(afterSecond, afterFirst, "a same-block swap credited time that did not elapse");
    }

    /*//////////////////////////////////////////////////////////////
        EVERY SWAP ADVANCES — the scan bound's correctness precondition
    //////////////////////////////////////////////////////////////*/

    /// @notice UNBONDED exact-input swaps must still advance the accumulator.
    ///
    /// @dev ADR-0003 § 3.2 makes this a CORRECTNESS precondition, not merely an accuracy one: the
    ///      bounded maturity scan is sound only because a bond cannot open without a swap and a
    ///      swap cannot happen without advancing `lastUpdate`. An early return that skipped the
    ///      advance on the cheap path would silently void that proof.
    function test_unbondedExactInput_stillAdvancesAccumulator() public {
        _assertSwapAdvances(-1e13, true, ""); // below MIN_BONDED, no hookData needed
    }

    function test_unbondedExactInput_oneForZero_stillAdvancesAccumulator() public {
        _assertSwapAdvances(-1e13, false, "");
    }

    /// @notice UNBONDED exact-output swaps must also advance it.
    function test_unbondedExactOutput_stillAdvancesAccumulator() public {
        _assertSwapAdvances(1e13, true, _validHookData());
    }

    function test_unbondedExactOutput_oneForZero_stillAdvancesAccumulator() public {
        _assertSwapAdvances(1e13, false, _validHookData());
    }

    /// @notice Bonded swaps advance it too, in both directions and both swap kinds.
    function test_bondedExactInput_advancesAccumulator() public {
        _assertSwapAdvances(-1e16, true, _validHookData());
    }

    function test_bondedExactInput_oneForZero_advancesAccumulator() public {
        _assertSwapAdvances(-1e16, false, _validHookData());
    }

    function test_bondedExactOutput_advancesAccumulator() public {
        _assertSwapAdvances(1e16, true, _validHookData());
    }

    function test_bondedExactOutput_oneForZero_advancesAccumulator() public {
        _assertSwapAdvances(1e16, false, _validHookData());
    }

    /// @notice An unconfigured pool — which can never bond — must still advance its accumulator.
    /// @dev The cheapest path in the contract, and the one most likely to acquire an early return.
    function test_unconfiguredPool_stillAdvancesAccumulator() public {
        hook.setPoolConfig(key_, 0, 0, 0, 0);
        _assertSwapAdvances(-1e16, true, "");
    }

    /// @dev Rolls forward, swaps, and asserts elapsed time was credited at the pre-swap tick and
    ///      the cursor moved to the current block.
    function _assertSwapAdvances(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
        (int24 tickBefore, uint32 updateBefore, int56 cumBefore) = _acc();

        uint256 elapsed = 13;
        vm.roll(block.number + elapsed);

        _swap(amountSpecified, zeroForOne, hookData);

        (, uint32 updateAfter, int56 cumAfter) = _acc();

        assertGt(updateAfter, updateBefore, "accumulator cursor did not move");
        assertEq(updateAfter, uint32(block.number), "accumulator not advanced to the current block");
        assertEq(
            cumAfter,
            cumBefore + int56(tickBefore) * int56(uint56(elapsed)),
            "elapsed blocks were not credited at the pre-swap tick"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          QUIET-POOL EXTRAPOLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice A pool with no swaps still produces a valid observation: the last tick is held for the whole interval rather than the window being treated as missing data.
    /// @dev This is the property that makes a quiet pool settle without a keeper, and it is why there is no auto-refund branch.
    function test_quietPool_holdsLastTickAcrossTheGap() public {
        _swap(-1e16, true, _validHookData());

        (int24 tickAfterSwap, uint32 updateAtSwap, int56 cumAtSwap) = _acc();

        // A long quiet gap with no interaction at all.
        vm.roll(block.number + 5_000);

        // Storage is untouched — nothing happened.
        (int24 stillTick, uint32 stillUpdate, int56 stillCum) = _acc();
        assertEq(stillTick, tickAfterSwap, "quiet gap changed the stored tick");
        assertEq(stillUpdate, updateAtSwap, "quiet gap changed the stored cursor");
        assertEq(stillCum, cumAtSwap, "quiet gap changed the stored cumulative");

        // The next swap credits the entire gap at the tick that was live across it.
        _swap(-1e16, true, _validHookData());

        (,, int56 cumAfterGap) = _acc();
        assertEq(
            cumAfterGap,
            cumAtSwap + int56(tickAfterSwap) * int56(uint56(5_000)),
            "quiet gap was not extrapolated at the last known tick"
        );
    }
}
