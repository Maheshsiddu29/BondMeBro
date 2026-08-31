// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {TickAccumulatorLib} from "./libraries/TickAccumulatorLib.sol";
import {PersistenceMathLib} from "./libraries/PersistenceMathLib.sol";
import {HookDataCodec} from "./libraries/HookDataCodec.sol";

/// @title BondMeBro — outcome-linked LP insurance for Uniswap v4.
/// @notice Swaps whose total input exceeds the active pool's per-currency threshold post a
///         refundable bond. Exact-input bonds are taken before the pool executes and the
///         pool receives only the net amount; exact-output bonds are solved after the pool
///         reports its real input. After `observationBlocks`, the bond settles against the
///         pool's own time-weighted average tick: impact that reverted refunds in full;
///         impact that persisted is slashed into the LP insurance pot.
///
/// @dev OWNERSHIP. The hook only sees the direct caller of `PoolManager.swap` — usually a
///      router, not the trader. A bonded swap must carry the fixed 37-byte versioned
///      `HookDataCodec` payload containing the refund recipient and maximum accepted bond.
///      Empty data remains valid only for unbonded exact-input swaps, where it is used as a
///      fallback for piggyback settlement rewards. Refunds go to the encoded recipient; a
///      router must never substitute `tx.origin` for this explicit value.
///
/// @dev SETTLEMENT TRIGGER (Problem 2). Two paths, no required keeper:
///      1. Piggyback — every swap first settles the matured prefix of the queue,
///      capped at `maxSettlesPerSwap`, so normal pool activity drains bonds and no
///      single swapper pays unbounded cleanup gas. The current swap's resolved owner
///      receives `settlerFeeBps` of each slash as compensation; the fee is never taken
///      from a refund.
///      2. Permissionless — anyone may call `settleBonds` at any time; matured bonds settle
///      in FIFO order and the caller earns `settlerFeeBps` of each SLASHED amount (never
///      of refunds: honest traders always receive exactly 100% back). This keeps the
///      "no external dependency" story as a safety property — nothing breaks with zero
///      keepers — while making liveness profitable in pools that have gone quiet.
///
/// @dev SETTLEMENT WINDOW. The TWA runs [openBlock, settle-block]. Piggyback settlement
///      keeps late settling rare; where it happens, `observe` extrapolation extends the
///      window at the last recorded tick — a one-directional bias toward slash (no fresh
///      reversion evidence), which matches the quiet-pool rule documented in
///      TickAccumulatorLib. Settlement timing is never owner-chosen: owners cannot wait for
///      favourable drift past maturity and then settle themselves, because ANY later swap
///      or keeper call settles the prefix they sit in.
///
/// @dev INSURANCE POT. Slashed amounts accrue per (pool, currency) in the hook's own token
///      balances; `donatePot` is callable by anyone and pushes the accrued amount to
///      currently-in-range LPs via PoolManager.donate. Donating rewards the LPs in range at
///      donation time, not necessarily those in range at harm time — accepted MVP
///      simplification, documented for the demo.
contract BondMeBro is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using TickAccumulatorLib for TickAccumulatorLib.Accumulator;

    uint256 internal constant BPS = 10_000;

    /// @dev Hard cap for a single permissionless settle call, so a caller can never be
    ///      gas-griefed by an enormous queue.
    uint256 internal constant MAX_SETTLE_BATCH = 32;

    /// @dev PoolManager.donate stores amounts as int128, so a large accumulated pot is
    ///      drained in bounded chunks rather than becoming permanently undistributable.
    uint256 internal constant MAX_DONATION = (uint256(1) << 127) - 1;

    // ------------------------------------------------------------------
    // Config & state
    // ------------------------------------------------------------------

    struct Config {
        /// @dev Default bond rate in basis points. Pool configurations cap this at 100 (1%).
        uint16 bondBps;
        /// @dev Persistence noise floor (PersistenceMathLib.refundTol).
        uint24 refundTolTicks;
        /// @dev N — blocks a bond seasons before it can settle.
        uint32 observationBlocks;
        /// @dev Per-block clamp for the accumulator's recorded tick (truncation defense).
        uint24 maxAbsTickDelta;
        /// @dev Share of each SLASHED amount paid to the piggyback owner or direct settler.
        uint16 settlerFeeBps;
        /// @dev Max piggyback settlements per swap.
        uint8 maxSettlesPerSwap;
        /// @dev Default minimum total input when currency0 is the swap input.
        uint96 minBondedAmount0;
        /// @dev Default minimum total input when currency1 is the swap input.
        uint96 minBondedAmount1;
        /// @dev Explicit owner. CREATE2 deployment is performed by a proxy, so msg.sender is
        ///      not a reliable way to assign the EOA that may configure pools.
        address owner;
    }

    /// @notice Default bond rate retained as an immutable deployment manifest value.
    uint16 public immutable bondBps;
    uint24 public immutable refundTolTicks;
    uint32 public immutable observationBlocks;
    uint24 public immutable maxAbsTickDelta;
    uint16 public immutable settlerFeeBps;
    uint8 public immutable maxSettlesPerSwap;
    uint96 public immutable defaultMinBondedAmount0;
    uint96 public immutable defaultMinBondedAmount1;
    address public immutable owner;

    /// @notice Per-pool custody configuration. The three fields occupy one storage slot.
    struct PoolConfig {
        uint96 minBondedAmount0;
        uint96 minBondedAmount1;
        uint16 bondBps;
    }

    mapping(PoolId => PoolConfig) internal _poolConfigs;

    /// @notice A posted bond. Enqueued FIFO per pool, so matured bonds are always a prefix.
    struct Bond {
        address owner;
        uint48 openBlock;
        int24 tickBefore;
        int24 tickAfter;
        Currency currency;
        int56 cumulativeAtOpen;
        uint128 amount;
        bytes32 next;
    }

    mapping(PoolId => mapping(bytes32 => Bond)) internal _bonds;
    mapping(PoolId => bytes32) internal _queueHead;
    mapping(PoolId => bytes32) internal _queueTail;
    mapping(PoolId => uint64) internal _bondNonce;
    mapping(PoolId => mapping(Currency => uint256)) public insurancePot;
    /// @notice Pull-payment fallback for recipients whose token/native receiver rejects
    ///      settlement. A bad recipient can no longer freeze the FIFO queue for everyone else.
    mapping(address => mapping(Currency => uint256)) public claimablePayments;
    mapping(PoolId => TickAccumulatorLib.Accumulator) internal _accumulators;

    /// @dev Settlement pays ERC-20/native tokens to arbitrary owners and settler callers.
    ///      A callback-capable token or recipient must not be able to re-enter the queue
    ///      walker while its head is still pending. Direct settlement re-entry is a no-op;
    ///      nested swaps are rejected, leaving the outer settlement sole owner of the queue.
    bool private _settlementInProgress;

    /// @dev The pre-swap tick of the in-flight swap, per pool. Set in _beforeSwap, consumed
    ///      in _afterSwap. `set` flag because tick 0 is a real tick.
    mapping(PoolId => int24) internal _pendingTick;
    mapping(PoolId => bool) internal _pendingSet;

    /// @dev Exact-input custody is decided before the pool swap, but the bond record needs the
    ///      post-swap tick and accumulator reading. This temporary record bridges the two
    ///      callbacks; a reverted swap reverts it together with token custody.
    struct PendingBond {
        address owner;
        Currency currency;
        uint128 amount;
    }

    mapping(PoolId => PendingBond) internal _pendingBonds;

    // ------------------------------------------------------------------
    // Events & errors
    // ------------------------------------------------------------------

    event BondOpened(
        PoolId indexed poolId,
        bytes32 indexed bondId,
        address indexed owner,
        Currency currency,
        uint128 amount,
        int24 tickBefore,
        int24 tickAfter,
        uint48 maturesAtBlock
    );
    event BondSettled(
        PoolId indexed poolId,
        bytes32 indexed bondId,
        address indexed owner,
        address settler,
        uint128 refundAmount,
        uint128 slashAmount,
        uint128 settlerFee,
        int24 twaReference,
        uint16 persistenceBps
    );
    event PotDonated(PoolId indexed poolId, Currency indexed currency, uint256 amount, address caller);
    event PaymentDeferred(address indexed recipient, Currency indexed currency, uint256 amount);
    event PaymentsClaimed(address indexed recipient, Currency indexed currency, uint256 amount);
    event PoolConfigUpdated(
        PoolId indexed poolId, uint96 minBondedAmount0, uint96 minBondedAmount1, uint16 bondBps, address indexed caller
    );

    error InvalidConfig();
    error InvalidPoolConfig();
    error NotOwner();
    error PoolNotInitialized();
    error BondTooLarge();
    error BondTooSmall();
    error BondSlippage();
    error NothingToDonate();
    error NothingToClaim();
    error PaymentTransferFailed();
    error SettlementReentrancy();
    error InvalidCurrency();
    error InvalidPoolManager();
    // NotPoolManager() is inherited from BaseHook and reused for unlockCallback.

    constructor(IPoolManager _poolManager, Config memory cfg) BaseHook(_poolManager) {
        if (address(_poolManager).code.length == 0) revert InvalidPoolManager();
        if (
            cfg.settlerFeeBps > BPS || cfg.observationBlocks == 0 || cfg.maxAbsTickDelta == 0
                || cfg.maxSettlesPerSwap == 0 || cfg.maxSettlesPerSwap > MAX_SETTLE_BATCH || cfg.owner == address(0)
        ) revert InvalidConfig();
        _validatePoolConfig(cfg.minBondedAmount0, cfg.minBondedAmount1, cfg.bondBps);

        bondBps = cfg.bondBps;
        refundTolTicks = cfg.refundTolTicks;
        observationBlocks = cfg.observationBlocks;
        maxAbsTickDelta = cfg.maxAbsTickDelta;
        settlerFeeBps = cfg.settlerFeeBps;
        maxSettlesPerSwap = cfg.maxSettlesPerSwap;
        defaultMinBondedAmount0 = cfg.minBondedAmount0;
        defaultMinBondedAmount1 = cfg.minBondedAmount1;
        owner = cfg.owner;
    }

    /// @dev AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA |
    ///      AFTER_SWAP_RETURNS_DELTA. Exact-input bonds adjust the swap before the pool
    ///      executes; exact-output bonds are solved after the pool reports its real input.
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

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = key.toId();
        // Seed from the pool's declared starting tick so the first swap is also clamped.
        _accumulators[id].initialize(tick);
        _poolConfigs[id] = PoolConfig({
            minBondedAmount0: defaultMinBondedAmount0,
            minBondedAmount1: defaultMinBondedAmount1,
            bondBps: bondBps
        });
        emit PoolConfigUpdated(id, defaultMinBondedAmount0, defaultMinBondedAmount1, bondBps, msg.sender);
        return BaseHook.afterInitialize.selector;
    }

    /// @notice Updates the amount thresholds and bond rate for one initialized pool.
    /// @dev All three values are enabled together or disabled together. A zero threshold in
    ///      one direction would otherwise make every swap in that direction qualify. The
    ///      1% cap is deliberately independent of the immutable global settlement settings.
    function setPoolConfig(PoolKey calldata key, uint96 minBondedAmount0, uint96 minBondedAmount1, uint16 poolBondBps)
        external
    {
        if (msg.sender != owner) revert NotOwner();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        _validatePoolConfig(minBondedAmount0, minBondedAmount1, poolBondBps);
        _poolConfigs[id] =
            PoolConfig({minBondedAmount0: minBondedAmount0, minBondedAmount1: minBondedAmount1, bondBps: poolBondBps});
        emit PoolConfigUpdated(id, minBondedAmount0, minBondedAmount1, poolBondBps, msg.sender);
    }

    /// @notice Returns the active custody configuration for a pool.
    function getPoolConfig(PoolId id) external view returns (PoolConfig memory) {
        return _poolConfigs[id];
    }

    function _validatePoolConfig(uint96 minBondedAmount0, uint96 minBondedAmount1, uint16 poolBondBps) internal pure {
        bool disabled = minBondedAmount0 == 0 && minBondedAmount1 == 0 && poolBondBps == 0;
        bool enabled = minBondedAmount0 != 0 && minBondedAmount1 != 0 && poolBondBps != 0;
        if ((!disabled && !enabled) || poolBondBps > 100) revert InvalidPoolConfig();
    }

    // ------------------------------------------------------------------
    // Swap callbacks
    // ------------------------------------------------------------------

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // A payout invokes a user-controlled token/receiver. A nested PoolManager swap
        // would otherwise overwrite the pending tick or append a bond while the outer FIFO
        // walker still owns the queue head. The payout helper catches this revert and turns
        // that receiver's payment into a pull payment instead.
        if (_settlementInProgress) revert SettlementReentrancy();

        PoolId id = key.toId();

        // Piggyback settlement: routine swaps drain matured bonds without any keeper.
        // The resolved owner is the party the router told us is paying for this swap;
        // compensating it keeps cleanup gas from becoming a hidden tax on pool activity.
        _settleMaturedPrefix(id, maxSettlesPerSwap, _resolveOwner(sender, hookData));

        // Record the pre-swap tick; _afterSwap consumes it. Only `tick` is needed here;
        // sqrtPriceX96 / protocolFee / lpFee are intentionally discarded.
        // slither-disable-next-line unused-return
        (, int24 tick,,) = poolManager.getSlot0(id);
        _pendingTick[id] = tick;
        _pendingSet[id] = true;

        // Exact-output swaps must carry a complete payload even when the eventual input is
        // below the configured threshold: the user has explicitly opted into this swap's
        // refund recipient and bond limit. Exact-input payloads are decoded only if the
        // amount threshold says this swap can actually open a bond.
        if (params.amountSpecified >= 0) {
            HookDataCodec.decode(hookData);
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolConfig memory poolConfig = _poolConfigs[id];
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        uint256 grossInput = uint256(-params.amountSpecified);
        uint256 minimumInput = params.zeroForOne ? poolConfig.minBondedAmount0 : poolConfig.minBondedAmount1;

        if (poolConfig.bondBps == 0 || grossInput < minimumInput) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (address owner_, uint128 maxBondAmount) = HookDataCodec.decode(hookData);
        uint256 bond = (grossInput * uint256(poolConfig.bondBps)) / BPS;
        if (bond == 0) revert BondTooSmall();
        if (bond >= grossInput) revert BondTooLarge(); // INV-NOOP: the pool must receive input
        if (bond > maxBondAmount) revert BondSlippage();
        if (bond >= (uint256(1) << 127)) revert BondTooLarge();

        _pendingBonds[id] = PendingBond({owner: owner_, currency: inputCurrency, amount: bond.toUint128()});
        // `take` moves the bond into hook custody and creates the negative half of the hook
        // delta. The returned specified delta makes the swapper pay gross input while the
        // pool executes only gross minus bond.
        poolManager.take(inputCurrency, address(this), bond);

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(bond.toInt128(), 0), 0);
    }

    /// @dev Everything the bond bookkeeper needs from the swap, passed as a struct to keep
    ///      stack frames under the 16-slot limit without via-IR.
    struct SwapReading {
        int24 tickBefore;
        int24 tickAfter;
        int56 cumulativeAtOpen;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();

        // slither-disable-next-line unused-return
        (, int24 tickAfter,,) = poolManager.getSlot0(id);

        // The accumulator is fed on EVERY swap, bonded or not: a silent gap would bias
        // every window spanning it. Update before opening the bond so cumulativeAtOpen
        // reflects the post-swap recorded tick.
        int56 cumulativeNow = _accumulators[id].update(tickAfter, maxAbsTickDelta);

        int24 tickBefore = tickAfter;
        if (_pendingSet[id]) {
            tickBefore = _pendingTick[id];
            _pendingSet[id] = false;
        }

        SwapReading memory reading = SwapReading(tickBefore, tickAfter, cumulativeNow);
        if (params.amountSpecified < 0) {
            PendingBond memory pending = _pendingBonds[id];
            delete _pendingBonds[id];
            if (pending.amount != 0) {
                _openBond(
                    id,
                    pending.owner,
                    pending.currency,
                    pending.amount,
                    reading.tickBefore,
                    reading.tickAfter,
                    reading.cumulativeAtOpen
                );
            }
            // The beforeSwap return delta is combined by v4's Hooks library. No afterSwap
            // delta is needed for exact input; custody was completed before pool execution.
            return (BaseHook.afterSwap.selector, 0);
        }

        return (BaseHook.afterSwap.selector, _bondExactOutput(key, params, delta, hookData, id, reading));
    }

    /// @dev Exact-output input is unknown until PoolManager returns the swap delta. The bond
    ///      is solved from poolInput so bond / (poolInput + bond) equals the configured rate.
    struct BondTerms {
        address owner;
        Currency currency;
        uint128 amount;
    }

    function _bondExactOutput(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData,
        PoolId id,
        SwapReading memory reading
    ) internal returns (int128 hookDelta) {
        BondTerms memory terms = _exactOutputTerms(key, params, delta, hookData, id);
        if (terms.amount == 0) return 0;

        _openBond(
            id,
            terms.owner,
            terms.currency,
            terms.amount,
            reading.tickBefore,
            reading.tickAfter,
            reading.cumulativeAtOpen
        );
        poolManager.take(terms.currency, address(this), terms.amount);
        // afterSwap returns the unspecified-currency delta. For exact-output, the input is
        // the unspecified side in both swap directions, so this adds the bond to the user's
        // final input obligation.
        hookDelta = uint256(terms.amount).toInt128();
    }

    function _exactOutputTerms(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData,
        PoolId id
    ) internal view returns (BondTerms memory terms) {
        PoolConfig memory poolConfig = _poolConfigs[id];
        if (poolConfig.bondBps == 0) return terms;

        terms.currency = params.zeroForOne ? key.currency0 : key.currency1;
        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (inputDelta >= 0) return terms;

        uint256 poolInput = uint256(-int256(inputDelta));
        uint256 bond = (poolInput * uint256(poolConfig.bondBps)) / (BPS - uint256(poolConfig.bondBps));
        uint256 totalInput = poolInput + bond;
        uint256 minimumInput = params.zeroForOne ? poolConfig.minBondedAmount0 : poolConfig.minBondedAmount1;
        if (totalInput < minimumInput) return terms;
        if (bond == 0) revert BondTooSmall();
        if (bond >= totalInput || bond >= (uint256(1) << 127)) revert BondTooLarge();

        uint128 maxBondAmount;
        (terms.owner, maxBondAmount) = HookDataCodec.decode(hookData);
        if (bond > maxBondAmount) revert BondSlippage();
        terms.amount = bond.toUint128();
    }

    function _resolveOwner(address swapCaller, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 0) return swapCaller;
        if (hookData.length != HookDataCodec.LENGTH) revert HookDataCodec.InvalidHookDataLength();
        (address refundRecipient,) = HookDataCodec.decode(hookData);
        return refundRecipient;
    }

    // ------------------------------------------------------------------
    // Bond lifecycle
    // ------------------------------------------------------------------

    function _openBond(
        PoolId id,
        address bondOwner,
        Currency currency,
        uint128 amount,
        int24 tickBefore,
        int24 tickAfter,
        int56 cumulativeAtOpen
    ) internal {
        bytes32 bondId = keccak256(abi.encode(id, uint64(++_bondNonce[id])));
        _bonds[id][bondId] = Bond({
            owner: bondOwner,
            openBlock: uint48(block.number),
            tickBefore: tickBefore,
            tickAfter: tickAfter,
            currency: currency,
            cumulativeAtOpen: cumulativeAtOpen,
            amount: amount,
            next: bytes32(0)
        });

        bytes32 tail = _queueTail[id];
        if (tail == bytes32(0)) {
            _queueHead[id] = bondId;
        } else {
            _bonds[id][tail].next = bondId;
        }
        _queueTail[id] = bondId;

        emit BondOpened(
            id, bondId, bondOwner, currency, amount, tickBefore, tickAfter, uint48(block.number) + observationBlocks
        );
    }

    /// @notice Permissionless settlement (Problem 2, second path). Settles the matured
    ///         prefix of the pool's bond queue — FIFO order means matured bonds are always
    ///         a prefix — paying the caller `settlerFeeBps` of each slash.
    /// @param key The pool key.
    /// @param maxCount Max bonds to settle this call (capped at MAX_SETTLE_BATCH). 0 = no-op.
    /// @return settled How many bonds were settled.
    function settleBonds(PoolKey calldata key, uint256 maxCount) external returns (uint256 settled) {
        if (maxCount > MAX_SETTLE_BATCH) maxCount = MAX_SETTLE_BATCH;
        return _settleMaturedPrefix(key.toId(), maxCount, msg.sender);
    }

    /// @notice Piggyback + permissionless shared core. Settles matured queue prefix, oldest
    ///         first, stopping at the first immature bond (maturity is monotone in FIFO
    ///         order). A zero `feeRecipient` is reserved for an explicitly fee-free
    ///         internal call; both public paths normally supply a recipient.
    // The loop is explicitly bounded by maxSettlesPerSwap or MAX_SETTLE_BATCH.
    // Settlement effects are recorded before payout; re-entry is blocked by the progress flag.
    // slither-disable-next-line reentrancy-eth
    function _settleMaturedPrefix(PoolId id, uint256 maxCount, address feeRecipient)
        internal
        returns (uint256 settled)
    {
        if (maxCount == 0 || _settlementInProgress) return 0;
        _settlementInProgress = true;

        bytes32 head = _queueHead[id];
        while (settled < maxCount && head != bytes32(0)) {
            Bond storage b = _bonds[id][head];
            if (block.number < uint256(b.openBlock) + uint256(observationBlocks)) break;
            bytes32 next = b.next;
            _settle(id, head, feeRecipient);
            head = next;
            unchecked {
                ++settled;
            }
        }
        _queueHead[id] = head;
        if (head == bytes32(0)) _queueTail[id] = bytes32(0);
        _settlementInProgress = false;
    }

    // Effects (bond deletion, queue accounting, and pot accounting) precede all payouts.
    // Failed payouts become pull payments instead of reverting a completed settlement.
    // slither-disable-next-line reentrancy-eth
    function _settle(PoolId id, bytes32 bondId, address feeRecipient) internal {
        Bond memory b = _bonds[id][bondId];

        // Window [open, now]: observe() extends a late settle at the last recorded tick —
        // a deliberate lean toward slash. elapsed > 0 is guaranteed by the maturity gate.
        uint48 elapsed = uint48(block.number - uint256(b.openBlock));
        int56 cumulativeNow = TickAccumulatorLib.observe(_accumulators[id]);
        int24 referenceTick = TickAccumulatorLib.twaTick(b.cumulativeAtOpen, cumulativeNow, elapsed);

        uint16 persistenceBps = PersistenceMathLib.computeBps(b.tickBefore, b.tickAfter, referenceTick, refundTolTicks);
        (uint128 slashAmount, uint128 refundAmount) = PersistenceMathLib.split(b.amount, persistenceBps);

        uint128 fee = 0;
        if (feeRecipient != address(0)) fee = ((uint256(slashAmount) * settlerFeeBps) / BPS).toUint128();
        uint128 toPot = slashAmount - fee;

        // Effects before interactions: the bond record is gone before any token moves,
        // so a callback-happy token cannot settle or re-settle it mid-payout.
        delete _bonds[id][bondId];
        insurancePot[id][b.currency] += toPot;

        _payOrCredit(b.currency, b.owner, refundAmount);
        _payOrCredit(b.currency, feeRecipient, fee);

        emit BondSettled(
            id, bondId, b.owner, feeRecipient, refundAmount, slashAmount, fee, referenceTick, persistenceBps
        );
    }

    /// @dev Standard ERC-20s and EOAs are paid inline. If a token or recipient rejects
    ///      the transfer, record a pull payment instead of reverting after the bond has been
    ///      deleted. This keeps an arbitrary owner from freezing all later FIFO settlements.
    function _payOrCredit(Currency currency, address recipient, uint256 amount) internal {
        if (amount < 1) return;
        if (!_tryTransfer(currency, recipient, amount)) {
            claimablePayments[recipient][currency] += amount;
            emit PaymentDeferred(recipient, currency, amount);
        }
    }

    // Recipients are intentionally arbitrary: bond owners and permissionless settler
    // callers are user-controlled addresses, not a trusted payout list.
    // slither-disable-next-line arbitrary-send-eth
    function _tryTransfer(Currency currency, address recipient, uint256 amount) internal returns (bool success) {
        if (currency.isAddressZero()) {
            (success,) = recipient.call{value: amount}("");
            return success;
        }

        (bool tokenCallSuccess, bytes memory result) =
            Currency.unwrap(currency).call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, recipient, amount));
        if (!tokenCallSuccess) return false;
        if (result.length < 1) return true;
        if (result.length != 32) return false;

        // Do not abi.decode here: a hostile token can return a 32-byte word other than
        // 0/1, and the decoder would revert instead of giving us the intended fallback.
        uint256 returned;
        assembly ("memory-safe") {
            returned := mload(add(result, 32))
        }
        return returned > 0 && returned < 2;
    }

    /// @notice Claims a deferred refund or settler reward. Ordinary recipients never need
    ///      this path; it is a safety valve for callback-capable tokens and non-payable
    ///      contracts. The transfer is retried atomically and the amount remains claimable
    ///      if the recipient still rejects it.
    function claimPayments(Currency currency) external returns (uint256 amount) {
        amount = claimablePayments[msg.sender][currency];
        if (amount < 1) revert NothingToClaim();

        delete claimablePayments[msg.sender][currency];
        if (!_tryTransfer(currency, msg.sender, amount)) revert PaymentTransferFailed();
        emit PaymentsClaimed(msg.sender, currency, amount);
    }

    // ------------------------------------------------------------------
    // Insurance pot distribution
    // ------------------------------------------------------------------

    /// @notice Push the next chunk of the pot for one (pool, currency) to the pool's
    ///         in-range LPs, via PoolManager.donate. Permissionless: whoever wants the pot
    ///         distributed pays the gas. Large pots are drained over multiple calls because
    ///         PoolManager represents one donation as a signed int128 delta. Reverts through
    ///         PoolManager if the pool currently has no in-range liquidity.
    // Pot accounting is cleared before PoolManager.unlock; a failed donation reverts the
    // entire call and cannot strand a partial payout.
    // slither-disable-next-line reentrancy-events
    function donatePot(PoolKey calldata key, Currency currency) external {
        if (
            Currency.unwrap(currency) != Currency.unwrap(key.currency0)
                && Currency.unwrap(currency) != Currency.unwrap(key.currency1)
        ) revert InvalidCurrency();

        PoolId id = key.toId();
        uint256 amount = insurancePot[id][currency];
        if (amount == 0) revert NothingToDonate();
        if (amount > MAX_DONATION) amount = MAX_DONATION;

        insurancePot[id][currency] -= amount;
        // The callback's return data is intentionally empty; unlock reverts on failure.
        // slither-disable-next-line unused-return
        poolManager.unlock(abi.encode(key, currency, amount));

        emit PotDonated(key.toId(), currency, amount, msg.sender);
    }

    /// @dev donatePot's callback: donate, then pay the PoolManager from the hook's own
    ///      balance (sync/transfer/settle for ERC-20s, settle{value} for native).
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (PoolKey memory key, Currency currency, uint256 amount) = abi.decode(data, (PoolKey, Currency, uint256));
        if (
            Currency.unwrap(currency) != Currency.unwrap(key.currency0)
                && Currency.unwrap(currency) != Currency.unwrap(key.currency1)
        ) revert InvalidCurrency();

        (uint256 amount0, uint256 amount1) =
            Currency.unwrap(currency) == Currency.unwrap(key.currency0) ? (amount, uint256(0)) : (uint256(0), amount);

        // Both calls revert atomically if the pool cannot receive the donation or the
        // hook cannot settle its exact payment.
        // slither-disable-next-line unused-return
        poolManager.donate(key, amount0, amount1, "");

        if (currency.isAddressZero()) {
            // slither-disable-next-line unused-return
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), amount);
            // slither-disable-next-line unused-return
            poolManager.settle();
        }
        return "";
    }

    /// @dev Native bond custody is funded only by PoolManager.take. Rejecting unsolicited
    ///      ETH prevents the hook balance from containing unaccounted funds.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ------------------------------------------------------------------
    // Views (test / UI surface)
    // ------------------------------------------------------------------

    function getBond(PoolId id, bytes32 bondId) external view returns (Bond memory) {
        return _bonds[id][bondId];
    }

    function queueBounds(PoolId id) external view returns (bytes32 head, bytes32 tail) {
        return (_queueHead[id], _queueTail[id]);
    }

    function queueLength(PoolId id) external view returns (uint256 length) {
        bytes32 cur = _queueHead[id];
        while (cur != bytes32(0)) {
            cur = _bonds[id][cur].next;
            ++length;
        }
    }

    function getAccumulator(PoolId id) external view returns (TickAccumulatorLib.Accumulator memory) {
        return _accumulators[id];
    }

    /// @dev The owner a swap would be attributed to, exposed for off-chain quoting.
    function resolveOwner(address swapCaller, bytes calldata hookData) external pure returns (address) {
        return _resolveOwner(swapCaller, hookData);
    }
}
