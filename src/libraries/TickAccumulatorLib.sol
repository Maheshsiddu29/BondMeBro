// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title TickAccumulatorLib
/// @notice Keeps a running, block-weighted price record for each pool.
/// @dev We add tick * elapsed blocks whenever the pool is updated. For example,
/// tick 20 lasting three blocks adds 60 tick-blocks. Subtracting two cumulative
/// readings gives the tick-blocks between them; dividing by elapsed blocks gives
/// the average tick.
///
/// The hook saves readings at opening block + 6, + 8 and + 10 for settlement.
/// This library does not store a full price history. Due checkpoints must be saved
/// before a new swap replaces the tick that was active across their interval.
///
/// A quiet pool carries its last observed tick forward. That means the pool price
/// is treated as unchanged, not that the bond is automatically refunded. Time here
/// is measured in blocks, not seconds. Callers must keep block numbers within
/// uint32 and use valid Uniswap ticks.
library TickAccumulatorLib {
    /// @notice An average requires at least one elapsed block; zero would divide by zero.
    error ZeroWindow();

    /// @notice The requested block is before the retained history or after the current block.
    /// @dev This compact record cannot answer arbitrary historical or future queries.
    /// @param atBlock Requested observation block.
    /// @param lastUpdate Earliest block derivable from the current accumulator.
    /// @param currentBlock Latest block that can be observed.
    error BlockOutOfDomain(uint32 atBlock, uint32 lastUpdate, uint256 currentBlock);

    /// @notice Pool tick, update block, block-start tick and cumulative, packed into one slot.
    /// @dev The fields use 136 of 256 bits. int24 represents Uniswap ticks; uint32 stores
    /// block numbers; int56 has room for about 4e10 blocks at the maximum absolute tick.
    /// Sharing one slot keeps repeated reads and writes small on the swap path.
    struct Accumulator {
        /// @dev Tick active since lastUpdate, in ticks.
        int24 lastTick;

        /// @dev Last accumulator update block. Zero is the uninitialized marker.
        /// This also identifies whether the current block has already been processed,
        /// so a separate blockNumber field is unnecessary.
        uint32 lastUpdate;

        /// @dev Pool tick before the first swap in the current block.
        /// beginBlock captures it before lastUpdate advances. Later swaps in that block
        /// keep the same baseline, even when update replaces lastTick. It is used for
        /// block-wide collateral sizing, not as settlement's opening-tick baseline.
        int24 blockStartTick;

        /// @dev Running sum of tick * elapsed blocks, in tick-blocks.
        int56 tickCumulative;
    }

    /// @notice Captures the tick used as the starting price for the current block.
    /// @dev Call this before update advances lastUpdate and before the swap replaces
    /// lastTick. Otherwise the new-block check would fail or the starting price would
    /// already include the first swap's movement.
    ///
    /// Later swaps in the same block leave the starting tick unchanged. On a new
    /// block we use the last observed tick, including across quiet blocks. The hook
    /// advances lastUpdate on every swap, bonded or not, which makes this check work.
    /// @param acc Pool accumulator in storage.
    /// @param currentTick Initialization tick if the accumulator has no previous update.
    function beginBlock(Accumulator storage acc, int24 currentTick) internal {
        if (acc.lastUpdate == 0) {
            acc.blockStartTick = currentTick;

            return;
        }

        if (acc.lastUpdate < uint32(block.number)) {
            acc.blockStartTick = acc.lastTick;
        }
    }

    /// @notice Adds the elapsed interval at the old tick, then records the new active tick.
    /// @dev The old tick, not newTick, describes the blocks that already passed.
    /// For example, switching from tick 20 to tick 30 after three blocks adds
    /// 20 * 3 = 60 tick-blocks, not 30 * 3.
    ///
    /// The hook calls this before a swap to account for elapsed blocks and after it
    /// to record the executed price. Unbonded swaps must update it too. First use
    /// seeds the record without inventing earlier history. blockStartTick is unchanged.
    /// @param acc Pool accumulator in storage.
    /// @param newTick Tick active from this update onward.
    /// @return cumulative Tick cumulative at the current block, in tick-blocks.
    function update(Accumulator storage acc, int24 newTick) internal returns (int56 cumulative) {
        uint32 nowBlock = uint32(block.number);

        if (acc.lastUpdate == 0) {
            acc.lastTick = newTick;
            acc.lastUpdate = nowBlock;

            return acc.tickCumulative;
        }

        uint32 elapsed = nowBlock - acc.lastUpdate;

        cumulative = acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));

        acc.tickCumulative = cumulative;
        acc.lastTick = newTick;
        acc.lastUpdate = nowBlock;
    }

    /// @notice Reads the current block's cumulative without changing storage.
    /// @dev Carries lastTick forward through the quiet interval since lastUpdate.
    /// This is a current reading, not a maturity checkpoint. Late settlement must use
    /// the saved or exactly reconstructed C6, C8 and C10 values instead of this value.
    /// @param acc Snapshot of the pool accumulator.
    /// @return Current tick cumulative in tick-blocks.
    function observe(Accumulator memory acc) internal view returns (int56) {
        uint32 elapsed = uint32(block.number) - acc.lastUpdate;

        return acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));
    }

    /// @notice Reads a cumulative at a block still covered by the unchanged last tick.
    /// @dev Valid only when lastUpdate <= atBlock <= block.number. In that range,
    /// carrying lastTick forward is exact because any intervening swap would have
    /// advanced lastUpdate. Earlier history is not stored; future values are unknown.
    /// Both out-of-range cases revert instead of returning a guess.
    /// @param acc Accumulator snapshot.
    /// @param atBlock Requested checkpoint block.
    /// @return cumulative Tick cumulative at atBlock, in tick-blocks.
    function cumulativeAt(Accumulator memory acc, uint32 atBlock) internal view returns (int56 cumulative) {
        if (atBlock < acc.lastUpdate || uint256(atBlock) > block.number) {
            revert BlockOutOfDomain(atBlock, acc.lastUpdate, block.number);
        }

        uint32 elapsed = atBlock - acc.lastUpdate;

        return acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));
    }

    /// @notice Calculates a time-weighted average tick from two cumulative readings.
    /// @dev Time-weighted average (TWA) here means weighted by elapsed blocks.
    /// The formula is (end cumulative - start cumulative) / elapsedBlocks, with
    /// division rounded toward zero. Inputs must describe a valid tick interval.
    ///
    /// This general helper is not used to calculate production settlement. Settlement
    /// subtracts its opening baseline in tick-blocks before dividing each late window;
    /// changing that order can change integer rounding.
    /// @param cumulativeAtOpen Start reading for the chosen interval, in tick-blocks.
    /// @param cumulativeNow End reading for the same interval, in tick-blocks.
    /// @param elapsedBlocks Number of blocks between readings; must be positive.
    /// @return averageTick Average tick over the interval.
    function twaTick(int56 cumulativeAtOpen, int56 cumulativeNow, uint32 elapsedBlocks)
        internal
        pure
        returns (int24 averageTick)
    {
        if (elapsedBlocks == 0) revert ZeroWindow();

        averageTick = int24((int256(cumulativeNow) - int256(cumulativeAtOpen)) / int256(uint256(elapsedBlocks)));
    }
}
