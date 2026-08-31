// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TickAccumulatorLib} from "../src/libraries/TickAccumulatorLib.sol";
import {PersistenceMathLib} from "../src/libraries/PersistenceMathLib.sol";

/// @dev Thin harness: the library writes to a storage pointer, so it needs a stateful host.
contract AccumulatorHost {
    using TickAccumulatorLib for TickAccumulatorLib.Accumulator;

    TickAccumulatorLib.Accumulator internal acc;

    function update(int24 newTick) external returns (int56) {
        return acc.update(newTick);
    }

    function observe() external view returns (int56) {
        return TickAccumulatorLib.observe(acc);
    }

    function lastTick() external view returns (int24) {
        return acc.lastTick;
    }

    function lastUpdate() external view returns (uint32) {
        return acc.lastUpdate;
    }

    /// @dev External wrapper: vm.expectRevert only intercepts external calls, so a pure
    ///      internal library revert cannot be asserted without a boundary like this.
    function twa(int56 open, int56 current, uint32 elapsed) external pure returns (int24) {
        return TickAccumulatorLib.twaTick(open, current, elapsed);
    }

    /// @dev External wrapper for the T5.1 Stage 3 helper, for the same reason as `twa`.
    function cumulativeAt(uint32 atBlock) external view returns (int56) {
        return TickAccumulatorLib.cumulativeAt(acc, atBlock);
    }
}

