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
import {BondCustodyHandler} from "./BondCustodyHandler.sol";

/// @title BondCustodyInvariantsTest

/// @notice Stateful invariant tests for BondMeBro's current bond-custody implementation.

/// @dev Unit tests verify individual swaps. These invariants verify that custody remains correct across sequences of exact-input and exact-output swaps, both directions, including reverted transactions.

/// T3/T3B/T3C only implement custody. Bonds cannot yet be settled or refunded, so every bond ever taken should still be physically held by the hook. T5 will introduce bond records and outflows, so these accounting invariants must be updated when settlement is implemented.

/// Maturity and settlement invariants are intentionally not tested here because maturity checkpoints do not exist yet. T5 must add tests proving that the settlement result is fixed at maturity and cannot be changed by later swaps.

contract BondCustodyInvariantsTest is Test, Deployers {
    BondMeBro internal hook;
    BondCustodyHandler internal handler;

    PoolKey internal key_;
    PoolId internal id_;

    /// @dev `bonds` mapping slot and the byte offset of `Bond.state` within struct slot 1, both
    ///      from `forge inspect BondMeBro storage-layout`. Raw access is required because Rule 1
    ///      deliberately makes PROVISIONAL indistinguishable from absent through the public API —
    ///      which is the property under test.
    uint256 internal constant BONDS_SLOT = 4;
    uint256 internal constant STATE_BYTE_OFFSET = 30;
    uint8 internal constant STATE_PROVISIONAL = 1;

    /// @dev First cumulative the invariant ever observed for a frozen bucket, used to prove
    ///      immutability across the campaign.
    mapping(uint32 => bool) internal seenCheckpoint;
    mapping(uint32 => int56) internal firstSeenCumulative;

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;

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
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e23, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS);

        handler = new BondCustodyHandler(IPoolManager(address(manager)), swapRouter, hook, key_, currency0, currency1);

        // Fund the handler with both currencies and allow the test router to
        // pull tokens during swaps.
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1e30);

        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1e30);

        vm.startPrank(address(handler));

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);

        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        vm.stopPrank();

        // Restrict the stateful campaign to the handler's two swap actions.
        bytes4[] memory selectors = new bytes4[](3);

        selectors[0] = BondCustodyHandler.swapExactInput.selector;

        selectors[1] = BondCustodyHandler.swapExactOutput.selector;

        selectors[2] = BondCustodyHandler.advanceBlocks.selector;

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

    /// @notice The hook's real token balance must equal the total bonds it actually received.

    /// @dev This is checked separately for currency0 and currency1 because every bond must remain denominated in the swap's input currency. In the current custody-only build nothing can leave the hook, so the relationship should be exact.
    function invariant_hookBalanceEqualsSumOfBondsTaken() public view {
        assertEq(
            currency0.balanceOf(address(hook)),
            handler.measuredBondTotal(currency0),
            "currency0: hook balance != sum of bonds taken"
        );

        assertEq(
            currency1.balanceOf(address(hook)),
            handler.measuredBondTotal(currency1),
            "currency1: hook balance != sum of bonds taken"
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

    /// @notice The hook must not hold PoolManager claim tokens after a completed swap.

    /// @dev BondMeBro uses physical token custody with `claims = false`. A non-zero ERC-6909 claim balance would mean some custody was represented as a claim against PoolManager instead of real ERC-20 tokens held by the hook.
    function invariant_hookHoldsNoPoolManagerClaims() public view {
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds currency0 claims");

        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook holds currency1 claims");
    }

    /// @notice Every expected bond must be backed by real tokens held by the hook.

    /// @dev In the current custody-only build, no refund or settlement path can remove tokens, so the hook must always hold at least the collateral represented by the expected bond totals. T5 must replace this simple custody rule with settlement-aware liability accounting.
    function invariant_hookIsFullyBackedByRealTokens() public view {
        assertGe(
            currency0.balanceOf(address(hook)), handler.expectedBondTotal(currency0), "currency0: bonds not backed"
        );

        assertGe(
            currency1.balanceOf(address(hook)), handler.expectedBondTotal(currency1), "currency1: bonds not backed"
        );
    }

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

            (, uint32 pending,) = hook.maturity(id_, m);

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

            (, uint32 pending,) = hook.maturity(id_, m);

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

            (, uint32 pending,) = hook.maturity(id_, m);

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
        (, uint32 lastUpdate,) = hook.accumulator(id_);

        uint256 count = handler.activeMaturityCount();

        for (uint256 i = 0; i < count; i++) {
            uint32 m = handler.activeMaturityAt(i);

            if (m > lastUpdate) continue;

            (, uint32 pending, bool checkpointed) = hook.maturity(id_, m);

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

            (int56 cumulative,, bool checkpointed) = hook.maturity(id_, m);

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
                         CAMPAIGN COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Prints how many times each custody path was exercised during the invariant campaign.

    /// @dev Reporting only. Path reachability is tested separately by `test_handlerExercisesAllFourCustodyPaths` so invariant shrinking cannot turn a coverage assertion into an unrelated failure.
    function afterInvariant() public view {
        console2.log("exact-input  bonded  :", handler.exactInputBonded());

        console2.log("exact-input  unbonded:", handler.exactInputUnbonded());

        console2.log("exact-output bonded  :", handler.exactOutputBonded());

        console2.log("exact-output unbonded:", handler.exactOutputUnbonded());

        console2.log("reverted             :", handler.reverted());
    }

    /// @notice Proves that the handler can reach all four custody paths.

    /// @dev This prevents a vacuous invariant campaign where every action reverts or does nothing and all accounting totals remain zero. The hand-picked seeds deterministically exercise bonded and unbonded exact-input and exact-output swaps.
    function test_handlerExercisesAllFourCustodyPaths() public {
        // Odd seed => amount at or above threshold => bonded exact-input.
        handler.swapExactInput(3, true, false);

        assertEq(handler.exactInputBonded(), 1, "exact-input bonded path unreachable");

        // Even seed => amount below threshold => unbonded exact-input.
        handler.swapExactInput(2, true, false);

        assertEq(handler.exactInputUnbonded(), 1, "exact-input unbonded path unreachable");

        // Exact-output, opposite direction, bonded.
        handler.swapExactOutput(3, false, false);

        assertEq(handler.exactOutputBonded(), 1, "exact-output bonded path unreachable");

        // Exact-output, opposite direction, unbonded.
        handler.swapExactOutput(2, false, false);

        assertEq(handler.exactOutputUnbonded(), 1, "exact-output unbonded path unreachable");

        // Confirm that both input currencies were actually taken as collateral.
        assertGt(handler.measuredBondTotal(currency0), 0, "no currency0 bond was actually taken");

        assertGt(handler.measuredBondTotal(currency1), 0, "no currency1 bond was actually taken");

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
    function test_rejectedSwapLeavesAccountingUntouched() public {
        // First create a successful bond so we have a non-zero baseline.
        handler.swapExactInput(3, true, false);

        uint256 hookBalance = currency0.balanceOf(address(hook));

        uint256 ghost = handler.measuredBondTotal(currency0);

        assertGt(hookBalance, 0, "baseline bond was not taken");

        // Repeat with a bond ceiling one wei below the required amount.
        handler.swapExactInput(3, true, true);

        assertEq(handler.reverted(), 1, "the tight-ceiling swap did not revert");

        assertEq(currency0.balanceOf(address(hook)), hookBalance, "a reverted swap changed the hook balance");

        assertEq(handler.measuredBondTotal(currency0), ghost, "a reverted swap moved the ghost");
    }
}
