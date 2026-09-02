// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

/// @title SettleBondMeBro
/// @notice Production operations script for permissionless bond settlement.
///
/// @dev The hook is keeperless by design, but an operator, cron job, or public keeper can
///      still call this script for profitable liveness in a quiet pool. Settlement is capped
///      inside the contract at 32 bonds even if MAX_COUNT is set higher.
///
/// Required environment variables:
/// - RPC_URL and PRIVATE_KEY (provided to forge script)
/// - BOND_HOOK
/// - CURRENCY0, CURRENCY1, POOL_FEE, TICK_SPACING
/// Optional:
/// - MAX_COUNT (defaults to 32)
contract SettleBondMeBro is Script {
    using PoolIdLibrary for PoolKey;

    function run() external returns (uint256 settled) {
        address hookAddress = vm.envAddress("BOND_HOOK");
        BondMeBro hook = BondMeBro(payable(hookAddress));
        PoolKey memory key = _poolKey(hookAddress);
        uint256 maxCount = vm.envOr("MAX_COUNT", uint256(32));

        vm.startBroadcast();
        settled = hook.settleBonds(key, maxCount);
        vm.stopBroadcast();

        console2.log("settled    ", settled);
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(key.toId()));
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
