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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @notice ADR-0004 — split-phase bond records for exact-output.
///
/// @dev WHAT THIS SUITE GUARDS. The exact-output record header is written in `beforeSwap` and
///      either finalized or cleared in `afterSwap`. That means a half-written record exists in
///      storage mid-transaction, which is only safe because ADR-0004 Rule 1 makes it semantically
///      invisible. These tests pin that invisibility, the warm finalize, the clear, and the
///      id-derivation assumption the split depends on.
contract SplitPhaseBondRecordsTest is Test, Deployers {
    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);
    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;

    /// @dev Settlement noise floor, in ticks. Displacement at or below this is never slashed.
    uint16 internal constant REFUND_TOL = 5;
    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    uint128 internal constant BONDED_OUTPUT = 1e16;
    uint128 internal constant UNBONDED_OUTPUT = 1e13;

    /// @dev `bonds` mapping slot, and the byte offset of `Bond.state` within struct slot 1.
    ///      Both derived from `forge inspect BondMeBro storage-layout`, never by hand.
    uint256 internal constant BONDS_SLOT = 3;
    /// @dev Byte offset of `Bond.state` within the record's second slot.
    ///
    ///      MOVED FROM 30 TO 23 IN P-L2-7: removing `cumulativeAtOpen` (an `int56`) freed seven
    ///      bytes from the middle of slot 1 and shifted `state` down with everything above it.
    ///      `test/StorageLayout.t.sol` is the authority and fails first if it moves again.
    uint256 internal constant STATE_BYTE_OFFSET = 25;

    uint8 internal constant STATE_NONE = 0;
    uint8 internal constant STATE_PROVISIONAL = 1;
    uint8 internal constant STATE_FINALIZED = 2;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));
        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));
        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        // Reduced from 1e21 in P-L2-3/4. Model L bonds nothing when a swap moves no whole tick,
        // and at 1e21 the swaps in this file moved one tick at best -- so several of them landed
        // on zero impact and produced no record at all, which this suite reads as "bond missing".
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e19, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _swap(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
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
    }

    function _validHookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /// @dev Mirrors the contract's id derivation. Deliberately duplicated rather than exposed from
    ///      production, so a change to the scheme has to be made in two places on purpose.
    function _expectedBondId(uint32 maturityBlock, uint32 indexInBucket) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, indexInBucket));
    }

    function _maturityOfNow() internal view returns (uint32) {
        return uint32(block.number) + hook.OBSERVATION_BLOCKS();
    }

    /// @dev Reads `Bond.state` straight from storage.
    ///
    ///      ADR-0004 Rule 1 makes a provisional record indistinguishable from an absent one
    ///      through the SUPPORTED read API — `getBond` reverts identically for both. That is the
    ///      property under test, so verifying the physical state needs raw storage access, which
    ///      the ADR explicitly places outside the semantic guarantee.
    function _rawState(bytes32 bondId) internal view returns (uint8) {
        bytes32 base = keccak256(abi.encode(bondId, BONDS_SLOT));
        bytes32 word = vm.load(address(hook), bytes32(uint256(base) + 1));

        return uint8(uint256(word) >> (STATE_BYTE_OFFSET * 8));
    }

    /*//////////////////////////////////////////////////////////////
              RULE 1 — provisional is indistinguishable from absent
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-PROVISIONAL (a): no record is left PROVISIONAL once the transaction ends.
    /// @dev The bonded branch must finalize.
    function test_invProvisional_bondedSwapLeavesNoProvisional() public {
        bytes32 bondId = _expectedBondId(_maturityOfNow(), 0);

        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        assertEq(_rawState(bondId), STATE_FINALIZED, "bonded exact-output did not finalize its record");
        assertTrue(hook.bondExists(bondId), "finalized bond is not visible");
    }

    /// @notice INV-PROVISIONAL (a) on the unbonded branch: the record must be CLEARED, leaving
    ///         `NONE` — the same state as never having existed.
    function test_invProvisional_unbondedSwapClearsTheRecord() public {
        bytes32 bondId = _expectedBondId(_maturityOfNow(), 0);

        _swap(int256(uint256(UNBONDED_OUTPUT)), true, _validHookData());

        assertEq(_rawState(bondId), STATE_NONE, "unbonded exact-output left a record behind");
        assertFalse(hook.bondExists(bondId), "cleared record is still visible");
    }

    /// @notice INV-PROVISIONAL (a) after a revert: atomicity must unwind the provisional write.
    /// @dev The bond ceiling is set one wei too low, so `afterSwap` reverts after `beforeSwap`
    ///      has already written the header.
    function test_invProvisional_revertedSwapLeavesNoProvisional() public {
        bytes32 bondId = _expectedBondId(_maturityOfNow(), 0);

        // Probe the real bond, then rewind, so the ceiling can sit exactly one wei below it.
        uint256 snap = vm.snapshotState();
        uint256 hookBefore = currency0.balanceOf(address(hook));
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());
        uint256 bond = currency0.balanceOf(address(hook)) - hookBefore;
        vm.revertToState(snap);

        vm.expectRevert();
        _swap(int256(uint256(BONDED_OUTPUT)), true, HookDataCodec.encode(TRADER, uint128(bond - 1)));

        assertEq(_rawState(bondId), STATE_NONE, "a reverted swap left a provisional record behind");
    }

    /// @notice Rule 1: the supported read API reports a provisional record as ABSENT, and does not
    ///         distinguish it from a never-existent id.
    /// @dev Both must revert with the same error and the same argument shape.
    function test_rule1_getBondRejectsProvisionalIdenticallyToAbsent() public {
        bytes32 neverExisted = keccak256("no such bond");
        bytes32 provisionalId = _expectedBondId(_maturityOfNow(), 0);

        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotFound.selector, neverExisted));
        hook.getBond(neverExisted);

        // Same id, before any swap has created it: also absent.
        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotFound.selector, provisionalId));
        hook.getBond(provisionalId);

        assertFalse(hook.bondExists(neverExisted));
        assertFalse(hook.bondExists(provisionalId));
    }

    /// @notice Rule 3 / INV-PENDING-FINALIZED: `pendingBonds` counts FINALIZED bonds only. An
    ///         unbonded exact-output swap writes and clears a provisional record and must leave
    ///         the counter untouched.
    /// @dev This is the cheapest sentinel for the whole design: if a provisional record ever
    ///      leaked into the count, this fails.
    function test_rule3_pendingBondsCountsFinalizedOnly() public {
        uint32 m = _maturityOfNow();

        (,,, uint32 pendingBefore,) = hook.maturity(id_, m);
        assertEq(pendingBefore, 0, "bucket did not start empty");

        // Unbonded: provisional written and cleared. Counter must not move.
        _swap(int256(uint256(UNBONDED_OUTPUT)), true, _validHookData());

        (,,, uint32 pendingAfterUnbonded,) = hook.maturity(id_, m);
        assertEq(pendingAfterUnbonded, 0, "an unbonded swap incremented pendingBonds");

        // Bonded: finalized. Counter moves by exactly one.
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        (,,, uint32 pendingAfterBonded,) = hook.maturity(id_, m);
        assertEq(pendingAfterBonded, 1, "a finalized bond did not increment pendingBonds by one");
    }

    /// @notice Registration must not touch the checkpoint. ADR-0003 § 5.1, unchanged by ADR-0004.
    function test_registrationDoesNotCheckpoint() public {
        uint32 m = _maturityOfNow();

        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        (,, int56 cumulative, uint32 pending, uint8 checkpointedMask) = hook.maturity(id_, m);

        bool checkpointed = checkpointedMask & hook.FROZEN_C10() != 0;

        assertEq(pending, 1, "bond was not registered");
        assertFalse(checkpointed, "registration marked the checkpoint frozen");
        assertEq(cumulative, int56(0), "registration wrote the maturity cumulative");
    }

    /*//////////////////////////////////////////////////////////////
                        RECORD CONTENT & IMMUTABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice The finalized record binds every field T5B needs, from the swap itself.
    /// @dev None of these may come from caller-supplied settlement arguments later.
    function test_finalizedRecord_bindsAllRequiredFields() public {
        uint32 openBlock = uint32(block.number);
        uint32 m = _maturityOfNow();
        bytes32 bondId = _expectedBondId(m, 0);

        uint256 hookBefore = currency0.balanceOf(address(hook));
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());
        uint256 actualBond = currency0.balanceOf(address(hook)) - hookBefore;

        BondMeBro.Bond memory bond = hook.getBond(bondId);

        assertEq(bond.refundRecipient, TRADER, "refund recipient not bound");
        assertEq(bond.openBlock, openBlock, "open block not bound");
        assertEq(bond.maturityBlock, m, "maturity not bound");
        assertEq(
            uint256(hook.collateralAmountOf(bondId)),
            actualBond,
            "recomputed collateral does not match the collateral taken"
        );
        // EXACT-OUTPUT zeroForOne. The specified leg is the output, so the VARIABLE leg is the
        // input -- currency0. This is the half of the migration that did NOT change currencies:
        // exact-output collateral came from the input before and still does. It changed reason,
        // not side, and stating the reason is what stops the next reader from "fixing" it to
        // match the exact-input case two tests below.
        assertTrue(bond.collateralIsCurrency0, "exact-output zeroForOne collateral must be currency0 (the input)");
        assertGt(bond.poolIndex, 0, "pool identity not bound");
        assertEq(uint8(bond.state), STATE_FINALIZED, "record is not finalized");

        // The observation window's opening reading, and both ticks.
        assertEq(bond.tickBefore, int24(0), "tickBefore should be the pool's pre-swap tick");
        assertLt(bond.tickAfter, bond.tickBefore, "zeroForOne should have moved the tick down");
    }

    /// @notice A finalized record is immutable across later swaps.
    function test_finalizedRecord_immutableAcrossLaterSwaps() public {
        bytes32 bondId = _expectedBondId(_maturityOfNow(), 0);

        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        BondMeBro.Bond memory before = hook.getBond(bondId);

        vm.roll(block.number + 3);
        _swap(-1e16, true, _validHookData());
        _swap(int256(uint256(BONDED_OUTPUT)), false, _validHookData());

        BondMeBro.Bond memory afterLater = hook.getBond(bondId);

        assertEq(afterLater.variableLegAmount, before.variableLegAmount, "variable leg changed");
        assertEq(afterLater.maturityBlock, before.maturityBlock, "maturity changed");
        assertEq(afterLater.tickAfter, before.tickAfter, "tickAfter changed");
        assertEq(afterLater.refundRecipient, before.refundRecipient, "recipient changed");

        // `cumulativeAtOpen` was asserted here until P-L2-7 removed it from `Bond`. Model L2
        // measures every late window against `tickBefore`, not against an opening cumulative, so
        // the field had become write-only. `tickBefore` carries the immutability claim now.
        assertEq(afterLater.tickBefore, before.tickBefore, "opening tick changed");
        assertEq(afterLater.collateralIsCurrency0, before.collateralIsCurrency0, "collateral currency changed");
    }

    /// @notice Exact-input still creates its record in one phase, never provisionally.
    /// @dev ADR-0004 § 6 — the asymmetry is intentional. If exact-input ever started writing a
    ///      provisional header, this would catch it.
    function test_exactInput_neverWritesProvisional() public {
        bytes32 bondId = _expectedBondId(_maturityOfNow(), 0);

        _swap(-1e16, true, _validHookData());

        assertEq(_rawState(bondId), STATE_FINALIZED, "exact-input record is not finalized in one phase");
    }

    /// @notice An unbonded exact-input swap creates no record at all.
    function test_unbondedExactInput_createsNoRecord() public {
        bytes32 bondId = _expectedBondId(_maturityOfNow(), 0);

        _swap(-1e13, true, "");

        assertEq(_rawState(bondId), STATE_NONE, "unbonded exact-input created a record");
    }

    /*//////////////////////////////////////////////////////////////
            SAME-BLOCK ID DERIVATION — the split's key assumption
    //////////////////////////////////////////////////////////////*/

    /// @notice Two bonded exact-output swaps in the SAME block get distinct ids and distinct
    ///         records.
    ///
    /// @dev THE ASSUMPTION THE SPLIT DEPENDS ON (ADR-0004 § 11). The id derives from
    ///      `pendingBonds`, which is now incremented only at finalization — so `beforeSwap` and
    ///      `afterSwap` of one swap must see the same value, and a second swap in the same block
    ///      must see the incremented one. If callbacks could interleave, both swaps would compute
    ///      the same id and the second would overwrite the first.
    function test_sameBlock_twoBondedExactOutputSwaps_getDistinctRecords() public {
        uint32 m = _maturityOfNow();
        bytes32 first = _expectedBondId(m, 0);
        bytes32 second = _expectedBondId(m, 1);

        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        assertTrue(hook.bondExists(first), "first bond missing");
        assertTrue(hook.bondExists(second), "second bond missing");
        assertTrue(first != second, "two same-block bonds share an id");

        (,,, uint32 pending,) = hook.maturity(id_, m);
        assertEq(pending, 2, "pendingBonds does not reflect both bonds");

        // Both records are intact — the second did not overwrite the first.
        assertGt(hook.getBond(first).variableLegAmount, 0, "first bond has no variable leg");
        assertGt(hook.getBond(second).variableLegAmount, 0, "second bond has no variable leg");
    }

    /// @notice ID REUSE AFTER AN UNBONDED CLEAR. An unbonded swap writes provisional id N and
    ///         clears it without incrementing; the NEXT swap in the same block legitimately
    ///         reuses id N.
    ///
    /// @dev Explicitly required by ADR-0004 § 11. This is the case where a stale provisional
    ///      record, if it had survived, would be silently overwritten by a real bond — or worse,
    ///      would make the real bond appear to already exist.
    function test_sameBlock_unbondedThenBonded_reusesTheClearedId() public {
        uint32 m = _maturityOfNow();
        bytes32 reusedId = _expectedBondId(m, 0);

        // Unbonded first: writes provisional id 0, clears it, leaves pendingBonds at 0.
        _swap(int256(uint256(UNBONDED_OUTPUT)), true, _validHookData());

        assertEq(_rawState(reusedId), STATE_NONE, "unbonded swap left id 0 occupied");
        (,,, uint32 pendingAfterUnbonded,) = hook.maturity(id_, m);
        assertEq(pendingAfterUnbonded, 0, "unbonded swap moved the counter");

        // Bonded second, same block: takes the same index 0, and must own it cleanly.
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        assertEq(_rawState(reusedId), STATE_FINALIZED, "reused id is not finalized");
        assertGt(hook.getBond(reusedId).variableLegAmount, 0, "reused record has no variable leg");

        (,,, uint32 pendingAfterBonded,) = hook.maturity(id_, m);
        assertEq(pendingAfterBonded, 1, "reused id did not register exactly once");
    }

    /// @notice Mixed swap kinds in one block share the bucket's index sequence without collision.
    function test_sameBlock_exactInputAndExactOutput_getDistinctRecords() public {
        uint32 m = _maturityOfNow();

        _swap(-1e16, true, _validHookData()); // exact-input  -> index 0
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData()); // exact-output -> index 1

        assertTrue(hook.bondExists(_expectedBondId(m, 0)), "exact-input bond missing");
        assertTrue(hook.bondExists(_expectedBondId(m, 1)), "exact-output bond missing");

        (,,, uint32 pending,) = hook.maturity(id_, m);
        assertEq(pending, 2, "mixed same-block bonds did not both register");
    }

    /// @notice Bonds in different blocks land in different buckets, so ids cannot collide.
    function test_differentBlocks_getDistinctRecords() public {
        uint32 m1 = _maturityOfNow();
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        vm.roll(block.number + 1);

        uint32 m2 = _maturityOfNow();
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());

        assertTrue(m1 != m2, "fixture did not advance the maturity block");
        assertTrue(hook.bondExists(_expectedBondId(m1, 0)), "first-block bond missing");
        assertTrue(hook.bondExists(_expectedBondId(m2, 0)), "second-block bond missing");
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev End-to-end totals for the § 7 unbonded-path requirement. `forge test`'s reported gas
    ///      is whole-transaction, which is the only level at which a refund is visible.
    function test_gas_e2e_exactOutputUnbonded() public {
        _swap(int256(uint256(UNBONDED_OUTPUT)), true, _validHookData());
    }

    function test_gas_e2e_exactOutputBonded() public {
        _swap(int256(uint256(BONDED_OUTPUT)), true, _validHookData());
    }
}
