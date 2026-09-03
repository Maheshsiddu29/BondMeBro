// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ModelL2SettlementLib} from "../../src/libraries/ModelL2SettlementLib.sol";

/// @title AuditSettlementMath
///
/// @notice AUDIT ONLY. Independent re-derivation of the settlement arithmetic, written from
///         ADR-0005's stated rules rather than by calling the production helpers and comparing them
///         to themselves.
contract AuditSettlementMathTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_BPS = 100;

    /// @dev Independent restatement of the dead zone: 0 on [0,5], slope 2 on (5,10), identity above.
    function _chargeable(uint256 r) internal pure returns (uint256) {
        if (r <= 5) return 0;
        if (r < 10) return 2 * (r - 5);
        return r;
    }

    /// @dev Independent ceil(q * 25 / 100).
    function _target(uint256 q) internal pure returns (uint256) {
        return (q * 25 + 99) / 100;
    }

    /*//////////////////////////////////////////////////////////////
                  § 20 -- CONSERVATION AND MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /// @notice refund + slash == collateral, exactly, with no lost wei.
    function testFuzz_audit_conservationIsExact(uint128 leg, uint16 cBps, uint32 residual) public pure {
        cBps = uint16(bound(cBps, 1, MAX_BPS));
        residual = uint32(bound(residual, 0, 5_000));

        uint256 slashBps = ModelL2SettlementLib.slashBpsFor(cBps, residual);

        (uint128 collateral, uint128 slash, uint128 refund) = ModelL2SettlementLib.split(leg, cBps, slashBps);

        assertEq(uint256(refund) + uint256(slash), uint256(collateral), "refund + slash != collateral");
        assertLe(slash, collateral, "slash exceeded collateral");
    }

    /// @notice The production slash rate agrees with an independent derivation of the same rule.
    function testFuzz_audit_slashRateMatchesIndependentDerivation(uint16 cBps, uint32 residual) public pure {
        cBps = uint16(bound(cBps, 1, MAX_BPS));
        residual = uint32(bound(residual, 0, 5_000));

        uint256 expected = _target(_chargeable(residual));

        if (expected > cBps) expected = cBps;

        assertEq(ModelL2SettlementLib.slashBpsFor(cBps, residual), expected, "slash rate diverged from the ADR rule");
    }

    /// @notice INV-L2-5. Increasing the residual can never decrease the absolute token slash.
    ///
    /// @dev Walks every residual across both dead-zone joins at a fixed leg and rate, in TOKEN
    ///      units rather than bps -- integer truncation is where a monotone rate can still produce
    ///      a non-monotone amount.
    function testFuzz_audit_slashIsMonotoneInResidual(uint128 leg, uint16 cBps) public pure {
        cBps = uint16(bound(cBps, 1, MAX_BPS));

        uint128 previous;

        for (uint256 r = 0; r <= 60; r++) {
            uint256 slashBps = ModelL2SettlementLib.slashBpsFor(cBps, r);

            (, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, slashBps);

            assertGe(slash, previous, "INV-L2-5: a higher residual produced a lower absolute slash");

            previous = slash;
        }
    }

    /// @notice INV-L2-4-style: at a fixed residual, a higher collateral rate never lowers the slash.
    ///
    /// @dev This is the token-unit form ADR-0005 § 3.1 says the rejected ratio formula broke. Swept
    ///      exhaustively over every adjacent rate pair at dust-sized legs, which is the class that
    ///      produced the original one-wei counterexample.
    function test_audit_slashIsMonotoneInCollateralRateAtDustLegs() public pure {
        uint128[8] memory legs = [uint128(1), 2, 99, 101, 102, 103, 9_999, 10_001];
        uint256[6] memory residuals = [uint256(0), 6, 9, 10, 60, 400];

        for (uint256 l = 0; l < legs.length; l++) {
            for (uint256 r = 0; r < residuals.length; r++) {
                uint128 previous;

                for (uint256 c = 1; c <= MAX_BPS; c++) {
                    uint256 slashBps = ModelL2SettlementLib.slashBpsFor(c, residuals[r]);

                    (, uint128 slash,) = ModelL2SettlementLib.split(legs[l], c, slashBps);

                    assertGe(slash, previous, "a higher collateral rate lowered the absolute slash");

                    previous = slash;
                }
            }
        }
    }

    /// @notice The dead zone is continuous at both joins and never decreasing.
    function test_audit_deadZoneJoins() public pure {
        assertEq(ModelL2SettlementLib.chargeableResidual(5), 0, "D join at 5 is not zero");
        assertEq(ModelL2SettlementLib.chargeableResidual(6), 2, "slope-2 segment wrong at 6");
        assertEq(ModelL2SettlementLib.chargeableResidual(9), 8, "slope-2 segment wrong at 9");
        assertEq(ModelL2SettlementLib.chargeableResidual(10), 10, "2D join does not rejoin identity");
        assertEq(ModelL2SettlementLib.chargeableResidual(11), 11, "identity segment wrong at 11");

        uint256 previous;

        for (uint256 r = 0; r <= 200; r++) {
            uint256 q = ModelL2SettlementLib.chargeableResidual(r);

            assertGe(q, previous, "chargeable residual decreased");

            previous = q;
        }
    }

    /*//////////////////////////////////////////////////////////////
              § 19 -- SIGNED DIVISION IN THE LATE WINDOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Direction alignment: an opposite-direction excursion is negative, never a charge.
    ///
    /// @dev The clamp is applied by `residual`, per window, before the max. This checks the raw
    ///      aligned value is genuinely signed, so the clamp has something to do.
    function test_audit_alignedWindowIsSignedNotAbsolute() public pure {
        // Upward trade (tickAfter > tickBefore) whose late window sits BELOW the baseline.
        int256 down = ModelL2SettlementLib.alignedLateWindow(0, -200, 0, 100);

        assertLt(down, 0, "an opposite-direction window was not negative: abs() would be a bug");

        // The same geometry for a downward trade.
        int256 up = ModelL2SettlementLib.alignedLateWindow(0, 200, 0, -100);

        assertLt(up, 0, "an opposite-direction window was not negative for the mirrored direction");

        // And the residual clamps both to zero rather than charging them.
        assertEq(ModelL2SettlementLib.residual(0, -200, -400, 0, 100), 0, "a reversal manufactured a residual");
        assertEq(ModelL2SettlementLib.residual(0, 200, 400, 0, -100), 0, "a reversal manufactured a residual");
    }

    /// @notice Truncation toward zero is applied consistently for both signs.
    ///
    /// @dev Solidity `/` truncates toward zero, so `sign * (x / n)` and `(sign * x) / n` agree. The
    ///      production comment claims that equivalence; this checks it on values whose numerator is
    ///      not divisible by the window width, which is where the two forms could diverge.
    function testFuzz_audit_alignedWindowTruncationIsSymmetric(int56 cumEnd, int24 tickBefore) public pure {
        vm.assume(tickBefore > -800_000 && tickBefore < 800_000);
        vm.assume(cumEnd > -1e15 && cumEnd < 1e15);

        int256 numerator = int256(cumEnd) - 2 * int256(tickBefore);

        int256 up = ModelL2SettlementLib.alignedLateWindow(0, cumEnd, tickBefore, tickBefore + 1);
        int256 down = ModelL2SettlementLib.alignedLateWindow(0, cumEnd, tickBefore, tickBefore - 1);

        assertEq(up, numerator / 2, "upward alignment diverged from the stated formula");
        assertEq(down, (-numerator) / 2, "downward alignment diverged from the stated formula");
    }
}