contract TickAccumulatorLibTest is Test {
    AccumulatorHost internal host;

    function setUp() public {
        host = new AccumulatorHost();
        vm.roll(1000); // avoid block 0, where lastUpdate == 0 means "uninitialised"
    }

    /// @notice A tick held flat for the whole window must average to itself.
    function test_flatTick_TwaEqualsTick() public {
        host.update(100); // seed
        int56 open = host.observe();

        vm.roll(block.number + 10);
        int56 nowC = host.observe();

        assertEq(TickAccumulatorLib.twaTick(open, nowC, 10), int24(100));
    }

    /// @notice Quiet pool: no swaps at all during the window. Extrapolation must hold the
    ///         last tick, so the TWA equals tickAfter and the bond slashes fully. This is
    ///         the correct answer under the thesis — price moved, nobody reverted it — and
    ///         it is why there is no "invalid reference -> auto-refund" branch to grind.
    function test_quietPool_TwaHoldsLastTick_AndSlashes() public {
        host.update(950); // the swap set tick to 950, then silence
        int56 open = host.observe();

        vm.roll(block.number + 5);
        int24 twa = TickAccumulatorLib.twaTick(open, host.observe(), 5);

        assertEq(twa, int24(950));
        assertEq(PersistenceMathLib.computeBps(1000, 950, twa, 5), 10_000, "quiet pool must slash");
    }

    /// @notice Averaging works over multiple segments with unequal durations.
    function test_multiSegmentAverage() public {
        host.update(100);
        int56 open = host.observe();

        vm.roll(block.number + 4); // 4 blocks at tick 100
        host.update(200);
        vm.roll(block.number + 6); // 6 blocks at tick 200

        int24 twa = TickAccumulatorLib.twaTick(open, host.observe(), 10);
        assertEq(twa, int24(160)); // (4*100 + 6*200) / 10
    }

    /// @notice The elapsed interval is credited at the tick that was live during it, not at
    ///         the new tick — otherwise a swap's impact is attributed backwards in time.
    function test_creditsOldTickNotNew() public {
        host.update(100);
        int56 open = host.observe();

        vm.roll(block.number + 10);
        host.update(9999); // huge move at the very end of the window

        // The 10 elapsed blocks were lived at tick 100, so the average is still 100.
        assertEq(TickAccumulatorLib.twaTick(open, host.observe(), 10), int24(100));
    }

    /// @notice The reason spot settlement was removed. An attacker who pushes the price back
    ///         for one block out of a ten-block window recovers only a fraction of the bond,
    ///         where spot settlement would have handed back the lot.
    function test_shortManipulationIsDiluted() public {
        host.update(950); // post-swap tick
        int56 open = host.observe();

        vm.roll(block.number + 9); // 9 quiet blocks at 950
        host.update(1000); // attacker pushes fully back to tickBefore
        vm.roll(block.number + 1); // held for exactly 1 block
        int24 twa = TickAccumulatorLib.twaTick(open, host.observe(), 10);

        uint16 twaResult = PersistenceMathLib.computeBps(1000, 950, twa, 5);
        uint16 spotResult = PersistenceMathLib.computeBps(1000, 950, 1000, 5);

        assertEq(spotResult, 0, "spot settlement would refund the whole bond");
        assertGt(twaResult, 8_000, "TWA must still slash most of it");

        console2.log("TWA tick after 1/10 blocks manipulated:", twa);
        console2.log("persistence under TWA (bps): ", twaResult);
        console2.log("persistence under spot (bps):", spotResult);
    }

    /// @notice Sustained manipulation still works — TWA raises the cost, it does not remove
    ///         the attack. Holding the push for most of the window recovers most of the bond.
    function test_sustainedManipulationStillWorks_KnownLimitation() public {
        host.update(950);
        int56 open = host.observe();

        vm.roll(block.number + 1);
        host.update(1000); // pushed back immediately
        vm.roll(block.number + 9); // and held for 9 of 10 blocks

        int24 twa = TickAccumulatorLib.twaTick(open, host.observe(), 10);
        assertLt(PersistenceMathLib.computeBps(1000, 950, twa, 5), 2_000);
    }

    /// @notice A zero-length window must revert rather than divide by zero. Unreachable
    ///         through settleBond (maturity is enforced first), but the library is reusable
    ///         surface and must be safe for any caller.
    function test_twaTick_RevertsOnZeroWindow() public {
        vm.expectRevert(TickAccumulatorLib.ZeroWindow.selector);
        host.twa(int56(0), int56(100), 0);
    }

    /// @notice `update` must roll `lastTick` forward, otherwise every later extrapolation
    ///         would be anchored to a stale tick and silently skew the TWA.
    function test_update_RollsLastTickForward() public {
        host.update(100);
        assertEq(host.lastTick(), int24(100));

        vm.roll(block.number + 3);
        host.update(250);
        assertEq(host.lastTick(), int24(250), "lastTick not rolled forward");
    }

    function testFuzz_TwaWithinTickRange(int16 a, int16 b, uint8 blocksAtA, uint8 blocksAtB) public {
        vm.assume(blocksAtA > 0 && blocksAtB > 0);

        host.update(int24(a));
        int56 open = host.observe();

        vm.roll(block.number + blocksAtA);
        host.update(int24(b));
        vm.roll(block.number + blocksAtB);

        uint32 total = uint32(blocksAtA) + uint32(blocksAtB);
        int24 twa = TickAccumulatorLib.twaTick(open, host.observe(), total);

        int24 lo = a < b ? int24(a) : int24(b);
        int24 hi = a < b ? int24(b) : int24(a);
        assertGe(twa, lo - 1); // -1/+1 absorbs truncation toward zero
        assertLe(twa, hi + 1);
    }

    /*//////////////////////////////////////////////////////////////
                   cumulativeAt — the Stage 3 helper
    //////////////////////////////////////////////////////////////*/

    /// @notice `cumulativeAt` generalises `observe` to any block inside its domain, which is what
    ///         lets a maturity checkpoint freeze at the exact maturity block rather than at
    ///         whichever block the crossing swap happened to land on.
    function test_cumulativeAt_matchesObserveAtTheCurrentBlock() public {
        host.update(100);

        vm.roll(block.number + 20);

        assertEq(host.cumulativeAt(uint32(block.number)), host.observe(), "cumulativeAt disagrees with observe");
    }

    /// @notice Interior points extrapolate the stored tick exactly.
    function test_cumulativeAt_extrapolatesInteriorBlocks() public {
        host.update(100);

        uint32 start = host.lastUpdate();

        vm.roll(block.number + 50);

        // Seven blocks after the cursor, at a constant tick of 100.
        assertEq(host.cumulativeAt(start + 7), int56(700), "interior extrapolation is wrong");

        // And the cursor itself credits nothing.
        assertEq(host.cumulativeAt(start), int56(0), "the cursor block should credit no time");
    }

    /// @notice Blocks before the cursor are REJECTED, not extrapolated.
    ///
    /// @dev The domain guard matters more than it looks. Below `lastUpdate` the accumulator keeps
    ///      no history, so answering would mean extrapolating backwards using the WRONG tick and
    ///      returning a plausible but false number. Reverting is what stops this helper becoming a
    ///      historical oracle — the checkpoint design depends on values being captured while they
    ///      are still knowable, never reconstructed afterwards.
    function test_cumulativeAt_rejectsBlocksBeforeTheCursor() public {
        host.update(100);

        vm.roll(block.number + 10);
        host.update(200);

        uint32 cursor = host.lastUpdate();

        vm.expectRevert(
            abi.encodeWithSelector(TickAccumulatorLib.BlockOutOfDomain.selector, cursor - 1, cursor, block.number)
        );
        host.cumulativeAt(cursor - 1);
    }

    /// @notice Future blocks are rejected: the helper must not invent time that has not elapsed.
    function test_cumulativeAt_rejectsFutureBlocks() public {
        host.update(100);

        uint32 future = uint32(block.number) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                TickAccumulatorLib.BlockOutOfDomain.selector, future, host.lastUpdate(), block.number
            )
        );
        host.cumulativeAt(future);
    }

    /// @notice A negative tick accumulates downward, and the helper handles the sign correctly.
    function testFuzz_cumulativeAt_isLinearInElapsedBlocks(int16 rawTick, uint8 rawOffset) public {
        int24 tick = int24(rawTick);

        host.update(tick);

        uint32 start = host.lastUpdate();
        uint32 offset = uint32(rawOffset);

        vm.roll(block.number + 256);

        assertEq(
            host.cumulativeAt(start + offset),
            int56(tick) * int56(uint56(offset)),
            "cumulativeAt is not linear in elapsed blocks"
        );
    }
}
