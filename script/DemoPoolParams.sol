// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title DemoPoolParams
/// @notice Every number and derivation the BondMeBro demo pool depends on, in one place.
/// @dev Shared by the deployment script and the fork rehearsal so the rehearsal cannot pass
/// against different parameters from the ones that would be broadcast. Testnet demo values
/// only; nothing here is protocol configuration.
library DemoPoolParams {
    // ---------------------------------------------------------------------------------
    // Live Unichain Sepolia addresses
    // ---------------------------------------------------------------------------------

    /// @notice The deployed BondMeBro hook the demo pool is built around.
    address internal constant HOOK = 0x2A07B25994FdE4c772f00d6B89e05E8ad62650C4;

    /// @notice Uniswap v4 PoolManager the hook was constructed with.
    address internal constant POOL_MANAGER = 0x9cB26A7183B2F4515945Dc52CB4195B0d2D06C95;

    /// @notice Uniswap v4 PositionManager, used to mint the liquidity position.
    address internal constant POSITION_MANAGER = 0x12A98709BB5D0641D61458f85dcAFbE17AC2d05c;

    /// @notice Universal Router. The swap path the frontend uses.
    address internal constant UNIVERSAL_ROUTER = 0x7F9B8D606E0F35E5073ABf93695814530b28a37b;

    /// @notice V4Quoter, used to size exact-output limits the way the frontend does.
    address internal constant QUOTER = 0xB2b34025a07af3925313b6B46f8046Ee8FfBa30B;

    /// @notice Permit2. Both the PositionManager and the router pull tokens through it.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Low 14 address bits every BondMeBro deployment must carry.
    uint160 internal constant REQUIRED_HOOK_MASK = 0x10C4;

    // ---------------------------------------------------------------------------------
    // Pool parameters
    // ---------------------------------------------------------------------------------

    /// @notice 0.30% static fee: the ordinary tier, with nothing dynamic to explain.
    uint24 internal constant FEE = 3000;

    /// @notice Tick spacing conventionally paired with the 0.30% tier.
    int24 internal constant TICK_SPACING = 60;

    // ---------------------------------------------------------------------------------
    // Demo tokens
    // ---------------------------------------------------------------------------------

    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant WETH_DECIMALS = 18;

    /// @notice Whole demo units of bUSDC minted to the deployer: 10,000,000.
    uint256 internal constant USDC_SUPPLY = 10_000_000 * 10 ** USDC_DECIMALS;

    /// @notice Whole demo units of bWETH minted to the deployer: 4,000.
    uint256 internal constant WETH_SUPPLY = 4_000 * 10 ** WETH_DECIMALS;

    /// @notice bUSDC deposited as liquidity: 1,000,000, a tenth of supply.
    uint256 internal constant USDC_LIQUIDITY = 1_000_000 * 10 ** USDC_DECIMALS;

    /// @notice bWETH deposited as liquidity: 400 — the same value as the bUSDC side at 2,500.
    uint256 internal constant WETH_LIQUIDITY = 400 * 10 ** WETH_DECIMALS;

    /// @notice Initial human price: 1 bWETH costs this many bUSDC.
    uint256 internal constant USDC_PER_WETH = 2_500;

    // ---------------------------------------------------------------------------------
    // BMB-01 participation thresholds, in RAW UNITS of their own currency.
    //
    //   minBondedAmount  rations the INPUT the pool actually consumes.
    //   minVariableLeg   rations the leg the collateral is carved from — the OUTPUT for an
    //                    exact-input swap, which is the OTHER token.
    //
    // Roughly 100 demo dollars of input and 50 of variable leg, expressed separately in each
    // currency's own units. `setPoolConfig` refuses a variable-leg minimum below BPS (10,000
    // raw units); both values clear that floor by a wide margin, so no eligible trade can
    // round its collateral down to zero.
    // ---------------------------------------------------------------------------------

    /// @notice 100 bUSDC of consumed input.
    uint256 internal constant MIN_INPUT_USDC = 100 * 10 ** USDC_DECIMALS;

    /// @notice 0.04 bWETH of consumed input — the same 100 demo dollars at 2,500.
    uint256 internal constant MIN_INPUT_WETH = 4 * 10 ** (WETH_DECIMALS - 2);

    /// @notice 50 bUSDC of variable leg. 5e7 raw, comfortably above the 10,000 floor.
    uint256 internal constant MIN_LEG_USDC = 50 * 10 ** USDC_DECIMALS;

    /// @notice 0.02 bWETH of variable leg. 2e16 raw, far above the 10,000 floor.
    uint256 internal constant MIN_LEG_WETH = 2 * 10 ** (WETH_DECIMALS - 2);

    // ---------------------------------------------------------------------------------
    // Derivations
    // ---------------------------------------------------------------------------------

    /// @notice sqrtPriceX96 for the intended human price, for whichever ordering occurred.
    /// @dev sqrtPriceX96 = sqrt(price * 2^192), price being raw currency1 per raw currency0.
    /// Feeding two value-equivalent raw amounts in keeps the decimals honest: 2,500 bUSDC and
    /// 1 bWETH are the same money, so their raw ratio IS the pool price.
    function sqrtPriceX96For(bool usdcIsCurrency0) internal pure returns (uint160) {
        uint256 usdcRaw = USDC_PER_WETH * 10 ** USDC_DECIMALS;
        uint256 wethRaw = 10 ** WETH_DECIMALS;

        (uint256 amount0, uint256 amount1) = usdcIsCurrency0 ? (usdcRaw, wethRaw) : (wethRaw, usdcRaw);

        // mulDiv carries the full 512-bit intermediate, so the 2^192 factor cannot overflow
        // the way a plain multiplication would.
        uint256 priceX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);

        uint256 sqrtPrice = FixedPointMathLib.sqrt(priceX192);
        require(sqrtPrice >= TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE, "price out of range");

        return uint160(sqrtPrice);
    }

    /// @notice Reverses the encoding: bUSDC per bWETH implied by sqrtPriceX96, in MILLIONTHS
    /// of a bUSDC.
    /// @dev The extra six digits of resolution keep the round-trip check meaningful instead of
    /// hiding a real error inside integer truncation.
    function impliedUsdcPerWethX6(uint160 sqrtPriceX96, bool usdcIsCurrency0) internal pure returns (uint256) {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);

        // 1 whole bWETH is 10^18 raw and 1 whole bUSDC is 10^6 raw, so the decimal gap is
        // 10^12; the extra 10^6 is the millionths resolution.
        uint256 scale = 10 ** (WETH_DECIMALS - USDC_DECIMALS) * 1e6;

        if (usdcIsCurrency0) {
            // price = raw bWETH per raw bUSDC, a large number. Invert it.
            return FullMath.mulDiv(scale, 1 << 192, priceX192);
        }
        // price = raw bUSDC per raw bWETH, a very small number. Scale it up.
        return FullMath.mulDiv(priceX192, scale, 1 << 192);
    }

    /// @notice Maps the per-token thresholds onto currency0/currency1 for the actual ordering.
    /// @dev Assigning these positionally would silently apply a six-decimal threshold to an
    /// eighteen-decimal token.
    function thresholds(bool usdcIsCurrency0)
        internal
        pure
        returns (uint128 minInput0, uint96 minInput1, uint128 minLeg0, uint128 minLeg1)
    {
        if (usdcIsCurrency0) {
            minInput0 = uint128(MIN_INPUT_USDC);
            minInput1 = uint96(MIN_INPUT_WETH);
            minLeg0 = uint128(MIN_LEG_USDC);
            minLeg1 = uint128(MIN_LEG_WETH);
        } else {
            minInput0 = uint128(MIN_INPUT_WETH);
            minInput1 = uint96(MIN_INPUT_USDC);
            minLeg0 = uint128(MIN_LEG_WETH);
            minLeg1 = uint128(MIN_LEG_USDC);
        }
    }

    /// @notice Largest multiple of `spacing` at or above MIN_TICK.
    /// @dev Solidity truncates toward zero, which for a negative numerator already rounds in
    /// the safe direction.
    function alignedMinTick(int24 spacing) internal pure returns (int24) {
        return (TickMath.MIN_TICK / spacing) * spacing;
    }

    /// @notice Smallest multiple of `spacing` at or below MAX_TICK.
    function alignedMaxTick(int24 spacing) internal pure returns (int24) {
        return (TickMath.MAX_TICK / spacing) * spacing;
    }
}
