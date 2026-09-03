// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {ModelLReference} from "./ModelLReference.sol";

/// @title ModelL2Reference
///
/// @notice An INDEPENDENT reference implementation of ADR-0005's settlement arithmetic, for tests.
///
/// @dev WHAT MAKES THIS INDEPENDENT, AND WHY IT MATTERS MORE HERE THAN ANYWHERE ELSE.
///
///      `docs/INVARIANTS-L2.md` opens with the rule: every "exact" claim must be checked against a
///      reference the test builds itself. For settlement that is not a formality — ADR-0005 § 3.1
///      records an algebraically CORRECT token formula that is nonetheless wrong in integer
///      arithmetic, and the only thing that caught it was computing the answer a second way and
///      comparing. A test that asserted the hook against its own library would have missed it.
///
///      THE LATE WINDOWS ARE COMPUTED FROM A PER-BLOCK TICK PATH, NOT FROM CUMULATIVES. Production
///      differences two frozen cumulatives and subtracts `2 * tickBefore` from the result:
///
///          aligned = sign * ( (cumEnd - cumStart) - 2 * tickBefore ) / 2
///
///      This library instead sums the per-block displacements directly:
///
///          aligned = sign * ( sum over k of (tick[k] - tickBefore) ) / n
///
///      The two are equal — `sum(tick[k]) == cumEnd - cumStart` over the window — but they are
///      different code, reached from different inputs, and a mistake in one has no reason to
///      appear in the other. That is the whole point of a differential.
///
///      It also mirrors the research implementation's shape (`window_twa`, `residual_for`), which
///      is what ADR-0005 § 3.3's 200,000-path differential was run against.
///
///      CONSTANTS ARE RESTATED, NOT IMPORTED, for the same reason as `ModelLReference`: an
///      imported constant makes the comparison a tautology. They are pinned against the production
///      library in exactly one place, `test/ModelL2SettlementAgreement.t.sol`, so a divergence is
///      reported once and loudly instead of being absorbed into every test that uses this.
library ModelL2Reference {
    /// @dev Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @dev Slash rate per tick of chargeable residual, as a numerator over 100. `25` == 0.25 bps.
    uint256 internal constant SLASH_SCALE = 25;

    /// @dev The dead zone, in ticks. ADR-0005 § 2.1, frozen at 5.
    uint256 internal constant DEAD_ZONE_TICKS = 5;

    /// @dev Each late window spans two blocks.
    uint256 internal constant LATE_WINDOW_BLOCKS = 2;

    /// @notice One late window's direction-aligned average displacement, from a per-block path.
    ///
    /// @dev `tickPath[k]` is the tick effective across `[open+k, open+k+1)`, so `tickPath` covers
    ///      the bond's ten observation blocks, indices 0..9.
    ///
    ///      Displacement is measured against `tickBefore`, the pool tick immediately BEFORE the
    ///      bonded swap — the trade's own zero. The alignment sign comes from the direction the
    ///      trade actually moved the price, so a late excursion the other way yields a NEGATIVE
    ///      result. It is never absolute-valued; clamping is the caller's job and happens per
    ///      window.
    ///
    ///      The division happens ONCE, at the end, after the baseline has been removed in
    ///      tick-block space. Dividing first and subtracting after is a different function under
    ///      truncation and is the specific mistake ADR-0005 § 3.3 warns about.
    ///
    /// @param tickPath Effective tick during each of the bond's ten observation blocks.
    /// @param from First block index of the window, inclusive.
    /// @param to Last block index, exclusive.
    function windowTwa(int24[10] memory tickPath, uint256 from, uint256 to, int24 tickBefore, int24 tickAfter)
        internal
        pure
        returns (int256)
    {
        int256 sum;

        for (uint256 k = from; k < to; k++) {
            sum += int256(tickPath[k]) - int256(tickBefore);
        }

        int256 sign = tickAfter > tickBefore ? int256(1) : int256(-1);

        return (sign * sum) / int256(to - from);
    }

    /// @notice `R = max( max(TWA(6,8), 0), max(TWA(8,10), 0) )`.
    ///
    /// @dev The two windows are disjoint and adjacent: blocks 6-7 and blocks 8-9. Each is clamped
    ///      at zero BEFORE the max, so a negative window cannot drag down a positive one.
    function residual(int24[10] memory tickPath, int24 tickBefore, int24 tickAfter) internal pure returns (uint256) {
        int256 late1 = windowTwa(tickPath, 6, 8, tickBefore, tickAfter);
        int256 late2 = windowTwa(tickPath, 8, 10, tickBefore, tickAfter);

        int256 c1 = late1 > 0 ? late1 : int256(0);
        int256 c2 = late2 > 0 ? late2 : int256(0);

        return uint256(c1 > c2 ? c1 : c2);
    }

    /// @notice The catch-up dead zone.
    ///
    /// @dev Written as an explicit three-case table rather than reusing production's branch order,
    ///      so a mistake in either boundary shows up as a disagreement:
    ///
    ///          R <= 5      ->  0
    ///          5 < R < 10  ->  2 * (R - 5)
    ///          R >= 10     ->  R
    ///
    ///      It leaves zero at `D` and rejoins the identity at `2D`, so every residual at or above
    ///      10 is charged exactly as if there were no dead zone.
    function chargeableResidual(uint256 residualTicks) internal pure returns (uint256) {
        if (residualTicks <= DEAD_ZONE_TICKS) return 0;

        if (residualTicks >= 2 * DEAD_ZONE_TICKS) return residualTicks;

        return 2 * (residualTicks - DEAD_ZONE_TICKS);
    }

    /// @notice `ceil(Q * 25 / 100)`, uncapped.
    function targetSlashBps(uint256 chargeable) internal pure returns (uint256) {
        uint256 numerator = chargeable * SLASH_SCALE;

        // Ceiling written as an explicit remainder test rather than the `+99` trick production
        // uses, so the two do not share a rounding idiom.
        uint256 whole = numerator / 100;

        return numerator % 100 == 0 ? whole : whole + 1;
    }

    /// @notice `slashBps = min(collateralBps, targetSlashBps(deadZone(R)))`.
    function slashBpsFor(uint256 collateralBps, uint256 residualTicks) internal pure returns (uint256) {
        uint256 target = targetSlashBps(chargeableResidual(residualTicks));

        return target < collateralBps ? target : collateralBps;
    }

    /// @notice The token split. Denominator is the VARIABLE LEG, never the collateral.
    ///
    /// @dev ADR-0005 § 3.1's rejected Form A divided the collateral by `collateralBps`, which
    ///      double-rounds and loses a wei as the impact rises. Both amounts here are floors of the
    ///      SAME leg over the SAME fixed denominator, and the refund is the difference.
    function split(uint128 variableLegAmount, uint256 collateralBps, uint256 slashBps)
        internal
        pure
        returns (uint128 collateral, uint128 slash, uint128 refund)
    {
        uint256 leg = uint256(variableLegAmount);

        collateral = uint128(leg * collateralBps / BPS);

        uint256 target = leg * slashBps / BPS;

        slash = uint128(target < collateral ? target : collateral);

        refund = collateral - slash;
    }

    /// @notice The whole settlement, from a per-block tick path.
    ///
    /// @dev The collateral rate comes from `ModelLReference`, which is the independent restatement
    ///      of ADR-0005 § 2.2 already pinned against the hook by
    ///      `test/ModelLReferenceAgreement.t.sol`. Reusing it here keeps one reference for one
    ///      rate rather than a third copy.
    function settle(uint128 variableLegAmount, int24 tickBefore, int24 tickAfter, int24[10] memory tickPath)
        internal
        pure
        returns (uint128 collateral, uint128 slash, uint128 refund, uint256 slashBps)
    {
        return settleAtRate(
            variableLegAmount, ModelLReference.collateralBps(tickBefore, tickAfter), tickBefore, tickAfter, tickPath
        );
    }

    /// @notice Settlement at an EXPLICIT collateral rate (ADR-0008 § 6).
    ///
    /// @dev THE RATE IS NOW AN INPUT, and it has to be. Before ADR-0008 the rate was a pure
    ///      function of the bond's two stored ticks, so this reference could re-derive it. The
    ///      effective rate also depends on `blockStartTick`, which is per-pool state that later
    ///      blocks overwrite, so it is unrecoverable at settlement time — the hook stores it in the
    ///      record and so must anything that prices a settlement independently.
    ///
    ///      `settle` above is kept as the own-impact special case, because a first-in-block bond's
    ///      stored rate IS the own-impact rate and several tests are about exactly that equality.
    ///
    ///      NOTE what is still derived rather than passed: `targetSlashBps`, from the tick path.
    ///      ADR-0008 changes the collateral rate and nothing else, so the residual half of the
    ///      calculation stays fully independent of the hook.
    function settleAtRate(
        uint128 variableLegAmount,
        uint256 collateralBps,
        int24 tickBefore,
        int24 tickAfter,
        int24[10] memory tickPath
    ) internal pure returns (uint128 collateral, uint128 slash, uint128 refund, uint256 slashBps) {
        slashBps = slashBpsFor(collateralBps, residual(tickPath, tickBefore, tickAfter));

        (collateral, slash, refund) = split(variableLegAmount, collateralBps, slashBps);
    }

    /// @notice A flat tick path: every observation block sits at `tick`.
    ///
    /// @dev The common fixture — a trade that moves the price and leaves it there. Written as a
    ///      helper because building it inline in twenty tests invites an off-by-one in the index.
    function flatPath(int24 tick) internal pure returns (int24[10] memory path) {
        for (uint256 k = 0; k < 10; k++) {
            path[k] = tick;
        }
    }
}
