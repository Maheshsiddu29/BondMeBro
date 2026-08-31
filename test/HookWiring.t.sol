// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @notice Phase 1 wiring: the mined address must encode the extended permission bits
///         (both swap callbacks return deltas), and a real swap through PoolManager must
///         drive input-side bond custody end to end.
contract HookWiringTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal pid;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function config() internal view returns (BondMeBro.Config memory) {
        return BondMeBro.Config({
            bondBps: 25, // 0.25% of total input
            refundTolTicks: 5,
            observationBlocks: 10,
            maxAbsTickDelta: 1000,
            settlerFeeBps: 500, // 5% of slash to piggyback owner or direct settler
            maxSettlesPerSwap: 4,
            minBondedAmount0: 1e15,
            minBondedAmount1: 1e15,
            owner: address(this)
        });
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Use a broad range so the lifecycle tests exercise settlement rather than merely
        // running the low-liquidity fixture into TickMath's boundary.

        // In forge test the deployer is address(this), so that is what HookMiner must be told.
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

    function test_permissionBitsMatchAddress() public view {
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
    }

    function test_constructorRejectsZeroPoolManager() public {
        BondMeBro.Config memory cfg = config();
        (, bytes32 salt) = HookMiner.find(
            address(this), FLAGS, type(BondMeBro).creationCode, abi.encode(IPoolManager(address(0)), cfg)
        );

        vm.expectRevert(BondMeBro.InvalidPoolManager.selector);
        new BondMeBro{salt: salt}(IPoolManager(address(0)), cfg);
    }

    /// @notice A small input below the currency0 threshold must not be bonded at all.
    function test_smallSwap_opensNoBond() public {
        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -1e13, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(hook.queueLength(pid), 0, "small input must not open a bond");
    }

    /// @notice A large swap opens a bond and the hook holds the bonded tokens.
    function test_largeSwap_opensBond_andTakesTokens() public {
        uint256 hookBefore = Currency.unwrap(currency0) == address(0)
            ? address(hook).balance
            : MockERC20Like(Currency.unwrap(currency0)).balanceOf(address(hook));

        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -5e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            HookDataCodec.encode(address(this), type(uint128).max) // owner = test contract
        );

        assertEq(hook.queueLength(pid), 1, "bond not enqueued");
        uint256 hookAfter = MockERC20Like(Currency.unwrap(currency0)).balanceOf(address(hook));
        assertGt(hookAfter, hookBefore, "hook must be holding the bond");
    }
}

interface MockERC20Like {
    function balanceOf(address) external view returns (uint256);
}
