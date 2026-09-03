// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title ModelL2SettlementLib
///
/// @notice Model L2's settlement arithmetic: the two late windows, the direction alignment, the
///         `D = 5` catch-up dead zone, and the token-unit slash.
///
/// @dev THE AUTHORITATIVE SPECIFICATION IS `docs/adr/0005-model-l2-economics.md`. This library is
///      its translation into integer Solidity and nothing more; it makes no economic decisions of
///      its own. Where a line below looks like it could be simplified, check ADR-0005 first — two
///      of them are load-bearing in ways that are invisible locally.
///
///      WHY MODEL B WAS REPLACED, IN ONE LINE. Model B computed
///      `persistence = (remaining - tolerance) / (initialImpact - tolerance)`, putting the opening
///      impact in the DENOMINATOR. Inflating the impact inflated the denominator, so the charge
///      fell: a trader who pushed the price further than they needed to was refunded more. Across
///      525 measured Model B rows, 490 lowered the absolute slash, recovering up to the entire
///      bond. Model L2 computes `slash = min(f(impact), g(residual))` where `f` is non-decreasing
///      and `g` does not mention impact at all. The minimum of a non-decreasing function and a
///      constant is non-decreasing, so raising the opening impact can only raise the collateral
///      posted, never lower the amount lost. That is arithmetic and holds for any population.
///
///      THE PIPELINE, end to end:
///
///          collateralBps  = min(100, ceil(|tickAfter - tickBefore| * 25 / 100))   <- caller's job
///          late1          = aligned TWA over (open+6,  open+8)   = (C6,  C8)
///          late2          = aligned TWA over (open+8,  open+10)  = (C8,  C10)
///          R              = max( max(late1, 0), max(late2, 0) )
///          Q              = deadZone(R)
///          targetSlashBps = ceil(Q * 25 / 100)
///          slashBps       = min(collateralBps, targetSlashBps)
///          collateral     = leg * collateralBps / 10_000
///          slash          = min(collateral, leg * slashBps / 10_000)
///          refund         = collateral - slash                    <- DERIVED, never independent
///
///      `collateralBps` is an INPUT rather than computed here, deliberately: the hook already owns
///      that rate function because CUSTODY uses it in `afterSwap` to decide how much to take. Two
///      implementations of one rate in one contract would be a live hazard — the recomputed
///      collateral must reproduce the amount physically taken to the wei, and it can only do that
///      if there is exactly one expression.
library ModelL2SettlementLib {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Slash rate per tick of chargeable residual, as an integer numerator over 100.
    ///
    /// @dev `25` is `0.25 bps/tick`, the V7.1 selected value, FROZEN by ADR-0005 § 2.1. It is the
    ///      same scale the collateral uses, which is what makes a fully persistent displacement
    ///      forfeit exactly the collateral it posted: `targetSlashBps` reaches `collateralBps`
    ///      precisely when the residual reaches the initial impact.
    uint256 internal constant SLASH_SCALE = 25;

    /// @notice The dead zone, in ticks. Residual at or below this is charged nothing.
    ///
    /// @dev FROZEN at 5 by ADR-0005 § 2.1, and it is a calibration choice against a SYNTHETIC
    ///      population rather than a historically validated optimum. ADR-0005 § 2.1 records the
    ///      trade-off openly: `D = 10` is the only candidate that meets the study's own trader
    ///      targets, and `D = 5` was chosen instead because past 7 ticks the dead zone begins
    ///      forgiving more harmful trades than benign ones. § 6.4 records what would change the
    ///      answer.
    uint256 internal constant DEAD_ZONE_TICKS = 5;

    /// @notice Blocks spanned by each late window. Both windows are two blocks wide.
    uint256 internal constant LATE_WINDOW_BLOCKS = 2;

    /// @notice Denominator for `SLASH_SCALE`, making the rate `25/100 == 0.25` bps per tick.
    uint256 internal constant SLASH_SCALE_DENOMINATOR = 100;

    /// @notice One late window's average displacement, aligned to the trade's own direction.
    ///
    /// @dev THE ALIGNMENT HAPPENS IN CUMULATIVE SPACE, AND THAT IS NOT INTERCHANGEABLE WITH THE
    ///      OBVIOUS ALTERNATIVE. ADR-0005 § 3.3 is explicit about it. The tempting form is
    ///
    ///          twa     = (cumEnd - cumStart) / 2          // average absolute tick
    ///          aligned = twa - tickBefore                 // then subtract the baseline
    ///
    ///      and it is WRONG under integer truncation, because dividing before subtracting discards
    ///      a remainder that the subtraction would otherwise have carried. The correct form
    ///      subtracts the baseline from the cumulative FIRST, while the quantity is still measured
    ///      in tick-blocks, and divides once at the end:
    ///
    ///          aligned = sign * ( (cumEnd - cumStart) - 2 * tickBefore ) / 2
    ///
    ///      Solidity's `/` truncates toward zero, matching `numpy.trunc`, and for
    ///      trunc-toward-zero division `sign * (x / n) == (sign * x) / n`, so the sign may sit
    ///      inside or outside. The research implementation was differentially checked against this
    ///      on 200,000 random paths with zero mismatches;
    ///      `test/ModelL2Settlement.t.sol` keeps that as a live test rather than a claim.
    ///
    ///      NO ABSOLUTE VALUE. The sign is taken from the ORIGINAL trade direction, so a late
    ///      excursion in the opposite direction produces a NEGATIVE aligned displacement, which
    ///      the caller clamps to zero. Using `abs` here would let an opposite-direction move
    ///      manufacture a charge for a displacement that had already reverted — INV-L2-6, and the
    ///      single most important reason this function does not look symmetric.
    ///
    /// @param cumStart Tick cumulative at the window's opening block.
    /// @param cumEnd Tick cumulative at the window's closing block.
    /// @param tickBefore The pool tick immediately before the bonded swap: the displacement's zero.
    /// @param tickAfter The pool tick immediately after it; supplies the direction only.
    /// @return aligned Average displacement across the window, positive when it lies in the same
    ///         direction as the original trade.
    function alignedLateWindow(int56 cumStart, int56 cumEnd, int24 tickBefore, int24 tickAfter)
        internal
        pure
        returns (int256 aligned)
    {
        // Widened before subtracting: the difference of two `int56` values is not representable in
        // `int56` at the extremes, and the baseline term scales with the window length.
        int256 numerator = (int256(cumEnd) - int256(cumStart)) - int256(LATE_WINDOW_BLOCKS) * int256(tickBefore);

        // Direction of the original trade. A zero-impact trade cannot be bonded at all
        // (`collateralBps` would be zero), so the `>` boundary is never reached in production; it
        // resolves to -1 for definiteness rather than being left to chance.
        int256 sign = tickAfter > tickBefore ? int256(1) : int256(-1);

        return (sign * numerator) / int256(LATE_WINDOW_BLOCKS);
    }

    /// @notice The robust late residual: the larger of the two clamped, aligned windows.
    ///
    /// @dev `R = max( max(late1, 0), max(late2, 0) )`.
    ///
    ///      WHY TWO WINDOWS AND A MAX, rather than one whole-window average. A single window can be
    ///      erased by a single opposing block, which is Model B's failure mode returning by another
    ///      route. Two disjoint windows cannot both be touched by one block, so a single late push
    ///      achieves a measured 0.0% reduction at every magnitude tested to 8x. The cost of erasing
    ///      the charge is moving the real price across BOTH windows for two consecutive blocks —
    ///      ADR-0005 § 6.1, which is a security boundary and explicitly NOT a claim that
    ///      manipulation is impossible.
    ///
    ///      THE CLAMP IS PER WINDOW, before the max. Clamping only the result would let a large
    ///      positive window be dragged down by a negative one, which is the opposite of what the
    ///      `max` is for.
    ///
    /// @param c6 Cumulative at `open+6`.
    /// @param c8 Cumulative at `open+8`.
    /// @param c10 Cumulative at `open+10`, the maturity block.
    /// @return residualTicks The residual, in ticks, never negative.
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

    /// @notice The catch-up dead zone: how much of the residual is chargeable.
    ///
    /// @dev ```
    ///          R <= 5      ->  Q = 0
    ///          5 < R < 10  ->  Q = 2 * (R - 5)
    ///          R >= 10     ->  Q = R
    ///      ```
    ///
    ///      THE SLOPE-2 MIDDLE SEGMENT IS THE WHOLE DESIGN, and it is what makes this a CATCH-UP
    ///      dead zone rather than a permanent subtraction. The function leaves zero at `D` and
    ///      rejoins the identity exactly at `2D`, because `2(2D - D) = 2D`.
    ///
    ///      The consequence is the point: FOR EVERY RESIDUAL AT OR ABOVE 10 TICKS THE CHARGE IS
    ///      BIT-IDENTICAL TO HAVING NO DEAD ZONE AT ALL. The rejected alternative,
    ///      `max(R - D, 0)`, never catches up — it under-charges every residual forever, including
    ///      the largest and most harmful ones.
    ///
    ///      The function is continuous at both joins and non-decreasing throughout, which is what
    ///      INV-L2-5 needs: at `R = 5` both branches give 0, and at `R = 10` both give 10.
    ///
    ///      Also, deliberately: a residual at or below `D` is charged nothing NO MATTER HOW
    ///      PERSISTENT. ADR-0005 § 6.2 records the consequence — displacement built at 5 ticks or
    ///      fewer per observation window costs zero, without bound. That is inherent to any noise
    ///      floor and is a documented limitation, not a defect to be patched here.
    function chargeableResidual(uint256 residualTicks) internal pure returns (uint256) {
        if (residualTicks <= DEAD_ZONE_TICKS) return 0;

        if (residualTicks < 2 * DEAD_ZONE_TICKS) {
            return 2 * (residualTicks - DEAD_ZONE_TICKS);
        }

        return residualTicks;
    }

    /// @notice The slash rate the residual asks for, before the collateral rate caps it.
    ///
    /// @dev `ceil(Q * 25 / 100)`. `ceil` is load-bearing for the same reason it is on the
    ///      collateral side: with `floor`, a chargeable residual of 1-3 ticks would ask for a ZERO
    ///      rate, so a displacement that visibly persisted would be charged nothing.
    ///
    ///      Not capped here. The cap is `collateralBps`, applied by `slashBpsFor`, because a bond
    ///      can never forfeit more than it posted.
    function targetSlashBps(uint256 chargeable) internal pure returns (uint256) {
        return (chargeable * SLASH_SCALE + (SLASH_SCALE_DENOMINATOR - 1)) / SLASH_SCALE_DENOMINATOR;
    }

    /// @notice The realized slash rate: what the residual asks for, capped by what was posted.
    ///
    /// @dev `slashBps = min(collateralBps, targetSlashBps(Q))`.
    ///
    ///      THIS `min` IS THE MODEL L PROPERTY IN ONE LINE. `collateralBps` is non-decreasing in
    ///      the opening impact; `targetSlashBps` does not mention the impact at all. The minimum
    ///      of a non-decreasing function and a constant is non-decreasing, so no amount of
    ///      overshoot can reduce the charge. Model B's defect was putting the impact in a
    ///      denominator, where growing it shrank the result.
    function slashBpsFor(uint256 collateralBps, uint256 residualTicks) internal pure returns (uint256) {
        uint256 target = targetSlashBps(chargeableResidual(residualTicks));

        return target < collateralBps ? target : collateralBps;
    }

    /// @notice Converts rates into token amounts.
    ///
    /// @dev THE DENOMINATOR IS THE VARIABLE LEG, NOT THE COLLATERAL, and that is the single most
    ///      consequential line in this library. ADR-0005 § 3.1 records the alternative and why it
    ///      fails:
    ///
    ///          FORM A:  slash = collateralAmount * slashBps / collateralBps        <- REJECTED
    ///          FORM B:  slash = min(collateral, leg * slashBps / 10_000)           <- this one
    ///
    ///      Form A is algebraically identical — `collateralBps` cancels — but it BREAKS INV-L2-4
    ///      in integer arithmetic. Exhaustively over 606,000,000 combinations, Form A loses one wei
    ///      as the impact rises, and its minimal counterexample is small enough to state in full:
    ///
    ///          leg = 102 wei, target = 99 bps
    ///          collateralBps  99 : collateral = floor(102*99/1e4)  = 1 ; slash = floor(1*99/99)  = 1
    ///          collateralBps 100 : collateral = floor(102*100/1e4) = 1 ; slash = floor(1*99/100) = 0
    ///
    ///      Raising the impact lowered the slash. One wei, on a dust-sized leg — and INV-L2-4 is
    ///      the invariant this entire architecture exists to provide, so "it only breaks on dust"
    ///      is not a proof. Dividing both amounts by the same fixed denominator removes the
    ///      double-rounding that causes it.
    ///
    ///      THE REFUND IS DERIVED BY SUBTRACTION, never computed independently. Computing both
    ///      sides from bps would leave rounding dust unaccounted for, and `refund + slash ==
    ///      collateral` (INV-L2-3) would hold only approximately. By subtraction it is exact by
    ///      construction, with no residual wei anywhere.
    ///
    ///      The `min` is defensive rather than load-bearing: `slashBps <= collateralBps` and
    ///      flooring is monotone, so the target can never exceed the collateral. ADR-0005 § 3.2
    ///      writes it explicitly and it costs one comparison, so it stays.
    ///
    /// @param variableLegAmount The realized variable leg the bond recorded.
    /// @param collateralBps Rate the collateral was taken at.
    /// @param slashBps Realized slash rate, already capped by `collateralBps`.
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

    /// @notice The whole settlement calculation, from a bond's stored fields and its three frozen
    ///         endpoints.
    ///
    /// @dev The single entry point production uses. Split into the named steps above so each is
    ///      independently testable and each failure names its own stage.
    ///
    /// @param variableLegAmount The bond's realized variable leg.
    /// @param collateralBps The rate the collateral was taken at, from the hook's own rate
    ///        function — see the note in this library's header on why it is passed in.
    /// @param tickBefore Pool tick immediately before the bonded swap.
    /// @param tickAfter Pool tick immediately after it.
    /// @param c6 Cumulative at `open+6`.
    /// @param c8 Cumulative at `open+8`.
    /// @param c10 Cumulative at `open+10`.
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

        // Safe: `bps <= collateralBps <= MAX_COLLATERAL_BPS == 100`.
        realizedSlashBps = uint16(bps);
    }
}
