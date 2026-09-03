// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title TickAccumulatorLib

/// @notice Maintains a time-weighted tick accumulator for each pool so BondMeBro can measure the average pool tick between bond opening and maturity without using an external oracle, observation ring buffer, or binary search.

/// @dev Uniswap v4 does not provide the built-in historical oracle observations that v3 pools exposed, so BondMeBro must maintain the information it needs inside the hook. A full v3-style observations array is useful when a protocol needs to query the cumulative tick at arbitrary historical times. BondMeBro's MVP only needs a known start point recorded when a bond opens and a fixed maturity endpoint, so two accumulator readings are enough: one at bond opening and one at maturity.

/// The accumulator does NOT make late settlement depend on the settlement block. T5 must freeze or reconstruct the accumulator value at the bond's fixed maturity checkpoint. A trader may call settlement later, but swaps after maturity must not change the result.

/// Using a time-weighted average makes settlement harder to manipulate than using only the spot tick at settlement. With spot settlement, an attacker could temporarily push the price toward a refund-friendly level, settle, and immediately unwind. With a TWA, the attacker must keep that price displacement alive for a meaningful part of the observation window, increasing the cost and exposure to arbitrage.

/// The observation window starts from the post-swap tick recorded when the bond opens, so the
/// swap's own immediate price impact sits inside the window. Model L2 removes the sting of that
/// bias structurally rather than by tolerance: it scores only the LATE windows -- blocks 6-7 and
/// 8-9 of ten -- so the opening block is never part of what is charged. See ADR-0005 § 2.3.

/// Quiet pools are handled by extrapolation, not by automatic refunds. If no swap occurs after the bond opens, the last observed tick is treated as remaining active for the elapsed blocks. This means a quiet pool still produces a valid time-weighted observation instead of being treated as missing data.

