// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PersistenceMathLib} from "../src/libraries/PersistenceMathLib.sol";

/// @notice The settlement curve is the mechanism. These are pure-function tests, so they run
///         without a PoolManager and complete in milliseconds — this is the suite to keep
///         green while everything else is in flux.
contract PersistenceMathLibTest is Test {
    uint24 constant TOL = 5;

    // Canonical scenario from the design doc, zeroForOne: price/tick moves DOWN.
    int24 constant BEFORE_0F1 = 1000;
    int24 constant AFTER_0F1 = 950; // impactAbs = 50

    // oneForZero mirror: price/tick moves UP.
    int24 constant BEFORE_1F0 = 1000;
    int24 constant AFTER_1F0 = 1050;

    function _bps(int24 tickBefore, int24 tickAfter, int24 ref) internal pure returns (uint16) {
        return PersistenceMathLib.computeBps(tickBefore, tickAfter, ref, TOL);
    }

    // ---------------------------------------------------------------------
    // zeroForOne
    // ---------------------------------------------------------------------

    function test_zeroForOne_FullReversion_Refunds() public pure {
        // Price came all the way back to where it started.
        assertEq(_bps(BEFORE_0F1, AFTER_0F1, 1000), 0);
    }

    function test_zeroForOne_OppositeOvershoot_Refunds() public pure {
        // Price reverted past the start. remaining is negative.
        assertEq(_bps(BEFORE_0F1, AFTER_0F1, 1030), 0);
    }

    function test_zeroForOne_PartialReversion_PartialSlash() public pure {
        // Half the impact survived: remaining = 25, impactAbs = 50.
        // (25 - 5) * 10000 / (50 - 5) = 4444
        uint16 p = _bps(BEFORE_0F1, AFTER_0F1, 975);
        assertEq(p, 4444);
    }

    /// @notice THE case the deprecated continuation rule got wrong.
    function test_zeroForOne_StaysAtTickAfter_FullSlash() public pure {
        // Price sat exactly where the trade left it. Under the old rule this refunded.
        assertEq(_bps(BEFORE_0F1, AFTER_0F1, 950), 10_000);
    }

    function test_zeroForOne_ContinuesPastTickAfter_FullSlash() public pure {
        // Continuation is a strictly stronger signal than the plateau; clamped, not >100%.
        assertEq(_bps(BEFORE_0F1, AFTER_0F1, 900), 10_000);
    }

    // ---------------------------------------------------------------------
    // oneForZero — the sign convention must mirror exactly
    // ---------------------------------------------------------------------

    function test_oneForZero_FullReversion_Refunds() public pure {
        assertEq(_bps(BEFORE_1F0, AFTER_1F0, 1000), 0);
    }

    function test_oneForZero_PartialReversion_PartialSlash() public pure {
        assertEq(_bps(BEFORE_1F0, AFTER_1F0, 1025), 4444);
    }

    function test_oneForZero_StaysAtTickAfter_FullSlash() public pure {
        assertEq(_bps(BEFORE_1F0, AFTER_1F0, 1050), 10_000);
    }

    function test_oneForZero_ContinuesPastTickAfter_FullSlash() public pure {
        assertEq(_bps(BEFORE_1F0, AFTER_1F0, 1100), 10_000);
    }

    /// @notice Direction symmetry: a mirrored trade in a mirrored market must price identically.
    function testFuzz_DirectionSymmetry(int16 impact, int16 drift) public pure {
        vm.assume(impact != 0);
        int24 i = int24(impact);
        int24 d = int24(drift);

        uint16 down = _bps(1000, 1000 - i, 1000 - i + d);
        uint16 up = _bps(1000, 1000 + i, 1000 + i - d);
        assertEq(down, up, "settlement must be direction-symmetric");
    }

    // ---------------------------------------------------------------------
    // Noise floor and boundary behaviour
    // ---------------------------------------------------------------------

    function test_impactAbsBelowRefundTol_NoSlash() public pure {
        // impactAbs = 3 <= TOL = 5. Early return, no division.
        assertEq(_bps(1000, 997, 997), 0);
    }

    function test_impactAbsEqualsRefundTol_NoSlash() public pure {
        assertEq(_bps(1000, 995, 995), 0);
    }

    function test_zeroImpact_NoSlash() public pure {
        assertEq(_bps(1000, 1000, 900), 0);
    }

    /// @notice No cliff: the curve must rise continuously out of the refund zone.
    /// @dev The earlier `remaining * 10000 / impactAbs` form jumped to 1200 bps one tick past
    ///      the tolerance. A discontinuity is a boundary an attacker pays to sit exactly on.
    function test_persistenceCurve_NoCliffAtRefundTolerance() public pure {
        uint16 atTol = _bps(BEFORE_0F1, AFTER_0F1, 995); // remaining == 5 == TOL
        uint16 justPast = _bps(BEFORE_0F1, AFTER_0F1, 994); // remaining == 6

        assertEq(atTol, 0);
        assertEq(justPast, 222); // 1 * 10000 / 45
        assertLt(justPast, 500, "curve jumped at the refund boundary");
    }

    /// @notice The degenerate-denominator bug: with a `max(impactAbs - tol, 1)` guard, a
    ///         small-impact swap would saturate to 10000 on the first tick past tolerance.
    ///         The early return must prevent that instead.
    function test_smallImpact_DoesNotSaturate() public pure {
        // impactAbs = 4, below TOL = 5.
        assertEq(_bps(1000, 996, 990), 0, "small impact must refund, not saturate");
    }

    // ---------------------------------------------------------------------
    // Curve properties
    // ---------------------------------------------------------------------

    /// @notice Persistence must never decrease as more of the impact survives.
    function testFuzz_MonotonicInRemaining(int24 refA, int24 refB) public pure {
        vm.assume(refA > -800_000 && refA < 800_000);
        vm.assume(refB > -800_000 && refB < 800_000);
        vm.assume(refA >= refB); // zeroForOne: lower ref == more surviving impact

        uint16 pA = _bps(BEFORE_0F1, AFTER_0F1, refA);
        uint16 pB = _bps(BEFORE_0F1, AFTER_0F1, refB);
        assertLe(pA, pB, "persistence must be monotonic");
    }

    function testFuzz_AlwaysWithinBounds(int24 tickBefore, int24 tickAfter, int24 ref, uint16 tol) public pure {
        vm.assume(tickBefore > -800_000 && tickBefore < 800_000);
        vm.assume(tickAfter > -800_000 && tickAfter < 800_000);
        vm.assume(ref > -800_000 && ref < 800_000);

        uint16 p = PersistenceMathLib.computeBps(tickBefore, tickAfter, ref, uint24(tol));
        assertLe(p, 10_000);
    }

    /// @notice Conservation: the bond is fully accounted for, with no rounding leak.
    function testFuzz_SplitConserves(uint128 bond, uint16 pBps) public pure {
        vm.assume(pBps <= 10_000);
        (uint128 slash, uint128 refund) = PersistenceMathLib.split(bond, pBps);
        assertEq(uint256(slash) + uint256(refund), uint256(bond), "bond not conserved");
    }

    function testFuzz_SplitRoundsInTradersFavour(uint128 bond, uint16 pBps) public pure {
        vm.assume(pBps <= 10_000);
        (uint128 slash,) = PersistenceMathLib.split(bond, pBps);
        assertLe(uint256(slash) * 10_000, uint256(bond) * uint256(pBps), "slash rounded up");
    }

    // ---------------------------------------------------------------------
    // Documented limitation
    // ---------------------------------------------------------------------

    /// @notice This test is expected to PASS and documents a weakness, not a bug.
    ///         The identical trade settles as full refund or full slash purely on market
    ///         drift direction. This is why BondMeBro is framed as outcome-linked LP
    ///         insurance rather than per-trade toxicity attribution. Keep this test; it is
    ///         the honest answer to "what if the market moved for unrelated reasons?"
    function test_driftDominatesSignal_KnownLimitation() public pure {
        // Same trade every time: tick 1000 -> 950, impact 50 down.
        uint16 flat = _bps(BEFORE_0F1, AFTER_0F1, 950); // no drift
        uint16 withTrend = _bps(BEFORE_0F1, AFTER_0F1, 900); // 50 ticks of same-direction drift
        uint16 againstTrend = _bps(BEFORE_0F1, AFTER_0F1, 1000); // 50 ticks of opposite drift

        assertEq(flat, 10_000);
        assertEq(withTrend, 10_000);
        assertEq(againstTrend, 0);

        console2.log("same trade, flat market      ->", flat);
        console2.log("same trade, with-trend drift ->", withTrend);
        console2.log("same trade, against drift    ->", againstTrend);
    }
}
