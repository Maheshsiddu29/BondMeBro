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

import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title GoldenBehaviourTest
///
/// @notice Thirteen deterministic end-to-end cases, printed as canonical lines.
///
/// @dev THE BEHAVIOURAL EQUIVALENCE GATE FOR P-L2-7.
///
///      Cleanup must not change what the protocol DOES. That is easy to claim and hard to be sure
///      of: deleting a storage field, renaming a config field and removing a library all touch code
///      that settlement reads, and a subtle drift would show up as a slightly different slash on
///      one path rather than as a failing test.
///
///      So every case below prints a `GOLDEN|...` line carrying every number a caller could
///      observe — collateral, both token deltas, the surviving bond fields, all three checkpoint
///      endpoints, slash, refund and the insurance pot. The full set is captured BEFORE the cleanup
///      and diffed against the same set AFTER. Any economic drift anywhere becomes a textual diff.
///
///      WHY PRINTED RATHER THAN HARD-CODED. Hard-coding the expected numbers would mean writing
///      them from a run of the code being tested, which proves only that the code is deterministic.
///      Capturing the output of the PRE-cleanup build and comparing it to the POST-cleanup build
///      compares two different programs, which is the actual question.
///
///      The cases are deterministic by construction: fixed liquidity, fixed amounts, fixed block
///      offsets, no fuzzing. Anything non-deterministic here would make the diff useless.
contract GoldenBehaviourTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;

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

        _enableBonding(key_);
    }

    /// @dev THE ONLY LINE THAT MAY DIFFER BETWEEN THE PRE- AND POST-CLEANUP BUILDS.
    ///
    ///      P-L2-7 changes `PoolConfig`'s shape, so the configuration call necessarily changes with
    ///      it. Isolating it here keeps the rest of this file — every assertion, every printed
    ///      number — byte-identical across the two runs, so the diff shows economic drift and
    ///      nothing else.
    function _enableBonding(PoolKey memory k) internal {
        // PRE-CLEANUP SIGNATURE. P-L2-7 replaces the two economic `uint16` fields with a single
        // explicit enable flag; this line becomes `setPoolConfig(k, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true)`.
        hook.setPoolConfig(k, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

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

    function _swapLimited(int256 amountSpecified, uint160 limit, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _bondIdAt(uint32 maturityBlock, uint32 index) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, index));
    }

    function _maturityOfNow() internal view returns (uint32) {
        return uint32(block.number) + hook.OBSERVATION_BLOCKS();
    }

    /// @dev Prints every observable field of a bond and its bucket.
    ///
    ///      `cumulativeAtOpen` is deliberately NOT printed: P-L2-6 left it write-only and P-L2-7
    ///      removes it, so including it would make the diff report a field nothing reads as if it
    ///      were an economic change.
    function _logBond(string memory label, bytes32 bondId, uint32 m) internal view {
        _logBondFields(label, bondId);
        _logBondLifecycle(label, bondId);
        _logBucket(label, m);
    }

    /// @dev The economic fields: the leg, the two ticks, the collateral currency.
    function _logBondFields(string memory label, bytes32 bondId) internal view {
        BondMeBro.Bond memory b = hook.getBond(bondId);

        console2.log(
            string.concat(
                "GOLDEN|",
                label,
                "|leg=",
                vm.toString(b.variableLegAmount),
                "|tickBefore=",
                vm.toString(b.tickBefore),
                "|tickAfter=",
                vm.toString(b.tickAfter),
                "|c0=",
                b.collateralIsCurrency0 ? "1" : "0"
            )
        );
    }

    /// @dev The lifecycle fields and the derived collateral.
    function _logBondLifecycle(string memory label, bytes32 bondId) internal view {
        BondMeBro.Bond memory b = hook.getBond(bondId);

        console2.log(
            string.concat(
                "GOLDEN|",
                label,
                "|open=",
                vm.toString(b.openBlock),
                "|maturity=",
                vm.toString(b.maturityBlock),
                "|poolIndex=",
                vm.toString(b.poolIndex),
                "|state=",
                vm.toString(uint256(uint8(b.state))),
                "|collateral=",
                vm.toString(hook.collateralAmountOf(bondId))
            )
        );
    }

    /// @dev The three checkpoint endpoints, the liability count and the frozen mask.
    function _logBucket(string memory label, uint32 m) internal view {
        (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = hook.maturity(id_, m);

        console2.log(
            string.concat(
                "GOLDEN|",
                label,
                "|C6=",
                vm.toString(c6),
                "|C8=",
                vm.toString(c8),
                "|C10=",
                vm.toString(c10),
                "|pending=",
                vm.toString(pending),
                "|mask=",
                vm.toString(uint256(mask))
            )
        );
    }

    /// @dev Prints the hook's and the trader's balances in both currencies.
    function _logBalances(string memory label) internal view {
        console2.log(
            string.concat(
                "GOLDEN|",
                label,
                "|hook0=",
                vm.toString(currency0.balanceOf(address(hook))),
                "|hook1=",
                vm.toString(currency1.balanceOf(address(hook))),
                "|trader0=",
                vm.toString(currency0.balanceOf(TRADER)),
                "|trader1=",
                vm.toString(currency1.balanceOf(TRADER))
            )
        );

        console2.log(
            string.concat(
                "GOLDEN|",
                label,
                "|pot0=",
                vm.toString(hook.insurancePot(id_, currency0)),
                "|pot1=",
                vm.toString(hook.insurancePot(id_, currency1))
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                       A-D  THE FOUR CUSTODY MODES
    //////////////////////////////////////////////////////////////*/

    /// @dev A — exact-input, bonded. Collateral comes from the OUTPUT.
    function test_goldenA_exactInputBonded() public {
        uint32 m = _maturityOfNow();

        _swap(BONDED, true, _hookData());

        _logBond("A_EI_bonded", _bondIdAt(m, 0), m);
        _logBalances("A_EI_bonded");
    }

    /// @dev B — exact-output, bonded. Collateral comes from the INPUT.
    function test_goldenB_exactOutputBonded() public {
        uint32 m = _maturityOfNow();

        _swap(-BONDED, true, _hookData());

        _logBond("B_EO_bonded", _bondIdAt(m, 0), m);
        _logBalances("B_EO_bonded");
    }

    /// @dev C — exact-input below the threshold. No record, no collateral.
    function test_goldenC_exactInputUnbonded() public {
        uint32 m = _maturityOfNow();

        _swap(-int256(uint256(MIN_BONDED) - 1), true, "");

        (,,, uint32 pending, uint8 mask) = hook.maturity(id_, m);

        console2.log(
            string.concat(
                "GOLDEN|C_EI_unbonded|exists=",
                hook.bondExists(_bondIdAt(m, 0)) ? "1" : "0",
                "|pending=",
                vm.toString(pending),
                "|mask=",
                vm.toString(uint256(mask))
            )
        );

        _logBalances("C_EI_unbonded");
    }

    /// @dev D — exact-output below the threshold. Provisional written then cleared.
    function test_goldenD_exactOutputUnbonded() public {
        uint32 m = _maturityOfNow();

        _swap(int256(1e13), true, _hookData());

        (,,, uint32 pending, uint8 mask) = hook.maturity(id_, m);

        console2.log(
            string.concat(
                "GOLDEN|D_EO_unbonded|exists=",
                hook.bondExists(_bondIdAt(m, 0)) ? "1" : "0",
                "|pending=",
                vm.toString(pending),
                "|mask=",
                vm.toString(uint256(mask))
            )
        );

        _logBalances("D_EO_unbonded");
    }

    /// @dev E — a partial fill. The bond follows the REALIZED fill, not the request.
    function test_goldenE_partialFill() public {
        uint32 m = _maturityOfNow();

        // slither-disable-next-line unused-return
        (uint160 sqrtNow,,,) = manager.getSlot0(id_);

        _swapLimited(BONDED, sqrtNow - uint160((uint256(sqrtNow) * 200) / 1_000_000), _hookData());

        _logBond("E_partialFill", _bondIdAt(m, 0), m);
        _logBalances("E_partialFill");
    }

    /*//////////////////////////////////////////////////////////////
                     F-I  THE SETTLEMENT OUTCOMES
    //////////////////////////////////////////////////////////////*/

    /// @dev F — the price reverts: full refund.
    function test_goldenF_fullRefund() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(BONDED, true, _hookData());

        vm.roll(block.number + 1);
        _swap(-4e16, false, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);

        _logBond("F_fullRefund", bondId, m);
        _logBalances("F_fullRefund");
    }

    /// @dev G — a small persistent displacement inside the D = 5 dead zone: full refund.
    function test_goldenG_deadZoneRefund() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(-int256(uint256(MIN_BONDED) * 2), true, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);

        _logBond("G_deadZoneRefund", bondId, m);
        _logBalances("G_deadZoneRefund");
    }

    /// @dev H — a partly reverted displacement: partial slash.
    function test_goldenH_partialSlash() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(BONDED, true, _hookData());

        vm.roll(block.number + 3);
        _swap(-7e15, false, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);

        _logBond("H_partialSlash", bondId, m);
        _logBalances("H_partialSlash");
    }

    /// @dev I — the displacement persists: full slash.
    function test_goldenI_fullSlash() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleBond(bondId);

        _logBond("I_fullSlash", bondId, m);
        _logBalances("I_fullSlash");
    }

    /*//////////////////////////////////////////////////////////////
                      J-L  TIMING AND BATCHING
    //////////////////////////////////////////////////////////////*/

    /// @dev J — a completely quiet pool: endpoints derived at settlement.
    function test_goldenJ_quietSettlement() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(m) + 60);

        hook.settleBond(bondId);

        _logBond("J_quiet", bondId, m);
        _logBalances("J_quiet");
    }

    /// @dev K — settled 10,000 blocks late, after heavy post-maturity trading.
    function test_goldenK_lateSettlement() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        _swap(BONDED, true, _hookData());

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 3);
            _swap(BONDED * 2, i % 2 == 0, _hookData());
        }

        vm.roll(uint256(m) + 10_000);

        hook.settleBond(bondId);

        _logBond("K_late", bondId, m);
        _logBalances("K_late");
    }

    /// @dev L — a batch of four bonds sharing one maturity.
    ///
    ///      THE ONLY GOLDEN CASE ADR-0008 CHANGED, and it is the only one that runs four bonded
    ///      swaps in a SINGLE BLOCK. `test_goldenL_isTheDocumentedMigrationDelta` below records the
    ///      change explicitly rather than letting it pass as an all-green diff.
    function test_goldenL_settleMany() public {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](4);

        for (uint32 i = 0; i < 4; i++) {
            ids[i] = _bondIdAt(m, i);
            _swap(BONDED, true, _hookData());
        }

        vm.roll(uint256(m) + 1);
        _swap(NUDGE, true, "");

        hook.settleMany(ids);

        for (uint32 i = 0; i < 4; i++) {
            _logBond(string.concat("L_batch", vm.toString(uint256(i))), ids[i], m);
        }

        _logBalances("L_batch");
    }

    /// @notice THE MIGRATION'S GOLDEN DELTA, stated as an assertion rather than left to a diff.
    ///
    /// @dev ADR-0008 § 3.4 changes same-block follow-on collateral sizing and NOTHING else. Diffing
    ///      the 67 golden lines across the migration bears that out exactly: 62 are bit-identical,
    ///      and the 5 that moved are all inside case L — the only case that puts four bonded swaps
    ///      in one block.
    ///
    ///      MEASURED, pre-migration to post-migration:
    ///
    ///          L_batch0   4,971,473,942,316 -> 4,971,473,942,316   UNCHANGED (first in block)
    ///          L_batch1   4,971,473,942,316 -> 9,942,947,884,632
    ///          L_batch2   4,962,486,453,713 -> 13,894,962,070,399
    ///          L_batch3   4,953,523,314,632 -> 18,823,388,595,601
    ///          hook1     19,867,969,579,378 -> 28,809,432,684,666
    ///          trader1                    0 -> 18,832,351,734,683   (refund now paid)
    ///
    ///      This test pins the STRUCTURE of that delta rather than the six literals, which would
    ///      break on any fixture change without saying anything about the mechanism:
    ///
    ///        - piece 0 is first in its block, so it is priced on its own impact;
    ///        - each later piece is priced on its distance from the block start, which grows, so
    ///          the collateral sequence is strictly increasing — a property that was FALSE before
    ///          the migration, where later pieces were slightly CHEAPER as the pool thinned.
    ///
    ///      A regression to the old model fails the strict-increase assertion immediately.
    function test_goldenL_isTheDocumentedMigrationDelta() public {
        uint32 m = _maturityOfNow();

        bytes32[] memory ids = new bytes32[](4);

        uint256[4] memory collateral;

        for (uint32 i = 0; i < 4; i++) {
            ids[i] = _bondIdAt(m, i);

            _swap(BONDED, true, _hookData());

            collateral[i] = hook.collateralAmountOf(ids[i]);
        }

        // Piece 0 was first in its block: `blockStartTick == tickBefore`, so ADR-0008 is a no-op on
        // it and it is charged exactly what the pre-migration model charged.
        BondMeBro.Bond memory first = hook.getBond(ids[0]);

        assertEq(
            uint256(first.collateralBps),
            ModelLReference.collateralBps(first.tickBefore, first.tickAfter),
            "the batch's first piece is not priced on its own impact"
        );

        // Every later piece is strictly more expensive than the one before it.
        for (uint256 i = 1; i < 4; i++) {
            assertGt(
                collateral[i],
                collateral[i - 1],
                "same-block collateral is not increasing: ADR-0008's block term is not being applied"
            );
        }

        console2.log("GOLDEN-DELTA L_batch0", collateral[0]);
        console2.log("GOLDEN-DELTA L_batch1", collateral[1]);
        console2.log("GOLDEN-DELTA L_batch2", collateral[2]);
        console2.log("GOLDEN-DELTA L_batch3", collateral[3]);
    }

    /*//////////////////////////////////////////////////////////////
                        M  SHARED CURRENCY
    //////////////////////////////////////////////////////////////*/

    /// @dev M — two pools on the same hook sharing both currencies, each settling.
    ///
    ///      The aggregate-solvency shape: the hook holds ONE balance per ERC-20 while liabilities
    ///      are keyed per pool, so this case is where a currency-routing regression would surface
    ///      as a pot credited to the wrong pool.
    function test_goldenM_sharedCurrency() public {
        // A second pool on a different fee tier, same currencies, same hook.
        (PoolKey memory keyB, PoolId idB) =
            initPool(currency0, currency1, IHooks(address(hook)), 500, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(2))
            }),
            ""
        );

        _enableBonding(keyB);

        uint32 m = _maturityOfNow();

        bytes32 bondA = _bondIdAt(m, 0);
        bytes32 bondB = keccak256(abi.encode(idB, m, uint32(0)));

        _swap(BONDED, true, _hookData());

        swapRouter.swap(
            keyB,
            SwapParams({zeroForOne: true, amountSpecified: BONDED, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData()
        );

        vm.roll(uint256(m) + 1);

        _swap(NUDGE, true, "");

        swapRouter.swap(
            keyB,
            SwapParams({zeroForOne: true, amountSpecified: NUDGE, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        hook.settleBond(bondA);
        hook.settleBond(bondB);

        console2.log(
            string.concat(
                "GOLDEN|M_shared|potA0=",
                vm.toString(hook.insurancePot(id_, currency0)),
                "|potA1=",
                vm.toString(hook.insurancePot(id_, currency1)),
                "|potB0=",
                vm.toString(hook.insurancePot(idB, currency0)),
                "|potB1=",
                vm.toString(hook.insurancePot(idB, currency1))
            )
        );

        console2.log(
            string.concat(
                "GOLDEN|M_shared|hook0=",
                vm.toString(currency0.balanceOf(address(hook))),
                "|hook1=",
                vm.toString(currency1.balanceOf(address(hook))),
                "|stateA=",
                vm.toString(uint256(uint8(hook.getBond(bondA).state))),
                "|stateB=",
                vm.toString(uint256(uint8(hook.getBond(bondB).state)))
            )
        );
    }
}
