// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";

/// @title DeployBondMeBro

/// @notice Mines a CREATE2 salt for BondMeBro's required hook permission bits and deploys the hook.

/// @dev Uniswap v4 hook addresses encode their permissions in the low address bits, so BondMeBro cannot be deployed to an arbitrary address. `HookMiner` searches for a salt that produces an address matching `HOOK_FLAGS`.

/// When running with `forge script`, deterministic deployment uses Foundry's CREATE2 deployer at `0x4e59...B4956C`. The salt must therefore be mined using that deployer address rather than the broadcasting EOA. Mining against the wrong deployer produces a different hook address whose permission bits may be rejected by PoolManager.

contract DeployBondMeBro is Script {
    /// @notice Foundry CREATE2 deployer used for deterministic script deployments.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Mines and deploys a BondMeBro hook with the correct permission bits.

    /// @dev `HOOK_FLAGS` comes directly from `BondMeBro.sol` so the deployment script, hook permissions, and tests share one source of truth. Constructor arguments are part of the CREATE2 init-code hash, so changing the PoolManager or owner requires mining a new salt.

    /// Flow:
    /// 1. Read PoolManager and owner from the environment.
    /// 2. Encode the constructor arguments.
    /// 3. Mine a salt for the required hook permission bits.
    /// 4. Broadcast the deployment.
    /// 5. Verify the deployed address and hook permissions.

    /// @return hook Newly deployed BondMeBro hook.
    function run() external returns (BondMeBro hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        address hookOwner = vm.envAddress("HOOK_OWNER");

        console2.log("chainid     ", block.chainid);
        console2.log("poolManager ", address(poolManager));
        console2.log("owner       ", hookOwner);

        // Salt mining is local computation and happens before broadcasting.
        //
        // Constructor arguments are included in the CREATE2 init-code hash, so a
        // different PoolManager or owner produces a different address and requires
        // mining a new salt.
        bytes memory constructorArgs = abi.encode(poolManager, hookOwner);

        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(BondMeBro).creationCode, constructorArgs);

        console2.log("predicted   ", predicted);
        console2.log("salt        ", vm.toString(salt));

        vm.startBroadcast();

        hook = new BondMeBro{salt: salt}(poolManager, hookOwner);

        vm.stopBroadcast();

        // The deployed address must match the address produced during salt mining.
        require(address(hook) == predicted, "DeployBondMeBro: address mismatch");

        // Confirm that the deployed address bits match the permissions returned by
        // the hook itself.
        Hooks.validateHookPermissions(hook, hook.getHookPermissions());

        console2.log("deployed    ", address(hook));
        console2.log("addr bits   ", uint256(uint160(address(hook))) & 0x3FFF);
    }
}
