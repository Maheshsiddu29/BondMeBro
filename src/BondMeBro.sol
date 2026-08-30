// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {HookDataCodec} from "./libraries/HookDataCodec.sol";

// below constant is important for the hook to work properly. It is the permission bits that the hook's deployed address must encode. It is a single source of truth shared with getHookPermissions() and the test suite.getHookPermissions(), test suite, and the deploy script's miner all three derive from this one constant.

uint160 constant HOOK_FLAGS = uint160(
    Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
);

/// @title BondMeBro
/// @notice A hook that takes a collateral bond on swaps that exceed a per-pool threshold, and returns it after the swap. The bond is sized as a fraction of gross input, and is taken from the trader's input currency. The hook supports both exact-input and exact-output swaps, single-hop, ERC-20 <-> ERC-20, both directions.

/// @dev please note that BondMeBro currently handles bondCustody only. It can calculate, validate and holds the bond, but bond settlement is yet to be designed and implemented.For now , it doesnt store long-term bond, track maturity, settle traders and refund them but it is part of the current roadmap and is currently under development. This hook is stateless design, so it does'nt store any state between beforeSwap and afterSwap.

/// for exact-input swaps , the bond is taken out from the funds that trader planned to spend on the trade/swap.For instance, if trader wants to swap 1000 USDC for ETH , only 999 USDC goes into the pool and 1 USDC is taken as bond and held as collateral. Trader does'nt need to pay 10001 USDC for the swap. The bond is taken as same currency as the i/p currency of the swap.

///for exact-output swaps, it is difficult to calculate the bond amount, coz for exact-output swaps the trader specifies the o/p amount they want to receive. So, pool determines the exact ampunt during the execution. For that reason, the bond is added on top of the funds that trader planned to spend on the trade/swap. For instance, if trader wants Trader requests exactly 1 ETH , then pool requires 1000 USDC to give 1 ETH. The hook will take 10 USDC as bond and send 1000 USDC to the pool. So, the total amount spent by trader is 1010 USDC. The bond is taken as same currency as the i/p currency of the swap.The trader's `maxBondAmount` and the router's exact-output maximum-input protection limit how much additional input may be charged.

///For Custody, bonds are always taken in the input currency of the swap. The hook does not support cross-currency custody.Exact-input swap use 'beforeSwapDelta' and exact-output swaps use 'afterSwapDelta', actual amount is known only after the swap is executed by the pool. The exact-output swap doesnt store temporary information between 'beforeSwap' and 'afterSwap'; the required hookData is validated again when needed.abi

///For now , this hook does'nt support multi-hop swaps,native currency, fee on transfer tokens and rebasing. These features to be added considering the time left for the hookathon.

