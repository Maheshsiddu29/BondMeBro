// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title SwapBondMeBro
/// @notice Executes one exact-input, single-hop v4 swap through the canonical Universal
///         Router. This is the production-shaped smoke test for opening a BondMeBro bond.
///
/// @dev The Universal Router's V4_SWAP command receives the standard v4 action plan:
///      SWAP_EXACT_IN_SINGLE, SETTLE, TAKE. The fixed 37-byte hookData carries TRADER and
///      MAX_BOND_AMOUNT through the router so a refund and piggyback reward go to the end
///      user rather than the router contract. Set a non-zero SWAP_AMOUNT_OUT_MINIMUM outside
///      a demo.
///
/// Required environment variables:
/// - RPC_URL and PRIVATE_KEY (provided to forge script)
/// - UNIVERSAL_ROUTER, PERMIT2, TRADER, BOND_HOOK
/// - CURRENCY0, CURRENCY1, POOL_FEE, TICK_SPACING
/// - ZERO_FOR_ONE, SWAP_AMOUNT_IN, SWAP_AMOUNT_OUT_MINIMUM, MAX_BOND_AMOUNT
/// Optional:
/// - DEADLINE (defaults to block.timestamp + 20 minutes)
contract SwapBondMeBro is Script {
    using CurrencyLibrary for Currency;

    bytes1 internal constant V4_SWAP_COMMAND = 0x10;

    struct SwapRequest {
        address router;
        address permit2;
        address trader;
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint128 maxBondAmount;
        uint256 deadline;
    }

    function run() external {
        SwapRequest memory request = _request();
        _execute(request);

        console2.log("swap executed through Universal Router");
        console2.log("trader       ", request.trader);
        console2.log("amount in    ", request.amountIn);
        console2.log("zeroForOne   ", request.zeroForOne);
    }

    function _request() internal view returns (SwapRequest memory request) {
        request.router = vm.envAddress("UNIVERSAL_ROUTER");
        request.permit2 = vm.envAddress("PERMIT2");
        address hookAddress = vm.envAddress("BOND_HOOK");
        request.trader = vm.envAddress("TRADER");
        request.key = _poolKey(hookAddress);

        require(request.router.code.length != 0, "SwapBondMeBro: invalid UNIVERSAL_ROUTER");
        require(request.permit2.code.length != 0, "SwapBondMeBro: invalid PERMIT2");
        require(hookAddress.code.length != 0, "SwapBondMeBro: invalid BOND_HOOK");
        require(request.trader != address(0), "SwapBondMeBro: invalid TRADER");

        request.zeroForOne = vm.envBool("ZERO_FOR_ONE");
        request.amountIn = _envUint128("SWAP_AMOUNT_IN");
        request.amountOutMinimum = _envUint128("SWAP_AMOUNT_OUT_MINIMUM");
        request.maxBondAmount = _envOrUint128("MAX_BOND_AMOUNT", type(uint128).max);
        request.deadline = vm.envOr("DEADLINE", block.timestamp + 20 minutes);
    }

    function _envUint128(string memory name) internal view returns (uint128 value) {
        uint256 raw = vm.envUint(name);
        require(raw <= type(uint128).max, "SwapBondMeBro: uint128 environment overflow");
        value = uint128(raw);
    }

    function _envOrUint128(string memory name, uint128 defaultValue) internal view returns (uint128 value) {
        uint256 raw = vm.envOr(name, uint256(defaultValue));
        require(raw <= type(uint128).max, "SwapBondMeBro: uint128 environment overflow");
        value = uint128(raw);
    }

    function _execute(SwapRequest memory request) internal {
        Currency inputCurrency = request.zeroForOne ? request.key.currency0 : request.key.currency1;
        (bytes memory commands, bytes[] memory inputs) = _encodePlan(request, inputCurrency);

        vm.startBroadcast();
        _approveInput(inputCurrency, request.permit2, request.router, request.amountIn);
        IUniversalRouterLike(request.router).execute{value: inputCurrency.isAddressZero() ? request.amountIn : 0}(
            commands, inputs, request.deadline
        );
        vm.stopBroadcast();
    }

    function _encodePlan(SwapRequest memory request, Currency inputCurrency)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        Currency outputCurrency = request.zeroForOne ? request.key.currency1 : request.key.currency0;
        IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
            poolKey: request.key,
            zeroForOne: request.zeroForOne,
            amountIn: request.amountIn,
            amountOutMinimum: request.amountOutMinimum,
            minHopPriceX36: 0,
            hookData: HookDataCodec.encode(request.trader, request.maxBondAmount)
        });

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)), bytes1(uint8(Actions.SETTLE)), bytes1(uint8(Actions.TAKE))
        );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(inputCurrency, uint256(ActionConstants.OPEN_DELTA), true);
        actionParams[2] = abi.encode(outputCurrency, request.trader, uint256(ActionConstants.OPEN_DELTA));

        commands = abi.encodePacked(V4_SWAP_COMMAND);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);
    }

    function _approveInput(Currency currency, address permit2, address routerAddress, uint128 amount) internal {
        if (currency.isAddressZero()) return;

        // Scope both allowances to this operation. The broadcaster can run the script again
        // and approve a new amount without leaving a reusable unlimited router allowance.
        IERC20Minimal(Currency.unwrap(currency)).approve(permit2, amount);
        IAllowanceTransfer(permit2)
            .approve(Currency.unwrap(currency), routerAddress, uint160(amount), uint48(block.timestamp + 1 hours));
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

interface IUniversalRouterLike {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
