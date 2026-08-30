// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

/// @title DeployBondMeBro
/// @notice Mines a CREATE2 salt for the hook's permission bits and deploys it.
///
/// @dev THE ONE THING THAT BREAKS EVERY v4 DEPLOY SCRIPT.
///      In `forge test` the deployer is `address(this)`. In `forge script` it is NOT the
///      broadcasting EOA — Foundry routes `new C{salt: s}(...)` through the deterministic
///      CREATE2 factory at 0x4e59b44847b379578588920cA78FbF26c0B4956C. A salt mined against
///      your own EOA produces a different address and `initialize` reverts with
///      HookAddressNotValid. `CREATE2_DEPLOYER` below is what HookMiner must be given.
///
/// @dev Phase 1 note: AFTER_SWAP_RETURNS_DELTA_FLAG was added — the hook now takes bonds
///      out of the swap itself — so the permission bits, and therefore EVERY previously
///      mined salt/address, changed. Config is part of the constructor, hence part of the
///      mined address: change any knob, re-mine.
contract DeployBondMeBro is Script {
    /// @notice Canonical deterministic-deployment proxy, same address on every chain.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice The permission bits that must be encoded in the hook's address.
    /// @dev Must stay in lockstep with `getHookPermissions()`. Change one, re-mine the salt.
    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external returns (BondMeBro hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        // Sane defaults with env overrides, e.g. BOND_BPS=500 forge script ...
        BondMeBro.Config memory cfg = BondMeBro.Config({
            bondBps: uint16(vm.envOr("BOND_BPS", uint256(500))),
            minImpactTicks: uint24(vm.envOr("MIN_IMPACT_TICKS", uint256(25))),
            refundTolTicks: uint24(vm.envOr("REFUND_TOL_TICKS", uint256(10))),
            observationBlocks: uint32(vm.envOr("OBSERVATION_BLOCKS", uint256(50))),
            maxAbsTickDelta: uint24(vm.envOr("MAX_ABS_TICK_DELTA", uint256(9116) / 18)), // TruncGeoOracle's cap scaled to ~15-min window
            settlerFeeBps: uint16(vm.envOr("SETTLER_FEE_BPS", uint256(500))),
            maxSettlesPerSwap: uint8(vm.envOr("MAX_SETTLES_PER_SWAP", uint256(4)))
        });

        console2.log("chainid     ", block.chainid);
        console2.log("poolManager ", address(poolManager));

        // Mining is pure computation — deliberately OUTSIDE the broadcast so it costs no gas
        // and sends no transaction. It brute-forces salts until the resulting CREATE2 address
        // has the right low bits.
        bytes memory constructorArgs = abi.encode(poolManager, cfg);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(BondMeBro).creationCode, constructorArgs);

        console2.log("predicted   ", predicted);
        console2.log("salt        ", vm.toString(salt));

        vm.startBroadcast();
        hook = new BondMeBro{salt: salt}(poolManager, cfg);
        vm.stopBroadcast();

        // Belt and braces: if these disagree, something about the deployer assumption is wrong
        // and you want to know now, not when initialize() reverts.
        require(address(hook) == predicted, "DeployBondMeBro: address mismatch");
        Hooks.validateHookPermissions(hook, hook.getHookPermissions());

        console2.log("deployed    ", address(hook));
        console2.log("addr bits   ", uint256(uint160(address(hook))) & 0x3FFF);
    }
}
