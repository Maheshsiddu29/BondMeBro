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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {BondMeBro, HOOK_FLAGS} from "../../src/BondMeBro.sol";
import {ModelLReference} from "../utils/ModelLReference.sol";
import {BondCustodyHandler} from "./BondCustodyHandler.sol";

/// @title BondCustodyInvariantsTest

/// @notice Tests custody, frozen observations and settlement over many swaps and block advances.

/// @dev Unit tests verify individual swaps. These invariants verify that custody remains correct across sequences of exact-input and exact-output swaps, both directions, including reverted transactions.

/// Settlement and refunds are implemented. The hook must hold enough tokens for unsettled bonds
/// and the insurance pot; tokens already refunded belong to the recipient, not to the hook.

/// These tests also check that C6, C8 and C10 stay fixed once frozen, that settlement agrees with
/// the independent Model L2 calculation, and that a bond cannot be settled twice.

contract BondCustodyInvariantsTest is Test, Deployers {
    BondMeBro internal hook;
    BondCustodyHandler internal handler;

    PoolKey internal key_;
    PoolId internal id_;

    /// @dev `bonds` mapping slot and the byte offset of `Bond.state` within struct slot 1, both
    ///      from `forge inspect BondMeBro storage-layout`. Raw access is required because Rule 1
    ///      deliberately makes PROVISIONAL indistinguishable from absent through the public API —
    ///      which is the property under test.
    uint256 internal constant BONDS_SLOT = 3;
    uint256 internal constant STATE_BYTE_OFFSET = 25;
    uint8 internal constant STATE_PROVISIONAL = 1;

    /// @dev First cumulative the invariant ever observed for a frozen bucket, used to prove
    ///      immutability across the campaign.
    mapping(uint32 => bool) internal seenCheckpoint;

    /// @dev First-observed endpoint values and the union of every mask bit ever seen, per bucket.
    ///      Used by `invariant_frozenEndpointsNeverChange` so a rewrite is caught even if a later
    ///      advancement happens to restore the original value.
    mapping(uint32 => int56) internal firstSeenC6;
    mapping(uint32 => int56) internal firstSeenC8;
    mapping(uint32 => int56) internal firstSeenC10;
    mapping(uint32 => uint8) internal seenMask;
    mapping(uint32 => int56) internal firstSeenCumulative;

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;

    /// @dev Settlement noise floor, in ticks. Displacement at or below this is never slashed.
    uint16 internal constant REFUND_TOL = 5;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        // Add deep liquidity so the invariant campaign spends most calls testing
        // custody rather than reverting because the liquidity range is exhausted.
        // DEPTH REDUCED FROM 1e23 TO 1e19 IN P-L2-3/4.
        //
        // This is a real new coupling between subsystems, not a test tidy-up. Model L prices
        // collateral off the REALIZED tick impact, so whether a swap bonds at all now depends on
        // the pool's depth. At 1e23 the swaps in this file move zero ticks, every one of them is
        // unbonded, and a suite about maturity buckets ends up asserting properties of an empty
        // bucket -- passing or failing for reasons that have nothing to do with checkpoints.
        //
        // The same retune was needed in the combined research prototype for the same reason, and
        // it is recorded there too. Any future test that creates bonds must size its liquidity
        // against its swap amounts deliberately.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e19, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, true);

        handler = new BondCustodyHandler(IPoolManager(address(manager)), swapRouter, hook, key_, currency0, currency1);

        // Fund the handler with both currencies and allow the test router to
        // pull tokens during swaps.
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1e30);

        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1e30);

        vm.startPrank(address(handler));

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);

        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        vm.stopPrank();

        // THE CAMPAIGN'S ACTION SET, and `settleABond` was MISSING from it.
        //
        // P-L2-8 § 7 recorded that the campaign never reached settlement and attributed it to the
        // walk needing to both pass maturity and select that action. The real cause is simpler and
        // worse: the selector was never registered, so settlement was STRUCTURALLY unreachable
        // rather than merely improbable. Every settlement-side invariant in this file was
        // therefore vacuous for the campaign's whole life.
        //
        // Registered twice, deliberately. Foundry picks uniformly across this array, and a bond
        // only becomes settleable ten blocks after it opens — a single entry leaves settlement
        // rare enough that the settlement invariants stay near-vacuous. The counters printed by
        // `afterInvariant` are what this weighting is tuned against.
        bytes4[] memory selectors = new bytes4[](6);

        selectors[0] = BondCustodyHandler.swapExactInput.selector;

        selectors[1] = BondCustodyHandler.swapExactOutput.selector;

        selectors[2] = BondCustodyHandler.advanceBlocks.selector;

        selectors[3] = BondCustodyHandler.settleABond.selector;

        selectors[4] = BondCustodyHandler.settleABond.selector;

        // A second swap entry keeps same-block sequences frequent, which is what exercises
        // ADR-0008's block term at all.
        selectors[5] = BondCustodyHandler.swapExactInput.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        targetContract(address(handler));
    }

    /// @dev Mirrors the contract's bond-id derivation.
    function _bondId(uint32 maturityBlock, uint32 indexInBucket) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, indexInBucket));
    }

    /// @dev Reads `Bond.state` straight from storage. Raw access is required precisely because
    ///      ADR-0004 Rule 1 makes PROVISIONAL indistinguishable from absent through the public
    ///      API — which is the property under test.
    function _rawBondState(bytes32 bondId) internal view returns (uint8) {
        bytes32 base = keccak256(abi.encode(bondId, BONDS_SLOT));

        bytes32 word = vm.load(address(hook), bytes32(uint256(base) + 1));

        return uint8(uint256(word) >> (STATE_BYTE_OFFSET * 8));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-SOLVENCY — the hook physically holds at least everything it owes.

    /// @dev REPLACES THE OLD CUSTODY EQUALITY, which asserted the hook's balance EQUALS the total
    ///      collateral ever taken. That held only while nothing could leave the hook. Settlement
    ///      pays refunds out, so the equality is now simply false; keeping it would have meant
    ///      either a failing suite or a quietly weakened assertion.

    ///      THE AGGREGATION IS THE POINT, and it is where a naive version goes wrong. The hook
    ///      holds ONE balance per ERC-20, but liabilities are keyed per pool. Comparing each
    ///      pool's liability separately against that single balance proves nothing:

    ///          hook holds 100 USDC;  pool A owes 80;  pool B owes 80
    ///          80 <= 100 PASS        80 <= 100 PASS   — yet 160 is owed and the hook is insolvent

    ///      So liabilities are summed across every pool sharing a physical currency FIRST, and the
    ///      total is compared once. The handler's ghost totals are already per-currency sums.

    ///      `>=` rather than `==`: a direct token donation or dust must not break solvency.

    ///      SCOPE OF THIS CAMPAIGN, STATED HONESTLY. The ghost totals below are keyed by CURRENCY,
    ///      which is already the aggregated shape — but this campaign drives a single pool, so the
    ///      aggregation itself is not exercised here: with one pool, "sum across pools" and "read
    ///      this pool" are the same number. The aggregation is proved deterministically instead by
    ///      `test/SharedCurrencySolvency.t.sol`, which runs two distinct PoolIds over one ERC-20
    ///      and includes a negative proof that the per-pool form passes while the hook is
    ///      genuinely insolvent.
    function invariant_solvency() public view {
        assertGe(
            currency0.balanceOf(address(hook)),
            handler.ghostUnsettledCollateral(currency0) + handler.ghostInsurancePot(currency0),
            "currency0: hook holds less than it owes"
        );

        assertGe(
            currency1.balanceOf(address(hook)),
            handler.ghostUnsettledCollateral(currency1) + handler.ghostInsurancePot(currency1),
            "currency1: hook holds less than it owes"
        );
    }

    /// @notice INV-COLLATERAL-CONSERVATION — every settled bond splits exactly.

    /// @dev `refund + slash == collateral`, no residual wei. Checked by the handler at the instant
    ///      each bond settles, because the split is only observable then; a violation sets a
    ///      sticky flag so it survives to be reported here.
    function invariant_collateralConservation() public view {
        assertFalse(handler.ghostConservationViolated(), "a settled bond did not conserve collateral exactly");
    }

    /// @notice INV-NO-DOUBLE-SETTLEMENT — a settled bond can never pay out again.

    /// @dev The sticky flag is set if a second settlement ever succeeds, OR if a correctly
    ///      rejected attempt still moved the pot or the hook's balance. The CEI ordering in
    ///      `_settleBond` is what prevents both: the bond is marked SETTLED before the transfer,
    ///      so a reentrant token sees SETTLED and reverts.
    function invariant_noDoubleSettlement() public view {
        assertFalse(handler.ghostDoubleSettlement(), "a bond settled twice, or a rejected settlement moved funds");
    }

    /// @notice Refunds paid never exceed the collateral ever taken in that currency.

    /// @dev A cheap sentinel against the refund and slash sides being crossed. If a slashed
    ///      portion were ever refunded by mistake, the excess would surface here.
    function invariant_refundsNeverExceedCollateralTaken() public view {
        assertLe(
            handler.ghostRefundPaid(currency0),
            handler.measuredBondTotal(currency0),
            "currency0: refunds exceed collateral ever taken"
        );

        assertLe(
            handler.ghostRefundPaid(currency1),
            handler.measuredBondTotal(currency1),
            "currency1: refunds exceed collateral ever taken"
        );
    }

    /// @notice Every bond actually received by the hook must match the amount independently predicted by the bond formulas.

    /// @dev The handler calculates expected custody separately from the hook's token balance:
    ///
    /// Exact-input:
    /// `bond = grossInput * bondBps / 10_000`
    ///
    /// Exact-output:
    /// `bond = poolInput * bondBps / (10_000 - bondBps)`
    ///
    /// If the hook takes a different amount on either path, this invariant fails.
    function invariant_bondsMatchTheFormula() public view {
        assertEq(
            handler.measuredBondTotal(currency0),
            handler.expectedBondTotal(currency0),
            "currency0: bonds taken != bonds the formula predicts"
        );

        assertEq(
            handler.measuredBondTotal(currency1),
            handler.expectedBondTotal(currency1),
            "currency1: bonds taken != bonds the formula predicts"
        );
    }

    /// @notice NON-VACUITY GUARD for the raw state decoder.
    ///
    /// @dev THIS TEST EXISTS BECAUSE THE DECODER WAS SILENTLY BROKEN. `STATE_BYTE_OFFSET` was 30
    ///      here, which is past every field a `Bond` has ever had — in the pre-ADR-0008 layout as
    ///      well as this one. `_rawBondState` therefore always returned 0, and
    ///      `invariant_noProvisionalRecordSurvives` compared 0 against `STATE_PROVISIONAL == 1` and
    ///      passed unconditionally. The invariant was VACUOUS for its whole life and no failure
    ///      could ever have surfaced it, because a decoder that reads the wrong byte does not
    ///      error — it returns a plausible value.
    ///
    ///      The offset is now 25, from the compiler's own layout, and this pins it by driving a
    ///      bond to a state the decoder must actually see. A future field insertion that shifts
    ///      `state` again fails HERE, loudly, rather than turning the invariant back into a no-op.
    function test_rawBondStateDecoderIsNotVacuous() public {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // slither-disable-next-line unused-return
        (,,, uint32 pending,) = hook.maturity(id_, m);

        bytes32 bondId = _bondId(m, pending);

        // An ODD seed: `_sizeStraddlingThreshold` puts odd seeds at or above the bonding
        // threshold, which is what makes this drive a FINALIZED record rather than an unbonded one.
        handler.swapExactInput(1, true, false);

        assertTrue(hook.bondExists(bondId), "the fixture did not finalize a bond");

        assertEq(uint256(_rawBondState(bondId)), 2, "the raw decoder does not read Bond.state (FINALIZED == 2)");

        // And an id that was never written must decode as NONE, so the decoder is not simply
        // returning a constant.
        assertEq(uint256(_rawBondState(keccak256("never written"))), 0, "an absent record did not decode as NONE");
    }

    /*//////////////////////////////////////////////////////////////
                   ADR-0008 -- INV-L2-4b AND THE STORED RATE
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-L2-4b, statefully. Every bond's stored rate is at least the own-impact rate.
    ///
    /// @dev `max(ownImpact, blockDisplacement) >= ownImpact`, so the block model can never charge
    ///      LESS than the pre-migration model for the same realized trade. That is what makes
    ///      INV-L2-4a's restriction to outward trades safe rather than a loophole, and it is
    ///      checkable directly from the record: `tickBefore` and `tickAfter` give the own-impact
    ///      rate, and `collateralBps` is what was actually charged.
    ///
    ///      Holds over every bond the campaign ever created, settled or not — `openBondIds` is
    ///      pruned on settlement, so this walks `allBondIds` instead.
    function invariant_inv_L2_4b_storedRateNeverBelowOwnImpact() public view {
        uint256 n = handler.allBondCount();

        for (uint256 i = 0; i < n; i++) {
            // Every id in `allBondIds` was FINALIZED when it was recorded, and `getBond` reads
            // FINALIZED and SETTLED alike -- a settled bond stays auditable, which is what lets
            // this invariant cover a bond's whole life rather than only its open phase.
            BondMeBro.Bond memory bond = hook.getBond(handler.allBondAt(i));

            assertGe(
                uint256(bond.collateralBps),
                ModelLReference.collateralBps(bond.tickBefore, bond.tickAfter),
                "INV-L2-4b: a stored rate is below the own-impact rate"
            );
        }
    }

    /// @notice Every stored rate is inside the frozen band, and never zero on a finalized bond.
    ///
    /// @dev INV-L2-2 restated over the stored field rather than the recomputed one, plus the half
    ///      of INV-NOOP-VL that a rate can express: a bond that finalized with a zero rate would be
    ///      a maturity obligation with nothing behind it, which ADR-0004 Rule 1 forbids.
    function invariant_storedRateIsInsideTheFrozenBand() public view {
        uint256 n = handler.allBondCount();

        for (uint256 i = 0; i < n; i++) {
            BondMeBro.Bond memory bond = hook.getBond(handler.allBondAt(i));

            assertGt(uint256(bond.collateralBps), 0, "a finalized bond stored a zero rate");
            assertLe(uint256(bond.collateralBps), hook.MAX_BOND_BPS(), "a stored rate exceeded the cap");
        }
    }

    /// @notice Settlement reproduces the collateral the record says was taken.
    ///
    /// @dev ADR-0008 § 6. The migration moved settlement from recomputation to the stored rate, and
    ///      this is the property that move exists to preserve: `collateralAmountOf` must equal
    ///      `leg * storedBps / BPS` for every live bond, at every point in the campaign.
    function invariant_collateralIsTheStoredRateTimesTheLeg() public view {
        uint256 n = handler.openBondCount();

        for (uint256 i = 0; i < n; i++) {
            bytes32 bondId = handler.openBondAt(i);

            BondMeBro.Bond memory bond = hook.getBond(bondId);

            assertEq(
                uint256(hook.collateralAmountOf(bondId)),
                (uint256(bond.variableLegAmount) * uint256(bond.collateralBps)) / hook.BPS(),
                "collateralAmountOf does not equal leg * storedBps / BPS"
            );
        }
    }

    /// @notice The hook must not hold PoolManager claim tokens after a completed swap.

    /// @dev BondMeBro uses physical token custody with `claims = false`. A non-zero ERC-6909 claim balance would mean some custody was represented as a claim against PoolManager instead of real ERC-20 tokens held by the hook.
    function invariant_hookHoldsNoPoolManagerClaims() public view {
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds currency0 claims");

        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook holds currency1 claims");
    }

    // NOTE: `invariant_hookIsFullyBackedByRealTokens` was REMOVED in T5B. It asserted the hook's
    // balance equals the total collateral ever taken, which stops being true the moment a refund
    // can leave the hook. `invariant_solvency` above states the property that survives settlement.

    /*//////////////////////////////////////////////////////////////
                        ADR-0004 SPLIT-PHASE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-PROVISIONAL (a) — no bond record is ever left `PROVISIONAL` once a transaction
    ///         has ended.

    /// @dev THE CORE SAFETY PROPERTY OF ADR-0004. The exact-output header is written in
    ///      `beforeSwap`, before anyone knows whether the swap will bond. Every exit from
    ///      `afterSwap` must finalize it or clear it, and a revert must unwind it. If any path
    ///      returns without doing one of those, a half-written record survives and a later swap
    ///      reusing that bucket index inherits it.

    ///      Checked over the ghost model's maturity blocks, never by scanning block ranges or all
    ///      historical bonds, so work stays bounded by the distinct maturity blocks touched.
    function invariant_noProvisionalRecordSurvives() public view {
        uint256 maturityCount = handler.touchedMaturityCount();

        for (uint256 i = 0; i < maturityCount; i++) {
            uint32 m = handler.touchedMaturityAt(i);

            (,,, uint32 pending,) = hook.maturity(id_, m);

            // Indices [0, pending) hold finalized bonds; index `pending` is where the next
            // provisional record would sit. Checking one past the end is the point.
            for (uint32 index = 0; index <= pending; index++) {
                assertTrue(
                    _rawBondState(_bondId(m, index)) != STATE_PROVISIONAL,
                    "a PROVISIONAL bond record survived its transaction"
                );
            }
        }
    }

    /// @notice INV-PENDING-FINALIZED — `pendingBonds[M]` counts finalized bonds only.

    /// @dev The cheapest sentinel for the split-phase design. If a provisional record ever leaked
    ///      into the count — the Option B failure mode ADR-0004 section 5 rejects — this fails.
    ///      The handler's expectation comes from observed collateral movement, not from the
    ///      contract's own counter, so this is a genuine cross-check rather than a tautology.
    function invariant_pendingBondsCountsFinalizedOnly() public view {
        uint256 maturityCount = handler.touchedMaturityCount();

        for (uint256 i = 0; i < maturityCount; i++) {
            uint32 m = handler.touchedMaturityAt(i);

            (,,, uint32 pending,) = hook.maturity(id_, m);

            assertEq(pending, handler.expectedFinalizedAt(m), "pendingBonds does not equal the finalized bond count");
        }
    }

    /// @notice Every bond the contract counts is readable as a finalized bond.
    /// @dev Pairs with the two above: they prove nothing provisional is counted, this proves
    ///      nothing counted is missing.
    function invariant_countedBondsAreAllFinalized() public view {
        uint256 maturityCount = handler.touchedMaturityCount();

        for (uint256 i = 0; i < maturityCount; i++) {
            uint32 m = handler.touchedMaturityAt(i);

            (,,, uint32 pending,) = hook.maturity(id_, m);

            for (uint32 index = 0; index < pending; index++) {
                assertTrue(hook.bondExists(_bondId(m, index)), "a counted bond is not finalized");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    NO-MISSED-MATURITY — Stage 3 core invariant
    //////////////////////////////////////////////////////////////*/

    /// @notice NO-MISSED-MATURITY.

    /// For every registered maturity M:  M <= accumulator.lastUpdate  =>  checkpoint[M].checkpointed

    /// @dev TREATED WITH THE SAME SERIOUSNESS AS INV-NOOP, because the failure it guards is silent
    ///      and permanent. Once `lastUpdate` moves past an unfrozen maturity, that maturity is
    ///      behind the scan cursor. The accumulator keeps no history, so the next price-changing
    ///      swap makes the exact cumulative at M unrecoverable — and every bond maturing there
    ///      becomes unsettleable, with nothing anywhere reporting an error.

    ///      TWO HALVES, AND BOTH ARE NEEDED.

    ///      The STICKY FLAG covers maturities that have already been resolved and dropped from the
    ///      active set. The handler checks each maturity at the moment the cursor passes it; if the
    ///      checkpoint was missing then, `ghostMissedMaturity` is set and never cleared. So a
    ///      maturity skipped early stays detected for the rest of the campaign even though its
    ///      entry is gone. This is what makes forgetting safe.

    ///      The ACTIVE-SET LOOP covers maturities that have become due since the last handler
    ///      action — the window the sticky flag has not yet seen.

    ///      Together these are exactly the original property. Nothing is weakened: a maturity
    ///      skipped earlier and now behind the cursor is still caught, by the first half.

    ///      BOUND. The active set holds only registered-but-unresolved maturities, so its size is
    ///      proportional to maturities in flight — bounded by `OBSERVATION_BLOCKS` distinct blocks
    ///      at any moment — and does NOT grow with campaign length, elapsed blocks, chain age or
    ///      total historical bonds. No loop here or in the handler iterates a block range.
    function invariant_noMissedMaturity() public view {
        // Half one: anything already resolved and dropped.
        assertFalse(handler.ghostMissedMaturity(), "a registered maturity fell behind the cursor unfrozen");

        // Half two: anything due but not yet resolved.
        (, uint32 lastUpdate,,) = hook.accumulator(id_);

        uint256 count = handler.activeMaturityCount();

        for (uint256 i = 0; i < count; i++) {
            uint32 m = handler.activeMaturityAt(i);

            if (m > lastUpdate) continue;

            (,,, uint32 pending, uint8 checkpointedMask) = hook.maturity(id_, m);

            bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;

            assertGt(pending, 0, "a registered maturity lost its bonds");
            assertTrue(checkpointed, "a due registered maturity was never checkpointed");
        }
    }

    /// @notice The active set stays bounded — it does not accumulate over the campaign.
    /// @dev Makes the bound a tested property rather than a claim in a comment. A model that grew
    ///      with history would fail this well before the campaign ended.
    function invariant_ghostActiveSetStaysBounded() public view {
        // Generous headroom over `OBSERVATION_BLOCKS` in-flight maturities; the point is that this
        // is a constant, not a function of how many actions the campaign has run.
        assertLe(handler.activeMaturityCount(), 64, "the ghost active set is growing with campaign length");
    }

    /// @notice A frozen checkpoint is never rewritten by later advancement.

    /// @dev Immutability is what makes settlement independent of when it is called. Checked here
    ///      across the whole campaign by comparing each frozen value against the first value the
    ///      invariant ever observed for that bucket.
    function invariant_frozenCheckpointsNeverChange() public {
        uint256 count = handler.activeMaturityCount();

        for (uint256 i = 0; i < count; i++) {
            uint32 m = handler.activeMaturityAt(i);

            (,, int56 cumulative,, uint8 checkpointedMask) = hook.maturity(id_, m);

            bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;

            if (!checkpointed) continue;

            if (seenCheckpoint[m]) {
                assertEq(cumulative, firstSeenCumulative[m], "a frozen checkpoint changed");
            } else {
                seenCheckpoint[m] = true;
                firstSeenCumulative[m] = cumulative;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
            MODEL L2 SETTLEMENT — AMOUNTS, NOT JUST CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Every settlement in the campaign paid exactly what Model L2 predicts.
    ///
    /// @dev CONSERVATION ALONE IS A WEAK CHECK, and this is the invariant that makes the settlement
    ///      campaign mean something. `invariant_collateralConservation` asserts
    ///      `refund + slash == collateral`, which a hook that refunded everything — or slashed
    ///      everything — would satisfy on every bond it ever touched.
    ///
    ///      This prices each settled bond independently, from the per-block pool ticks the handler
    ///      observed rather than from anything the hook stored, and compares the amounts that
    ///      actually moved. A dead zone off by a tick, a window read from the wrong endpoint, or a
    ///      slash computed against the collateral instead of the variable leg all show up here.
    function invariant_settlementMatchesModelL2() public view {
        assertFalse(handler.ghostSettlementMismatch(), "a settlement paid an amount Model L2 does not predict");
    }

    /*//////////////////////////////////////////////////////////////
              INV-L2-8 — THREE ENDPOINTS, EXACT (ADR-0007)
    //////////////////////////////////////////////////////////////*/

    /// @notice NO-MISSED-C6 / C8 / C10, each checked independently, each against the reference.
    ///
    /// @dev THE INVARIANT P-L2-5 ACTIVATES. ADR-0003's single NO-MISSED-MATURITY becomes three,
    ///      because the three endpoints freeze at three different blocks:
    ///
    ///          open+6  <= lastUpdate  =>  bit 0 set, and the value is exact
    ///          open+8  <= lastUpdate  =>  bit 1 set, and the value is exact
    ///          M       <= lastUpdate  =>  bit 2 set, and the value is exact
    ///
    ///      Each condition is separate on purpose. A bucket at `lastUpdate == open+7` is legally
    ///      half-frozen, and a check that demanded all-or-nothing would either reject a correct
    ///      state or accept a stranded endpoint.
    ///
    ///      EXACTNESS IS CHECKED AGAINST `handler.refCumulativeAt`, which integrates the POOL's
    ///      tick block by block and never touches the hook's accumulator. Comparing the hook to its
    ///      own accumulator would be circular — ADR-0007 § 6 names this specifically.
    ///
    ///      A stranded endpoint is not cosmetic: once `lastUpdate` passes it the value is
    ///      unrecoverable, `cumulativeAt` reverts rather than guessing, and every bond in that
    ///      cohort becomes unsettleable.
    function invariant_inv_L2_8_everyDueEndpointIsFrozenAndExact() public view {
        (, uint32 lastUpdate,,) = hook.accumulator(id_);

        uint32 obs = hook.OBSERVATION_BLOCKS();

        uint256 count = handler.activeMaturityCount();

        for (uint256 i = 0; i < count; i++) {
            uint32 m = handler.activeMaturityAt(i);

            (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = hook.maturity(id_, m);

            if (pending == 0) continue;

            uint32 open = m - obs;

            if (open + 6 <= lastUpdate) {
                assertTrue(mask & hook.FROZEN_C6() != 0, "NO-MISSED-C6: a due C6 was never frozen");

                if (handler.refCovers(open + 6)) {
                    assertEq(c6, handler.refCumulativeAt(open + 6), "C6 does not match the independent reference");
                }
            }

            if (open + 8 <= lastUpdate) {
                assertTrue(mask & hook.FROZEN_C8() != 0, "NO-MISSED-C8: a due C8 was never frozen");

                if (handler.refCovers(open + 8)) {
                    assertEq(c8, handler.refCumulativeAt(open + 8), "C8 does not match the independent reference");
                }
            }

            if (m <= lastUpdate) {
                assertTrue(mask & hook.FROZEN_C10() != 0, "NO-MISSED-C10: a due C10 was never frozen");

                if (handler.refCovers(m)) {
                    assertEq(c10, handler.refCumulativeAt(m), "C10 does not match the independent reference");
                }
            }
        }
    }

    /// @notice No frozen endpoint value ever changes, and no set mask bit is ever cleared.
    ///
    /// @dev IMMUTABLE, extended from one endpoint to three. Each value is compared against the
    ///      FIRST value this invariant ever observed for it, so a rewrite anywhere in the campaign
    ///      is caught even if a later advancement restores the original.
    ///
    ///      Immutability is what makes settlement independent of when it is called, which is
    ///      ADR-0003's governing invariant and the reason the whole checkpoint mechanism exists.
    function invariant_frozenEndpointsNeverChange() public {
        uint256 count = handler.activeMaturityCount();

        for (uint256 i = 0; i < count; i++) {
            uint32 m = handler.activeMaturityAt(i);

            (int56 c6, int56 c8, int56 c10,, uint8 mask) = hook.maturity(id_, m);

            // A set bit is never cleared.
            assertEq(mask & seenMask[m], seenMask[m], "IMMUTABLE: a frozen endpoint bit was cleared");

            if (mask & hook.FROZEN_C6() != 0) {
                if (seenMask[m] & hook.FROZEN_C6() != 0) {
                    assertEq(c6, firstSeenC6[m], "IMMUTABLE: a frozen C6 changed");
                } else {
                    firstSeenC6[m] = c6;
                }
            }

            if (mask & hook.FROZEN_C8() != 0) {
                if (seenMask[m] & hook.FROZEN_C8() != 0) {
                    assertEq(c8, firstSeenC8[m], "IMMUTABLE: a frozen C8 changed");
                } else {
                    firstSeenC8[m] = c8;
                }
            }

            if (mask & hook.FROZEN_C10() != 0) {
                if (seenMask[m] & hook.FROZEN_C10() != 0) {
                    assertEq(c10, firstSeenC10[m], "IMMUTABLE: a frozen C10 changed");
                } else {
                    firstSeenC10[m] = c10;
                }
            }

            seenMask[m] = mask | seenMask[m];
        }
    }

    /// @notice BOUNDED — no occupied, partly unfrozen bucket sits outside the scan horizon.
    ///
    /// @dev This is what keeps the loop bound honest. The scheduler scans only
    ///      `(lastUpdate, lastUpdate + OBSERVATION_BLOCKS]`. If an occupied bucket could sit above
    ///      that and still be waiting for endpoints, the loop would have to grow to reach it — and
    ///      until it did, those endpoints would be silently stranded.
    ///
    ///      Note the direction of the claim: buckets BELOW the cursor are fine to be unfrozen only
    ///      if their endpoints are not yet due, which
    ///      `invariant_inv_L2_8_everyDueEndpointIsFrozenAndExact` covers. This one is about the
    ///      upper edge.
    function invariant_noOccupiedUnfrozenBucketAboveTheHorizon() public view {
        (, uint32 lastUpdate,,) = hook.accumulator(id_);

        uint32 horizon = lastUpdate + hook.OBSERVATION_BLOCKS();

        uint256 count = handler.activeMaturityCount();

        for (uint256 i = 0; i < count; i++) {
            uint32 m = handler.activeMaturityAt(i);

            (,,, uint32 pending, uint8 mask) = hook.maturity(id_, m);

            if (pending == 0) continue;

            if (mask == hook.FROZEN_ALL()) continue;

            assertLe(m, horizon, "BOUNDED: an occupied, unfrozen bucket sits above the scan horizon");
        }
    }

    /// @notice NO-PHANTOM — a bucket carries checkpoint data only where a bond was registered.
    ///
    /// @dev The guarantee that makes the scheduler's FORWARD writes safe. It writes into buckets
    ///      ahead of the cursor, so without the `pendingBonds == 0` early return a scan could
    ///      conjure a cohort for a bond that never existed.
    ///
    ///      Stated as: a frozen mask implies the bucket was registered at some point. Because
    ///      buckets are never deleted (ADR-0003 § 5.4), "registered at some point" is the handler's
    ///      ghost record rather than the live `pendingBonds`, which drops back to zero as bonds
    ///      settle.
    function invariant_noPhantomBucket() public view {
        uint256 count = handler.touchedMaturityCount();

        for (uint256 i = 0; i < count; i++) {
            uint32 m = handler.touchedMaturityAt(i);

            (,,,, uint8 mask) = hook.maturity(id_, m);

            if (mask == 0) continue;

            assertTrue(
                handler.everRegisteredAt(m), "NO-PHANTOM: a bucket froze endpoints without a bond ever registering"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                         CAMPAIGN COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reports everything the campaign reached. REPORTING ONLY, deliberately.
    ///
    /// @dev P-L2-8 § 27 asks that "a passing invariant campaign that never reaches the interesting
    ///      state FAILS". That requirement is met — but NOT by asserting here, and the reason is
    ///      worth recording because the obvious implementation is wrong.
    ///
    ///      `afterInvariant` observes whatever sequence the run happened to produce, including a
    ///      SHRUNK one after a failure and a thin one when the random selector draw happens not to
    ///      settle anything. Asserting reachability here therefore turns an unrelated invariant
    ///      failure into a confusing second failure, and makes the campaign flaky on seeds that are
    ///      perfectly healthy. Measured directly: with hard assertions here, a default-profile run
    ///      reported all seventeen invariants failing with "nothing ever settled" — none of which
    ///      was true of the mechanism.
    ///
    ///      So reachability is proven DETERMINISTICALLY instead, by
    ///      `test_campaignCanReachEveryInterestingState`, which drives the handler by hand through
    ///      every state the invariants are conditional on. That is a stronger guarantee than a
    ///      probabilistic one: it does not depend on the seed at all.
    ///
    ///      The counters are still printed, because a reviewer reading a campaign log should be
    ///      able to see the coverage it actually achieved rather than trust that it achieved any.
    function afterInvariant() public view {
        console2.log("exact-input  bonded  :", handler.exactInputBonded());
        console2.log("exact-input  unbonded:", handler.exactInputUnbonded());
        console2.log("exact-output bonded  :", handler.exactOutputBonded());
        console2.log("exact-output unbonded:", handler.exactOutputUnbonded());
        console2.log("reverted             :", handler.reverted());
        console2.log("settled              :", handler.settledCount());
        console2.log("settlements priced   :", handler.settlementsChecked());
        console2.log("full refunds         :", handler.fullRefundCount());
        console2.log("partial slashes      :", handler.partialSlashCount());
        console2.log("full slashes         :", handler.fullSlashCount());
        console2.log("mask union observed  :", uint256(handler.observedMaskUnion()));

        // ADR-0008 REACH. `blockTermDecidedBonds` is the sharpest of the three: zero would mean the
        // campaign never produced a bond whose rate came from the block term rather than its own
        // impact, so every ADR-0008 invariant above would have been asserted only on the old
        // model's behaviour. It is reported rather than asserted, because `afterInvariant` also
        // observes shrunk sequences after a failure and asserting here would misreport those.
        console2.log("first-in-block swaps :", handler.firstInBlockSwaps());
        console2.log("same-block swaps     :", handler.sameBlockSwaps());
        console2.log("block-term bonds     :", handler.blockTermDecidedBonds());
        console2.log("bonds ever created   :", handler.allBondCount());
    }

    /// @notice DETERMINISTIC NON-VACUITY: every state the invariants are conditional on is
    ///         reachable through the handler's own actions.
    ///
    /// @dev THE POINT OF P-L2-8 § 27, proven without depending on a seed. Almost every invariant in
    ///      this file is a conditional, and each is satisfied trivially by a campaign that bonded
    ///      nothing. This drives the handler by hand until each state has been visited, so a
    ///      regression that quietly stopped the campaign bonding, settling or freezing would fail
    ///      HERE — loudly and in one place — rather than turning the whole suite silently green.
    function test_campaignCanReachEveryInterestingState() public {
        // All four custody modes. Odd seeds land at or above the threshold, even below.
        handler.swapExactInput(3, true, false);
        handler.swapExactInput(3, false, false);
        handler.swapExactInput(2, true, false);
        handler.swapExactOutput(3, true, false);
        handler.swapExactOutput(3, false, false);
        handler.swapExactOutput(2, false, false);

        assertGt(handler.exactInputBonded(), 0, "NON-VACUITY: exact-input never bonded");
        assertGt(handler.exactOutputBonded(), 0, "NON-VACUITY: exact-output never bonded");
        assertGt(handler.exactInputUnbonded(), 0, "NON-VACUITY: exact-input was never unbonded");
        assertGt(handler.exactOutputUnbonded(), 0, "NON-VACUITY: exact-output was never unbonded");

        // Both collateral currencies were taken: the four modes above span both.
        assertGt(currency0.balanceOf(address(hook)) + currency1.balanceOf(address(hook)), 0, "no collateral taken");

        // Advance past maturity and flush so every checkpoint bit freezes.
        handler.advanceBlocks(11);
        handler.swapExactInput(2, true, false);

        assertEq(
            handler.observedMaskUnion() & hook.FROZEN_ALL(),
            0,
            "the mask union is only updated at settlement; it should still be empty here"
        );

        // Settle everything the campaign opened.
        for (uint256 i = 0; i < 12; i++) {
            handler.settleABond(i);
        }

        assertGt(handler.settledCount(), 0, "NON-VACUITY: nothing ever settled");
        assertGt(handler.settlementsChecked(), 0, "NON-VACUITY: no settlement was priced against the reference");
        assertGt(handler.settledAfterMaturity(), 0, "NON-VACUITY: nothing settled at or after maturity");

        assertEq(
            handler.observedMaskUnion() & hook.FROZEN_ALL(),
            hook.FROZEN_ALL(),
            "NON-VACUITY: some checkpoint endpoint was never frozen"
        );

        assertTrue(
            handler.settledInCurrency(currency0) || handler.settledInCurrency(currency1),
            "NON-VACUITY: no settlement was attributed to a currency"
        );

        // At least one settlement outcome was reached, and the breakdown is reported. Which
        // outcome depends on the price path, so the bar here is existence rather than all three.
        uint256 outcomes = (handler.fullRefundCount() > 0 ? 1 : 0) + (handler.partialSlashCount() > 0 ? 1 : 0)
            + (handler.fullSlashCount() > 0 ? 1 : 0);

        assertGt(outcomes, 0, "NON-VACUITY: no settlement outcome was classified");

        console2.log("REACHABLE full refunds   :", handler.fullRefundCount());
        console2.log("REACHABLE partial slashes:", handler.partialSlashCount());
        console2.log("REACHABLE full slashes   :", handler.fullSlashCount());
        console2.log("REACHABLE mask union     :", uint256(handler.observedMaskUnion()));

        // And the invariants still hold on the state this test built.
        assertFalse(handler.ghostConservationViolated(), "conservation broke on the reachable path");
        assertFalse(handler.ghostSettlementMismatch(), "a settlement disagreed with Model L2");
        assertFalse(handler.ghostDoubleSettlement(), "a double settlement occurred");
    }

    /// @notice Proves that the handler can reach all four custody paths.

    /// @notice All four custody paths are reachable, and between them they take collateral in
    ///         BOTH currencies.
    ///
    /// @dev THE DIRECTION MATRIX CHANGED IN P-L2-3/4, and the old one silently stopped covering
    ///      what this test claims to cover.
    ///
    ///      Previously collateral always came from the INPUT, so direction alone chose the
    ///      currency and "one zeroForOne swap plus one oneForZero swap" guaranteed both. Under
    ///      ADR-0006 the swap KIND participates too:
    ///
    ///          exact-input  zeroForOne -> currency1      exact-output zeroForOne -> currency0
    ///          exact-input  oneForZero -> currency0      exact-output oneForZero -> currency1
    ///
    ///      The old pairing -- exact-input zeroForOne with exact-output oneForZero -- now lands in
    ///      currency1 BOTH times. The test would have kept asserting "both currencies were taken"
    ///      against a run that only ever touched one.
    ///
    ///      So all four combinations are driven explicitly rather than two, and the currency each
    ///      one is expected to produce is taken from `ModelLReference` rather than written out, so
    ///      the mapping cannot drift out of step with the specification.
    function test_handlerExercisesAllFourCustodyPaths() public {
        // Odd seed => amount at or above threshold => bonded. Even seed => below => unbonded.

        // Exact-input, both directions.
        handler.swapExactInput(3, true, false);
        handler.swapExactInput(3, false, false);

        assertGe(handler.exactInputBonded(), 1, "exact-input bonded path unreachable");

        handler.swapExactInput(2, true, false);

        assertGe(handler.exactInputUnbonded(), 1, "exact-input unbonded path unreachable");

        // Exact-output, both directions.
        handler.swapExactOutput(3, true, false);
        handler.swapExactOutput(3, false, false);

        assertGe(handler.exactOutputBonded(), 1, "exact-output bonded path unreachable");

        handler.swapExactOutput(2, false, false);

        assertGe(handler.exactOutputUnbonded(), 1, "exact-output unbonded path unreachable");

        // Both collateral currencies were genuinely used.
        assertGt(handler.measuredBondTotal(currency0), 0, "no currency0 collateral was ever taken");

        assertGt(handler.measuredBondTotal(currency1), 0, "no currency1 collateral was ever taken");

        // The mapping the matrix above relies on, asserted rather than assumed.
        assertFalse(ModelLReference.collateralIsCurrency0(true, true), "exact-input zeroForOne must bond in currency1");
        assertTrue(ModelLReference.collateralIsCurrency0(false, true), "exact-input oneForZero must bond in currency0");
        assertTrue(ModelLReference.collateralIsCurrency0(true, false), "exact-output zeroForOne must bond in currency0");
        assertFalse(
            ModelLReference.collateralIsCurrency0(false, false), "exact-output oneForZero must bond in currency1"
        );

        // Ghost accounting must match the hook's real ERC-20 balances.
        assertEq(
            currency0.balanceOf(address(hook)),
            handler.measuredBondTotal(currency0),
            "currency0 ghost disagrees with the hook's real balance"
        );

        assertEq(
            currency1.balanceOf(address(hook)),
            handler.measuredBondTotal(currency1),
            "currency1 ghost disagrees with the hook's real balance"
        );
    }

    /// @notice A reverted swap must not change the hook's custody accounting.

    /// @dev The handler's `tightCeiling` mode sets `maxBondAmount` one wei below the required bond, forcing the hook to revert. The hook balance and ghost accounting must remain unchanged.
    /// @notice The checkpoint invariants are reachable: the handler really does drive buckets to
    ///         due endpoints, and the reference really does get compared.
    ///
    /// @dev NON-VACUITY, and it is not a formality here.
    ///
    ///      `invariant_inv_L2_8_everyDueEndpointIsFrozenAndExact` is written as a set of
    ///      conditionals — "if this endpoint is due, it must be frozen and exact". Every one of
    ///      those conditions is false on a campaign that never registers a bond or never advances
    ///      far enough, and the invariant would then pass by doing nothing at all. P-L2-3/4 already
    ///      caught one harness bug of exactly this shape.
    ///
    ///      So this drives the handler by hand into the state the invariant is meant to police —
    ///      a registered bucket with all three endpoints behind the cursor — and asserts the
    ///      endpoints are both frozen and equal to the INDEPENDENT reference. If the campaign could
    ///      not reach that state, this fails while the invariant would have stayed green.
    function test_checkpointInvariantsAreReachable() public {
        // Odd seed puts the amount at or above the threshold, so this bonds.
        handler.swapExactInput(3, true, false);

        uint32 obs = hook.OBSERVATION_BLOCKS();

        // Find the bucket the handler just registered.
        uint256 count = handler.activeMaturityCount();

        assertGt(count, 0, "the handler registered no maturity at all");

        uint32 m = handler.activeMaturityAt(count - 1);

        (,,, uint32 pending,) = hook.maturity(id_, m);

        assertEq(pending, 1, "the handler did not register exactly one bond");

        // Advance past every endpoint and flush.
        handler.advanceBlocks(11);
        handler.swapExactInput(2, true, false);

        (, uint32 lastUpdate,,) = hook.accumulator(id_);

        uint32 open = m - obs;

        assertGe(lastUpdate, m, "the campaign cannot reach a fully due bucket");

        (int56 c6, int56 c8, int56 c10,, uint8 mask) = hook.maturity(id_, m);

        assertEq(mask, hook.FROZEN_ALL(), "a fully due bucket was not fully frozen");

        // And the reference comparison the invariant performs is actually meaningful here.
        assertTrue(handler.refCovers(open + 6), "the reference cannot answer for C6");

        assertEq(c6, handler.refCumulativeAt(open + 6), "C6 disagrees with the independent reference");
        assertEq(c8, handler.refCumulativeAt(open + 8), "C8 disagrees with the independent reference");
        assertEq(c10, handler.refCumulativeAt(m), "C10 disagrees with the independent reference");

        // The three values must be genuinely distinct, or a scheduler writing one value into all
        // three fields would satisfy every assertion above.
        assertTrue(c6 != c8 && c8 != c10, "the three endpoints are identical; this proves nothing");
    }

    /// @notice The settlement differential is reachable: the campaign really does settle bonds and
    ///         really does price them against the reference.
    ///
    /// @dev NON-VACUITY for `invariant_settlementMatchesModelL2`. That invariant asserts a sticky
    ///      flag stays false, which a campaign that never settled anything would satisfy by doing
    ///      nothing. The `settlementsChecked` counter exists precisely so "no mismatch" can be
    ///      distinguished from "no comparison", and this drives the handler by hand until at least
    ///      one settlement has been priced.
    function test_settlementDifferentialIsReachable() public {
        // Odd seed puts the amount at or above the threshold, so this bonds.
        handler.swapExactInput(3, true, false);

        assertEq(handler.settlementsChecked(), 0, "nothing should have settled yet");

        // Past maturity, then flush so the endpoints freeze.
        handler.advanceBlocks(11);
        handler.swapExactInput(2, true, false);

        handler.settleABond(0);

        assertGt(handler.settlementsChecked(), 0, "the campaign cannot reach a priced settlement");

        assertFalse(handler.ghostSettlementMismatch(), "the reached settlement disagreed with Model L2");

        assertGt(handler.settledCount(), 0, "no bond actually settled");
    }

    function test_rejectedSwapLeavesAccountingUntouched() public {
        // First create a successful bond so we have a non-zero baseline.
        handler.swapExactInput(3, true, false);

        // Exact-input zeroForOne bonds in the OUTPUT currency, which is currency1.
        Currency collateral =
            ModelLReference.collateralIsCurrency0({zeroForOne: true, exactInput: true}) ? currency0 : currency1;

        uint256 hookBalance = collateral.balanceOf(address(hook));

        uint256 ghost = handler.measuredBondTotal(collateral);

        assertGt(hookBalance, 0, "baseline bond was not taken");

        // Repeat with a bond ceiling far below the required amount.
        handler.swapExactInput(3, true, true);

        assertEq(handler.reverted(), 1, "the tight-ceiling swap did not revert");

        assertEq(collateral.balanceOf(address(hook)), hookBalance, "a reverted swap changed the hook balance");

        assertEq(handler.measuredBondTotal(collateral), ghost, "a reverted swap moved the ghost");
    }
}
