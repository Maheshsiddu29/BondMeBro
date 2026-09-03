// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";
import {ModelL2SettlementLib} from "../src/libraries/ModelL2SettlementLib.sol";

import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title BlockCumulativeImpactTest
///
/// @notice ADR-0008. The block-cumulative collateral rate, end to end on a live pool: first-swap
///         equivalence with the pre-migration model, the same-block split mitigation, and the three
///         invariants that replaced INV-L2-4.
///
/// @dev PROMOTED FROM P-L2-8.1 / P-L2-8.1B RESEARCH. Those stages measured the candidate against a
///      prototype; this file measures the SHIPPED mechanism and is the permanent regression corpus
///      for it. Every rate assertion is made against `ModelLReference`, which restates ADR-0008 § 3
///      from its prose rather than importing the hook's arithmetic — so a bug that changed both
///      would still be caught.
///
///      DEPTH IS LOAD-BEARING. `POOL_LIQUIDITY = 1e19` puts a 1e16 swap at roughly 19 ticks, clear
///      of the `D = 5` dead zone, so the charged paths are actually reachable. On a deeper pool
///      every bonded swap would sit inside the dead zone and the whole file would pass vacuously.
contract BlockCumulativeImpactTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);
    address internal constant BYSTANDER = address(0xCAFE);

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    int128 internal constant POOL_LIQUIDITY = 1e19;

    /// @dev The notional P-L2-8 measured its finding at: 32e15 displaces exactly 58 ticks here.
    uint256 internal constant REPRO_TOTAL = 32e15;

    /// @dev Thresholds are set to 1 wei so split pieces are never filtered out before the rate is
    ///      reached. Threshold splitting is a SEPARATE documented limitation (ADR-0005 § 6); mixing
    ///      the two would confound this file's measurements.
    ///      `BondCustodyExactOutput.t.sol` covers the realistic-threshold interaction.
    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, 1, 1, true);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _tick() internal view returns (int24 t) {
        // slither-disable-next-line unused-return
        (, t,,) = manager.getSlot0(id_);
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    function _hookDataFor(address who) internal pure returns (bytes memory) {
        return HookDataCodec.encode(who, GENEROUS_CEILING);
    }

    function _maturityNow() internal view returns (uint32) {
        return uint32(block.number) + hook.OBSERVATION_BLOCKS();
    }

    function _bondIdAt(uint32 m, uint32 i) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, m, i));
    }

    function _nextBondId() internal view returns (bytes32) {
        uint32 m = _maturityNow();

        // slither-disable-next-line unused-return
        (,,, uint32 pending,) = hook.maturity(id_, m);

        return _bondIdAt(m, pending);
    }

    /// @dev One swap. `limitTick == type(int24).max` means "no price limit".
    function _swap(int256 amountSpecified, bool zeroForOne, int24 limitTick, address recipient) internal {
        uint160 limit = limitTick == type(int24).max
            ? (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
            : TickMath.getSqrtPriceAtTick(limitTick);

        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookDataFor(recipient)
        );
    }

    function _swapIn(uint256 amountIn, bool zeroForOne) internal {
        _swap(-int256(amountIn), zeroForOne, type(int24).max, TRADER);
    }

    /// @dev Exact-input stopped at `limitTick`, so the FINAL tick is controlled exactly.
    function _swapToTick(bool zeroForOne, int24 limitTick) internal {
        _swap(-int256(uint256(type(uint96).max)), zeroForOne, limitTick, TRADER);
    }

    /// @dev Walks the price to `target` in one leg, choosing direction from where the pool must go.
    function _stepTo(int24 target) internal {
        if (target == _tick()) return;

        _swapToTick(target < _tick(), target);
    }

    /// @dev Rolls past `m` and nudges, so every endpoint of maturity `m` freezes.
    function _nudgeAt(uint32 target) internal {
        vm.roll(target);

        _swapIn(1e11, true);
    }

    /// @dev Aggregate collateral currently held against every bond in bucket `m`.
    function _aggregateCollateral(uint32 m, uint32 upTo) internal view returns (uint256 total, uint256 bonded) {
        for (uint32 i = 0; i < upTo; i++) {
            bytes32 bondId = _bondIdAt(m, i);

            if (!hook.bondExists(bondId)) continue;

            bonded++;
            total += hook.collateralAmountOf(bondId);
        }
    }

    /*//////////////////////////////////////////////////////////////
        s 4 / s 16 -- BLOCK-START INITIALIZATION AND EQUIVALENCE
    //////////////////////////////////////////////////////////////*/

    /// @notice THE COMPATIBILITY TEST. A trade first in its block is charged EXACTLY what the
    ///         pre-ADR-0008 own-impact model charged, to the wei, in all four modes.
    ///
    /// @dev This is the single most important assertion in the migration. `blockStartTick ==
    ///      tickBefore` for a block's first swap, so the two terms of the `max` are equal and the
    ///      effective impact IS the own impact. Isolated traffic — which is most traffic — must be
    ///      completely unaffected.
    ///
    ///      The comparison is against `ModelLReference.collateralFor`, the OLD formula, which is
    ///      derived from ADR-0005 § 2.2's prose and does not know ADR-0008 exists.
    function test_s16_firstSwapInBlock_isBitIdenticalToTheOldModel() public {
        for (uint256 mode = 0; mode < 4; mode++) {
            bool zeroForOne = mode % 2 == 0;
            bool exactInput = mode < 2;

            uint256 snap = vm.snapshotState();

            // A fresh block, with no other swap in it.
            vm.roll(block.number + 1);

            int24 tickBefore = _tick();

            bytes32 bondId = _nextBondId();

            _swap(exactInput ? -int256(REPRO_TOTAL) : int256(REPRO_TOTAL), zeroForOne, type(int24).max, TRADER);

            int24 tickAfter = _tick();

            assertTrue(hook.bondExists(bondId), "the fixture did not bond");

            BondMeBro.Bond memory b = hook.getBond(bondId);

            // The rate stored is the OLD model's rate.
            assertEq(
                uint256(b.collateralBps),
                ModelLReference.collateralBps(tickBefore, tickAfter),
                "first-in-block rate differs from the pre-ADR-0008 rate"
            );

            // ...and so is the collateral actually held, to the wei.
            assertEq(
                uint256(hook.collateralAmountOf(bondId)),
                ModelLReference.collateralFor(b.variableLegAmount, tickBefore, tickAfter),
                "first-in-block collateral differs from the pre-ADR-0008 collateral"
            );

            // The two reference derivations agree here, which is the ADR-0008 half of the claim.
            assertEq(
                ModelLReference.effectiveCollateralBps(tickBefore, tickAfter, tickBefore),
                ModelLReference.collateralBps(tickBefore, tickAfter),
                "the reference disagrees with itself on a first-in-block trade"
            );

            assertEq(b.tickBefore, tickBefore, "tickBefore");
            assertEq(b.tickAfter, tickAfter, "tickAfter");
            assertEq(
                b.collateralIsCurrency0,
                ModelLReference.collateralIsCurrency0(zeroForOne, exactInput),
                "collateral currency"
            );

            vm.revertToState(snap);
        }
    }

    /// @notice The full settlement of a first-in-block bond is unchanged too.
    ///
    /// @dev Equivalence of the RATE is necessary but not sufficient: the migration also moved
    ///      settlement from recomputation to the stored rate. This drives a bond all the way
    ///      through maturity and asserts the refund and slash against the old formula.
    function test_s16_firstSwapInBlock_settlesToTheOldNumbers() public {
        vm.roll(block.number + 1);

        uint32 m = _maturityNow();

        int24 tickBefore = _tick();

        bytes32 bondId = _nextBondId();

        _swapIn(REPRO_TOTAL, true);

        int24 tickAfter = _tick();

        _nudgeAt(m + 1);

        BondMeBro.Bond memory b = hook.getBond(bondId);

        uint256 expectedCollateral = ModelLReference.collateralFor(b.variableLegAmount, tickBefore, tickAfter);

        Currency c = b.collateralIsCurrency0 ? currency0 : currency1;

        uint256 potBefore = hook.insurancePot(id_, c);
        uint256 traderBefore = c.balanceOf(b.refundRecipient);

        hook.settleBond(bondId);

        uint256 slashed = hook.insurancePot(id_, c) - potBefore;
        uint256 refunded = c.balanceOf(b.refundRecipient) - traderBefore;

        assertEq(slashed + refunded, expectedCollateral, "settlement did not conserve the OLD collateral");

        console2.log("S16 first-in-block collateral", expectedCollateral);
        console2.log("S16 slash / refund          ", slashed, refunded);
    }

    /// @notice The latch's behaviour at every lifecycle boundary ADR-0008 § 4 names.
    function test_s4_blockStartLatchLifecycle() public {
        // FIRST EVER SWAP after initialization: the latch was seeded at `afterInitialize`, so the
        // pool's opening tick is the block start and the first swap is priced on its own impact.
        int24 initTick = _tick();

        assertEq(hook.blockStartTickOf(id_), initTick, "latch not seeded at initialization");

        _swapIn(1e16, true);

        int24 afterFirst = _tick();

        assertEq(hook.blockStartTickOf(id_), initTick, "latch moved during its own block");

        // MULTIPLE SWAPS IN THE SAME BLOCK share one latch.
        _swapIn(1e16, true);

        assertEq(hook.blockStartTickOf(id_), initTick, "latch moved on a second same-block swap");

        // A NEW BLOCK re-latches to where the previous block left the price.
        vm.roll(block.number + 1);

        assertEq(hook.blockStartTickOf(id_), _tick(), "latch did not roll to the new block");

        int24 blockTwoStart = _tick();

        assertTrue(blockTwoStart != initTick, "the fixture did not move the price; the test is vacuous");

        _swapIn(1e16, true);

        assertEq(hook.blockStartTickOf(id_), blockTwoStart, "latch is not the second block's opening tick");

        // A QUIET GAP behaves the same: the latch follows the price, not the elapsed time.
        vm.roll(block.number + 5_000);

        assertEq(hook.blockStartTickOf(id_), _tick(), "latch did not roll after a quiet gap");

        // POST-MATURITY swaps are ordinary swaps as far as the latch is concerned.
        vm.roll(block.number + hook.OBSERVATION_BLOCKS() + 1);

        _swapIn(1e16, true);

        assertTrue(hook.blockStartTickOf(id_) != _tick(), "latch should now trail this block's own move");

        afterFirst;
    }

    /// @notice A pool whose owner enables bonding mid-block still has a correct latch.
    ///
    /// @dev The latch is advanced unconditionally, before the `bondingEnabled` branch — the same
    ///      placement the accumulator advance already had, and for the same reason. If it sat
    ///      behind the branch, a pool switched on mid-block would price its first bonded swap
    ///      against a stale or unwritten latch.
    function test_s4_latchIsCorrectWhenBondingIsEnabledMidBlock() public {
        hook.setPoolConfig(key_, 1, 1, false);

        int24 start = _tick();

        _swapIn(1e16, true); // unbonded: bonding is off, but the latch must still advance

        assertEq(hook.blockStartTickOf(id_), start, "latch did not advance while bonding was disabled");

        hook.setPoolConfig(key_, 1, 1, true);

        int24 tickBefore = _tick();

        bytes32 bondId = _nextBondId();

        _swapIn(1e16, true);

        assertTrue(hook.bondExists(bondId), "the fixture did not bond after enabling");

        assertEq(
            uint256(hook.getBond(bondId).collateralBps),
            ModelLReference.effectiveCollateralBps(tickBefore, _tick(), start),
            "a mid-block enable priced against the wrong block start"
        );
    }

    /*//////////////////////////////////////////////////////////////
             s 17 -- SAME-BLOCK SPLIT REGRESSION (THE POINT)
    //////////////////////////////////////////////////////////////*/

    /// @notice The 1 / 2 / 4 / 8 / 16 / 32 / 64 / 128 grid at 58 ticks, on the shipped mechanism.
    ///
    /// @dev WHAT IS ASSERTED, and it is deliberately structural rather than a table of synthetic
    ///      ratios (ADR-0008 § 7):
    ///
    ///        - the split is still CHEAPER than one shot — the limitation is mitigated, not gone;
    ///        - the dilution never exceeds ~3x at any N, where the OLD model reached 15x at 32 and
    ///          grew without bound past that;
    ///        - the dilution does NOT grow with N past 32, which is the property the old model
    ///          lacked and the whole reason for the migration;
    ///        - every piece bonds — no sub-tick free expansion.
    function test_s17_sameBlockSplitGrid() public {
        uint256[8] memory pieces = [uint256(1), 2, 4, 8, 16, 32, 64, 128];

        uint256[8] memory collateral;
        uint256[8] memory bondedCount;

        for (uint256 p = 0; p < pieces.length; p++) {
            uint256 snap = vm.snapshotState();

            uint256 n = pieces[p];
            uint32 m = _maturityNow();

            int24 start = _tick();

            for (uint256 i = 0; i < n; i++) {
                _swapIn(REPRO_TOTAL / n, true);
            }

            uint256 displaced = uint256(int256(start) - int256(_tick()));

            (collateral[p], bondedCount[p]) = _aggregateCollateral(m, uint32(n));

            console2.log("SPLIT pieces / displaced / bonded", n, displaced, bondedCount[p]);
            console2.log("SPLIT aggregate collateral      ", collateral[p]);

            assertEq(displaced, 58, "every arm must move the price the same 58 ticks");

            vm.revertToState(snap);
        }

        for (uint256 p = 1; p < pieces.length; p++) {
            // NO SUB-TICK FREE EXPANSION. Under the old model, pieces below one tick produced a
            // zero rate and were not bonded at all, so the bonded count SATURATED at roughly the
            // displacement in ticks however large N grew -- 58 of 512 -- and the dilution was
            // unbounded. Under ADR-0008 the block displacement keeps the rate positive once the
            // block has moved, so the bonded count TRACKS N.
            //
            // A SMALL LEAD-IN IS LEGITIMATE AND IS ALLOWED FOR. The first pieces of a fine split
            // execute while the block has not yet moved a whole tick, so their effective impact is
            // genuinely zero and they are unbonded -- exactly the treatment an isolated sub-tick
            // swap gets. This fixture starts on a tick boundary so the lead-in is zero here;
            // `BlockImpactGas.t.sol` runs the same split off-boundary and sees two. The tolerance
            // keeps the assertion about saturation rather than about where the pool happens to sit.
            assertGe(bondedCount[p], pieces[p] - 2, "the bonded count is saturating: sub-tick free expansion is back");

            // MITIGATED: dilution stays inside ~3x at every N.
            assertGt(collateral[p] * 3, collateral[0], "dilution exceeded ADR-0008's band");

            // NOT ELIMINATED: the split is still cheaper, exactly as ADR-0008 § 7 says.
            assertLt(collateral[p], collateral[0], "the split stopped being cheaper; ADR-0008 s 7 is now wrong");
        }

        // AND IT STOPS GROWING WITH N. The old model doubled its advantage with every doubling of
        // N past 64; here 128 pieces must be no cheaper than a few percent below 32.
        assertGt(collateral[7] * 100, collateral[5] * 90, "dilution is still growing with N; the mitigation failed");
    }

    /*//////////////////////////////////////////////////////////////
                    s 18 -- INV-L2-4a HARM MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Among trades moving FARTHER from `blockStartTick`, increasing own impact never
    ///         reduces the absolute token slash.
    ///
    /// @dev The security property, swept as a pure function of the shipped rate. `blockStartTick`,
    ///      `tickBefore`, `tickAfter`, leg and residual all vary; the overshoot multipliers are the
    ///      ones the pre-migration `test_overshootAttack_slashNeverFallsAcrossMultipliers` used, so
    ///      this is the original attack re-run under the new semantics rather than a softer one.
    function test_s18_inv_L2_4a_harmMonotonicity() public view {
        uint256[7] memory multX10 = [uint256(10), 15, 20, 30, 50, 100, 1_000];
        uint256[4] memory residuals = [uint256(6), 20, 100, 500];
        int24[3] memory blockStarts = [int24(0), 40, -40];
        uint128[3] memory legs = [uint128(1e18), 1e12, 100_000];

        uint256 checked;

        for (uint256 s = 0; s < 2; s++) {
            for (uint256 bs = 0; bs < blockStarts.length; bs++) {
                for (uint256 l = 0; l < legs.length; l++) {
                    for (uint256 r = 0; r < residuals.length; r++) {
                        checked += _assertAwayLadderIsMonotone(blockStarts[bs], s == 0, legs[l], residuals[r], multX10);
                    }
                }
            }
        }

        console2.log("S18 INV-L2-4a points checked", checked);

        assertGt(checked, 0, "the sweep ran no points");
    }

    /// @dev One overshoot ladder, every step moving AWAY from `blockStart`.
    function _assertAwayLadderIsMonotone(
        int24 blockStart,
        bool up,
        uint128 leg,
        uint256 residual,
        uint256[7] memory multX10
    ) private view returns (uint256 checked) {
        // Starting AT the block start makes every step outward whatever the multiplier.
        int24 tickBefore = blockStart;

        uint128 previousSlash;

        for (uint256 i = 0; i < multX10.length; i++) {
            int256 impact = int256((40 * multX10[i]) / 10);

            int24 tickAfter = int24(up ? int256(tickBefore) + impact : int256(tickBefore) - impact);

            uint256 bps = hook.effectiveCollateralBpsFor(tickBefore, tickAfter, blockStart);

            (uint128 collateral, uint128 slash,) =
                ModelL2SettlementLib.split(leg, bps, ModelL2SettlementLib.slashBpsFor(bps, residual));

            assertGe(uint256(slash), uint256(previousSlash), "INV-L2-4a: overshoot AWAY lowered the absolute slash");

            assertLe(uint256(slash), uint256(collateral), "slash exceeded collateral");

            previousSlash = slash;

            checked++;
        }
    }

    /// @notice The same ladder from an ALREADY-DISPLACED block, still moving outward.
    function test_s18_inv_L2_4a_fromADisplacedBlock() public view {
        uint256[7] memory multX10 = [uint256(10), 15, 20, 30, 50, 100, 1_000];

        for (uint256 s = 0; s < 2; s++) {
            bool up = s == 0;

            int24 tickBefore = up ? int24(60) : int24(-60);

            uint128 previous;

            for (uint256 i = 0; i < multX10.length; i++) {
                int256 impact = int256((40 * multX10[i]) / 10);

                int24 tickAfter = int24(up ? int256(tickBefore) + impact : int256(tickBefore) - impact);

                uint256 bps = hook.effectiveCollateralBpsFor(tickBefore, tickAfter, 0);

                (, uint128 slash,) = ModelL2SettlementLib.split(1e18, bps, ModelL2SettlementLib.slashBpsFor(bps, 100));

                assertGe(uint256(slash), uint256(previous), "INV-L2-4a: displaced-block overshoot lowered the slash");

                previous = slash;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                       s 19 -- INV-L2-4b NO DISCOUNT
    //////////////////////////////////////////////////////////////*/

    /// @notice The block rate is NEVER below the own-impact rate, anywhere in the domain.
    ///
    /// @dev `max(own, displacement) >= own`, so this is structural — but it is the property that
    ///      makes INV-L2-4a's restriction safe rather than a loophole, so it is swept rather than
    ///      asserted in prose. Outward, reverting, exactly at the midpoint, and crossing through
    ///      the block start, both signs.
    function test_s19_inv_L2_4b_noDiscount() public view {
        int24[5] memory blockStarts = [int24(0), 60, -60, 1000, -1000];
        int24[7] memory offsets = [int24(-200), -60, -13, 0, 13, 60, 200];

        uint256 checked;

        for (uint256 bs = 0; bs < blockStarts.length; bs++) {
            for (uint256 o = 0; o < offsets.length; o++) {
                int24 tickBefore = int24(int256(blockStarts[bs]) + int256(offsets[o]));

                for (int256 step = -240; step <= 240; step += 7) {
                    int24 tickAfter = int24(int256(tickBefore) + step);

                    uint256 blockBps = hook.effectiveCollateralBpsFor(tickBefore, tickAfter, blockStarts[bs]);
                    uint256 ownBps = hook.collateralBpsFor(tickBefore, tickAfter);

                    assertGe(blockBps, ownBps, "INV-L2-4b: the block rate fell below the own-impact rate");

                    // And the reference agrees, independently derived.
                    assertEq(
                        blockBps,
                        ModelLReference.effectiveCollateralBps(tickBefore, tickAfter, blockStarts[bs]),
                        "the hook disagrees with the ADR-0008 reference"
                    );

                    checked++;
                }
            }
        }

        console2.log("S19 INV-L2-4b points checked", checked);
    }

    /// @notice INV-L2-4b on a LIVE pool, not just as a pure function.
    ///
    /// @dev Drives real reverting and outward trades behind a displacement and asserts the
    ///      collateral actually taken is at least what the old model would have taken.
    function test_s19_inv_L2_4b_onALivePool() public {
        int24[6] memory targets = [int24(-66), -50, -40, -29, -20, -2];

        for (uint256 i = 0; i < targets.length; i++) {
            uint256 snap = vm.snapshotState();

            int24 start = _tick();

            _swapToTick(true, start - 58);

            int24 tickBefore = _tick();

            bytes32 bondId = _nextBondId();

            _stepTo(int24(int256(start) + int256(targets[i])));

            if (hook.bondExists(bondId)) {
                BondMeBro.Bond memory b = hook.getBond(bondId);

                assertGe(
                    uint256(hook.collateralAmountOf(bondId)),
                    ModelLReference.collateralFor(b.variableLegAmount, tickBefore, b.tickAfter),
                    "INV-L2-4b: live collateral fell below the old model's"
                );
            }

            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                     s 20 -- INV-L2-4c PATH MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /// @notice No reversal route to the same final tick is cheaper than the monotone floor.
    ///
    /// @dev Every arm ends at exactly −58 ticks in one block, so the LP-visible outcome is
    ///      identical and only the route differs. The floor is the finest monotone ramp the tick
    ///      grid allows: `Σ Δᵢ·effᵢ` is a right Riemann sum of `∫x dx`, so it overestimates and the
    ///      overestimate shrinks with the partition.
    ///
    ///      COARSER MONOTONE PARTITIONS ARE ALLOWED TO COST MORE — that is the Riemann property,
    ///      not a defect — so what is asserted is that no path CONTAINING A REVERSAL beats the
    ///      floor, not that every partition ties.
    function test_s20_inv_L2_4c_pathMonotonicity() public {
        uint256 floorCost = _pathCost(_monotone(58), "monotone 58 x 1 tick (floor)");

        uint256[6] memory reversalCosts;

        reversalCosts[0] = _pathCost(_overshootThenRevert(70), "overshoot -70 then revert");
        reversalCosts[1] = _pathCost(_overshootThenRevert(116), "overshoot -116 then revert");
        reversalCosts[2] = _pathCost(_sawtooth(2), "sawtooth 58/29 x2");
        reversalCosts[3] = _pathCost(_sawtooth(4), "sawtooth 58/29 x4");
        reversalCosts[4] = _pathCost(_wrongWayFirst(), "wrong way +29 first");
        reversalCosts[5] = _pathCost(_shallowRetrace(4), "fine ramp, 4 retrace steps");

        for (uint256 i = 0; i < reversalCosts.length; i++) {
            assertGt(reversalCosts[i], floorCost, "INV-L2-4c: a reversal route beat the monotone floor");
        }

        // Coarser monotone partitions cost at least the floor too, which is the Riemann half.
        assertGe(_pathCost(_monotone(8), "monotone 8 pieces"), floorCost, "a coarse monotone ramp beat the floor");
        assertGe(_pathCost(_monotone(32), "monotone 32 pieces"), floorCost, "a coarse monotone ramp beat the floor");
    }

    /// @dev Drives one signed path in a single block and returns aggregate collateral held.
    function _pathCost(int24[] memory offsets, string memory name) private returns (uint256 total) {
        uint256 snap = vm.snapshotState();

        uint32 m = _maturityNow();

        int24 start = _tick();

        for (uint256 i = 0; i < offsets.length; i++) {
            _stepTo(int24(int256(start) + int256(offsets[i])));
        }

        assertEq(int256(_tick()) - int256(start), -58, "path did not end at the common final tick");

        (total,) = _aggregateCollateral(m, uint32(offsets.length + 2));

        console2.log("PATH", name);
        console2.log("     aggregate collateral", total);

        vm.revertToState(snap);
    }

    function _monotone(uint256 n) private pure returns (int24[] memory t) {
        t = new int24[](n);

        for (uint256 i = 0; i < n; i++) {
            t[i] = int24(-int256((58 * (i + 1)) / n));
        }
    }

    function _overshootThenRevert(uint256 depth) private pure returns (int24[] memory t) {
        t = new int24[](9);

        for (uint256 i = 0; i < 8; i++) {
            t[i] = int24(-int256((depth * (i + 1)) / 8));
        }

        t[8] = -58;
    }

    function _sawtooth(uint256 cycles) private pure returns (int24[] memory t) {
        t = new int24[](2 * cycles + 1);

        for (uint256 i = 0; i < cycles; i++) {
            t[2 * i] = -58;
            t[2 * i + 1] = -29;
        }

        t[2 * cycles] = -58;
    }

    function _wrongWayFirst() private pure returns (int24[] memory t) {
        t = new int24[](5);

        t[0] = 29;
        t[1] = 0;
        t[2] = -20;
        t[3] = -40;
        t[4] = -58;
    }

    function _shallowRetrace(uint256 steps) private pure returns (int24[] memory t) {
        t = new int24[](58 + 2 * steps);

        uint256 k;

        for (uint256 i = 1; i <= 29; i++) {
            t[k++] = int24(-int256(i));
        }

        for (uint256 i = 0; i < steps; i++) {
            t[k++] = int24(-int256(29 - (i + 1)));
        }

        for (uint256 i = 0; i < steps; i++) {
            t[k++] = int24(-int256(29 - steps + (i + 1)));
        }

        for (uint256 i = 30; i <= 58; i++) {
            t[k++] = int24(-int256(i));
        }
    }

    /*//////////////////////////////////////////////////////////////
                       s 21 -- BENIGN FOLLOW-ON
    //////////////////////////////////////////////////////////////*/

    /// @notice What a later, unrelated trade in a displaced block actually pays.
    ///
    /// @dev THE THREE SHAPES, and the third is the one that matters most for fairness:
    ///
    ///        A. adds to the displacement  -> MORE REFUNDABLE COLLATERAL is posted
    ///        B. restores >= ~half of it   -> converges to the own-impact model exactly
    ///        C. deep / full reversion     -> no slash manufactured by the block displacement
    ///
    ///      The additional collateral in case A is REFUNDABLE, not a fee: the slash is decided by
    ///      the trade's own residual through `targetSlashBps`, which ADR-0008 does not touch.
    function test_s21_benignFollowOn() public {
        // A. Further out.
        _benignRow(-66, "adds to displacement");

        // B. Restores half.
        _benignRow(-29, "restores ~half");

        // C. Near-full reversion.
        _benignRow(-2, "near-full reversion");
    }

    function _benignRow(int24 bTargetOffset, string memory name) private {
        uint256 snap = vm.snapshotState();

        uint32 m = _maturityNow();

        int24 start = _tick();

        // Trader A displaces the block by 58 ticks.
        _swapToTick(true, start - 58);

        int24 tickBefore = _tick();

        bytes32 bondId = _nextBondId();

        int24 target = int24(int256(start) + int256(bTargetOffset));

        if (target != _tick()) {
            _swap(-int256(uint256(type(uint96).max)), target < _tick(), target, BYSTANDER);
        }

        assertTrue(hook.bondExists(bondId), "trader B did not bond");

        BondMeBro.Bond memory b = hook.getBond(bondId);

        uint256 blockCollateral = hook.collateralAmountOf(bondId);
        uint256 ownCollateral = ModelLReference.collateralFor(b.variableLegAmount, tickBefore, b.tickAfter);

        _nudgeAt(m + 1);

        Currency c = b.collateralIsCurrency0 ? currency0 : currency1;

        uint256 potBefore = hook.insurancePot(id_, c);

        hook.settleBond(bondId);

        uint256 slashed = hook.insurancePot(id_, c) - potBefore;

        console2.log("BENIGN", name);
        console2.log(
            "   own impact / block displacement",
            uint256(int256(b.tickAfter > tickBefore ? b.tickAfter - tickBefore : tickBefore - b.tickAfter)),
            uint256(int256(b.tickAfter > start ? b.tickAfter - start : start - b.tickAfter))
        );
        console2.log("   collateral OLD / BLOCK         ", ownCollateral, blockCollateral);
        console2.log("   slash                          ", slashed);
        console2.log("   EXTRA REFUNDABLE               ", blockCollateral - ownCollateral);

        // INV-L2-4b, live.
        assertGe(blockCollateral, ownCollateral, "the block model charged a follow-on LESS than the old model");

        // The extra is refundable: the slash never exceeds what the OLD model would have taken,
        // because `targetSlashBps` is set by the trade's own residual and ADR-0008 does not
        // touch it.
        assertLe(slashed, ownCollateral, "the block displacement manufactured slash beyond the own-impact charge");

        // Case B and C converge exactly: once the trade restores at least half the displacement,
        // its own impact dominates the `max` and the model is a literal no-op.
        if (bTargetOffset >= -29) {
            assertEq(blockCollateral, ownCollateral, "a restoring trade was charged more than the own-impact model");
        }

        vm.revertToState(snap);
    }

    /*//////////////////////////////////////////////////////////////
             s 7 -- CUSTODY MATCHES THE STORED RATE, TO THE WEI
    //////////////////////////////////////////////////////////////*/

    /// @notice The physical collateral taken equals `leg * storedBps / BPS`, exactly.
    ///
    /// @dev The migration's central accounting requirement: the record must reproduce what moved.
    ///      Measured from the hook's REAL token balance, across a split so most rows are priced on
    ///      the block term rather than their own impact.
    function test_s7_physicalCustodyMatchesTheStoredRate() public {
        uint32 m = _maturityNow();

        for (uint256 i = 0; i < 8; i++) {
            uint256 hookBefore = currency1.balanceOf(address(hook));

            bytes32 bondId = _nextBondId();

            _swapIn(REPRO_TOTAL / 8, true);

            uint256 taken = currency1.balanceOf(address(hook)) - hookBefore;

            assertTrue(hook.bondExists(bondId), "piece did not bond");

            BondMeBro.Bond memory b = hook.getBond(bondId);

            assertEq(
                taken,
                (uint256(b.variableLegAmount) * uint256(b.collateralBps)) / hook.BPS(),
                "physical custody does not equal leg * storedBps / BPS"
            );

            assertEq(taken, hook.collateralAmountOf(bondId), "collateralAmountOf does not equal what was taken");
        }

        m;
    }
}
