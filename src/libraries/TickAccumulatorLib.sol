// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TickAccumulatorLib
/// @notice A time-weighted average tick over `[bondOpen, settle]`, using a single running
///         accumulator per pool — no observations ring buffer and no binary search.
///
/// @dev WHY THIS SHAPE. Uniswap v4 removed the built-in oracle that v3 pools carried, so
///      there is no pool-internal history to read; a hook must accumulate it itself. The
///      obvious approach — a v3-style 65535-slot observations array plus binary search — is
///      what you need if you want the cumulative at an *arbitrary past block*, e.g. to
///      average over a delayed sub-window `[open + warmup, open + N]`. BondMeBro does not
///      need that, because it only ever averages over one interval whose start it can record
///      at the time: the moment the bond opened. Two readings of one accumulator suffice.
///
///      WHAT IT BUYS. Spot settlement makes push-settle-unwind atomic and, because the
///      persistence curve is linear, pushing price back k% of the way recovers k% of the
///      bond at a cost of roughly a k-sized round trip. A TWA removes the atomicity: the
///      attacker must hold the distorted price across a real fraction of the window, bleeding
///      to arbitrageurs every block, for a payoff that is only proportional to the fraction
///      of the window they sustained.
///
///      KNOWN BIAS. The window starts at `tickAfter`, which under the persistence rule is the
///      maximum-harm anchor, so including the immediate post-trade period drags the average
///      toward slashing. The bias is bounded, one-directional, shrinks as N grows, and can be
///      offset with `refundToleranceTicks`. Correcting it properly requires the warmup window
///      and therefore the ring buffer — that is production scope, not MVP.
///
///      QUIET POOLS ARE NOT A SPECIAL CASE. If nobody swaps during the window, extrapolation
///      holds the last tick for the whole interval, so the TWA equals `tickAfter` and the bond
///      slashes fully. That is the correct answer under the thesis, not an error condition:
///      the price moved and no arbitrageur found it worth reverting. Do NOT add an
///      "invalid reference -> auto-refund" branch; it would be a free, grindable exit that is
///      cheapest in exactly the thin pools this mechanism targets.
library TickAccumulatorLib {
    /// @notice Thrown when a TWA is requested over a zero-length window.
    /// @dev Unreachable via settleBond, which enforces maturity first, but the library is
    ///      public surface and must not divide by zero for any caller.
    error ZeroWindow();

    /// @notice One accumulator per pool. Packs into a single storage slot
    ///         (24 + 32 + 56 = 112 bits).
    struct Accumulator {
        /// @dev Tick that has been live since `lastUpdate`.
        int24 lastTick;
        /// @dev Block number of the most recent update.
        uint32 lastUpdate;
        /// @dev Running sum of tick * blocks. int56 matches v3's tickCumulative width and
        ///      cannot realistically overflow: |tick| <= 887272, so it takes ~4e10 blocks
        ///      at the extreme tick to approach int56's range.
        int56 tickCumulative;
    }

    /// @notice Credits the elapsed interval and rolls the accumulator forward to `newTick`.
    /// @dev MUST be called on every swap in the pool, not only bonded ones — a gap in the
    ///      accumulator silently biases every bond whose window spans it. Correctness detail:
    ///      the elapsed interval is credited at `acc.lastTick`, the tick that was actually
    ///      live during it, NOT at `newTick`. Crediting the new tick would attribute the swap's
    ///      own impact backwards over time it had not yet occurred.
    /// @param acc Storage pointer to the pool's accumulator.
    /// @param newTick Tick after the swap.
    /// @return cumulative The accumulator value as of the current block.
    function update(Accumulator storage acc, int24 newTick) internal returns (int56 cumulative) {
        uint32 nowBlock = uint32(block.number);

        if (acc.lastUpdate == 0) {
            // First touch: nothing has elapsed under a known tick yet.
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

    /// @notice Accumulator value as of the current block, without writing.
    /// @dev Extrapolates the open trailing interval at `lastTick`. This is what makes a quiet
    ///      pool resolve correctly instead of reading as missing data.
    function observe(Accumulator memory acc) internal view returns (int56) {
        uint32 elapsed = uint32(block.number) - acc.lastUpdate;
        return acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));
    }

    /// @notice Time-weighted average tick between two accumulator readings.
    /// @dev Integer division truncates toward zero, so the TWA can be off by at most one tick
    ///      and the direction of that error depends on sign. One tick is far below any sane
    ///      `refundToleranceTicks`, so this is not corrected.
    /// @param cumulativeAtOpen Accumulator value recorded when the bond opened.
    /// @param cumulativeNow Accumulator value at settlement.
    /// @param elapsedBlocks Blocks between the two readings. Must be non-zero.
    function twaTick(int56 cumulativeAtOpen, int56 cumulativeNow, uint32 elapsedBlocks) internal pure returns (int24) {
        if (elapsedBlocks == 0) revert ZeroWindow();
        return int24((int256(cumulativeNow) - int256(cumulativeAtOpen)) / int256(uint256(elapsedBlocks)));
    }
}
