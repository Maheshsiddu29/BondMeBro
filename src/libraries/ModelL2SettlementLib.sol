// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title ModelL2SettlementLib
/// @notice Splits a bond's collateral into a refund and an amount retained in reserve.
/// @dev The hook supplies the actual variable-side token amount and the collateral
/// rate stored when the bond opened. This library does not recalculate that rate
/// from opening ticks: it also depended on block-start state that may have changed.
///
/// Settlement uses two late windows in the ten-block observation period:
/// C6 to C8 covers blocks 6 and 7; C8 to C10 covers blocks 8 and 9.
/// C means a cumulative sum of tick * elapsed blocks, measured in tick-blocks.
/// A difference between two readings, divided by elapsed blocks, gives an average tick.
///
/// We measure each window's displacement from tickBefore in the opening move's
/// direction and keep the larger non-negative result. Displacement at or below
/// five ticks is not charged. Larger residual displacement determines the retained
/// rate, limited by the stored collateral rate. The refund is collateral - slash.
///
/// The opening block is outside these late windows, but an opening displacement
/// still counts if it remains near maturity. These observations describe pool
/// outcomes, not trader intent. Two windows reduce dependence on a single late
/// interval; they do not make manipulation impossible.
library ModelL2SettlementLib {
    /// @notice Basis-point denominator: 10,000 bps = 100%; one bps = 0.01%.
    uint256 internal constant BPS = 10_000;

    /// @notice Retained-rate numerator: 25 / 100 = 0.25 bps per chargeable residual tick.
    uint256 internal constant SLASH_SCALE = 25;

    /// @notice Residual of five ticks or less is not charged.
    /// @dev This fixed demo setting is not a historically proven optimum. Repeated
    /// small moves within this allowance remain a known limitation.
    uint256 internal constant DEAD_ZONE_TICKS = 5;

    /// @notice Each of the two late observation windows spans two blocks.
    uint256 internal constant LATE_WINDOW_BLOCKS = 2;

    /// @notice Divisor that expresses the 0.25 bps-per-tick scale using integers.
    uint256 internal constant SLASH_SCALE_DENOMINATOR = 100;

    /// @notice Calculates a late window's average displacement in the opening move's direction.
    /// @dev Subtract the baseline while values are still in tick-blocks, then divide
    /// by two. Dividing first can discard a remainder and change the result.
    /// For example, a cumulative increase of 220 tick-blocks with baseline tick 100
    /// gives (220 - 2 * 100) / 2 = 10 ticks above the baseline.
    ///
    /// Subtracting widened int256 values avoids overflow between int56 readings.
    /// Division rounds toward zero. Direction is positive only when tickAfter is
    /// greater than tickBefore; otherwise, including equal ticks, it is negative.
    /// Equal opening ticks can still accompany a positive block-aware collateral rate.
    ///
    /// Do not take an absolute value here: movement opposite the opening direction
    /// must stay negative so it cannot create a slash.
    /// @param cumStart Window-start cumulative in tick-blocks.
    /// @param cumEnd Window-end cumulative in tick-blocks, exactly two blocks later.
    /// @param tickBefore Tick before the bonded swap; the displacement baseline.
    /// @param tickAfter Tick after the swap, used to choose direction.
    /// @return aligned Average displacement in ticks, positive in the chosen direction.
    function alignedLateWindow(int56 cumStart, int56 cumEnd, int24 tickBefore, int24 tickAfter)
        internal
        pure
        returns (int256 aligned)
    {
        int256 numerator = (int256(cumEnd) - int256(cumStart)) - int256(LATE_WINDOW_BLOCKS) * int256(tickBefore);

        int256 sign = tickAfter > tickBefore ? int256(1) : int256(-1);

        return (sign * numerator) / int256(LATE_WINDOW_BLOCKS);
    }

    /// @notice Returns the larger non-negative displacement from the two late windows.
    /// @dev A negative window cannot cancel a positive one. A positive window that
    /// survives a change to the other still contributes to the result. Manipulation
    /// spanning both windows remains possible.
    /// @param c6 Cumulative at opening block + 6, in tick-blocks.
    /// @param c8 Cumulative at opening block + 8, in tick-blocks.
    /// @param c10 Cumulative at maturity, opening block + 10, in tick-blocks.
    /// @param tickBefore Tick before the bonded swap.
    /// @param tickAfter Tick after the swap, used for direction.
    /// @return residualTicks Remaining displacement in ticks, never negative.
    function residual(int56 c6, int56 c8, int56 c10, int24 tickBefore, int24 tickAfter)
        internal
        pure
        returns (uint256 residualTicks)
    {
        int256 late1 = alignedLateWindow(c6, c8, tickBefore, tickAfter);
        int256 late2 = alignedLateWindow(c8, c10, tickBefore, tickAfter);

        int256 best = late1 > late2 ? late1 : late2;

        return best > 0 ? uint256(best) : 0;
    }

    /// @notice Applies the five-tick allowance and the catch-up region.
    /// @dev Residual R <= 5 gives zero. Between 5 and 10, chargeable ticks are
    /// 2 * (R - 5). At 10 or more, all R ticks are chargeable.
    /// For example, residuals 5, 7 and 10 give 0, 4 and 10 chargeable ticks.
    /// The allowance is not a permanent subtraction of five from larger moves.
    /// @param residualTicks Non-negative late residual in ticks.
    /// @return Chargeable residual in ticks.
    function chargeableResidual(uint256 residualTicks) internal pure returns (uint256) {
        if (residualTicks <= DEAD_ZONE_TICKS) return 0;

        if (residualTicks < 2 * DEAD_ZONE_TICKS) {
            return 2 * (residualTicks - DEAD_ZONE_TICKS);
        }

        return residualTicks;
    }

    /// @notice Converts chargeable residual ticks into a requested retained rate.
    /// @dev ceil(chargeable * 25 / 100) keeps a positive rate for small positive
    /// residuals. This result is not yet capped by the collateral posted.
    /// @param chargeable Chargeable residual in ticks.
    /// @return Requested slash rate in basis points of the variable leg.
    function targetSlashBps(uint256 chargeable) internal pure returns (uint256) {
        return (chargeable * SLASH_SCALE + (SLASH_SCALE_DENOMINATOR - 1)) / SLASH_SCALE_DENOMINATOR;
    }

    /// @notice Caps the residual-based rate at the bond's stored collateral rate.
    /// @dev The residual determines a target independently of the opening collateral
    /// rate. For the same residual, increasing that collateral rate cannot lower this
    /// result. Settlement can never retain more than the bond originally posted.
    /// @param collateralBps Rate stored when the bond opened, in basis points.
    /// @param residualTicks Non-negative displacement in ticks.
    /// @return Retained rate in basis points of the variable leg.
    function slashBpsFor(uint256 collateralBps, uint256 residualTicks) internal pure returns (uint256) {
        uint256 target = targetSlashBps(chargeableResidual(residualTicks));

        return target < collateralBps ? target : collateralBps;
    }

    /// @notice Converts collateral and slash rates into raw token amounts.
    /// @dev Both amounts are calculated from the original variable leg using the same
    /// 10,000 denominator. Do not calculate slash as collateral * slashBps /
    /// collateralBps: collateral has already been rounded, so that adds another
    /// rounding step and can lower the slash when the collateral rate increases.
    ///
    /// For example, a leg of 102 raw units has collateral of 1 unit at either 99 or
    /// 100 bps. With slashBps = 99, the ratio formula changes from 1 * 99 / 99 = 1
    /// to 1 * 99 / 100 = 0. Calculating 102 * 99 / 10,000 keeps the slash at 1.
    ///
    /// We derive refund by subtraction, so refund + slash equals collateral exactly.
    /// Production supplies a rate capped at 100 bps; the uint256 intermediate products
    /// then fit and the final collateral fits in uint128.
    /// @param variableLegAmount Recorded variable-side amount in raw collateral-token units.
    /// @param collateralBps Original collateral rate in basis points.
    /// @param slashBps Retained rate, capped by collateralBps in the settlement flow.
    /// @return collateral Original collateral in raw token units.
    /// @return slash Retained amount in raw token units, at most collateral.
    /// @return refund Remaining amount in raw token units.
    function split(uint128 variableLegAmount, uint256 collateralBps, uint256 slashBps)
        internal
        pure
        returns (uint128 collateral, uint128 slash, uint128 refund)
    {
        uint256 leg = uint256(variableLegAmount);

        collateral = uint128((leg * collateralBps) / BPS);

        uint256 target = (leg * slashBps) / BPS;

        slash = target < collateral ? uint128(target) : collateral;

        refund = collateral - slash;
    }

    /// @notice Calculates the refund and retained collateral from fixed bond observations.
    /// @dev This is the hook's settlement entry point into the math library. It changes
    /// no storage and moves no tokens. The hook handles maturity checks, accounting
    /// and the actual refund transfer.
    /// @param variableLegAmount Actual output for exact-input or pool input for exact-output,
    /// in raw units of the collateral token.
    /// @param collateralBps Saved rate from custody, capped at 100 bps.
    /// @param tickBefore Pool tick before the bonded swap.
    /// @param tickAfter Pool tick after the swap.
    /// @param c6 Cumulative at opening block + 6, in tick-blocks.
    /// @param c8 Cumulative at opening block + 8, in tick-blocks.
    /// @param c10 Cumulative at opening block + 10, in tick-blocks.
    /// @return collateral Original collateral in raw token units.
    /// @return slash Amount retained in raw token units.
    /// @return refund Amount returned in raw token units.
    /// @return realizedSlashBps Retained rate in basis points, no greater than collateralBps.
    function settle(
        uint128 variableLegAmount,
        uint256 collateralBps,
        int24 tickBefore,
        int24 tickAfter,
        int56 c6,
        int56 c8,
        int56 c10
    ) internal pure returns (uint128 collateral, uint128 slash, uint128 refund, uint16 realizedSlashBps) {
        uint256 residualTicks = residual(c6, c8, c10, tickBefore, tickAfter);

        uint256 bps = slashBpsFor(collateralBps, residualTicks);

        (collateral, slash, refund) = split(variableLegAmount, collateralBps, bps);

        realizedSlashBps = uint16(bps);
    }
}
