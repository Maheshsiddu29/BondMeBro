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
import {ModelL2Reference} from "./utils/ModelL2Reference.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title ModelL2SettlementIntegrationTest
///
/// @notice Model L2 settlement driven through a real Uniswap v4 pool, checked against an
///         independent reference built from the observed per-block tick path.
///
/// @dev WHAT THIS ADDS OVER THE PURE SUITE. `ModelL2Settlement.t.sol` proves the arithmetic over
///      the whole input space. It cannot prove the arithmetic is WIRED UP: that settlement actually
///      resolves C6, C8 and C10 from the checkpoint scheduler, that the collateral it recomputes is
///      the collateral custody physically took, that the slash lands in the right currency's pot,
///      and that Model B is genuinely gone from the path.
///
///      THE REFERENCE IS BUILT FROM THE POOL, NOT FROM THE HOOK. Every swap goes through
///      `_swapTracked`, which records the pool tick from `PoolManager.getSlot0` afterwards. The
///      expected settlement is then computed by `ModelL2Reference` from that observed per-block
///      path — summing displacements rather than differencing the hook's cumulatives. So a
///      disagreement means the hook and the pool disagree, which is the only comparison worth
///      making.
contract ModelL2SettlementIntegrationTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;
    uint16 internal constant REFUND_TOL = 5;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    /// @dev Shallow enough that a 1e16 swap moves ~19 ticks — clear of the D = 5 dead zone, so the
    ///      settlement paths under test are actually reachable. On a deeper pool every bonded swap
    ///      would land inside the dead zone and every test here would assert `0 == 0`.
    int128 internal constant POOL_LIQUIDITY = 1e19;

    int256 internal constant BONDED = -1e16;
    int256 internal constant NUDGE = -1e13;

    /// @dev Per-block record of the pool's effective tick, for the independent reference.
    struct RefPoint {
        uint32 blockNumber;
        int24 tickFrom;
    }

    RefPoint[] internal refPoints;

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

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, true);

        refPoints.push(RefPoint({blockNumber: uint32(block.number), tickFrom: _poolTick()}));
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _poolTick() internal view returns (int24 tick) {
        // slither-disable-next-line unused-return
        (, tick,,) = manager.getSlot0(id_);
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    function _swapTracked(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        refPoints.push(RefPoint({blockNumber: uint32(block.number), tickFrom: _poolTick()}));
    }

    /// @dev The pool's effective tick across `[atBlock, atBlock+1)`, from the observed path.
    function _tickDuring(uint32 atBlock) internal view returns (int24) {
        for (uint256 i = refPoints.length; i > 0; i--) {
            if (refPoints[i - 1].blockNumber <= atBlock) return refPoints[i - 1].tickFrom;
        }

        revert("reference does not cover a block before initialization");
    }

    /// @dev The bond's ten-block observation path, as the reference wants it.
    function _observedPath(uint32 openBlock) internal view returns (int24[10] memory path) {
        for (uint256 k = 0; k < 10; k++) {
            path[k] = _tickDuring(openBlock + uint32(k));
        }
    }

    function _bondIdAt(uint32 maturityBlock, uint32 index) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, index));
    }

    /// @dev Opens one bonded swap. Returns its id, opening block and maturity.
    function _openBond(int256 amount, bool zeroForOne)
        internal
        returns (bytes32 bondId, uint32 openBlock, uint32 maturityBlock)
    {
        openBlock = uint32(block.number);
        maturityBlock = openBlock + hook.OBSERVATION_BLOCKS();
        bondId = _bondIdAt(maturityBlock, 0);

        _swapTracked(amount, zeroForOne, _hookData());
    }

    /// @dev Settles a bond and reports what actually moved.
    struct Settled {
        Currency currency;
        uint128 collateral;
        uint256 refund;
        uint256 slash;
    }

    function _settle(bytes32 bondId) internal returns (Settled memory out) {
        BondMeBro.Bond memory bond = hook.getBond(bondId);

        out.currency = bond.collateralIsCurrency0 ? currency0 : currency1;
        out.collateral = hook.collateralAmountOf(bondId);

        uint256 traderBefore = out.currency.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(id_, out.currency);

        hook.settleBond(bondId);

        out.refund = out.currency.balanceOf(TRADER) - traderBefore;
        out.slash = hook.insurancePot(id_, out.currency) - potBefore;
    }

    /// @dev Asserts a settlement matches the reference computed from the OBSERVED tick path.
    function _assertMatchesReference(bytes32 bondId, uint32 openBlock, Settled memory got, string memory label)
        internal
        view
    {
        BondMeBro.Bond memory bond = hook.getBond(bondId);

        (uint128 refCollateral, uint128 refSlash, uint128 refRefund,) =
            ModelL2Reference.settle(bond.variableLegAmount, bond.tickBefore, bond.tickAfter, _observedPath(openBlock));

        assertEq(got.collateral, refCollateral, string.concat(label, ": collateral disagrees with the reference"));
        assertEq(got.slash, refSlash, string.concat(label, ": slash disagrees with the reference"));
        assertEq(got.refund, refRefund, string.concat(label, ": refund disagrees with the reference"));

        // INV-L2-3, observed end to end rather than in the library.
        assertEq(
            got.refund + got.slash, uint256(got.collateral), string.concat(label, ": INV-L2-3 conservation failed")
        );
    }

    /*//////////////////////////////////////////////////////////////
             THE THREE CHECKPOINTS ACTUALLY DRIVE SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Settlement reads C6, C8 and C10 — not C10 alone.
    ///
    /// @dev THE HEADLINE WIRING CHECK, and the thing P-L2-5 explicitly deferred.
    ///
    ///      Proven by construction rather than by inspection: the pool is driven so the two late
    ///      windows carry DIFFERENT displacements, then the settlement outcome is compared against
    ///      a reference that uses both. A settlement still reading C10 alone would compute a
    ///      whole-window average and land somewhere else entirely.
    ///
    ///      The second half is the sharper one: the bond is settled, and the result is checked
    ///      against what `max(window1, window2)` predicts rather than against either window on its
    ///      own, so using the wrong window — or averaging them — fails.
    function test_settlementReadsAllThreeEndpoints() public {
        (bytes32 bondId, uint32 openBlock, uint32 m) = _openBond(BONDED, true);

        // Let the displacement persist through window 1 (blocks 6-7), then revert hard across
        // window 2 (blocks 8-9), so the two windows disagree sharply.
        vm.roll(uint256(openBlock) + 8);

        _swapTracked(-3e16, false, _hookData()); // push the price back the other way

        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        // All three endpoints must be frozen by now.
        (,,,, uint8 mask) = hook.maturity(id_, m);

        assertEq(mask, hook.FROZEN_ALL(), "the bond's three endpoints did not all freeze");

        int24[10] memory path = _observedPath(openBlock);

        BondMeBro.Bond memory bond = hook.getBond(bondId);

        int256 w1 = ModelL2Reference.windowTwa(path, 6, 8, bond.tickBefore, bond.tickAfter);
        int256 w2 = ModelL2Reference.windowTwa(path, 8, 10, bond.tickBefore, bond.tickAfter);

        assertTrue(w1 != w2, "the fixture did not make the two windows differ; this proves nothing");

        Settled memory got = _settle(bondId);

        _assertMatchesReference(bondId, openBlock, got, "two-window settlement");

        console2.log("window1", w1);
        console2.log("window2", w2);
        console2.log("slash  ", got.slash);
    }

    /// @notice A bond whose C6 is unrecoverable cannot be settled, and the revert names C6.
    ///
    /// @dev The other direction of the same wiring claim. If settlement still read C10 alone, a
    ///      bucket with an intact C10 and a wiped C6 would settle happily. It must not: Model L2
    ///      needs the early endpoint, so losing it makes the bond unsettleable rather than settled
    ///      on partial data.
    function test_settlementFailsWhenAnEarlyEndpointIsUnrecoverable() public {
        (bytes32 bondId,, uint32 m) = _openBond(BONDED, true);

        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        (,,, uint32 pending,) = hook.maturity(id_, m);

        // Wipe every endpoint and the mask, keeping the liability. `pendingBonds` sits at byte 21.
        bytes32 slot = keccak256(abi.encode(uint256(m), keccak256(abi.encode(id_, uint256(2)))));

        vm.store(address(hook), slot, bytes32(uint256(pending) << 168));

        vm.roll(uint256(m) + 40);

        _swapTracked(NUDGE, true, "");

        // slither-disable-next-line unused-return
        (, uint32 lastUpdate,,) = hook.accumulator(id_);

        vm.expectRevert(
            abi.encodeWithSelector(
                BondMeBro.MaturityCheckpointMissing.selector, bondId, m - hook.C6_OFFSET_FROM_MATURITY(), lastUpdate
            )
        );

        hook.settleBond(bondId);
    }

    /*//////////////////////////////////////////////////////////////
                     MODEL B IS GONE FROM THE PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Settlement does not produce Model B's answer, on a case where the two models differ.
    ///
    /// @dev PROVING A NEGATIVE, BY CONSTRUCTION RATHER THAN BY GREP. `PersistenceMathLib` is no
    ///      longer imported by `src/BondMeBro.sol` — the compiler would fail if it were called —
    ///      but "the import is gone" is a fact about the source, not about behaviour. This is the
    ///      behavioural half.
    ///
    ///      The construction is a displacement INSIDE the dead zone that fully persists. The two
    ///      models disagree sharply there:
    ///
    ///        Model B  — the displacement survives in full, so persistence is 100% and the whole
    ///                   collateral is slashed. Its `refundToleranceTicks` is a tolerance
    ///                   SUBTRACTED FROM BOTH SIDES of a ratio, not a floor: a fully persistent
    ///                   move is fully charged no matter how small.
    ///        Model L2 — the residual is at or below `D = 5`, so the chargeable residual is zero
    ///                   and the entire collateral comes back.
    ///
    ///      So a hook still running Model B would slash everything here. Observing a full refund is
    ///      positive evidence that the L2 path is the one executing.
    function test_modelBIsNotOnTheSettlementPath() public {
        (bytes32 bondId,, uint32 m) = _openBond(-int256(uint256(MIN_BONDED) * 2), true);

        BondMeBro.Bond memory bond = hook.getBond(bondId);

        uint256 impact = uint256(int256(bond.tickBefore) - int256(bond.tickAfter));

        assertGt(impact, 0, "the fixture moved no tick, so nothing was bonded");
        assertLe(impact, 5, "the fixture must sit inside the dead zone for the two models to differ");

        // Fully persistent: nothing pushes back before maturity.
        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        Settled memory got = _settle(bondId);

        assertGt(got.collateral, 0, "no collateral was posted; the comparison would be vacuous");

        // Model L2's answer.
        assertEq(got.refund, uint256(got.collateral), "settlement did not refund in full inside the dead zone");

        // Model B's answer, which must NOT be what happened.
        assertEq(got.slash, 0, "settlement slashed a fully persistent dead-zone move: Model B behaviour");
    }

    /*//////////////////////////////////////////////////////////////
                     THE THREE SETTLEMENT OUTCOMES
    //////////////////////////////////////////////////////////////*/

    /// @notice A reverted price refunds in full and credits nothing to the pot.
    function test_fullRefund_whenThePriceReverts() public {
        (bytes32 bondId, uint32 openBlock, uint32 m) = _openBond(BONDED, true);

        // Arbitrage pushes the price back, and a little past.
        vm.roll(uint256(openBlock) + 1);

        _swapTracked(-4e16, false, _hookData());

        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        Settled memory got = _settle(bondId);

        assertGt(got.collateral, 0, "no collateral was posted; the case is vacuous");
        assertEq(got.slash, 0, "a reverted price was slashed");
        assertEq(got.refund, uint256(got.collateral), "a reverted price was not refunded in full");

        _assertMatchesReference(bondId, openBlock, got, "full refund");
    }

    /// @notice A persistent displacement forfeits the whole collateral.
    function test_fullSlash_whenTheDisplacementPersists() public {
        (bytes32 bondId, uint32 openBlock, uint32 m) = _openBond(BONDED, true);

        // Nothing pushes back; the displacement simply persists.
        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        Settled memory got = _settle(bondId);

        assertGt(got.collateral, 0, "no collateral was posted");
        assertEq(got.slash, uint256(got.collateral), "a fully persistent displacement was not fully slashed");
        assertEq(got.refund, 0, "a fully persistent displacement was refunded");

        _assertMatchesReference(bondId, openBlock, got, "full slash");
    }

    /// @notice A partly reverted displacement is partly slashed and partly refunded.
    ///
    /// @dev The interesting middle case, and the one a broken dead zone or a wrong window would
    ///      most likely land wrong. Both halves must be strictly positive, or the fixture has
    ///      collapsed into one of the two extremes above and proves nothing new.
    function test_partialSlash_whenTheDisplacementPartlyReverts() public {
        (bytes32 bondId, uint32 openBlock, uint32 m) = _openBond(BONDED, true);

        vm.roll(uint256(openBlock) + 3);

        // Push back most, but not all, of the way.
        _swapTracked(-7e15, false, _hookData());

        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        Settled memory got = _settle(bondId);

        assertGt(got.slash, 0, "the partial case did not slash at all");
        assertGt(got.refund, 0, "the partial case refunded nothing");

        _assertMatchesReference(bondId, openBlock, got, "partial slash");

        console2.log("partial: collateral", got.collateral);
        console2.log("partial: slash     ", got.slash);
        console2.log("partial: refund    ", got.refund);
    }

    /// @notice A displacement inside the dead zone is refunded in full, however persistent.
    ///
    /// @dev The `D = 5` behaviour observed end to end. A small bonded swap that moves the price by
    ///      five ticks or fewer and NEVER reverts still pays nothing — the limit is size, not
    ///      silence, and not repentance.
    function test_deadZoneRefund_smallPersistentDisplacementPaysNothing() public {
        // Sized to move the price by only a few ticks against this liquidity.
        (bytes32 bondId, uint32 openBlock, uint32 m) = _openBond(-int256(uint256(MIN_BONDED) * 2), true);

        BondMeBro.Bond memory bond = hook.getBond(bondId);

        uint256 impact = uint256(int256(bond.tickBefore) - int256(bond.tickAfter));

        assertLe(impact, 5, "the fixture moved more than D ticks; it is not testing the dead zone");
        assertGt(impact, 0, "the fixture moved no tick at all, so nothing was bonded");

        // The displacement persists all the way to maturity.
        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        Settled memory got = _settle(bondId);

        assertGt(got.collateral, 0, "no collateral was posted; the dead-zone claim would be vacuous");
        assertEq(got.slash, 0, "a displacement inside the dead zone was slashed");
        assertEq(got.refund, uint256(got.collateral), "a dead-zone bond was not fully refunded");

        _assertMatchesReference(bondId, openBlock, got, "dead zone");
    }

    /*//////////////////////////////////////////////////////////////
                        QUIET AND LATE SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice A quiet pool extrapolates and is NOT auto-refunded.
    ///
    /// @dev The rule ADR-0005 § 6.5 restates: the charge depends on measured displacement, never on
    ///      activity. A bonded swap that displaces the price well past the dead zone and is then
    ///      followed by total silence must still be slashed — the endpoints derive exactly, and
    ///      they derive to a persistent displacement.
    ///
    ///      Getting this wrong in the forgiving direction would be a free attack: displace the
    ///      price, then simply do not trade.
    function test_quietPool_persistentDisplacementIsStillSlashed() public {
        (bytes32 bondId, uint32 openBlock, uint32 m) = _openBond(BONDED, true);

        // Total silence from the opening swap onward.
        vm.roll(uint256(m) + 60);

        // slither-disable-next-line unused-return
        (, uint32 lastUpdate,,) = hook.accumulator(id_);

        assertEq(lastUpdate, openBlock, "fixture: the pool must be silent since the bond opened");

        (,,,, uint8 maskBefore) = hook.maturity(id_, m);

        assertEq(maskBefore, 0, "nothing should be frozen on a silent pool");

        Settled memory got = _settle(bondId);

        assertGt(got.slash, 0, "a quiet pool auto-refunded a persistent displacement");
        assertEq(got.slash, uint256(got.collateral), "quiet persistence should forfeit the whole collateral");

        _assertMatchesReference(bondId, openBlock, got, "quiet");

        // Settlement froze what it derived.
        (,,,, uint8 maskAfter) = hook.maturity(id_, m);

        assertEq(maskAfter, hook.FROZEN_ALL(), "settlement did not freeze the endpoints it derived");
    }

    /// @notice Settlement is identical at M, M+1 and M+10,000, with post-maturity swaps in between.
    ///
    /// @dev ADR-0003's governing invariant, now applied to the FULL L2 economics rather than to the
    ///      checkpoints alone. Settlement is permissionless, so if the answer moved with the calling
    ///      block, whoever chose the block would be choosing the answer.
    ///
    ///      The hammering between maturity and settlement is the point: it moves the live price a
    ///      long way, so any accidental dependence on current state — rather than on the frozen
    ///      endpoints — shows up immediately.
    function test_settlementIsIndependentOfCallTimeAndLaterActivity() public {
        uint256 baseline = vm.snapshotState();

        (uint256 slashAtM, uint256 refundAtM) = _openPersistAndSettle(0, false);

        vm.revertToState(baseline);

        (uint256 slashAtM1, uint256 refundAtM1) = _openPersistAndSettle(1, false);

        vm.revertToState(baseline);

        (uint256 slashLate, uint256 refundLate) = _openPersistAndSettle(10_000, false);

        vm.revertToState(baseline);

        // And the same again, with heavy trading between maturity and settlement.
        (uint256 slashHammered, uint256 refundHammered) = _openPersistAndSettle(10_000, true);

        assertEq(slashAtM1, slashAtM, "settling one block later changed the slash");
        assertEq(refundAtM1, refundAtM, "settling one block later changed the refund");

        assertEq(slashLate, slashAtM, "settling 10,000 blocks later changed the slash");
        assertEq(refundLate, refundAtM, "settling 10,000 blocks later changed the refund");

        assertEq(slashHammered, slashAtM, "post-maturity trading changed the slash");
        assertEq(refundHammered, refundAtM, "post-maturity trading changed the refund");

        assertGt(slashAtM, 0, "the fixture produced no slash, so invariance is vacuous");
    }

    /// @dev Opens a persistent bond, waits `delay` blocks past maturity, optionally hammers the
    ///      pool, then settles.
    function _openPersistAndSettle(uint32 delay, bool hammer) internal returns (uint256 slash, uint256 refund) {
        (bytes32 bondId,, uint32 m) = _openBond(BONDED, true);

        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        if (delay > 0) vm.roll(uint256(m) + delay);

        if (hammer) {
            for (uint256 i = 0; i < 5; i++) {
                vm.roll(block.number + 3);

                _swapTracked(BONDED * 2, i % 2 == 0, _hookData());
            }
        }

        Settled memory got = _settle(bondId);

        return (got.slash, got.refund);
    }

    /*//////////////////////////////////////////////////////////////
                    CUSTODY / SETTLEMENT AGREEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice The collateral settlement recomputes equals the collateral custody physically took.
    ///
    /// @dev ADR-0005 § 3.2's requirement, and the reason the record can store the variable leg
    ///      rather than the collateral at all. If the recomputation differed by even one wei, the
    ///      hook would pay out more than it holds or accumulate dust with no owner.
    ///
    ///      Checked across all four token-flow modes, because the collateral currency differs
    ///      between them and a mode-specific error would hide in a single-direction test.
    function test_recomputedCollateralEqualsWhatCustodyTook() public {
        for (uint256 i = 0; i < 4; i++) {
            bool exactInput = i < 2;
            bool zeroForOne = (i % 2) == 0;

            uint256 snapshot = vm.snapshotState();

            Currency collateralCurrency =
                ModelLReference.collateralIsCurrency0(zeroForOne, exactInput) ? currency0 : currency1;

            uint256 hookBefore = collateralCurrency.balanceOf(address(hook));

            (bytes32 bondId,, uint32 m) = _openBond(exactInput ? BONDED : -BONDED, zeroForOne);

            uint256 physicallyTaken = collateralCurrency.balanceOf(address(hook)) - hookBefore;

            assertGt(physicallyTaken, 0, "the mode took no collateral");

            assertEq(
                uint256(hook.collateralAmountOf(bondId)),
                physicallyTaken,
                "recomputed collateral differs from what custody took"
            );

            // And settlement pays out exactly that, no more and no less.
            vm.roll(uint256(m) + 1);

            _swapTracked(NUDGE, true, "");

            Settled memory got = _settle(bondId);

            assertEq(uint256(got.collateral), physicallyTaken, "settlement used a different collateral");
            assertEq(got.refund + got.slash, physicallyTaken, "settlement did not conserve what was taken");

            vm.revertToState(snapshot);
        }
    }

    /// @notice The slash credits the pot of the collateral currency recorded in the bond.
    ///
    /// @dev INV-L2-10's rule applied to settlement: the currency is READ FROM THE RECORD, never
    ///      inferred from the swap direction. Under variable-leg custody the direction alone gives
    ///      the wrong answer for half of all bonds, because the swap KIND also decides.
    function test_slashCreditsTheRecordedCurrencyAndOnlyThat() public {
        // Exact-input oneForZero: collateral is currency0 (the OUTPUT).
        (bytes32 bondId,, uint32 m) = _openBond(BONDED, false);

        BondMeBro.Bond memory bond = hook.getBond(bondId);

        assertTrue(bond.collateralIsCurrency0, "fixture: this mode should bond in currency0");

        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        uint256 otherPotBefore = hook.insurancePot(id_, currency1);

        Settled memory got = _settle(bondId);

        assertGt(got.slash, 0, "the fixture produced no slash");

        assertEq(hook.insurancePot(id_, currency1), otherPotBefore, "the slash credited the WRONG currency's pot");

        assertEq(
            Currency.unwrap(got.currency), Currency.unwrap(currency0), "settlement used the wrong collateral currency"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             BATCH AND FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice A batch settles every bond and conserves each one's collateral.
    function test_settleMany_conservesEveryBond() public {
        uint32 openBlock = uint32(block.number);
        uint32 m = openBlock + hook.OBSERVATION_BLOCKS();

        bytes32[] memory ids = new bytes32[](4);

        for (uint32 i = 0; i < 4; i++) {
            ids[i] = _bondIdAt(m, i);

            _swapTracked(BONDED, true, _hookData());
        }

        vm.roll(uint256(m) + 1);

        _swapTracked(NUDGE, true, "");

        uint128 total;

        for (uint256 i = 0; i < 4; i++) {
            total += hook.collateralAmountOf(ids[i]);
        }

        Currency c = hook.getBond(ids[0]).collateralIsCurrency0 ? currency0 : currency1;

        uint256 traderBefore = c.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(id_, c);

        hook.settleMany(ids);

        uint256 refunded = c.balanceOf(TRADER) - traderBefore;
        uint256 slashed = hook.insurancePot(id_, c) - potBefore;

        assertEq(refunded + slashed, uint256(total), "the batch did not conserve total collateral");

        for (uint256 i = 0; i < 4; i++) {
            assertEq(uint8(hook.getBond(ids[i]).state), 3, "a batched bond is not SETTLED");
        }
    }

    /// @notice Settlement matches the reference over randomized late tick paths.
    ///
    /// @dev The end-to-end differential. The bond opens, the pool is driven through a random late
    ///      path, and the realized settlement is compared against what the reference computes from
    ///      the OBSERVED ticks. Anything that only shows on unusual paths — an endpoint off by a
    ///      block, a sign error under an unusual direction — has somewhere to appear.
    function testFuzz_settlementMatchesTheReference(uint256 seed, bool zeroForOne) public {
        uint256 rng = uint256(keccak256(abi.encode(seed)));

        (bytes32 bondId, uint32 openBlock, uint32 m) = _openBond(BONDED, zeroForOne);

        (,,, uint32 pending,) = hook.maturity(id_, m);

        vm.assume(pending == 1);

        // Drive a random late path.
        //
        // THE ROLL MUST ONLY EVER ADVANCE. An earlier version of this driver rolled to
        // `openBlock + 1 + (rng % 9)` each step, which can pick a SMALLER offset than the previous
        // step and move `block.number` backwards. The accumulator then underflows on
        // `nowBlock - lastUpdate` and the swap reverts with an arithmetic panic.
        //
        // That is a defect in the driver, not in the hook: block numbers never decrease on any
        // chain, so the state is unreachable in production and the hook is right to assume it.
        // Advancing by a random positive delta keeps the timeline random without inventing an
        // impossible one.
        for (uint256 step = 0; step < 4; step++) {
            rng = uint256(keccak256(abi.encode(rng)));

            vm.roll(block.number + 1 + (rng % 3));

            if (uint32(block.number) >= m) break;

            int256 size = int256(1e15 + (rng % 4e16));

            _swapTracked(-size, (rng >> 8) % 2 == 0, _hookData());
        }

        vm.roll(uint256(m) + 2);

        _swapTracked(NUDGE, true, "");

        Settled memory got = _settle(bondId);

        _assertMatchesReference(bondId, openBlock, got, "fuzz");
    }
}
