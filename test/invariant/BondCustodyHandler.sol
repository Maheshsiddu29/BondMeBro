// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro} from "../../src/BondMeBro.sol";
import {HookDataCodec} from "../../src/libraries/HookDataCodec.sol";

/// @title BondCustodyHandler

/// @notice Fuzz handler that drives BondMeBro through exact-input and exact-output swaps in both directions so the custody invariants can be checked across sequences of swaps.

/// @dev The handler tracks two independent totals for each currency. `measuredBondTotal` records how much the hook's real ERC-20 balance increased, while `expectedBondTotal` recomputes how much collateral the BondMeBro formulas say should have been taken. Comparing the two helps detect accounting or bond-calculation errors.

/// Reverted swaps are expected during fuzzing. A revert must leave custody accounting unchanged, so ghost totals are updated only after a successful swap.

contract BondCustodyHandler is Test {
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    BondMeBro internal immutable hook;

    Currency internal immutable currency0;
    Currency internal immutable currency1;

    PoolKey internal key_;

    uint256 internal constant BPS = 10_000;

    /// @dev Fuzzed swap sizes stay between `FLOOR` and `CEIL` so the campaign can exercise both bonded and unbonded paths without spending most calls on dust or liquidity-limit failures.
    uint256 internal constant FLOOR = 1e12;
    uint256 internal constant CEIL = 1e18;

    address internal constant REFUND_RECIPIENT = address(0xB0B);

    /// @notice Total collateral the hook actually received, tracked separately for each currency.
    mapping(Currency => uint256) public measuredBondTotal;

    /// @notice Total collateral the formulas independently predict should have been taken, tracked separately for each currency.
    mapping(Currency => uint256) public expectedBondTotal;

    /// @notice Number of successful bonded exact-input swaps exercised by the campaign.
    uint256 public exactInputBonded;

    /// @notice Number of successful unbonded exact-input swaps exercised by the campaign.
    uint256 public exactInputUnbonded;

    /// @notice Number of successful bonded exact-output swaps exercised by the campaign.
    uint256 public exactOutputBonded;

    /// @notice Number of successful unbonded exact-output swaps exercised by the campaign.
    uint256 public exactOutputUnbonded;

    /// @notice Number of swap attempts that reverted.
    uint256 public reverted;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        BondMeBro _hook,
        PoolKey memory _key,
        Currency _currency0,
        Currency _currency1
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        hook = _hook;
        key_ = _key;
        currency0 = _currency0;
        currency1 = _currency1;
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a fuzzed exact-input swap.

    /// @dev For exact-input, BondMeBro calculates the bond from the requested gross input and takes it in `beforeSwap`. The generated amount intentionally lands either below or above the direction-specific bonding threshold so both paths are exercised.

    /// When `tightCeiling` is true and a bond is expected, `maxBondAmount` is set one wei below the expected bond. The swap should then revert, which helps prove that failed swaps leave custody accounting unchanged.

    /// @param amountSeed Fuzz value used to choose the swap amount.
    /// @param zeroForOne Swap direction.
    /// @param tightCeiling Whether to deliberately make the bond ceiling too small.
    function swapExactInput(
        uint256 amountSeed,
        bool zeroForOne,
        bool tightCeiling
    )
        external
    {
        (Currency inputCurrency,) =
            _currencies(zeroForOne);

        uint256 minBondedAmount =
            _threshold(zeroForOne);

        (,, uint16 bondBps) =
            hook.poolConfig(key_.toId());

        uint256 grossInput =
            _sizeStraddlingThreshold(
                amountSeed,
                minBondedAmount
            );

        // Independently calculate the bond expected from an exact-input swap.
        uint256 expectedBond =
            grossInput < minBondedAmount
                ? 0
                : (grossInput * bondBps) / BPS;

        uint128 ceiling =
            _ceiling(
                expectedBond,
                tightCeiling
            );

        // A zero maxBondAmount cannot produce valid hookData.
        if (ceiling == 0) return;

        _execute(
            -int256(grossInput),
            zeroForOne,
            inputCurrency,
            expectedBond,
            ceiling,
            expectedBond > 0,
            true
        );
    }

    /// @notice Executes a fuzzed exact-output swap.

    /// @dev Exact-output collateral cannot be predicted from `amountOut` alone because the bond depends on the amount the pool actually consumes. `_execute` measures the real pool input after the swap and independently applies the exact-output bond formula.

    /// The output amount is chosen around the input-side threshold. At the test pool's seeded price this gives the campaign a useful mix of bonded and unbonded exact-output swaps.

    /// @param amountSeed Fuzz value used to choose the requested output amount.
    /// @param zeroForOne Swap direction.
    /// @param tightCeiling Whether to use a deliberately restrictive bond ceiling.
    function swapExactOutput(
        uint256 amountSeed,
        bool zeroForOne,
        bool tightCeiling
    )
        external
    {
        (Currency inputCurrency,) =
            _currencies(zeroForOne);

        uint256 amountOut =
            _sizeStraddlingThreshold(
                amountSeed,
                _threshold(zeroForOne)
            );

        // The real exact-output bond is unknown until execution.
        //
        // A value of 1 is intentionally restrictive; otherwise use the maximum
        // uint128 ceiling so normal bonded swaps can succeed.
        uint128 ceiling =
            tightCeiling
                ? 1
                : type(uint128).max;

        _execute(
            int256(amountOut),
            zeroForOne,
            inputCurrency,
            0,
            ceiling,
            false,
            false
        );
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the input and output currencies for the selected swap direction.
    function _currencies(
        bool zeroForOne
    )
        internal
        view
        returns (
            Currency inputCurrency,
            Currency outputCurrency
        )
    {
        return
            zeroForOne
                ? (currency0, currency1)
                : (currency1, currency0);
    }

    /// @dev Returns the bonding threshold denominated in the input currency for the selected direction.
    function _threshold(
        bool zeroForOne
    )
        internal
        view
        returns (uint256)
    {
        (
            uint128 min0,
            uint96 min1,
        ) = hook.poolConfig(key_.toId());

        return
            zeroForOne
                ? uint256(min0)
                : uint256(min1);
    }

    /// @dev Chooses swap sizes from both sides of the bonding threshold. Roughly half of the seeds produce an amount below the threshold and half produce an amount at or above it.

    /// A single large uniform range would heavily favour one side when the threshold occupies only a small part of that range, causing the invariant campaign to miss the unbonded or bonded path. Splitting the range first gives both paths regular coverage.

    function _sizeStraddlingThreshold(
        uint256 seed,
        uint256 threshold
    )
        internal
        pure
        returns (uint256)
    {
        // If the threshold is outside the useful fuzzing window, choose any
        // swappable amount inside the configured range.
        if (
            threshold <= FLOOR ||
            threshold >= CEIL
        ) {
            return
                FLOOR +
                (seed % (CEIL - FLOOR));
        }

        if (seed & 1 == 0) {
            // Strictly below threshold => unbonded.
            return
                FLOOR +
                (seed % (threshold - FLOOR));
        }

        // At or above threshold => bonded.
        return
            threshold +
            (seed % (CEIL - threshold));
    }

    /// @dev Returns a permissive bond ceiling for normal swaps or one wei below the expected bond when testing the rejection path.
    function _ceiling(
        uint256 expectedBond,
        bool tight
    )
        internal
        pure
        returns (uint128)
    {
        if (!tight) {
            return type(uint128).max;
        }

        // No bond is expected, so there is nothing useful to constrain.
        if (expectedBond == 0) {
            return type(uint128).max;
        }

        // One wei below the expected bond should force BondMeBro to revert.
        return uint128(expectedBond - 1);
    }

    /// @dev Executes a swap, measures the real custody change, and updates the independent ghost accounting only if the swap succeeds.

    /// For exact-input swaps, the expected bond is already known before execution. For exact-output swaps, the expected bond is recomputed from the actual amount consumed by PoolManager.

    function _execute(
        int256 amountSpecified,
        bool zeroForOne,
        Currency inputCurrency,
        uint256 expectedBondIfExactInput,
        uint128 ceiling,
        bool expectBondedExactInput,
        bool isExactInput
    )
        internal
    {
        uint256 hookBefore =
            inputCurrency.balanceOf(address(hook));

        uint256 managerBefore =
            inputCurrency.balanceOf(address(manager));

        try swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            HookDataCodec.encode(
                REFUND_RECIPIENT,
                ceiling
            )
        ) {
            // Real collateral received by the hook.
            uint256 bondTaken =
                inputCurrency.balanceOf(address(hook)) -
                hookBefore;

            // Real input retained by PoolManager.
            uint256 poolInput =
                inputCurrency.balanceOf(address(manager)) -
                managerBefore;

            measuredBondTotal[inputCurrency] +=
                bondTaken;

            if (isExactInput) {
                // Exact-input expected collateral was calculated before execution.
                expectedBondTotal[inputCurrency] +=
                    expectedBondIfExactInput;

                if (expectBondedExactInput) {
                    exactInputBonded++;
                } else {
                    exactInputUnbonded++;
                }

                return;
            }

            // Exact-output bond:
            //
            // bond = poolInput * bondBps / (BPS - bondBps)
            //
            // This independently reconstructs the same gross-input economic rate
            // from what the pool actually consumed.
            (,, uint16 bondBps) =
                hook.poolConfig(key_.toId());

            uint256 candidateBond =
                FullMath.mulDiv(
                    poolInput,
                    bondBps,
                    BPS - uint256(bondBps)
                );

            uint256 candidateGross =
                poolInput +
                candidateBond;

            uint256 expectedBond =
                candidateGross < _threshold(zeroForOne)
                    ? 0
                    : candidateBond;

            expectedBondTotal[inputCurrency] +=
                expectedBond;

            if (expectedBond > 0) {
                exactOutputBonded++;
            } else {
                exactOutputUnbonded++;
            }
        } catch {
            // Failed swaps must not update either ghost accounting total.
            reverted++;
        }
    }
}