// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title MintBondMeBroPosition
/// @notice Mints one protected Uniswap v4 liquidity position through the canonical
///         PositionManager after a BondMeBro pool has been initialized.
///
/// @dev This script uses the standard `MINT_POSITION + CLOSE_CURRENCY` action flow. It does
/// not use the deprecated delta-based mint action, so amount0Max/amount1Max remain real
/// slippage bounds. Permit2 approvals are set by the broadcaster for ERC-20 currencies.
///
/// Required environment variables:
/// - RPC_URL and PRIVATE_KEY (provided to forge script)
/// - POSITION_MANAGER, PERMIT2, LIQUIDITY_OWNER, BOND_HOOK
/// - CURRENCY0, CURRENCY1, POOL_FEE, TICK_SPACING
/// - TICK_LOWER, TICK_UPPER, LIQUIDITY, AMOUNT0_MAX, AMOUNT1_MAX
/// Optional:
/// - SQRT_PRICE_X96 (initializes the pool through PositionManager if supplied)
/// - NATIVE_VALUE (ETH sent for a native currency0 position)
/// - DEADLINE (defaults to block.timestamp + 1 hour)
contract MintBondMeBroPosition is Script {
    using CurrencyLibrary for Currency;

    function run() external returns (uint256 tokenId) {
        IPositionManager positionManager = IPositionManager(vm.envAddress("POSITION_MANAGER"));
        address permit2 = vm.envAddress("PERMIT2");
        address hookAddress = vm.envAddress("BOND_HOOK");
        address owner = vm.envAddress("LIQUIDITY_OWNER");
        PoolKey memory key = _poolKey(hookAddress);

        uint256 nativeValue = vm.envOr("NATIVE_VALUE", uint256(0));
        uint256 deadline = vm.envOr("DEADLINE", block.timestamp + 1 hours);

        vm.startBroadcast();
        _approveCurrency(key.currency0, permit2, address(positionManager));
        _approveCurrency(key.currency1, permit2, address(positionManager));

        uint256 initialPrice = vm.envOr("SQRT_PRICE_X96", uint256(0));
        if (initialPrice != 0) positionManager.initializePool(key, uint160(initialPrice));

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            int24(vm.envInt("TICK_LOWER")),
            int24(vm.envInt("TICK_UPPER")),
            vm.envUint("LIQUIDITY"),
            uint128(vm.envUint("AMOUNT0_MAX")),
            uint128(vm.envUint("AMOUNT1_MAX")),
            owner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);

        positionManager.modifyLiquidities{value: nativeValue}(abi.encode(actions, params), deadline);
        vm.stopBroadcast();

        // PositionManager increments nextTokenId after minting. Reading it after the call
        // gives the token id just created without relying on event parsing in the script.
        tokenId = positionManager.nextTokenId() - 1;
        console2.log("position token id ", tokenId);
    }

    function _approveCurrency(Currency currency, address permit2, address positionManager) internal {
        if (currency.isAddressZero()) return;

        IERC20Minimal(Currency.unwrap(currency)).approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2)
            .approve(Currency.unwrap(currency), positionManager, type(uint160).max, type(uint48).max);
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
