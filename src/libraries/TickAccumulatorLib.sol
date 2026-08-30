// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title TickAccumulatorLib

/// @notice Maintains a time-weighted tick accumulator for each pool so BondMeBro can measure the average pool tick between bond opening and maturity without using an external oracle, observation ring buffer, or binary search.

/// @dev Uniswap v4 does not provide the built-in historical oracle observations that v3 pools exposed, so BondMeBro must maintain the information it needs inside the hook. A full v3-style observations array is useful when a protocol needs to query the cumulative tick at arbitrary historical times. BondMeBro's MVP only needs a known start point recorded when a bond opens and a fixed maturity endpoint, so two accumulator readings are enough: one at bond opening and one at maturity.

/// The accumulator does NOT make late settlement depend on the settlement block. T5 must freeze or reconstruct the accumulator value at the bond's fixed maturity checkpoint. A trader may call settlement later, but swaps after maturity must not change the result.

/// Using a time-weighted average makes settlement harder to manipulate than using only the spot tick at settlement. With spot settlement, an attacker could temporarily push the price toward a refund-friendly level, settle, and immediately unwind. With a TWA, the attacker must keep that price displacement alive for a meaningful part of the observation window, increasing the cost and exposure to arbitrage.

/// The observation window starts from the post-swap tick used when the bond opens. This can slightly bias the average toward the swap's immediate price impact because that first post-trade state is included in the window. The MVP accepts this behaviour and uses `refundToleranceTicks` to provide tolerance. A delayed warmup/sub-window design would require historical observations or another checkpoint mechanism and is outside this library's current scope.

/// Quiet pools are handled by extrapolation, not by automatic refunds. If no swap occurs after the bond opens, the last observed tick is treated as remaining active for the elapsed blocks. This means a quiet pool still produces a valid time-weighted observation instead of being treated as missing data.

library TickAccumulatorLib {
    /// @notice Thrown when a time-weighted average is requested over a zero-length interval.

    /// @dev Settlement should normally prevent this by requiring maturity before evaluating a bond, but the library still checks it directly so division by zero can never occur.
    error ZeroWindow();

    /// @notice Running tick accumulator for one pool. The fields fit in one storage slot: 24 + 32 + 56 = 112 bits.

    struct Accumulator {
        /// @dev Tick that has been active since `lastUpdate`.
        int24 lastTick;

        /// @dev Block number when the accumulator was last updated.
        uint32 lastUpdate;

        /// @dev Running sum of `tick * elapsedBlocks`. `int56` matches the width traditionally used for tick cumulative accounting and has ample range for the Uniswap tick bounds; even at the maximum absolute tick it would take roughly 4e10 blocks to approach the signed range limit.
        int56 tickCumulative;
    }

    /// @notice Adds the elapsed blocks at the previous tick, then moves the accumulator to `newTick`.

    /// @dev This function must be called for every swap in the pool, including swaps that do not post a bond. Otherwise the accumulator would miss part of the pool's price path and every bond whose observation window crosses that gap could receive a biased settlement result.

    /// The elapsed interval is always credited using `acc.lastTick`, because that is the tick that was actually active during those blocks. `newTick` only becomes active from the current update onward. Using `newTick` for the elapsed interval would incorrectly apply the new swap's price movement backward in time.

    /// Flow:
    /// 1. Measure blocks elapsed since `lastUpdate`.
    /// 2. Add `lastTick * elapsedBlocks` to `tickCumulative`.
    /// 3. Store `newTick` as the tick active from this block onward.
    /// 4. Store the current block as `lastUpdate`.

    /// @param acc Storage pointer to the pool's accumulator.
    /// @param newTick Tick that becomes active after the current swap.
    /// @return cumulative Accumulator value as of the current block.
    function update(
        Accumulator storage acc,
        int24 newTick
    )
        internal
        returns (int56 cumulative)
    {
        uint32 nowBlock = uint32(block.number);

        // First observation: there is no earlier known tick interval to credit.
        if (acc.lastUpdate == 0) {
            acc.lastTick = newTick;
            acc.lastUpdate = nowBlock;

            return acc.tickCumulative;
        }

        uint32 elapsed = nowBlock - acc.lastUpdate;

        cumulative =
            acc.tickCumulative +
            int56(acc.lastTick) * int56(uint56(elapsed));

        acc.tickCumulative = cumulative;
        acc.lastTick = newTick;
        acc.lastUpdate = nowBlock;
    }

    /// @notice Returns the accumulator value at the current block without changing storage.

    /// @dev The time since the last stored update is extrapolated using `lastTick`, because that is the most recently known tick. This is what allows quiet pools to produce a valid observation even when no swap occurs during the observation window.

    /// This function observes the current block only. If settlement happens after a bond's maturity, T5 must use the accumulator value frozen or reconstructed at the maturity checkpoint rather than calling this function and using the later settlement block directly.
    function observe(
        Accumulator memory acc
    )
        internal
        view
        returns (int56)
    {
        uint32 elapsed =
            uint32(block.number) - acc.lastUpdate;

        return
            acc.tickCumulative +
            int56(acc.lastTick) * int56(uint56(elapsed));
    }

    /// @notice Calculates the time-weighted average tick between two accumulator readings.

    /// @dev The two cumulative readings should represent the bond's opening checkpoint and its fixed maturity checkpoint. Integer division truncates toward zero, so the returned average may differ from the exact mathematical average by less than one tick.

    /// Formula:
    /// `averageTick = (cumulativeAtEnd - cumulativeAtOpen) / elapsedBlocks`

    /// @param cumulativeAtOpen Accumulator value recorded when the bond opened.
    /// @param cumulativeNow Accumulator value at the end of the observation window. For BondMeBro settlement this should be the fixed maturity checkpoint, not an arbitrarily late settlement reading.
    /// @param elapsedBlocks Number of blocks between the two readings. Must be greater than zero.
    /// @return averageTick Time-weighted average tick over the interval.
    function twaTick(
        int56 cumulativeAtOpen,
        int56 cumulativeNow,
        uint32 elapsedBlocks
    )
        internal
        pure
        returns (int24 averageTick)
    {
        if (elapsedBlocks == 0) revert ZeroWindow();

        averageTick = int24(
            (
                int256(cumulativeNow) -
                int256(cumulativeAtOpen)
            ) / int256(uint256(elapsedBlocks))
        );
    }
}