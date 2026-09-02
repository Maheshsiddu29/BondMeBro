// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title ModelLReferenceAgreementTest
///
/// @notice The single place where `test/utils/ModelLReference.sol` is pinned against the hook.
///
/// @dev THE POINT OF CONCENTRATING THIS IN ONE FILE.
///
///      `ModelLReference` deliberately RESTATES the Model L constants instead of importing them,
///      so that every test using it is checking the hook against an independent statement of the
///      specification rather than against the hook itself. That independence is only useful if a
///      divergence is actually reported: without this file, changing `COLLATERAL_SCALE` in the
///      hook would simply make dozens of unrelated assertions fail with confusing arithmetic
///      mismatches, and nothing would say *why*.
///
///      So the constants are compared here, once, with messages that name the cause. A deliberate
///      change to Model L should fail exactly this file first, be resolved by editing ADR-0005 and
///      then both sides, and leave the rest of the suite meaning what it meant before.
///
///      INV-L2-2 is also proven here rather than in an integration test, because the rate is a
///      pure function and a pure function deserves an exhaustive sweep rather than a sampling of
///      whatever impacts a pool happened to produce.
contract ModelLReferenceAgreementTest is Test, Deployers {
    BondMeBro internal hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");
    }

    /// @notice Every constant the reference restates must equal the hook's own.
    function test_reference_constantsAgreeWithTheHook() public view {
        assertEq(
            ModelLReference.COLLATERAL_SCALE,
            hook.COLLATERAL_SCALE(),
            "COLLATERAL_SCALE diverged: update ADR-0005 s2.2, then BOTH the hook and the test reference"
        );

        assertEq(
            ModelLReference.MAX_BOND_BPS,
            hook.MAX_BOND_BPS(),
            "MAX_BOND_BPS diverged: update ADR-0005 s2.2, then BOTH the hook and the test reference"
        );

        assertEq(
            ModelLReference.CAP_ACTIVATION_TICKS,
            hook.CAP_ACTIVATION_TICKS(),
            "CAP_ACTIVATION_TICKS diverged: this is a DERIVED value, so recompute it rather than editing it"
        );

        assertEq(ModelLReference.BPS, hook.BPS(), "BPS diverged");
    }

    /// @notice INV-L2-2, exhaustively over every impact from zero to well past the cap.
    ///
    /// @dev Three properties in one sweep, because they constrain each other:
    ///
    ///        1. the rate never exceeds the cap;
    ///        2. it is non-decreasing in the impact -- a bigger move can never cost less;
    ///        3. it is symmetric in direction.
    ///
    ///      The range runs to 1,200 rather than stopping at the cap so the flat region above 397
    ///      is actually exercised. A sweep that ended at the boundary would pass even if the rate
    ///      resumed climbing one tick later.
    function test_inv_L2_2_rateIsCappedMonotoneAndSymmetric() public pure {
        uint256 previous = 0;

        for (uint32 impact = 0; impact <= 1_200; impact++) {
            uint256 up = ModelLReference.collateralBps(0, int24(int32(impact)));
            uint256 down = ModelLReference.collateralBps(0, -int24(int32(impact)));

            assertEq(up, down, "INV-L2-2: the rate must depend on |impact|, never on its sign");

            assertLe(up, ModelLReference.MAX_BOND_BPS, "INV-L2-2: the rate exceeded the cap");

            assertGe(up, previous, "INV-L2-2: the rate decreased as the impact grew");

            previous = up;
        }
    }

    /// @notice `ceil` is load-bearing: small but non-zero impacts must not round to a zero rate.
    ///
    /// @dev This is the specific defect `floor` would introduce. Under `floor(ticks * 0.25)` an
    ///      impact of 1, 2 or 3 ticks yields zero, so a swap that demonstrably moved the price
    ///      would post no collateral at all -- and, because a zero bond is treated as unbonded,
    ///      would leave no record either. Every impact from 1 to 3 is checked individually
    ///      because they are exactly the values that differ between the two roundings.
    function test_ceilingIsLoadBearing_smallImpactsStillCharge() public pure {
        assertEq(ModelLReference.collateralBps(0, 1), 1, "a 1-tick impact must round UP to 1 bps");
        assertEq(ModelLReference.collateralBps(0, 2), 1, "a 2-tick impact must round UP to 1 bps");
        assertEq(ModelLReference.collateralBps(0, 3), 1, "a 3-tick impact must round UP to 1 bps");
        assertEq(ModelLReference.collateralBps(0, 4), 1, "a 4-tick impact is exactly 1 bps");
        assertEq(ModelLReference.collateralBps(0, 5), 2, "a 5-tick impact must round UP to 2 bps");

        assertEq(ModelLReference.collateralBps(0, 0), 0, "a zero impact must charge nothing");
    }

    /// @notice The cap activation boundary, to the tick: 396 / 397 / 398.
    ///
    /// @dev INV-L2-2 names 397 as the first capped impact, and an off-by-one here would be
    ///      invisible in any test that only checked "the rate is at most 100".
    function test_capActivationBoundary_isExactlyAt397() public pure {
        assertEq(ModelLReference.collateralBps(0, 396), 99, "396 ticks must still be below the cap");
        assertEq(ModelLReference.collateralBps(0, 397), 100, "397 ticks must be the FIRST capped impact");
        assertEq(ModelLReference.collateralBps(0, 398), 100, "398 ticks must remain at the cap");

        assertEq(
            ModelLReference.collateralBps(0, int24(int32(ModelLReference.CAP_ACTIVATION_TICKS))),
            ModelLReference.MAX_BOND_BPS,
            "CAP_ACTIVATION_TICKS does not actually activate the cap"
        );

        assertLt(
            ModelLReference.collateralBps(0, int24(int32(ModelLReference.CAP_ACTIVATION_TICKS - 1))),
            ModelLReference.MAX_BOND_BPS,
            "the tick below CAP_ACTIVATION_TICKS is already capped, so the constant is too high"
        );
    }

    /// @notice The reference agrees with the hook across the whole rate curve, not just at its
    ///         constants.
    ///
    /// @dev Equal constants do not imply equal arithmetic: the two could still differ in rounding,
    ///      in where the cap is applied, or in how the absolute value is taken. Both directions are
    ///      swept so a sign-handling difference cannot hide.
    function testFuzz_reference_agreesWithHookAcrossTheCurve(int24 tickBefore, int24 tickAfter) public view {
        tickBefore = int24(bound(tickBefore, -887_000, 887_000));
        tickAfter = int24(bound(tickAfter, -887_000, 887_000));

        assertEq(
            ModelLReference.collateralBps(tickBefore, tickAfter),
            hook.collateralBpsFor(tickBefore, tickAfter),
            "the independent reference and the hook disagree on the Model L rate"
        );
    }
}
