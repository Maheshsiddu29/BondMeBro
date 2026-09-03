// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AdversarialBase} from "./AdversarialBase.sol";
import {BondMeBro} from "../../src/BondMeBro.sol";
import {ModelL2Reference} from "../utils/ModelL2Reference.sol";

/// @title AdvSettlementTest
///
/// @notice P-L2-8 settlement attacks: checkpoint timing, post-maturity manipulation, caller
///         privilege, double settlement, batch boundaries, shared-currency solvency and multi-pool
///         isolation.
///
/// @dev THE SHARPEST TEST IN THIS FILE is § 19. Settlement is permissionless, so an attacker who
///      could move the answer AFTER maturity would be choosing their own charge by choosing when to
///      settle. Everything else here is accounting hygiene; that one is the mechanism's spine.
contract AdvSettlementTest is AdversarialBase {
    using StateLibrary for IPoolManager;

    /// @dev A second pool on the SAME hook sharing BOTH currencies. The shared-currency solvency
    ///      failure mode only exists when one ERC-20 balance backs two pools' liabilities.
    PoolKey internal keyB;
    PoolId internal idB;

    function setUp() public {
        _deployAndOpenPool();

        (keyB, idB) = initPool(currency0, currency1, IHooks(address(hook)), 500, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(2))
            }),
            ""
        );

        hook.setPoolConfig(keyB, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);
    }

    /*//////////////////////////////////////////////////////////////
                18  CHECKPOINT ADVERSARIAL TIMING
    //////////////////////////////////////////////////////////////*/

    /// @notice Every endpoint boundary, exactly: C6, C6+1, C8, C8+1, C10, C10+1.
    ///
    /// @dev The off-by-one sweep. Freezing is inclusive at the endpoint block and exclusive below
    ///      it, so activity at `e - 1` must leave `e` open and activity at `e` must close it. A
    ///      scheduler off by one in either direction fails at the first boundary it crosses.
    function test_adv18_everyEndpointBoundaryExactly() public {
        (, uint32 open, uint32 m) = _open(BONDED, true);

        uint8 c6 = hook.FROZEN_C6();
        uint8 c8 = hook.FROZEN_C8();
        uint8 c10 = hook.FROZEN_C10();

        _nudgeAt(open + 5);
        assertEq(_mask(m), 0, "C6 froze one block early");

        _nudgeAt(open + 6);
        assertEq(_mask(m), c6, "C6 did not freeze at its own block");

        _nudgeAt(open + 7);
        assertEq(_mask(m), c6, "C8 froze one block early");

        _nudgeAt(open + 8);
        assertEq(_mask(m), c6 | c8, "C8 did not freeze at its own block");

        _nudgeAt(m - 1);
        assertEq(_mask(m), c6 | c8, "C10 froze one block early");

        _nudgeAt(m);
        assertEq(_mask(m), hook.FROZEN_ALL(), "C10 did not freeze at M");

        _nudgeAt(m + 1);
        assertEq(_mask(m), hook.FROZEN_ALL(), "the mask changed after M");

        _assertEndpointsExact(m, open, "boundary sweep");
    }

    /// @notice One advancement crossing all three, a fully quiet window, and a vast quiet gap.
    function test_adv18_singleAdvancementQuietAndVastGap() public {
        // ONE ADVANCEMENT past everything.
        uint256 snap = vm.snapshotState();

        (, uint32 openA, uint32 mA) = _open(BONDED, true);

        _nudgeAt(mA);

        assertEq(_mask(mA), hook.FROZEN_ALL(), "one advancement did not freeze all three");
        _assertEndpointsExact(mA, openA, "single advancement");

        vm.revertToState(snap);

        // A VAST QUIET GAP: nothing at all until long past maturity.
        (bytes32 bondB, uint32 openB, uint32 mB) = _open(BONDED, true);

        vm.roll(uint256(mB) + 250_000);

        assertEq(_mask(mB), 0, "a silent pool froze something");

        // Settlement derives all three exactly, and freezes what it derived.
        (int56 c6, int56 c8, int56 c10) = hook.resolveEndpoints(bondB, id_, mB);

        assertEq(c6, _refCum(openB + 6), "quiet C6 wrong after a vast gap");
        assertEq(c8, _refCum(openB + 8), "quiet C8 wrong after a vast gap");
        assertEq(c10, _refCum(mB), "quiet C10 wrong after a vast gap");

        assertEq(_mask(mB), hook.FROZEN_ALL(), "resolution did not freeze what it derived");
    }

    /// @notice Overlapping maturities, same-maturity fan-in, and no cross-contamination.
    ///
    /// @dev Ten consecutive opening blocks with four bonds each: thirty endpoints across ten
    ///      buckets, all frozen by ONE later swap, each against its own independent reference.
    ///      A stale-reuse or future-contamination bug shows as one bucket carrying another's value.
    function test_adv18_overlappingMaturitiesAndFanIn() public {
        uint32 obs = hook.OBSERVATION_BLOCKS();
        uint32 firstOpen = uint32(block.number);

        for (uint32 i = 0; i < obs; i++) {
            for (uint32 j = 0; j < 4; j++) {
                _swapT(BONDED, true, _hookData());
            }

            vm.roll(block.number + 1);
        }

        // ONE flush past every outstanding maturity.
        vm.roll(uint256(firstOpen) + obs + 60);

        _swapT(NUDGE, true, "");

        for (uint32 i = 0; i < obs; i++) {
            uint32 open = firstOpen + i;
            uint32 m = open + obs;

            (,,, uint32 pending, uint8 mask) = hook.maturity(id_, m);

            assertEq(pending, 4, "a bucket lost part of its fan-in");
            assertEq(mask, hook.FROZEN_ALL(), "a bucket was not fully frozen by the single flush");

            _assertEndpointsExact(m, open, string.concat("overlap bucket ", vm.toString(uint256(i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
             19  POST-MATURITY MANIPULATION — THE SPINE
    //////////////////////////////////////////////////////////////*/

    /// @notice After C10 freezes, NOTHING an attacker does can change the settlement.
    ///
    /// @dev THE MOST IMPORTANT TEST IN THIS FILE. Settlement is permissionless and its timing is
    ///      adversarially chosen, so if post-maturity flow could move the answer, whoever picked
    ///      the block would be picking their own charge.
    ///
    ///      The baseline is settled immediately at M+1. Every other arm applies a different
    ///      post-maturity assault — huge same-direction pushes, huge reversals, many alternating
    ///      swaps, activity on a SECOND pool, and a 250,000-block wait — and every one must produce
    ///      a bit-identical refund and slash.
    function test_adv19_postMaturityManipulationCannotMoveTheAnswer() public {
        uint256 baseline = vm.snapshotState();

        (uint256 refund0, uint256 slash0) = _openMatureAndSettle(0);

        assertGt(slash0, 0, "the baseline produced no slash; invariance would be vacuous");

        vm.revertToState(baseline);

        for (uint256 mode = 1; mode <= 5; mode++) {
            (uint256 refund, uint256 slash) = _openMatureAndSettle(mode);

            assertEq(slash, slash0, string.concat("post-maturity mode ", vm.toString(mode), " changed the SLASH"));

            assertEq(refund, refund0, string.concat("post-maturity mode ", vm.toString(mode), " changed the REFUND"));

            vm.revertToState(baseline);
        }

        console2.log("POST-MATURITY baseline refund", refund0);
        console2.log("POST-MATURITY baseline slash ", slash0);
    }

    /// @dev Opens a bond, matures it, applies post-maturity assault `mode`, then settles.
    function _openMatureAndSettle(uint256 mode) internal returns (uint256 refund, uint256 slash) {
        (bytes32 bondId,, uint32 m) = _open(BONDED, true);

        _nudgeAt(m + 1);

        // C10 is frozen from here on. Nothing below may change the outcome.
        assertEq(_mask(m), hook.FROZEN_ALL(), "the bond did not fully freeze before the assault");

        if (mode == 1) {
            // A huge push in the SAME direction.
            _swapT(BONDED * 40, true, _hookData());
        } else if (mode == 2) {
            // A huge REVERSAL, far past the original price.
            _swapT(BONDED * 40, false, _hookData());
        } else if (mode == 3) {
            // Many alternating swaps over many blocks.
            for (uint256 i = 0; i < 8; i++) {
                vm.roll(block.number + 2);
                _swapT(BONDED * 5, i % 2 == 0, _hookData());
            }
        } else if (mode == 4) {
            // Activity on a DIFFERENT pool sharing both currencies.
            for (uint256 i = 0; i < 4; i++) {
                vm.roll(block.number + 2);
                _swapOn(keyB, BONDED * 8, i % 2 == 0, _hookData());
            }
        } else if (mode == 5) {
            // A very long wait, then more activity.
            vm.roll(block.number + 250_000);
            _swapT(BONDED * 20, true, _hookData());
        }

        Settled memory got = _settle(bondId);

        return (got.refund, got.slash);
    }

    /*//////////////////////////////////////////////////////////////
                20-21  CALLER PRIVILEGE AND DOUBLE SPEND
    //////////////////////////////////////////////////////////////*/

    /// @notice Settlement is caller-agnostic: four different callers, identical result.
    ///
    /// @dev No privilege, and no caller-dependent economics. A settler cannot pay themselves, and
    ///      the refund always goes to the recipient bound in `hookData` at open.
    function test_adv20_settlementIsCallerAgnostic() public {
        address[4] memory callers = [address(this), TRADER, ATTACKER, BYSTANDER];

        uint256 baseline = vm.snapshotState();

        uint256 refund0;
        uint256 slash0;

        for (uint256 i = 0; i < callers.length; i++) {
            (bytes32 bondId,, uint32 m) = _open(BONDED, true);

            _nudgeAt(m + 1);

            BondMeBro.Bond memory b = hook.getBond(bondId);
            Currency c = b.collateralIsCurrency0 ? currency0 : currency1;

            uint256 recipientBefore = c.balanceOf(b.refundRecipient);
            uint256 potBefore = hook.insurancePot(id_, c);
            uint256 callerBefore = c.balanceOf(callers[i]);

            vm.prank(callers[i]);
            hook.settleBond(bondId);

            uint256 refund = c.balanceOf(b.refundRecipient) - recipientBefore;
            uint256 slash = hook.insurancePot(id_, c) - potBefore;

            if (i == 0) {
                refund0 = refund;
                slash0 = slash;

                assertGt(slash0, 0, "the baseline produced no slash");
            } else {
                assertEq(refund, refund0, "the refund depended on who called settleBond");
                assertEq(slash, slash0, "the slash depended on who called settleBond");
            }

            // The caller received nothing for calling, unless they ARE the recipient.
            if (callers[i] != b.refundRecipient) {
                assertEq(c.balanceOf(callers[i]), callerBefore, "the settler was paid for settling");
            }

            vm.revertToState(baseline);
        }
    }

    /// @notice Double settlement is impossible in all three shapes, and nothing moves on the retry.
    ///
    /// @dev The three ways to try: twice via `settleBond`, twice inside one `settleMany`, and once
    ///      each way. All must revert on the second attempt with the SETTLED state named, and the
    ///      pot, the recipient's balance and `pendingBonds` must be untouched by the failed attempt.
    function test_adv21_doubleSettlementIsImpossibleInEveryShape() public {
        // SHAPE 1 -- settleBond twice.
        uint256 snap = vm.snapshotState();

        (bytes32 bondId,, uint32 m) = _open(BONDED, true);
        _nudgeAt(m + 1);

        Settled memory first = _settle(bondId);

        assertGt(first.collateral, 0, "nothing was settled the first time");

        uint256 potAfter = hook.insurancePot(id_, first.currency);
        uint256 recipientAfter = first.currency.balanceOf(TRADER);
        (,,, uint32 pendingAfter,) = hook.maturity(id_, m);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotSettleable.selector, bondId, uint8(3)));
        hook.settleBond(bondId);

        assertEq(hook.insurancePot(id_, first.currency), potAfter, "a rejected re-settle credited the pot");
        assertEq(first.currency.balanceOf(TRADER), recipientAfter, "a rejected re-settle paid a second refund");

        (,,, uint32 pendingNow,) = hook.maturity(id_, m);
        assertEq(pendingNow, pendingAfter, "a rejected re-settle moved pendingBonds");

        vm.revertToState(snap);

        // SHAPE 2 -- the same id twice inside one batch. The batch must revert atomically.
        (bytes32 dupId,, uint32 m2) = _open(BONDED, true);
        _nudgeAt(m2 + 1);

        bytes32[] memory dup = new bytes32[](2);
        dup[0] = dupId;
        dup[1] = dupId;

        uint256 potBefore2 = hook.insurancePot(id_, currency1);

        vm.expectRevert();
        hook.settleMany(dup);

        assertEq(hook.insurancePot(id_, currency1), potBefore2, "a reverted duplicate batch credited the pot");
        assertEq(uint8(hook.getBond(dupId).state), 2, "a reverted batch settled the bond anyway");

        vm.revertToState(snap);

        // SHAPE 3 -- settleBond, then a batch containing the same id.
        (bytes32 mixId,, uint32 m3) = _open(BONDED, true);
        _nudgeAt(m3 + 1);

        hook.settleBond(mixId);

        bytes32[] memory mixed = new bytes32[](1);
        mixed[0] = mixId;

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotSettleable.selector, mixId, uint8(3)));
        hook.settleMany(mixed);
    }

    /// @notice `pendingBonds` cannot be driven below zero by any settlement sequence.
    function test_adv21_pendingBondsCannotUnderflow() public {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](3);

        for (uint32 i = 0; i < 3; i++) {
            ids[i] = _bondIdAt(m, i);
            _swapT(BONDED, true, _hookData());
        }

        _nudgeAt(m + 1);

        for (uint32 i = 0; i < 3; i++) {
            hook.settleBond(ids[i]);

            (,,, uint32 pending,) = hook.maturity(id_, m);

            assertEq(pending, 3 - i - 1, "pendingBonds did not decrement by exactly one");
        }

        // Every further attempt reverts; the counter stays at zero.
        for (uint32 i = 0; i < 3; i++) {
            vm.expectRevert();
            hook.settleBond(ids[i]);
        }

        (,,, uint32 finalPending,) = hook.maturity(id_, m);

        assertEq(finalPending, 0, "pendingBonds underflowed or drifted");
    }

    /*//////////////////////////////////////////////////////////////
                       22  BATCH BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Batch sizes 0, 1, 2, 10, 31, 32 succeed; 33 is rejected at the cap.
    ///
    /// @dev `MAX_SETTLE_BATCH` is a real bound, not advice: without it a caller could submit an
    ///      array long enough to exceed the block limit, and the failure would be an out-of-gas
    ///      rather than a diagnosable revert.
    function test_adv22_batchSizeBoundariesIncludingTheCap() public {
        uint256[6] memory sizes = [uint256(0), 1, 2, 10, 31, 32];

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();

            _settleBatchOfSize(sizes[i]);

            vm.revertToState(snap);
        }

        // 33 exceeds the cap and must be rejected by name.
        uint256 snap2 = vm.snapshotState();

        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](33);

        for (uint32 i = 0; i < 33; i++) {
            ids[i] = _bondIdAt(m, i);
            _swapT(BONDED, true, _hookData());
        }

        _nudgeAt(m + 1);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.SettleBatchTooLarge.selector, uint256(33), uint256(32)));
        hook.settleMany(ids);

        vm.revertToState(snap2);
    }

    function _settleBatchOfSize(uint256 n) internal {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](n);

        for (uint32 i = 0; i < n; i++) {
            ids[i] = _bondIdAt(m, i);
            _swapT(BONDED, true, _hookData());
        }

        if (n > 0) _nudgeAt(m + 1);

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += hook.collateralAmountOf(ids[i]);
        }

        Currency c = n > 0 ? (hook.getBond(ids[0]).collateralIsCurrency0 ? currency0 : currency1) : currency1;

        uint256 recipientBefore = c.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(id_, c);

        hook.settleMany(ids);

        uint256 moved = (c.balanceOf(TRADER) - recipientBefore) + (hook.insurancePot(id_, c) - potBefore);

        assertEq(moved, total, string.concat("batch of ", vm.toString(n), " did not conserve"));

        for (uint256 i = 0; i < n; i++) {
            assertEq(uint8(hook.getBond(ids[i]).state), 3, "a batched bond is not SETTLED");
        }
    }

    /// @notice A batch containing one invalid entry reverts atomically — documented, not redesigned.
    ///
    /// @dev `settleMany` is all-or-nothing. That is the current contract semantics and this pins it
    ///      rather than changing it: a partially applied batch would leave the caller unable to
    ///      tell which entries succeeded without parsing logs.
    function test_adv22_batchIsAtomicOnOneBadEntry() public {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](3);

        for (uint32 i = 0; i < 2; i++) {
            ids[i] = _bondIdAt(m, i);
            _swapT(BONDED, true, _hookData());
        }

        // A third id that was never created.
        ids[2] = keccak256("no such bond");

        _nudgeAt(m + 1);

        uint256 potBefore = hook.insurancePot(id_, currency1);

        vm.expectRevert();
        hook.settleMany(ids);

        assertEq(hook.insurancePot(id_, currency1), potBefore, "a reverted batch still credited the pot");

        for (uint32 i = 0; i < 2; i++) {
            assertEq(uint8(hook.getBond(ids[i]).state), 2, "a reverted batch settled a valid entry anyway");
        }
    }

    /*//////////////////////////////////////////////////////////////
              23-24  SOLVENCY AND MULTI-POOL ISOLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice AGGREGATE solvency holds after every step of a mixed two-pool sequence.
    ///
    /// @dev PER-POOL SOLVENCY IS UNSOUND AND IS NOT USED. The hook holds ONE balance per ERC-20
    ///      while liabilities are keyed per pool, so `holds 100; pool A owes 80; pool B owes 80`
    ///      passes a per-pool check twice while insolvent.
    ///
    ///      The collateral currency is READ FROM EACH BOND RECORD, never inferred from direction:
    ///      under variable-leg custody the direction alone gives the wrong answer for half of all
    ///      bonds, because the swap KIND also decides.
    function test_adv23_aggregateSolvencyAcrossTwoPoolsAndAllFourModes() public {
        bytes32[] memory ids = new bytes32[](8);
        PoolId[] memory pools = new PoolId[](8);

        uint256 n;

        // Four modes on each pool, interleaved, with solvency checked after every single step.
        for (uint256 i = 0; i < 4; i++) {
            bool exactInput = i < 2;
            bool zeroForOne = (i % 2) == 0;

            int256 amount = exactInput ? BONDED : -BONDED;

            uint32 mA = _maturityOfNow();
            (,,, uint32 pendingA,) = hook.maturity(id_, mA);
            _swapT(amount, zeroForOne, _hookData());
            ids[n] = _bondIdAt(mA, pendingA);
            pools[n] = id_;
            n++;

            _assertAggregateSolvency(ids, n, pools, "after pool A mode");

            uint32 mB = uint32(block.number) + hook.OBSERVATION_BLOCKS();
            (,,, uint32 pendingB,) = hook.maturity(idB, mB);
            _swapOn(keyB, amount, zeroForOne, _hookData());
            ids[n] = keccak256(abi.encode(idB, mB, pendingB));
            pools[n] = idB;
            n++;

            _assertAggregateSolvency(ids, n, pools, "after pool B mode");

            vm.roll(block.number + 1);
        }

        // Mature everything, then settle in a mixed order, checking solvency after each.
        vm.roll(block.number + hook.OBSERVATION_BLOCKS() + 2);

        _swapT(NUDGE, true, "");
        _swapOn(keyB, NUDGE, true, "");

        uint256 settled;

        for (uint256 i = 0; i < n; i++) {
            if (!hook.bondExists(ids[i])) continue;

            hook.settleBond(ids[i]);
            settled++;

            _assertAggregateSolvency(ids, n, pools, "after a settlement");
        }

        assertGt(settled, 0, "nothing settled; the solvency sweep proves nothing");

        console2.log("SOLVENCY bonds created / settled", n, settled);
    }

    /// @dev Hook balance >= outstanding refundable collateral + realized pot, per CURRENCY, summed
    ///      across BOTH pools.
    function _assertAggregateSolvency(bytes32[] memory ids, uint256 n, PoolId[] memory pools, string memory label)
        internal
        view
    {
        for (uint256 cIdx = 0; cIdx < 2; cIdx++) {
            Currency c = cIdx == 0 ? currency0 : currency1;

            uint256 outstanding;

            for (uint256 i = 0; i < n; i++) {
                if (!hook.bondExists(ids[i])) continue;

                BondMeBro.Bond memory b = hook.getBond(ids[i]);

                if (uint8(b.state) != 2) continue;

                // THE CURRENCY COMES FROM THE RECORD.
                Currency bondCurrency = b.collateralIsCurrency0 ? currency0 : currency1;

                if (Currency.unwrap(bondCurrency) != Currency.unwrap(c)) continue;

                outstanding += hook.collateralAmountOf(ids[i]);
            }

            uint256 pots = hook.insurancePot(id_, c) + hook.insurancePot(idB, c);

            assertGe(
                c.balanceOf(address(hook)),
                outstanding + pots,
                string.concat(label, ": AGGREGATE INSOLVENCY in a shared currency")
            );

            pools;
        }
    }

    /// @notice Manipulating and settling pool A leaves pool B's state untouched.
    ///
    /// @dev State isolation, field by field. The two pools share both ERC-20s, so their physical
    ///      token balances are legitimately shared — everything else must be independent.
    function test_adv24_multiPoolStateIsolation() public {
        uint32 m = _maturityOfNow();

        bytes32 bondA = _bondIdAt(m, 0);
        bytes32 bondB = keccak256(abi.encode(idB, m, uint32(0)));

        _swapT(BONDED, true, _hookData());
        _swapOn(keyB, BONDED, true, _hookData());

        bytes32 snapshotB = _poolBSnapshot(m, bondB);

        // Hammer and fully settle pool A.
        _nudgeAt(m + 1);

        for (uint256 i = 0; i < 6; i++) {
            vm.roll(block.number + 2);
            _swapT(BONDED * 6, i % 2 == 0, _hookData());
        }

        hook.settleBond(bondA);

        assertEq(_poolBSnapshot(m, bondB), snapshotB, "pool A's activity and settlement changed pool B's state");

        // And pool B still settles correctly afterwards.
        vm.roll(block.number + 1);
        _swapOn(keyB, NUDGE, true, "");

        uint128 collateralB = hook.collateralAmountOf(bondB);

        Currency cB = hook.getBond(bondB).collateralIsCurrency0 ? currency0 : currency1;

        uint256 recipientBefore = cB.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(idB, cB);

        hook.settleBond(bondB);

        assertEq(
            (cB.balanceOf(TRADER) - recipientBefore) + (hook.insurancePot(idB, cB) - potBefore),
            uint256(collateralB),
            "pool B did not conserve after pool A's activity"
        );
    }

    /// @dev Every piece of pool B's state that pool A must not be able to touch, hashed into one
    ///      value.
    ///
    ///      Hashed rather than compared field by field for two reasons: it keeps the frame inside
    ///      the EVM stack limit, and it means a field ADDED to the struct later is covered
    ///      automatically instead of being silently omitted from a hand-written comparison.
    ///
    ///      Physical token balances are deliberately excluded — the two pools share both ERC-20s,
    ///      so those are legitimately common.
    function _poolBSnapshot(uint32 m, bytes32 bondB) internal view returns (bytes32) {
        (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = hook.maturity(idB, m);

        BondMeBro.Bond memory b = hook.getBond(bondB);

        // slither-disable-next-line unused-return
        (int24 tick, uint32 lastUpdate,, int56 cumulative) = hook.accumulator(idB);

        return keccak256(
            abi.encode(
                c6,
                c8,
                c10,
                pending,
                mask,
                b,
                tick,
                lastUpdate,
                cumulative,
                hook.insurancePot(idB, currency0),
                hook.insurancePot(idB, currency1)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mask(uint32 m) internal view returns (uint8 mask) {
        (,,,, mask) = hook.maturity(id_, m);
    }

    /// @dev The independently integrated cumulative at a block, from the observed tick path.
    function _refCum(uint32 atBlock) internal view returns (int56) {
        int256 running;

        uint32 start = refPoints[0].blockNumber;

        for (uint32 b = start; b < atBlock; b++) {
            running += int256(_tickDuring(b));
        }

        return int56(running);
    }

    function _assertEndpointsExact(uint32 m, uint32 open, string memory label) internal view {
        (int56 c6, int56 c8, int56 c10,,) = hook.maturity(id_, m);

        assertEq(c6, _refCum(open + 6), string.concat(label, ": C6 does not match the reference"));
        assertEq(c8, _refCum(open + 8), string.concat(label, ": C8 does not match the reference"));
        assertEq(c10, _refCum(m), string.concat(label, ": C10 does not match the reference"));
    }
}
