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
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ),
            "HOOK_FLAGS is not the intended bit set"
        );
        // 0x10C8 in T3A; AFTER_SWAP_RETURNS_DELTA (1<<2) added in T3B -- see ADR-0002 s12.
        // P-L2-3/4 REMOVED BEFORE_SWAP_RETURNS_DELTA (1<<3), so 0x10CC -> 0x10C4 (ADR-0006 s4).
        //
        // This numeric pin was itself a migration hazard of exactly the kind P-L2-2 hit with the
        // hookData version byte: it encodes the OLD permission set as a literal, so it survives a
        // rename of every named constant and fails only at the point of edit. It is kept rather
        // than deleted -- an independent statement of the bitmap is the whole reason it caught
        // anything -- but it is now stated as a derivation from the removal so the next reader can
        // see WHICH bit left and why.
        assertEq(HOOK_FLAGS, 0x10C4, "HOOK_FLAGS drifted from the value recorded in ADR-0002 s12 / ADR-0006 s4");
        assertEq(HOOK_FLAGS, 0x10CC & ~uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG), "0x10C4 is not 0x10CC minus 1<<3");
    }

    /// @notice The permission removed by P-L2-3/4 must be absent from BOTH sources of truth, and
    ///         absent is asserted directly rather than inferred from the bitmap equality above.
    ///
    /// @dev Two independent statements, because they fail for different reasons:
    ///
    ///        - the ADDRESS bit, which is what `PoolManager` actually consults at every callback;
    ///        - the DECLARED struct, which is what `validateHookPermissions` compares against it.
    ///
    ///      Re-adding the flag to `HOOK_FLAGS` alone would mine a new address and fail here on the
    ///      first assertion; re-adding it to `getHookPermissions` alone would fail on the second.
    ///      Neither is caught by a test that only checks the two agree with each other.
    ///
    ///      This matters beyond tidiness. `beforeSwapReturnDelta` is the permission Uniswap rates
    ///      CRITICAL, because a hook holding it can return a specified-currency delta and turn a
    ///      swap into a no-op. ADR-0006 s4's security argument is that BondMeBro cannot do this
    ///      because it does not hold the bit -- not that it chooses not to. That argument is only
    ///      true while this test passes.
    function test_hookFlags_beforeSwapReturnDeltaIsGone() public view {
        assertEq(
            uint160(address(hook)) & uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG),
            0,
            "the deployed address still carries BEFORE_SWAP_RETURNS_DELTA"
        );

        assertFalse(hook.getHookPermissions().beforeSwapReturnDelta, "the hook still declares beforeSwapReturnDelta");
    }

    /// @dev The invocation proof has been progressively cheapened as the scaffolding it relied on
    ///      was removed: `beforeSwapCount`/`afterSwapCount` in T3B (two ~20,000-gas SSTOREs per
    ///      swap), then the `CallbackFired` events in T5.1 (a string-argument LOG in each callback,
    ///      on a gas-budgeted path). The accumulator now proves both callbacks ran, for free: only
    ///      `beforeSwap` advances `lastUpdate`, and only `afterSwap` writes the post-swap tick.
    function test_hookIsCalledOnSwap() public {
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

        // The accumulator replaced the lastTickBefore/lastTickAfter diagnostics in T5.1.
        (int24 effectiveTick, uint32 lastUpdate,) = hook.accumulator(key_.toId());

        console2.log("effective tick after swap", effectiveTick);

        // Both callbacks ran: `beforeSwap` advanced `lastUpdate` to this block, and `afterSwap`
        // stored the post-swap tick. zeroForOne sells token0, so the tick must have moved DOWN
        // from the pool's starting tick of 0.
        assertEq(lastUpdate, uint32(block.number), "beforeSwap did not advance the accumulator");

        assertLt(effectiveTick, 0, "zeroForOne should move the effective tick down");
    }
}
