// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {AdversarialBase} from "./AdversarialBase.sol";
import {ModelL2SettlementLib} from "../../src/libraries/ModelL2SettlementLib.sol";
import {ModelL2Reference} from "../utils/ModelL2Reference.sol";
import {ModelLReference} from "../utils/ModelLReference.sol";
import {BondMeBro} from "../../src/BondMeBro.sol";

/// @title AdvEconomicTest
///
/// @notice P-L2-8 economic attacks: overshoot, dead-zone boundaries, the two-block straddle, the
///         single-block late push, temporal grinding, split trades, threshold grinding, the
///         collateral cap, and raw-token rounding.
///
/// @dev WHAT SEPARATES THIS FROM THE EARLIER SUITES. `ModelL2Settlement.t.sol` proves the
///      arithmetic; this tries to BREAK it, and where it cannot, it measures what an attacker
///      actually gets. Several tests below are expected to demonstrate a limitation rather than a
///      defence — those are labelled, and they are labelled because hiding them would be the more
///      serious failure.
///
///      THE DISTINCTION THAT MATTERS THROUGHOUT: a STRUCTURAL SECURITY INVARIANT is a property the
///      mechanism guarantees for any population (INV-L2-4's monotonicity, conservation, the cap).
///      A KNOWN ECONOMIC LIMITATION is a cost an attacker can pay to reduce their charge (the
///      straddle, the noise floor, splitting). The first kind failing is a defect; the second kind
///      existing is a documented trade-off.
contract AdvEconomicTest is AdversarialBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployAndOpenPool();
    }

    /*//////////////////////////////////////////////////////////////
                    4  THE OVERSHOOT ATTACK, WIDENED
    //////////////////////////////////////////////////////////////*/

    /// @notice Model B's killer, across ten multipliers, both directions, four leg sizes.
    ///
    /// @dev THE ATTACK: hold the residual path fixed and push the opening price much further than
    ///      needed, betting that the bigger denominator refunds more. Under Model B, 1.54x reached
    ///      the refund boundary and 2x manufactured a full refund; across 525 measured rows, 490
    ///      lowered the absolute slash.
    ///
    ///      Model L2's answer is arithmetic rather than empirical: `slash = min(f(impact),
    ///      g(residual))` with `f` non-decreasing and `g` free of impact. The minimum of a
    ///      non-decreasing function and a constant is non-decreasing.
    ///
    ///      ONLY ABSOLUTE SLASH IS INVARIANT. The slash-to-collateral RATIO is deliberately not
    ///      asserted: it genuinely falls at some impacts (the 8/9 wrinkle below), and asserting it
    ///      would be asserting something false.
    function test_adv4_overshootNeverReducesAbsoluteSlash() public pure {
        uint256[10] memory multiplierX100 = [uint256(100), 125, 150, 200, 300, 500, 1_000, 2_500, 5_000, 10_000];

        uint128[4] memory legs = [uint128(1e18), 1e12, 10_001, 103];

        uint256[5] memory residuals = [uint256(6), 12, 40, 200, 900];

        for (uint256 l = 0; l < legs.length; l++) {
            for (uint256 r = 0; r < residuals.length; r++) {
                _assertOvershootMonotone(legs[l], residuals[r], multiplierX100);
            }
        }
    }

    /// @dev One (leg, residual) row of the overshoot grid. Split out for the stack.
    function _assertOvershootMonotone(uint128 leg, uint256 residual, uint256[10] memory multiplierX100) internal pure {
        uint128 previous = 0;

        for (uint256 i = 0; i < multiplierX100.length; i++) {
            // Base impact 40 ticks, scaled. Both signs give the same rate: it depends on |impact|.
            uint256 impact = (40 * multiplierX100[i]) / 100;

            uint256 up = ModelLReference.collateralBps(0, int24(int256(impact)));
            uint256 down = ModelLReference.collateralBps(0, -int24(int256(impact)));

            assertEq(up, down, "the collateral rate is direction-dependent");

            uint256 bps = ModelL2SettlementLib.slashBpsFor(up, residual);

            (uint128 collateral, uint128 slash, uint128 refund) = ModelL2SettlementLib.split(leg, up, bps);

            if (slash < previous) {
                revert(
                    string.concat(
                        "OVERSHOOT PAID: leg=",
                        vm.toString(leg),
                        " R=",
                        vm.toString(residual),
                        " multiplier=",
                        vm.toString(multiplierX100[i]),
                        " slash fell from ",
                        vm.toString(previous),
                        " to ",
                        vm.toString(slash)
                    )
                );
            }

            assertLe(slash, collateral, "slash exceeded collateral");
            assertEq(uint256(refund) + uint256(slash), uint256(collateral), "conservation broke under overshoot");

            previous = slash;
        }
    }

    /// @notice The overshoot attack driven through a REAL pool, both directions.
    ///
    /// @dev The pure grid proves the arithmetic; this proves the wiring. The attacker opens the
    ///      same nominal position at increasing sizes and lets the price persist, and the realized
    ///      token slash must never fall.
    function test_adv4_overshootThroughARealPool() public {
        int256[5] memory sizes = [int256(-2e15), -5e15, -1e16, -3e16, -8e16];

        for (uint256 d = 0; d < 2; d++) {
            bool zeroForOne = d == 0;

            uint256 previousSlash = 0;

            for (uint256 i = 0; i < sizes.length; i++) {
                uint256 snap = vm.snapshotState();

                (bytes32 bondId,, uint32 m) = _open(sizes[i], zeroForOne);

                _nudgeAt(m + 1);

                Settled memory got = _settle(bondId);

                assertEq(got.refund + got.slash, uint256(got.collateral), "conservation broke in the pool");

                assertGe(
                    got.slash,
                    previousSlash,
                    string.concat("overshoot lowered the realized slash at size index ", vm.toString(i))
                );

                previousSlash = got.slash;

                vm.revertToState(snap);
            }

            assertGt(previousSlash, 0, "the direction never produced a slash; the sweep proves nothing");
        }
    }

    /*//////////////////////////////////////////////////////////////
                   5  DEAD-ZONE BOUNDARIES, PINNED
    //////////////////////////////////////////////////////////////*/

    /// @notice Every residual around `D`, and the full-persistence pattern including the 8/9 step.
    ///
    /// @dev The 8/9 discontinuity is DELIBERATELY NOT "FIXED". At 9 ticks the collateral rate steps
    ///      to 3 bps while the residual is still in the catch-up segment (Q = 8, target 2 bps), so
    ///      the trade posts 3 and forfeits 2. INV-L2-4 constrains the ABSOLUTE slash, which is
    ///      identical at 8 and 9; the ratio is not an invariant and never was.
    function test_adv5_deadZoneBoundariesAndFullPersistence() public pure {
        uint256[10] memory rs = [uint256(0), 1, 4, 5, 6, 7, 8, 9, 10, 11];
        uint256[10] memory qs = [uint256(0), 0, 0, 0, 2, 4, 6, 8, 10, 11];

        for (uint256 i = 0; i < rs.length; i++) {
            assertEq(ModelL2SettlementLib.chargeableResidual(rs[i]), qs[i], "dead-zone mapping moved");
        }

        uint128 leg = 1e18;

        // Fully persistent: residual == initial impact.
        for (uint256 impact = 1; impact <= 5; impact++) {
            (uint128 c, uint128 s) = _persistent(leg, impact);

            assertGt(c, 0, "no collateral posted");
            assertEq(s, 0, "a fully persistent dead-zone impact was charged");
        }

        for (uint256 impact = 6; impact <= 7; impact++) {
            (uint128 c, uint128 s) = _persistent(leg, impact);

            assertGt(s, 0, "the catch-up segment charged nothing");
            assertLt(s, c, "the catch-up segment forfeited everything too early");
        }

        (uint128 c8, uint128 s8) = _persistent(leg, 8);
        assertEq(s8, c8, "8 ticks of full persistence must forfeit everything");

        (uint128 c9, uint128 s9) = _persistent(leg, 9);
        assertLt(s9, c9, "the documented 9-tick step has moved");
        assertGe(s9, s8, "INV-L2-4 broke across the 8/9 step");

        for (uint256 impact = 10; impact <= 60; impact++) {
            (uint128 c, uint128 s) = _persistent(leg, impact);

            assertEq(s, c, "full persistence at or above 2D must forfeit everything");
        }
    }

    function _persistent(uint128 leg, uint256 impact) internal pure returns (uint128, uint128) {
        uint256 cBps = ModelLReference.collateralBps(0, int24(int256(impact)));

        uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, impact);

        (uint128 collateral, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

        return (collateral, slash);
    }

    /*//////////////////////////////////////////////////////////////
        6-7  THE STRADDLE AND THE SINGLE-BLOCK PUSH, MEASURED
    //////////////////////////////////////////////////////////////*/

    /// @notice KNOWN LIMITATION, REPRODUCED. Two adjacent blocks straddling the window boundary
    ///         can erase the whole charge; one block anywhere cannot.
    ///
    /// @dev The windows are disjoint but ADJACENT — blocks 6-7 and 8-9 — so the pair at 7 and 8
    ///      takes one block from each. This measures both halves of the claim and reports the
    ///      attacker's effort in TICK-BLOCKS, which is the quantity that costs money: the price
    ///      must actually be moved and held, exposed to arbitrage, for two consecutive blocks.
    ///
    ///      This is the intended security boundary, not the absence of one. It is emphatically not
    ///      a claim that manipulation is impossible.
    function test_adv6_twoBlockStraddleErasesTheChargeAndOneBlockCannot() public pure {
        int24 tickBefore = 0;
        int24 tickAfter = 100;

        int24[10] memory clean = ModelL2Reference.flatPath(100);

        uint256 baseline = ModelL2Reference.residual(clean, tickBefore, tickAfter);

        assertEq(baseline, 100, "fixture: a flat persistent path should give R = 100");

        // THE STRADDLE: blocks 7 and 8, one from each window.
        int24[10] memory straddled = ModelL2Reference.flatPath(100);
        straddled[7] = -100;
        straddled[8] = -100;

        uint256 afterStraddle = ModelL2Reference.residual(straddled, tickBefore, tickAfter);

        assertEq(afterStraddle, 0, "the documented two-block straddle no longer erases the charge");

        // Effort, in tick-blocks: each pushed block moves 200 ticks from +100 to -100.
        uint256 effortTickBlocks = 2 * 200;

        console2.log("STRADDLE  residual before      ", baseline);
        console2.log("STRADDLE  residual after       ", afterStraddle);
        console2.log("STRADDLE  attacker tick-blocks ", effortTickBlocks);
        console2.log("STRADDLE  blocks required      ", uint256(2));

        // AND THE CONTRAST: no single block, at any position or magnitude, does the same.
        for (uint256 b = 6; b < 10; b++) {
            int24[10] memory one = ModelL2Reference.flatPath(100);
            one[b] = -100_000;

            assertEq(
                ModelL2Reference.residual(one, tickBefore, tickAfter),
                100,
                "a SINGLE opposing block reduced the charge; the two-window max is broken"
            );
        }
    }

    /// @notice Single-block late pushes: every late block, six magnitudes, both signs.
    ///
    /// @dev STRUCTURAL PROPERTY, not a percentage. One block lies in exactly one window, so the
    ///      other window still reads the full displacement and `max` takes it. The charge is
    ///      therefore unchanged no matter how hard the single block is pushed.
    function test_adv7_singleBlockLatePushNeverReducesTheCharge() public pure {
        uint256[6] memory magnitudeX4 = [uint256(1), 2, 4, 8, 16, 32]; // 0.25x .. 8x of a 100-tick move

        for (uint256 d = 0; d < 2; d++) {
            bool up = d == 0;

            int24 tickBefore = 0;
            int24 tickAfter = up ? int24(100) : int24(-100);
            int24 held = tickAfter;

            int24[10] memory clean = ModelL2Reference.flatPath(held);

            uint256 baseline = ModelL2Reference.residual(clean, tickBefore, tickAfter);

            assertEq(baseline, 100, "fixture baseline wrong for this direction");

            for (uint256 b = 6; b < 10; b++) {
                for (uint256 mi = 0; mi < magnitudeX4.length; mi++) {
                    int24[10] memory pushed = ModelL2Reference.flatPath(held);

                    int256 push = (int256(100) * int256(magnitudeX4[mi])) / 4;

                    // Opposing: against the trade's direction.
                    pushed[b] = int24(up ? -push : push);

                    assertEq(
                        ModelL2Reference.residual(pushed, tickBefore, tickAfter),
                        baseline,
                        "a single-block late push reduced the charge"
                    );
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
             8  TEMPORAL GRINDING — KNOWN LIMITATION
    //////////////////////////////////////////////////////////////*/

    /// @notice KNOWN ECONOMIC LIMITATION, REPRODUCED THROUGH A REAL POOL.
    ///
    /// @dev Displacement built at `D` ticks or fewer per observation window costs zero BondMeBro
    ///      collateral, without bound. This is inherent to ANY noise floor: at `D = 0` grinding is
    ///      never cheaper than the single move, and the price of removing it is charging benign
    ///      noise instead.
    ///
    ///      Driven with real swaps rather than synthetic paths, so the accumulated displacement is
    ///      whatever the AMM actually produced. Profitability is explicitly OUT OF SCOPE: each step
    ///      pays LP fees and gas and leaves the price exposed for a full window, and pricing that
    ///      needs pool depth and a fee tier this repository does not have.
    function test_adv8_temporalGrindingUnderTheNoiseFloorIsFree() public {
        uint32 obs = hook.OBSERVATION_BLOCKS();

        int24 startTick = _tick();

        uint256 totalSlashed;
        uint256 windows;
        uint256 swaps;
        uint256 bondsCreated;

        // Each step: one small swap, then a full observation window of silence.
        for (uint256 step = 0; step < 12; step++) {
            uint32 m = _maturityOfNow();
            bytes32 bondId = _bondIdAt(m, 0);

            // Sized to move only a few ticks against this depth.
            _swapT(-int256(uint256(MIN_BONDED) * 2), true, _hookData());

            swaps++;

            if (hook.bondExists(bondId)) {
                bondsCreated++;

                vm.roll(uint256(m) + 1);

                _swapT(NUDGE, true, "");

                Settled memory got = _settle(bondId);

                totalSlashed += got.slash;
            } else {
                vm.roll(block.number + obs + 1);
            }

            windows++;
        }

        int24 endTick = _tick();

        uint256 accumulated = uint256(int256(startTick) - int256(endTick));

        console2.log("GRIND  swaps                ", swaps);
        console2.log("GRIND  observation windows  ", windows);
        console2.log("GRIND  bonds created        ", bondsCreated);
        console2.log("GRIND  ticks accumulated    ", accumulated);
        console2.log("GRIND  total BondMeBro slash", totalSlashed);

        assertGt(accumulated, 5, "the grind did not accumulate displacement beyond one window's floor");

        assertGt(bondsCreated, 0, "no bond was ever created; the zero slash below would be vacuous");

        assertEq(totalSlashed, 0, "the documented sub-D grinding limitation no longer holds");

        // AND THE CONTRAST: the same total displacement in ONE trade IS charged.
        uint256 snap = vm.snapshotState();

        (bytes32 oneShot,, uint32 m2) = _open(-int256(uint256(MIN_BONDED) * 24), true);

        _nudgeAt(m2 + 1);

        Settled memory big = _settle(oneShot);

        console2.log("GRIND  same move in one trade, slash", big.slash);

        assertGt(big.slash, 0, "the single-move equivalent was not charged; the contrast is lost");

        vm.revertToState(snap);
    }

    /// @notice Where the charge begins: residual 5 is free, 6 is not.
    function test_adv8_chargeBeginsExactlyAboveD() public pure {
        uint128 leg = 1e18;

        for (uint256 r = 1; r <= 5; r++) {
            (, uint128 s) = _atResidual(leg, 100, r);

            assertEq(s, 0, "a residual at or below D was charged");
        }

        for (uint256 r = 6; r <= 10; r++) {
            (, uint128 s) = _atResidual(leg, 100, r);

            assertGt(s, 0, "a residual above D was not charged");
        }
    }

    function _atResidual(uint128 leg, uint256 cBps, uint256 residual) internal pure returns (uint128, uint128) {
        uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, residual);

        (uint128 collateral, uint128 slash,) = ModelL2SettlementLib.split(leg, cBps, bps);

        return (collateral, slash);
    }

    /*//////////////////////////////////////////////////////////////
                     9  THE SPLIT-TRADE ATTACK
    //////////////////////////////////////////////////////////////*/

    /// @notice MEASURED: splitting one trade into N pieces IN THE SAME BLOCK reduces the collateral
    ///         posted roughly as 1/N, while moving the price by the same amount.
    ///
    /// @dev MITIGATED BY ADR-0008, NOT ELIMINATED. This test was P-L2-8's original finding and it
    ///      now pins the mitigation instead: same numbers, same displacement, opposite assertion.
    ///
    ///      WHAT IT USED TO SHOW. Collateral was sized from each trade's OWN realized impact
    ///      (pre-ADR-0008), so splitting into N same-block pieces gave each roughly `impact/N` and
    ///      `leg/N`; each posted about `leg*impact/N^2` and the sum fell as about `1/N` — measured
    ///      at 15x for 32 pieces, and UNBOUNDED beyond that as sub-tick pieces stopped bonding
    ///      entirely (132x at 512 pieces; ADR-0008 § 2 corrects P-L2-8's claimed 100x ceiling).
    ///
    ///      WHAT IT SHOWS NOW. ADR-0008 sizes collateral from
    ///      `max(ownImpact, |tickAfter - blockStartTick|)`, so each later piece is charged for
    ///      where it left the pool relative to the block's start. The dilution collapses from ~15x
    ///      to ~1.9x and stops growing with N.
    ///
    ///      THE RESIDUAL IS REAL AND IS ASSERTED AS SUCH. A monotone ramp still pays the AREA under
    ///      a linear rate curve while the one-shot pays its ENDPOINT, so about half — ADR-0008 § 7
    ///      and INV-L2-4c. This test asserts the charge lands in that band and does NOT assert
    ///      split invariance, which the design explicitly does not provide.
    ///
    ///      The price displacement is measured on BOTH arms precisely so this is not an unfair
    ///      comparison: if the split moved the price materially less, the lower charge would simply
    ///      be correct pricing rather than a gap.
    ///
    ///      WHAT IS NOT CLAIMED: that this is profitable. Each piece pays LP fees and gas, and N
    ///      swaps pay N times the fee. Whether the saved collateral exceeds that needs pool depth
    ///      and a fee tier this repository does not have, so it is deliberately left unclassified
    ///      rather than waved through.
    ///
    ///      RELATED TO BUT DISTINCT FROM ADR-0005 § 6.2. That records grinding under the dead zone,
    ///      which needs one observation window per step — 400 blocks for the measured 200 ticks.
    ///      This needs a single block. The shared root is per-trade impact sizing; the cost to the
    ///      attacker is very different.
    function test_adv9_sameBlockSplitReducesPostedCollateral() public {
        uint256[4] memory pieces = [uint256(1), 2, 8, 32];

        uint256 total = 32e15;

        uint256[4] memory collateralAt;
        uint256[4] memory slashAt;
        uint256[4] memory displacementAt;

        for (uint256 p = 0; p < pieces.length; p++) {
            uint256 snap = vm.snapshotState();

            uint32 m = _maturityOfNow();
            uint256 n = pieces[p];

            int24 tickStart = _tick();

            for (uint256 i = 0; i < n; i++) {
                _swapT(-int256(total / n), true, _hookData());
            }

            // Displacement the block actually produced, which is the LP-visible harm.
            displacementAt[p] = uint256(int256(tickStart) - int256(_tick()));

            _nudgeAt(m + 1);

            uint256 bonded;

            for (uint256 i = 0; i < n; i++) {
                bytes32 bondId = _bondIdAt(m, uint32(i));

                if (!hook.bondExists(bondId)) continue;

                bonded++;

                Settled memory got = _settle(bondId);

                collateralAt[p] += got.collateral;
                slashAt[p] += got.slash;
            }

            assertGt(bonded, 0, "no piece bonded; this row proves nothing");

            console2.log("SPLIT-A pieces              ", n);
            console2.log("SPLIT-A ticks displaced     ", displacementAt[p]);
            console2.log("SPLIT-A aggregate collateral", collateralAt[p]);
            console2.log("SPLIT-A aggregate slash     ", slashAt[p]);

            vm.revertToState(snap);
        }

        // THE COMPARISON IS FAIR: every arm moved the price by a comparable amount.
        for (uint256 p = 1; p < pieces.length; p++) {
            assertGt(displacementAt[p], (displacementAt[0] * 8) / 10, "the split moved the price materially less");
        }

        // THE MITIGATION, asserted so it cannot silently regress.
        //
        // Bounds rather than an exact ratio, per ADR-0008 § 7: the limit is ~2x dilution from
        // above and the measured 32-piece figure is ~1.9x, so the aggregate must sit comfortably
        // inside a third-to-full band. A brittle equality here would fail on any liquidity or
        // fixture change without indicating anything about the mechanism.
        assertGt(
            collateralAt[3] * 3,
            collateralAt[0],
            "the same-block split is diluting MORE than ADR-0008 permits; the mitigation regressed"
        );

        // ...AND IS NOT CLAIMED TO BE ELIMINATED. If this ever fails, the split stopped being
        // cheaper at all and ADR-0008 § 7's "mitigated, not eliminated" wording is now wrong.
        assertLt(
            collateralAt[3],
            collateralAt[0],
            "the split is no longer cheaper at all; ADR-0008 s 7 overstates the residual limitation"
        );

        console2.log("SPLIT-A collateral ratio 32-piece/1-piece x1000", (collateralAt[3] * 1000) / collateralAt[0]);
        console2.log("SPLIT-A slash ratio      32-piece/1-piece x1000", (slashAt[3] * 1000) / slashAt[0]);

        // AND WHAT DOES NOT BREAK. Every accounting property survives the attack: each piece
        // conserves, and the mechanism is under-charging rather than mis-accounting.
        assertGt(slashAt[3], 0, "the split escaped the charge entirely");

        // THE REDUCTION IS BOUNDED, and under ADR-0008 the bound is structural rather than a
        // by-product of `ceil`.
        //
        // P-L2-8 argued the ceiling was `collateralBps(fullImpact)` because `ceil` floors every
        // piece at 1 bps. THAT ARGUMENT WAS WRONG -- it omitted the zero case, where a sub-tick
        // piece produces a zero rate and is not bonded at all, so the old model's dilution grew
        // without bound as Theta(N). ADR-0008 § 2 records the correction.
        //
        // The block model's bound comes from geometry instead: a monotone ramp pays the area under
        // a linear rate curve and the one-shot pays its endpoint, so the ratio tends to one half
        // and does not depend on the partition (INV-L2-4c).
        uint256 singleRateBps = ModelLReference.collateralBps(0, int24(int256(displacementAt[0])));

        assertLe(
            collateralAt[3] * 1_000,
            collateralAt[0] * 1_000,
            "the split paid MORE than the one-shot; that is not the expected geometry"
        );

        console2.log("SPLIT-A single-trade rate (bps)   ", singleRateBps);
        console2.log("SPLIT-A max reduction this bound  ", singleRateBps);
    }

    /// @notice KNOWN LIMITATION. Splitting ACROSS observation windows does reduce the charge,
    ///         because each piece is measured against its own dead zone.
    ///
    /// @dev CASE C of the split attack, and it is the same limitation as § 8 wearing a different
    ///      hat: a piece small enough to land inside `D` is free, and separating pieces by a full
    ///      window makes each one independent. Reported, not patched — the dead zone is frozen.
    function test_adv9_temporalSplitReducesTheChargeAsDocumented() public {
        uint32 obs = hook.OBSERVATION_BLOCKS();

        // ONE TRADE.
        uint256 snap = vm.snapshotState();

        (bytes32 single,, uint32 m1) = _open(-24e15, true);

        _nudgeAt(m1 + 1);

        uint256 singleSlash = _settle(single).slash;

        vm.revertToState(snap);

        // THE SAME NOTIONAL, one window apart.
        uint256 splitSlash;
        uint256 splitBonds;

        for (uint256 i = 0; i < 12; i++) {
            uint32 m = _maturityOfNow();
            bytes32 bondId = _bondIdAt(m, 0);

            _swapT(-2e15, true, _hookData());

            if (hook.bondExists(bondId)) {
                splitBonds++;

                vm.roll(uint256(m) + 1);
                _swapT(NUDGE, true, "");

                splitSlash += _settle(bondId).slash;
            } else {
                vm.roll(block.number + obs + 1);
            }
        }

        console2.log("SPLIT-C single-trade slash  ", singleSlash);
        console2.log("SPLIT-C temporal-split slash", splitSlash);
        console2.log("SPLIT-C pieces bonded       ", splitBonds);

        assertGt(singleSlash, 0, "the single trade was not charged; the comparison is vacuous");

        // The limitation, asserted as a limitation.
        assertLt(splitSlash, singleSlash, "the documented temporal-split limitation no longer holds");
    }

    /*//////////////////////////////////////////////////////////////
                     10  THRESHOLD GRINDING
    //////////////////////////////////////////////////////////////*/

    /// @notice The eligibility boundary is exact, and splitting below it bypasses participation.
    ///
    /// @dev `minBondedAmount` IS A RATION, NOT AN ANTI-SYBIL MECHANISM, and was never designed as
    ///      one. It decides which trades are large enough to participate; it cannot decide who is
    ///      asking. Splitting a large notional into sub-threshold pieces therefore avoids bonding
    ///      entirely, and that is declared policy rather than a defect.
    ///
    ///      What IS asserted is that no accounting invariant breaks while it happens: no record is
    ///      created, no liability is registered, nothing is taken.
    function test_adv10_thresholdBoundaryAndSubThresholdSplitting() public {
        // The boundary, to the wei, on CONSUMED input.
        uint256 snap = vm.snapshotState();

        uint32 mA = _maturityOfNow();
        _swapT(-int256(uint256(MIN_BONDED) - 1), true, "");
        assertFalse(hook.bondExists(_bondIdAt(mA, 0)), "threshold - 1 was bonded");

        vm.revertToState(snap);

        uint32 mB = _maturityOfNow();
        _swapT(-int256(uint256(MIN_BONDED)), true, _hookData());
        assertTrue(hook.bondExists(_bondIdAt(mB, 0)), "exactly at the threshold was not bonded");

        vm.revertToState(snap);

        uint32 mC = _maturityOfNow();
        _swapT(-int256(uint256(MIN_BONDED) + 1), true, _hookData());
        assertTrue(hook.bondExists(_bondIdAt(mC, 0)), "threshold + 1 was not bonded");

        vm.revertToState(snap);

        // THE GRIND: 40 pieces, each one wei below the threshold.
        uint32 m = _maturityOfNow();

        uint256 hookBefore0 = currency0.balanceOf(address(hook));
        uint256 hookBefore1 = currency1.balanceOf(address(hook));

        for (uint256 i = 0; i < 40; i++) {
            _swapT(-int256(uint256(MIN_BONDED) - 1), true, "");
        }

        (,,, uint32 pending,) = hook.maturity(id_, m);

        console2.log("THRESHOLD-GRIND pieces        ", uint256(40));
        console2.log("THRESHOLD-GRIND notional      ", 40 * (uint256(MIN_BONDED) - 1));
        console2.log("THRESHOLD-GRIND bonds created ", pending);

        // The declared policy: sub-threshold trades do not participate.
        assertEq(pending, 0, "a sub-threshold swap registered a liability");

        // And no accounting invariant broke while it happened.
        assertEq(currency0.balanceOf(address(hook)), hookBefore0, "the hook took currency0 from unbonded swaps");
        assertEq(currency1.balanceOf(address(hook)), hookBefore1, "the hook took currency1 from unbonded swaps");

        for (uint32 i = 0; i < 8; i++) {
            assertFalse(hook.bondExists(_bondIdAt(m, i)), "a sub-threshold swap left a record");
        }
    }

    /*//////////////////////////////////////////////////////////////
                   11  THE COLLATERAL CAP
    //////////////////////////////////////////////////////////////*/

    /// @notice The cap binds at exactly 397 ticks, holds above it, and monotonicity survives.
    ///
    /// @dev KNOWN LIMITATION above the cap: the chargeable residual keeps growing while the
    ///      collateral saturates, so the largest persistent moves are systematically
    ///      under-collateralized. At 1,000 ticks the uncapped target would be 250 bps against 100
    ///      posted. Monotonicity still holds — that is asserted — but LP protection does not scale,
    ///      and raising the cap is out of scope.
    function test_adv11_capBoundaryAndUnderCollateralizationAboveIt() public pure {
        uint32[7] memory impacts = [uint32(395), 396, 397, 398, 500, 1_000, 500_000];

        uint128 leg = 1e18;

        uint128 previous = 0;

        for (uint256 i = 0; i < impacts.length; i++) {
            uint256 cBps = ModelLReference.collateralBps(0, int24(int32(impacts[i])));

            assertLe(cBps, 100, "the collateral rate exceeded the cap");

            // Fully persistent at that impact.
            uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, impacts[i]);

            (uint128 collateral, uint128 slash, uint128 refund) = ModelL2SettlementLib.split(leg, cBps, bps);

            assertLe(slash, collateral, "slash exceeded collateral above the cap");
            assertEq(uint256(refund) + uint256(slash), uint256(collateral), "conservation broke above the cap");
            assertGe(slash, previous, "INV-L2-4 broke across the cap boundary");

            previous = slash;
        }

        assertEq(ModelLReference.collateralBps(0, 396), 99, "396 should sit just below the cap");
        assertEq(ModelLReference.collateralBps(0, 397), 100, "397 should be the first capped impact");
        assertEq(ModelLReference.collateralBps(0, 398), 100, "398 should remain capped");

        // The under-collateralization, quantified rather than asserted away.
        uint256 uncappedTargetAt1000 = ModelL2SettlementLib.targetSlashBps(1_000);

        assertEq(uncappedTargetAt1000, 250, "the uncapped target at 1,000 ticks should be 250 bps");

        console2.log("CAP  uncapped target at 1000 ticks (bps)", uncappedTargetAt1000);
        console2.log("CAP  collateral actually posted    (bps)", uint256(100));
        console2.log("CAP  shortfall                     (bps)", uncappedTargetAt1000 - 100);
    }

    /*//////////////////////////////////////////////////////////////
                   12  ROUNDING AND DUST
    //////////////////////////////////////////////////////////////*/

    /// @notice The full dust matrix: eleven legs against every rate from 1 to 100 bps.
    ///
    /// @dev The class that broke ADR-0005's rejected token form. Four properties per cell:
    ///      conservation is exact, the slash never exceeds the collateral, raising the impact never
    ///      lowers the absolute slash, and the two independent implementations agree.
    function test_adv12_dustMatrixHoldsEveryProperty() public pure {
        uint128[11] memory legs = [uint128(1), 2, 3, 99, 100, 101, 102, 103, 9_999, 10_000, 10_001];

        uint256[6] memory residuals = [uint256(0), 5, 6, 9, 10, 400];

        for (uint256 l = 0; l < legs.length; l++) {
            for (uint256 r = 0; r < residuals.length; r++) {
                uint128 previous = 0;

                for (uint256 cBps = 1; cBps <= 100; cBps++) {
                    uint256 bps = ModelL2SettlementLib.slashBpsFor(cBps, residuals[r]);

                    (uint128 collateral, uint128 slash, uint128 refund) = ModelL2SettlementLib.split(legs[l], cBps, bps);

                    if (uint256(refund) + uint256(slash) != uint256(collateral)) {
                        revert(string.concat("CONSERVATION BROKE at leg=", vm.toString(legs[l])));
                    }

                    if (slash > collateral) revert("SLASH EXCEEDED COLLATERAL");

                    if (slash < previous) {
                        revert(
                            string.concat(
                                "MONOTONICITY BROKE: leg=",
                                vm.toString(legs[l]),
                                " R=",
                                vm.toString(residuals[r]),
                                " cBps=",
                                vm.toString(cBps)
                            )
                        );
                    }

                    // The independent reference must agree on every cell.
                    (uint128 rc, uint128 rs, uint128 rr) = ModelL2Reference.split(legs[l], cBps, bps);

                    if (rc != collateral || rs != slash || rr != refund) revert("REFERENCE DISAGREED");

                    previous = slash;
                }
            }
        }
    }

    /// @notice NEGATIVE CONTROL: the rejected token form still exhibits its defect.
    ///
    /// @dev Without this, the passing monotonicity assertions above could be passing for the wrong
    ///      reason — a fixture too coarse to expose the bug at all. ADR-0005 § 3.1's minimal
    ///      counterexample must still fail under Form A, and must not fail under ours.
    function test_adv12_rejectedFormIsStillBrokenAndOursIsNot() public pure {
        uint128 leg = 102;
        uint256 target = 99;

        uint256 formAAt99 = ((uint256(leg) * 99) / 10_000) * target / 99;
        uint256 formAAt100 = ((uint256(leg) * 100) / 10_000) * target / 100;

        assertEq(formAAt99, 1, "Form A should slash 1 wei at 99 bps");
        assertEq(formAAt100, 0, "Form A should slash 0 wei at 100 bps");
        assertLt(formAAt100, formAAt99, "the rejected form no longer exhibits its defect");

        (, uint128 ourAt99,) = ModelL2SettlementLib.split(leg, 99, 99);
        (, uint128 ourAt100,) = ModelL2SettlementLib.split(leg, 100, 99);

        assertGe(ourAt100, ourAt99, "the adopted form lost a wei as the impact rose");
    }

    /// @notice A bond whose collateral would round to zero is DECLINED, never finalized at zero.
    ///
    /// @dev The lower half of INV-NOOP-VL, driven through a real pool. The invariant is unchanged:
    ///      a zero-collateral finalized record would be a maturity obligation with nothing behind
    ///      it — refundable to nobody and counted in `pendingBonds` forever, so it must never be
    ///      written.
    ///
    ///      WHAT CHANGED IS THE DISPOSAL, NOT THE INVARIANT. Such a swap used to revert; it is now
    ///      turned away from bonding and executes unbonded. Rejecting the whole trade also rejected
    ///      ordinary small trades on pools whose two tokens differ in decimals, where the variable
    ///      leg is measured in a currency the input threshold does not bound. The assertion that
    ///      matters here — nothing finalized, nothing pending — is asserted exactly as before.
    function test_adv12_zeroCollateralBondIsDeclinedNotFinalized() public {
        (PoolKey memory thinKey, PoolId thinId) =
            initPool(currency0, currency1, IHooks(address(hook)), 500, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            thinKey,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 4e6, salt: bytes32(0)}),
            ""
        );

        uint256 baseline = vm.snapshotState();

        // Search with bonding OFF so probe swaps cannot revert with the error under test.
        uint256 chosen;
        uint256 observedLeg;

        for (uint256 amount = 100; amount <= 9_000; amount += 100) {
            uint256 snap = vm.snapshotState();

            // slither-disable-next-line unused-return
            (, int24 before_,,) = manager.getSlot0(thinId);

            uint256 traderBefore = currency1.balanceOf(address(this));

            _swapOn(thinKey, -int256(amount), true, "");

            // slither-disable-next-line unused-return
            (, int24 after_,,) = manager.getSlot0(thinId);

            uint256 leg = currency1.balanceOf(address(this)) - traderBefore;

            bool moved = ModelLReference.collateralBps(before_, after_) > 0;
            bool truncates = leg > 0 && ModelLReference.collateralFor(leg, before_, after_) == 0;

            vm.revertToState(snap);

            if (moved && truncates) {
                chosen = amount;
                observedLeg = leg;
                break;
            }
        }

        assertGt(chosen, 0, "could not construct a moved-a-tick-but-truncates-to-zero swap");

        vm.revertToState(baseline);

        hook.setPoolConfig(thinKey, 1, 1, 10_000, 10_000, true);

        assertLt(observedLeg, 10_000, "the leg was not actually below the minimum: the test proves nothing");

        uint256 hookBefore = currency1.balanceOf(address(hook));

        // Executes rather than reverting — and pays nothing.
        _swapOn(thinKey, -int256(chosen), true, _hookData());

        assertEq(currency1.balanceOf(address(hook)), hookBefore, "a declined swap still took collateral");

        // Nothing was created by the declined attempt.
        uint32 m = _maturityOfNow();

        (,,, uint32 pending,) = hook.maturity(thinId, m);

        assertEq(pending, 0, "a declined zero-collateral swap registered a liability");
    }
}
