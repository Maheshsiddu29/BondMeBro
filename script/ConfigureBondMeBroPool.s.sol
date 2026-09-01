// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

/// @title ConfigureBondMeBroPool
/// @notice Updates the per-currency custody thresholds and bond rate for an initialized pool.
///
/// @dev The broadcaster must be the immutable `OWNER` configured at deployment. Use an all-zero
///      triple to disable bonding for a pool; partial configurations are rejected by the hook.
///
/// Required environment variables:
/// - RPC_URL and PRIVATE_KEY (provided to forge script)
/// - BOND_HOOK, CURRENCY0, CURRENCY1, POOL_FEE, TICK_SPACING
/// - POOL_MIN_BONDED_AMOUNT0, POOL_MIN_BONDED_AMOUNT1, POOL_BOND_BPS
contract ConfigureBondMeBroPool is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        address hookAddress = vm.envAddress("BOND_HOOK");
        BondMeBro hook = BondMeBro(payable(hookAddress));
        PoolKey memory key = _poolKey(hookAddress);

        uint256 rawMinBondedAmount0 = vm.envUint("POOL_MIN_BONDED_AMOUNT0");
        uint256 rawMinBondedAmount1 = vm.envUint("POOL_MIN_BONDED_AMOUNT1");
        uint256 rawPoolBondBps = vm.envUint("POOL_BOND_BPS");
        require(rawMinBondedAmount0 <= type(uint96).max, "ConfigureBondMeBroPool: amount0 threshold overflows uint96");
        require(rawMinBondedAmount1 <= type(uint96).max, "ConfigureBondMeBroPool: amount1 threshold overflows uint96");
        require(rawPoolBondBps <= 100, "ConfigureBondMeBroPool: POOL_BOND_BPS must be <= 100");

        uint96 minBondedAmount0 = uint96(rawMinBondedAmount0);
        uint96 minBondedAmount1 = uint96(rawMinBondedAmount1);
        uint16 poolBondBps = uint16(rawPoolBondBps);

        vm.startBroadcast();
        hook.setPoolConfig(key, minBondedAmount0, minBondedAmount1, poolBondBps);
        vm.stopBroadcast();

        PoolId id = key.toId();
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("min amount0  ", uint256(minBondedAmount0));
        console2.log("min amount1  ", uint256(minBondedAmount1));
        console2.log("bond bps     ", uint256(poolBondBps));
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
