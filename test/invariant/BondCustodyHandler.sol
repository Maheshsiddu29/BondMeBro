// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro} from "../../src/BondMeBro.sol";
import {HookDataCodec} from "../../src/libraries/HookDataCodec.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModelLReference} from "../utils/ModelLReference.sol";

/// @title BondCustodyHandler

/// @notice Fuzz handler that drives BondMeBro through exact-input and exact-output swaps in both directions so the custody invariants can be checked across sequences of swaps.

/// @dev The handler tracks two independent totals for each currency. `measuredBondTotal` records how much the hook's real ERC-20 balance increased, while `expectedBondTotal` recomputes how much collateral the BondMeBro formulas say should have been taken. Comparing the two helps detect accounting or bond-calculation errors.

/// Reverted swaps are expected during fuzzing. A revert must leave custody accounting unchanged, so ghost totals are updated only after a successful swap.

contract BondCustodyHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    BondMeBro internal immutable hook;

    Currency internal immutable currency0;
    Currency internal immutable currency1;

    PoolKey internal key_;

    uint256 internal constant BPS = 10_000;

    /// @dev Fuzzed swap sizes stay between `FLOOR` and `CEIL` so the campaign can exercise both bonded and unbonded paths without spending most calls on dust or liquidity-limit failures.
    uint256 internal constant FLOOR = 1e12;
    uint256 internal constant CEIL = 1e18;

    address internal constant REFUND_RECIPIENT = address(0xB0B);

    /// @notice Total collateral the hook actually received, tracked separately for each currency.
    mapping(Currency => uint256) public measuredBondTotal;

    /// @notice Total collateral the formulas independently predict should have been taken, tracked separately for each currency.
    mapping(Currency => uint256) public expectedBondTotal;

    /// @notice Number of successful bonded exact-input swaps exercised by the campaign.
    uint256 public exactInputBonded;

    /// @notice Number of successful unbonded exact-input swaps exercised by the campaign.
    uint256 public exactInputUnbonded;

    /// @notice Number of successful bonded exact-output swaps exercised by the campaign.
    uint256 public exactOutputBonded;

    /// @notice Number of successful unbonded exact-output swaps exercised by the campaign.
    uint256 public exactOutputUnbonded;

    /// @notice Number of swap attempts that reverted.
    uint256 public reverted;

    /*//////////////////////////////////////////////////////////////
                      T5B SETTLEMENT GHOST ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Collateral still owed to traders — finalized bonds not yet settled, per currency.
    /// @dev Decreases when a bond settles, by the full collateral: part leaves as refund, the rest
    ///      is reclassified into the pot. Both halves are tracked separately below.
    mapping(Currency => uint256) public ghostUnsettledCollateral;

    /// @notice Slashed collateral retained by the hook, per currency, as the handler models it.
    mapping(Currency => uint256) public ghostInsurancePot;

    /// @notice Total refunds actually paid out, per currency.
    mapping(Currency => uint256) public ghostRefundPaid;

    /// @notice Bonds settled by the campaign.
    uint256 public settledCount;

    /// @notice Bonds whose settlement was attempted too early and correctly reverted.
    uint256 public earlySettleRejected;

    /// @notice STICKY. Set if any settled bond failed `refund + slash == collateral`.
    bool public ghostConservationViolated;

    /// @notice STICKY. Set if a bond ever settled twice.
    bool public ghostDoubleSettlement;

    /// @notice Bond ids the campaign has finalized and not yet settled.
    /// @dev Bounded the same way the maturity active set is: entries leave on settlement. It holds
    ///      only live liabilities, never settled history.
    bytes32[] internal openBondIds;

    /// @notice Whether a bond id is currently in `openBondIds`.
    mapping(bytes32 => bool) internal bondOpen;

    /// @notice Whether the campaign has already settled this bond, for double-settle detection.
    mapping(bytes32 => bool) internal bondSettled;

    function openBondCount() external view returns (uint256) {
        return openBondIds.length;
    }

    function openBondAt(uint256 index) external view returns (bytes32) {
        return openBondIds[index];
    }

    /// @notice Every maturity block any swap has plausibly touched, in first-seen order.
    ///
    /// @dev GHOST MODEL FOR INV-PROVISIONAL AND INV-PENDING-FINALIZED. Recorded per maturity
    ///      BLOCK, never per elapsed block and never per historical bond, so invariant work stays
    ///      bounded by the number of distinct blocks the campaign swapped in rather than by the
    ///      protocol's history.
    ///
    ///      Recorded for EVERY attempt, including reverted and unbonded ones, because those are
    ///      exactly the cases where a provisional record could be left behind.
    uint32[] internal touchedMaturities;

    /// @notice Whether a maturity block is already in `touchedMaturities`.
    mapping(uint32 => bool) internal maturitySeen;

    /// @notice Count of bonds the handler believes were finalized at each maturity block.
    /// @dev Independently maintained, so `INV-PENDING-FINALIZED` compares the contract's counter
    ///      against a number derived from observed behaviour rather than from itself.
    mapping(uint32 => uint32) public expectedFinalizedAt;

    /*//////////////////////////////////////////////////////////////
              THE INDEPENDENT CUMULATIVE REFERENCE (ADR-0007)
    //////////////////////////////////////////////////////////////*/

    /// @dev One observation of the POOL: from `blockNumber` onward the tick is `tickFrom`, and the
    ///      integral up to `blockNumber` is `cumulative`.
    ///
    ///      ADR-0007 section 6 requires the checkpoint invariants to be checked against a reference
    ///      the test builds itself, never against the hook's own accumulator -- that would be
    ///      circular and would pass unchanged if every endpoint were off by a block.
    ///
    ///      This integrates `PoolManager.getSlot0`'s tick block by block. It never reads
    ///      `hook.accumulator`. It is exact because the pool tick can only change in a swap, and
    ///      the handler performs every swap in this campaign through one call site.
    struct RefPoint {
        uint32 blockNumber;
        int56 cumulative;
        int24 tickFrom;
    }

    RefPoint[] public refPoints;

    /// @dev Extends the reference to the current block. Called after every successful swap.
    function _noteRef() internal {
        RefPoint memory last = refPoints[refPoints.length - 1];

        uint32 nowBlock = uint32(block.number);

        int56 cumulative = last.cumulative + int56(last.tickFrom) * int56(uint56(nowBlock - last.blockNumber));

        // slither-disable-next-line unused-return
        (, int24 tick,,) = manager.getSlot0(key_.toId());

        refPoints.push(RefPoint({blockNumber: nowBlock, cumulative: cumulative, tickFrom: tick}));
    }

    /// @notice The independently integrated cumulative at an arbitrary block.
    function refCumulativeAt(uint32 atBlock) public view returns (int56) {
        for (uint256 i = refPoints.length; i > 0; i--) {
            RefPoint memory p = refPoints[i - 1];

            if (p.blockNumber <= atBlock) {
                return p.cumulative + int56(p.tickFrom) * int56(uint56(atBlock - p.blockNumber));
            }
        }

        revert("reference does not cover a block before initialization");
    }

    /// @notice Whether the reference can answer for a block at all.
    function refCovers(uint32 atBlock) public view returns (bool) {
        return refPoints.length > 0 && refPoints[0].blockNumber <= atBlock;
    }

    /// @notice Number of distinct maturity blocks the campaign has touched.
    function touchedMaturityCount() external view returns (uint256) {
        return touchedMaturities.length;
    }

    /// @notice Maturity block at `index` in the ghost model.
    function touchedMaturityAt(uint256 index) external view returns (uint32) {
        return touchedMaturities[index];
    }

    /// @dev Records a maturity block once. Cheap enough to call on every swap attempt.
    function _noteMaturity(uint32 maturityBlock) internal {
        if (maturitySeen[maturityBlock]) return;

        maturitySeen[maturityBlock] = true;
        touchedMaturities.push(maturityBlock);
    }

    /// @notice UNRESOLVED registered maturities — the NO-MISSED-MATURITY active set.
    ///
    /// @dev BOUNDED BY THE PROTOCOL HORIZON, NOT BY CAMPAIGN LENGTH. An entry is added when a bond
    ///      finalizes into a maturity block, and REMOVED as soon as that maturity has been
    ///      resolved — that is, once the cursor has passed it and its checkpoint has been observed
    ///      (or its absence recorded in `ghostMissedMaturity`).
    ///
    ///      Size is therefore proportional to the number of maturities that are simultaneously
    ///      registered-but-not-yet-due, which is bounded by `OBSERVATION_BLOCKS` distinct maturity
    ///      blocks in flight at any moment — NOT by total historical bonds, elapsed blocks, or
    ///      chain age. A campaign creating 5,000 distinct maturities over its run holds only the
    ///      handful still in flight, because each is resolved and dropped as the cursor passes it.
    ///
    ///      WHY FORGETTING A RESOLVED MATURITY IS SOUND. A verified checkpoint cannot later become
    ///      wrong: Stage 3 proves immutability separately, via
    ///      `invariant_frozenCheckpointsNeverChange` and `test_noBucketDeletion`. Re-checking it
    ///      every step would prove nothing further, so retention buys no strength — only unbounded
    ///      growth.
    ///
    ///      WHAT PRESERVES THE PROPERTY IS `ghostMissedMaturity`, NOT RETENTION. If a maturity is
    ///      found unfrozen at the moment it leaves the active set, that fact is recorded in a
    ///      sticky flag that is never cleared. So a maturity skipped early and detected once stays
    ///      detected for the remainder of the campaign, even though the entry itself is gone. The
    ///      invariant is not weakened: it still catches a maturity skipped earlier that has since
    ///      fallen behind the cursor.
    uint32[] internal activeMaturities;

    /// @notice Whether a maturity block is currently in the active set.
    mapping(uint32 => bool) internal maturityActive;

    /// @notice STICKY. Set the first time a due maturity is observed without its checkpoint, and
    ///         never cleared for the rest of the campaign.
    /// @dev This is what lets the active set forget resolved entries without losing the property.
    bool public ghostMissedMaturity;

    /// @notice Number of maturities currently in flight — registered and not yet resolved.
    function activeMaturityCount() external view returns (uint256) {
        return activeMaturities.length;
    }

    /// @notice Active maturity block at `index`.
    function activeMaturityAt(uint256 index) external view returns (uint32) {
        return activeMaturities[index];
    }

    /// @notice Whether a bond was EVER registered into this bucket, over the whole campaign.
    ///
    /// @dev Distinct from the live `pendingBonds`, which drops back to zero as bonds settle, and
    ///      distinct from `maturityActive`, which is cleared when a maturity is resolved and
    ///      dropped from the bounded active set.
    ///
    ///      `invariant_noPhantomBucket` needs the permanent fact: a bucket carrying frozen
    ///      endpoints must have had a real bond at some point. Buckets are never deleted
    ///      (ADR-0003 § 5.4), so the live counter cannot answer that question.
    mapping(uint32 => bool) public everRegisteredAt;

    /// @dev Adds a maturity to the active set once, when a bond finalizes into it.
    function _noteRegisteredMaturity(uint32 maturityBlock) internal {
        // Permanent, and set before the early return so a second bond into the same bucket does
        // not skip it.
        everRegisteredAt[maturityBlock] = true;

        if (maturityActive[maturityBlock]) return;

        maturityActive[maturityBlock] = true;
        activeMaturities.push(maturityBlock);
    }

    /// @notice Resolves every active maturity the cursor has now passed.
    ///
    /// @dev Called at the end of each handler action. For each due maturity it records whether the
    ///      checkpoint exists — setting the sticky flag if not — and then drops it from the set.
    ///      This is what keeps the set bounded by in-flight maturities rather than by history.
    ///
    ///      Iterates the ACTIVE SET, never a block range. There is no
    ///      `for b = oldLastUpdate + 1 ... newLastUpdate` here or anywhere else.
    function _resolveDueMaturities() internal {
        (, uint32 lastUpdate,) = hook.accumulator(key_.toId());

        uint256 i;

        while (i < activeMaturities.length) {
            uint32 m = activeMaturities[i];

            if (m > lastUpdate) {
                // Not due yet. Keep it in flight.
                i++;
                continue;
            }

            (,,,, uint8 checkpointedMask) = hook.maturity(key_.toId(), m);

            bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;

            // THE DETECTION POINT. A due maturity without a checkpoint is a miss, and the record
            // of it survives this entry's removal.
            if (!checkpointed) {
                ghostMissedMaturity = true;
            }

            // Resolved: drop it. Swap-and-pop keeps this O(1) per removal.
            maturityActive[m] = false;
            activeMaturities[i] = activeMaturities[activeMaturities.length - 1];
            activeMaturities.pop();
        }
    }

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        BondMeBro _hook,
        PoolKey memory _key,
        Currency _currency0,
        Currency _currency1
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        hook = _hook;
        key_ = _key;
        currency0 = _currency0;
        currency1 = _currency1;

        // Seed the independent reference where the hook seeded its accumulator: at the pool's
        // current state, with a cumulative of zero.
        // slither-disable-next-line unused-return
        (, int24 tick,,) = _manager.getSlot0(_key.toId());

        refPoints.push(RefPoint({blockNumber: uint32(block.number), cumulative: 0, tickFrom: tick}));
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a fuzzed exact-input swap.

    /// @dev For exact-input, BondMeBro calculates the bond from the requested gross input and takes it in `beforeSwap`. The generated amount intentionally lands either below or above the direction-specific bonding threshold so both paths are exercised.

    /// When `tightCeiling` is true and a bond is expected, `maxBondAmount` is set one wei below the expected bond. The swap should then revert, which helps prove that failed swaps leave custody accounting unchanged.

    /// @param amountSeed Fuzz value used to choose the swap amount.
    /// @param zeroForOne Swap direction.
    /// @param tightCeiling Whether to deliberately make the bond ceiling too small.
    function swapExactInput(uint256 amountSeed, bool zeroForOne, bool tightCeiling) external {
        uint256 minBondedAmount = _threshold(zeroForOne);

        uint256 grossInput = _sizeStraddlingThreshold(amountSeed, minBondedAmount);

        // THE EXACT-INPUT BOND CAN NO LONGER BE PREDICTED BEFORE EXECUTION.
        //
        // The old model computed it here, from the requested gross input, because that is exactly
        // what the hook did -- and that shared assumption is precisely the defect INV-L2-13
        // names. Model L prices collateral from the REALIZED variable leg and the REALIZED tick
        // impact, neither of which exists until the swap has run.
        //
        // So both swap kinds now take the same path: execute, measure, then reconstruct the
        // expected bond from what actually happened. The ghost model is strictly stronger for it,
        // because it no longer shares a formula with the code under test -- it shares only the
        // specification, restated in `ModelLReference`.
        //
        // The tight-ceiling path is driven differently for the same reason: without a predicted
        // bond there is no "one wei below" to aim at, so a ceiling of 1 is used, which is below
        // any bond this pool can produce and therefore still exercises the rejection path.
        uint128 ceiling = tightCeiling ? 1 : type(uint128).max;

        _execute(-int256(grossInput), zeroForOne, ceiling, true);

        _resolveDueMaturities();
    }

    /// @notice Executes a fuzzed exact-output swap.

    /// @dev Exact-output collateral cannot be predicted from `amountOut` alone because the bond depends on the amount the pool actually consumes. `_execute` measures the real pool input after the swap and independently applies the exact-output bond formula.

    /// The output amount is chosen around the input-side threshold. At the test pool's seeded price this gives the campaign a useful mix of bonded and unbonded exact-output swaps.

    /// @param amountSeed Fuzz value used to choose the requested output amount.
    /// @param zeroForOne Swap direction.
    /// @param tightCeiling Whether to use a deliberately restrictive bond ceiling.
    function swapExactOutput(uint256 amountSeed, bool zeroForOne, bool tightCeiling) external {
        uint256 amountOut = _sizeStraddlingThreshold(amountSeed, _threshold(zeroForOne));

        // A value of 1 is intentionally restrictive; otherwise use the maximum
        // uint128 ceiling so normal bonded swaps can succeed.
        uint128 ceiling = tightCeiling ? 1 : type(uint128).max;

        _execute(int256(amountOut), zeroForOne, ceiling, false);

        _resolveDueMaturities();
    }

    /// @notice Advances the chain without swapping, producing quiet gaps.
    ///
    /// @dev Lets the campaign spread bonds across many maturity blocks instead of piling them all
    ///      into one, and exercises the case where a bond matures with no swap having touched the
    ///      pool since. Bounded so the campaign does not wander thousands of blocks from any
    ///      maturity it created.
    ///
    /// @param blocksSeed Fuzz value choosing how far to roll.
    function advanceBlocks(uint256 blocksSeed) external {
        vm.roll(block.number + 1 + (blocksSeed % 12));

        // Rolling alone does not move the accumulator cursor, so nothing can become due here.
        // Resolving anyway keeps the rule uniform: every action ends with resolution.
        _resolveDueMaturities();
    }

    /// @notice Settles one of the campaign's open bonds, if any is mature.
    ///
    /// @dev The action that makes the solvency invariants meaningful — before settlement existed,
    ///      nothing could leave the hook and the old equality held trivially.
    ///
    ///      Measures the real refund from the recipient's balance and the real slash from the
    ///      pot, then checks conservation against the recorded collateral. A mismatch sets a
    ///      sticky flag rather than reverting, so the campaign continues and the invariant reports
    ///      it.
    ///
    /// @param seed Fuzz value selecting which open bond to try.
    function settleABond(uint256 seed) external {
        uint256 count = openBondIds.length;
        if (count == 0) return;

        bytes32 bondId = openBondIds[seed % count];

        BondMeBro.Bond memory bond = hook.getBond(bondId);

        Currency currency = bond.collateralIsCurrency0 ? currency0 : currency1;

        // Not mature yet: prove early settlement is rejected, then leave it alone.
        if (block.number < bond.maturityBlock) {
            try hook.settleBond(bondId) {
                // Settling before maturity must be impossible.
                ghostDoubleSettlement = true;
            } catch {
                earlySettleRejected++;
            }
            return;
        }

        // Read the collateral BEFORE settling. The record stores the realized variable leg now,
        // so the collateral is derived (ADR-0005 s3.2); capturing it up front keeps the
        // conservation check comparing against the amount that was actually held.
        uint256 collateralHeld = hook.collateralAmountOf(bondId);

        uint256 recipientBefore = currency.balanceOf(bond.refundRecipient);
        uint256 potBefore = hook.insurancePot(key_.toId(), currency);

        try hook.settleBond(bondId) {
            uint256 refund = currency.balanceOf(bond.refundRecipient) - recipientBefore;
            uint256 slash = hook.insurancePot(key_.toId(), currency) - potBefore;

            // INV-COLLATERAL-CONSERVATION, checked per bond at the moment it settles.
            if (refund + slash != collateralHeld) {
                ghostConservationViolated = true;
            }

            // A second settlement of the same bond must be impossible.
            if (bondSettled[bondId]) {
                ghostDoubleSettlement = true;
            }
            bondSettled[bondId] = true;

            ghostUnsettledCollateral[currency] -= collateralHeld;
            ghostInsurancePot[currency] += slash;
            ghostRefundPaid[currency] += refund;

            settledCount++;

            _dropOpenBond(bondId);
        } catch {
            reverted++;
        }
    }

    /// @notice Attempts to settle an already-settled bond, proving it cannot pay out twice.
    /// @param seed Fuzz value selecting a settled bond.
    function attemptDoubleSettle(uint256 seed) external {
        uint256 count = settledIds.length;
        if (count == 0) return;

        bytes32 bondId = settledIds[seed % count];

        Currency currency = hook.getBond(bondId).collateralIsCurrency0 ? currency0 : currency1;

        uint256 potBefore = hook.insurancePot(key_.toId(), currency);
        uint256 hookBefore = currency.balanceOf(address(hook));

        try hook.settleBond(bondId) {
            // Any success at all is a double settlement.
            ghostDoubleSettlement = true;
        } catch {
            // Expected. Nothing may have moved.
            if (
                hook.insurancePot(key_.toId(), currency) != potBefore || currency.balanceOf(address(hook)) != hookBefore
            ) {
                ghostDoubleSettlement = true;
            }
        }
    }

    /// @notice Settled bond ids, kept only so `attemptDoubleSettle` has something to aim at.
    /// @dev Capped so it cannot grow without bound over a long campaign.
    bytes32[] internal settledIds;

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Records the id of the bond just finalized, derived the same way the contract does.
    function _noteOpenBond(uint32 maturityBlock) internal {
        // The bond just registered took index `pendingBonds - 1`.
        (,,, uint32 pending,) = hook.maturity(key_.toId(), maturityBlock);
        if (pending == 0) return;

        bytes32 bondId = keccak256(abi.encode(key_.toId(), maturityBlock, pending - 1));

        if (bondOpen[bondId]) return;

        bondOpen[bondId] = true;
        openBondIds.push(bondId);
    }

    /// @dev Removes a settled bond from the live-liability set. Swap-and-pop, O(1).
    function _dropOpenBond(bytes32 bondId) internal {
        bondOpen[bondId] = false;

        uint256 length = openBondIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (openBondIds[i] == bondId) {
                openBondIds[i] = openBondIds[length - 1];
                openBondIds.pop();
                break;
            }
        }

        if (settledIds.length < 16) settledIds.push(bondId);
    }

    /// @dev Returns the input and output currencies for the selected swap direction.
    function _currencies(bool zeroForOne) internal view returns (Currency inputCurrency, Currency outputCurrency) {
        return zeroForOne ? (currency0, currency1) : (currency1, currency0);
    }

    /// @dev Returns the bonding threshold denominated in the input currency for the selected direction.
    function _threshold(bool zeroForOne) internal view returns (uint256) {
        (uint128 min0, uint96 min1,,) = hook.poolConfig(key_.toId());

        return zeroForOne ? uint256(min0) : uint256(min1);
    }

    /// @dev Chooses swap sizes from both sides of the bonding threshold. Roughly half of the seeds produce an amount below the threshold and half produce an amount at or above it.

    /// A single large uniform range would heavily favour one side when the threshold occupies only a small part of that range, causing the invariant campaign to miss the unbonded or bonded path. Splitting the range first gives both paths regular coverage.

    function _sizeStraddlingThreshold(uint256 seed, uint256 threshold) internal pure returns (uint256) {
        // If the threshold is outside the useful fuzzing window, choose any
        // swappable amount inside the configured range.
        if (threshold <= FLOOR || threshold >= CEIL) {
            return FLOOR + (seed % (CEIL - FLOOR));
        }

        if (seed & 1 == 0) {
            // Strictly below threshold => unbonded.
            return FLOOR + (seed % (threshold - FLOOR));
        }

        // At or above threshold => bonded.
        return threshold + (seed % (CEIL - threshold));
    }

    /// @dev Returns a permissive bond ceiling for normal swaps or one wei below the expected bond when testing the rejection path.
    function _ceiling(uint256 expectedBond, bool tight) internal pure returns (uint128) {
        if (!tight) {
            return type(uint128).max;
        }

        // No bond is expected, so there is nothing useful to constrain.
        if (expectedBond == 0) {
            return type(uint128).max;
        }

        // One wei below the expected bond should force BondMeBro to revert.
        return uint128(expectedBond - 1);
    }

    /// @dev Executes a swap, measures the real custody change, and updates the independent ghost
    ///      accounting only if the swap succeeds.
    ///
    ///      MEASURE-THEN-PREDICT, FOR BOTH SWAP KINDS.
    ///
    ///      This function used to take a pre-computed expected bond for exact-input and
    ///      reconstruct one only for exact-output. Under Model L neither kind can be predicted in
    ///      advance, so both are now handled identically: run the swap, read the realized legs and
    ///      the two ticks off actual balance movement and pool state, and only then apply the
    ///      specification through `ModelLReference`.
    ///
    ///      Reconstructing from measurement is what keeps this a genuine cross-check. The ghost
    ///      model never calls the hook's own sizing function and never reads the hook's own bond
    ///      record for the amount -- if it did, "bonds taken == bonds predicted" would be a
    ///      tautology.
    function _execute(int256 amountSpecified, bool zeroForOne, uint128 ceiling, bool isExactInput) internal {
        // Record the maturity this attempt would use, BEFORE the swap. A reverted or unbonded
        // attempt is exactly the case that could strand a provisional record, so the ghost model
        // must know about the bucket even when nothing is finalized into it.
        _noteMaturity(uint32(block.number) + hook.OBSERVATION_BLOCKS());

        Legs memory legs = _snapshotLegs(zeroForOne, isExactInput);

        try swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            HookDataCodec.encode(REFUND_RECIPIENT, ceiling)
        ) {
            // The reference must be extended before anything reads it, and only on success -- a
            // reverted swap leaves the pool untouched, so it contributes no interval.
            _noteRef();

            _recordOutcome(legs, zeroForOne, isExactInput);
        } catch {
            // Failed swaps must not update either ghost accounting total.
            reverted++;
        }
    }

    /// @dev The pre-swap readings needed to reconstruct a Model L bond afterwards.
    struct Legs {
        Currency collateralCurrency;
        Currency variableCurrency;
        Currency inputCurrency;
        uint256 hookCollateralBefore;
        uint256 managerInputBefore;
        uint256 selfVariableBefore;
        int24 tickBefore;
    }

    /// @dev Captures everything needed before a swap, choosing currencies by KIND and direction.
    function _snapshotLegs(bool zeroForOne, bool isExactInput) internal view returns (Legs memory legs) {
        (Currency inputCurrency, Currency outputCurrency) = _currencies(zeroForOne);

        // ADR-0006's unified rule. The swap KIND decides which side is variable; the direction
        // decides which currency that side is.
        legs.inputCurrency = inputCurrency;
        legs.variableCurrency = isExactInput ? outputCurrency : inputCurrency;
        legs.collateralCurrency =
            ModelLReference.collateralIsCurrency0(zeroForOne, isExactInput) ? currency0 : currency1;

        legs.hookCollateralBefore = legs.collateralCurrency.balanceOf(address(hook));
        legs.managerInputBefore = inputCurrency.balanceOf(address(manager));
        legs.selfVariableBefore = legs.variableCurrency.balanceOf(address(this));

        // slither-disable-next-line unused-return
        (, legs.tickBefore,,) = manager.getSlot0(key_.toId());
    }

    /// @dev Reconstructs the expected bond from realized movement and updates every ghost total.
    function _recordOutcome(Legs memory legs, bool zeroForOne, bool isExactInput) internal {
        uint32 maturityBlock = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // slither-disable-next-line unused-return
        (, int24 tickAfter,,) = manager.getSlot0(key_.toId());

        uint256 bondTaken = legs.collateralCurrency.balanceOf(address(hook)) - legs.hookCollateralBefore;

        // The input the pool actually consumed. Under variable-leg custody the hook no longer
        // carves anything out of the input, so this is the whole of it.
        uint256 actualInput = legs.inputCurrency.balanceOf(address(manager)) - legs.managerInputBefore;

        // The realized variable leg.
        //
        //   exact-input  : the pool paid out the OUTPUT, of which the hook withheld the bond
        //                  before this contract saw it -- so the leg is what arrived plus what
        //                  was withheld.
        //   exact-output : the leg IS the pool input.
        uint256 variableLeg = isExactInput
            ? (legs.variableCurrency.balanceOf(address(this)) - legs.selfVariableBefore) + bondTaken
            : actualInput;

        measuredBondTotal[legs.collateralCurrency] += bondTaken;

        if (bondTaken > 0) {
            expectedFinalizedAt[maturityBlock] += 1;

            // NO-MISSED-MATURITY ghost. Only REGISTERED maturities are recorded -- a bucket a
            // provisional record merely touched must never appear here, or the invariant would
            // demand a checkpoint for something ADR-0004 Rule 1 says does not exist.
            _noteRegisteredMaturity(maturityBlock);

            // The collateral is now a live liability of the hook, in ITS OWN currency.
            ghostUnsettledCollateral[legs.collateralCurrency] += bondTaken;

            _noteOpenBond(maturityBlock);
        }

        // ELIGIBILITY IS DECIDED ON THE ACTUAL CONSUMED INPUT (INV-L2-13), not on the requested
        // amount. A swap that asked for more than the threshold but filled below it is unbonded.
        uint256 expectedBond = actualInput < _threshold(zeroForOne)
            ? 0
            : ModelLReference.collateralFor(variableLeg, legs.tickBefore, tickAfter);

        expectedBondTotal[legs.collateralCurrency] += expectedBond;

        if (isExactInput) {
            if (expectedBond > 0) exactInputBonded++;
            else exactInputUnbonded++;
        } else {
            if (expectedBond > 0) exactOutputBonded++;
            else exactOutputUnbonded++;
        }
    }
}
