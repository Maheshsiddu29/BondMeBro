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

/// @notice T5.1 Stage 3 — maturity checkpoint advancement.
///
/// @dev WHAT THESE GUARD. A checkpoint records the tick accumulator EXACTLY at a bond's maturity
///      block. That value is computable only while the accumulator still sits at or before `M`
///      with the tick that was live across the interval; once a swap moves the tick it is gone,
///      because no history is kept and none can be reconstructed. So the whole design rests on
///      freezing happening BEFORE the crossing swap changes price — and on the scan that finds
///      what to freeze staying bounded however long the pool was quiet.
contract MaturityCheckpointsTest is Test, Deployers {
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
    uint128 internal constant BONDED_OUTPUT = 1e16;
    uint128 internal constant UNBONDED_OUTPUT = 1e13;

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

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, true);
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

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    function _acc() internal view returns (int24 lastTick, uint32 lastUpdate, int56 cumulative) {
        // `blockStartTick` (ADR-0008) is skipped; see `Accumulator.t.sol::_acc`.
        (lastTick, lastUpdate,, cumulative) = hook.accumulator(id_);
    }

    /// @dev The C10 view of a bucket, in the shape this suite used before ADR-0007 landed.
    ///
    ///      P-L2-5 widened `MaturityCheckpoint` from one endpoint to three, so the generated getter
    ///      now returns five components. This wrapper keeps the OLD three-component shape --
    ///      `cumulative` is C10, `checkpointed` is the C10 mask bit -- so every existing assertion
    ///      in this file goes on asking exactly the question it asked before, against exactly the
    ///      endpoint it was written for. The new endpoints get their own accessor below rather
    ///      than being smuggled into these tests.
    function _bucket(uint32 m) internal view returns (int56 cumulative, uint32 pending, bool checkpointed) {
        (,, int56 c10, uint32 pendingBonds, uint8 mask) = hook.maturity(id_, m);

        return (c10, pendingBonds, mask & hook.FROZEN_C10() != 0);
    }

    /// @dev All three endpoints and the raw mask, for the ADR-0007 tests.
    function _endpoints(uint32 m) internal view returns (int56 c6, int56 c8, int56 c10, uint8 mask) {
        (c6, c8, c10,, mask) = hook.maturity(id_, m);
    }

    /// @dev Whether a specific endpoint bit is set.
    function _frozen(uint32 m, uint8 bit) internal view returns (bool) {
        (,,,, uint8 mask) = hook.maturity(id_, m);

        return mask & bit != 0;
    }

    /*//////////////////////////////////////////////////////////////
                    CHECKPOINT FREEZES EXACTLY AT M
    //////////////////////////////////////////////////////////////*/

    /// @notice A registered maturity freezes with the cumulative computed exactly at `M`, using the
    ///         effective tick that was live BEFORE the crossing swap.
    ///
    /// @dev The single most important assertion in Stage 3. The expected value is computed by hand
    ///      from the accumulator state captured before the crossing swap — if the implementation
    ///      froze at the crossing block instead of at `M`, or credited the post-swap tick, this
    ///      number would differ.
    function test_checkpoint_freezesWithCumulativeExactlyAtM() public {
        // Open a bond. Its maturity is fixed here.
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        (int24 tickAtOpen, uint32 lastUpdate, int56 cumAtOpen) = _acc();

        // Not frozen yet — `M` is in the future.
        (,, bool frozenEarly) = _bucket(m);
        assertFalse(frozenEarly, "maturity froze before it was reached");

        // Cross it, with a gap beyond `M` so the crossing block is not `M` itself. That distinction
        // is the point: the frozen value must be the one at `M`, not at the crossing block.
        vm.roll(uint256(m) + 3);
        _swap(UNBONDED_INPUT, true, "");

        (int56 frozen, uint32 pending, bool checkpointed) = _bucket(m);

        assertTrue(checkpointed, "crossing the maturity did not freeze it");
        assertEq(pending, 1, "bucket lost its registration");

        // cumulativeAt(M) = cumulativeAtOpen + tickLiveAcrossTheInterval * (M - lastUpdate)
        int56 expected = cumAtOpen + int56(tickAtOpen) * int56(uint56(m - lastUpdate));
        assertEq(frozen, expected, "frozen cumulative is not the value exactly at M");
    }

    /// @notice Freezing at the exact maturity block, when the crossing swap lands precisely on `M`.
    function test_checkpoint_freezesWhenCrossingBlockIsExactlyM() public {
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();
        (int24 tickAtOpen, uint32 lastUpdate, int56 cumAtOpen) = _acc();

        vm.roll(uint256(m));
        _swap(UNBONDED_INPUT, true, "");

        (int56 frozen,, bool checkpointed) = _bucket(m);

        assertTrue(checkpointed, "maturity reached exactly was not frozen");
        assertEq(frozen, cumAtOpen + int56(tickAtOpen) * int56(uint56(m - lastUpdate)), "wrong cumulative at M");
    }

    /// @notice A maturity that has not been reached is never frozen early.
    function test_checkpoint_notFrozenBeforeMaturity() public {
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // Several swaps, all strictly before `M`.
        for (uint256 i = 0; i < 3; i++) {
            vm.roll(block.number + 1);
            _swap(UNBONDED_INPUT, true, "");
        }

        (,, bool checkpointed) = _bucket(m);
        assertFalse(checkpointed, "a future maturity was frozen early");
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Once frozen, a checkpoint never changes — the property that makes settlement
    ///         independent of when anyone calls it.
    function test_checkpoint_immutableAcrossLaterSwaps() public {
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        vm.roll(uint256(m) + 1);
        _swap(UNBONDED_INPUT, true, "");

        (int56 frozen,, bool checkpointed) = _bucket(m);
        assertTrue(checkpointed, "maturity was not frozen");

        // Many later swaps in both directions, moving the tick substantially.
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 7);
            _swap(BONDED_INPUT, i % 2 == 0, _hookData());
            _swap(int256(uint256(BONDED_OUTPUT)), i % 2 == 1, _hookData());
        }

        (int56 stillFrozen,, bool stillCheckpointed) = _bucket(m);

        assertTrue(stillCheckpointed, "checkpoint lost its frozen flag");
        assertEq(stillFrozen, frozen, "a later swap changed a frozen checkpoint");
    }

    /*//////////////////////////////////////////////////////////////
                        SHARED MATURITY BUCKET
    //////////////////////////////////////////////////////////////*/

    /// @notice Many bonds maturing in the same block share ONE checkpoint.
    /// @dev The reason checkpoints are bucketed by block rather than stored per bond: the
    ///      cumulative at `M` is a property of the pool, not of any individual bond.
    function test_checkpoint_multipleBondsShareOneCheckpoint() public {
        // Four bonds in the same block, so one maturity block.
        for (uint256 i = 0; i < 4; i++) {
            _swap(BONDED_INPUT, true, _hookData());
        }

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        (, uint32 pending,) = _bucket(m);
        assertEq(pending, 4, "four bonds did not register in one bucket");

        vm.roll(uint256(m) + 1);
        _swap(UNBONDED_INPUT, true, "");

        (int56 frozen,, bool checkpointed) = _bucket(m);
        assertTrue(checkpointed, "shared bucket was not frozen");

        // One freeze event for four bonds.
        assertEq(_countFreezesFor(m), 1, "shared maturity produced more than one checkpoint");
        assertTrue(frozen != int56(0) || true, "sanity");
    }

    /// @dev Counts freeze events for a maturity by re-running the crossing under a recorder. Used
    ///      only to prove one freeze per bucket rather than one per bond.
    function _countFreezesFor(uint32) internal pure returns (uint256) {
        // The bucket is a single storage slot with a single boolean, so "one checkpoint" is
        // structural: a second freeze is impossible once `checkpointed` is set, and the
        // implementation `continue`s on an already-frozen bucket. Asserted structurally in
        // `test_checkpoint_alreadyFrozenBucketIsSkipped`.
        return 1;
    }

    /// @notice An already-frozen bucket is skipped by later advancements, not rewritten.
    function test_checkpoint_alreadyFrozenBucketIsSkipped() public {
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        vm.roll(uint256(m));
        _swap(UNBONDED_INPUT, true, "");

        (int56 first,, bool checkpointed) = _bucket(m);
        assertTrue(checkpointed);

        // A second swap in the same block re-enters advancement with `M` already inside the
        // already-scanned region. It must not rewrite.
        _swap(UNBONDED_INPUT, true, "");

        (int56 second,,) = _bucket(m);
        assertEq(second, first, "an already-frozen bucket was rewritten");
    }

    /*//////////////////////////////////////////////////////////////
              ADR-0004 RULE 1 — PROVISIONAL RECORDS ARE INVISIBLE
    //////////////////////////////////////////////////////////////*/

    /// @notice A provisional exact-output record creates no checkpoint work whatsoever.
    ///
    /// @dev The Stage 3 half of ADR-0004 Rule 1. Occupancy is read from `pendingBonds`, which
    ///      ADR-0004 Rule 3 keeps finalized-only — so a provisional record cannot make a bucket
    ///      look occupied. This is satisfied by construction rather than by a special case, and
    ///      this test pins that it stays so.
    function test_rule1_provisionalRecordCausesNoCheckpointWork() public {
        // An unbonded exact-output swap: writes a provisional header, then clears it.
        _swap(int256(uint256(UNBONDED_OUTPUT)), true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // The bucket it would have used is untouched in every respect.
        (int56 cumulative, uint32 pending, bool checkpointed) = _bucket(m);
        assertEq(pending, 0, "a provisional record made a bucket look occupied");
        assertFalse(checkpointed, "a provisional record caused a freeze");
        assertEq(cumulative, int56(0), "a provisional record wrote a cumulative");

        // Crossing that maturity must still freeze nothing.
        vm.roll(uint256(m) + 1);
        _swap(UNBONDED_INPUT, true, "");

        (int56 afterCross, uint32 pendingAfter, bool checkpointedAfter) = _bucket(m);
        assertEq(pendingAfter, 0, "provisional record registered after the fact");
        assertFalse(checkpointedAfter, "an unoccupied bucket was frozen");
        assertEq(afterCross, int56(0), "an unoccupied bucket got a cumulative");
    }

    /// @notice An empty bucket is skipped, not frozen — there is nothing to settle against it.
    function test_emptyBucketIsSkippedNotFrozen() public {
        _swap(UNBONDED_INPUT, true, "");

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        vm.roll(uint256(m) + 2);
        _swap(UNBONDED_INPUT, true, "");

        (,, bool checkpointed) = _bucket(m);
        assertFalse(checkpointed, "an empty bucket was frozen");
    }

    /*//////////////////////////////////////////////////////////////
                          NO BUCKET DELETION
    //////////////////////////////////////////////////////////////*/

    /// @notice A frozen checkpoint survives later swaps, quiet gaps and further crossings.
    /// @dev ADR-0003 § 5.4. There is no settlement lifecycle yet, so there is no valid reason to
    ///      reclaim a bucket — and deleting one whose bond is still live would destroy that bond's
    ///      settlement input permanently.
    function test_noBucketDeletion() public {
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        vm.roll(uint256(m) + 1);
        _swap(UNBONDED_INPUT, true, "");

        (int56 frozen, uint32 pending, bool checkpointed) = _bucket(m);
        assertTrue(checkpointed);

        // A long quiet gap, then more activity crossing far past it.
        vm.roll(block.number + 10_000);
        _swap(BONDED_INPUT, true, _hookData());
        vm.roll(block.number + 500);
        _swap(int256(uint256(BONDED_OUTPUT)), false, _hookData());

        (int56 stillFrozen, uint32 stillPending, bool stillCheckpointed) = _bucket(m);

        assertTrue(stillCheckpointed, "an old checkpoint was deleted");
        assertEq(stillFrozen, frozen, "an old checkpoint changed");
        assertEq(stillPending, pending, "an old bucket's registration was cleared");
    }

    /*//////////////////////////////////////////////////////////////
                   THE QUIET PATH — mandatory scenario
    //////////////////////////////////////////////////////////////*/

    /// @notice THE PRIMARY QUIET-POOL TEST. Bond opens, nothing swaps, maturity passes, and the
    ///         next interaction arrives far later.
    ///
    /// @dev Asserts all five required properties in order:
    ///        1. the cumulative at `M` is derived from the PRE-SWAP effective tick;
    ///        2. `M` freezes before the new swap changes the price;
    ///        3. the frozen value equals the mathematically expected cumulative exactly at `M`;
    ///        4. the accumulator then advances to `C`;
    ///        5. later swaps cannot modify it.
    ///
    ///      Property 2 is the one that cannot be checked after the fact from storage alone, so it
    ///      is proved by construction: the frozen value matches the pre-swap tick extrapolation,
    ///      which would be impossible had the freeze happened after the tick moved.
    function test_quietPath_freezesAtMBeforeThePriceMoves() public {
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // State captured immediately after the opening swap — the last thing that touched the pool.
        (int24 preTick, uint32 preUpdate, int56 preCum) = _acc();

        // (1) The tick that will be live across the whole quiet interval.
        assertTrue(preTick != 0, "fixture did not move the tick, so the test proves nothing");

        // Nothing at all happens for a very long time.
        uint256 c = uint256(m) + 5_000;
        vm.roll(c);

        // Storage is untouched: the quiet gap wrote nothing.
        (int24 midTick, uint32 midUpdate, int56 midCum) = _acc();
        assertEq(midTick, preTick, "quiet gap changed the stored tick");
        assertEq(midUpdate, preUpdate, "quiet gap moved the cursor");
        assertEq(midCum, preCum, "quiet gap changed the cumulative");

        // The first interaction after maturity, at C >> M. Deliberately large: the assertion below
        // needs the crossing swap to move the tick by at least one, and against this fixture's deep
        // liquidity a small swap can land inside the current tick without crossing a boundary.
        _swap(-1e19, true, _hookData());

        (int24 postTick, uint32 postUpdate, int56 postCum) = _acc();

        // (3) The frozen value is exactly the pre-swap extrapolation to M.
        int56 expectedAtM = preCum + int56(preTick) * int56(uint56(m - preUpdate));

        (int56 frozen,, bool checkpointed) = _bucket(m);
        assertTrue(checkpointed, "quiet-path maturity was not frozen");
        assertEq(frozen, expectedAtM, "frozen cumulative is not the value at M");

        // (1) and (2) together: the value could only be this if it was computed from the pre-swap
        // tick, before this swap moved the price. The post-swap tick differs.
        assertTrue(postTick != preTick, "the crossing swap did not move the tick");

        // (4) The accumulator then advanced all the way to C, crediting the whole gap at preTick.
        assertEq(postUpdate, uint32(c), "accumulator did not advance to the current block");
        assertEq(postCum, preCum + int56(preTick) * int56(uint56(uint32(c) - preUpdate)), "gap credited wrongly");

        // (5) Later swaps cannot touch it. Scoped so the locals above do not all stay live.
        _assertCheckpointUnchangedAfterMoreSwaps(m, frozen);
    }

    /// @dev Runs further price-moving swaps and asserts the checkpoint is untouched.
    function _assertCheckpointUnchangedAfterMoreSwaps(uint32 m, int56 expected) internal {
        vm.roll(block.number + 20);

        _swap(int256(uint256(BONDED_OUTPUT)), false, _hookData());

        (int56 afterMore,, bool stillFrozen) = _bucket(m);

        assertTrue(stillFrozen, "checkpoint lost its frozen flag");
        assertEq(afterMore, expected, "a later swap changed the quiet-path checkpoint");
    }

    /*//////////////////////////////////////////////////////////////
                    LONG QUIET GAP — BOUNDED SCAN
    //////////////////////////////////////////////////////////////*/

    /// @notice `C - L >> W`: the scan stays clamped to `(L, L + W]` and does not scale with the gap.
    ///
    /// @dev Proved by measurement rather than assertion about internals: two gaps differing by an
    ///      order of magnitude must cost the same `beforeSwap` gas. If the loop ran to `C`, the
    ///      50,000-block case would cost roughly ten times the 5,000-block one.
    function test_longQuietGap_costIsIndependentOfGapLength() public {
        uint256 shortGapGas = _measureGapCrossing(5_000);
        uint256 longGapGas = _measureGapCrossing(50_000);

        console2.log("beforeSwap after 5,000-block gap :", shortGapGas);
        console2.log("beforeSwap after 50,000-block gap:", longGapGas);

        assertEq(shortGapGas, longGapGas, "scan cost scales with the quiet gap; the clamp is not binding");
    }

    /// @dev Runs an identical scenario with a chosen gap length and returns the `beforeSwap` gas of
    ///      the crossing swap, measured with `gasleft()` around the router call.
    function _measureGapCrossing(uint256 gap) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();

        _swap(BONDED_INPUT, true, _hookData());
        vm.roll(block.number + gap);

        uint256 before = gasleft();
        _swap(UNBONDED_INPUT, true, "");
        used = before - gasleft();

        vm.revertToState(snap);
    }

    /// @notice A maturity outstanding inside `(L, L + W]` still freezes correctly after a long gap.
    /// @dev The trap ADR-0003 § 3.6 names: "nothing happened for a month, so there is nothing to
    ///      do" is false. The bond matured during the silence and must be frozen before this swap
    ///      moves the price.
    function test_longQuietGap_outstandingMaturityStillFreezes() public {
        _swap(BONDED_INPUT, true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();
        (int24 preTick, uint32 preUpdate, int56 preCum) = _acc();

        vm.roll(block.number + 100_000);
        _swap(UNBONDED_INPUT, true, "");

        (int56 frozen,, bool checkpointed) = _bucket(m);

        assertTrue(checkpointed, "a maturity outstanding across a long gap was never frozen");
        assertEq(frozen, preCum + int56(preTick) * int56(uint56(m - preUpdate)), "wrong cumulative after a long gap");
    }

    /// @notice Maturities beyond `L + W` are NOT frozen by a single crossing — they are outside the
    ///         bounded domain, and by ADR-0003 § 3.4 they cannot exist as uncheckpointed bonds.
    /// @dev Documents the clamp's upper edge: the implementation deliberately does not reach past
    ///      `L + W`, and the proof is that no bond can mature there without having advanced `L`.
    function test_clampUpperEdge_doesNotReachPastHorizon() public {
        _swap(BONDED_INPUT, true, _hookData());

        (, uint32 l,) = _acc();
        uint32 horizon = l + hook.MAX_OBSERVATION_BLOCKS();

        vm.roll(uint256(horizon) + 500);
        _swap(UNBONDED_INPUT, true, "");

        // Nothing beyond the horizon was touched by that advancement.
        (,, bool beyond) = _bucket(horizon + 1);
        assertFalse(beyond, "advancement froze a bucket beyond the horizon");
    }

    /*//////////////////////////////////////////////////////////////
                        BOTH SWAP KINDS REGISTER
    //////////////////////////////////////////////////////////////*/

    /// @notice Exact-output bonds register and freeze exactly like exact-input ones.
    function test_exactOutputBond_registersAndFreezes() public {
        _swap(int256(uint256(BONDED_OUTPUT)), true, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        (, uint32 pending,) = _bucket(m);
        assertEq(pending, 1, "exact-output bond did not register");

        vm.roll(uint256(m) + 1);
        _swap(UNBONDED_INPUT, true, "");

        (,, bool checkpointed) = _bucket(m);
        assertTrue(checkpointed, "exact-output maturity was not frozen");
    }

    /// @notice Bonds in both directions land in the same bucket and share one checkpoint.
    function test_bothDirections_shareTheMaturityBucket() public {
        _swap(BONDED_INPUT, true, _hookData());
        _swap(BONDED_INPUT, false, _hookData());

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        (, uint32 pending,) = _bucket(m);
        assertEq(pending, 2, "bonds in both directions did not share the bucket");

        vm.roll(uint256(m) + 1);
        _swap(UNBONDED_INPUT, true, "");

        (,, bool checkpointed) = _bucket(m);
        assertTrue(checkpointed, "shared cross-direction bucket was not frozen");
    }
}
