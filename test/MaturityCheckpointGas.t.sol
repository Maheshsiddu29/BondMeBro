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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @notice Stage 3 scan-cost benchmarks — the measurements that choose `MAX_OBSERVATION_BLOCKS`.
///
/// @dev These isolate the two costs that scale with the scan horizon, because they scale
///      differently and answer different questions:
///
///        - EMPTY BUCKET READ: one cold `SLOAD` per candidate block that holds no bond. Paid `W`
///          times in the worst case, so it is what caps `W`.
///        - OCCUPIED CHECKPOINT WRITE: a cold `SSTORE` plus an event, paid only per bucket that
///          actually has a bond maturing in it.
///
///      Cheap empty reads make a larger `W` affordable; expensive ones force it small. Reporting a
///      single blended number would hide which constraint is binding.
///
///      `MAX_OBSERVATION_BLOCKS` is a compile-time constant, so the curve across `W` is produced by
///      rebuilding at each value and re-running this file. Each run reports the numbers for the `W`
///      it was compiled against.
contract MaturityCheckpointGasTest is Test, Deployers {
    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);
    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;

    /// @dev Settlement noise floor, in ticks. Displacement at or below this is never slashed.
    uint16 internal constant REFUND_TOL = 5;
    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    int256 internal constant BONDED_INPUT = -1e16;
    int256 internal constant UNBONDED_INPUT = -1e13;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));
        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));
        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        // DEPTH REDUCED FROM 1e23 TO 1e19 IN P-L2-3/4.
        //
        // This is a real new coupling between subsystems, not a test tidy-up. Model L prices
        // collateral off the REALIZED tick impact, so whether a swap bonds at all now depends on
        // the pool's depth. At 1e23 the swaps in this file move zero ticks, every one of them is
        // unbonded, and a suite about maturity buckets ends up asserting properties of an empty
        // bucket -- passing or failing for reasons that have nothing to do with checkpoints.
        //
        // The same retune was needed in the combined research prototype for the same reason, and
        // it is recorded there too. Any future test that creates bonds must size its liquidity
        // against its swap amounts deliberately.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e19, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);
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

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /*//////////////////////////////////////////////////////////////
                     CASE 1 — ZERO CROSSED MATURITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice The common case: a swap in the very next block, with nothing maturing.
    /// @dev The scan domain is a single block and it is empty, so this is the floor the other
    ///      cases are measured against.
    function test_gas_case1_zeroCrossed_exactInputBonded() public {
        vm.roll(block.number + 1);
        _swap(BONDED_INPUT, true, _hookData());
    }

    function test_gas_case1_zeroCrossed_exactInputUnbonded() public {
        vm.roll(block.number + 1);
        _swap(UNBONDED_INPUT, true, "");
    }

    function test_gas_case1_zeroCrossed_exactOutputBonded() public {
        vm.roll(block.number + 1);
        _swap(1e16, true, _hookData());
    }

    function test_gas_case1_zeroCrossed_exactOutputUnbonded() public {
        vm.roll(block.number + 1);
        _swap(1e13, true, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                  CASE 2 — ONE OCCUPIED CROSSED MATURITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Exactly one registered maturity becomes due. Isolates one checkpoint write.
    function test_gas_case2_oneOccupiedCrossed() public {
        // Open one bond, then jump exactly to its maturity.
        _swap(BONDED_INPUT, true, _hookData());

        vm.roll(block.number + hook.OBSERVATION_BLOCKS());

        _swap(UNBONDED_INPUT, true, "");
    }

    /*//////////////////////////////////////////////////////////////
              CASE 3 — FULL HORIZON SCANNED, ZERO OCCUPIED
    //////////////////////////////////////////////////////////////*/

    /// @notice The empty-read worst case: the whole horizon is inspected and every bucket is empty.
    ///
    /// @dev An unbonded swap leaves no maturity registered, so a gap of at least `W` forces the
    ///      clamp to bind with nothing to freeze. Subtracting case 1 gives the marginal cost of
    ///      `W - 1` extra empty reads.
    function test_gas_case3_fullHorizonScanned_zeroOccupied() public {
        _swap(UNBONDED_INPUT, true, "");

        vm.roll(block.number + hook.MAX_OBSERVATION_BLOCKS() + 5);

        _swap(UNBONDED_INPUT, true, "");
    }

    /*//////////////////////////////////////////////////////////////
              CASE 4 — FULL HORIZON SCANNED, MANY OCCUPIED
    //////////////////////////////////////////////////////////////*/

    /// @notice The write-heavy worst bounded case: as many buckets occupied as the horizon allows.
    ///
    /// @dev Bonds opened in consecutive blocks mature in consecutive blocks, so they land in
    ///      distinct adjacent buckets. After the last one the cursor sits just behind them all, and
    ///      a single later swap must freeze every one of them in one advancement.
    function test_gas_case4_fullHorizonScanned_manyOccupied() public {
        uint32 w = hook.MAX_OBSERVATION_BLOCKS();

        // One bonded swap per block, filling `w` consecutive maturity buckets.
        for (uint32 i = 0; i < w; i++) {
            _swap(BONDED_INPUT, true, _hookData());
            vm.roll(block.number + 1);
        }

        // Jump past all of them, then one swap that has to freeze the lot.
        vm.roll(block.number + hook.OBSERVATION_BLOCKS() + w);

        _swap(UNBONDED_INPUT, true, "");
    }

    /*//////////////////////////////////////////////////////////////
              INTEGRATED WORST CASE — what the gas gate judges
    //////////////////////////////////////////////////////////////*/

    /// @notice The real worst-case `beforeSwap`: the most expensive swap kind, crossing the most
    ///         occupied maturities one advancement can ever face.
    ///
    /// @dev NOT AN ESTIMATE. The gate is on integrated cost, so this measures the whole callback —
    ///      exact-output's provisional record header (the most expensive `beforeSwap` after
    ///      ADR-0004) plus a full checkpoint scan with the maximum reachable occupancy.
    ///
    ///      MAXIMUM OCCUPANCY IS BOUNDED BY `OBSERVATION_BLOCKS`, NOT BY `W`. A bucket at `m` is
    ///      occupied only if a bond opened at `m - OBSERVATION_BLOCKS`, and opening a bond is a
    ///      swap, which advances the cursor. So distinct occupied buckets need distinct opening
    ///      blocks inside the last `OBSERVATION_BLOCKS`. Filling more than that is impossible, and
    ///      the remainder of the horizon can only be cheaper empty reads.
    function test_gas_integratedWorstCase_beforeSwap() public {
        uint32 ob = hook.OBSERVATION_BLOCKS();

        // One bonded swap per block for `OBSERVATION_BLOCKS` blocks: the densest reachable run of
        // occupied maturity buckets, all still unfrozen because each swap's own scan is clamped to
        // its own block.
        for (uint32 i = 0; i < ob; i++) {
            _swap(BONDED_INPUT, true, _hookData());
            vm.roll(block.number + 1);
        }

        // Jump past every one of them, so a single advancement must freeze the lot.
        vm.roll(block.number + uint256(ob) + hook.MAX_OBSERVATION_BLOCKS());

        // The expensive swap kind, on top of that scan.
        _swap(1e16, true, _hookData());
    }

    /// @notice THE TRUE WORST CASE, and the number the hard gate is judged on.
    ///
    /// @dev `test_gas_integratedWorstCase_beforeSwap` above is NOT the worst case, and the
    ///      difference is easy to miss. It crosses 10 occupied maturities with `C - L` around 10,
    ///      so `scanEnd = min(C, L + W)` is bound by `C` and only ~10 of the 16 available
    ///      positions are ever inspected. The remaining 6 empty positions cost nothing there.
    ///
    ///      The real worst case pays for BOTH: the maximum reachable occupancy
    ///      (`OBSERVATION_BLOCKS = 10` buckets, since a bucket at `m` needs a bond opened at
    ///      `m - OBSERVATION_BLOCKS` and opening advances the cursor) AND the full horizon
    ///      (`MAX_OBSERVATION_BLOCKS = 16` positions, reached by making `C - L >= W` so the clamp
    ///      binds on the horizon rather than on the current block). The 6 positions beyond the
    ///      occupied run are scanned as empty reads.
    ///
    ///      So: 10 occupied freezes + 6 empty reads + the most expensive swap kind's own
    ///      `beforeSwap` work.
    function test_gas_trueWorstCase_fullHorizonAndMaxOccupancy() public {
        uint32 ob = hook.OBSERVATION_BLOCKS();
        uint32 w = hook.MAX_OBSERVATION_BLOCKS();

        // Fill the densest reachable run of occupied maturity buckets.
        for (uint32 i = 0; i < ob; i++) {
            _swap(BONDED_INPUT, true, _hookData());
            vm.roll(block.number + 1);
        }

        // Push `C` far enough past `L` that the clamp binds on the HORIZON, not on `C`. That is
        // what makes the trailing empty positions part of the scan.
        vm.roll(block.number + uint256(w) + uint256(ob) + 50);

        _swap(1e16, true, _hookData());
    }

    /// @notice Same scenario, asserting the scan really did cover the full horizon and freeze
    ///         exactly the occupied subset.
    /// @dev Without this the gas number above could be measuring a shorter scan than intended.
    function test_trueWorstCase_scansFullHorizonAndFreezesExactlyTheOccupied() public {
        uint32 ob = hook.OBSERVATION_BLOCKS();
        uint32 w = hook.MAX_OBSERVATION_BLOCKS();

        uint32 firstMaturity = uint32(block.number) + ob;

        for (uint32 i = 0; i < ob; i++) {
            _swap(BONDED_INPUT, true, _hookData());
            vm.roll(block.number + 1);
        }

        // The cursor sits at the last opening block.
        (, uint32 l,) = hook.accumulator(id_);

        // All ten maturities are ahead of the cursor and still unfrozen.
        for (uint32 i = 0; i < ob; i++) {
            (,,, uint32 pending, uint8 frozenMask) = hook.maturity(id_, firstMaturity + i);
            bool frozen = frozenMask & hook.FROZEN_C10() != 0;
            assertEq(pending, 1, "a maturity did not register");
            assertFalse(frozen, "a maturity froze before it was crossed");
            assertGt(firstMaturity + i, l, "fixture did not leave the maturities ahead of the cursor");
        }

        vm.roll(block.number + uint256(w) + uint256(ob) + 50);

        _swap(1e16, true, _hookData());

        // The clamp bound on the horizon, so the scan covered (l, l + w] — 16 positions.
        assertGt(uint256(block.number), uint256(l) + uint256(w), "fixture did not force the horizon clamp");

        // Every occupied position inside the horizon froze.
        uint32 frozenCount;
        for (uint32 m = l + 1; m <= l + w; m++) {
            (,,, uint32 pending, uint8 frozenMask) = hook.maturity(id_, m);
            bool frozen = frozenMask & hook.FROZEN_C10() != 0;

            if (pending > 0) {
                assertTrue(frozen, "an occupied position inside the horizon was not frozen");
                frozenCount++;
            } else {
                assertFalse(frozen, "an empty position was frozen");
            }
        }

        assertEq(frozenCount, ob, "wrong number of checkpoints frozen across the horizon");
    }

    /// @notice CONTROL for the true worst case: the same 10 occupied maturities, but with `C`
    ///         close enough to `L` that the clamp binds on the CURRENT BLOCK instead of on the
    ///         horizon, so the 6 trailing empty positions are never scanned.
    ///
    /// @dev Exists to prove the worst-case benchmark is really paying for the full horizon. The
    ///      difference between this and `test_gas_trueWorstCase_fullHorizonAndMaxOccupancy` is the
    ///      cost of those 6 empty reads; if the two were equal, the "worst case" would not be
    ///      scanning what it claims to.
    function test_gas_control_maxOccupancy_clampBindsOnCurrentBlock() public {
        uint32 ob = hook.OBSERVATION_BLOCKS();

        for (uint32 i = 0; i < ob; i++) {
            _swap(BONDED_INPUT, true, _hookData());
            vm.roll(block.number + 1);
        }

        // Land exactly on the last maturity: C - L = ob, well under W, so scanEnd = C.
        vm.roll(block.number + uint256(ob) - 1);

        _swap(1e16, true, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                       CASE 5 — LONG QUIET GAP
    //////////////////////////////////////////////////////////////*/

    /// @notice `C - L >> W`. Work must stay clamped to the horizon, not scale with the gap.
    /// @dev Compared against case 3 in the report: if the two differ materially, the clamp is not
    ///      binding and the scan is proportional to the quiet period.
    function test_gas_case5_longQuietGap() public {
        _swap(BONDED_INPUT, true, _hookData());

        // Two orders of magnitude beyond the horizon.
        vm.roll(block.number + 5_000);

        _swap(UNBONDED_INPUT, true, "");
    }

    /// @notice Same shape as case 5 but an order of magnitude further out again.
    /// @dev Two gap lengths that differ by 10x must cost the same. That is the clamp, measured
    ///      rather than argued.
    function test_gas_case5b_veryLongQuietGap() public {
        _swap(BONDED_INPUT, true, _hookData());

        vm.roll(block.number + 50_000);

        _swap(UNBONDED_INPUT, true, "");
    }
}
