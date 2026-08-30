// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

/// @title InitializeBondMeBroPool
/// @notice Initializes a Uniswap v4 pool with BondMeBro installed as its hook.
///
/// @dev Adding liquidity is intentionally a separate operation. Production deployments use
/// the network's canonical PositionManager so token approvals, Permit2, slippage limits, and
/// native-currency handling stay under the user's normal liquidity-management flow.
///
/// Required environment variables:
/// - RPC_URL and PRIVATE_KEY (provided to forge script)
/// - POOL_MANAGER, BOND_HOOK, CURRENCY0, CURRENCY1
/// - POOL_FEE, TICK_SPACING, SQRT_PRICE_X96
contract InitializeBondMeBroPool is Script {
    using PoolIdLibrary for PoolKey;

    function run() external returns (PoolId id, int24 initialTick) {
        address hookAddress = vm.envAddress("BOND_HOOK");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        require(address(poolManager).code.length != 0, "InitializeBondMeBroPool: invalid POOL_MANAGER");
        require(hookAddress.code.length != 0, "InitializeBondMeBroPool: invalid BOND_HOOK");
        require(
            address(BondMeBro(payable(hookAddress)).poolManager()) == address(poolManager),
            "InitializeBondMeBroPool: manager mismatch"
        );
        PoolKey memory key = _poolKey(hookAddress);
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));

        vm.startBroadcast();
        initialTick = poolManager.initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        id = key.toId();
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("initial tick ", initialTick);
    }

    function _poolKey(address hookAddress) internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("CURRENCY0")),
            currency1: Currency.wrap(vm.envAddress("CURRENCY1")),
            fee: uint24(vm.envUint("POOL_FEE")),
            tickSpacing: int24(uint24(vm.envUint("TICK_SPACING"))),
            hooks: IHooks(hookAddress)
        });
    }
}
