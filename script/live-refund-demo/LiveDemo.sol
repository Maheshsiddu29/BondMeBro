// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @dev The Universal Router's one entry point, declared exactly as the frontend declares it.
interface IUniversalRouterMinimal {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPermit2Minimal {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @dev THE DEPLOYED ROUTER'S SWAP PARAMETERS, WHICH ARE NOT THE PINNED ONES.
///
/// The Universal Router live on Unichain Sepolia was built against a v4-periphery that
/// predates `minHopPriceX36`. Its calldata decoder is strict: an extra word shifts the
/// hookData offset and the call reverts inside `unlockCallback` before any swap happens.
/// This shape is the one proven to execute against that router.
struct RouterExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @title LiveDemo
/// @notice Addresses and calldata for the live Unichain Sepolia refund rehearsal.
/// @dev Testnet demo automation only. Nothing here changes protocol behaviour: it builds the
/// same router calldata and the same version 2 hookData the frontend already sends, so the
/// rehearsal exercises the deployed contract rather than a re-implementation of it.
library LiveDemo {
    uint256 internal constant CHAIN_ID = 1301;

    address internal constant HOOK = 0x2A07B25994FdE4c772f00d6B89e05E8ad62650C4;
    address internal constant POOL_MANAGER = 0x9cB26A7183B2F4515945Dc52CB4195B0d2D06C95;
    address internal constant UNIVERSAL_ROUTER = 0x7F9B8D606E0F35E5073ABf93695814530b28a37b;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice currency0. 18 decimals.
    address internal constant BWETH = 0x38293A5D8A879Af5e2Eb2D3eb80121CA82f6acC1;

    /// @notice currency1. 6 decimals.
    address internal constant BUSDC = 0x49d5E60035e13b3736e5D26ef7ecEAbA52f9cC39;

    address internal constant DEPLOYER = 0xA5B709025224bA08B8eFfF1b0D1d28E970A34Cf3;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    uint160 internal constant REQUIRED_HOOK_MASK = 0x10C4;

    /// @notice The forward leg: 10,000 bUSDC of exact input.
    uint128 internal constant FORWARD_USDC = 10_000e6;

    /// @dev Universal Router command byte for a V4 swap plan.
    bytes internal constant V4_SWAP = hex"10";

    /// @dev ActionConstants.OPEN_DELTA: settle the whole debt, take the whole credit.
    uint256 internal constant OPEN_DELTA = 0;

    function poolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(BWETH),
            currency1: Currency.wrap(BUSDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    /// @notice hookData version 2: 1 version byte, 20 address bytes, 16 amount bytes.
    function hookDataV2(address refundRecipient, uint128 maxBondAmount) internal pure returns (bytes memory data) {
        data = abi.encodePacked(uint8(2), refundRecipient, maxBondAmount);
        require(data.length == 37, "LiveDemo: hookData must be 37 bytes");
    }

    /// @notice Builds the exact-input router payload the frontend builds.
    /// @param zeroForOne True to spend currency0 (bWETH), false to spend currency1 (bUSDC).
    /// @param amountIn Exact input, in that token's raw units.
    /// @param amountOutMinimum Slippage floor on the NET output, after any collateral.
    /// @param recipient Output recipient and refund recipient.
    function exactInputCall(bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, address recipient)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PoolKey memory key = poolKey();
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        // Exact input carries the unbounded ceiling; protection is amountOutMinimum.
        bytes memory hookData = hookDataV2(recipient, type(uint128).max);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RouterExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: hookData
            })
        );
        params[1] = abi.encode(inputCurrency, OPEN_DELTA, true);
        params[2] = abi.encode(outputCurrency, recipient, OPEN_DELTA);

        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        commands = V4_SWAP;
    }

    /// @notice Sends one exact-input swap through the deployed Universal Router.
    function swapExactInput(bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, address recipient) internal {
        (bytes memory commands, bytes[] memory inputs) =
            exactInputCall(zeroForOne, amountIn, amountOutMinimum, recipient);
        IUniversalRouterMinimal(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 1200);
    }
}
