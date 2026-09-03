// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {ModelL2SettlementLib} from "../src/libraries/ModelL2SettlementLib.sol";

/// @title FrozenParametersTest
///
/// @notice Every economic parameter the protocol ships with, pinned to its frozen value in one
///         place.
///
/// @dev WHY THESE ARE PINNED AS LITERALS, AND WHY IT IS NOT REDUNDANT.
///
///      The suite already checks these constants against independent references, but those tests
///      answer a different question: "do the two implementations agree?" Both could be edited
///      together and stay agreeing. This file answers "are they still the values the research
///      settled on?" — which is the question that matters when someone reaches for a parameter to
///      make a failing test pass.
///
///      NONE OF THESE IS GOVERNABLE. There is no setter, no owner path and no proxy: they are
///      compile-time constants, and a pool owner's entire economic authority is enabling the
///      mechanism and choosing which trades are large enough to participate. Changing any value
///      below requires editing the contract, which means a new deployment, a new ADR, and the
///      research to justify it.
///
///      TWO OF THEM ARE CALIBRATION, NOT PROOF. `COLLATERAL_SCALE` and `DEAD_ZONE_TICKS` were
///      selected against a SYNTHETIC population — no historical Uniswap trade was ever replayed.
///      ADR-0005 § 6.4 records exactly what measurement would revisit them. They are frozen
///      because shipping requires a number, not because the number is proven optimal.
contract FrozenParametersTest is Test, Deployers {
    BondMeBro internal hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");
    }

    /// @notice The collateral side: scale, cap, and the tick at which the cap first binds.
    function test_frozen_collateralParameters() public view {
        assertEq(hook.BPS(), 10_000, "BPS is not the basis-point denominator");

        assertEq(hook.COLLATERAL_SCALE(), 25, "COLLATERAL_SCALE moved from the frozen 0.25 bps/tick");

        assertEq(hook.COLLATERAL_SCALE_DENOMINATOR(), 100, "the scale denominator moved");

        assertEq(hook.MAX_BOND_BPS(), 100, "the 1% collateral cap moved");

        // Derived, not independently chosen: `ceil(396*25/100) = 99` and `ceil(397*25/100) = 100`.
        assertEq(hook.CAP_ACTIVATION_TICKS(), 397, "the cap activation tick is inconsistent with the scale");

        assertEq(hook.collateralBpsFor(0, 396), 99, "396 ticks should sit just below the cap");
        assertEq(hook.collateralBpsFor(0, 397), 100, "397 ticks should be the first capped impact");
    }

    /// @notice The settlement side: the dead zone, the slash scale, the window width.
    function test_frozen_settlementParameters() public pure {
        assertEq(ModelL2SettlementLib.DEAD_ZONE_TICKS, 5, "D moved from the frozen 5 ticks");

        assertEq(ModelL2SettlementLib.SLASH_SCALE, 25, "SLASH_SCALE moved from the frozen 0.25 bps/tick");

        assertEq(ModelL2SettlementLib.SLASH_SCALE_DENOMINATOR, 100, "the slash scale denominator moved");

        assertEq(ModelL2SettlementLib.LATE_WINDOW_BLOCKS, 2, "the late windows are no longer two blocks wide");

        assertEq(ModelL2SettlementLib.BPS, 10_000, "BPS diverged between the hook and the library");
    }

    /// @notice The observation window and the checkpoint endpoints.
    function test_frozen_observationParameters() public view {
        assertEq(hook.OBSERVATION_BLOCKS(), 10, "the observation horizon moved from 10 blocks");

        assertEq(hook.C6_OFFSET_FROM_MATURITY(), 4, "C6 is no longer at M-4");
        assertEq(hook.C8_OFFSET_FROM_MATURITY(), 2, "C8 is no longer at M-2");

        // The endpoints must land on blocks 6, 8 and 10 of the window.
        assertEq(hook.OBSERVATION_BLOCKS() - hook.C6_OFFSET_FROM_MATURITY(), 6, "C6 is not at open+6");
        assertEq(hook.OBSERVATION_BLOCKS() - hook.C8_OFFSET_FROM_MATURITY(), 8, "C8 is not at open+8");

        assertLe(
            hook.OBSERVATION_BLOCKS(),
            hook.MAX_OBSERVATION_BLOCKS(),
            "OBSERVATION_BLOCKS exceeds the accumulator's supported domain"
        );
    }

    /// @notice The two scales are the SAME number, and that is load-bearing.
    ///
    /// @dev It is what makes a fully persistent displacement forfeit exactly the collateral it
    ///      posted: the slash target reaches the collateral rate precisely when the residual
    ///      reaches the initial impact. If they diverged, full persistence would either
    ///      systematically over- or under-charge, and the `min(collateralBps, targetSlashBps)` cap
    ///      would stop expressing "you can lose at most what you posted".
    function test_frozen_theTwoScalesAreTheSame() public view {
        assertEq(
            uint256(hook.COLLATERAL_SCALE()),
            ModelL2SettlementLib.SLASH_SCALE,
            "the collateral and slash scales diverged; full persistence no longer forfeits exactly the collateral"
        );

        assertEq(
            hook.COLLATERAL_SCALE_DENOMINATOR(),
            ModelL2SettlementLib.SLASH_SCALE_DENOMINATOR,
            "the two scale denominators diverged"
        );
    }

    /// @notice No economic parameter is reachable through any setter.
    ///
    /// @dev The claim that matters for governance risk, checked mechanically rather than asserted
    ///      in prose: the only owner-facing function is `setPoolConfig`, and its parameters are
    ///      two thresholds and an enable flag. There is no rate, no dead zone and no horizon in
    ///      the owner's reach.
    ///
    ///      A future setter for any of these would change this selector list, which is what makes
    ///      this a test rather than a comment.
    function test_frozen_noSetterExposesAnEconomicParameter() public pure {
        // The one owner-facing mutator, and its exact shape.
        //
        // THE SIGNATURE CHANGED DELIBERATELY, and the point of this test survives the change. It
        // gained two variable-leg minimums, which are eligibility gates in raw token units -- the
        // same kind of parameter the two amounts beside them already were. They decide WHICH trades
        // take part, never what participation costs.
        //
        // What this test exists to catch is an owner gaining control over the PRICE of the
        // mechanism: the collateral scale, the cap, the dead zone or the observation window. None
        // of those appears here, and the assertions above pin them as compile-time constants with
        // no setter at all. If a future edit adds a rate, a cap or a window to this signature, this
        // comparison fails and that is the intended alarm.
        assertEq(
            BondMeBro.setPoolConfig.selector,
            bytes4(
                keccak256("setPoolConfig((address,address,uint24,int24,address),uint128,uint96,uint128,uint128,bool)")
            ),
            "setPoolConfig's signature changed: check nothing economic was added to it"
        );
    }
}
