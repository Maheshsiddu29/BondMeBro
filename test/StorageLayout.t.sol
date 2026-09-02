// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title StorageLayoutTest
///
/// @notice Pins BondMeBro's storage layout: the top-level slot assignments, and the packing of the
///         two structs whose size is a design commitment rather than an accident.
///
/// @dev WHY A TEST AND NOT JUST A COMMENT.
///
///      Two separate things are being protected here, and they fail in different ways.
///
///      1. THE PACKING IS A GAS COMMITMENT. `Bond` fits in exactly two slots and `PoolConfig` in
///         one. Those are load-bearing for the callback gas ceilings: a `Bond` that spilled into a
///         third slot would add a cold SSTORE to every bonded swap, on a path budgeted at under
///         100,000 gas. Solidity packs silently, so reordering two fields or widening one by a
///         byte can cost 20,000 gas per swap with no diagnostic at all.
///
///      2. THE SLOT ASSIGNMENTS ARE READ BY TESTS. Several suites reach into storage directly --
///         `vm.load` to observe a PROVISIONAL record that ADR-0004 Rule 1 deliberately hides from
///         every public reader, and `vm.store` for configurations the owner-facing setter refuses.
///         Those tests compute slots from the numbers pinned here. If a state variable were
///         inserted above them, those tests would silently read the wrong slot and start asserting
///         nothing, which is the worst possible outcome for a test whose whole job is to catch a
///         stranded record.
///
///      P-L2-3/4 RENAMED TWO `Bond` FIELDS in place -- `amount` to `variableLegAmount` and
///      `inputIsCurrency0` to `collateralIsCurrency0` -- keeping both widths and both offsets
///      identical. This file is what makes "identical" a checked claim rather than an intention.
contract StorageLayoutTest is Test, Deployers {
    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;
    uint16 internal constant REFUND_TOL = 5;

    /*//////////////////////////////////////////////////////////////
                       THE PINNED SLOT NUMBERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Top-level slot assignments, from `forge inspect BondMeBro storage-layout`.
    uint256 internal constant SLOT_POOL_CONFIG = 0;
    uint256 internal constant SLOT_AFTER_INITIALIZE_COUNT = 1;
    uint256 internal constant SLOT_ACCUMULATOR = 2;
    uint256 internal constant SLOT_MATURITY = 3;
    uint256 internal constant SLOT_BONDS = 4;
    uint256 internal constant SLOT_POOL_REF_BY_INDEX = 5;
    uint256 internal constant SLOT_POOL_INDEX_OF = 6;
    uint256 internal constant SLOT_POOL_COUNT = 7;
    uint256 internal constant SLOT_INSURANCE_POT = 8;

    /// @dev Byte offset of `Bond.state` within the record's SECOND slot.
    ///
    ///      `variableLegAmount` 16 + `cumulativeAtOpen` 7 + `tickBefore` 3 + `tickAfter` 3 +
    ///      `collateralIsCurrency0` 1 = 30, so `state` starts at byte 30 and the slot uses 31 of
    ///      its 32 bytes. The spare byte is headroom, not waste: one more `uint8` could be added
    ///      to a `Bond` without costing a slot.
    uint256 internal constant BOND_STATE_BYTE_OFFSET = 30;

    /// @dev Byte offset of `Bond.collateralIsCurrency0` within the second slot.
    uint256 internal constant BOND_CURRENCY_FLAG_BYTE_OFFSET = 29;

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
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e19, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The storage slot holding a bond record's FIRST word.
    function bondSlot(bytes32 bondId) public pure returns (bytes32) {
        return keccak256(abi.encode(bondId, SLOT_BONDS));
    }

    function _bondIdAt(uint32 maturityBlock, uint32 index) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, index));
    }

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

    /*//////////////////////////////////////////////////////////////
                          TOP-LEVEL SLOTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Each mapping is where the pinned constants say it is.
    ///
    /// @dev Proven by WRITING through the public interface and READING back through `vm.load` at
    ///      the computed slot -- not by re-deriving the layout, which would only restate the
    ///      compiler's own answer. If a state variable is inserted above any of these, the value
    ///      read here comes back as zero and the test fails on the variable that moved.
    function test_topLevelSlots_areWhereTheyArePinned() public {
        // `poolConfig` at slot 0. The packed word is min0 (16) | min1 (12) | bps (2) | tol (2).
        bytes32 cfgWord = vm.load(address(hook), keccak256(abi.encode(id_, SLOT_POOL_CONFIG)));

        assertEq(uint128(uint256(cfgWord)), MIN_BONDED, "poolConfig.minBondedAmount0 is not at slot 0 offset 0");

        assertEq(
            uint96(uint256(cfgWord) >> 128), MIN_BONDED_1, "poolConfig.minBondedAmount1 is not at slot 0 offset 16"
        );

        assertEq(uint16(uint256(cfgWord) >> 224), BOND_BPS, "poolConfig.bondBps is not at slot 0 offset 28");

        assertEq(
            uint16(uint256(cfgWord) >> 240), REFUND_TOL, "poolConfig.refundToleranceTicks is not at slot 0 offset 30"
        );

        // `afterInitializeCount` at slot 1, a plain uint256.
        assertEq(
            uint256(vm.load(address(hook), bytes32(SLOT_AFTER_INITIALIZE_COUNT))),
            hook.afterInitializeCount(),
            "afterInitializeCount is not at slot 1"
        );

        // `poolCount` at slot 7, low four bytes.
        assertEq(
            uint32(uint256(vm.load(address(hook), bytes32(SLOT_POOL_COUNT)))),
            hook.poolCount(),
            "poolCount is not at slot 7 offset 0"
        );

        // `poolIndexOf` at slot 6.
        assertEq(
            uint32(uint256(vm.load(address(hook), keccak256(abi.encode(id_, SLOT_POOL_INDEX_OF))))),
            hook.poolIndexOf(id_),
            "poolIndexOf is not at slot 6"
        );

        // `insurancePot` at slot 8, a nested mapping.
        bytes32 potSlot = keccak256(abi.encode(currency0, keccak256(abi.encode(id_, SLOT_INSURANCE_POT))));

        assertEq(
            uint256(vm.load(address(hook), potSlot)), hook.insurancePot(id_, currency0), "insurancePot is not at slot 8"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            BOND PACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice A `Bond` occupies exactly two slots, with every field where the design says.
    ///
    /// @dev Read back field by field from raw storage after a real bonded swap, so the assertion
    ///      is about the bytes the EVM actually wrote rather than about a struct definition.
    ///
    ///      The third slot is asserted EMPTY. That is the gas commitment: a `Bond` that spilled
    ///      into a third slot would add a cold SSTORE to every bonded swap. Nothing in the type
    ///      system prevents that spill, and nothing else in the suite would notice it -- every
    ///      behavioural test would keep passing, only more expensively.
    function test_bondRecord_packsIntoExactlyTwoSlots() public {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        bytes32 bondId = _bondIdAt(m, 0);

        _swap(-1e16, true, HookDataCodec.encode(TRADER, type(uint128).max));

        BondMeBro.Bond memory bond = hook.getBond(bondId);

        bytes32 base = bondSlot(bondId);

        uint256 word0 = uint256(vm.load(address(hook), base));
        uint256 word1 = uint256(vm.load(address(hook), bytes32(uint256(base) + 1)));
        uint256 word2 = uint256(vm.load(address(hook), bytes32(uint256(base) + 2)));

        // SLOT 0 -- address 20 + uint32 4 + uint32 4 + uint32 4 = 32 bytes, exactly full.
        assertEq(address(uint160(word0)), bond.refundRecipient, "refundRecipient is not at slot 0 offset 0");
        assertEq(uint32(word0 >> 160), bond.openBlock, "openBlock is not at slot 0 offset 20");
        assertEq(uint32(word0 >> 192), bond.maturityBlock, "maturityBlock is not at slot 0 offset 24");
        assertEq(uint32(word0 >> 224), bond.poolIndex, "poolIndex is not at slot 0 offset 28");

        // SLOT 1 -- uint128 16 + int56 7 + int24 3 + int24 3 + bool 1 + enum 1 = 31 bytes.
        assertEq(uint128(word1), bond.variableLegAmount, "variableLegAmount is not at slot 1 offset 0");
        assertEq(int56(uint56(word1 >> 128)), bond.cumulativeAtOpen, "cumulativeAtOpen is not at slot 1 offset 16");
        assertEq(int24(uint24(word1 >> 184)), bond.tickBefore, "tickBefore is not at slot 1 offset 23");
        assertEq(int24(uint24(word1 >> 208)), bond.tickAfter, "tickAfter is not at slot 1 offset 26");

        assertEq(
            uint8(word1 >> (8 * BOND_CURRENCY_FLAG_BYTE_OFFSET)) & 0xFF,
            bond.collateralIsCurrency0 ? 1 : 0,
            "collateralIsCurrency0 is not at slot 1 offset 29"
        );

        assertEq(
            uint8(word1 >> (8 * BOND_STATE_BYTE_OFFSET)) & 0xFF, uint8(bond.state), "state is not at slot 1 offset 30"
        );

        // THE COMMITMENT.
        assertEq(word2, 0, "a Bond spilled into a THIRD slot: every bonded swap now pays an extra cold SSTORE");
    }

    /// @notice The renamed fields kept their exact widths and offsets.
    ///
    /// @dev P-L2-3/4 renamed `amount` to `variableLegAmount` and `inputIsCurrency0` to
    ///      `collateralIsCurrency0`. Both were pure renames -- the MEANING changed, the layout did
    ///      not -- and this pins that claim by writing a known bit pattern into the record and
    ///      reading it back through the struct.
    ///
    ///      A rename that silently widened a field would move everything above it, and the two
    ///      tick fields are the ones that would suffer: `tickBefore` and `tickAfter` feed the
    ///      collateral recomputation, so a one-byte shift would corrupt the rate rather than
    ///      produce an obviously wrong value.
    function test_renamedFields_keptTheirWidthsAndOffsets() public {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        bytes32 bondId = _bondIdAt(m, 0);

        _swap(-1e16, true, HookDataCodec.encode(TRADER, type(uint128).max));

        bytes32 slot1 = bytes32(uint256(bondSlot(bondId)) + 1);

        uint256 original = uint256(vm.load(address(hook), slot1));

        // Overwrite ONLY the 16 bytes `variableLegAmount` is supposed to occupy, leaving every
        // other field's bits untouched, then confirm exactly that field changed.
        uint256 probe = 0x0123456789ABCDEF0123456789ABCDEF;

        uint256 rewritten = (original & ~uint256(type(uint128).max)) | probe;

        vm.store(address(hook), slot1, bytes32(rewritten));

        BondMeBro.Bond memory after_ = hook.getBond(bondId);

        assertEq(after_.variableLegAmount, uint128(probe), "variableLegAmount does not occupy bytes 0-15 of slot 1");

        // Everything else must be exactly as before, which is what proves the write was confined.
        BondMeBro.Bond memory expected = _decodeSlot1(original);

        assertEq(after_.cumulativeAtOpen, expected.cumulativeAtOpen, "cumulativeAtOpen moved");
        assertEq(after_.tickBefore, expected.tickBefore, "tickBefore moved");
        assertEq(after_.tickAfter, expected.tickAfter, "tickAfter moved");
        assertEq(after_.collateralIsCurrency0, expected.collateralIsCurrency0, "collateralIsCurrency0 moved");
        assertEq(uint8(after_.state), uint8(expected.state), "state moved");
    }

    /// @dev Decodes the fields of a `Bond`'s second slot from a raw word, by the pinned offsets.
    function _decodeSlot1(uint256 word) internal pure returns (BondMeBro.Bond memory bond) {
        bond.variableLegAmount = uint128(word);
        bond.cumulativeAtOpen = int56(uint56(word >> 128));
        bond.tickBefore = int24(uint24(word >> 184));
        bond.tickAfter = int24(uint24(word >> 208));
        bond.collateralIsCurrency0 = (uint8(word >> (8 * BOND_CURRENCY_FLAG_BYTE_OFFSET)) & 0xFF) != 0;
        bond.state = BondMeBro.BondState(uint8(word >> (8 * BOND_STATE_BYTE_OFFSET)) & 0xFF);
    }

    /*//////////////////////////////////////////////////////////////
                      POOL CONFIG AND CHECKPOINT
    //////////////////////////////////////////////////////////////*/

    /// @notice `PoolConfig` occupies exactly one slot.
    ///
    /// @dev Read on the swap path in both callbacks, so a spill would cost a second SLOAD on every
    ///      swap the hook sees -- bonded or not.
    ///
    ///      This also replaces the incidental layout coverage that the deleted `_forceBondBps`
    ///      helper in `BondCustody.t.sol` used to provide: it wrote this packed word directly and
    ///      read it back through the public getter, catching a layout change as a side effect of
    ///      testing something else. That helper became inert when Model L stopped reading
    ///      `bondBps` as a rate, so the check belongs here instead, stated as its own claim.
    function test_poolConfig_packsIntoExactlyOneSlot() public view {
        bytes32 base = keccak256(abi.encode(id_, SLOT_POOL_CONFIG));

        assertEq(
            uint256(vm.load(address(hook), bytes32(uint256(base) + 1))),
            0,
            "PoolConfig spilled into a second slot: every swap now pays an extra SLOAD"
        );

        (uint128 min0, uint96 min1, uint16 bps, uint16 tol) = hook.poolConfig(id_);

        uint256 word = uint256(vm.load(address(hook), base));

        assertEq(uint128(word), min0, "minBondedAmount0 offset");
        assertEq(uint96(word >> 128), min1, "minBondedAmount1 offset");
        assertEq(uint16(word >> 224), bps, "bondBps offset");
        assertEq(uint16(word >> 240), tol, "refundToleranceTicks offset");
    }

    /// @notice `MaturityCheckpoint` occupies exactly one slot.
    ///
    /// @dev The checkpoint is written on the settlement path and read on every swap that crosses a
    ///      maturity, so its single-slot packing is the premise of ADR-0007's cost argument.
    function test_maturityCheckpoint_packsIntoExactlyOneSlot() public {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        _swap(-1e16, true, HookDataCodec.encode(TRADER, type(uint128).max));

        bytes32 base = keccak256(abi.encode(uint256(m), keccak256(abi.encode(id_, SLOT_MATURITY))));

        (int56 cumulative, uint32 pending, bool checkpointed) = hook.maturity(id_, m);

        uint256 word = uint256(vm.load(address(hook), base));

        assertEq(int56(uint56(word)), cumulative, "MaturityCheckpoint.cumulative is not at offset 0");
        assertEq(uint32(word >> 56), pending, "MaturityCheckpoint.pendingBonds is not at offset 7");
        assertEq((uint8(word >> 88) & 0xFF) != 0, checkpointed, "MaturityCheckpoint.checkpointed is not at offset 11");

        assertEq(
            uint256(vm.load(address(hook), bytes32(uint256(base) + 1))),
            0,
            "MaturityCheckpoint spilled into a second slot"
        );

        assertGt(pending, 0, "the fixture registered no bond, so nothing was actually read back");
    }
}
