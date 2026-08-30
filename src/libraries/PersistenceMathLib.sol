// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title PersistenceMathLib

/// @notice Calculates how much of a swap's original price displacement is still present at maturity and converts that persistence into the fraction of the bond that should be slashed.

/// @dev BondMeBro uses one continuous persistence formula for settlement. The calculation compares the tick before the bonded swap, the tick immediately after it, and the time-weighted reference tick at the bond's fixed maturity. This library does not use a second slash curve, minimum slash, continuation threshold, or other competing settlement rule.

/// This calculation measures an outcome, not trader intent. A persistent price displacement may contain the original swap's surviving impact, broader market movement, or unrelated later trading. Pool-local tick data cannot separate those causes. BondMeBro should therefore be described as an outcome-linked LP-risk mechanism, not as a system that proves a trader was toxic or informed.

library PersistenceMathLib {
    /// @notice Basis-point denominator. `10_000` represents 100%.
    uint256 internal constant BPS = 10_000;

    /// @notice Calculates the fraction of the original swap displacement that remains at maturity.

    /// @dev All values are measured in ticks. First measure the swap's original displacement:
    ///
    /// `impactSigned = tickAfter - tickBefore`
    ///
    /// Then measure how far the maturity reference remains from the original pre-swap tick in the same direction as the swap:
    ///
    /// `remaining = direction * (maturityRef - tickBefore)`
    ///
    /// where `direction` is `+1` when the swap moved the tick upward and `-1` when it moved the tick downward.

    /// The important cases are:
    ///
    /// `remaining <= refundTol`        -> effectively reverted -> 0% slash
    ///
    /// `remaining == impactAbs`        -> original displacement persisted -> 100% slash
    ///
    /// `remaining > impactAbs`         -> displacement continued further -> capped at 100% slash

    /// `refundTol` creates a noise region around the original pre-swap tick. It is subtracted from both the surviving displacement and the original impact so the persistence curve starts smoothly from zero rather than jumping at the tolerance boundary.

    /// Formula after the tolerance checks:
    ///
    /// `persistenceBps = (remaining - refundTol) * 10_000 / (impactAbs - refundTol)`
    ///
    /// The result is clamped to `[0, 10_000]`.

    /// @param tickBefore Pool tick immediately before the bonded swap.
    /// @param tickAfter Pool tick immediately after the bonded swap.
    /// @param settlementRef Time-weighted reference tick at the bond's fixed maturity. Despite the parameter name, T5 must not substitute an arbitrarily late settlement-time tick here.
    /// @param refundTol Tick tolerance treated as noise. An original impact at or below this value is not slashable.
    /// @return persistenceBps Fraction of the original displacement that survived, in basis points from 0 to 10_000.
    function computeBps(int24 tickBefore, int24 tickAfter, int24 settlementRef, uint24 refundTol)
        internal
        pure
        returns (uint16 persistenceBps)
    {
        // Widen before subtraction because an int24 difference can exceed the int24 range.
        int256 impactSigned = int256(tickAfter) - int256(tickBefore);

        // No original displacement means there is nothing to measure.
        if (impactSigned == 0) return 0;

        uint256 impactAbs = impactSigned > 0 ? uint256(impactSigned) : uint256(-impactSigned);

        // Ignore swaps whose original displacement is entirely inside the tolerance region.
        //
        // This also guarantees that the denominator below is strictly positive.
        if (impactAbs <= uint256(refundTol)) {
            return 0;
        }

        // Direction of the swap's original tick movement.
        int256 direction = impactSigned > 0 ? int256(1) : int256(-1);

        // Distance from tickBefore that still remains in the swap's original direction.
        int256 remaining = direction * (int256(settlementRef) - int256(tickBefore));

        // Apply the tolerance before converting persistence into basis points.
        int256 numerator = (remaining - int256(uint256(refundTol))) * int256(BPS);

        // The price reverted to the tolerance region or crossed back beyond it.
        if (numerator <= 0) {
            return 0;
        }

        // Safe because `impactAbs > refundTol` was checked above.
        uint256 denominator = impactAbs - uint256(refundTol);

        uint256 raw = uint256(numerator) / denominator;

        // Persistence beyond the original impact cannot slash more than 100% of the bond.
        return raw >= BPS ? uint16(BPS) : uint16(raw);
    }

    /// @notice Splits a bond into the amount returned to the trader and the amount allocated to the slash side of settlement.

    /// @dev The slash calculation rounds down, so any integer-rounding remainder goes to the refund. The two outputs always add back to the original bond:
    ///
    /// `slashAmount + refundAmount = bondAmount`

    /// @param bondAmount Total collateral posted by the trader.
    /// @param persistenceBps Persistence result returned by `computeBps`.
    /// @return slashAmount Portion of the bond assigned to the slash side.
    /// @return refundAmount Portion of the bond returned to the trader.
    function split(uint128 bondAmount, uint16 persistenceBps)
        internal
        pure
        returns (uint128 slashAmount, uint128 refundAmount)
    {
        slashAmount = uint128((uint256(bondAmount) * uint256(persistenceBps)) / BPS);

        refundAmount = bondAmount - slashAmount;
    }
}
