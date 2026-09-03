// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

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

/// @title VariableLegGasTest
///
/// @notice Isolated swap shapes for measuring `beforeSwap` and `afterSwap` gas after P-L2-3/4.
///
/// @dev HOW THESE NUMBERS ARE MEANT TO BE READ.
///
///      Each test here is ONE swap and nothing else, so the callback frames in a `-vvvv` trace
///      belong unambiguously to that shape. The ceilings that matter are stated in `AGENTS.md`:
///
///          beforeSwap  < 150,000
///          afterSwap   < 100,000
///
///      WHY THE SHAPES ARE SPLIT THE WAY THEY ARE. P-L2-3/4 moved work in BOTH directions at once,
///      which makes a single headline figure misleading:
///
///        - custody MOVED OUT of `beforeSwap` into `afterSwap` -- the sizing, the ceiling check
///          and the `take` now happen where the realized legs are known;
///        - the provisional record header MOVED THE OTHER WAY -- `beforeSwap` now writes it for
///          exact-INPUT as well, which it previously did only for exact-output.
///
///      So exact-input got heavier in `afterSwap` and heavier in `beforeSwap`, while exact-output
///      barely moved. Measuring only one mode would report whichever half of that story the mode
///      happened to show.
///
///      The unbonded shapes are measured too, and they are the ones most users pay: a pool with a
///      realistic `minBondedAmount` leaves most swaps unbonded, so the unbonded frame is the
///      hook's actual tax on ordinary flow.
///
///      MEASURED AT P-L2-3/4, from `-vvvv` callback frames on this fixture:
///
///          shape                                     beforeSwap   afterSwap
///          ---------------------------------------   ----------   ---------
///          bonded  exact-input  zeroForOne               60,883      68,719
///          bonded  exact-input  oneForZero               60,917      68,697
///          bonded  exact-output zeroForOne               60,618      68,712
///          bonded  exact-output oneForZero               60,618      68,724
///          unbonded exact-input below threshold           9,506      17,071
///          unbonded exact-output below threshold         60,618      10,974
///          bonded, freezing one maturity                 83,229      41,219
///          bonded, after a 100,000-block quiet gap       95,559      41,219
///          WORST CASE: full scan + 10 freezes + bond    102,075      68,719
///
///          ceiling                                      150,000     100,000
///          worst-case margin                              32.0%       31.3%
///
///      THE WORST CASE IS 10 FREEZES, NOT 16, and that is a property rather than an accident of
///      this fixture. The scan runs from `lastUpdate + 1` to at most `lastUpdate +
///      MAX_OBSERVATION_BLOCKS` (16), but a bucket can only be occupied and still unfrozen if its
///      maturity is at most `OBSERVATION_BLOCKS` (10) ahead of the cursor -- anything older would
///      have been frozen by the swap that passed it. So no single scan can freeze more than ten,
///      whatever the gap, and `test_worstCaseConstruction_leavesEveryBucketOccupiedAndUnfrozen`
///      pins that the construction below really does reach all ten.
///
///      RESIDUAL, STATED PLAINLY. Running the whole non-research suite with traces on, the largest
///      `beforeSwap` frame observed anywhere is 112,717, inside the stateful invariant campaign --
///      about 10,600 above the worst case reconstructed here. That gap is NOT explained. What can
///      be said about it: it is bounded (INV-L2-12 measures callback cost as flat from 4 to 64
///      pending bonds, 134,916 against 134,772), it is reproducible in the campaign, and even the
///      unexplained figure sits 24.9% under the ceiling. It is reported rather than rounded away.
///
///      P-L2-7 RE-MEASURED: the figures above are pre-cleanup. After removing `cumulativeAtOpen`,
///      `PersistenceMathLib`, `afterInitializeCount` and the two obsolete `PoolConfig` fields,
///      `beforeSwap` fell by 127 gas everywhere and `afterSwap` rose by a uniform 222. The
///      worst-case `beforeSwap` is now 106,878 against a 150,000 ceiling; the worst `afterSwap`
///      73,447 against 100,000. See `P_L2_7_MIGRATION_REPORT.md` § 7 for the full table and for
///      what the +222 is and is not attributable to.
contract VariableLegGasTest is Test, Deployers {
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

    int128 internal constant POOL_LIQUIDITY = 1e19;

    uint256 internal constant BONDED_SIZE = 1e16;
    uint256 internal constant UNBONDED_SIZE = 1e14;

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

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, true);
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

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

    /*//////////////////////////////////////////////////////////////
                       THE FOUR BONDED SHAPES
    //////////////////////////////////////////////////////////////*/

    function test_gas_bonded_exactInput_zeroForOne() public {
        _swap(-int256(BONDED_SIZE), true, _hookData());
    }

    function test_gas_bonded_exactInput_oneForZero() public {
        _swap(-int256(BONDED_SIZE), false, _hookData());
    }

    function test_gas_bonded_exactOutput_zeroForOne() public {
        _swap(int256(BONDED_SIZE), true, _hookData());
    }

    function test_gas_bonded_exactOutput_oneForZero() public {
        _swap(int256(BONDED_SIZE), false, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                          UNBONDED SHAPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Below the threshold and exact-input, so `beforeSwap`'s pre-filter short-circuits before
    ///      it decodes hookData or writes a provisional record. This is the cheapest path the hook
    ///      has, and the one most ordinary flow takes.
    function test_gas_unbonded_exactInput_belowThreshold() public {
        _swap(-int256(UNBONDED_SIZE), true, "");
    }

    /// @dev Exact-OUTPUT below the threshold. The pre-filter cannot help here -- the input is not
    ///      known until the swap runs -- so this pays for hookData decoding AND a provisional
    ///      record that `afterSwap` then clears. The most expensive way to bond nothing.
    function test_gas_unbonded_exactOutput_belowThreshold() public {
        _swap(int256(UNBONDED_SIZE), true, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                    THE EXPENSIVE CHECKPOINT FRAMES
    //////////////////////////////////////////////////////////////*/

    /// @dev A swap that must freeze a maturity checkpoint on its way through. The scan is what
    ///      `beforeSwap` does beyond custody, so this is the shape that sets its ceiling rather
    ///      than the plain bonded one.
    function test_gas_bonded_afterAQuietGapFreezingOneMaturity() public {
        _swap(-int256(BONDED_SIZE), true, _hookData());

        vm.roll(block.number + hook.OBSERVATION_BLOCKS() + 1);

        _swap(-int256(BONDED_SIZE), true, _hookData());
    }

    /// @dev A long quiet gap, so `beforeSwap` scans its full horizon with nothing to freeze. The
    ///      empty-scan cost, which is what every swap after a quiet period pays.
    function test_gas_bonded_afterALongQuietGap() public {
        _swap(-int256(BONDED_SIZE), true, _hookData());

        vm.roll(block.number + 100_000);

        _swap(-int256(BONDED_SIZE), true, _hookData());
    }

    /// @dev THE DETERMINISTIC WORST CASE for `beforeSwap`, reconstructed rather than observed.
    ///
    ///      Running the whole suite with traces on, the largest `beforeSwap` frame anywhere is
    ///      produced by the stateful invariant campaign, not by any enumerated test -- the campaign
    ///      wanders into a shape none of the fixed shapes above reach. Reporting that as an
    ///      "observed randomized maximum" would leave the actual ceiling unexplained, so this
    ///      rebuilds the shape on purpose.
    ///
    ///      The expensive frame needs BOTH halves of `beforeSwap`'s work at once:
    ///
    ///        - a FULL-HORIZON SCAN. A long quiet gap means the cursor has to walk its entire
    ///          window rather than the block or two a busy pool leaves behind. Measured alone at
    ///          95,559 on an empty horizon.
    ///        - SEVERAL OCCUPIED BUCKETS TO FREEZE. Each maturity that comes due in that walk is a
    ///          cold SSTORE. One freeze alone measured 83,229; the empty walk 95,559; the campaign's
    ///          frames sit near 112,500, which is roughly the walk plus a second freeze.
    ///
    ///      So: bonds opened in consecutive blocks, spreading liabilities across consecutive
    ///      maturity buckets, then a long silence, then one swap that must clear all of them.
    function test_gas_worstCase_fullHorizonScanFreezingEveryOccupiedBucket() public {
        // One bonded swap per block, filling OBSERVATION_BLOCKS consecutive maturity buckets.
        for (uint256 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            _swap(-int256(BONDED_SIZE), true, _hookData());

            vm.roll(block.number + 1);
        }

        // Long silence, so the cursor must walk its whole horizon when it next moves.
        vm.roll(block.number + 100_000);

        // The frame under measurement: full scan, every occupied bucket due, plus a new bond.
        _swap(-int256(BONDED_SIZE), true, _hookData());
    }

    /// @dev The same worst case with no new bond opened, isolating the scan-and-freeze cost from
    ///      the provisional write.
    /// @dev Diagnostic: confirms the worst-case construction really leaves every bucket occupied
    ///      and unfrozen before the flush. Without this the shape above could silently degrade
    ///      into a cheap scan and still "pass" as a gas measurement.
    function test_worstCaseConstruction_leavesEveryBucketOccupiedAndUnfrozen() public {
        uint32 firstMaturity = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        for (uint256 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            _swap(-int256(BONDED_SIZE), true, _hookData());

            vm.roll(block.number + 1);
        }

        uint256 occupied;
        uint256 frozen;

        for (uint32 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            (,,, uint32 pending, uint8 checkpointedMask) = hook.maturity(id_, firstMaturity + i);
            bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;

            if (pending > 0) occupied++;
            if (checkpointed) frozen++;

            console2.log("bucket", uint256(firstMaturity + i));
            console2.log("  pending", uint256(pending));
        }

        console2.log("occupied buckets", occupied);
        console2.log("frozen buckets  ", frozen);

        assertEq(occupied, hook.OBSERVATION_BLOCKS(), "not every block opened its own maturity bucket");

        assertEq(frozen, 0, "buckets were frozen during setup, so the flush has nothing left to do");
    }

    function test_gas_worstCase_fullHorizonScanUnbonded() public {
        for (uint256 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            _swap(-int256(BONDED_SIZE), true, _hookData());

            vm.roll(block.number + 1);
        }

        vm.roll(block.number + 100_000);

        _swap(-int256(UNBONDED_SIZE), true, "");
    }

    /*//////////////////////////////////////////////////////////////
                     THE BOUND, ASSERTED NOT PRINTED
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-L2-12: neither callback's cost depends on the number of pending bonds.
    ///
    /// @dev THE PROPERTY THAT MAKES THE CEILINGS MEAN ANYTHING. A measured figure is only a bound
    ///      if the work is bounded; if callback cost grew with the number of outstanding bonds,
    ///      today's number would say nothing about a busy pool tomorrow.
    ///
    ///      THE COMPARISON IS BETWEEN TWO ALREADY-WARM POOLS, and that construction is deliberate.
    ///
    ///      The obvious version of this test -- one swap into an empty pool against one swap into
    ///      a loaded pool -- measures the wrong thing. Measured here, the loaded run came out
    ///      131,155 gas CHEAPER, because 64 prior swaps had warmed the token contracts, the pool's
    ///      slot0 and the accumulator. Storage warming swamps the effect under test in the
    ///      opposite direction, so that comparison can neither confirm nor refute the invariant: a
    ///      genuinely linear cost could hide inside the warming discount.
    ///
    ///      Both arms therefore run against a pool that is already warm, differing ONLY in how many
    ///      bonds are outstanding -- 4 against 64. Any per-bond work shows up undiluted. Sixteen
    ///      times the bonds at even one cold SLOAD each would be 126,000 gas; the tolerance below
    ///      is a small fraction of that, so a linear term could not pass.
    function test_inv_L2_12_callbackCostDoesNotGrowWithPendingBonds() public {
        uint256 clean = vm.snapshotState();

        uint256 gasFew = _gasAfterNBonds(4);

        vm.revertToState(clean);

        uint256 gasMany = _gasAfterNBonds(64);

        console2.log("bonded swap with  4 pending", gasFew);
        console2.log("bonded swap with 64 pending", gasMany);

        // ONE-SIDED. The invariant forbids cost GROWING with the bond count; coming out cheaper is
        // a warming artifact and is not a violation of anything.
        assertLe(gasMany, gasFew + 5_000, "INV-L2-12: callback cost grew with the number of pending bonds");
    }

    /// @dev Fills a bucket with `n` bonds, then times one more identical swap.
    ///
    ///      The measured swap is always the `n + 1`th, so by the time it runs every slot it touches
    ///      has been touched before in both arms. What differs between the arms is only the value
    ///      of the bucket's `pendingBonds` counter and the number of bond records already written.
    function _gasAfterNBonds(uint256 n) internal returns (uint256) {
        for (uint256 i = 0; i < n; i++) {
            _swap(-int256(BONDED_SIZE), true, _hookData());
        }

        (,,, uint32 pending,) = hook.maturity(id_, uint32(block.number) + hook.OBSERVATION_BLOCKS());

        assertEq(pending, n, "the fixture did not accumulate the expected number of pending bonds");

        return _timeOneBondedSwap();
    }

    /// @dev Times one bonded swap end to end, including both callbacks.
    function _timeOneBondedSwap() internal returns (uint256) {
        uint256 before = gasleft();

        _swap(-int256(BONDED_SIZE), true, _hookData());

        return before - gasleft();
    }

    /// @notice The deployed runtime bytecode is inside the EIP-170 limit, with the margin stated.
    ///
    /// @dev P-L2-3/4 deleted three custody functions and added one, so the direction of travel
    ///      should be downward -- but "should" is not a measurement, and a hook that cannot be
    ///      deployed is not a hook. The margin is logged so the next stage knows what it has to
    ///      spend before this becomes the binding constraint.
    ///
    ///      SKIPPED UNDER `forge coverage`, and that is not the assertion being weakened.
    ///      Coverage instrumentation rewrites the contract to record every branch and builds with
    ///      the optimizer off, which inflates the bytecode well past 24,576 bytes. The instrumented
    ///      artifact is never deployed and its size means nothing, so asserting against it would
    ///      fail for a reason that has no bearing on deployability -- and, before this guard, the
    ///      margin subtraction underflowed and aborted the run outright. The size that matters is
    ///      the optimized one, which this test measures under `forge test` and which
    ///      `forge build --sizes` reports independently in the gate.
    function test_codeSize_isInsideTheEip170Limit() public view {
        uint256 size = address(hook).code.length;

        console2.log("BondMeBro runtime bytecode (bytes)", size);

        if (vm.isContext(VmSafe.ForgeContext.Coverage)) {
            console2.log("skipping the EIP-170 assertion: coverage-instrumented build, size is not meaningful");

            return;
        }

        assertLt(size, 24_576, "BondMeBro exceeds the EIP-170 contract size limit and cannot be deployed");

        console2.log("EIP-170 headroom remaining (bytes)", 24_576 - size);
    }
}
