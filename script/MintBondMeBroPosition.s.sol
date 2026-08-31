// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

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
/// - POOL_MANAGER, POSITION_MANAGER, PERMIT2, LIQUIDITY_OWNER, BOND_HOOK
/// - CURRENCY0, CURRENCY1, POOL_FEE, TICK_SPACING
/// - TICK_LOWER, TICK_UPPER, LIQUIDITY, AMOUNT0_MAX, AMOUNT1_MAX
/// Optional:
/// - SQRT_PRICE_X96 (initializes the pool only when it is not already initialized)
/// - NATIVE_VALUE (ETH sent for a native currency0 position)
/// - DEADLINE (defaults to block.timestamp + 1 hour)
contract MintBondMeBroPosition is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant CURRENT_HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external returns (uint256 tokenId) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IPositionManager positionManager = IPositionManager(vm.envAddress("POSITION_MANAGER"));
        address permit2 = vm.envAddress("PERMIT2");
        address hookAddress = vm.envAddress("BOND_HOOK");
        address owner = vm.envAddress("LIQUIDITY_OWNER");
        require(address(poolManager).code.length != 0, "MintBondMeBroPosition: invalid POOL_MANAGER");
        require(address(positionManager).code.length != 0, "MintBondMeBroPosition: invalid POSITION_MANAGER");
        require(permit2.code.length != 0, "MintBondMeBroPosition: invalid PERMIT2");
        require(hookAddress.code.length != 0, "MintBondMeBroPosition: invalid BOND_HOOK");
        require(owner != address(0), "MintBondMeBroPosition: invalid LIQUIDITY_OWNER");
        require(
            address(BondMeBro(payable(hookAddress)).poolManager()) == address(poolManager),
            "MintBondMeBroPosition: manager mismatch"
        );
        require(
            (uint160(hookAddress) & CURRENT_HOOK_FLAGS) == CURRENT_HOOK_FLAGS,
            "MintBondMeBroPosition: legacy hook permissions"
        );
        PoolKey memory key = _poolKey(hookAddress);

        uint256 nativeValue = vm.envOr("NATIVE_VALUE", uint256(0));
        uint256 deadline = vm.envOr("DEADLINE", block.timestamp + 1 hours);

        vm.startBroadcast();
        _approveCurrency(key.currency0, permit2, address(positionManager));
        _approveCurrency(key.currency1, permit2, address(positionManager));

        uint256 initialPrice = vm.envOr("SQRT_PRICE_X96", uint256(0));
        (uint160 existingSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (existingSqrtPriceX96 == 0) {
            require(initialPrice != 0, "MintBondMeBroPosition: missing SQRT_PRICE_X96");
            positionManager.initializePool(key, uint160(initialPrice));
        } else {
            console2.log("pool already initialized; skipping initializePool");
        }

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
        IAllowanceTransfer(permit2).approve(
            Currency.unwrap(currency), positionManager, type(uint160).max, type(uint48).max
        );
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
