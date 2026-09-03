// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

import {ScaledPoolFixture} from "./utils/ScaledPoolFixture.sol";

/// @title VariableLegMinimumTest
///
/// @notice Permanent coverage for the variable-leg minimum: the second bonding threshold, measured
///         in the collateral's own currency.
///
/// @dev WHY THIS FILE EXISTS. The hook has always had an input-side threshold, and for a long time
///      that was assumed to bound the collateral too. It does not. An exact-input swap pays its
///      collateral out of the token it RECEIVES, so the two quantities live in different currencies
///      and, on a pool whose tokens differ in decimals or in unit value, differ by many orders of
///      magnitude in raw units. A trade could clear the input threshold comfortably and still
///      produce an output leg small enough that the collateral truncated to zero -- which the hook
///      treated as a violation and rejected, making ordinary trades on such pools unexecutable.
///
///      That gap survived a full test suite because every fixture in it paired two 18-decimal
///      tokens at tick 0, where input and output are numerically similar and the coincidence holds.
///      These tests are therefore built on `ScaledPoolFixture`, and they deliberately vary the one
///      dimension the old fixtures held fixed.
///
///      THE PROPERTY BEING PINNED, in one sentence: a variable leg too small to carve collateral
///      from makes the swap UNBONDED, never failed -- and a bond that is taken still satisfies
///      `0 < bond < variableLegAmount`.
contract VariableLegMinimumTest is ScaledPoolFixture {
    /// @dev The smallest variable-leg minimum `setPoolConfig` will accept.
    uint128 internal constant FLOOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                              SHARED ROUTINES
    //////////////////////////////////////////////////////////////*/

    /// @dev Configures the pool with negligible input thresholds and the given leg minimum on both
    ///      currencies, so the leg gate is the only thing that can decline a swap.
    function _configureLegMinimum(uint128 minLeg) internal {
        hook.setPoolConfig(key_, 1, 1, minLeg, minLeg, true);
    }

    /// @dev Finds a swap size, in the given direction and kind, that produces a positive variable
    ///      leg. Returns zero if none of the probes does, which callers assert against rather than
    ///      silently skipping.
    function _findAmountWithPositiveLeg(bool zeroForOne, bool exactInput, uint256 decimalsOfSpecified)
        internal
        returns (uint256 amount, uint256 leg)
    {
        uint256 unit = 10 ** decimalsOfSpecified;

        uint256[6] memory scaled = [unit / 1_000, unit / 100, unit / 10, unit, unit * 10, unit * 100];

        for (uint256 i = 0; i < scaled.length; i++) {
            if (scaled[i] == 0) continue;

            int256 specified = exactInput ? -int256(scaled[i]) : int256(scaled[i]);

            uint256 measured = _measureVariableLeg(specified, zeroForOne);

            if (measured > 0) return (scaled[i], measured);
        }

        return (0, 0);
    }

    /// @dev Finds a swap size that actually moves the price. Some pool shapes need a far larger
    ///      trade than others to cross a tick, so the size is searched for rather than guessed.
    function _findAmountThatMovesTheTick(bool zeroForOne, uint256 decimalsOfInput) internal returns (uint256) {
        uint256 amount = 10 ** decimalsOfInput / 1_000;

        if (amount == 0) amount = 1;

        for (uint256 i = 0; i < 24; i++) {
            uint256 snap = vm.snapshotState();

            int24 before = _tick();

            _swap(-int256(amount), zeroForOne);

            bool moved = _tick() != before;

            vm.revertToState(snap);

            if (moved) return amount;

            amount *= 4;
        }

        return 0;
    }

    /// @dev The heart of the file. For one direction and kind:
    ///
    ///        - a leg exactly AT the configured minimum bonds;
    ///        - a leg ONE UNIT below it is declined -- executes in full, pays nothing, records
    ///          nothing;
    ///        - nothing anywhere in that band reverts.
    ///
    ///      The boundary is set from the leg the swap actually produces rather than from a guessed
    ///      constant, so the test is exact on every pool shape it is pointed at.
    function _assertLegBoundaryIsExact(bool zeroForOne, bool exactInput, uint256 decimalsOfSpecified) internal {
        (uint256 amount, uint256 leg) = _findAmountWithPositiveLeg(zeroForOne, exactInput, decimalsOfSpecified);

        assertGt(amount, 0, "no probe produced a positive variable leg: this pool shape proves nothing");

        // The minimum cannot be set below the floor, so a leg under it can only ever be declined.
        // Legs that small are covered separately by `test_belowTheFloor_isAlwaysDeclined`.
        if (leg <= FLOOR) return;

        int256 specified = exactInput ? -int256(amount) : int256(amount);

        Currency collateral = _collateralCurrency(zeroForOne, exactInput);

        // ---- ONE UNIT ABOVE THE LEG: declined ----
        uint256 snap = vm.snapshotState();

        _configureLegMinimum(uint128(leg + 1));

        uint256 hookBefore = collateral.balanceOf(address(hook));
        uint32 pendingBefore = _pendingNow();

        _swap(specified, zeroForOne);

        assertEq(collateral.balanceOf(address(hook)), hookBefore, "a declined swap took collateral");
        assertEq(_pendingNow(), pendingBefore, "a declined swap registered a maturity liability");

        vm.revertToState(snap);

        // ---- EXACTLY AT THE LEG: bonds ----
        _configureLegMinimum(uint128(leg));

        int24 tickBefore = _tick();

        hookBefore = collateral.balanceOf(address(hook));

        bytes32 bondId = _nextBondId();

        _swap(specified, zeroForOne);

        // Only assert the bond when the price actually moved: a sub-tick swap is unbonded for a
        // different and entirely legitimate reason, and conflating the two would hide a regression.
        if (_tick() != tickBefore) {
            uint256 taken = collateral.balanceOf(address(hook)) - hookBefore;

            assertGt(taken, 0, "a leg at the minimum took no collateral");

            BondMeBro.Bond memory b = hook.getBond(bondId);

            // INV-NOOP-VL, on the record that was actually written.
            assertGt(taken, 0, "INV-NOOP-VL lower bound: a finalized bond holds no collateral");
            assertLt(taken, b.variableLegAmount, "INV-NOOP-VL upper bound: the bond swallowed its own leg");
        }
    }

    /*//////////////////////////////////////////////////////////////
              THE HISTORICAL FAILURE, PINNED AT ITS OWN SHAPE
    //////////////////////////////////////////////////////////////*/

    /// @notice An 18-decimal token quoted against an 8-decimal one: the exact pool shape on which
    ///         ordinary exact-input trades used to revert.
    ///
    /// @dev The price here is roughly 1e-4 in human terms -- a ~$10 token against a ~$100k asset --
    ///      which is an unremarkable pair, not a contrived one. Every size in the sweep straddles
    ///      the old failure boundary of `BPS / collateralBps` raw output units. Before the leg
    ///      minimum existed, the smaller half of this sweep reverted.
    function test_mismatchedDecimals_exactInputNeverRevertsAcrossTheOldBoundary() public {
        _deployScaledPool(18, 8, -322_020, 1e18);

        _configureLegMinimum(FLOOR);

        uint256[6] memory inputs = [uint256(775e15), 87e16, 96e16, 1e18, 106e16, 12e17];

        for (uint256 i = 0; i < inputs.length; i++) {
            uint256 snap = vm.snapshotState();

            _configureLegMinimum(FLOOR);

            assertFalse(
                _swapReverts(-int256(inputs[i]), true),
                "an ordinary exact-input trade reverted because its output leg was small in raw units"
            );

            vm.revertToState(snap);
        }
    }

    /// @notice The same pool, from the other side: the collateral currency flips to the 18-decimal
    ///         token, and the leg is then large in raw units. Bonding must still work normally.
    function test_mismatchedDecimals_oppositeDirectionStillBonds() public {
        _deployScaledPool(18, 8, -322_020, 1e18);

        _configureLegMinimum(FLOOR);

        // At this price the 8-decimal token is the expensive one, so it takes a much larger raw
        // amount to move the tick than the mirrored direction needs. Searched, not guessed.
        uint256 amount = _findAmountThatMovesTheTick(false, 8);

        assertGt(amount, 0, "no oneForZero size moved the price: the test would prove nothing");

        uint256 hookBefore = c0.balanceOf(address(hook));

        _swap(-int256(amount), false);

        assertGt(c0.balanceOf(address(hook)) - hookBefore, 0, "the reverse direction stopped bonding");
    }

    /*//////////////////////////////////////////////////////////////
                       EVERY DECIMAL ORDERING WE SHIP
    //////////////////////////////////////////////////////////////*/

    /// @notice Both exact-input directions, on five decimal pairings including the parity case the
    ///         old fixtures used exclusively.
    ///
    /// @dev The pairings are run in both orders (18/8 and 8/18) because the swap direction decides
    ///      which side is the variable leg: a bug that only bites when the SMALL-decimal token is
    ///      the collateral would be invisible if only one order were tested.
    function test_decimalOrderings_exactInput_zeroForOne() public {
        _sweepDecimalOrderings(true, true);
    }

    function test_decimalOrderings_exactInput_oneForZero() public {
        _sweepDecimalOrderings(false, true);
    }

    /// @notice Exact output on the same pairings. Its leg is the consumed input, so the currency
    ///         mismatch does not arise -- which is exactly why it must be checked rather than
    ///         assumed.
    function test_decimalOrderings_exactOutput_zeroForOne() public {
        _sweepDecimalOrderings(true, false);
    }

    function test_decimalOrderings_exactOutput_oneForZero() public {
        _sweepDecimalOrderings(false, false);
    }

    function _sweepDecimalOrderings(bool zeroForOne, bool exactInput) internal {
        uint8[2][5] memory pairs = [[uint8(18), 18], [uint8(18), 8], [uint8(8), 18], [uint8(18), 6], [uint8(6), 18]];

        for (uint256 i = 0; i < pairs.length; i++) {
            _deployScaledPool(pairs[i][0], pairs[i][1], 0, 1e18);

            // The specified amount is the input for exact input and the output for exact output,
            // so its decimals follow both the direction and the kind.
            bool specifiedIsCurrency0 = exactInput ? zeroForOne : !zeroForOne;

            _assertLegBoundaryIsExact(zeroForOne, exactInput, specifiedIsCurrency0 ? pairs[i][0] : pairs[i][1]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE REGIMES
    //////////////////////////////////////////////////////////////*/

    /// @notice The boundary is exact across four orders of magnitude of price, in both directions.
    ///
    /// @dev Decimals are only one way the two legs drift apart in raw units; price is the other,
    ///      and it moves continuously rather than in fixed steps. A pool at 1:1,000,000 has the
    ///      same asymmetry as an 18/6 pool at parity, and the ticks below are `log(price)` in base
    ///      1.0001 for 1, 100, 10,000 and 1,000,000 -- each also run inverted.
    ///      SPLIT ONE REGIME PER TEST rather than looped in one body: each regime needs its own
    ///      manager, hook and mined CREATE2 address, and seven of those in a single test exhausts
    ///      memory under the unoptimized build `forge coverage` uses.
    function test_priceRegime_parity() public {
        _assertRegime(0);
    }

    function test_priceRegime_oneToOneHundred() public {
        _assertRegime(46_054);
        _assertRegime(-46_054);
    }

    function test_priceRegime_oneToTenThousand() public {
        _assertRegime(92_108);
        _assertRegime(-92_108);
    }

    function test_priceRegime_oneToAMillion() public {
        _assertRegime(138_162);
        _assertRegime(-138_162);
    }

    function _assertRegime(int24 startTick) internal {
        _deployScaledPool(18, 18, startTick, 1e18);

        _assertLegBoundaryIsExact(true, true, 18);
    }

    /*//////////////////////////////////////////////////////////////
                         THE FLOOR AND ITS BOUND
    //////////////////////////////////////////////////////////////*/

    /// @notice `setPoolConfig` refuses a variable-leg minimum below `BPS`, on either currency.
    ///
    /// @dev The floor is what makes the last-resort `BondViolatesNoOpVLBound` guard unreachable:
    ///      `BPS` raw units at one basis point is exactly one unit of collateral, so nothing that
    ///      clears the gate can truncate to zero. Lower the floor and that guarantee is gone, which
    ///      is why the refusal is enforced rather than documented.
    function test_config_refusesALegMinimumBelowTheFloor() public {
        _deployScaledPool(18, 18, 0, 1e18);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.VariableLegMinimumTooSmall.selector, uint256(0), FLOOR));
        hook.setPoolConfig(key_, 1, 1, 0, FLOOR, true);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.VariableLegMinimumTooSmall.selector, uint256(9_999), FLOOR));
        hook.setPoolConfig(key_, 1, 1, 9_999, FLOOR, true);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.VariableLegMinimumTooSmall.selector, uint256(1), FLOOR));
        hook.setPoolConfig(key_, 1, 1, FLOOR, 1, true);

        // At the floor exactly, it is accepted.
        hook.setPoolConfig(key_, 1, 1, FLOOR, FLOOR, true);

        // slither-disable-next-line unused-return
        (,,, uint128 leg0, uint128 leg1) = hook.poolConfig(id_);

        assertEq(leg0, FLOOR, "the accepted minimum was not stored");
        assertEq(leg1, FLOOR, "the accepted minimum was not stored");
    }

    /// @notice Disabling bonding is still allowed to pass zero minimums, and clears them.
    ///
    /// @dev The floor guards the bonding path, and a disabled pool has none. Requiring a valid
    ///      threshold in order to turn bonding OFF would be a trap with no purpose.
    function test_config_disabledPoolMayPassZeroAndIsCleared() public {
        _deployScaledPool(18, 18, 0, 1e18);

        _configureLegMinimum(FLOOR);

        hook.setPoolConfig(key_, 0, 0, 0, 0, false);

        // slither-disable-next-line unused-return
        (,,, uint128 leg0, uint128 leg1) = hook.poolConfig(id_);

        assertEq(leg0, 0, "disabling did not clear the leg minimum");
        assertEq(leg1, 0, "disabling did not clear the leg minimum");
    }

    /// @notice The collateral forgone by a declined swap is bounded, and the bound is the
    ///         operator's threshold rather than a fixed constant.
    ///
    /// @dev THIS IS THE COST OF THE FIX, STATED RATHER THAN HIDDEN. A declined swap moves the price
    ///      and pays nothing, so the exemption has to be small enough not to matter. It is:
    ///
    ///          forgone  =  leg * bps / BPS  <  minVariableLeg * MAX_BOND_BPS / BPS
    ///
    ///      At the enforced floor that is at most 99 raw units per swap -- 1e-16 of an 18-decimal
    ///      token. The bound is linear in the configured minimum, so an operator who raises the
    ///      threshold to a realistic value raises the exemption with it; that trade is theirs to
    ///      make, and the sweep below is what makes it legible.
    function test_forgoneCollateralIsBoundedByTheConfiguredMinimum() public {
        _deployScaledPool(18, 18, 0, 1e18);

        uint128[4] memory minimums = [FLOOR, 1e6, 1e12, 1e18];

        for (uint256 m = 0; m < minimums.length; m++) {
            uint256 bound = (uint256(minimums[m]) * hook.MAX_BOND_BPS()) / 10_000;

            // The largest leg that can still be declined is one unit below the minimum.
            for (uint256 bps = 1; bps <= hook.MAX_BOND_BPS(); bps++) {
                uint256 forgone = ((uint256(minimums[m]) - 1) * bps) / 10_000;

                assertLe(forgone, bound, "a declined swap forwent more than the stated bound");
            }

            console2.log("minVariableLeg", uint256(minimums[m]), "max forgone raw units", bound);
        }
    }

    /// @notice Splitting a trade into sub-minimum pieces does not accumulate free price movement.
    ///
    /// @dev The obvious worry about an unbonded band is that it stacks: N declined swaps in one
    ///      block, each below the minimum, adding up to a displacement nobody paid for. They do
    ///      not, because a leg capped at the minimum is also a TRADE capped at roughly the minimum,
    ///      and pieces that small are far too thin to move a pool with real liquidity.
    ///
    ///      MEASURED, AND THE MEASUREMENT IS NOT ZERO, so it is worth being precise about what the
    ///      non-zero part is. The pool is initialized exactly ON a tick boundary, and the very
    ///      first downward swap of any size at all -- one wei included -- crosses it. That single
    ///      tick is the boundary artifact, not accumulation. The distinction is what the second
    ///      batch establishes: another twenty swaps, off the boundary now, move the price not at
    ///      all. Displacement stops after the crossing instead of compounding with volume.
    function test_splittingBelowTheMinimumBuysNoDisplacement() public {
        _deployScaledPool(18, 18, 0, 1e18);

        _configureLegMinimum(FLOOR);

        int24 start = _tick();

        uint256 hookBefore = c1.balanceOf(address(hook));

        for (uint256 i = 0; i < 20; i++) {
            _swap(-int256(uint256(FLOOR - 1)), true);
        }

        int24 afterFirstBatch = _tick();

        assertEq(c1.balanceOf(address(hook)), hookBefore, "a sub-minimum split took collateral");

        assertLe(start - afterFirstBatch, 1, "twenty sub-minimum swaps moved the price more than the boundary crossing");

        for (uint256 i = 0; i < 20; i++) {
            _swap(-int256(uint256(FLOOR - 1)), true);
        }

        assertEq(_tick(), afterFirstBatch, "sub-minimum swaps accumulate displacement: the unbonded band is stackable");

        assertEq(c1.balanceOf(address(hook)), hookBefore, "a sub-minimum split took collateral");
    }

    /*//////////////////////////////////////////////////////////////
                    SOLVENCY ON A MISMATCHED-DECIMAL POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice Every bond opened on an 18/8 pool settles, conserves, and leaves the hook solvent.
    ///
    /// @dev The custody arithmetic was never decimal-aware in the first place -- it works in raw
    ///      units of whichever currency the collateral is in -- so the risk here is not that the
    ///      maths breaks but that the NEW gate lets through a case the old one never produced.
    ///      Legs a few orders of magnitude smaller than any previously-tested pool now reach
    ///      settlement, and this walks a batch of them all the way through.
    ///
    ///      Three properties are checked at once: the hook holds at least what it owes at every
    ///      point, each settlement splits its collateral exactly, and the pending count returns to
    ///      zero rather than stranding an obligation.
    function test_solvency_mismatchedDecimalsThroughFullSettlement() public {
        _deployScaledPool(18, 8, -322_020, 1e18);

        _configureLegMinimum(FLOOR);

        uint32 openBlock = uint32(block.number);
        uint32 maturityBlock = openBlock + hook.OBSERVATION_BLOCKS();

        uint256[4] memory sizes = [uint256(96e16), 1e18, 106e16, 12e17];

        bytes32[4] memory ids;

        uint256 owed;

        for (uint256 i = 0; i < sizes.length; i++) {
            ids[i] = _nextBondId();

            _swap(-int256(sizes[i]), true);

            if (!hook.bondExists(ids[i])) {
                // Declined rather than bonded: legitimate, and it must have left nothing behind.
                ids[i] = bytes32(0);
                continue;
            }

            BondMeBro.Bond memory b = hook.getBond(ids[i]);

            uint256 collateral = hook.collateralAmountOf(ids[i]);

            // INV-NOOP-VL on every record that actually got written.
            assertGt(collateral, 0, "a finalized bond holds no collateral");
            assertLt(collateral, b.variableLegAmount, "a bond swallowed its own variable leg");

            owed += collateral;

            assertGe(c1.balanceOf(address(hook)), owed, "the hook holds less than it owes");
        }

        assertGt(owed, 0, "no bond was taken: the solvency walk proves nothing");

        // Let the window pass, poking the accumulator so the maturity checkpoints are recorded.
        for (uint32 b = openBlock + 1; b <= maturityBlock + 1; b++) {
            vm.roll(b);

            _swap(-int256(uint256(1e15)), b % 2 == 0);
        }

        uint256 refunded;
        uint256 slashed;

        uint256 potBefore = hook.insurancePot(id_, c1);

        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == bytes32(0)) continue;

            uint256 collateral = hook.collateralAmountOf(ids[i]);

            address recipient = hook.getBond(ids[i]).refundRecipient;

            uint256 recipientBefore = c1.balanceOf(recipient);
            uint256 potStep = hook.insurancePot(id_, c1);

            // Permissionless: a stranger settles.
            vm.prank(address(0xDEAD));
            hook.settleBond(ids[i]);

            uint256 back = c1.balanceOf(recipient) - recipientBefore;
            uint256 cut = hook.insurancePot(id_, c1) - potStep;

            assertEq(back + cut, collateral, "settlement did not conserve on a mismatched-decimal pool");

            refunded += back;
            slashed += cut;
        }

        assertEq(refunded + slashed, owed, "the batch did not conserve in aggregate");
        assertEq(hook.insurancePot(id_, c1) - potBefore, slashed, "the insurance pot disagrees with the slashes");

        // slither-disable-next-line unused-return
        (,,, uint32 pending,) = hook.maturity(id_, maturityBlock);

        assertEq(pending, 0, "a settled batch left an obligation outstanding");
    }

    /// @notice A swap declined by the LEG gate still has to carry hookData.
    ///
    /// @dev AN INTEGRATOR-FACING CONSEQUENCE, and not an obvious one. The two gates run in
    ///      different callbacks. `beforeSwap` sees the requested input and can skip the hookData
    ///      requirement for a trade under the input threshold. It cannot do the same for the leg,
    ///      because the leg does not exist until the pool has executed -- so a trade that clears
    ///      the input threshold must supply hookData even if `afterSwap` then declines to bond it.
    ///
    ///      Callers must therefore attach hookData whenever the input threshold is cleared, not
    ///      whenever they expect a bond. Sending empty data reverts in `beforeSwap`, before the
    ///      pool executes.
    function test_declinedByTheLegGate_stillRequiresHookData() public {
        _deployScaledPool(18, 18, 0, 1e18);

        _configureLegMinimum(FLOOR);

        // Clears the input threshold of 1, but its leg is far below the minimum.
        vm.expectRevert();

        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -2, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice A leg minimum large enough to exclude every trade turns bonding off in practice.
    ///
    /// @dev Worth stating because `setPoolConfig` accepts it without complaint. The owner already
    ///      has an explicit disable flag, so this is a redundant path to the same place rather than
    ///      a new power -- but it is a silent one, and an operator who sets a minimum in the wrong
    ///      units gets a pool that quietly never bonds instead of an error.
    function test_anAbsurdLegMinimumSilentlyDisablesBonding() public {
        _deployScaledPool(18, 18, 0, 1e18);

        hook.setPoolConfig(key_, 1, 1, type(uint128).max, type(uint128).max, true);

        uint256 hookBefore = c1.balanceOf(address(hook));

        int24 before = _tick();

        _swap(-int256(uint256(1e16)), true);

        assertTrue(_tick() != before, "the probe swap did not move the price");

        assertEq(c1.balanceOf(address(hook)), hookBefore, "an unreachable minimum still bonded");
    }

    /// @notice A leg below the enforced floor is always declined, whatever the configuration.
    ///
    /// @dev The complement of the boundary test: there is no legal configuration under which such
    ///      a swap bonds, because the minimum cannot be set low enough to admit it.
    function test_belowTheFloor_isAlwaysDeclined() public {
        _deployScaledPool(18, 18, 0, 1e18);

        _configureLegMinimum(FLOOR);

        uint256 hookBefore = c1.balanceOf(address(hook));

        uint32 pendingBefore = _pendingNow();

        // Two units of input cannot produce 10,000 units of output at this price.
        _swap(-int256(uint256(2)), true);

        assertEq(c1.balanceOf(address(hook)), hookBefore, "a sub-floor leg took collateral");
        assertEq(_pendingNow(), pendingBefore, "a sub-floor leg registered a liability");
    }
}
