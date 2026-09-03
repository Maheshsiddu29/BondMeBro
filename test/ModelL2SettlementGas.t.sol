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

/// @title ModelL2SettlementGasTest
///
/// @notice Settlement cost under Model L2, by outcome.
///
/// @dev SETTLEMENT HAS NO CALLBACK CEILING — it is a standalone permissionless transaction, not a
///      swap hook — so these are reported as practical costs rather than measured against a limit.
///      What matters is that they stay in the range a keeper or a trader will actually pay, and
///      that no outcome is pathologically more expensive than the others.
///
///      WHY THE OUTCOMES ARE SPLIT. The three settlement outcomes touch different storage:
///
///        full refund   — no pot write at all, one ERC-20 transfer
///        full slash    — a pot write, and NO transfer (the refund is zero)
///        partial slash — both, and it is the only path that pays for both
///
///      A single "settlement gas" figure would hide a factor of two between them.
///
///      MEASURED AT P-L2-6, as `settleBond` / `settleMany` CALL FRAMES, against the P-L2-5
///      baseline for the same shape:
///
///          outcome                        P-L2-6     P-L2-5     delta
///          ----------------------------   --------   --------   -------
///          full refund                      43,077     41,979    +1,098
///          full slash                       40,331     39,286    +1,045
///          partial slash                    65,716          -         -
///          dead-zone refund                 43,062          -         -
///          quiet, derive and freeze x3      45,849     42,338    +3,511
///          late settlement (M+10,000)       40,331          -         -
///          settleMany(1)                    40,653          -         -
///          settleMany(10)                  150,392          -         -
///          settleMany(32)                  418,657    385,548   +33,109
///
///      THE DELTA IS ~1,040 GAS PER SETTLEMENT, and it is the price of reading three endpoints
///      instead of one. They come out of a single already-loaded slot, so the cost is masking and
///      shifting rather than SLOADs — which is exactly what ADR-0007's one-slot bucket was for.
///
///      THE QUIET PATH IS THE EXCEPTION, at +3,511. On a silent pool nothing is frozen, so
///      settlement derives and freezes all three endpoints itself where it previously derived and
///      froze one. That is three writes into the bucket instead of one. It is paid once per BUCKET
///      rather than once per bond, and a bond settling into an already-frozen bucket pays none of
///      it — `settleMany(32)`'s +33,109 is +1,035 per bond, not +3,511.
///
///      PARTIAL SLASH IS THE MOST EXPENSIVE SINGLE OUTCOME at 65,716, and that is storage rather
///      than arithmetic: it is the only path that both credits the insurance pot (a cold write on
///      the first slash in a currency) AND transfers a refund. Full slash skips the transfer; full
///      refund skips the pot.
///
///      P-L2-7 RE-MEASURED: the figures above are pre-cleanup. After removing `cumulativeAtOpen`,
///      `PersistenceMathLib`, `afterInitializeCount` and the two obsolete `PoolConfig` fields,
///      `beforeSwap` fell by 127 gas everywhere and `afterSwap` rose by a uniform 222. The
///      worst-case `beforeSwap` is now 106,878 against a 150,000 ceiling; the worst `afterSwap`
///      73,447 against 100,000. See `P_L2_7_MIGRATION_REPORT.md` § 7 for the full table and for
///      what the +222 is and is not attributable to.
contract ModelL2SettlementGasTest is Test, Deployers {
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

    int128 internal constant POOL_LIQUIDITY = 1e19;

    int256 internal constant BONDED = -1e16;
    int256 internal constant NUDGE = -1e13;

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
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
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

    function _bondIdAt(uint32 maturityBlock, uint32 index) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, index));
    }

    /// @dev Opens one bond and returns its id, opening block and maturity.
    function _open(int256 amount) internal returns (bytes32 bondId, uint32 openBlock, uint32 m) {
        openBlock = uint32(block.number);
        m = openBlock + hook.OBSERVATION_BLOCKS();
        bondId = _bondIdAt(m, 0);

        _swap(amount, true, _hookData());
    }

    /*//////////////////////////////////////////////////////////////
                         THE THREE OUTCOMES
    //////////////////////////////////////////////////////////////*/

    /// @dev Full refund: the price reverts, nothing is slashed, one transfer.
    function test_gasL2_settle_fullRefund() public {
        (bytes32 bondId, uint32 openBlock, uint32 m) = _open(BONDED);

        vm.roll(uint256(openBlock) + 1);
        _swap(-4e16, false, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);
    }

    /// @dev Full slash: the displacement persists, the pot is credited, NO transfer.
    function test_gasL2_settle_fullSlash() public {
        (bytes32 bondId,, uint32 m) = _open(BONDED);

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);
    }

    /// @dev Partial slash: the only outcome that pays for BOTH a pot write and a transfer.
    function test_gasL2_settle_partialSlash() public {
        (bytes32 bondId, uint32 openBlock, uint32 m) = _open(BONDED);

        vm.roll(uint256(openBlock) + 3);
        _swap(-7e15, false, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);
    }

    /// @dev Dead-zone refund: a small persistent displacement, refunded in full because of its
    ///      SIZE rather than because it reverted. Same storage shape as a full refund, and
    ///      measured separately because it is the outcome most real traders will see.
    function test_gasL2_settle_deadZoneRefund() public {
        (bytes32 bondId,, uint32 m) = _open(-int256(uint256(MIN_BONDED) * 2));

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);
    }

    /*//////////////////////////////////////////////////////////////
                        QUIET AND LATE PATHS
    //////////////////////////////////////////////////////////////*/

    /// @dev Quiet settlement: NOTHING is frozen, so settlement derives and freezes all three
    ///      endpoints itself. The most expensive single settlement, and the shape that moved most
    ///      between P-L2-5 and P-L2-6 — three cold-slot writes where there was previously one.
    function test_gasL2_settle_quietDeriveAndFreezeAllThree() public {
        (bytes32 bondId,, uint32 m) = _open(BONDED);

        // Total silence: no swap crosses any endpoint.
        vm.roll(uint256(m) + 5);

        hook.settleBond(bondId);
    }

    /// @dev Late settlement, 10,000 blocks past maturity, with the endpoints already frozen. Must
    ///      cost the same as settling at M+1: the answer comes from frozen state, not live state.
    function test_gasL2_settle_lateByTenThousandBlocks() public {
        (bytes32 bondId,, uint32 m) = _open(BONDED);

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        vm.roll(uint256(m) + 10_000);

        hook.settleBond(bondId);
    }

    /// @notice Late settlement costs the same as prompt settlement.
    ///
    /// @dev Asserted rather than left to a reader comparing two printed numbers. If settling later
    ///      were cheaper, a keeper would be incentivised to wait; if dearer, to race. Neither
    ///      should be true — the frozen endpoints make the work identical.
    function test_lateSettlementCostsTheSameAsPromptSettlement() public {
        uint256 baseline = vm.snapshotState();

        uint256 prompt = _measureSettleAfter(1);

        vm.revertToState(baseline);

        uint256 late = _measureSettleAfter(10_000);

        console2.log("settle at M+1     ", prompt);
        console2.log("settle at M+10,000", late);

        assertEq(prompt, late, "settlement cost moved with how long the caller waited");
    }

    function _measureSettleAfter(uint32 delay) internal returns (uint256) {
        (bytes32 bondId,, uint32 m) = _open(BONDED);

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        if (delay > 1) vm.roll(uint256(m) + delay);

        uint256 before = gasleft();

        hook.settleBond(bondId);

        return before - gasleft();
    }

    /*//////////////////////////////////////////////////////////////
                                BATCH
    //////////////////////////////////////////////////////////////*/

    function test_gasL2_settleMany_1() public {
        _measureBatch(1);
    }

    function test_gasL2_settleMany_10() public {
        _measureBatch(10);
    }

    function test_gasL2_settleMany_32() public {
        _measureBatch(32);
    }

    /// @dev A batch of `n` bonds, all sharing one maturity bucket, all endpoints already frozen.
    ///
    ///      Sharing a bucket is the realistic and the cheap case: the three endpoints are a
    ///      property of the POOL, so they are read once and every bond in the batch reuses them.
    function _measureBatch(uint32 n) internal {
        uint32 openBlock = uint32(block.number);
        uint32 m = openBlock + hook.OBSERVATION_BLOCKS();

        bytes32[] memory ids = new bytes32[](n);

        for (uint32 i = 0; i < n; i++) {
            ids[i] = _bondIdAt(m, i);

            _swap(BONDED, true, _hookData());
        }

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleMany(ids);
    }

    /// @notice Per-bond batch cost does not grow with batch size.
    ///
    /// @dev The property that makes `settleMany` worth having. If per-bond cost rose with `n`, the
    ///      `MAX_SETTLE_BATCH` cap of 32 would be hiding a quadratic rather than bounding a linear.
    function test_batchCostIsLinearInBondCount() public {
        uint256 baseline = vm.snapshotState();

        uint256 one = _measureBatchGas(1);

        vm.revertToState(baseline);

        uint256 ten = _measureBatchGas(10);

        vm.revertToState(baseline);

        uint256 thirtyTwo = _measureBatchGas(32);

        console2.log("settleMany(1) ", one);
        console2.log("settleMany(10)", ten);
        console2.log("settleMany(32)", thirtyTwo);
        console2.log("per bond at 32", thirtyTwo / 32);

        // Per-bond cost at 32 must not exceed the single-bond cost. A quadratic term would blow
        // straight through this.
        assertLt(thirtyTwo / 32, one, "per-bond settlement cost grew with batch size");
    }

    function _measureBatchGas(uint32 n) internal returns (uint256) {
        uint32 openBlock = uint32(block.number);
        uint32 m = openBlock + hook.OBSERVATION_BLOCKS();

        bytes32[] memory ids = new bytes32[](n);

        for (uint32 i = 0; i < n; i++) {
            ids[i] = _bondIdAt(m, i);

            _swap(BONDED, true, _hookData());
        }

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        uint256 before = gasleft();

        hook.settleMany(ids);

        return before - gasleft();
    }
}
