// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

/// @notice Milestone 1. The point of this test is NOT that the contract compiles — it is that
///         a real swap through PoolManager drives our callbacks, and that the mined address
///         actually satisfies Hooks.validateHookPermissions.
contract HookWiringTest is Test, Deployers {
    BondMeBro internal hook;
    PoolKey internal key_;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // The permission bits the deployed address must encode.
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // In forge test the deployer is address(this), so that is what HookMiner must be told.
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(BondMeBro).creationCode, abi.encode(manager));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)));
        assertEq(address(hook), predicted, "mined address mismatch");

        (key_,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
    }

    function test_permissionBitsMatchAddress() public view {
        // If this holds, the CREATE2 salt mining worked and PoolManager will accept the hook.
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertEq(hook.afterInitializeCount(), 1, "afterInitialize did not fire");
    }

    function test_hookIsCalledOnSwap() public {
        assertEq(hook.beforeSwapCount(), 0);
        assertEq(hook.afterSwapCount(), 0);

        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e15, // exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(hook.beforeSwapCount(), 1, "beforeSwap did not fire");
        assertEq(hook.afterSwapCount(), 1, "afterSwap did not fire");

        int24 tickBefore = hook.lastTickBefore();
        int24 tickAfter = hook.lastTickAfter();
        console2.log("tickBefore", tickBefore);
        console2.log("tickAfter ", tickAfter);

        // zeroForOne sells token0, so price and tick must move DOWN.
        assertLt(tickAfter, tickBefore, "zeroForOne should move tick down");
    }
}
