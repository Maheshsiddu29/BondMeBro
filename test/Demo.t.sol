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

/// @title DemoTest
///
/// @notice The three-scenario walkthrough. `make demo`, or
///         `forge test --match-path test/Demo.t.sol -vv`.
///
/// @dev DETERMINISTIC AND NARRATED. Every number below is produced by the real hook on a real pool
///      in this run — nothing is hard-coded for display. The assertions are deliberately loose:
///      this file exists to SHOW the mechanism, and the tight pinning lives in the dedicated suites
///      (`Settlement`, `ModelL2SettlementIntegration`, `BlockCumulativeImpact`). A demo that failed
///      on a rounding change would be a liability during a presentation.
contract DemoTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant ALICE = address(0xA11CE);

    int128 internal constant POOL_LIQUIDITY = 1e19;
    uint256 internal constant BIG_TRADE = 1e16;

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

        // Bond anything at or above 0.001 units of input.
        hook.setPoolConfig(key_, 1e15, 1e15, true);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _tick() internal view returns (int24 t) {
        // slither-disable-next-line unused-return
        (, t,,) = manager.getSlot0(id_);
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(ALICE, type(uint128).max);
    }

    function _swap(int256 amount, bool zeroForOne, bytes memory data) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
    }

    function _nextBondId() internal view returns (bytes32) {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // slither-disable-next-line unused-return
        (,,, uint32 pending,) = hook.maturity(id_, m);

        return keccak256(abi.encode(id_, m, pending));
    }

    function _line() internal pure {
        console2.log("--------------------------------------------------------------");
    }

    /*//////////////////////////////////////////////////////////////
       SCENARIO 1 -- BENIGN TRADE: THE PRICE COMES BACK, FULL REFUND
    //////////////////////////////////////////////////////////////*/

    function test_demo1_benignTradeIsFullyRefunded() public {
        _line();
        console2.log("SCENARIO 1  Benign trade -- the price reverts, everything comes back");
        _line();

        uint32 openBlock = uint32(block.number);
        uint32 maturity = openBlock + hook.OBSERVATION_BLOCKS();

        bytes32 bondId = _nextBondId();

        int24 before = _tick();

        _swap(-int256(BIG_TRADE), true, _hookData());

        BondMeBro.Bond memory b = hook.getBond(bondId);

        uint256 collateral = hook.collateralAmountOf(bondId);

        console2.log("  Alice swaps (currency0)", BIG_TRADE);
        console2.log("  pool tick before       ", int256(before));
        console2.log("  pool tick after        ", int256(_tick()));
        console2.log("  collateral rate (bps)  ", uint256(b.collateralBps));
        console2.log("  collateral held (cur1) ", collateral);
        console2.log("  matures at block       ", maturity);

        // The price comes straight back the next block -- an arbitrageur, or just noise.
        vm.roll(openBlock + 1);

        _swap(-int256(BIG_TRADE), false, _hookData());

        console2.log("  next block: price reverts to tick", int256(_tick()));

        // Wait out the window, then settle. Anyone may call this.
        vm.roll(maturity + 1);

        _swap(-1e11, true, _hookData());

        uint256 potBefore = hook.insurancePot(id_, currency1);
        uint256 aliceBefore = currency1.balanceOf(ALICE);

        vm.prank(address(0xDEAD)); // a total stranger settles it
        hook.settleBond(bondId);

        uint256 refund = currency1.balanceOf(ALICE) - aliceBefore;
        uint256 slash = hook.insurancePot(id_, currency1) - potBefore;

        _line();
        console2.log("  settled by a stranger (permissionless)");
        console2.log("  refunded to Alice      ", refund);
        console2.log("  slashed to LPs         ", slash);
        _line();

        assertEq(refund + slash, collateral, "settlement did not conserve");
        assertEq(slash, 0, "a fully reverted move should not be slashed");
        assertEq(refund, collateral, "a fully reverted move should be fully refunded");
    }

    /*//////////////////////////////////////////////////////////////
     SCENARIO 2 -- PERSISTENT DISPLACEMENT: LPs ARE PAID
    //////////////////////////////////////////////////////////////*/

    function test_demo2_persistentDisplacementPaysTheInsurancePot() public {
        _line();
        console2.log("SCENARIO 2  Persistent move -- the price stays, LPs are compensated");
        _line();

        uint32 openBlock = uint32(block.number);
        uint32 maturity = openBlock + hook.OBSERVATION_BLOCKS();

        bytes32 bondId = _nextBondId();

        int24 before = _tick();

        _swap(-int256(BIG_TRADE), true, _hookData());

        uint256 collateral = hook.collateralAmountOf(bondId);

        console2.log("  Alice swaps (currency0)", BIG_TRADE);
        console2.log("  pool tick before       ", int256(before));
        console2.log("  pool tick after        ", int256(_tick()));
        console2.log("  collateral rate (bps)  ", uint256(hook.getBond(bondId).collateralBps));
        console2.log("  collateral held        ", collateral);

        // Nobody trades it back. The displacement simply stays for the whole window.
        console2.log("  ... 10 blocks pass, price does NOT revert ...");

        vm.roll(maturity + 1);

        _swap(-1e11, true, _hookData());

        // slither-disable-next-line unused-return
        (int56 c6, int56 c8, int56 c10,,) = hook.maturity(id_, maturity);

        console2.log("  frozen C6              ", int256(c6));
        console2.log("  frozen C8              ", int256(c8));
        console2.log("  frozen C10             ", int256(c10));

        uint256 potBefore = hook.insurancePot(id_, currency1);
        uint256 aliceBefore = currency1.balanceOf(ALICE);

        hook.settleBond(bondId);

        uint256 refund = currency1.balanceOf(ALICE) - aliceBefore;
        uint256 slash = hook.insurancePot(id_, currency1) - potBefore;

        _line();
        console2.log("  refunded to Alice      ", refund);
        console2.log("  slashed to LPs         ", slash);
        console2.log("  LP insurance pot now   ", hook.insurancePot(id_, currency1));
        _line();

        assertEq(refund + slash, collateral, "settlement did not conserve");
        assertGt(slash, 0, "a persistent move should be slashed");
    }

    /*//////////////////////////////////////////////////////////////
      SCENARIO 3 -- SAME-BLOCK SPLIT: OLD RULE vs SHIPPED RULE
    //////////////////////////////////////////////////////////////*/

    /// @notice One price move, made in 16 same-block pieces, priced under both rules.
    ///
    /// @dev The comparison is honest because BOTH columns are computed from the SAME executed
    ///      swaps. The "old rule" column is not a memory of a previous build — it is
    ///      `ModelLReference.collateralFor`, an independent restatement of the own-impact rule,
    ///      applied to the very same realized ticks and legs the shipped hook just charged on.
    function test_demo3_sameBlockSplitComparison() public {
        _line();
        console2.log("SCENARIO 3  One move, split 16 ways in a single block");
        _line();

        uint32 maturity = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        int24 start = _tick();

        uint256 shipped;
        uint256 oldRule;
        uint256 bonded;

        for (uint32 i = 0; i < 16; i++) {
            bytes32 bondId = _nextBondId();

            _swap(-int256(32e15 / 16), true, _hookData());

            if (!hook.bondExists(bondId)) continue;

            BondMeBro.Bond memory b = hook.getBond(bondId);

            bonded++;
            shipped += hook.collateralAmountOf(bondId);
            oldRule += ModelLReference.collateralFor(b.variableLegAmount, b.tickBefore, b.tickAfter);
        }

        console2.log("  total ticks moved      ", uint256(int256(start) - int256(_tick())));
        console2.log("  pieces / bonded        ", uint256(16), bonded);
        _line();
        console2.log("  collateral, OLD per-swap rule  ", oldRule);
        console2.log("  collateral, SHIPPED block rule ", shipped);
        console2.log("  shipped / old (x1000)          ", (shipped * 1000) / oldRule);
        _line();
        console2.log("  The same price move, the same swaps, the same LP harm.");
        console2.log("  The block rule prices each piece against where the BLOCK started,");
        console2.log("  so splitting no longer dilutes the collateral toward zero.");
        console2.log("  It is a mitigation, not immunity -- see README limitation E.");
        _line();

        maturity;

        assertGt(shipped, oldRule, "the shipped rule should charge a split more than the old rule");
    }
}
