// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

/// @title DonateBondPot
/// @notice Production operations script that pushes one currency's accumulated insurance
///         pot into the selected pool through `PoolManager.donate`.
///
/// @dev The hook enforces PoolManager's signed-int128 donation limit and drains a very large
///      pot over multiple calls. An empty pot is reported as a successful no-op. If there is
///      no in-range liquidity, a non-empty donation reverts and the pot remains intact.
///
/// Required environment variables:
/// - RPC_URL and PRIVATE_KEY (provided to forge script)
/// - BOND_HOOK
/// - CURRENCY0, CURRENCY1, POT_CURRENCY, POOL_FEE, TICK_SPACING
contract DonateBondPot is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        address hookAddress = vm.envAddress("BOND_HOOK");
        BondMeBro hook = BondMeBro(payable(hookAddress));
        PoolKey memory key = _poolKey(hookAddress);
        Currency currency = Currency.wrap(vm.envAddress("POT_CURRENCY"));
        PoolId id = key.toId();
        uint256 pot = hook.insurancePot(id, currency);

        if (pot == 0) {
            console2.log("nothing to donate; pot is empty");
            console2.logBytes32(PoolId.unwrap(id));
            return;
        }

        vm.startBroadcast();
        hook.donatePot(key, currency);
        vm.stopBroadcast();

        console2.log("donated currency ", Currency.unwrap(currency));
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(id));
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
