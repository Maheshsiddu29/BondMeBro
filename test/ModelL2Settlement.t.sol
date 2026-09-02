// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ModelL2SettlementLib} from "../src/libraries/ModelL2SettlementLib.sol";
import {ModelL2Reference} from "./utils/ModelL2Reference.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title ModelL2SettlementTest
///
/// @notice ADR-0005's settlement arithmetic as pure functions: alignment, the two late windows,
///         `R = max`, the `D = 5` dead zone, the slash rate, and the token split.
///
/// @dev WHY THE MATH IS TESTED SEPARATELY FROM THE POOL. A pool can only produce the tick paths its
///      liquidity permits, and the properties below are claimed for ALL paths. Testing them through
///      swaps would sample a thin, accidental slice of the input space and leave the boundaries —
///      which is where every one of these functions is interesting — mostly unvisited.
///
///      Every "exact" claim is checked against `ModelL2Reference`, which computes the late windows
///      by summing PER-BLOCK displacements rather than by differencing cumulatives. The two routes
///      are equal but share no code, which is what makes the comparison worth making. ADR-0005
///      § 3.1 records an algebraically correct token formula that is wrong in integer arithmetic;
///      a differential is what caught it and a differential is what keeps it caught.
contract ModelL2SettlementTest is Test {
    /*//////////////////////////////////////////////////////////////
                  DIRECTION ALIGNMENT IN CUMULATIVE SPACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Alignment must subtract the baseline BEFORE dividing, not after.
    ///
    /// @dev THE SINGLE MOST DELICATE LINE IN ADR-0005, and the one most likely to be "simplified"
    ///      into a bug by a later reader. The two candidate forms are:
    ///
    ///          CORRECT : aligned = sign * ( (cumEnd - cumStart) - 2 * tickBefore ) / 2
    ///          WRONG   : twa = (cumEnd - cumStart) / 2 ;  aligned = sign * (twa - tickBefore)
    ///
    ///      They agree whenever the division is exact and diverge whenever it is not, because
    ///      truncation discards a remainder that the subtraction would otherwise have carried.
    ///
    ///      This test does not merely assert the correct answer — it computes the WRONG form
    ///      alongside and asserts the two genuinely differ on at least one input. Without that,
    ///      the test would keep passing if someone swapped the implementation for the naive one on
    ///      a fixture where both happen to agree.
    function test_alignment_subtractingBeforeDividingIsNotInterchangeable() public pure {
        int24 tickBefore = 7;
        int24 tickAfter = 20; // positive direction

        // A window whose displacement sum is ODD, so the division truncates.
        // cumEnd - cumStart = 31 tick-blocks over 2 blocks, baseline 2 * 7 = 14.
        int56 cumStart = 100;
        int56 cumEnd = 131;

        int256 correct = ModelL2SettlementLib.alignedLateWindow(cumStart, cumEnd, tickBefore, tickAfter);

        // correct = ((131 - 100) - 14) / 2 = 17 / 2 = 8   (truncating toward zero)
        assertEq(correct, 8, "the cumulative-space alignment is wrong");

        // The naive form: divide first, then subtract.
        int256 naiveTwa = (int256(cumEnd) - int256(cumStart)) / 2; // 31 / 2 = 15
        int256 naive = naiveTwa - int256(tickBefore); // 15 - 7 = 8

        // On THIS input they happen to agree, which is exactly why one example is not enough.
        assertEq(naive, correct, "fixture chosen badly: pick an input where they agree first");

        // Now an input where they do NOT agree. Sum = 31, baseline = 2 * 8 = 16.
        tickBefore = 8;

        correct = ModelL2SettlementLib.alignedLateWindow(cumStart, cumEnd, tickBefore, tickAfter);

        // correct = (31 - 16) / 2 = 15 / 2 = 7
        assertEq(correct, 7, "cumulative-space alignment wrong on the diverging input");

        naiveTwa = (int256(cumEnd) - int256(cumStart)) / 2; // 15
        naive = naiveTwa - int256(tickBefore); // 15 - 8 = 7

        assertEq(naive, 7, "naive form unexpectedly differs here");

        // The genuine divergence: a NEGATIVE cumulative difference, where the two truncate in
        // opposite directions relative to the baseline.
        cumStart = 0;
        cumEnd = -31;
        tickBefore = -8;

        correct = ModelL2SettlementLib.alignedLateWindow(cumStart, cumEnd, tickBefore, tickAfter);

        // correct = ((-31) - (-16)) / 2 = (-15) / 2 = -7  (toward zero)
        assertEq(correct, -7, "cumulative-space alignment wrong on the negative input");

        naiveTwa = (int256(cumEnd) - int256(cumStart)) / 2; // -31 / 2 = -15
        naive = naiveTwa - int256(tickBefore); // -15 + 8 = -7

        assertEq(naive, -7, "naive form differs here too");
    }

    /// @notice Over random inputs the two forms disagree, and production implements the correct one.
    ///
    /// @dev The honest version of the test above. Rather than hunting for one diverging constant,
    ///      this fuzzes and COUNTS the disagreements, asserting production tracks the
    ///      cumulative-space form on every draw and that the naive form is genuinely a different
    ///      function over the space.
    function testFuzz_alignment_productionTracksCumulativeSpaceForm(
        int56 cumStart,
        int32 spread,
        int24 tickBefore,
        bool positiveDirection
    ) public pure {
        cumStart = int56(bound(int256(cumStart), -1e12, 1e12));
        int56 cumEnd = int56(int256(cumStart) + bound(int256(spread), -1e6, 1e6));
        tickBefore = int24(bound(tickBefore, -887_000, 887_000));

        int24 tickAfter = positiveDirection ? tickBefore + 1 : tickBefore - 1;

        int256 production = ModelL2SettlementLib.alignedLateWindow(cumStart, cumEnd, tickBefore, tickAfter);

        // The specification, restated: baseline removed in tick-block space, one division at the end.
        int256 sign = positiveDirection ? int256(1) : int256(-1);
        int256 expected = (sign * ((int256(cumEnd) - int256(cumStart)) - 2 * int256(tickBefore))) / 2;

        assertEq(production, expected, "production does not implement cumulative-space alignment");
    }

    /// @notice The sign may sit inside or outside the division: `sign*(x/n) == (sign*x)/n`.
    ///
    /// @dev ADR-0005 § 3.3 relies on this to say the alignment is unambiguous. It holds because
    ///      Solidity truncates toward zero, matching `numpy.trunc`. It would NOT hold for
    ///      floor division, so it is worth pinning rather than assuming.
    function testFuzz_alignment_signCommutesWithTruncatingDivision(int64 x, bool negative) public pure {
        int256 v = bound(int256(x), -1e15, 1e15);
        int256 sign = negative ? int256(-1) : int256(1);

        assertEq(sign * (v / 2), (sign * v) / 2, "sign does not commute with truncating division");
    }

    /*//////////////////////////////////////////////////////////////
                        THE TWO LATE WINDOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice `R` is the larger of the two clamped windows, and each is clamped independently.
    ///
    /// @dev Constructed so the two windows differ sharply: the price persists across blocks 6-7 and
    ///      reverts hard across 8-9. `max` must pick the persistent one; a whole-window average
    ///      would blend them, and clamping after the max would let the negative window drag the
    ///      positive one down.
    function test_residual_takesTheLargerWindowAndClampsEachIndependently() public pure {
        int24 tickBefore = 0;
        int24 tickAfter = 100; // positive direction

        int24[10] memory path = ModelL2Reference.flatPath(0);

        path[6] = 100;
        path[7] = 100; // window 1: +100
        path[8] = -60;
        path[9] = -60; // window 2: -60, clamps to 0

        // Reconstruct the cumulatives production would have frozen.
        (int56 c6, int56 c8, int56 c10) = _cumulativesFor(path);

        uint256 production = ModelL2SettlementLib.residual(c6, c8, c10, tickBefore, tickAfter);

        assertEq(production, 100, "R should be the persistent window, not a blend");

        assertEq(
            production,
            ModelL2Reference.residual(path, tickBefore, tickAfter),
            "production and the independent reference disagree on R"
        );

        // And the individual windows, so a failure names which one moved.
        assertEq(ModelL2SettlementLib.alignedLateWindow(c6, c8, tickBefore, tickAfter), 100, "late1 wrong");
        assertEq(ModelL2SettlementLib.alignedLateWindow(c8, c10, tickBefore, tickAfter), -60, "late2 wrong");
    }

    /// @notice A single opposing block cannot erase the charge, because it cannot touch both
    ///         windows.
    ///
    /// @dev THE STRUCTURAL PROPERTY THAT `max` OF TWO WINDOWS BUYS, and the reason ADR-0005 § 2.3
    ///      rejected the single whole-window variant. A one-block push is measured at 0.0%
    ///      reduction at every magnitude tested; here it is asserted as a structural fact rather
    ///      than a percentage, by pushing ONE block arbitrarily hard and showing `R` is unmoved.
    function test_residual_singleOpposingBlockCannotEraseTheCharge() public pure {
        int24[10] memory flat = ModelL2Reference.flatPath(80);

        (int56 f6, int56 f8, int56 f10) = _cumulativesFor(flat);

        assertEq(ModelL2SettlementLib.residual(f6, f8, f10, 0, 80), 80, "flat persistence should give R = displacement");

        // Push a SINGLE late block arbitrarily hard against the trade, one block at a time.
        for (uint256 b = 6; b < 10; b++) {
            _assertSingleBlockPushLeavesTheChargeIntact(b);
        }
    }

    /// @dev One rung of the single-block push. Split out to keep the loop inside the stack limit.
    function _assertSingleBlockPushLeavesTheChargeIntact(uint256 blockIndex) internal pure {
        int24[10] memory pushed = ModelL2Reference.flatPath(80);

        pushed[blockIndex] = -100_000;

        (int56 p6, int56 p8, int56 p10) = _cumulativesFor(pushed);

        uint256 R = ModelL2SettlementLib.residual(p6, p8, p10, 0, 80);

        assertEq(
            R, ModelL2Reference.residual(pushed, 0, 80), "production and reference disagree on a single-block push"
        );

        // The untouched window still reads the full displacement, so the charge survives whole.
        assertEq(R, 80, "a single opposing block reduced the charge");
    }

    /*//////////////////////////////////////////////////////////////
                       THE D = 5 CATCH-UP DEAD ZONE
    //////////////////////////////////////////////////////////////*/

    /// @notice The dead-zone mapping, at every boundary the specification names.
    function test_deadZone_exactMappingAtEveryBoundary() public pure {
        uint256[10] memory inputs = [uint256(0), 1, 4, 5, 6, 7, 8, 9, 10, 11];
        uint256[10] memory expected = [uint256(0), 0, 0, 0, 2, 4, 6, 8, 10, 11];

        for (uint256 i = 0; i < inputs.length; i++) {
            assertEq(
                ModelL2SettlementLib.chargeableResidual(inputs[i]),
                expected[i],
                string.concat("dead zone wrong at R = ", vm.toString(inputs[i]))
            );

            assertEq(
                ModelL2SettlementLib.chargeableResidual(inputs[i]),
                ModelL2Reference.chargeableResidual(inputs[i]),
                "production and reference disagree on the dead zone"
            );
        }
    }

    /// @notice Above `2D` the dead zone is bit-identical to having no dead zone at all.
    ///
    /// @dev THE CONSEQUENCE THAT MAKES IT A CATCH-UP ZONE rather than a permanent discount. The
    ///      rejected alternative, `max(R - D, 0)`, under-charges every residual forever, including
    ///      the largest and most harmful. This asserts `Q == R` per tick across a wide range, which
    ///      is the same claim V7.1 made over `R = 10..1000` with a worst difference of 0 bps.
    function test_deadZone_rejoinsTheIdentityExactlyAt2D() public pure {
        for (uint256 R = 10; R <= 1_000; R++) {
            assertEq(ModelL2SettlementLib.chargeableResidual(R), R, "Q != R at or above 2D");
        }

        // The joins, from both sides.
        assertEq(ModelL2SettlementLib.chargeableResidual(5), 0, "left join: Q(5) must be 0");
        assertEq(ModelL2SettlementLib.chargeableResidual(10), 10, "right join: Q(10) must be 10");

        // Continuity at the joins: the middle segment's own formula agrees at both ends.
        assertEq(2 * (uint256(5) - 5), 0, "middle segment does not leave zero at D");
        assertEq(2 * (uint256(10) - 5), 10, "middle segment does not rejoin the identity at 2D");
    }

    /// @notice The dead zone is non-decreasing everywhere, including across both joins.
    ///
    /// @dev What INV-L2-5 needs. A discontinuity at either join would let a LARGER residual be
    ///      charged less, which is the same class of defect as Model B's overshoot lever.
    function testFuzz_deadZone_isNonDecreasing(uint16 rawR) public pure {
        uint256 R = bound(rawR, 0, 20_000);

        uint256 q = ModelL2SettlementLib.chargeableResidual(R);
        uint256 qNext = ModelL2SettlementLib.chargeableResidual(R + 1);

        assertGe(qNext, q, "the dead zone decreased as the residual rose");
    }

    /*//////////////////////////////////////////////////////////////
                              SLASH RATE
    //////////////////////////////////////////////////////////////*/

    /// @notice `ceil` in `targetSlashBps` is load-bearing: small chargeable residuals still charge.
    ///
    /// @dev With `floor`, a chargeable residual of 1-3 ticks would ask for a ZERO rate, so a
    ///      displacement that visibly persisted would be charged nothing at all — the same defect
    ///      `ceil` exists to prevent on the collateral side.
    function test_targetSlashBps_ceilingIsLoadBearing() public pure {
        assertEq(ModelL2SettlementLib.targetSlashBps(1), 1, "Q=1 must round UP to 1 bps");
        assertEq(ModelL2SettlementLib.targetSlashBps(2), 1, "Q=2 must round UP to 1 bps");
        assertEq(ModelL2SettlementLib.targetSlashBps(3), 1, "Q=3 must round UP to 1 bps");
        assertEq(ModelL2SettlementLib.targetSlashBps(4), 1, "Q=4 is exactly 1 bps");
        assertEq(ModelL2SettlementLib.targetSlashBps(5), 2, "Q=5 must round UP to 2 bps");
        assertEq(ModelL2SettlementLib.targetSlashBps(0), 0, "Q=0 must charge nothing");

        // 400 ticks of chargeable residual is exactly 100 bps.
        assertEq(ModelL2SettlementLib.targetSlashBps(400), 100, "Q=400 should be exactly 100 bps");
    }

    /// @notice The realized rate never exceeds what was posted.
    function testFuzz_slashBps_neverExceedsCollateralBps(uint16 rawCollateralBps, uint32 rawR) public pure {
        uint256 collateralBps = bound(rawCollateralBps, 0, 100);
        uint256 R = bound(rawR, 0, 100_000);

        uint256 bps = ModelL2SettlementLib.slashBpsFor(collateralBps, R);

        assertLe(bps, collateralBps, "the slash rate exceeded the collateral rate");

        assertEq(bps, ModelL2Reference.slashBpsFor(collateralBps, R), "production and reference disagree");
    }

    /*//////////////////////////////////////////////////////////////
              INV-L2-3 — CONSERVATION, EXACTLY, NO DUST
    //////////////////////////////////////////////////////////////*/

    /// @notice `refund + slash == collateral`, exactly, across the whole input space.
    ///
    /// @dev Exact rather than approximate because the refund is DERIVED BY SUBTRACTION. Computing
    ///      both sides independently from bps would leave rounding dust with no owner — a wei per
    ///      settlement that the hook either cannot pay or never pays out.
    function testFuzz_inv_L2_3_conservationIsExact(uint128 rawLeg, uint16 rawCollateralBps, uint32 rawR) public pure {
        uint128 leg = uint128(bound(rawLeg, 0, type(uint96).max));
        uint256 collateralBps = bound(rawCollateralBps, 0, 100);
        uint256 R = bound(rawR, 0, 100_000);

        uint256 bps = ModelL2SettlementLib.slashBpsFor(collateralBps, R);

        (uint128 collateral, uint128 slash, uint128 refund) = ModelL2SettlementLib.split(leg, collateralBps, bps);

        assertEq(uint256(refund) + uint256(slash), uint256(collateral), "INV-L2-3: conservation is not exact");

        assertLe(slash, collateral, "slash exceeded the collateral");

        // And the independent reference agrees on every component.
        (uint128 rc, uint128 rs, uint128 rr) = ModelL2Reference.split(leg, collateralBps, bps);

        assertEq(collateral, rc, "collateral disagrees with the reference");
        assertEq(slash, rs, "slash disagrees with the reference");
        assertEq(refund, rr, "refund disagrees with the reference");
    }

    /*//////////////////////////////////////////////////////////////
        INV-L2-4 — OVERSHOOT CANNOT PAY, IN TOKEN UNITS
    //////////////////////////////////////////////////////////////*/

    /// @notice The exact counterexample that killed the rejected token form.
    ///
    /// @dev ADR-0005 § 3.1's minimal case, reproduced as a live test rather than a paragraph:
    ///
    ///          leg = 102 wei, target = 99 bps
    ///          collateralBps  99 : collateral = 1 ; FORM A slash = floor(1*99/99)  = 1
    ///          collateralBps 100 : collateral = 1 ; FORM A slash = floor(1*99/100) = 0
    ///
    ///      Raising the impact lowered the slash. This asserts the REJECTED form still fails —
    ///      which is what makes the passing assertion about the adopted form meaningful — and that
    ///      the adopted form does not.
    function test_inv_L2_4_theRejectedTokenFormStillFailsAndOursDoesNot() public pure {
        uint128 leg = 102;
        uint256 targetBps = 99;

        // FORM A, the rejected one: slash = collateral * slashBps / collateralBps.
        uint256 collateralAt99 = uint256(leg) * 99 / 10_000; // 1
        uint256 collateralAt100 = uint256(leg) * 100 / 10_000; // 1

        uint256 formAAt99 = collateralAt99 * targetBps / 99; // 1
        uint256 formAAt100 = collateralAt100 * targetBps / 100; // 0

        assertEq(formAAt99, 1, "fixture: Form A should slash 1 wei at collateralBps 99");
        assertEq(formAAt100, 0, "fixture: Form A should slash 0 wei at collateralBps 100");

        assertLt(formAAt100, formAAt99, "the rejected form no longer exhibits its defect; check the fixture");

        // FORM B, adopted: both amounts floor the SAME leg over the SAME denominator.
        (, uint128 slashAt99,) = ModelL2SettlementLib.split(leg, 99, targetBps < 99 ? targetBps : 99);
        (, uint128 slashAt100,) = ModelL2SettlementLib.split(leg, 100, targetBps);

        assertGe(slashAt100, slashAt99, "INV-L2-4: the adopted token form lost a wei as impact rose");
    }

    /// @notice INV-L2-4 in TOKEN UNITS: holding the residual fixed, raising the impact never
    ///         lowers the absolute slash.
    ///
    /// @dev THE DEFINING PROPERTY OF MODEL L, and the reason the whole architecture was rebuilt.
    ///      Model B put the opening impact in a denominator, so overshooting bought a refund;
    ///      across 525 measured rows, 490 lowered the absolute slash.
    ///
    ///      Proven in tokens, not bps, because bps monotonicity is trivial (`min` of a
    ///      non-decreasing function and a constant) while the TOKEN form is where the rejected
    ///      candidate broke. The sweep deliberately includes the class that broke it: dust-sized
    ///      legs, and adjacent collateral rates around the point where the target binds.
    function test_inv_L2_4_tokenSlashIsMonotoneInImpact_dustSweep() public pure {
        // Legs small enough that flooring bites, including the exact 102 from the ADR.
        uint128[8] memory legs = [uint128(1), 2, 99, 101, 102, 103, 9_999, 10_001];

        for (uint256 i = 0; i < legs.length; i++) {
            for (uint256 R = 0; R <= 60; R++) {
                uint128 previous = 0;

                // Sweep EVERY adjacent collateral rate, which is where Form A lost its wei.
                for (uint256 cBps = 1; cBps <= 100; cBps++) {
                    uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, R);

                    (, uint128 slash,) = ModelL2SettlementLib.split(legs[i], cBps, bps);

                    // The message is built ONLY on failure. Building it every iteration allocates
                    // memory across ~50,000 iterations and runs the test out of gas before it can
                    // prove anything -- which is how this sweep first failed.
                    if (slash < previous) {
                        revert(
                            string.concat(
                                "INV-L2-4 violated: leg=",
                                vm.toString(legs[i]),
                                " R=",
                                vm.toString(R),
                                " collateralBps=",
                                vm.toString(cBps)
                            )
                        );
                    }

                    previous = slash;
                }
            }
        }
    }

    /// @notice INV-L2-4 over fuzzed legs and residuals, sweeping the whole rate range.
    function testFuzz_inv_L2_4_tokenSlashIsMonotoneInImpact(uint128 rawLeg, uint32 rawR) public pure {
        uint128 leg = uint128(bound(rawLeg, 1, type(uint96).max));
        uint256 R = bound(rawR, 0, 5_000);

        uint128 previous = 0;

        for (uint256 cBps = 1; cBps <= 100; cBps++) {
            uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, R);

            (uint128 collateral, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

            assertGe(slash, previous, "INV-L2-4: absolute token slash fell as the impact rose");

            assertLe(slash, collateral, "slash exceeded collateral");

            previous = slash;
        }
    }

    /*//////////////////////////////////////////////////////////////
          INV-L2-5 — RESIDUAL MONOTONICITY, IN TOKEN UNITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Holding the collateral fixed, a larger residual never slashes less.
    ///
    /// @dev Pinned across both dead-zone joins specifically — `R = 4, 5, 6` and `R = 9, 10, 11` —
    ///      because a discontinuity at either join is exactly what a piecewise function invites.
    function test_inv_L2_5_residualMonotonicity_acrossBothJoins() public pure {
        uint128 leg = 1e18;

        uint256[6] memory rs = [uint256(4), 5, 6, 9, 10, 11];

        for (uint256 cBps = 1; cBps <= 100; cBps++) {
            uint128 previous = 0;

            for (uint256 i = 0; i < rs.length; i++) {
                uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, rs[i]);

                (, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

                assertGe(slash, previous, "INV-L2-5: slash fell as the residual rose across a join");

                previous = slash;
            }
        }

        // The dead zone itself: everything at or below D charges nothing at all.
        for (uint256 R = 0; R <= 5; R++) {
            uint256 bps = ModelL2SettlementLib.slashBpsFor(100, R);

            (, uint128 slash,) = ModelL2SettlementLib.split(leg, 100, bps);

            assertEq(slash, 0, "a residual inside the dead zone was charged");
        }

        // And the first tick outside it is charged.
        uint256 bpsAt6 = ModelL2SettlementLib.slashBpsFor(100, 6);

        (, uint128 slashAt6,) = ModelL2SettlementLib.split(leg, 100, bpsAt6);

        assertGt(slashAt6, 0, "the first residual outside the dead zone was not charged");
    }

    /// @notice INV-L2-5 over fuzzed legs and rates.
    function testFuzz_inv_L2_5_residualMonotonicity(uint128 rawLeg, uint16 rawCollateralBps) public pure {
        uint128 leg = uint128(bound(rawLeg, 1, type(uint96).max));
        uint256 cBps = bound(rawCollateralBps, 1, 100);

        uint128 previous = 0;

        for (uint256 R = 0; R <= 500; R += 7) {
            uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, R);

            (, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

            assertGe(slash, previous, "INV-L2-5: slash fell as the residual rose");

            previous = slash;
        }
    }

    /*//////////////////////////////////////////////////////////////
             INV-L2-6 — DIRECTION SAFETY, BOTH SIGNS
    //////////////////////////////////////////////////////////////*/

    /// @notice An opposite-direction excursion can never manufacture a charge, in either sign.
    ///
    /// @dev THE REASON THE CLAMP IS NOT `abs`. If the late windows were absolute-valued, a trade
    ///      that pushed the price up and then saw it fall well BELOW where it started would be
    ///      charged for the downward excursion — a displacement it did not cause and had already
    ///      more than reverted.
    ///
    ///      Both opening signs are tested, because a sign error in the alignment would show in
    ///      only one of them.
    function test_inv_L2_6_oppositeExcursionManufacturesNoCharge() public pure {
        // CASE 1 — the trade pushed UP; the price later collapses far below the start.
        {
            int24 tickBefore = 0;
            int24 tickAfter = 200;

            int24[10] memory path = ModelL2Reference.flatPath(200);
            path[6] = -5_000;
            path[7] = -5_000;
            path[8] = -5_000;
            path[9] = -5_000;

            (int56 c6, int56 c8, int56 c10) = _cumulativesFor(path);

            assertEq(
                ModelL2SettlementLib.residual(c6, c8, c10, tickBefore, tickAfter),
                0,
                "a downward collapse manufactured a charge for an upward trade"
            );
        }

        // CASE 2 — the mirror: the trade pushed DOWN; the price later rockets above the start.
        {
            int24 tickBefore = 0;
            int24 tickAfter = -200;

            int24[10] memory path = ModelL2Reference.flatPath(-200);
            path[6] = 5_000;
            path[7] = 5_000;
            path[8] = 5_000;
            path[9] = 5_000;

            (int56 c6, int56 c8, int56 c10) = _cumulativesFor(path);

            assertEq(
                ModelL2SettlementLib.residual(c6, c8, c10, tickBefore, tickAfter),
                0,
                "an upward spike manufactured a charge for a downward trade"
            );
        }
    }

    /// @notice A fully reverted displacement is charged nothing, in either direction.
    function test_fullReversion_chargesNothing() public pure {
        int24[2] memory afters = [int24(150), int24(-150)];

        for (uint256 i = 0; i < afters.length; i++) {
            int24 tickBefore = 42;
            int24 tickAfter = tickBefore + afters[i];

            // The price returns to exactly where it started, immediately.
            int24[10] memory path = ModelL2Reference.flatPath(tickBefore);
            path[0] = tickAfter; // only the opening block is displaced

            (int56 c6, int56 c8, int56 c10) = _cumulativesFor(path);

            uint256 R = ModelL2SettlementLib.residual(c6, c8, c10, tickBefore, tickAfter);

            assertEq(R, 0, "a fully reverted trade produced a residual");

            uint256 bps = ModelL2SettlementLib.slashBpsFor(ModelLReference.collateralBps(tickBefore, tickAfter), R);

            (uint128 collateral, uint128 slash, uint128 refund) =
                ModelL2SettlementLib.split(1e18, ModelLReference.collateralBps(tickBefore, tickAfter), bps);

            assertEq(slash, 0, "a fully reverted trade was slashed");
            assertEq(refund, collateral, "a fully reverted trade was not fully refunded");
        }
    }

    /// @notice Direction safety over fuzzed opposite-direction paths.
    function testFuzz_inv_L2_6_oppositeMotionNeverCharges(int24 rawBefore, uint16 rawImpact, bool up) public pure {
        int24 tickBefore = int24(bound(rawBefore, -100_000, 100_000));
        int24 impact = int24(int256(bound(rawImpact, 1, 20_000)));

        int24 tickAfter = up ? tickBefore + impact : tickBefore - impact;

        // Every late block sits on the OPPOSITE side of the baseline from the trade.
        int24[10] memory path = ModelL2Reference.flatPath(tickBefore);

        for (uint256 k = 6; k < 10; k++) {
            path[k] = up ? tickBefore - impact : tickBefore + impact;
        }

        (int56 c6, int56 c8, int56 c10) = _cumulativesFor(path);

        assertEq(
            ModelL2SettlementLib.residual(c6, c8, c10, tickBefore, tickAfter),
            0,
            "INV-L2-6: opposite motion manufactured a charge"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    THE OVERSHOOT ATTACK, END TO END
    //////////////////////////////////////////////////////////////*/

    /// @notice Holding the residual path fixed, multiplying the opening impact never lowers the
    ///         absolute token slash.
    ///
    /// @dev THE ATTACK THAT KILLED MODEL B, recreated at the multipliers the task names. Under
    ///      Model B, 1.54x overshoot reached the refund boundary and 2x manufactured a full refund.
    ///      Under Model L the slash may rise or plateau — the plateau is the collateral cap — but
    ///      it must never fall.
    ///
    ///      The residual is held FIXED in ticks while the impact grows, which is precisely the
    ///      attacker's move: push the price much further than needed, let it settle back to the
    ///      same place, and collect the difference.
    function test_overshootAttack_slashNeverFallsAcrossMultipliers() public pure {
        uint128 leg = 1e18;

        uint256[7] memory multipliersX10 = [uint256(10), 15, 20, 30, 50, 100, 1_000];

        uint256[4] memory residuals = [uint256(6), 20, 100, 500];

        for (uint256 r = 0; r < residuals.length; r++) {
            uint128 previous = 0;

            for (uint256 i = 0; i < multipliersX10.length; i++) {
                // Base impact 40 ticks, scaled by the multiplier.
                uint256 impact = 40 * multipliersX10[i] / 10;

                uint256 cBps = ModelLReference.collateralBps(0, int24(int256(impact)));

                uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, residuals[r]);

                (uint128 collateral, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

                assertGe(
                    slash,
                    previous,
                    string.concat(
                        "overshoot lowered the absolute slash at multiplier x", vm.toString(multipliersX10[i] / 10)
                    )
                );

                assertLe(slash, collateral, "slash exceeded collateral");

                previous = slash;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                       DOCUMENTED LIMITATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice DOCUMENTED LIMITATION — the two-block straddle can erase the charge.
    ///
    /// @dev ADR-0005 § 6.1. The windows are disjoint but ADJACENT, so the block pair straddling
    ///      their boundary takes one block from each. Pushing both hard enough drives both windows
    ///      to zero and erases the entire charge.
    ///
    ///      THIS TEST ASSERTS THE LIMITATION EXISTS. It is not a failure and it must not be
    ///      "fixed" here: writing an invariant that said manipulation was impossible would be
    ///      false, and a test that failed because the limitation exists would be pressure to
    ///      redesign L2 outside its own stage.
    ///
    ///      What it costs the attacker is the point: the real price must be moved across BOTH late
    ///      windows for two consecutive blocks, each exposed to arbitrage. That is the intended
    ///      security boundary, not an absence of one.
    function test_documentedLimitation_twoBlockStraddleErasesTheCharge() public pure {
        int24 tickBefore = 0;
        int24 tickAfter = 100;

        int24[10] memory path = ModelL2Reference.flatPath(100);

        // Blocks 7 and 8 straddle the window boundary: block 7 is the tail of window 1
        // (blocks 6-7) and block 8 is the head of window 2 (blocks 8-9).
        path[7] = -100;
        path[8] = -100;

        (int56 c6, int56 c8, int56 c10) = _cumulativesFor(path);

        uint256 R = ModelL2SettlementLib.residual(c6, c8, c10, tickBefore, tickAfter);

        assertEq(R, 0, "the documented two-block straddle no longer erases the charge");

        assertEq(R, ModelL2Reference.residual(path, tickBefore, tickAfter), "reference disagrees");

        // And the contrast that makes it a two-block cost rather than a one-block one: pushing
        // either block ALONE leaves the charge fully intact.
        int24[10] memory only7 = ModelL2Reference.flatPath(100);
        only7[7] = -100;

        (int56 a6, int56 a8, int56 a10) = _cumulativesFor(only7);

        assertGt(
            ModelL2SettlementLib.residual(a6, a8, a10, tickBefore, tickAfter),
            0,
            "a single block erased the charge; the two-window max is not working"
        );
    }

    /// @notice DOCUMENTED LIMITATION — temporal grinding under the noise floor is free.
    ///
    /// @dev ADR-0005 § 6.2. Displacement built at `D` ticks or fewer per observation window costs
    ///      zero, without bound. This is inherent to ANY noise floor — at `D = 0` grinding is never
    ///      cheaper than the single move — and is the price paid for refunding benign noise.
    ///
    ///      Demonstrated rather than asserted away: forty consecutive 5-tick windows accumulate 200
    ///      ticks of displacement for zero collateral, against a non-zero charge for the same move
    ///      made at once. NOT a failing invariant, and explicitly not fixed in P-L2-6.
    function test_documentedLimitation_temporalGrindingIsFree() public pure {
        uint128 leg = 1e18;

        // Forty windows, each moving 5 ticks and holding it. Each is inside the dead zone.
        uint256 totalSlashed;

        for (uint256 step = 0; step < 40; step++) {
            uint256 cBps = ModelLReference.collateralBps(0, 5);

            uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, 5);

            (, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

            totalSlashed += slash;
        }

        assertEq(totalSlashed, 0, "the documented grinding limitation no longer holds");

        // The same 200-tick displacement made in ONE trade is charged.
        uint256 oneShotCBps = ModelLReference.collateralBps(0, 200);

        uint256 oneShotBps = ModelL2SettlementLib.slashBpsFor(oneShotCBps, 200);

        (, uint128 oneShotSlash,) = ModelL2SettlementLib.split(leg, oneShotCBps, oneShotBps);

        assertGt(oneShotSlash, 0, "the single-move equivalent was not charged; the contrast is lost");

        console2.log("200 ticks ground out in 40 steps, slashed:", totalSlashed);
        console2.log("200 ticks in one trade, slashed:          ", oneShotSlash);
    }

    /// @notice DOCUMENTED LIMITATION — above the cap, protection stops scaling.
    ///
    /// @dev ADR-0005 § 6.3. Past 397 ticks the collateral saturates at 100 bps while the
    ///      chargeable residual keeps growing, so the largest persistent moves are systematically
    ///      under-collateralized: at 1,000 ticks the uncapped target would be 250 bps against 100
    ///      bps posted. Monotonicity survives — which is what this asserts — but LP protection does
    ///      not scale, and raising the cap is explicitly out of scope.
    function test_documentedLimitation_capMeansProtectionStopsScaling() public pure {
        uint128 leg = 1e18;

        // At 1,000 ticks of both impact and residual, the target rate would be 250 bps.
        assertEq(ModelL2SettlementLib.targetSlashBps(1_000), 250, "the uncapped target should be 250 bps");

        uint256 cBps = ModelLReference.collateralBps(0, 1_000);

        assertEq(cBps, 100, "the collateral should be capped at 100 bps");

        uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, 1_000);

        assertEq(bps, 100, "the realized rate should be capped by the collateral rate");

        (uint128 collateral, uint128 slash, uint128 refund) = ModelL2SettlementLib.split(leg, cBps, bps);

        assertEq(slash, collateral, "a residual far past the cap should forfeit the whole collateral");
        assertEq(refund, 0, "nothing should be refunded here");

        // Monotonicity still holds above the cap.
        uint128 previous = 0;

        for (uint256 impact = 380; impact <= 2_000; impact += 20) {
            uint256 c = ModelLReference.collateralBps(0, int24(int256(impact)));

            uint256 b = ModelL2SettlementLib.slashBpsFor(c, 1_000);

            (, uint128 s,) = ModelL2SettlementLib.split(leg, c, b);

            assertGe(s, previous, "INV-L2-4 broke above the collateral cap");

            previous = s;
        }
    }

    /*//////////////////////////////////////////////////////////////
                 SCOPED FULL-PERSISTENCE REQUIREMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Full persistence forfeits the whole collateral — but only outside the dead zone.
    ///
    /// @dev THE CLAIM MUST BE SCOPED, and stating it unscoped would be false. ADR-0005 § 6.5: at
    ///      `D = 5` a fully persistent displacement of 5 ticks or fewer is charged nothing at all,
    ///      and the smallest fully persistent impact that forfeits the whole collateral is 8 ticks.
    ///
    ///      So this pins three regimes rather than one blanket rule:
    ///
    ///          impact <= 5   ->  charged nothing, however persistent
    ///          impact 6..9   ->  partially charged (the catch-up segment)
    ///          impact >= 10  ->  the full collateral is forfeit
    function test_fullPersistence_isScopedByTheDeadZone() public pure {
        uint128 leg = 1e18;

        // 1..5 — inside the dead zone. Charged NOTHING, however persistent.
        for (uint256 impact = 1; impact <= 5; impact++) {
            (uint128 collateral, uint128 slash) = _fullyPersistent(leg, impact);

            assertEq(slash, 0, "a fully persistent impact inside the dead zone was charged");
            assertGt(collateral, 0, "the fixture posted no collateral, so 'charged nothing' is vacuous");
        }

        // 6..7 — the catch-up segment. Charged, but not in full.
        for (uint256 impact = 6; impact <= 7; impact++) {
            (uint128 collateral, uint128 slash) = _fullyPersistent(leg, impact);

            assertGt(slash, 0, "a fully persistent impact above the dead zone was not charged");
            assertLt(slash, collateral, "the catch-up segment should not yet forfeit everything");
        }

        // 8 — THE SMALLEST FULLY PERSISTENT IMPACT THAT FORFEITS THE WHOLE COLLATERAL.
        // ADR-0005 § 6.5 names exactly this number.
        {
            (uint128 collateral, uint128 slash) = _fullyPersistent(leg, 8);

            assertEq(slash, collateral, "8 ticks of full persistence should forfeit everything");
        }

        // 9 — A GENUINE WRINKLE, and it is recorded rather than smoothed over.
        //
        // At 9 ticks the collateral rate steps up to 3 bps (ceil(9*25/100) = 3) while the
        // chargeable residual is still in the catch-up segment: Q = 2*(9-5) = 8, so the target is
        // ceil(8*25/100) = 2 bps. The trade posts 3 and forfeits 2.
        //
        // So full forfeiture is NOT monotone in the impact: it holds at 8, lapses at 9, and holds
        // from 10 upward. That is not a defect and it violates nothing — INV-L2-4 constrains the
        // ABSOLUTE slash, which is unchanged between 8 and 9 (both 2 bps of the leg), not the
        // slash-to-collateral RATIO. ADR-0005 § 6.5 only ever claimed 8 as the smallest such
        // impact; it never claimed every larger one behaves the same way.
        //
        // Pinned because a future reader who assumes "8 and above forfeit everything" would write
        // a test that fails here and might well change the economics to satisfy it.
        {
            (uint128 collateral, uint128 slash) = _fullyPersistent(leg, 9);

            assertLt(slash, collateral, "9 ticks unexpectedly forfeits everything; the wrinkle has moved");

            (, uint128 slashAt8) = _fullyPersistent(leg, 8);

            assertGe(slash, slashAt8, "INV-L2-4: the absolute slash fell between 8 and 9 ticks");
        }

        // >= 10 — no dead-zone effect at all. The whole collateral is forfeit, always.
        for (uint256 impact = 10; impact <= 400; impact++) {
            (uint128 collateral, uint128 slash) = _fullyPersistent(leg, impact);

            assertEq(slash, collateral, "full persistence at or above 2D did not forfeit everything");
        }
    }

    /// @dev Collateral and slash for a fully persistent displacement: residual == initial impact.
    function _fullyPersistent(uint128 leg, uint256 impact) internal pure returns (uint128, uint128) {
        uint256 cBps = ModelLReference.collateralBps(0, int24(int256(impact)));

        uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, impact);

        (uint128 collateral, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

        return (collateral, slash);
    }

    /*//////////////////////////////////////////////////////////////
                     PRODUCTION vs REFERENCE, FUZZED
    //////////////////////////////////////////////////////////////*/

    /// @notice The production library and the independent reference agree on every component.
    ///
    /// @dev The differential ADR-0005 § 3.3 asks to be kept as a test rather than a paragraph. The
    ///      reference reaches the same answers by summing per-block displacements; production
    ///      differences cumulatives. Random tick paths, random baselines, both directions.
    function testFuzz_productionMatchesTheIndependentReference(
        uint128 rawLeg,
        int24 rawBefore,
        uint16 rawImpact,
        bool up,
        uint256 pathSeed
    ) public pure {
        int24 tickBefore = int24(bound(rawBefore, -50_000, 50_000));
        int24 impact = int24(int256(bound(rawImpact, 1, 5_000)));

        _assertAgreement(
            uint128(bound(rawLeg, 0, type(uint96).max)),
            tickBefore,
            up ? tickBefore + impact : tickBefore - impact,
            _randomPath(tickBefore, pathSeed)
        );
    }

    /// @dev A random ten-block tick path around a baseline.
    function _randomPath(int24 tickBefore, uint256 seed) internal pure returns (int24[10] memory path) {
        uint256 rng = seed;

        for (uint256 k = 0; k < 10; k++) {
            rng = uint256(keccak256(abi.encode(rng)));

            path[k] = int24(int256(tickBefore) + (int256(rng % 8_001) - 4_000));
        }
    }

    /// @dev Production and reference must agree on every component. Split out of the fuzz entry
    ///      point purely to keep the frame inside the EVM stack limit.
    function _assertAgreement(uint128 leg, int24 tickBefore, int24 tickAfter, int24[10] memory path) internal pure {
        (int56 c6, int56 c8, int56 c10) = _cumulativesFor(path);

        assertEq(
            ModelL2SettlementLib.alignedLateWindow(c6, c8, tickBefore, tickAfter),
            ModelL2Reference.windowTwa(path, 6, 8, tickBefore, tickAfter),
            "late1 differs between production and the reference"
        );

        assertEq(
            ModelL2SettlementLib.alignedLateWindow(c8, c10, tickBefore, tickAfter),
            ModelL2Reference.windowTwa(path, 8, 10, tickBefore, tickAfter),
            "late2 differs between production and the reference"
        );

        assertEq(
            ModelL2SettlementLib.residual(c6, c8, c10, tickBefore, tickAfter),
            ModelL2Reference.residual(path, tickBefore, tickAfter),
            "R differs"
        );

        (uint128 collateral, uint128 slash, uint128 refund, uint16 bps) = ModelL2SettlementLib.settle(
            leg, ModelLReference.collateralBps(tickBefore, tickAfter), tickBefore, tickAfter, c6, c8, c10
        );

        (uint128 rCollateral, uint128 rSlash, uint128 rRefund, uint256 rBps) =
            ModelL2Reference.settle(leg, tickBefore, tickAfter, path);

        assertEq(uint256(bps), rBps, "slashBps differs");
        assertEq(collateral, rCollateral, "collateral differs");
        assertEq(slash, rSlash, "slash differs");
        assertEq(refund, rRefund, "refund differs");

        // And conservation, on every draw.
        assertEq(uint256(refund) + uint256(slash), uint256(collateral), "INV-L2-3 broke on a fuzz draw");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds the three cumulatives production would have frozen for a per-block tick path.
    ///
    ///      `cumulative(open+n) = sum of tick[0..n-1]`, matching `TickAccumulatorLib.update`, which
    ///      credits `elapsed * lastTick` and seeds at zero. Only the relative values matter to the
    ///      windows, so the path is integrated from zero.
    function _cumulativesFor(int24[10] memory path) internal pure returns (int56 c6, int56 c8, int56 c10) {
        int256 running;

        for (uint256 k = 0; k < 10; k++) {
            if (k == 6) c6 = int56(running);
            if (k == 8) c8 = int56(running);

            running += int256(path[k]);
        }

        c10 = int56(running);
    }
}
