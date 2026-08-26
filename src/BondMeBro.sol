// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title BondMeBro — skeleton
/// @notice Milestone 1 only: proves the permission bits, the mined address, and that both
///         swap callbacks actually fire with readable pool state. No bond logic yet — the
///         settlement model is deliberately not committed to at this stage.
contract BondMeBro is BaseHook {
    using StateLibrary for IPoolManager;

    /// @notice Counts callback invocations so tests can assert the hook is really wired in.
    uint256 public beforeSwapCount;
    uint256 public afterSwapCount;
    uint256 public afterInitializeCount;

    /// @notice Ticks observed either side of the swap. This is the raw material every
    ///         candidate settlement rule needs, regardless of which rule is chosen.
    int24 public lastTickBefore;
    int24 public lastTickAfter;

    event CallbackFired(string which, int24 tick);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @dev These three bits are what the deployed address must encode.
    ///      AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24 tick) internal override returns (bytes4) {
        afterInitializeCount++;
        emit CallbackFired("afterInitialize", tick);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Only `tick` is needed here; sqrtPriceX96 / protocolFee / lpFee are intentionally
        // discarded. Destructuring getSlot0 this way is the idiomatic v4 read pattern.
        // slither-disable-next-line unused-return
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        lastTickBefore = tick;
        beforeSwapCount++;
        emit CallbackFired("beforeSwap", tick);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // See _beforeSwap: only the tick is consumed by the settlement model.
        // slither-disable-next-line unused-return
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        lastTickAfter = tick;
        afterSwapCount++;
        emit CallbackFired("afterSwap", tick);
        return (BaseHook.afterSwap.selector, int128(0));
    }
}
