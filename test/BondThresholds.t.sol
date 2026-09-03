// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @notice Integration coverage for the per-currency amount thresholds, the owner-controlled
///         pool configuration, the 1% cap, and trader-selected bond slippage protection.
contract BondThresholdsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal pid;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function config() internal view returns (BondMeBro.Config memory) {
        return BondMeBro.Config({
            bondBps: 25,
            refundTolTicks: 5,
            observationBlocks: 10,
            maxAbsTickDelta: 1000,
            settlerFeeBps: 500,
            maxSettlesPerSwap: 4,
            minBondedAmount0: 1e15,
            minBondedAmount1: 1e15,
            owner: address(this)
        });
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(BondMeBro).creationCode, abi.encode(manager, config()));
        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), config());
        assertEq(address(hook), predicted, "mined address mismatch");

        (key_,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
        pid = key_.toId();
    }

    function _swap(bool zeroForOne, int256 amountSpecified, bytes memory data) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
    }

    function test_currencySpecificThresholds() public {
        // Currency0 has a higher threshold than currency1. The same raw input is therefore
        // unbonded in one direction and bonded in the other.
        hook.setPoolConfig(key_, 2e16, 1e15, 25);

        _swap(true, -1e16, "");
        assertEq(hook.queueLength(pid), 0, "currency0 threshold must be enforced");

        _swap(false, -1e16, HookDataCodec.encode(address(this), type(uint128).max));
        assertEq(hook.queueLength(pid), 1, "currency1 threshold must be enforced");
        (bytes32 head,) = hook.queueBounds(pid);
        BondMeBro.Bond memory bond = hook.getBond(pid, head);
        assertEq(Currency.unwrap(bond.currency), Currency.unwrap(currency1));
    }

    function test_partialPoolConfigIsRejected() public {
        vm.expectRevert(BondMeBro.InvalidPoolConfig.selector);
        hook.setPoolConfig(key_, 1e15, 0, 25);

        vm.expectRevert(BondMeBro.InvalidPoolConfig.selector);
        hook.setPoolConfig(key_, 1e15, 1e15, 101);
    }

    function test_onlyOwnerMayUpdatePoolConfig() public {
        vm.prank(address(0x1234));
        vm.expectRevert(BondMeBro.NotOwner.selector);
        hook.setPoolConfig(key_, 1e15, 1e15, 25);
    }

    function test_poolWritePathsRejectForeignHookKey() public {
        PoolKey memory foreignKey = key_;
        foreignKey.hooks = IHooks(address(0xBEEF));

        vm.expectRevert(BondMeBro.InvalidHookAddress.selector);
        hook.setPoolConfig(foreignKey, 1e15, 1e15, 25);

        vm.expectRevert(BondMeBro.InvalidHookAddress.selector);
        hook.settleBonds(foreignKey, 1);

        vm.expectRevert(BondMeBro.InvalidHookAddress.selector);
        hook.donatePot(foreignKey, currency0);
    }

    function test_exactInputBondUsesInputCurrencyAndRespectsMax() public {
        vm.expectRevert();
        _swap(true, -1e16, HookDataCodec.encode(address(this), 1));

        _swap(true, -1e16, HookDataCodec.encode(address(this), type(uint128).max));
        (bytes32 head,) = hook.queueBounds(pid);
        BondMeBro.Bond memory bond = hook.getBond(pid, head);

        assertEq(Currency.unwrap(bond.currency), Currency.unwrap(currency0));
        assertEq(bond.amount, uint128((1e16 * 25) / 10_000));
        assertLt(uint256(bond.amount), 1e16, "INV-NOOP: bond must leave input for the pool");
    }

    function test_exactOutputBondUsesCurrency1ForOppositeDirection() public {
        _swap(false, 4e15, HookDataCodec.encode(address(this), type(uint128).max));
        (bytes32 head,) = hook.queueBounds(pid);
        BondMeBro.Bond memory bond = hook.getBond(pid, head);

        assertEq(Currency.unwrap(bond.currency), Currency.unwrap(currency1));
        assertGt(bond.amount, 0);
    }

    function test_exactOutputBondRespectsMax() public {
        vm.expectRevert();
        _swap(true, 4e15, HookDataCodec.encode(address(this), 1));
        assertEq(hook.queueLength(pid), 0, "reverted exact-output quote must not open a bond");
    }

    function test_constructorAllowsDisabledDefaultButRejectsPartialDefault() public {
        BondMeBro.Config memory disabled = config();
        disabled.minBondedAmount0 = 0;
        disabled.minBondedAmount1 = 0;
        disabled.bondBps = 0;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(BondMeBro).creationCode, abi.encode(manager, disabled));
        BondMeBro disabledHook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), disabled);
        assertEq(address(disabledHook), predicted);

        BondMeBro.Config memory partialCfg = config();
        partialCfg.minBondedAmount1 = 0;
        (, salt) = HookMiner.find(address(this), FLAGS, type(BondMeBro).creationCode, abi.encode(manager, partialCfg));
        vm.expectRevert(BondMeBro.InvalidPoolConfig.selector);
        new BondMeBro{salt: salt}(IPoolManager(address(manager)), partialCfg);

        BondMeBro.Config memory overCap = config();
        overCap.bondBps = 101;
        (, salt) = HookMiner.find(address(this), FLAGS, type(BondMeBro).creationCode, abi.encode(manager, overCap));
        vm.expectRevert(BondMeBro.InvalidPoolConfig.selector);
        new BondMeBro{salt: salt}(IPoolManager(address(manager)), overCap);
    }
}