contract BondMeBro is BaseHook {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /*              CONSTANTS            /*/

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Max bond rate allowed by the contract is 1% of gross input i;e 100 bps.
    /// @dev This is a compile-time constant and cannot be changed by the owner.Keeping Max bond rate at 1% gives large safety margin from INV-NOOP boundary , where bond would equal to trader's full input

    uint16 public constant MAX_BOND_BPS = 100;

    /*              TYPES            /*/

    /// @notice Per-pool bonding parameters. Packs into one storage slot (128 + 96 + 16 = 240 bits).

    /// @dev TWO THRESHOLDS, ONE PER INPUT CURRENCY.

    ///A pool can be traded in either direction, so either currency may become the swap's input currency. When the currencies have different decimals or economic scales, a single raw-unit threshold cannot represent an appropriate threshold for both directions.

    /// Example: in a USDC/WETH pool, a raw threshold of `1e6` represents1 USDC on a 6-decimal USDC side, but only `1e-12` WETH on an18-decimal WETH side. Each input currency therefore has its ownthreshold denominated in that currency's raw units.

    ///`uint96` is used for the currency1 threshold so the complete configremains in one 256-bit storage slot. Its maximum value is approximately`7.9e28` raw units, equivalent to roughly 79 billion tokens for an18-decimal currency, which is far above any realistic bonding threshold.

    /// Keeping the config in one slot avoids introducing an additional storageslot read on swap paths. This is particularly useful for bondedexact-output `afterSwap`, which is already above its target gas budget.

    /// @param minBondedAmount0 Minimum gross input that requires collateral when  currency0 is the input (`zeroForOne == true`), expressed in raw  currency0 units. See ADR-0001 §3.1.

    /// @param minBondedAmount1 Minimum gross input that requires collateral when  currency1 is the input (`zeroForOne == false`), expressed in raw  currency1 units.

    /// @param bondBps Collateral rate as a fraction of gross input, expressed in  basis points. The rate is direction-independent because only absolute  token thresholds require per-currency scaling.
    struct PoolConfig {
        uint128 minBondedAmount0;
        uint96 minBondedAmount1;
        uint16 bondBps;
    }

    /*//////////////////////////////////////////////////////////////
                                  STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The only address that may configure pools.
    /// @dev ownership cannot be transferred or renounced. This avoids ownership-transfer complexity at the cost of key rotation. Owner powers are limited to configuring per-pool bonding parameters.
    address public immutable owner;

    /// @notice Bonding parameters per pool. A pool with no entry never bonds.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Number of times `afterInitialize` has fired.
    /// @dev we kept afterInitializeCount as public variable to check if the hook is called after initialize in the test suite. It is not used for any other purpose.It is safe to keep because it only increases when the pool is initialized, not every time when someone swaps. This does'nt make normal trading expensive.
    /// We used 'beforeSwapCount' and 'afterSwapCount' before, but they were removed because they wrote to storage on every swap, which costs a lot of gas.
    uint256 public afterInitializeCount;

    /// @notice Ticks observed immediately before and after the most recent swap.
    /// @dev As of now lastTickBefore and lastTickAfter only remembers price tick before and after the most recent swap. They can tell price moved by '30 ticks', but not whether it was toxic trade or not. So theya are just ddebug information for now.
    int24 public lastTickBefore;
    int24 public lastTickAfter;

    /*//////////////////////////////////////////////////////////////
                              EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when one of the hook callbacks executes.
    event CallbackFired(string which, int24 tick);

    /// @notice Emitted when bonding parameters are changed for a pool.
    /// @param id Pool being configured.
    /// @param minBondedAmount0 Minimum bonded input when currency0 is the input.
    /// @param minBondedAmount1 Minimum bonded input when currency1 is the input.
    /// @param bondBps Bond rate in basis points of gross input.
    event PoolConfigured(PoolId indexed id, uint128 minBondedAmount0, uint96 minBondedAmount1, uint16 bondBps);

    /// @notice Emitted when BondMeBro takes collateral from a swap.
    /// @param id Pool where the swap occurred.
    /// @param refundRecipient Address intended to receive a future refund.
    /// @param currency Currency used for the bond.
    /// @param bond Amount of collateral taken, in raw token units.
    /// @param grossInput Total input amount used to size the bond.
    event BondTaken(
        PoolId indexed id, address indexed refundRecipient, Currency indexed currency, uint256 bond, uint256 grossInput
    );

    /// @notice Thrown when a caller other than `owner` tries to configure a pool.
    error NotOwner();

    /// @notice Thrown when the contract is deployed with `address(0)` as owner.
    /// @dev The owner is immutable. If `address(0)` were accepted, nobody could ever
    ///      call `setPoolConfig`, leaving every pool permanently unconfigured.
    ///      Reject the zero address during deployment because this cannot be fixed later.
    error ZeroOwner();

    /// @notice Thrown when the configured bond rate exceeds `MAX_BOND_BPS`.
    error BondBpsAboveCap(uint16 bondBps, uint16 cap);

    /// @notice Thrown when only part of a pool configuration is provided.
    /// @dev `(0, 0, 0)` disables bonding. Otherwise both thresholds and `bondBps`
    ///      must all be non-zero.
    ///
    ///      A zero threshold does not mean "disable this direction". Because the
    ///      check is `grossInput >= threshold`, a zero threshold would bond every
    ///      positive swap in that direction.
    error IncompletePoolConfig(uint128 minBondedAmount0, uint96 minBondedAmount1, uint16 bondBps);

    /// @notice Thrown when an exact-input bond violates the INV-NOOP rule.
    /// @dev Every bonded exact-input swap must satisfy:
    ///
    ///          0 < bond < grossInput
    ///
    ///      A bond equal to the full input would leave nothing for the pool to swap.
    ///      Uniswap core does not fully protect the hook from creating this case,
    ///      so BondMeBro checks it directly.
    error BondViolatesNoOpBound(uint256 bond, uint256 grossInput);

    /// @notice Thrown when a swap should be bonded but the calculated bond rounds to zero.
    /// @dev A bonded swap must never continue with zero collateral.
    error BondRoundsToZero(uint256 poolInput);

    /// @notice Thrown when the calculated bond is larger than the trader allowed.
    /// @dev `maxBondAmount` protects the trader if pool configuration changes between
    ///      quote time and execution time.
    error BondExceedsTraderMax(uint256 bond, uint128 maxBondAmount);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param _poolManager Uniswap v4 PoolManager.
    /// @param _owner Address allowed to configure BondMeBro pools.
    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) {
        if (_owner == address(0)) revert ZeroOwner();

        owner = _owner;
    }

    /// @inheritdoc BaseHook
    /// @dev These permissions must match `HOOK_FLAGS`.
    ///      `test_hookFlagsConstantMatchesPermissions` verifies this.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                              CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the bonding configuration for a pool.
    ///
    /// @dev Use `(0, 0, 0)` to disable bonding.
    ///
    ///      Otherwise all three values must be non-zero:
    ///      - threshold for currency0 input
    ///      - threshold for currency1 input
    ///      - bond rate
    ///
    ///      Separate thresholds are needed because the two currencies may have
    ///      different decimals and values.
    ///
    ///      Example for a USDC/WETH pool:
    ///
    ///          minBondedAmount0 = 100e6      // 100 USDC
    ///          minBondedAmount1 = 0.03e18    // 0.03 WETH
    ///          bondBps          = 25         // 0.25%
    ///
    ///      Lowering a threshold can make a previously unbonded quote require a
    ///      bond at execution time. If that transaction has no valid hookData,
    ///      it will revert.
    ///
    /// @param key Pool to configure.
    /// @param minBondedAmount0 Minimum gross input requiring a bond when currency0
    ///        is the input, in raw currency0 units.
    /// @param minBondedAmount1 Minimum gross input requiring a bond when currency1
    ///        is the input, in raw currency1 units.
    /// @param bondBps Bond rate in basis points of gross input.
    function setPoolConfig(PoolKey calldata key, uint128 minBondedAmount0, uint96 minBondedAmount1, uint16 bondBps)
        external
        onlyOwner
    {
        if (bondBps > MAX_BOND_BPS) {
            revert BondBpsAboveCap(bondBps, MAX_BOND_BPS);
        }

        // All zero disables bonding. Otherwise all three values must be set.
        bool anySet = minBondedAmount0 != 0 || minBondedAmount1 != 0 || bondBps != 0;

        bool allSet = minBondedAmount0 != 0 && minBondedAmount1 != 0 && bondBps != 0;

        if (anySet && !allSet) {
            revert IncompletePoolConfig(minBondedAmount0, minBondedAmount1, bondBps);
        }

        PoolId id = key.toId();

        poolConfig[id] =
            PoolConfig({minBondedAmount0: minBondedAmount0, minBondedAmount1: minBondedAmount1, bondBps: bondBps});

        emit PoolConfigured(id, minBondedAmount0, minBondedAmount1, bondBps);
    }

    /*//////////////////////////////////////////////////////////////
                                CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Records pool initialization for testing and diagnostics.
    function _afterInitialize(address, PoolKey calldata, uint160, int24 tick) internal override returns (bytes4) {
        afterInitializeCount++;

        emit CallbackFired("afterInitialize", tick);

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Handles pre-swap validation and exact-input bond custody.
    ///
    /// @dev EXACT-INPUT
    ///
    ///      The input amount is known before the swap, so BondMeBro can calculate
    ///      and take the bond here.
    ///
    ///      For a bonded exact-input swap:
    ///
    ///          grossInput = trader's specified input
    ///          bond       = grossInput * bondBps / 10_000
    ///          poolInput  = grossInput - bond
    ///
    ///      The bond is carved out of the trader's specified input rather than
    ///      charged on top.
    ///
    ///      EXACT-OUTPUT
    ///
    ///      The actual input is not known yet, so no bond is taken here.
    ///      Valid hookData is still checked before the pool executes.
    ///      Exact-output custody happens later in `_afterSwap`.
    ///
    ///      BONDED EXACT-INPUT ORDER:
    ///      1. validate hookData
    ///      2. calculate bond
    ///      3. enforce INV-NOOP
    ///      4. enforce `maxBondAmount`
    ///      5. take collateral
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();

        // Only the current tick is needed.
        // slither-disable-next-line unused-return
        (, int24 tick,,) = poolManager.getSlot0(id);

        lastTickBefore = tick;

        emit CallbackFired("beforeSwap", tick);

        PoolConfig memory cfg = poolConfig[id];

        // Bonding disabled for this pool.
        if (cfg.bondBps == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Exact-output:
        // actual input is unknown until after the pool executes.
        //
        // Validate hookData now so bad data fails before the swap.
        // Custody happens in `_afterSwap`.
        if (params.amountSpecified > 0) {
            // slither-disable-next-line unused-return
            HookDataCodec.decode(hookData);

            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Exact-input amounts are negative in v4.
        // Convert the magnitude to an unsigned gross input amount.
        uint256 grossInput = uint256(-params.amountSpecified);

        // Use the threshold belonging to the actual input currency.
        uint256 minBondedAmount = params.zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1;

        // Small swaps do not require a bond or hookData.
        if (grossInput < minBondedAmount) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // From here onward the swap is bonded.
        // Invalid hookData must revert rather than silently falling back to unbonded.
        (address refundRecipient, uint128 maxBondAmount) = HookDataCodec.decode(hookData);

        // Bond is calculated from gross input.
        uint256 bond = (grossInput * cfg.bondBps) / BPS;

        // INV-NOOP:
        // the bond must be positive and strictly smaller than gross input.
        if (bond == 0 || bond >= grossInput) {
            revert BondViolatesNoOpBound(bond, grossInput);
        }

        // Trader-provided limit on collateral.
        if (bond > maxBondAmount) {
            revert BondExceedsTraderMax(bond, maxBondAmount);
        }

        // Exact-input uses the specified/input currency.
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        emit BondTaken(id, refundRecipient, inputCurrency, bond, grossInput);

        // Move the bond into BondMeBro custody.
        inputCurrency.take(poolManager, address(this), bond, false);

        // Return the same bond amount to v4's custom-accounting system.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(bond.toInt128(), 0), 0);
    }

    /// @notice Records the post-swap tick and handles exact-output bond custody.
    ///
    /// @dev EXACT-INPUT
    ///
    ///      Custody already happened in `_beforeSwap`, so this callback only records
    ///      the post-swap tick and returns zero.
    ///
    ///      EXACT-OUTPUT
    ///
    ///      The actual pool input is now known, so BondMeBro calculates and takes
    ///      the bond here.
    ///
    ///      Exact-output keeps the requested output fixed, therefore:
    ///
    ///          total trader input = poolInput + bond
    ///
    ///      The bond is added on top of the amount consumed by the pool.
    ///
    ///      `maxBondAmount` limits the BondMeBro collateral itself.
    ///
    ///      When using the supported router path, `amountInMaximum` separately limits
    ///      the trader's total input, including the bond.
    ///
    ///      If this callback reverts, the entire swap also reverts.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();

        // Diagnostic only. T5 will replace this with proper per-pool
        // accumulator/checkpoint state for settlement.
        // slither-disable-next-line unused-return
        (, int24 tick,,) = poolManager.getSlot0(id);

        lastTickAfter = tick;

        emit CallbackFired("afterSwap", tick);

        // Exact-input custody was already handled in `_beforeSwap`.
        if (params.amountSpecified < 0) {
            return (BaseHook.afterSwap.selector, int128(0));
        }

        PoolConfig memory cfg = poolConfig[id];

        // Bonding disabled for this pool.
        if (cfg.bondBps == 0) {
            return (BaseHook.afterSwap.selector, int128(0));
        }

        // Exact-output hookData was already validated in `_beforeSwap`.
        // Decode it again here instead of storing temporary cross-callback state.
        (address refundRecipient, uint128 maxBondAmount) = HookDataCodec.decode(hookData);

        // The input currency depends on swap direction.
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Read the amount actually consumed by the pool.
        //
        // This delta does not yet include the BondMeBro bond.
        int256 inputDelta = int256(params.zeroForOne ? delta.amount0() : delta.amount1());

        // No positive input was consumed, so there is nothing to bond.
        if (inputDelta >= 0) {
            return (BaseHook.afterSwap.selector, int128(0));
        }

        uint256 poolInput = uint256(-inputDelta);

        // Exact-output bondBps still represents a percentage of GROSS input.
        //
        // grossInput = poolInput + bond
        //
        // Solving for bond:
        //
        // bond = poolInput * bondBps / (10_000 - bondBps)
        uint256 candidateBond = FullMath.mulDiv(poolInput, cfg.bondBps, BPS - uint256(cfg.bondBps));

        // Use the threshold for this swap's input currency.
        uint256 minBondedAmount = params.zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1;

        uint256 candidateGross = poolInput + candidateBond;

        // Below threshold: no collateral required.
        if (candidateGross < minBondedAmount) {
            return (BaseHook.afterSwap.selector, int128(0));
        }

        // A bonded swap must never continue with zero collateral.
        if (candidateBond == 0) {
            revert BondRoundsToZero(poolInput);
        }

        // Trader-provided limit on the bond itself.
        if (candidateBond > maxBondAmount) {
            revert BondExceedsTraderMax(candidateBond, maxBondAmount);
        }

        emit BondTaken(id, refundRecipient, inputCurrency, candidateBond, candidateGross);

        // Move the input-currency bond into BondMeBro custody.
        inputCurrency.take(poolManager, address(this), candidateBond, false);

        // Return exactly the amount physically taken.
        //
        // On exact-output this delta applies to the input currency, so the trader's
        // final input becomes:
        //
        //     poolInput + candidateBond
        return (BaseHook.afterSwap.selector, candidateBond.toInt128());
    }
}
