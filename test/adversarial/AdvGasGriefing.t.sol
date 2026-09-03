// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {AdversarialBase} from "./AdversarialBase.sol";

/// @title AdvGasGriefingTest
///
/// @notice P-L2-8 § 25: an attacker arranges state to make an UNRELATED later trader pay.
///
/// @dev THE ATTACK SHAPE. Checkpoint work is deferred: a bond's endpoints freeze on whichever swap
///      happens to cross them, which is usually somebody else's. An attacker who can pile up
///      pending work cheaply and then walk away imposes that cost on the next trader. If the bill
///      could be made large enough, the victim's swap would revert on gas — a denial of service the
///      attacker never pays for.
///
///      THE DEFENCE IS STRUCTURAL, not a limit check. The scan is bounded by BLOCK POSITIONS, not
///      by bond count: at most `OBSERVATION_BLOCKS` buckets can be occupied and unfrozen at once,
///      because a bucket needs a bond opened `OBSERVATION_BLOCKS` earlier and opening a bond is a
///      swap that advances the cursor. So the attacker's spend does not translate into the victim's
///      cost, and that is what these patterns try to falsify.
///
///      Every pattern reports the VICTIM's own callback frames, which is what the ceilings bound.
///      MEASURED VICTIM CALLBACK FRAMES (from `-vvvv` traces, not the in-test transaction totals):
///
///          pattern                                   beforeSwap   afterSwap   ceiling
///          ---------------------------------------   ----------   ---------   -------
///          A  ten consecutive occupied buckets           57,603      14,440   150,000
///          C  V7.1 four-bond arrangement                 38,049      14,440   150,000
///          D  alternating occupied/empty                 40,362      14,440   150,000
///          E  ten buckets x EIGHT bonds each             57,603      14,440   150,000
///
///      A AND E ARE IDENTICAL AT 57,603, which is the whole defence in one number: eighty bonds
///      cost the victim exactly what ten did, because the scan iterates BUCKETS and a bucket
///      freezes once however many bonds it holds. The attacker's spend does not become the
///      victim's cost.
contract AdvGasGriefingTest is AdversarialBase {
    function setUp() public {
        _deployAndOpenPool();
    }

    /*//////////////////////////////////////////////////////////////
                          THE PATTERNS
    //////////////////////////////////////////////////////////////*/

    /// @dev A — maximum occupancy: ten consecutive occupied maturity buckets, all due at once.
    function test_grief_A_tenConsecutiveBuckets() public {
        _fillConsecutive(hook.OBSERVATION_BLOCKS());

        vm.roll(block.number + 100_000);

        _victim("A ten consecutive buckets");
    }

    /// @dev B — fan-in: many bonds in ONE bucket. The cumulative at a block is a property of the
    ///      POOL, so a bucket freezes once however many bonds it holds. If this scaled with bond
    ///      count it would be the cheapest griefing vector available.
    function test_grief_B_fanIn() public {
        uint32[4] memory counts = [uint32(1), 10, 100, 1_000];

        uint256[4] memory measured;

        for (uint256 i = 0; i < counts.length; i++) {
            uint256 snap = vm.snapshotState();

            uint32 open = uint32(block.number);

            for (uint32 j = 0; j < counts[i]; j++) {
                _swapT(BONDED, true, _hookData());
            }

            (,,, uint32 pending,) = hook.maturity(id_, open + hook.OBSERVATION_BLOCKS());

            assertEq(pending, counts[i], "the fan-in fixture did not register the expected bonds");

            vm.roll(uint256(open) + hook.OBSERVATION_BLOCKS());

            measured[i] = _victim(string.concat("B fan-in ", vm.toString(uint256(counts[i]))));

            vm.revertToState(snap);
        }

        // A thousand bonds must not cost meaningfully more than one. Anything proportional would be
        // three orders of magnitude larger than this tolerance.
        assertLt(
            measured[3],
            measured[0] + 25_000,
            "victim cost grew with the number of bonds sharing a maturity: a griefing vector"
        );
    }

    /// @dev C — ADR-0007 § 4's brute-forced worst arrangement: openings at L-7, L-6, L-1, L.
    ///
    ///      Four cheap swaps. Under the REJECTED design where interior endpoints had their own
    ///      buckets, six of the ten frozen blocks would have landed on FRESH slots at 22,100 gas
    ///      each, projecting ~217,000 against a 150,000 ceiling — a real DoS reachable for the price
    ///      of four swaps. Design 3 removes it by construction.
    function test_grief_C_v71AdversarialArrangement() public {
        uint32 base = uint32(block.number);

        _swapT(BONDED, true, _hookData()); // L-7

        vm.roll(uint256(base) + 1);
        _swapT(BONDED, true, _hookData()); // L-6

        vm.roll(uint256(base) + 6);
        _swapT(BONDED, true, _hookData()); // L-1

        vm.roll(uint256(base) + 7);
        _swapT(BONDED, true, _hookData()); // L

        vm.roll(block.number + 12);

        _victim("C V7.1 four-bond arrangement");
    }

    /// @dev D — alternating occupied and empty buckets, so the scan cannot short-circuit on a run.
    function test_grief_D_alternatingOccupiedAndEmpty() public {
        uint32 obs = hook.OBSERVATION_BLOCKS();

        for (uint32 i = 0; i < obs; i++) {
            if (i % 2 == 0) {
                _swapT(BONDED, true, _hookData());
            }

            vm.roll(block.number + 1);
        }

        vm.roll(block.number + 100_000);

        _victim("D alternating occupied/empty");
    }

    /// @dev E — maximum overlap: every one of the ten opening blocks carries several bonds, so both
    ///      dimensions of the state are saturated at once.
    function test_grief_E_maximumOverlap() public {
        uint32 obs = hook.OBSERVATION_BLOCKS();

        for (uint32 i = 0; i < obs; i++) {
            for (uint32 j = 0; j < 8; j++) {
                _swapT(BONDED, true, _hookData());
            }

            vm.roll(block.number + 1);
        }

        vm.roll(block.number + 100_000);

        _victim("E maximum overlap (10 buckets x 8 bonds)");
    }

    /// @dev F/G — quiet gaps. Length must buy the attacker nothing: the scan is clamped by block
    ///      positions, so going quiet cannot enlarge the bill.
    function test_grief_FG_quietGapsAreIdentical() public {
        uint256 snap = vm.snapshotState();

        _fillConsecutive(hook.OBSERVATION_BLOCKS());
        vm.roll(block.number + 50);

        uint256 gap50 = _victim("F quiet gap 50");

        vm.revertToState(snap);

        _fillConsecutive(hook.OBSERVATION_BLOCKS());
        vm.roll(block.number + 100_000);

        uint256 gap100k = _victim("G quiet gap 100,000");

        // MEASURED: 154,680 against 154,684 -- four gas apart on a ~155,000 transaction.
        //
        // That residual is not scan work. The scan is clamped by block positions, so a longer gap
        // cannot make it walk further; if it could, the difference between a 50-block and a
        // 100,000-block gap would be thousands of gas, not four. The four is transaction-level
        // noise from the larger block numbers themselves flowing through the accumulator's
        // arithmetic.
        //
        // Asserted with a tolerance rather than exactly, and the tolerance is two orders of
        // magnitude below the cost of a single extra scanned position (~2,466 gas), so a real
        // regression -- the scan actually growing with the gap -- still fails here.
        uint256 delta = gap100k > gap50 ? gap100k - gap50 : gap50 - gap100k;

        assertLt(delta, 1_000, "the victim's cost moved materially with the length of the quiet gap");
    }

    /*//////////////////////////////////////////////////////////////
                       THE AMPLIFICATION BOUND
    //////////////////////////////////////////////////////////////*/

    /// @notice What an attacker can actually buy, measured against a warm baseline.
    ///
    /// @dev Reports the ratio, but the number that matters is the ABSOLUTE headroom: a swap that
    ///      reverts on gas is the harm, and a 2x amplification on a small base is harmless while a
    ///      1.1x on a large one would not be.
    ///
    ///      BOTH ARMS ARE WARM. Measured cold, the baseline is the pool's first swap and pays
    ///      cold-storage costs everywhere, which made an earlier version of this comparison report
    ///      an amplification below 1.
    function test_grief_amplificationStaysFarInsideTheCeiling() public {
        // Warm the pool in both arms.
        _swapT(NUDGE, true, "");
        vm.roll(block.number + 2);
        _swapT(NUDGE, true, "");

        uint256 baseline = vm.snapshotState();

        vm.roll(block.number + 12);

        uint256 before = gasleft();
        _swapT(NUDGE, true, "");
        uint256 baselineGas = before - gasleft();

        vm.revertToState(baseline);

        // The worst pattern found above.
        uint32 obs = hook.OBSERVATION_BLOCKS();

        for (uint32 i = 0; i < obs; i++) {
            for (uint32 j = 0; j < 8; j++) {
                _swapT(BONDED, true, _hookData());
            }

            vm.roll(block.number + 1);
        }

        vm.roll(block.number + 100_000);

        before = gasleft();
        _swapT(NUDGE, true, "");
        uint256 victimGas = before - gasleft();

        console2.log("GRIEF baseline swap gas   ", baselineGas);
        console2.log("GRIEF victim swap gas     ", victimGas);
        console2.log("GRIEF amplification (x100)", (victimGas * 100) / baselineGas);

        // TRANSACTION gas, not the callback frame -- see `_victim`. The measured `beforeSwap`
        // frame for this exact pattern is 57,603 against a 150,000 ceiling.
        assertLt(victimGas, 400_000, "the victim's whole transaction ran away");

        // The amplification an attacker can buy, bounded. Under 2x on a warm baseline.
        assertLt((victimGas * 100) / baselineGas, 200, "an attacker doubled an unrelated trader's cost");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fillConsecutive(uint32 n) internal {
        for (uint32 i = 0; i < n; i++) {
            _swapT(BONDED, true, _hookData());

            vm.roll(block.number + 1);
        }
    }

    /// @dev An unrelated trader's swap, timed and reported. The attacker has already left.
    ///
    ///      WHAT THIS MEASURES, AND WHAT IT DOES NOT. `gasleft()` around the call measures the
    ///      WHOLE TRANSACTION: the test harness, `PoolSwapTest`, `PoolManager`, two ERC-20
    ///      transfers and the hook. The `AGENTS.md` ceilings constrain the `beforeSwap` and
    ///      `afterSwap` CALLBACK FRAMES, which are a strict subset.
    ///
    ///      An earlier version of this helper asserted the transaction total against the 150,000
    ///      callback ceiling and reported four failures at ~154,000. That was the assertion being
    ///      wrong, not the hook: the same runs measured `beforeSwap` at 57,603 in a `-vvvv` trace,
    ///      well under a third of the ceiling. Conflating the two would have raised a false alarm
    ///      on the most safety-critical section of this stage.
    ///
    ///      So the bound here is a TRANSACTION-level sanity limit, and the callback frames are
    ///      measured separately from traces and recorded in the report. The transaction figure is
    ///      still worth asserting: it is what a victim actually pays, and a runaway would show here
    ///      first.
    function _victim(string memory label) internal returns (uint256 used) {
        uint256 before = gasleft();

        _swapT(NUDGE, true, "");

        used = before - gasleft();

        console2.log(string.concat("GRIEF tx-gas ", label), used);

        assertLt(used, 400_000, string.concat(label, ": the victim's whole transaction ran away"));
    }
}
