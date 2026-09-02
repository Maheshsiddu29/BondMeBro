// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TickAccumulatorLib
/// @notice A time-weighted average tick over `[bondOpen, settle]`, using a single running
///         accumulator per pool — no observations ring buffer and no binary search.
///         v2: adds the truncation defense and the once-per-block rule.
///
/// @dev WHY THIS SHAPE. Uniswap v4 removed the built-in oracle that v3 pools carried, so
///      there is no pool-internal history to read; a hook must accumulate it itself. A
///      v3-style 65535-slot observations array answers for *arbitrary* past blocks;
///      BondMeBro only ever averages over one interval whose start it records at bond
///      open. Two readings of one accumulator suffice.
///
///      WHAT IT BUYS. Spot settlement makes push-settle-unwind atomic, and because the
///      persistence curve is linear, pushing price back k% of the way recovers k% of the
///      bond at the cost of roughly a k-sized round trip. A TWA removes the atomicity: the
///      attacker must hold the distorted price across a real fraction of the window,
///      bleeding to arbitrageurs every block, for a payoff proportional to the fraction
///      of the window sustained.
///
///      CORE MECHANICS. Each update credits the elapsed blocks at the tick that was live
///      during them (`lastTick`, the previous recording — never the incoming tick, which
///      would attribute this swap's impact backwards over time it had not yet occurred),
///      then rolls forward. `observe` returns the current value without writing, by
///      extrapolating open trailing intervals at `lastTick`.
///
///      ONCE PER BLOCK. Only the FIRST swap of a block updates the accumulator; later
///      same-block swaps change nothing that future blocks credit. This kills intra-block
///      ratcheting: without it, an attacker could chain same-block swaps to move the
///      recorded tick arbitrarily far past the clamp in a single block, then hold it for
///      one boundary and see it credited to the window. The honest cost is that a big
///      honest move in swap #3 of a block waits until the next block to be recorded —
///      settlement references lag, briefly, toward what the block opened with.
///
///      TRUNCATION (the clamp). The recorded tick may move at most `maxAbsTickDelta`
///      per touched block, regardless of how far the raw pool tick moved. A single-block
///      push of P ticks therefore registers at most `maxAbsTickDelta`, not P — converting
///      a capital attack (huge 1-block move) into a time attack (capped moves over many
///      blocks), which is exactly the attack the observation window makes expensive.
///      Mirrors the clamp in Uniswap v4-periphery's TruncatedOracle. The clamp applies
///      ONLY to this reference data: bond impact (tickBefore / tickAfter) is still read
///      from raw slot0 and never truncated.
///
///      FIXED PER-BLOCK CAP, NOT ELAPSED-SCALED. Scaling the cap by `elapsed` would let a
///      single swap after a quiet gap record an arbitrarily large move — and in a quiet
///      pool, `observe` would then extrapolate that spike across the remainder of every
///      open window. A fixed cap keeps the worst case bounded per block, per block,
///      always.
///
///      THE COST (accepted deliberately). An honest violent move (real news) is recorded
///      gradually — one clamp width per touched block — so the settlement reference
///      under-reads honest drift in both directions until it catches up. This leans
///      toward refunds for roughly one window. The trade is honest records are never
///      cheap to fake.
///
///      QUIET POOLS ARE NOT A SPECIAL CASE. If nobody swaps during a bond's window,
///      `observe` extrapolates the last recorded tick for the whole interval, so the TWA
///      equals the recorded post-swap tick and the bond slashes fully. That is the
///      correct answer under the thesis — the price moved and no arbitrageur found it
///      worth reverting. Do NOT add an "invalid reference -> auto-refund" branch; it
///      would be a free escape that is cheapest to grind in exactly the thin pools this
///      mechanism targets.
///
///      INITIALIZATION. BondMeBro seeds the accumulator from the pool's declared initial tick
///      in `afterInitialize`, so the first swap is clamped too. The lazy standalone path in
///      `update` records its first `newTick` UNCLAMPED: before any recording exists there is
///      no baseline to defend, and no bond can predate that first touch.
///
///      OVERFLOW (calculated, not assumed). int56 max ≈ 3.6e16; at the extreme sustained
///      tick (887272) overflow needs 4.06e10 blocks — ~15,400 years at 12s blocks, ~322
///      years even at 0.25s blocks, so it is not a design constraint. `lastUpdate` is
///      uint48 rather than uint32 because uint32 block numbers wrap in ~34 years on a
///      0.25s chain; uint48 never wraps. The struct packs into one storage slot:
///      24 + 48 + 56 = 128 bits.
library TickAccumulatorLib {
    /// @notice Thrown when a TWA is requested over a zero-length window.
    /// @dev Unreachable via settleBonds, which enforces maturity first, but the library is
    ///      public surface and must not divide by zero for any caller.
    error ZeroWindow();

    /// @notice One accumulator per pool. Packs into a single storage slot
    ///         (24 + 48 + 56 = 128 bits).
    struct Accumulator {
        /// @dev Tick recorded as of `lastUpdate` — post-clamp, so possibly not the raw
        ///      pool tick. Intervals are credited at this tick.
        int24 lastTick;
        /// @dev Block number of the most recent update. uint48, not uint32: see the
        ///      overflow note in the library NatSpec.
        uint48 lastUpdate;
        /// @dev Running sum of recordedTick * blocks.
        int56 tickCumulative;
    }

    /// @notice Seeds an accumulator at pool initialization.
    /// @dev BondMeBro calls this from `afterInitialize`, so the first swap is measured from
    ///      the pool's declared initial tick and is subject to the same clamp as every later
    ///      move. The lazy first-touch branch in `update` remains for standalone library users.
    function initialize(Accumulator storage acc, int24 initialTick) internal {
        acc.lastTick = initialTick;
        acc.lastUpdate = uint48(block.number);
        acc.tickCumulative = 0;
    }

    /// @notice Credits the elapsed interval, clamps the incoming tick's per-block move, and
    ///         rolls the accumulator forward.
    /// @dev MUST be called on every swap in the pool, not only bonded ones — a gap in the
    ///      accumulator silently biases every bond whose window spans it. Two correctness
    ///      details:
    ///        - the elapsed interval is credited at `acc.lastTick`, the tick that was
    ///          actually live during it, NOT at `newTick` — crediting the new tick would
    ///          attribute the swap's own impact backwards over time it had not yet
    ///          occurred;
    ///        - only the FIRST swap of a block updates the accumulator (once-per-block
    ///          rule), so a same-block sequence of swaps cannot ratchet the recorded tick
    ///          past `maxAbsTickDelta`.
    ///      Clamp semantics: per touched block the recorded tick moves at most
    ///      `maxAbsTickDelta`, regardless of how far the raw pool tick moved. Not scaled by
    ///      `elapsed` — scaling would let a single post-gap swap record an arbitrarily
    ///      large move, which in a quiet pool would then be extrapolated across the rest of
    ///      a bond's window by `observe`. A fixed cap keeps the worst case bounded by
    ///      `maxAbsTickDelta` per block, per block, always.
    /// @param acc Storage pointer to the pool's accumulator.
    /// @param newTick Raw tick after the swap.
    /// @param maxAbsTickDelta Per-block clamp on the recorded tick move (config param).
    /// @return cumulative The accumulator value as of the current block.
    function update(Accumulator storage acc, int24 newTick, uint24 maxAbsTickDelta)
        internal
        returns (int56 cumulative)
    {
        uint48 nowBlock = uint48(block.number);

        if (acc.lastUpdate == 0) {
            // First touch: nothing has elapsed under a known tick yet. Initialization
            // defines the baseline and is deliberately unclamped — before any recording
            // exists there is nothing to defend, and no bond can predate its pool's
            // first swap, so the baseline is honest by construction.
            acc.lastTick = newTick;
            acc.lastUpdate = nowBlock;
            return acc.tickCumulative;
        }

        if (acc.lastUpdate == nowBlock) {
            // Once per block: the first observation of the block wins. A same-block later
            // swap changes nothing the future credits — so a ratchet of small swaps inside
            // one block cannot move the recorded tick more than one clamp width.
            return acc.tickCumulative;
        }

        uint48 elapsed = nowBlock - acc.lastUpdate; // >= 1
        cumulative = acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));

        // |newTick - lastTick| <= 2 * 887272 < 2^21 for any real pool, so the clamped
        // delta always fits int24 regardless of how large a cap a config chooses.
        int256 delta = int256(newTick) - int256(acc.lastTick);
        int256 cap = int256(uint256(maxAbsTickDelta));
        if (delta > cap) delta = cap;
        else if (delta < -cap) delta = -cap;

        acc.tickCumulative = cumulative;
        acc.lastTick = acc.lastTick + int24(delta);
        acc.lastUpdate = nowBlock;
    }

    /// @notice Backwards-compatible uncapped update.
    /// @dev Callers of the truncation-aware API should use the three-argument overload. This
    ///      overload preserves the original library surface for integrations that explicitly
    ///      opt out of truncation (the hook itself never uses it).
    function update(Accumulator storage acc, int24 newTick) internal returns (int56 cumulative) {
        return update(acc, newTick, type(uint24).max);
    }

    /// @notice Accumulator value as of the current block, without writing.
    /// @dev Extrapolates the open trailing interval at `lastTick`. This is what makes a
    ///      quiet pool resolve correctly instead of reading as missing data — and it means
    ///      a late settlement simply extends the window at the last recorded tick, biasing
    ///      toward slash (no reversion evidence) rather than refund.
    function observe(Accumulator memory acc) internal view returns (int56) {
        uint48 elapsed = uint48(block.number) - acc.lastUpdate;
        return acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));
    }

    /// @notice Time-weighted average tick between two accumulator readings.
    /// @dev Integer division truncates toward zero, so the TWA can be off by at most one
    ///      tick and the direction of that error depends on sign. One tick is far below
    ///      any sane `refundToleranceTicks`, so this is not corrected.
    /// @param cumulativeAtOpen Accumulator value recorded when the bond opened.
    /// @param cumulativeNow Accumulator value at settlement.
    /// @param elapsedBlocks Blocks between the two readings. Must be non-zero. uint48 keeps
    ///        the settlement path aligned with the accumulator's uint48 block number.
    function twaTick(int56 cumulativeAtOpen, int56 cumulativeNow, uint48 elapsedBlocks) internal pure returns (int24) {
        if (elapsedBlocks == 0) revert ZeroWindow();
        return int24((int256(cumulativeNow) - int256(cumulativeAtOpen)) / int256(uint256(elapsedBlocks)));
    }
}
