// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PersistenceMathLib
/// @notice The single slash model for BondMeBro. Given the tick before a swap, the tick
///         immediately after it, and a settlement reference tick observed later, returns the
///         fraction of the swap's original price impact that survived — in basis points.
///
/// @dev There is exactly one slash curve in this library, and it is the only source of
///      `slashAmount` anywhere in the protocol. Deliberately absent, and absent by design
///      rather than by omission:
///        - no `minSlashBps` / `slashK` (a second, competing slash model)
///        - no `persistenceThresholdTicks` (the deprecated continuation rule's parameter)
///        - no `max(impactAbs - refundTol, 1)` denominator guard, which inverted the intended
///          behaviour for small-impact swaps by saturating the curve instead of disabling it
///
///      KNOWN LIMITATION — state this in the README and in the demo.
///      `remaining` is measured against the settlement reference, which reflects the swap's
///      own surviving impact PLUS market drift PLUS unrelated later flow. This library cannot
///      separate them; no pool-local tick math can. In a trending market, trades with the
///      trend read as persistent and trades against it read as reverted, independent of who
///      was informed. BondMeBro is therefore an outcome-linked LP insurance mechanism, not a
///      per-trade causal attribution of toxicity. Shortening the observation window is the
///      only lever here that improves signal-to-noise: impact is instantaneous, drift
///      accumulates with elapsed time. See `test_driftDominatesSignal_KnownLimitation`.
library PersistenceMathLib {
    /// @notice Basis-point denominator. 10_000 == 100% of the bond slashed.
    uint256 internal constant BPS = 10_000;

    /// @notice Fraction of the original impact that survived, in bps.
    ///
    /// @dev Definitions, all in ticks:
    ///        impactSigned = tickAfter - tickBefore      (what the swap itself did)
    ///        dir          = sign(impactSigned)          (-1 for zeroForOne, +1 for oneForZero)
    ///        remaining    = dir * (settlementRef - tickBefore)
    ///
    ///      `remaining` is how far the price still sits from `tickBefore` in the trade's own
    ///      direction. Reading the three cases that matter:
    ///        remaining <= 0          price fully reverted (or overshot the other way) -> refund
    ///        remaining == impactAbs  price sat exactly where the trade left it        -> full slash
    ///        remaining >  impactAbs  price kept going                                 -> clamped full slash
    ///
    ///      The plateau case is the whole point of this rule. The deprecated continuation rule
    ///      refunded it, which contradicted the project's own thesis: a trade that repriced the
    ///      pool and left it there is the canonical informed trade, and the LP ate the full
    ///      adverse selection.
    ///
    ///      `refundTol` is subtracted from BOTH numerator and denominator so the curve is
    ///      continuous at the refund boundary: persistence rises from 0 smoothly as `remaining`
    ///      passes `refundTol`, rather than jumping. A discontinuity here would be a boundary
    ///      an attacker pays to sit exactly on.
    ///
    /// @param tickBefore Pool tick captured in beforeSwap.
    /// @param tickAfter Pool tick captured in afterSwap.
    /// @param settlementRef Reference tick for the observation window (TWA, not spot).
    /// @param refundTol Noise floor in ticks. Impact at or below this is never slashable.
    /// @return persistenceBps Surviving fraction in [0, 10_000].
    function computeBps(int24 tickBefore, int24 tickAfter, int24 settlementRef, uint24 refundTol)
        internal
        pure
        returns (uint16 persistenceBps)
    {
        // Widen before any arithmetic: int24 differences overflow near the tick bounds.
        int256 impactSigned = int256(tickAfter) - int256(tickBefore);
        if (impactSigned == 0) return 0;

        uint256 impactAbs = impactSigned > 0 ? uint256(impactSigned) : uint256(-impactSigned);

        // The swap barely moved the pool. Its impact is inside the noise floor, so there is
        // nothing meaningful to measure the survival of. Early return BEFORE any division:
        // this is what makes the denominator provably positive below.
        if (impactAbs <= uint256(refundTol)) return 0;

        int256 dir = impactSigned > 0 ? int256(1) : int256(-1);
        int256 remaining = dir * (int256(settlementRef) - int256(tickBefore));

        int256 numerator = (remaining - int256(uint256(refundTol))) * int256(BPS);
        if (numerator <= 0) return 0; // reverted, or still inside the noise floor

        // Safe: impactAbs > refundTol was enforced above.
        uint256 denominator = impactAbs - uint256(refundTol);

        uint256 raw = uint256(numerator) / denominator;
        return raw >= BPS ? uint16(BPS) : uint16(raw);
    }

    /// @notice Splits a bond into the slashed and refunded portions.
    /// @dev Rounds the slash DOWN, so rounding error always favours the trader and the hook
    ///      can never owe out more than it holds. `slash + refund == bondAmount` exactly.
    /// @param bondAmount Posted collateral.
    /// @param persistenceBps Output of `computeBps`.
    function split(uint128 bondAmount, uint16 persistenceBps)
        internal
        pure
        returns (uint128 slashAmount, uint128 refundAmount)
    {
        slashAmount = uint128((uint256(bondAmount) * uint256(persistenceBps)) / BPS);
        refundAmount = bondAmount - slashAmount;
    }
}
