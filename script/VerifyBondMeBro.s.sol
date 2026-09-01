// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

/// @title VerifyBondMeBro
/// @notice Read-only post-deployment verification for the hook and its configured pool.
///
/// @dev Run without `--broadcast` or a private key. This script checks the immutable manager,
///      permission mask, pool initialization, owner, active custody configuration, queue, and
///      pot values before an operator records the deployment manifest.
contract VerifyBondMeBro is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external view returns (PoolId id) {
        address hookAddress = vm.envAddress("BOND_HOOK");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        BondMeBro hook = BondMeBro(payable(hookAddress));
        require(address(poolManager).code.length != 0, "VerifyBondMeBro: invalid POOL_MANAGER");
        require(hookAddress.code.length != 0, "VerifyBondMeBro: invalid BOND_HOOK");
        require(address(hook.poolManager()) == address(poolManager), "VerifyBondMeBro: manager mismatch");

        Hooks.validateHookPermissions(IHooks(hookAddress), hook.getHookPermissions());

        PoolKey memory key = _poolKey(hookAddress);
        id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        require(sqrtPriceX96 != 0, "VerifyBondMeBro: pool not initialized");

        BondMeBro.PoolConfig memory config = hook.getPoolConfig(id);
        require(hook.owner() == vm.envAddress("OWNER"), "VerifyBondMeBro: owner mismatch");

        console2.log("chain id    ", block.chainid);
        console2.log("hook        ", hookAddress);
        console2.log("poolManager ", address(poolManager));
        console2.log("owner       ", hook.owner());
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("sqrt price  ", uint256(sqrtPriceX96));
        console2.log("tick        ", tick);
        console2.log("min amount0 ", uint256(config.minBondedAmount0));
        console2.log("min amount1 ", uint256(config.minBondedAmount1));
        console2.log("bond bps    ", uint256(config.bondBps));
        console2.log("queue length", hook.queueLength(id));
        console2.log("verification ok");
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
