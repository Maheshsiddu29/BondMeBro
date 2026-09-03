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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BondMeBro} from "../../src/BondMeBro.sol";
import {HookDataCodec} from "../../src/libraries/HookDataCodec.sol";

/// @notice Stateful accounting invariant over both exact-input and exact-output routes.
///
/// The handler deliberately catches swaps that run into the test pool's price boundary. A
/// failed swap must leave no bond, no token transfer, and no queue mutation; successful swaps
/// are checked after every generated sequence by `invariant_tokenCustodyMatchesBook`.
contract BondAccountingHandler is Test {
    using PoolIdLibrary for PoolKey;

    BondMeBro public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolKey public key;
    PoolId public immutable pid;
    Currency public immutable currency0;
    Currency public immutable currency1;

    constructor(BondMeBro hook_, PoolSwapTest swapRouter_, PoolKey memory key_) {
        hook = hook_;
        swapRouter = swapRouter_;
        key = key_;
        pid = key_.toId();
        currency0 = key_.currency0;
        currency1 = key_.currency1;

        // The test token fixture exposes mint and does not restrict it. Giving the handler a
        // large balance lets invariant sequences originate from a distinct caller.
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e24);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
    }

    function hookData() public view returns (bytes memory) {
        return HookDataCodec.encode(address(this), type(uint128).max);
    }

    function swapDown(uint256 amount) external {
        amount = _boundedInput(amount);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData()
        ) {}
            catch {}
    }

    function swapUp(uint256 amount) external {
        amount = _boundedInput(amount);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData()
        ) {}
            catch {}
    }

    function exactOutputDown(uint256 amountOut) external {
        amountOut = _boundedOutput(amountOut);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData()
        ) {}
            catch {}
    }

    function exactOutputUp(uint256 amountOut) external {
        amountOut = _boundedOutput(amountOut);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData()
        ) {}
            catch {}
    }

    function settle() external {
        try hook.settleBonds(key, 32) {} catch {}
    }

    function advance(uint256 blocks) external {
        vm.roll(block.number + (blocks % 20) + 1);
    }

    function _boundedInput(uint256 amount) internal pure returns (uint256) {
        return 1e15 + (amount % 5e15);
    }

    function _boundedOutput(uint256 amountOut) internal pure returns (uint256) {
        return 1e12 + (amountOut % 5e15);
    }
}

contract BondAccountingInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal pid;
    BondAccountingHandler internal handler;

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
        assertEq(address(hook), predicted);

        (key_,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
        pid = key_.toId();

        handler = new BondAccountingHandler(hook, swapRouter, key_);
        targetContract(address(handler));
        vm.roll(1000);
    }

    function invariant_tokenCustodyMatchesBook() public view {
        (uint256 expected0, uint256 expected1) = _bookBalances();
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), expected0);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), expected1);
    }

    function _bookBalances() internal view returns (uint256 expected0, uint256 expected1) {
        expected0 = hook.insurancePot(pid, currency0);
        expected1 = hook.insurancePot(pid, currency1);
        (bytes32 current,) = hook.queueBounds(pid);

        uint256 guard;
        while (current != bytes32(0)) {
            BondMeBro.Bond memory bond = hook.getBond(pid, current);
            if (Currency.unwrap(bond.currency) == Currency.unwrap(currency0)) expected0 += bond.amount;
            else expected1 += bond.amount;
            current = bond.next;
            // The handler has bounded actions; this guard also prevents an invariant failure
            // from becoming an unbounded view loop if the queue ever corrupts itself.
            if (++guard > 256) revert("bond queue exceeded invariant guard");
        }
    }
}
