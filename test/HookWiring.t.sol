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

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";

/// @notice Milestone 1. The point of this test is NOT that the contract compiles — it is that
///         a real swap through PoolManager drives our callbacks, and that the mined address
///         actually satisfies Hooks.validateHookPermissions.
contract HookWiringTest is Test, Deployers {
    BondMeBro internal hook;
    PoolKey internal key_;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // In forge test the deployer is address(this), so that is what HookMiner must be told.
        // Flags come from HOOK_FLAGS — no local copy; see src/BondMeBro.sol.
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));
        assertEq(address(hook), predicted, "mined address mismatch");

        (key_,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
    }

    function test_permissionBitsMatchAddress() public view {
        // If this holds, the CREATE2 salt mining worked and PoolManager will accept the hook.
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertEq(hook.afterInitializeCount(), 1, "afterInitialize did not fire");
    }

    /// @notice The anti-drift test. `HOOK_FLAGS` is what the salt is mined against;
    ///         `getHookPermissions()` is what PoolManager validates. If they ever disagree, every
    ///         deploy mines an address that reverts at `initialize` with `HookAddressNotValid` —
    ///         a confusing failure a long way from its cause. This pins them together.
    function test_hookFlagsConstantMatchesPermissions() public view {
        // The deployed address must carry exactly HOOK_FLAGS in its low 14 bits, no more, no less.
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "address bits != HOOK_FLAGS");

        // And HOOK_FLAGS must be the same bit set getHookPermissions() declares. validateHookPermissions
        // compares the declared struct against the address bits field by field, so passing it here
        // — with the assertion above — closes the loop in both directions.
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());

        // Spelled out, so a wrong-but-self-consistent edit to HOOK_FLAGS still fails.
        assertEq(
            HOOK_FLAGS,
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ),
            "HOOK_FLAGS is not the intended bit set"
        );
        // 0x10C8 in T3A; AFTER_SWAP_RETURNS_DELTA (1<<2) added in T3B — see ADR-0002 s12.
        assertEq(HOOK_FLAGS, 0x10CC, "HOOK_FLAGS drifted from the value recorded in ADR-0002 s12");
    }

    /// @dev The `beforeSwapCount` / `afterSwapCount` counters this test used to read were removed
    ///      in T3B — two cold SSTOREs at ~20,000 gas each on every swap, to prove something the
    ///      `CallbackFired` event and the tick writes already prove for free. Invocation is now
    ///      asserted from the events, and the tick state confirms each callback ran far enough to
    ///      do its work.
    function test_hookIsCalledOnSwap() public {
        // Both callbacks must fire, in order, with the tick each observed.
        vm.expectEmit(false, false, false, true, address(hook));
        emit BondMeBro.CallbackFired("beforeSwap", 0);
        vm.expectEmit(false, false, false, false, address(hook));
        emit BondMeBro.CallbackFired("afterSwap", 0); // tick not checked; asserted below

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

        int24 tickBefore = hook.lastTickBefore();
        int24 tickAfter = hook.lastTickAfter();
        console2.log("tickBefore", tickBefore);
        console2.log("tickAfter ", tickAfter);

        // zeroForOne sells token0, so price and tick must move DOWN. This also proves both
        // callbacks actually ran: lastTickAfter is only written by afterSwap, and it could not
        // differ from lastTickBefore unless beforeSwap had written that first.
        assertLt(tickAfter, tickBefore, "zeroForOne should move tick down");
    }
}
