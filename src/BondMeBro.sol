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
import {ModelL2SettlementLib} from "./libraries/ModelL2SettlementLib.sol";
import {TickAccumulatorLib} from "./libraries/TickAccumulatorLib.sol";

/// @dev Permissions encoded in the deployed hook address's low 14 bits.
/// The hook, deployment miner and tests must agree on this callback set.
/// The mask is 0x10C4. BEFORE_SWAP_RETURNS_DELTA is absent, so beforeSwap cannot
/// adjust the user's specified swap amount.
///
/// We check address bits, not a visible text suffix. A change to creation bytecode,
/// including compiler metadata, can require a new mined salt and hook address.
uint160 constant HOOK_FLAGS = uint160(
    Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
);

/// @title BondMeBro
/// @notice Holds refundable swap collateral and settles it after ten blocks.
/// @dev Supported swaps are single-hop trades between standard ERC-20 tokens,
/// in both directions, with exact input or exact output. Native currency,
/// multi-hop, fee-on-transfer and rebasing tokens are not supported.
///
/// Uniswap fixes one side of a swap and lets the other side vary. For exact-input,
/// the output varies, so collateral is withheld from output. For exact-output,
/// the input varies, so collateral is added to input. We take collateral in
/// afterSwap, when actual execution is known. We do not carve it out of the
/// specified side. Pool price limits can still cause a partial fill.
///
/// For example, at a 10 bps rate, a fully filled exact-input swap that spends
/// 1,000 USDC and produces 1 WETH holds 0.001 WETH as collateral. The trader
/// still spends 1,000 USDC and receives 0.999 WETH. For exact-output, if the pool
/// needs 1,000 USDC to deliver 1 WETH, collateral is 1 USDC of additional input:
/// the trader pays 1,001 USDC and receives the specified 1 WETH.
///
/// The rate uses the larger of this swap's tick movement and the pool's movement
/// from the start of the block. A tick is Uniswap's price step. The rate grows
/// by 0.25 basis points per effective tick, rounded up to a whole basis point
/// and capped at 100 basis points, or 1%. This is refundable collateral, not
/// an extra swap fee.
///
/// Settlement uses cumulative-price checkpoints at opening block + 6, + 8 and + 10
/// to measure displacement near maturity. Anyone may settle a matured bond, but
/// the refund always goes to the recipient supplied in hookData. Retained
/// collateral enters an insurance reserve; there is no payout to individual
/// liquidity providers in this contract.
///
/// This measures the later pool price, not a trader's intent or private information.
/// It uses no external price oracle or identity classifier. Block-wide impact
/// reduces the benefit of same-block splitting; it does not eliminate it.
/// The fixed settings are demo calibration, not historically proven optima.
contract BondMeBro is BaseHook {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using TickAccumulatorLib for TickAccumulatorLib.Accumulator;

    /// @notice Basis-point denominator: 10,000 basis points equal 100%.
    /// @dev One basis point (bps) is 0.01%. Token amounts use amount * rate / BPS,
    /// rounded down in raw token units.
    uint256 public constant BPS = 10_000;

    /// @notice Maximum collateral rate: 100 basis points, or 1% of the variable leg.
    /// @dev The owner cannot change this cap. It keeps collateral well below the full
    /// variable-side amount; the strict bond bound is checked separately. The cap also
    /// means protection stops growing for sufficiently large price moves.
    uint16 public constant MAX_BOND_BPS = 100;

    /// @notice Maximum bonds accepted by settleMany, bounding the work in one call.
    uint256 public constant MAX_SETTLE_BATCH = 32;

    /// @notice Published technical observation limit, in blocks.
    /// @dev This is not the settlement wait. The ten-block OBSERVATION_BLOCKS value
    /// determines maturity and the scheduler's actual scan bound.
    uint32 public constant MAX_OBSERVATION_BLOCKS = 16;

    /// @notice Blocks between bond opening and maturity.
    /// @dev We wait ten blocks to observe later pool prices rather than settle against
    /// the immediate swap price. The chosen late windows end at blocks + 8 and + 10.
    /// This fixed horizon is demo calibration, not a measured optimum. Maturity makes
    /// settlement possible; someone must still call it.
    uint32 public constant OBSERVATION_BLOCKS = 10;

    /// @notice Bit marking the opening block + 6 cumulative as permanently stored.
    uint8 public constant FROZEN_C6 = 1;

    /// @notice Bit marking the opening block + 8 cumulative as permanently stored.
    uint8 public constant FROZEN_C8 = 2;

    /// @notice Bit marking the opening block + 10 cumulative as permanently stored.
    uint8 public constant FROZEN_C10 = 4;

    /// @notice All three checkpoint bits: 1 | 2 | 4 = 7.
    uint8 public constant FROZEN_ALL = 7;

    /// @notice Four blocks separate C6 from maturity: open + 6 = maturity - 4.
    uint32 public constant C6_OFFSET_FROM_MATURITY = 4;

    /// @notice Two blocks separate C8 from maturity: open + 8 = maturity - 2.
    uint32 public constant C8_OFFSET_FROM_MATURITY = 2;

    /// @notice Scale numerator: 25 / 100 = 0.25 basis points per effective tick.
    /// @dev For example, 40 effective ticks produce 10 bps, or 0.1%, of collateral.
    /// The rate rounds up to whole basis points before applying the 100 bps cap.
    uint16 public constant COLLATERAL_SCALE = 25;

    /// @notice Divisor used to express a quarter basis point with integer arithmetic.
    /// @dev Adding denominator - 1 before division rounds up, so movement of one to
    /// three ticks has a positive rate instead of rounding down to zero.
    uint256 public constant COLLATERAL_SCALE_DENOMINATOR = 100;

    /// @notice Smallest effective impact, in ticks, reaching the 100 bps cap.
    /// @dev ceil(397 * 25 / 100) = 100; ceil(396 * 25 / 100) = 99.
    uint32 public constant CAP_ACTIVATION_TICKS = 397;

    /// @notice Participation settings for one pool, packed into one storage slot.
    /// @dev Either token can be the input, so each currency needs its own raw-unit
    /// threshold. For example, 1e6 raw units means 1 USDC with six decimals, but only
    /// 1e-12 WETH with eighteen decimals. One number cannot express a sensible
    /// minimum in both directions.
    ///
    /// The currency1 threshold uses uint96, whose maximum is about 7.9e28 raw units,
    /// or 79 billion tokens with eighteen decimals. Both thresholds and the enable
    /// flag fit in one slot, avoiding another storage-slot read during swaps.
    ///
    /// Thresholds ration participation; they do not classify traders. Final eligibility
    /// uses input actually consumed by the pool. The owner can change participation,
    /// but cannot change the collateral curve or settlement parameters.
    struct PoolConfig {
        /// @dev Minimum consumed input in raw currency0 units; used when zeroForOne is true.
        uint128 minBondedAmount0;
        /// @dev Minimum consumed input in raw currency1 units; used when zeroForOne is false.
        uint96 minBondedAmount1;
        /// @dev Whether this pool takes collateral. Disabling clears both stored thresholds.
        bool bondingEnabled;
    }

    /// @notice Pool identifier and currencies shared by all bonds in that pool.
    /// @dev Each bond stores a four-byte index into this reference instead of copying
    /// the full PoolId and token addresses. The reference is written once during
    /// initialization, keeping each per-swap bond record at two storage slots.
    struct PoolRef {
        PoolId id;
        Currency currency0;
        Currency currency1;
    }

    /// @notice Facts needed to settle one bond, packed into two storage slots.
    /// @dev The first slot holds the recipient, block numbers and pool index. The
    /// second holds the executed amount, ticks, collateral rate, currency flag and state.
    /// The rate fits beside the other fields without adding a third slot.
    ///
    /// The variable leg is the output for exact-input or the pool input for exact-output.
    /// It is not the bond amount. Keeping it lets us calculate collateral and slash
    /// directly in token units without rounding one from the other. Original collateral
    /// equals variableLegAmount * collateralBps / BPS.
    ///
    /// Settlement uses this record and the pool checkpoints. A caller cannot choose
    /// a new refund recipient, currency, amount or maturity when settling.
    struct Bond {
        /// @dev Refund destination from validated hookData, never sender or tx.origin.
        address refundRecipient;
        /// @dev Block in which the swap opened this record.
        uint32 openBlock;
        /// @dev Fixed maturity: openBlock + OBSERVATION_BLOCKS, in blocks.
        uint32 maturityBlock;
        /// @dev Index into poolRefByIndex, identifying the pool and both currencies.
        uint32 poolIndex;
        /// @dev Actual output for exact-input or actual pool input for exact-output,
        /// in raw collateral-token units, before collateral adjusts the trader's balance.
        /// This is not the amount held by the hook.
        uint128 variableLegAmount;
        /// @dev Pool tick before the swap; the baseline for later displacement.
        int24 tickBefore;
        /// @dev Pool tick after the swap; also determines settlement's direction.
        int24 tickAfter;
        /// @dev Rate used when collateral was taken, in basis points.
        /// We store it because blockStartTick changes in later blocks. Recalculating from
        /// later pool state could produce a different amount from the tokens actually taken.
        /// Keeping the rate makes custody and settlement use the same value.
        uint16 collateralBps;
        /// @dev True if collateral is in currency0. Exact-input uses output; exact-output
        /// uses input. Direction alone is therefore not enough to choose the token.
        bool collateralIsCurrency0;
        /// @dev Whether this record is absent, being prepared, finalized or settled.
        BondState state;
    }

    /// @notice Bond lifecycle: NONE, PROVISIONAL, FINALIZED, then SETTLED.
    /// @dev Provisional records exist during a swap, are hidden by public bond readers
    /// and do not count toward checkpoint obligations. FINALIZED means custody succeeded.
    /// SETTLED records remain readable but cannot be settled again.
    enum BondState {
        NONE,
        PROVISIONAL,
        FINALIZED,
        SETTLED
    }

    /// @notice Three cumulative-price readings shared by a pool's bonds with the same maturity.
    /// @dev C6, C8 and C10 are the tick cumulatives at opening block + 6, + 8 and + 10.
    /// C6 to C8 covers blocks 6 and 7; C8 to C10 covers blocks 8 and 9. These late
    /// windows do not directly score the opening block. Displacement created at opening
    /// still matters if it remains during either window.
    ///
    /// Bonds with the same maturity also have the same opening block and can share
    /// these readings. Three int56 cumulatives, a uint32 count and a uint8 mask fit
    /// in one slot. Each endpoint is frozen separately when due; its mask bit prevents
    /// later swaps or settlement calls from changing it.
    struct MaturityCheckpoint {
        /// @dev C6: sum of tick * elapsed blocks at maturity - 4, in tick-blocks.
        int56 cumulativeMinus4;
        /// @dev C8: cumulative at maturity - 2, in tick-blocks.
        int56 cumulativeMinus2;
        /// @dev C10: cumulative at maturity, in tick-blocks.
        int56 cumulativeAtM;
        /// @dev Number of finalized, unsettled bonds depending on this bucket.
        uint32 pendingBonds;
        /// @dev Stored-endpoint flags. Once set, a bit is never cleared.
        uint8 frozenMask;
    }

    /// @notice Address allowed to enable bonding and set participation thresholds.
    /// @dev Fixed at deployment; there is no ownership transfer or key rotation.
    address public immutable owner;

    /// @notice Participation settings by PoolId. Unconfigured pools do not take collateral.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Pool tick history summarized as a running sum and the latest tick.
    /// @dev Updated on every swap, including unbonded swaps, so observations do not
    /// miss price changes. It also holds the block-start tick used for collateral sizing.
    mapping(PoolId => TickAccumulatorLib.Accumulator) public accumulator;

    /// @notice Checkpoint buckets keyed by pool and maturity block.
    /// @dev Readings use tick-blocks. Each bucket may have some endpoints frozen
    /// before maturity; each endpoint has its own frozenMask bit.
    mapping(PoolId => mapping(uint32 => MaturityCheckpoint)) public maturity;

    /// @dev Internal records let public readers hide provisional entries.
    /// Use getBond, bondExists and collateralAmountOf for finalized or settled records.
    /// This is an API rule, not secrecy: raw storage can still be inspected.
    mapping(bytes32 => Bond) internal bonds;

    /// @notice Full pool reference for the compact index stored in each bond.
    mapping(uint32 => PoolRef) public poolRefByIndex;

    /// @notice Pool index assigned at initialization; zero means not registered.
    mapping(PoolId => uint32) public poolIndexOf;

    /// @notice Number of registered pools and latest assigned index.
    uint32 public poolCount;

    /// @notice Retained collateral reserve, per pool and currency, in raw token units.
    /// @dev A slash changes accounting, not token location: the hook already holds
    /// these tokens. Settlement reduces the unsettled bond obligation and credits
    /// this reserve. There is no withdrawal or automatic distribution to individual
    /// liquidity providers (LPs) in this contract.
    mapping(PoolId => mapping(Currency => uint256)) public insurancePot;

    /// @notice Records the participation settings supplied by the owner.
    /// @dev Disabling clears stored thresholds even if the supplied event amounts are non-zero.
    /// @param id Pool being configured.
    /// @param minBondedAmount0 Supplied minimum in raw currency0 input units.
    /// @param minBondedAmount1 Supplied minimum in raw currency1 input units.
    /// @param bondingEnabled Whether bonding is enabled after this call.
    event PoolConfigured(PoolId indexed id, uint128 minBondedAmount0, uint96 minBondedAmount1, bool bondingEnabled);

    /// @notice Records collateral taken from a completed swap.
    /// @param id Pool where the swap executed.
    /// @param refundRecipient Validated address entitled to a future refund.
    /// @param currency Collateral token.
    /// @param bond Collateral amount in raw units of currency.
    /// @param variableLegAmount Actual output for exact-input or pool input for
    /// exact-output, in raw units of currency; not the bond amount.
    event BondTaken(
        PoolId indexed id,
        address indexed refundRecipient,
        Currency indexed currency,
        uint256 bond,
        uint256 variableLegAmount
    );

    /// @notice Records a finalized bond and its fixed maturity.
    /// @param bondId Identifier used to read and settle the bond.
    /// @param id Pool the bond belongs to.
    /// @param refundRecipient Address entitled to the refund.
    /// @param variableLegAmount Actual variable-side amount in raw collateral-token units.
    /// @param maturityBlock Opening block plus the fixed observation period.
    event BondOpened(
        bytes32 indexed bondId,
        PoolId indexed id,
        address indexed refundRecipient,
        uint128 variableLegAmount,
        uint32 maturityBlock
    );

    /// @notice Records the permanent C10 reading for a maturity bucket.
    /// @dev C6 and C8 are stored without separate events.
    /// @param id Pool the bucket belongs to.
    /// @param maturityBlock Block represented by C10.
    /// @param cumulative Tick cumulative at that block, in tick-blocks.
    event MaturityCheckpointed(PoolId indexed id, uint32 indexed maturityBlock, int56 cumulative);

    /// @notice Only the owner may change pool participation settings.
    error NotOwner();

    /// @notice Deployment requires a non-zero owner because ownership cannot be replaced later.
    error ZeroOwner();

    /// @notice Enabling bonding requires a non-zero threshold for both input currencies.
    /// @dev Zero is not a direction-disable switch: every positive input would meet
    /// a zero threshold. Use bondingEnabled = false to disable the pool.
    error IncompleteBondingConfig(uint128 minBondedAmount0, uint96 minBondedAmount1);

    /// @notice Collateral must be positive and smaller than the realized variable leg.
    /// @dev Core does not enforce this bound for after-swap adjustments. We reject a
    /// full-leg charge and a positive rate that rounds down to zero tokens. A zero-token
    /// bond would create a settlement obligation without real collateral.
    /// @param bond Proposed collateral in raw collateral-token units.
    /// @param variableLegAmount Actual variable-side amount in the same units.
    error BondViolatesNoOpVLBound(uint256 bond, uint256 variableLegAmount);

    /// @notice Calculated collateral exceeds the ceiling provided in hookData.
    /// @dev Both amounts use raw collateral-token units. This is bond-specific slippage
    /// protection, not a replacement for the router's final swap limit.
    error BondExceedsTraderMax(uint256 bond, uint128 maxBondAmount);

    /// @notice Records the split of original collateral between refund and insurance reserve.
    /// @param bondId Settled bond identifier.
    /// @param id Pool the bond belongs to.
    /// @param refundRecipient Stored recipient, not necessarily the caller.
    /// @param currency Token used for refund and slash.
    /// @param collateral Original collateral in raw token units.
    /// @param refund Amount returned in raw token units.
    /// @param slash Amount credited to insurancePot in raw token units.
    /// @param slashBps Retained rate in basis points of the original variable leg.
    event BondSettled(
        bytes32 indexed bondId,
        PoolId indexed id,
        address indexed refundRecipient,
        Currency currency,
        uint128 collateral,
        uint128 refund,
        uint128 slash,
        uint16 slashBps
    );

    /// @notice Settlement was requested before the fixed maturity block.
    error BondNotMature(bytes32 bondId, uint32 maturityBlock, uint256 currentBlock);

    /// @notice Only a FINALIZED bond can settle; absent, provisional or settled records revert.
    error BondNotSettleable(bytes32 bondId, BondState state);

    /// @notice A required checkpoint was not saved before the accumulator passed its block.
    /// @dev We cannot recover the exact value and revert instead of using a newer tick.
    /// @param bondId Identifier used in the error report.
    /// @param maturityBlock Missing endpoint block, which can be C6, C8 or C10.
    /// @param lastUpdate Block already reached by the accumulator.
    error MaturityCheckpointMissing(bytes32 bondId, uint32 maturityBlock, uint32 lastUpdate);

    /// @notice The batch exceeds the maximum number of settlements per call.
    error SettleBatchTooLarge(uint256 length, uint256 cap);

    /// @notice No finalized or settled bond exists at this identifier.
    /// @dev Public readers deliberately treat provisional entries as absent.
    error BondNotFound(bytes32 bondId);

    /// @notice A bond requires a pool registered through this hook's initialization callback.
    error PoolNotRegistered();

    /// @notice A current or calculated maturity block cannot fit in the stored uint32 block number.
    error BlockNumberOutOfRange(uint256 blockNumber);

    /// @dev Limits pool configuration to the immutable deployment owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Sets the PoolManager and the owner allowed to configure pool participation.
    /// @dev BaseHook checks that this address encodes the requested permissions.
    /// @param _poolManager Uniswap v4 PoolManager allowed to call the hook.
    /// @param _owner Non-zero configuration owner; cannot change after deployment.
    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) {
        if (_owner == address(0)) revert ZeroOwner();

        owner = _owner;
    }

    /// @notice Returns the callbacks and balance adjustments this hook requires.
    /// @dev These flags must match HOOK_FLAGS and the deployed address's low 14 bits.
    /// beforeSwapReturnDelta is false; afterSwapReturnDelta is true.
    /// @return The permission set used by BaseHook's address validation.
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
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Enables or disables bonding and sets a minimum input for each swap direction.
    /// @dev Enabling requires both thresholds to be positive. Disabling stores zero
    /// thresholds regardless of the supplied amounts. Neither operation changes the
    /// fixed collateral curve, cap, ten-block horizon or settlement dead zone.
    ///
    /// Lowering a threshold can make a previously unbonded quote require hookData.
    /// A transaction carrying empty data then reverts; it cannot silently take a bond
    /// without a recipient and ceiling. Extremely small thresholds are unsupported:
    /// a positive rate can round to zero tokens, which the strict bond bound rejects.
    /// The thresholds ration participation, not trader intent.
    ///
    /// @param key Pool to configure.
    /// @param minBondedAmount0 Minimum actual input in raw currency0 units; ignored when disabling.
    /// @param minBondedAmount1 Minimum actual input in raw currency1 units; ignored when disabling.
    /// @param bondingEnabled Whether the pool takes collateral.
    function setPoolConfig(PoolKey calldata key, uint128 minBondedAmount0, uint96 minBondedAmount1, bool bondingEnabled)
        external
        onlyOwner
    {
        if (bondingEnabled && (minBondedAmount0 == 0 || minBondedAmount1 == 0)) {
            revert IncompleteBondingConfig(minBondedAmount0, minBondedAmount1);
        }

        PoolId id = key.toId();

        poolConfig[id] = PoolConfig({
            minBondedAmount0: bondingEnabled ? minBondedAmount0 : 0,
            minBondedAmount1: bondingEnabled ? minBondedAmount1 : 0,
            bondingEnabled: bondingEnabled
        });

        emit PoolConfigured(id, minBondedAmount0, minBondedAmount1, bondingEnabled);
    }

    /// @notice Registers a pool and starts its accumulator at the actual initialization tick.
    /// @dev The compact pool index keeps later bond records small. We seed blockStartTick
    /// before advancing lastUpdate, so swaps in the initialization block use the correct
    /// starting price. No price history is invented for blocks before initialization.
    /// @param key Pool being initialized.
    /// @param tick Actual pool tick at initialization.
    /// @return The afterInitialize callback selector.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = key.toId();

        if (poolIndexOf[id] == 0) {
            uint32 index = ++poolCount;

            poolIndexOf[id] = index;
            poolRefByIndex[index] = PoolRef({id: id, currency0: key.currency0, currency1: key.currency1});
        }

        accumulator[id].beginBlock(tick);

        // slither-disable-next-line unused-return
        accumulator[id].update(tick);

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Saves due checkpoints and prepares a possible bond without taking tokens.
    /// @dev BaseHook restricts this callback to PoolManager. The accumulator advances
    /// on every swap, even if bonding is disabled or the amount is below its threshold.
    /// Otherwise existing bonds could miss part of the pool's price history.
    ///
    /// A disabled pool needs no hookData. An exact-input request below its threshold
    /// also needs none, because it cannot consume more input than requested.
    /// Exact-output input is unknown until execution, so an enabled exact-output pool
    /// requires valid hookData even when the final trade turns out too small to bond.
    ///
    /// Other swaps get a provisional record after hookData validation. afterSwap
    /// either finalizes it using actual execution or clears it. Every return here
    /// has zero swap delta and zero fee override.
    /// @param key Pool being traded.
    /// @param params Requested amount and swap direction.
    /// @param hookData Versioned recipient and collateral ceiling.
    /// @return The callback selector, zero balance adjustment and zero fee override.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();

        {
            // slither-disable-next-line unused-return
            (, int24 tick,,) = poolManager.getSlot0(id);

            _advanceAndCheckpoint(id, tick);
        }

        PoolConfig memory cfg = poolConfig[id];

        if (!cfg.bondingEnabled) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (params.amountSpecified < 0) {
            uint256 requestedInput = uint256(-params.amountSpecified);

            if (requestedInput < (params.zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1)) {
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
        }

        // slither-disable-next-line unused-return
        (address refundRecipient,) = HookDataCodec.decode(hookData);

        // slither-disable-next-line unused-return
        _openProvisionalBond(id, params.zeroForOne, refundRecipient, accumulator[id].lastTick);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Records the executed tick and takes eligible collateral from the variable side.
    /// @dev The input is fixed for exact-input, so the output is the variable leg.
    /// For exact-output the output is fixed, so the input is the variable leg.
    /// Taking collateral here leaves the user's specified side unchanged.
    ///
    /// We read tickBefore before update replaces lastTick. update does not replace
    /// blockStartTick, so sizing can still compare this swap's movement with the
    /// block's total displacement.
    /// @param key Pool being traded.
    /// @param params Requested swap kind and direction.
    /// @param delta Actual pool balances before this hook's adjustment: negative input,
    /// positive output, in raw units of the corresponding currencies.
    /// @param hookData Versioned recipient and collateral ceiling.
    /// @return The callback selector and a positive collateral adjustment, or zero if unbonded.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();

        int24 tickBefore = accumulator[id].lastTick;

        int24 tickAfter;
        {
            // slither-disable-next-line unused-return
            (, int24 tick,,) = poolManager.getSlot0(id);

            tickAfter = tick;

            // slither-disable-next-line unused-return
            accumulator[id].update(tick);
        }

        return (
            BaseHook.afterSwap.selector,
            _takeVariableLegBond(
                id, hookData, _custodyContext(key, params, delta, tickBefore, tickAfter, accumulator[id].blockStartTick)
            )
        );
    }

    /// @dev Execution facts passed together to the custody helper to keep stack usage bounded.
    /// Input and output deltas use raw units of their respective tokens. A negative
    /// input delta means the caller owes tokens; a positive output delta means tokens
    /// are owed to the caller. collateralBps is a rate, not a token amount.
    struct VLCustody {
        Currency collateralCurrency;
        uint256 collateralBps;
        int256 inputDelta;
        int256 outputDelta;
        int24 tickAfter;
        bool zeroForOne;
        bool exactInput;
    }

    /// @dev Selects actual input, output and collateral currency from the completed swap.
    /// zeroForOne means currency0 is input. The swap kind then chooses the variable
    /// leg: output for exact-input, input for exact-output. Delta values are widened
    /// before later negation so signed input amounts can be handled safely.
    function _custodyContext(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        int24 tickBefore,
        int24 tickAfter,
        int24 blockStartTick
    ) private pure returns (VLCustody memory c) {
        bool exactInput = params.amountSpecified < 0;
        bool collateralIsCurrency0 = _collateralIsCurrency0(params.zeroForOne, exactInput);

        c = VLCustody({
            collateralCurrency: collateralIsCurrency0 ? key.currency0 : key.currency1,
            collateralBps: _effectiveCollateralBps(tickBefore, tickAfter, blockStartTick),
            inputDelta: int256(params.zeroForOne ? delta.amount0() : delta.amount1()),
            outputDelta: int256(params.zeroForOne ? delta.amount1() : delta.amount0()),
            tickAfter: tickAfter,
            zeroForOne: params.zeroForOne,
            exactInput: exactInput
        });
    }

    /// @dev True when the swap's variable-side token is currency0.
    /// For zeroForOne, input is currency0 and output is currency1; the reverse
    /// direction swaps those roles. exactInput selects output rather than input.
    function _collateralIsCurrency0(bool zeroForOne, bool exactInput) private pure returns (bool) {
        return exactInput ? !zeroForOne : zeroForOne;
    }

    /// @dev Applies the capped, upward-rounded rate curve to movement between two ticks.
    /// Widen before subtracting and taking the absolute value. This helper measures
    /// only those two ticks; production sizing also considers the block-start tick.
    function _collateralBpsFor(int24 tickBefore, int24 tickAfter) private pure returns (uint256 collateralBps) {
        int256 signedImpact = int256(tickAfter) - int256(tickBefore);
        uint256 impactTicks = uint256(signedImpact < 0 ? -signedImpact : signedImpact);

        collateralBps = (impactTicks * uint256(COLLATERAL_SCALE) + (COLLATERAL_SCALE_DENOMINATOR - 1))
            / COLLATERAL_SCALE_DENOMINATOR;

        if (collateralBps > MAX_BOND_BPS) collateralBps = MAX_BOND_BPS;
    }

    /// @notice Calculates the collateral rate from a swap's own tick movement only.
    /// @dev This is not a full quote for a later swap in the block. Actual custody uses
    /// the larger of own movement and block-start displacement. They are equal for
    /// the first swap in a block.
    /// @param tickBefore Pool tick before the swap.
    /// @param tickAfter Pool tick after the swap.
    /// @return collateralBps Own-movement rate in basis points, capped at MAX_BOND_BPS.
    function collateralBpsFor(int24 tickBefore, int24 tickAfter) external pure returns (uint256 collateralBps) {
        return _collateralBpsFor(tickBefore, tickAfter);
    }

    /// @dev Uses the larger of this swap's movement and the pool's block-wide displacement.
    /// ownImpact is abs(tickAfter - tickBefore). blockDisplacement is
    /// abs(tickAfter - blockStartTick). effectiveImpact is the larger value.
    ///
    /// Pricing each piece of a split trade only by its own movement can reduce the
    /// total collateral even when the pool ends at a similar price. Including the
    /// block displacement reduces that benefit, but does not make splitting impossible.
    /// The result can never be below the own-impact rate.
    ///
    /// For the first swap in a block, blockStartTick equals tickBefore. Both movements
    /// are then equal, so the block term does not change the rate. We widen signed
    /// ticks before subtraction and round the rate up before applying the cap.
    function _effectiveCollateralBps(int24 tickBefore, int24 tickAfter, int24 blockStartTick)
        private
        pure
        returns (uint256 collateralBps)
    {
        int256 own = int256(tickAfter) - int256(tickBefore);
        int256 displacement = int256(tickAfter) - int256(blockStartTick);

        uint256 ownTicks = uint256(own < 0 ? -own : own);
        uint256 displacementTicks = uint256(displacement < 0 ? -displacement : displacement);

        uint256 effectiveTicks = ownTicks > displacementTicks ? ownTicks : displacementTicks;

        collateralBps = (effectiveTicks * uint256(COLLATERAL_SCALE) + (COLLATERAL_SCALE_DENOMINATOR - 1))
            / COLLATERAL_SCALE_DENOMINATOR;

        if (collateralBps > MAX_BOND_BPS) collateralBps = MAX_BOND_BPS;
    }

    /// @notice Calculates the block-aware collateral rate from supplied ticks.
    /// @dev This is a pure calculation, not a guarantee about future execution.
    /// Earlier transactions can change the block-start displacement before a swap executes.
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after it.
    /// @param blockStartTick Pool tick before the block's first swap.
    /// @return collateralBps Effective rate in basis points, capped at MAX_BOND_BPS.
    function effectiveCollateralBpsFor(int24 tickBefore, int24 tickAfter, int24 blockStartTick)
        external
        pure
        returns (uint256 collateralBps)
    {
        return _effectiveCollateralBps(tickBefore, tickAfter, blockStartTick);
    }

    /// @notice Returns the start tick that a swap would use in the current block.
    /// @dev If the pool has not been touched this block, its last observed tick will
    /// become the new block-start tick. This view returns that value without writing
    /// storage. Uninitialized pool state reads as zero.
    /// @param id Pool to read.
    /// @return Current block's stored or pending starting tick.
    function blockStartTickOf(PoolId id) external view returns (int24) {
        TickAccumulatorLib.Accumulator memory acc = accumulator[id];

        if (acc.lastUpdate != 0 && acc.lastUpdate < _blockNumber32()) return acc.lastTick;

        return acc.blockStartTick;
    }

    /// @dev Reconstructs original collateral from the saved leg and opening rate.
    /// Both values are fixed in the bond, so this matches the token amount taken even
    /// after later blocks have replaced the pool's block-start tick.
    function _collateralOf(Bond memory bond) private pure returns (uint128) {
        return uint128((uint256(bond.variableLegAmount) * uint256(bond.collateralBps)) / BPS);
    }

    /// @dev Finalizes eligible collateral using executed balances, then takes the tokens.
    /// The threshold uses input actually consumed, not the requested amount. If no
    /// input was consumed, the amount is too small, or the effective rate is zero,
    /// we clear any provisional record and return zero.
    ///
    /// A bonded operation must satisfy 0 < bond < variableLeg. Core does not enforce
    /// that bound for this after-swap adjustment. A positive rate can still round down
    /// to zero tokens on an extremely small leg; we revert rather than create an
    /// empty bond. Normal thresholds filter tiny swaps, but unrealistically low
    /// thresholds are unsupported and can reach this check.
    ///
    /// The calculated bond must also be at most maxBondAmount from hookData. That
    /// ceiling uses the collateral token's raw units. It does not replace final-output
    /// or maximum-input protection in the router.
    ///
    /// take() transfers the bond from PoolManager to this hook and opens a -bond
    /// currency debt for the hook. Returning +bond gives the hook an equal credit
    /// when PoolManager accounts the callback result, cancelling that debt.
    /// Core subtracts the same +bond from the caller's balance: less output for
    /// exact-input, or extra input owed for exact-output. The router then pays or
    /// withdraws its final balance. No hook currency debt should remain after unlock.
    /// @param id Pool being traded.
    /// @param hookData Validated again before custody.
    /// @param c Executed balances, tick, direction and effective collateral rate.
    /// @return bondDelta Positive variable-side adjustment equal to tokens taken, or zero.
    function _takeVariableLegBond(PoolId id, bytes calldata hookData, VLCustody memory c)
        private
        returns (int128 bondDelta)
    {
        PoolConfig storage cfg = poolConfig[id];

        if (!cfg.bondingEnabled) {
            return int128(0);
        }

        bytes32 bondId;
        {
            uint32 maturityBlock = _maturityOf(_blockNumber32());

            bondId = _bondId(id, maturityBlock, maturity[id][maturityBlock].pendingBonds);
        }

        uint256 variableLeg;
        {
            int256 inputDelta = c.inputDelta;

            if (inputDelta >= 0) {
                _clearProvisionalBond(bondId);

                return int128(0);
            }

            uint256 actualInput = uint256(-inputDelta);

            if (actualInput < (c.zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1)) {
                _clearProvisionalBond(bondId);

                return int128(0);
            }

            variableLeg = c.exactInput ? (c.outputDelta > 0 ? uint256(c.outputDelta) : 0) : actualInput;
        }

        // slither-disable-next-line incorrect-equality
        if (c.collateralBps == 0) {
            _clearProvisionalBond(bondId);

            return int128(0);
        }

        uint256 bond = (variableLeg * c.collateralBps) / BPS;

        // slither-disable-next-line incorrect-equality
        if (bond == 0 || bond >= variableLeg) {
            revert BondViolatesNoOpVLBound(bond, variableLeg);
        }

        {
            (address refundRecipient, uint128 maxBondAmount) = HookDataCodec.decode(hookData);

            if (bond > maxBondAmount) {
                revert BondExceedsTraderMax(bond, maxBondAmount);
            }

            emit BondTaken(id, refundRecipient, c.collateralCurrency, bond, variableLeg);
        }

        bonds[bondId].collateralIsCurrency0 = _collateralIsCurrency0(c.zeroForOne, c.exactInput);

        _finalizeBond(id, bondId, uint128(variableLeg), c.tickAfter, uint16(c.collateralBps));

        c.collateralCurrency.take(poolManager, address(this), bond, false);

        return bond.toInt128();
    }

    /// @dev Saves due observations before a swap can replace the tick needed to calculate them.
    /// We first capture blockStartTick, then freeze checkpoints, then advance the
    /// accumulator. Moving lastUpdate first would hide the new-block boundary.
    /// Moving the price first would apply the new price to an earlier quiet interval.
    ///
    /// The loop scans maturity buckets, not individual bonds. With L = lastUpdate,
    /// a bond already registered can mature no later than L + OBSERVATION_BLOCKS,
    /// because opening it required a swap. A bucket first has a due endpoint at
    /// maturity - 4, so the other bound is current block + 4. Taking the smaller
    /// bound limits the scan to ten candidate buckets, even after a long quiet gap.
    ///
    /// Each bucket is read once and may freeze up to three endpoints. Empty buckets
    /// and already frozen endpoints are skipped. This runs on unbonded swaps too,
    /// so enabling bonding mid-block cannot leave a stale starting tick.
    /// @param id Pool whose history is being advanced.
    /// @param currentTick Current pool tick, used to seed an uninitialized accumulator.
    function _advanceAndCheckpoint(PoolId id, int24 currentTick) private {
        TickAccumulatorLib.Accumulator storage acc = accumulator[id];

        acc.beginBlock(currentTick);

        uint32 lastUpdate = acc.lastUpdate;

        if (lastUpdate == 0) {
            // slither-disable-next-line unused-return
            acc.update(currentTick);

            return;
        }

        uint32 nowBlock = _blockNumber32();

        if (nowBlock > lastUpdate) {
            uint32 occupancyEnd = lastUpdate + OBSERVATION_BLOCKS;
            uint32 dueEnd = nowBlock + C6_OFFSET_FROM_MATURITY;

            uint32 bucketEnd = dueEnd < occupancyEnd ? dueEnd : occupancyEnd;

            TickAccumulatorLib.Accumulator memory snapshot = acc;

            for (uint32 m = lastUpdate + 1; m <= bucketEnd; m++) {
                _freezeDueEndpoints(id, m, snapshot, lastUpdate, nowBlock);
            }
        }

        // slither-disable-next-line unused-return
        acc.update(acc.lastTick);
    }

    /// @dev Returns the current block only if it fits the stored block-number type.
    /// Rejecting overflow avoids wrapping a future maturity into the past.
    function _blockNumber32() private view returns (uint32) {
        if (block.number > type(uint32).max) revert BlockNumberOutOfRange(block.number);

        return uint32(block.number);
    }

    /// @dev Adds the fixed observation period and checks that maturity fits in uint32.
    /// The addition is widened first, so overflow is reported rather than truncated.
    function _maturityOf(uint32 openBlock) private pure returns (uint32) {
        uint256 m = uint256(openBlock) + uint256(OBSERVATION_BLOCKS);

        if (m > type(uint32).max) revert BlockNumberOutOfRange(m);

        return uint32(m);
    }

    /// @dev Derives an identifier from the pool, maturity and position in that bucket.
    /// New bonds open ten blocks before their bucket can settle, so its count does
    /// not fall while bonds are still being added in the opening block.
    function _bondId(PoolId id, uint32 maturityBlock, uint32 indexInBucket) private pure returns (bytes32) {
        return keccak256(abi.encode(id, maturityBlock, indexInBucket));
    }

    /// @dev Stores the known opening facts before the pool executes the swap.
    /// The amount, final tick and rate are filled in after execution. Preparing the
    /// record here shares storage work between the two callbacks. It is not yet a
    /// settleable bond and does not increase pendingBonds.
    ///
    /// The initial currency flag is temporary and is replaced with the actual
    /// collateral currency before finalization. Public bond readers hide this record;
    /// a failed or ineligible swap must not leave a finalized zero-collateral bond.
    /// @param id Registered pool.
    /// @param provisionalCollateralIsCurrency0 Temporary currency flag, corrected before custody.
    /// @param refundRecipient Destination supplied in validated hookData.
    /// @param tickBefore Pool tick before execution.
    /// @return bondId Identifier reserved for this potential bond.
    function _openProvisionalBond(
        PoolId id,
        bool provisionalCollateralIsCurrency0,
        address refundRecipient,
        int24 tickBefore
    ) private returns (bytes32 bondId) {
        uint32 poolIndex = poolIndexOf[id];

        if (poolIndex == 0) revert PoolNotRegistered();

        uint32 openBlock = _blockNumber32();
        uint32 maturityBlock = _maturityOf(openBlock);

        bondId = _bondId(id, maturityBlock, maturity[id][maturityBlock].pendingBonds);

        bonds[bondId] = Bond({
            refundRecipient: refundRecipient,
            openBlock: openBlock,
            maturityBlock: maturityBlock,
            poolIndex: poolIndex,
            variableLegAmount: 0,
            tickBefore: tickBefore,
            tickAfter: 0,
            collateralBps: 0,
            collateralIsCurrency0: provisionalCollateralIsCurrency0,
            state: BondState.PROVISIONAL
        });
    }

    /// @dev Completes the prepared record and registers its checkpoint obligation.
    /// We store the actual variable leg, closing tick and collateral rate in the
    /// record's second slot. Settlement must reuse this rate because the block-start
    /// tick used to calculate it will change in later blocks.
    ///
    /// Only a finalized bond increases pendingBonds. Registration changes the count,
    /// not any cumulative reading or frozen bit.
    /// @param id Pool the bond belongs to.
    /// @param bondId Prepared record to complete.
    /// @param variableLegAmount Realized variable-side amount in raw collateral-token units.
    /// @param tickAfter Pool tick after execution.
    /// @param collateralBps Validated opening rate, capped at 100 basis points.
    function _finalizeBond(PoolId id, bytes32 bondId, uint128 variableLegAmount, int24 tickAfter, uint16 collateralBps)
        private
    {
        Bond storage bond = bonds[bondId];

        bond.variableLegAmount = variableLegAmount;
        bond.tickAfter = tickAfter;

        bond.collateralBps = collateralBps;
        bond.state = BondState.FINALIZED;

        uint32 maturityBlock = bond.maturityBlock;

        maturity[id][maturityBlock].pendingBonds += 1;

        emit BondOpened(bondId, id, bond.refundRecipient, variableLegAmount, maturityBlock);
    }

    /// @dev Clears a prepared record when execution does not qualify for collateral.
    /// Both slots return to zero and readers see NONE. The bucket count was never
    /// increased, so clearing does not leave a checkpoint obligation behind.
    function _clearProvisionalBond(bytes32 bondId) private {
        delete bonds[bondId];
    }

    /// @notice Settles a matured bond, returning the refundable portion to its stored recipient.
    /// @dev Anyone may call this function; the caller does not receive the refund
    /// unless they are also the stored recipient. Settlement before maturity reverts.
    /// At or after maturity, C6, C8 and C10 determine the result. Later swaps and the
    /// choice of settlement block cannot change those observations.
    ///
    /// Persistent same-direction displacement can leave part of the collateral in
    /// the insurance pot. A move that does not persist can return more or all of it.
    /// This measures a later price outcome, not the trader's intent or identity.
    /// @param bondId Finalized bond to settle.
    function settleBond(bytes32 bondId) external {
        _settleBond(bondId);
    }

    /// @notice Settles up to MAX_SETTLE_BATCH bonds in one transaction.
    /// @dev The batch is all-or-nothing. An unknown, provisional, immature or already
    /// settled entry reverts the entire call. Duplicate identifiers therefore also
    /// revert. An empty list does nothing. Refunds go to each bond's stored recipient.
    /// @param bondIds Bond identifiers to settle, in the supplied order.
    function settleMany(bytes32[] calldata bondIds) external {
        uint256 length = bondIds.length;

        if (length > MAX_SETTLE_BATCH) revert SettleBatchTooLarge(length, MAX_SETTLE_BATCH);

        for (uint256 i = 0; i < length; i++) {
            _settleBond(bondIds[i]);
        }
    }

    /// @dev Resolves the three fixed checkpoints and calculates amounts from the saved bond.
    /// The stored collateral rate is the rate used when tokens were taken. It must
    /// not be reconstructed from current pool state. Keeping these calculation locals
    /// in a separate helper also limits stack usage during settlement.
    /// @param bondId Identifier used in checkpoint error reports.
    /// @param id Pool the bond belongs to.
    /// @param bond Stored executed amount, rate and opening ticks.
    /// @param maturityBlock Fixed maturity of this bond.
    /// @return collateral Original collateral in raw token units.
    /// @return slash Amount retained in raw token units.
    /// @return refund Amount returned in raw token units.
    /// @return slashBps Retained rate in basis points of the original variable leg.
    function _computeL2Settlement(bytes32 bondId, PoolId id, Bond storage bond, uint32 maturityBlock)
        private
        returns (uint128 collateral, uint128 slash, uint128 refund, uint16 slashBps)
    {
        (int56 c6, int56 c8, int56 c10) = resolveEndpoints(bondId, id, maturityBlock);

        int24 tickBefore = bond.tickBefore;
        int24 tickAfter = bond.tickAfter;

        uint256 collateralBps = uint256(bond.collateralBps);

        return ModelL2SettlementLib.settle(bond.variableLegAmount, collateralBps, tickBefore, tickAfter, c6, c8, c10);
    }

    /// @dev Shared settlement path: validate, update accounting, then transfer the refund.
    /// The bond must be FINALIZED and mature. We mark it SETTLED, reduce its bucket's
    /// pending count and credit the insurance reserve before calling the token.
    /// A second attempt then sees SETTLED and cannot refund the same bond twice.
    ///
    /// A slash moves no tokens: the reserve keeps that portion of the existing balance.
    /// Only the refund leaves the hook, sent directly to the stored recipient. If the
    /// transfer fails, the state changes and event revert with it.
    function _settleBond(bytes32 bondId) private {
        Bond storage bond = bonds[bondId];

        BondState state = bond.state;
        if (state != BondState.FINALIZED) revert BondNotSettleable(bondId, state);

        uint32 maturityBlock = bond.maturityBlock;

        if (block.number < maturityBlock) {
            revert BondNotMature(bondId, maturityBlock, block.number);
        }

        PoolRef memory poolRef = poolRefByIndex[bond.poolIndex];
        PoolId id = poolRef.id;

        (uint128 collateral, uint128 slash, uint128 refund, uint16 slashBps) =
            _computeL2Settlement(bondId, id, bond, maturityBlock);

        Currency currency = bond.collateralIsCurrency0 ? poolRef.currency0 : poolRef.currency1;
        address refundRecipient = bond.refundRecipient;

        bond.state = BondState.SETTLED;

        maturity[id][maturityBlock].pendingBonds -= 1;

        if (slash > 0) {
            insurancePot[id][currency] += slash;
        }

        emit BondSettled(bondId, id, refundRecipient, currency, collateral, refund, slash, slashBps);

        if (refund > 0) {
            currency.transfer(refundRecipient, refund);
        }
    }

    /// @dev Saves each due, unfrozen reading for one occupied maturity bucket.
    /// Only endpoints in (lastUpdate, nowBlock] can be derived from this snapshot.
    /// Frozen endpoints are never overwritten, and empty buckets are never created
    /// by this helper. A single mask records which of the three readings are saved.
    ///
    /// Only C10 emits MaturityCheckpointed, so a bucket has one maturity event even
    /// if its endpoints are captured by different swaps or settlement calls.
    /// @param id Pool being observed.
    /// @param m Candidate maturity block.
    /// @param snapshot Accumulator before its tick or block number is advanced.
    /// @param lastUpdate Previous accumulator block.
    /// @param nowBlock Current block; later checkpoints are not yet due.
    function _freezeDueEndpoints(
        PoolId id,
        uint32 m,
        TickAccumulatorLib.Accumulator memory snapshot,
        uint32 lastUpdate,
        uint32 nowBlock
    ) private {
        MaturityCheckpoint storage bucket = maturity[id][m];

        if (bucket.pendingBonds == 0) return;

        uint8 mask = bucket.frozenMask;

        if (mask == FROZEN_ALL) return;

        if (m < C6_OFFSET_FROM_MATURITY) return;

        uint8 startingMask = mask;

        uint32 c6Block = m - C6_OFFSET_FROM_MATURITY;

        if (mask & FROZEN_C6 == 0 && c6Block > lastUpdate && c6Block <= nowBlock) {
            bucket.cumulativeMinus4 = snapshot.cumulativeAt(c6Block);
            mask |= FROZEN_C6;
        }

        uint32 c8Block = m - C8_OFFSET_FROM_MATURITY;

        if (mask & FROZEN_C8 == 0 && c8Block > lastUpdate && c8Block <= nowBlock) {
            bucket.cumulativeMinus2 = snapshot.cumulativeAt(c8Block);
            mask |= FROZEN_C8;
        }

        if (mask & FROZEN_C10 == 0 && m > lastUpdate && m <= nowBlock) {
            int56 cumulative = snapshot.cumulativeAt(m);

            bucket.cumulativeAtM = cumulative;
            mask |= FROZEN_C10;

            emit MaturityCheckpointed(id, m, cumulative);
        }

        if (mask != startingMask) {
            bucket.frozenMask = mask;
        }
    }

    /// @dev Reads a frozen checkpoint or saves it from a still-valid quiet interval.
    /// If no swap crossed the endpoint, the old tick still describes that interval:
    /// we carry it forward to the endpoint and store the exact cumulative there.
    /// This does not grant an automatic refund just because the pool was quiet.
    ///
    /// If the accumulator has already passed an unfrozen endpoint, its value is lost.
    /// We revert rather than guess from a newer tick. Frozen values are returned as
    /// stored, so post-maturity swaps cannot alter settlement.
    /// @param bondId Identifier used only for error diagnostics.
    /// @param id Pool to read.
    /// @param maturityBlock Bucket containing the endpoint.
    /// @param endpointBlock Exact block to observe.
    /// @param bit Frozen-mask bit for C6, C8 or C10.
    /// @return cumulative Tick cumulative at the requested endpoint, in tick-blocks.
    function _resolveEndpoint(bytes32 bondId, PoolId id, uint32 maturityBlock, uint32 endpointBlock, uint8 bit)
        private
        returns (int56 cumulative)
    {
        MaturityCheckpoint storage bucket = maturity[id][maturityBlock];

        uint8 mask = bucket.frozenMask;

        if (mask & bit != 0) {
            if (bit == FROZEN_C6) return bucket.cumulativeMinus4;
            if (bit == FROZEN_C8) return bucket.cumulativeMinus2;

            return bucket.cumulativeAtM;
        }

        TickAccumulatorLib.Accumulator memory acc = accumulator[id];

        if (acc.lastUpdate > endpointBlock) {
            revert MaturityCheckpointMissing(bondId, endpointBlock, acc.lastUpdate);
        }

        cumulative = acc.cumulativeAt(endpointBlock);

        if (bit == FROZEN_C6) {
            bucket.cumulativeMinus4 = cumulative;
        } else if (bit == FROZEN_C8) {
            bucket.cumulativeMinus2 = cumulative;
        } else {
            bucket.cumulativeAtM = cumulative;

            emit MaturityCheckpointed(id, maturityBlock, cumulative);
        }

        bucket.frozenMask = mask | bit;
    }

    /// @notice Reads or freezes C6, C8 and C10 for a pool's maturity bucket.
    /// @dev Resolves endpoints in time order so an error identifies the earliest
    /// missing reading. This function writes checkpoints but does not settle a bond
    /// or transfer tokens. It does not look up bondId or validate its relation to the
    /// supplied pool and maturity; bondId is only used in errors. Settlement supplies
    /// these values from the stored bond. An unfrozen future endpoint cannot be read.
    /// @param bondId Identifier for error diagnostics.
    /// @param id Pool whose accumulator and bucket are read.
    /// @param maturityBlock Bucket's maturity block.
    /// @return c6 Cumulative at maturity - 4, in tick-blocks.
    /// @return c8 Cumulative at maturity - 2, in tick-blocks.
    /// @return c10 Cumulative at maturity, in tick-blocks.
    function resolveEndpoints(bytes32 bondId, PoolId id, uint32 maturityBlock)
        public
        returns (int56 c6, int56 c8, int56 c10)
    {
        c6 = _resolveEndpoint(bondId, id, maturityBlock, maturityBlock - C6_OFFSET_FROM_MATURITY, FROZEN_C6);
        c8 = _resolveEndpoint(bondId, id, maturityBlock, maturityBlock - C8_OFFSET_FROM_MATURITY, FROZEN_C8);
        c10 = _resolveEndpoint(bondId, id, maturityBlock, maturityBlock, FROZEN_C10);
    }

    /// @notice Returns the recorded facts for a finalized or settled bond.
    /// @dev Settled records remain readable. Unknown and provisional records both
    /// revert with BondNotFound; raw storage inspection is outside this API guarantee.
    /// @param bondId Bond identifier.
    /// @return bond Stored record, including lifecycle state and original execution facts.
    function getBond(bytes32 bondId) external view returns (Bond memory bond) {
        bond = bonds[bondId];

        // slither-disable-next-line incorrect-equality
        if (bond.state == BondState.NONE || bond.state == BondState.PROVISIONAL) revert BondNotFound(bondId);
    }

    /// @notice Returns the original refundable collateral posted for a bond.
    /// @dev Calculated from its realized variable leg and the saved opening rate.
    /// This remains the original amount after settlement; it is not the remaining
    /// unsettled liability. Read getBond for state and BondSettled for refund/slash.
    /// Unknown and provisional records revert with BondNotFound.
    /// @param bondId Bond identifier.
    /// @return collateral Original collateral in raw units of the bond's collateral currency.
    function collateralAmountOf(bytes32 bondId) external view returns (uint128 collateral) {
        Bond memory bond = bonds[bondId];

        // slither-disable-next-line incorrect-equality
        if (bond.state == BondState.NONE || bond.state == BondState.PROVISIONAL) revert BondNotFound(bondId);

        return _collateralOf(bond);
    }

    /// @notice Reports whether an identifier belongs to a finalized or settled bond.
    /// @dev A settled bond still exists. Unknown and provisional records return false.
    /// Use getBond to distinguish a bond awaiting settlement from one already settled.
    /// @param bondId Identifier to check.
    /// @return True for FINALIZED or SETTLED; false for NONE or PROVISIONAL.
    function bondExists(bytes32 bondId) external view returns (bool) {
        BondState state = bonds[bondId].state;

        // slither-disable-next-line incorrect-equality
        return state == BondState.FINALIZED || state == BondState.SETTLED;
    }
}
