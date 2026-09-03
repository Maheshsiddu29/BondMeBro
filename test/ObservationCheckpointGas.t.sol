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

/// @title ObservationCheckpointGasTest
///
/// @notice Isolated shapes for measuring the Design 3 scheduler's cost, plus the storage-lifecycle
///         proof that the cost argument rests on.
///
/// @dev HOW TO READ THESE. Each test is ONE measured swap preceded by setup, so the `beforeSwap`
///      frame in a `-vvvv` trace belongs unambiguously to the shape named. Ceilings from
///      `AGENTS.md`: `beforeSwap < 150,000`, `afterSwap < 100,000`.
///
///      MEASURED AT P-L2-5, as `beforeSwap` / `afterSwap` CALLBACK FRAMES (not transaction gas)
///      on the final swap of each shape:
///
///          shape                                        beforeSwap    afterSwap
///          ------------------------------------------   ----------    ---------
///          A  empty advancement, no buckets                 37,947       14,272
///          B  bonded, registered bucket not yet due         68,018       41,220
///          C  one bucket, C6 only due                       30,910       14,218
///          D  one bucket, C6 + C8 due                       31,679       14,218
///          E  one bucket, all three due                     34,278       14,218
///          F  ten consecutive occupied buckets              57,629       14,218
///          G  V7.1 adversarial (L-7, L-6, L-1, L)           38,075       14,218
///          I  max occupancy + new exact-INPUT bond         107,005       41,220
///          J  max occupancy + new exact-OUTPUT bond        106,740       63,113
///          K  quiet gap 50                                  34,278       14,218
///          L  quiet gap 100,000                             34,278       14,218
///          N  consecutive buckets AND fan-in                57,629       14,218
///
///          ceiling                                        150,000      100,000
///
///      WORST DETERMINISTIC `beforeSwap` IS SHAPE I — 107,005, leaving 42,995 of headroom, close
///      to ADR-0007 § 8's projected 43,402. It is the full ten-bucket scan PLUS a provisional
///      record write, which is why it beats the scan-only shapes F and L by a wide margin: the
///      scan is not the expensive part on its own.
///
///      TWO MOVEMENTS, IN OPPOSITE DIRECTIONS, BOTH ADR-0007's DOING.
///
///      Cheaper: a long quiet gap on ONE bucket used to cost 95,559 in P-L2-3/4 and now costs
///      34,278. Production scanned to `lastUpdate + MAX_OBSERVATION_BLOCKS` (16) and paid for six
///      positions that provably cannot be occupied; this scheduler bounds by `OBSERVATION_BLOCKS`
///      (10). ADR-0007 § 3.2 predicted "14,794 gas of provably wasted work per full-horizon scan".
///
///      Dearer: the fully occupied shape rose from 102,075 to 107,005, because each occupied
///      bucket now freezes up to three endpoints instead of one. That is the price of the feature,
///      and it is paid only where there is real work to do.
///
///      GAP LENGTH BUYS AN ATTACKER NOTHING: K and L are identical to the gas unit, at 50 and
///      100,000 blocks. Neither does fan-in — see `test_gasM_fanInDoesNotChangeScanCost`, flat at
///      1 / 10 / 100 / 1,000 bonds in one maturity.
///
///      P-L2-7 RE-MEASURED: the figures above are pre-cleanup. After removing `cumulativeAtOpen`,
///      `PersistenceMathLib`, `afterInitializeCount` and the two obsolete `PoolConfig` fields,
///      `beforeSwap` fell by 127 gas everywhere and `afterSwap` rose by a uniform 222. The
///      worst-case `beforeSwap` is now 106,878 against a 150,000 ceiling; the worst `afterSwap`
///      73,447 against 100,000. See `P_L2_7_MIGRATION_REPORT.md` § 7 for the full table and for
///      what the +222 is and is not attributable to.
contract ObservationCheckpointGasTest is Test, Deployers {
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

    int256 internal constant BONDED = -1e16;
    int256 internal constant NUDGE = -1e13;

    /// @dev `maturity` is at storage slot 3.
    uint256 internal constant SLOT_MATURITY = 2;

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

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

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

    function _bucketSlot(uint32 m) internal view returns (bytes32) {
        return keccak256(abi.encode(uint256(m), keccak256(abi.encode(id_, SLOT_MATURITY))));
    }

    function _lastUpdate() internal view returns (uint32 lastUpdate) {
        // slither-disable-next-line unused-return
        (, lastUpdate,,) = hook.accumulator(id_);
    }

    /// @dev Opens `n` bonds in `n` consecutive blocks, filling `n` consecutive maturity buckets.
    function _fillConsecutiveBuckets(uint32 n) internal {
        for (uint32 i = 0; i < n; i++) {
            _swap(BONDED, true, _hookData());

            vm.roll(block.number + 1);
        }
    }

    /*//////////////////////////////////////////////////////////////
                  A-E  SINGLE BUCKET, EACH DUE COMBINATION
    //////////////////////////////////////////////////////////////*/

    /// @dev A — an advancement with no buckets registered at all. The scan's floor cost: ten empty
    ///      mapping reads and nothing else. This is what every swap on a quiet, unbonded pool pays.
    function test_gasA_emptyAdvancement() public {
        vm.roll(block.number + 20);

        _swap(NUDGE, true, "");
    }

    /// @dev B — a bonded swap with a registered bucket that has no due endpoint yet.
    function test_gasB_bondedNoDueEndpoint() public {
        _swap(BONDED, true, _hookData());

        vm.roll(block.number + 1);

        _swap(BONDED, true, _hookData());
    }

    /// @dev C — exactly one endpoint due: C6, and nothing else.
    function test_gasC_oneBucketC6Only() public {
        uint32 open = uint32(block.number);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(open) + 6);

        _swap(NUDGE, true, "");
    }

    /// @dev D — two endpoints due in one advancement, C6 and C8, into one warm slot.
    function test_gasD_oneBucketC6AndC8() public {
        uint32 open = uint32(block.number);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(open) + 8);

        _swap(NUDGE, true, "");
    }

    /// @dev E — all three endpoints of one bucket in a single advancement. The shape a
    ///      block-centric scheduler would have had to visit three times.
    function test_gasE_oneBucketAllThree() public {
        uint32 open = uint32(block.number);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(open) + hook.OBSERVATION_BLOCKS());

        _swap(NUDGE, true, "");
    }

    /*//////////////////////////////////////////////////////////////
                 F-J  MAXIMUM OCCUPANCY AND NEW BONDS
    //////////////////////////////////////////////////////////////*/

    /// @dev F/H — the maximum: ten consecutive occupied buckets, all due, in one scan.
    ///
    ///      TEN IS THE CEILING, NOT SIXTEEN, and that is a property rather than a fixture choice. A
    ///      bucket at `m` needs a bond opened at `m - OBSERVATION_BLOCKS`, and opening a bond is a
    ///      swap that sets `lastUpdate` to its own block. So distinct occupied buckets require
    ///      distinct opening blocks inside the last ten, and no scan can freeze more than ten
    ///      buckets however long the gap.
    function test_gasF_tenConsecutiveOccupiedBuckets() public {
        _fillConsecutiveBuckets(hook.OBSERVATION_BLOCKS());

        vm.roll(block.number + 100_000);

        _swap(NUDGE, true, "");
    }

    /// @dev I — maximum occupancy AND the measured swap opens a new exact-input bond, so the frame
    ///      carries the full scan plus a provisional record write.
    function test_gasI_maxOccupancyPlusNewExactInputBond() public {
        _fillConsecutiveBuckets(hook.OBSERVATION_BLOCKS());

        vm.roll(block.number + 100_000);

        _swap(BONDED, true, _hookData());
    }

    /// @dev J — the same with an exact-OUTPUT bond, which cannot use `beforeSwap`'s exact-input
    ///      pre-filter and therefore decodes hookData as well.
    function test_gasJ_maxOccupancyPlusNewExactOutputBond() public {
        _fillConsecutiveBuckets(hook.OBSERVATION_BLOCKS());

        vm.roll(block.number + 100_000);

        _swap(int256(1e16), true, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                       G  THE ADVERSARIAL ARRANGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev G — ADR-0007 § 4's brute-forced worst arrangement: openings at `L-7, L-6, L-1, L`.
    ///
    ///      FOUR CHEAP SWAPS BY AN ATTACKER, who then leaves. An unrelated later trader pays for
    ///      the resulting checkpoint work. This is the pattern that made the rejected
    ///      "separate interior buckets" design a griefing vector: under it, six of the ten frozen
    ///      blocks would have landed on FRESH slots at 22,100 gas each instead of 2,900, projecting
    ///      ~217,000 against a 150,000 ceiling.
    ///
    ///      Design 3 removes it by construction — every endpoint is a field of the maturity bucket,
    ///      and `pendingBonds` already made that slot non-zero.
    ///      `test_sstore_noEndpointFreezeEverWritesAFreshSlot` proves that directly.
    function test_gasG_v71AdversarialArrangement() public {
        _openAdversarialArrangement();

        // The victim: an unrelated trader, several blocks later, who pays for all of it.
        vm.roll(block.number + 12);

        _swap(NUDGE, true, "");
    }

    /// @dev Builds the `L-7, L-6, L-1, L` opening pattern. `L` is the cursor after the last one.
    function _openAdversarialArrangement() internal {
        uint32 base = uint32(block.number);

        // L-7
        _swap(BONDED, true, _hookData());

        // L-6
        vm.roll(uint256(base) + 1);
        _swap(BONDED, true, _hookData());

        // L-1
        vm.roll(uint256(base) + 6);
        _swap(BONDED, true, _hookData());

        // L
        vm.roll(uint256(base) + 7);
        _swap(BONDED, true, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                      K-L  QUIET-GAP INDEPENDENCE
    //////////////////////////////////////////////////////////////*/

    /// @dev K — a 50-block quiet gap.
    function test_gasK_quietGap50() public {
        uint32 open = uint32(block.number);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(open) + 50);

        _swap(NUDGE, true, "");
    }

    /// @dev L — a 100,000-block quiet gap. Must measure identically to K: the scan is clamped by
    ///      block positions, so gap length cannot buy the attacker anything.
    function test_gasL_quietGap100000() public {
        uint32 open = uint32(block.number);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(open) + 100_000);

        _swap(NUDGE, true, "");
    }

    /// @notice Scan cost does not depend on how long the pool was quiet.
    ///
    /// @dev Asserted rather than left to the reader comparing two printed numbers. If gap length
    ///      moved the cost, a pool could be griefed simply by going quiet.
    function test_scanCostIsIndependentOfQuietGapLength() public {
        uint256 baseline = vm.snapshotState();

        uint256 gas50 = _measureFlushAfterGap(50);

        vm.revertToState(baseline);

        uint256 gas100k = _measureFlushAfterGap(100_000);

        console2.log("flush after 50 blocks     ", gas50);
        console2.log("flush after 100,000 blocks", gas100k);

        assertEq(gas50, gas100k, "scan cost moved with the length of the quiet gap");
    }

    function _measureFlushAfterGap(uint256 gap) internal returns (uint256) {
        uint32 open = uint32(block.number);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(open) + gap);

        uint256 before = gasleft();

        _swap(NUDGE, true, "");

        return before - gasleft();
    }

    /*//////////////////////////////////////////////////////////////
                        M-N  FAN-IN AND MIXTURES
    //////////////////////////////////////////////////////////////*/

    /// @notice Scan cost does not depend on how many bonds share a maturity.
    ///
    /// @dev INV-L2-12 in its checkpoint form. A bucket is frozen once however many bonds it holds,
    ///      because the cumulative at a block is a property of the POOL, not of a bond. If this
    ///      failed, an attacker could inflate a victim's callback by piling bonds into one block.
    ///
    ///      Measured at 1, 10, 100 and 1,000 bonds in a single maturity.
    function test_gasM_fanInDoesNotChangeScanCost() public {
        uint32[4] memory counts = [uint32(1), 10, 100, 1_000];

        uint256[4] memory measured;

        for (uint256 i = 0; i < counts.length; i++) {
            uint256 snapshot = vm.snapshotState();

            uint32 open = uint32(block.number);

            for (uint32 j = 0; j < counts[i]; j++) {
                _swap(BONDED, true, _hookData());
            }

            (,,, uint32 pending,) = hook.maturity(id_, open + hook.OBSERVATION_BLOCKS());

            assertEq(pending, counts[i], "fan-in fixture did not register the expected bonds");

            vm.roll(uint256(open) + hook.OBSERVATION_BLOCKS());

            uint256 before = gasleft();

            _swap(NUDGE, true, "");

            measured[i] = before - gasleft();

            console2.log("fan-in bonds", counts[i]);
            console2.log("  flush gas ", measured[i]);

            vm.revertToState(snapshot);
        }

        // The 1,000-bond flush must not cost meaningfully more than the 1-bond flush. The tolerance
        // absorbs price-path differences from 1,000 real swaps moving the tick, not per-bond work:
        // anything proportional would be three orders of magnitude larger.
        assertLt(
            measured[3], measured[0] + 20_000, "INV-L2-12: scan cost grew with the number of bonds sharing a maturity"
        );
    }

    /// @dev N — consecutive buckets AND fan-in together: ten opening blocks, four bonds each.
    function test_gasN_mixedConsecutiveAndFanIn() public {
        for (uint32 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            for (uint32 j = 0; j < 4; j++) {
                _swap(BONDED, true, _hookData());
            }

            vm.roll(block.number + 1);
        }

        vm.roll(block.number + 100_000);

        _swap(NUDGE, true, "");
    }

    /*//////////////////////////////////////////////////////////////
              26  THE STORAGE-LIFECYCLE PROOF (vm.record)
    //////////////////////////////////////////////////////////////*/

    /// @notice No endpoint freeze ever performs a zero-to-non-zero write on a bucket slot.
    ///
    /// @dev THIS IS THE POINT OF DESIGN 3, AND IT IS NOT A GAS NUMBER — it is a storage lifecycle.
    ///
    ///      ADR-0007 § 4's whole argument is that interior endpoints live in the MATURITY bucket,
    ///      whose slot `pendingBonds` already made non-zero at registration. So every freeze is an
    ///      `SSTORE_RESET` (2,900) on an already-loaded slot, never an `SSTORE_SET` (22,100) on a
    ///      fresh one. The rejected alternative — separate buckets for C6 and C8 — allowed fresh
    ///      slots and projected ~217,000 gas on the arrangement below.
    ///
    ///      A gas measurement alone would not prove this: it would show a number today and say
    ///      nothing about whether a different arrangement could find a fresh slot. `vm.record` can,
    ///      by naming every slot the victim swap actually wrote and checking each was already
    ///      non-zero before it ran.
    ///
    ///      Run on ADR-0007's brute-forced worst arrangement specifically, not on a convenient one.
    function test_sstore_noEndpointFreezeEverWritesAFreshSlot() public {
        _openAdversarialArrangement();

        uint32 cursor = _lastUpdate();

        // Every bucket the coming scan can touch.
        uint32 horizon = cursor + hook.OBSERVATION_BLOCKS();

        // PRE-STATE: record which bucket slots are already non-zero, and confirm the occupied ones
        // are — that is the premise the whole cost argument rests on.
        uint256 occupiedBefore;

        for (uint32 m = cursor + 1; m <= horizon; m++) {
            (,,, uint32 pending,) = hook.maturity(id_, m);

            if (pending == 0) continue;

            occupiedBefore++;

            assertTrue(
                vm.load(address(hook), _bucketSlot(m)) != bytes32(0),
                "an occupied bucket slot was zero before the victim swap; the SSTORE_RESET argument fails"
            );
        }

        assertGt(occupiedBefore, 0, "the arrangement registered no buckets; this proves nothing");

        // THE VICTIM SWAP, recorded.
        vm.roll(block.number + 12);

        vm.record();

        _swap(NUDGE, true, "");

        (, bytes32[] memory writes) = vm.accesses(address(hook));

        // Every WRITE that lands on a bucket slot inside the horizon must be a slot that was
        // already non-zero. A write to a bucket slot that was zero is exactly the failure mode.
        uint256 bucketWrites;

        for (uint256 w = 0; w < writes.length; w++) {
            for (uint32 m = cursor + 1; m <= horizon; m++) {
                if (writes[w] != _bucketSlot(m)) continue;

                bucketWrites++;

                (,,, uint32 pendingNow,) = hook.maturity(id_, m);

                assertGt(
                    pendingNow,
                    0,
                    "a bucket slot was written for a maturity holding no bonds: a PHANTOM bucket was created"
                );
            }
        }

        assertGt(bucketWrites, 0, "the victim swap wrote no bucket slot at all; the fixture is not exercising freezes");

        console2.log("occupied buckets before the victim swap", occupiedBefore);
        console2.log("bucket-slot writes (repeats included)  ", bucketWrites);
    }

    /// @notice A scan over an entirely unregistered horizon writes no bucket slot at all.
    ///
    /// @dev The other half of the lifecycle: the scheduler must not create buckets. Without the
    ///      `pendingBonds == 0` early return, forward writes would conjure cohorts — and each one
    ///      would be a fresh-slot `SSTORE_SET`, which is both the correctness bug and the gas bug
    ///      at once.
    function test_sstore_emptyHorizonWritesNoBucketSlot() public {
        // Unbonded activity only, so nothing is ever registered.
        _swap(NUDGE, true, "");

        uint32 cursor = _lastUpdate();

        vm.roll(block.number + 6);

        vm.record();

        _swap(NUDGE, true, "");

        (, bytes32[] memory writes) = vm.accesses(address(hook));

        for (uint256 w = 0; w < writes.length; w++) {
            for (uint32 m = cursor; m <= cursor + hook.OBSERVATION_BLOCKS() + 8; m++) {
                assertTrue(
                    writes[w] != _bucketSlot(m), "a scan over an empty horizon wrote a bucket slot: PHANTOM bucket"
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                   27  ADVERSARIAL AMPLIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The victim's `beforeSwap` CALLBACK FRAME stays inside the 150,000 ceiling on the
    ///         worst arrangement an attacker can build.
    ///
    /// @dev Reports the amplification an attacker can actually buy: the ratio between an ordinary
    ///      swap's cost and that of a trader who arrives after the worst opening pattern. The bound
    ///      that matters is not the ratio but the absolute headroom, because a swap that reverts on
    ///      gas is the actual harm.
    ///
    ///      THE ASSERTION MEASURES THE CALLBACK FRAME, NOT THE WHOLE SWAP, and the distinction is
    ///      the entire point of this test. An earlier version wrapped `gasleft()` around
    ///      `swapRouter.swap(...)` and asserted the result against the `beforeSwap` ceiling. That
    ///      total also contains the router, `PoolManager.unlock`, the pool's own swap math,
    ///      `afterSwap` and token settlement -- none of which the 150,000 limit governs.
    ///
    ///      It is the wrong direction for an assertion. A PASS is sound (a superset under the
    ///      limit implies the subset is), but a FAIL says nothing about the callback at all. And it
    ///      failed for exactly that reason: under `forge coverage`, which builds WITHOUT the
    ///      optimizer, the whole-swap figure inflates past 150,000 while the callback itself is
    ///      unchanged -- turning an environment artifact into a false production gas alarm.
    ///      P-L2-8 § 4 records the same mistake being made and corrected once already.
    ///
    ///      `vm.lastCallGas()` reports the callee-side gas of the last CALL, so invoking
    ///      `beforeSwap` directly -- pranked as the `PoolManager`, which is what `onlyPoolManager`
    ///      checks -- measures precisely the frame the ceiling is written about. The hook state is
    ///      the real post-attack state, built by the same `_fillConsecutiveBuckets` arrangement, so
    ///      the scan this frame performs is the scan the victim would have paid for.
    ///
    ///      The 150,000 threshold is UNCHANGED. Only the quantity compared against it is.
    function test_adversarial_victimCallbackStaysInsideTheCeiling() public {
        // WARM THE POOL FIRST, in both arms. Without this the baseline is the pool's very first
        // swap and pays cold-storage costs everywhere -- measured, it came out HIGHER than the
        // victim's, giving a meaningless amplification below 1. What the attacker can buy is the
        // difference between two warm swaps, so both arms start warm.
        _swap(NUDGE, true, "");

        vm.roll(block.number + 2);

        _swap(NUDGE, true, "");

        uint256 baseline = vm.snapshotState();

        // Baseline: an unrelated swap on a warm pool with nothing outstanding.
        vm.roll(block.number + 12);

        uint256 before = gasleft();

        _swap(NUDGE, true, "");

        uint256 baselineGas = before - gasleft();

        vm.revertToState(baseline);

        // Worst arrangement, then the victim.
        _fillConsecutiveBuckets(hook.OBSERVATION_BLOCKS());

        vm.roll(block.number + 100_000);

        // MEASURED BEFORE THE VICTIM'S SWAP RUNS, and the order is load-bearing. `beforeSwap`
        // freezes the checkpoints it scans, so a frame measured AFTER the victim swap finds the
        // work already done and reports a few thousand gas -- which would be a silently vacuous
        // assertion. `_measureBeforeSwapFrame` snapshots and restores, so the arrangement below is
        // untouched.
        (uint256 victimBeforeSwapFrame, uint256 victimFrameCalleeSide) = _measureBeforeSwapFrame();

        before = gasleft();

        _swap(NUDGE, true, "");

        uint256 victimGas = before - gasleft();

        console2.log("baseline whole swap gas   ", baselineGas);
        console2.log("victim   whole swap gas   ", victimGas);
        console2.log("amplification x100        ", (victimGas * 100) / baselineGas);
        console2.log("victim beforeSwap FRAME   ", victimBeforeSwapFrame);
        console2.log("  (callee-side figure)    ", victimFrameCalleeSide);
        console2.log("ceiling                   ", uint256(150_000));

        assertLt(victimBeforeSwapFrame, 150_000, "the victim's beforeSwap CALLBACK exceeded its ceiling");
    }

    /// @dev The `beforeSwap` callback frame, in isolation, against the hook's CURRENT state.
    ///
    ///      Pranked as the `PoolManager` because that is the only thing `BaseHook.onlyPoolManager`
    ///      checks. `beforeSwap` reads `getSlot0` (a view) and writes only hook storage -- it takes
    ///      no currency and returns no delta -- so it is well-defined outside `unlock`, which is
    ///      what makes this measurement possible at all. `afterSwap` would NOT be, since it
    ///      settles tokens.
    ///
    ///      Deliberately UNBONDED (`NUDGE`, empty hookData): the ceiling is set by the checkpoint
    ///      scan, and this isolates it from bond-record writes. A state snapshot is taken and
    ///      restored so the measurement leaves the caller's arrangement untouched.
    function _measureBeforeSwapFrame() internal returns (uint256 charged, uint256 calleeSide) {
        uint256 snap = vm.snapshotState();

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: NUDGE, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        // The prank is set up OUTSIDE the measured window so its own cost is not counted.
        vm.prank(address(manager));

        uint256 g0 = gasleft();

        // slither-disable-next-line unused-return
        hook.beforeSwap(address(swapRouter), key_, params, "");

        charged = g0 - gasleft();

        // TWO FIGURES, AND THEY ARE NOT THE SAME NUMBER. `lastCallGas` reports the CALLEE-side
        // execution; the `gasleft()` delta is what the CALLER is charged, which additionally
        // carries the CALL opcode and this frame's calldata/memory expansion. The traces the
        // 106,878 / 107,543 ceilings were read from show the CALLER-charged figure, so that is the
        // one asserted -- it is the larger of the two and the conservative choice.
        calleeSide = vm.lastCallGas().gasTotalUsed;

        vm.revertToState(snap);
    }
}