library TickAccumulatorLib {
    /// @notice Thrown when a time-weighted average is requested over a zero-length interval.
    /// @dev Settlement should normally prevent this by requiring maturity before evaluating a bond, but the library still checks it directly so division by zero can never occur.
    error ZeroWindow();

    /// @notice Thrown when `cumulativeAt` is asked for a block outside its valid domain.
    /// @dev Below `lastUpdate` the value is unrecoverable; above the current block it does not
    ///      exist yet. Reverting keeps this helper from becoming a historical oracle.
    error BlockOutOfDomain(uint32 atBlock, uint32 lastUpdate, uint256 currentBlock);

    /// @notice Running tick accumulator for one pool. The fields fit in one storage slot: 24 + 32 + 24 + 56 = 136 bits.

    struct Accumulator {
        /// @dev Tick that has been active since `lastUpdate`.
        int24 lastTick;

        /// @dev Block number when the accumulator was last updated.
        uint32 lastUpdate;

        /// @dev Tick the pool sat at when the CURRENT block's FIRST swap was about to execute.
        ///
        ///      ADR-0008 § 3. This is the zero that block-cumulative impact is measured from:
        ///      `blockDisplacement = |tickAfter - blockStartTick|`. Latched by `beginBlock` and
        ///      deliberately NOT touched by `update`, so `afterSwap` can still read it after
        ///      `update` has overwritten `lastTick`.
        ///
        ///      IT COSTS NO SLOT. The three original fields used 112 of this slot's 256 bits, so
        ///      144 were already paid for and unused; this takes 24 of them and leaves 120.
        ///      `test/StorageLayout.t.sol` proves the one-slot claim from the compiler's own
        ///      layout and by decoding a raw `vm.load` word field by field.
        ///
        ///      THERE IS DELIBERATELY NO COMPANION `blockNumber` FIELD. `lastUpdate` already is
        ///      the block number and `BondMeBro` already advances it on every swap, bonded or not,
        ///      before any configuration branch — so `lastUpdate < block.number` is exactly "no
        ///      swap has touched this pool yet in this block". A second source of truth for that
        ///      would be a live hazard against the maturity scan, which derives its bound from
        ///      `lastUpdate` (ADR-0003 § 3.2).
        int24 blockStartTick;

        /// @dev Running sum of `tick * elapsedBlocks`. `int56` matches the width traditionally used for tick cumulative accounting and has ample range for the Uniswap tick bounds; even at the maximum absolute tick it would take roughly 4e10 blocks to approach the signed range limit.
        int56 tickCumulative;
    }

    /// @notice Latches `blockStartTick` the first time the accumulator sees a given block.

    /// @dev ADR-0008 § 3.3. POOL-LEVEL AND IDENTITY-FREE: it reads nothing but the pool's own
    /// accumulator — no sender, no recipient, no `tx.origin`, no router. The block-cumulative
    /// charge therefore cannot be reduced by spreading a trade across addresses, routers or
    /// transactions, only by not moving the price.

    /// `lastUpdate` IS THE WHOLE NEW-BLOCK TEST, and it works only because of an existing
    /// production guarantee: `BondMeBro._beforeSwap` advances the accumulator on EVERY swap,
    /// bonded or not, before any configuration branch. So `lastUpdate < block.number` means "no
    /// swap has touched this pool yet in this block", and at that instant `lastTick` is still the
    /// tick the previous block ended on — which is exactly the block's starting tick, available
    /// for free.

    /// ORDERING IS THE CORRECTNESS ARGUMENT and it is not interchangeable. This must run BEFORE
    /// `update` moves `lastUpdate` onto the current block, and `update` must run before
    /// `afterSwap` moves `lastTick` onto the new price. Called after `update`, the test would
    /// already read false and the latch would never fire; called after `afterSwap`, `lastTick`
    /// would be the post-swap tick and the block's own impact would be erased from its own
    /// displacement.

    /// IDEMPOTENT WITHIN A BLOCK. Second and later swaps in the same block see
    /// `lastUpdate == block.number` and leave the latch alone, which is what makes the whole block
    /// share one zero.

    /// @param acc Storage pointer to the pool's accumulator.
    /// @param currentTick Tick to seed with on the pool's very first touch, when there is no
    ///        previous block for `lastTick` to have carried over from.
    function beginBlock(Accumulator storage acc, int24 currentTick) internal {
        // First ever touch: `lastTick` holds nothing yet, so the seed is the pool's current tick.
        // `update` is about to store the same value, and this leaves the two consistent.
        if (acc.lastUpdate == 0) {
            acc.blockStartTick = currentTick;

            return;
        }

        // A block boundary. `lastTick` has not been touched since the previous block ended, so it
        // is that block's closing tick and therefore this block's opening tick.
        if (acc.lastUpdate < uint32(block.number)) {
            acc.blockStartTick = acc.lastTick;
        }
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
    function update(Accumulator storage acc, int24 newTick) internal returns (int56 cumulative) {
        uint32 nowBlock = uint32(block.number);

        // First observation: there is no earlier known tick interval to credit.
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

    /// @notice Returns the accumulator value at the current block without changing storage.

    /// @dev The time since the last stored update is extrapolated using `lastTick`, because that is the most recently known tick. This is what allows quiet pools to produce a valid observation even when no swap occurs during the observation window.

    /// This function observes the current block only. If settlement happens after a bond's maturity, T5 must use the accumulator value frozen or reconstructed at the maturity checkpoint rather than calling this function and using the later settlement block directly.
    function observe(Accumulator memory acc) internal view returns (int56) {
        uint32 elapsed = uint32(block.number) - acc.lastUpdate;

        return acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));
    }

    /// @notice Returns the accumulator value at a chosen block at or after `lastUpdate`.

    /// @dev The one additive helper ADR-0003 section 13.3 authorises. `observe` is the special case
    /// `atBlock == block.number`; this generalises it so a maturity checkpoint can be frozen at the
    /// exact block the bond matured rather than at the block the crossing swap happened to land on.

    /// DOMAIN, AND WHY IT IS ENFORCED. Valid only for `acc.lastUpdate <= atBlock <= block.number`.

    /// Below `lastUpdate` the answer is unknowable: the accumulator keeps no history, so a caller
    /// asking about an earlier block would silently receive a value extrapolated from the WRONG
    /// tick. Above the current block it would be inventing the future. Both are rejected rather
    /// than returning a plausible-looking number, because this function must never become a
    /// general historical oracle — the whole point of the checkpoint design is that values are
    /// captured while they are still knowable, not reconstructed afterwards.

    /// Within the domain the answer is exact, not an approximation: the tick cannot change without
    /// a swap, and a swap would have moved `lastUpdate` forward.

    /// @param acc Accumulator to read.
    /// @param atBlock Block to evaluate at. Must satisfy `acc.lastUpdate <= atBlock <= block.number`.
    /// @return cumulative Accumulator value at `atBlock`, in tick-blocks.
    function cumulativeAt(Accumulator memory acc, uint32 atBlock) internal view returns (int56 cumulative) {
        if (atBlock < acc.lastUpdate || uint256(atBlock) > block.number) {
            revert BlockOutOfDomain(atBlock, acc.lastUpdate, block.number);
        }

        uint32 elapsed = atBlock - acc.lastUpdate;

        return acc.tickCumulative + int56(acc.lastTick) * int56(uint56(elapsed));
    }

    /// @notice Calculates the time-weighted average tick between two accumulator readings.

    /// @dev The two cumulative readings should represent the bond's opening checkpoint and its fixed maturity checkpoint. Integer division truncates toward zero, so the returned average may differ from the exact mathematical average by less than one tick.

    /// Formula:
    /// `averageTick = (cumulativeAtEnd - cumulativeAtOpen) / elapsedBlocks`

    /// @param cumulativeAtOpen Accumulator value recorded when the bond opened.
    /// @param cumulativeNow Accumulator value at the end of the observation window. For BondMeBro settlement this should be the fixed maturity checkpoint, not an arbitrarily late settlement reading.
    /// @param elapsedBlocks Number of blocks between the two readings. Must be greater than zero.
    /// @return averageTick Time-weighted average tick over the interval.
    /// @dev NOT ON THE PRODUCTION SETTLEMENT PATH SINCE P-L2-6. Model L2 does not take a
    ///      whole-window average: it computes two two-block windows in CUMULATIVE space, aligning
    ///      to the trade's direction before dividing, because dividing first and subtracting after
    ///      is a different function under integer truncation (ADR-0005 § 3.3). That arithmetic
    ///      lives in `ModelL2SettlementLib.alignedLateWindow`.
    ///
    ///      Retained as general library surface and covered by this library's own tests. It is
    ///      deliberately NOT used to derive any settlement figure, and a future reader should not
    ///      infer from its presence that whole-window TWA is the mechanism -- ADR-0005 § 2.3
    ///      records why that variant was rejected.
    function twaTick(int56 cumulativeAtOpen, int56 cumulativeNow, uint32 elapsedBlocks)
        internal
        pure
        returns (int24 averageTick)
    {
        if (elapsedBlocks == 0) revert ZeroWindow();

        averageTick = int24((int256(cumulativeNow) - int256(cumulativeAtOpen)) / int256(uint256(elapsedBlocks)));
    }
}
