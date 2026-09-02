// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ModelL2SettlementLib} from "../src/libraries/ModelL2SettlementLib.sol";
import {ModelL2Reference} from "./utils/ModelL2Reference.sol";

/// @title ModelL2SettlementAgreementTest
///
/// @notice The single place `test/utils/ModelL2Reference.sol` is pinned against the production
///         settlement library.
///
/// @dev WHY THIS IS CONCENTRATED IN ONE FILE. `ModelL2Reference` deliberately RESTATES ADR-0005's
///      constants instead of importing them, so that every differential using it compares the hook
///      against an independent statement of the specification rather than against itself. That
///      independence is only useful if a divergence is actually reported: without this file,
///      changing `DEAD_ZONE_TICKS` in production would make a dozen unrelated assertions fail with
///      confusing arithmetic mismatches and nothing would say why.
///
///      A deliberate change to Model L2 should fail exactly this file first, be resolved by editing
///      ADR-0005 and then both sides, and leave the rest of the suite meaning what it meant before.
contract ModelL2SettlementAgreementTest is Test {
    /// @notice Every constant the reference restates equals production's.
    function test_reference_constantsAgreeWithProduction() public pure {
        assertEq(
            ModelL2Reference.SLASH_SCALE,
            ModelL2SettlementLib.SLASH_SCALE,
            "SLASH_SCALE diverged: update ADR-0005 s2.1, then BOTH the library and the test reference"
        );

        assertEq(
            ModelL2Reference.DEAD_ZONE_TICKS,
            ModelL2SettlementLib.DEAD_ZONE_TICKS,
            "DEAD_ZONE_TICKS diverged: update ADR-0005 s2.1, then BOTH sides"
        );

        assertEq(
            ModelL2Reference.LATE_WINDOW_BLOCKS, ModelL2SettlementLib.LATE_WINDOW_BLOCKS, "LATE_WINDOW_BLOCKS diverged"
        );

        assertEq(ModelL2Reference.BPS, ModelL2SettlementLib.BPS, "BPS diverged");
    }

    /// @notice The frozen parameter values themselves, stated as literals.
    ///
    /// @dev Belt and braces over the equality above: if BOTH sides were edited together the
    ///      agreement test would still pass, and the parameters are frozen by ADR-0005 § 2.1
    ///      rather than merely required to be consistent. Changing either of these is an economic
    ///      decision that needs an ADR, not a code review.
    function test_frozenParametersHaveTheirFrozenValues() public pure {
        assertEq(ModelL2SettlementLib.DEAD_ZONE_TICKS, 5, "D is frozen at 5 by ADR-0005 s2.1");
        assertEq(ModelL2SettlementLib.SLASH_SCALE, 25, "SCALE is frozen at 0.25 bps/tick by ADR-0005 s2.1");
        assertEq(ModelL2SettlementLib.LATE_WINDOW_BLOCKS, 2, "each late window spans two blocks");
    }

    /// @notice The dead zone agrees across its whole domain, not merely at its constants.
    ///
    /// @dev Equal constants do not imply equal arithmetic: the two implementations use different
    ///      branch orders (`< 2D` versus `>= 2D`) and different ceiling idioms (`+99` versus an
    ///      explicit remainder test), so a boundary mistake in either would show here.
    function testFuzz_deadZoneAndRateAgreeAcrossTheDomain(uint32 rawR, uint16 rawCollateralBps) public pure {
        uint256 R = bound(rawR, 0, 1_000_000);
        uint256 collateralBps = bound(rawCollateralBps, 0, 100);

        assertEq(
            ModelL2SettlementLib.chargeableResidual(R),
            ModelL2Reference.chargeableResidual(R),
            "the dead zone diverged between production and the reference"
        );

        assertEq(ModelL2SettlementLib.targetSlashBps(R), ModelL2Reference.targetSlashBps(R), "targetSlashBps diverged");

        assertEq(
            ModelL2SettlementLib.slashBpsFor(collateralBps, R),
            ModelL2Reference.slashBpsFor(collateralBps, R),
            "slashBpsFor diverged"
        );
    }
}
