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
import {TickAccumulatorLib} from "./libraries/TickAccumulatorLib.sol";

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
    using TickAccumulatorLib for TickAccumulatorLib.Accumulator;

    /*              CONSTANTS            /*/

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Max bond rate allowed by the contract is 1% of gross input i;e 100 bps.
    /// @dev This is a compile-time constant and cannot be changed by the owner.Keeping Max bond rate at 1% gives large safety margin from INV-NOOP boundary , where bond would equal to trader's full input

    uint16 public constant MAX_BOND_BPS = 100;

    /// @notice Technical maximum scan horizon, in blocks. This is `W` in ADR-0003.
    ///
    /// @dev A GAS DECISION, chosen by measurement — NOT the economic observation period, which is
    ///      `OBSERVATION_BLOCKS` below. The two are deliberately different numbers.
    ///
    ///      `W` bounds the maturity scan: a swap inspects at most `W` buckets whatever the bond
    ///      count or the length of the preceding quiet period.
    ///
    ///      Chosen from the measured Stage 3 scan-cost curve, which is linear:
    ///
    ///          empty bucket read      2,464 gas   (cold SLOAD plus loop overhead)
    ///          occupied bucket freeze 3,176 gas   (the read, plus a warm SSTORE and an event)
    ///
    ///      Against the 150,000 `beforeSwap` ceiling and the worst pre-scan cost of 60,489
    ///      (exact-output, after ADR-0004 moved the record header into this callback), 89,511 gas
    ///      is available. A hypothetical all-occupied W=32 scan measures 107,636 for the scan
    ///      alone and breaches; W=16 leaves a real margin. See the T5.1 Stage 3 review report.
    ///
    ///      ADR-0003 § 3.1 frames `W` as a per-pool cap; this narrows it to one protocol-wide
    ///      constant because `PoolConfig` is unchanged and per-pool windows are out of scope.
    uint32 public constant MAX_OBSERVATION_BLOCKS = 16;

    /// @notice The protocol's economic observation period, in blocks.
    ///
    /// @dev AN ECONOMIC DECISION, NOT A GAS ONE, and deliberately NOT set to the largest value
    ///      that fits the gas budget. It is how long the mechanism waits before judging whether a
    ///      swap's price displacement persisted, so it belongs to the product, not the profiler.
    ///
    ///      THIS VALUE IS A PLACEHOLDER. It was NOT chosen economically, and 10 carries no
    ///      analytical weight — a worked example in a design document is an illustration, not a
    ///      calibrated observation period. It exists so the contract compiles and can be tested.
    ///
    ///      **Choosing the real value is an OUTSTANDING DECISION and belongs to the persistence
    ///      research, not to the gas work that fixed `MAX_OBSERVATION_BLOCKS`.** It determines how
    ///      long the mechanism waits before judging whether a price displacement persisted, which
    ///      is the core economic parameter of the whole mechanism: too short and ordinary noise
    ///      reads as persistence, too long and the bond is held far beyond its useful life. That
    ///      trade-off can only be settled against the simulation and toxicity research, none of
    ///      which is present in this repository.
    ///
    ///      Must satisfy `0 < OBSERVATION_BLOCKS <= MAX_OBSERVATION_BLOCKS`; 10 <= 16 holds, with
    ///      room to raise it without re-measuring the scan.
    ///
    ///      A useful consequence of `OBSERVATION_BLOCKS <= MAX_OBSERVATION_BLOCKS`: the number of
    ///      OCCUPIED buckets one advancement can cross is bounded by `OBSERVATION_BLOCKS`, not by
    ///      `W`. A bucket at `m` is occupied only if a bond opened at `m - OBSERVATION_BLOCKS`,
    ///      and opening a bond advances the cursor — so distinct occupied buckets require distinct
    ///      opening blocks within the last `OBSERVATION_BLOCKS`. The rest of the horizon can only
    ///      ever be cheaper empty reads.
    ///
    ///      `_maturityOf` is the single place this is applied.
    uint32 public constant OBSERVATION_BLOCKS = 10;

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

    /// @notice Compact reference to a pool, written once at initialization.
    ///
    /// @dev Exists so a `Bond` can identify its pool with a 4-byte index instead of a 32-byte
    ///      `PoolId` plus a 20-byte currency. That is not micro-optimisation: it is the difference
    ///      between a 2-slot and a 4-slot bond record, i.e. ~44,200 gas on EVERY bonded swap,
    ///      against a one-off cost at pool creation which is off the swap path entirely.
    struct PoolRef {
        PoolId id;
        Currency currency0;
        Currency currency1;
    }

    /// @notice A bond's permanent record. Two storage slots.
    ///
    /// @dev Everything T5B needs is bound HERE, at the moment of the swap. Settlement must not
    ///      accept the recipient, currency, amount, maturity, pool or opening observation as
    ///      caller-supplied arguments — a permissionless settler could otherwise nominate them.
    ///
    ///      Packing (verified with `forge inspect BondMeBro storage-layout`):
    ///        slot 0: refundRecipient 20 + openBlock 4 + maturityBlock 4 + poolIndex 4 = 32 bytes
    ///        slot 1: amount 16 + cumulativeAtOpen 7 + tickBefore 3 + tickAfter 3 + flags 1 = 30
    ///
    ///      Two slots is the floor for this field set: `refundRecipient` (20) plus any useful
    ///      `amount` width already fills the first slot.
    ///
    /// @param refundRecipient Address the refund is owed to, from validated hookData. Never
    ///        `sender` and never `tx.origin`.
    /// @param openBlock Block the bond opened in.
    /// @param maturityBlock Fixed at open, never recomputed. `openBlock + OBSERVATION_BLOCKS`.
    /// @param poolIndex Index into `poolRefByIndex`, giving the PoolId and both currencies.
    /// @param amount Collateral held, in raw units of the input currency.
    /// @param cumulativeAtOpen Tick accumulator value at `openBlock`; the window's start reading.
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @param inputIsCurrency0 True when the bond is denominated in the pool's currency0.
    /// @param state Lifecycle marker. `NONE` / `PROVISIONAL` / `FINALIZED` — see `BondState`.
    ///        Packed into slot 1 deliberately: slot 1 is the slot `_afterSwap` must write anyway
    ///        to record `amount` and `tickAfter`, so finalization is a WARM update to an
    ///        already-touched slot rather than a second cold write. ADR-0004 Rule 2.
    struct Bond {
        address refundRecipient;
        uint32 openBlock;
        uint32 maturityBlock;
        uint32 poolIndex;
        uint128 amount;
        int56 cumulativeAtOpen;
        int24 tickBefore;
        int24 tickAfter;
        bool inputIsCurrency0;
        BondState state;
    }

    /// @notice One maturity bucket, shared by every bond maturing in the same block. One slot.
    ///
    /// @dev THREE LIFECYCLE STATES, NOT ONE FLAG (ADR-0003 § 4). `registered` is
    ///      `pendingBonds > 0`; `checkpointed` is this struct's boolean; `settled` is per-bond and
    ///      belongs to T5B. They are independent: a bond can be unsettled long after its checkpoint
    ///      froze, and a bond can be mature with its checkpoint still unfrozen after a quiet gap.
    ///
    /// @param cumulative Accumulator value exactly at this maturity block. Immutable once frozen.
    /// @param pendingBonds Registered-but-unsettled bonds depending on this bucket. A liability
    ///        count only — it must NEVER decide whether the bucket needs checkpointing.
    /// @param checkpointed Whether `cumulative` has been permanently written.
    /// @notice Lifecycle marker stored inside a `Bond`.
    ///
    /// @dev ADR-0004 Rule 1. `NONE == 0` matters: an untouched or cleared mapping entry reads as
    ///      `NONE` for free, so "never existed" and "explicitly cleared" are the same state and
    ///      need no distinguishing write.
    ///
    ///      An explicit field rather than inferring "provisional" from `amount == 0`: that would
    ///      overload a value field with a lifecycle meaning and conflate "not finalized yet" with
    ///      "finalized with a zero amount".
    enum BondState {
        NONE,
        PROVISIONAL,
        FINALIZED
    }

    /// @notice Pre-swap accumulator observation, passed between callback helpers.
    /// @dev A struct purely to keep helper signatures inside the EVM stack limit.
    struct Observation {
        int24 tickBefore;
        int24 tickAfter;
        int56 cumulativeAtOpen;
    }

    struct MaturityCheckpoint {
        int56 cumulative;
        uint32 pendingBonds;
        bool checkpointed;
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

    /// @notice Time-weighted tick accumulator for each pool.
    ///
    /// @dev Replaces the former `lastTickBefore` / `lastTickAfter` diagnostic globals, which only
    ///      remembered the most recent swap and were overwritten by the next one. The accumulator
    ///      carries strictly more information: `lastTick` is the currently effective tick, and
    ///      `tickCumulative` integrates tick over blocks so any two readings give a time-weighted
    ///      average. Settlement reads this, so it is real protocol state rather than debug output.
    ///
    ///      MUST be advanced on EVERY swap, bonded or not, and seeded at pool initialization.
    ///      `TickAccumulatorLib` requires this for accuracy — a gap biases every observation window
    ///      spanning it. ADR-0003 § 3.2 additionally makes it a CORRECTNESS precondition: the
    ///      bounded maturity scan proves `work <= W` only because a bond cannot open without a swap,
    ///      and a swap cannot happen without advancing `lastUpdate`.
    mapping(PoolId => TickAccumulatorLib.Accumulator) public accumulator;

    /// @notice Maturity buckets, per pool, keyed by maturity block.
    /// @dev `uint32` key matches `Accumulator.lastUpdate`; a wider key would advertise a block
    ///      range the accumulator cannot represent. ADR-0003 § 6.3.
    mapping(PoolId => mapping(uint32 => MaturityCheckpoint)) public maturity;

    /// @notice Bond records, by bond id.
    ///
    /// @dev INTERNAL, not public, and that is a correctness requirement rather than a style
    ///      choice. An auto-generated public getter would expose `PROVISIONAL` records, which
    ///      ADR-0004 Rule 1 forbids: the supported read surface must report a provisional record
    ///      as absent. `getBond` / `bondExists` are that surface.
    mapping(bytes32 => Bond) internal bonds;

    /// @notice Pool references, by the compact index stored in each bond.
    mapping(uint32 => PoolRef) public poolRefByIndex;

    /// @notice Index assigned to a pool at initialization. Zero means "not initialized here".
    /// @dev Indices start at 1 so zero stays an unambiguous sentinel.
    mapping(PoolId => uint32) public poolIndexOf;

    /// @notice Number of pools initialized through this hook. Also the last assigned index.
    uint32 public poolCount;

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

    /// @notice Emitted when a bond record is created and its maturity registered.
    /// @param bondId Deterministic identifier of the new bond.
    /// @param id Pool the bond belongs to.
    /// @param refundRecipient Address the refund is owed to.
    /// @param amount Collateral held, in raw input-currency units.
    /// @param maturityBlock Block at which the bond's observation window closes.
    event BondOpened(
        bytes32 indexed bondId, PoolId indexed id, address indexed refundRecipient, uint128 amount, uint32 maturityBlock
    );

    /// @notice Emitted when a maturity bucket's cumulative is permanently frozen.
    /// @param id Pool the checkpoint belongs to.
    /// @param maturityBlock Block the cumulative was captured at.
    /// @param cumulative Tick accumulator value exactly at that block.
    event MaturityCheckpointed(PoolId indexed id, uint32 indexed maturityBlock, int56 cumulative);

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

    /// @notice Thrown when a bond id does not identify a finalized bond.
    /// @dev A `PROVISIONAL` record is reported as absent, not as "pending" — ADR-0004 Rule 1.
    error BondNotFound(bytes32 bondId);

    /// @notice Thrown when a bond is opened against a pool this hook never initialized.
    /// @dev Every pool using this hook passes through `_afterInitialize`, so this is unreachable
    ///      in practice. It exists because a bond whose `poolIndex` is zero would be unsettleable:
    ///      `poolRefByIndex[0]` is empty, so T5B could not recover the pool or the currency.
    error PoolNotRegistered();

    /// @notice Thrown when a block number does not fit the accumulator's `uint32` width.
    /// @dev Inherited from `TickAccumulatorLib`, which stores `lastUpdate` as `uint32`. Checked
    ///      rather than silently truncated: a wrapped block number would produce a maturity in the
    ///      past and a bond that can never settle correctly.
    error BlockNumberOutOfRange(uint256 blockNumber);

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

    /// @notice Seeds the pool's tick accumulator at the pool's real starting tick.
    ///
    /// @dev ADR-0003 § 3.2 requires initialization to seed the accumulator so `lastUpdate` is
    ///      well-defined from the pool's first block. Without it the accumulator would sit at the
    ///      `lastUpdate == 0` first-touch sentinel and the scan bound would have no base case.
    ///
    ///      Seeding uses the REAL initialization tick, never Solidity's default `0`. A pool
    ///      initialized at tick 190,000 must start integrating from 190,000; starting from 0 would
    ///      corrupt every observation window until the first swap corrected it.
    ///
    ///      `update` credits no elapsed time on first touch, so no history is invented for blocks
    ///      before the pool existed.
    ///
    ///      This runs once per pool and is off the swap path.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        afterInitializeCount++;

        PoolId id = key.toId();

        // Register the pool so bonds can reference it by a 4-byte index instead of a 32-byte
        // PoolId plus a 20-byte currency. Indices start at 1 so zero stays a sentinel. This is a
        // one-off cost at pool creation, deliberately traded against per-swap record size.
        if (poolIndexOf[id] == 0) {
            uint32 index = ++poolCount;

            poolIndexOf[id] = index;
            poolRefByIndex[index] = PoolRef({id: id, currency0: key.currency0, currency1: key.currency1});
        }

        // slither-disable-next-line unused-return
        accumulator[id].update(tick);

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

        // Advance the accumulator to the current block, UNCONDITIONALLY and before any
        // configuration branch. Every swap must advance it — see the `accumulator` docs and
        // ADR-0003 § 3.2. An early return that skipped this would break both the accuracy of every
        // spanning observation window and the maturity scan bound.
        //
        // Scoped so these locals do not stay live across the bonded-custody code below, which is
        // already at the EVM stack limit.
        {
            // Only the current tick is needed, and only to seed an unseeded accumulator.
            // slither-disable-next-line unused-return
            (, int24 tick,,) = poolManager.getSlot0(id);

            // Freeze every crossed maturity checkpoint, THEN advance the accumulator — both
            // before the pool moves the tick. Order is the whole correctness argument: after the
            // swap the cumulative at a crossed maturity is unrecoverable.
            _advanceAndCheckpoint(id, tick);
        }

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
            // Validate hookData before the pool executes, then write the PROVISIONAL record
            // header from everything already knowable. ADR-0004 § 3.
            //
            // This pays the record's two cold SSTOREs in the callback with ~140,000 of spare
            // budget, leaving `_afterSwap` — which must also perform the token transfer — a single
            // warm update. It takes NO custody, changes NO delta, and does NOT touch
            // `pendingBonds`; until finalization the record is invisible to every protocol path.
            // slither-disable-next-line unused-return
            (address refundRecipient,) = HookDataCodec.decode(hookData);

            TickAccumulatorLib.Accumulator storage acc = accumulator[id];

            // slither-disable-next-line unused-return
            _openProvisionalBond(id, params.zeroForOne, refundRecipient, acc.lastTick, acc.tickCumulative);

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

        // Read the pre-swap observation BEFORE moving the accumulator forward.
        //
        //   `lastTick`       — `_beforeSwap` advanced time but left the tick alone, so this is
        //                      still the tick from before this swap: tickBefore.
        //   `tickCumulative` — already advanced to this block, so it is the window's opening
        //                      reading for any bond created here.
        //
        // Both are captured here because `accumulator[id].update` below overwrites the tick.
        int24 tickBefore = accumulator[id].lastTick;
        int56 cumulativeAtOpen = accumulator[id].tickCumulative;

        int24 tickAfter;
        {
            // slither-disable-next-line unused-return
            (, int24 tick,,) = poolManager.getSlot0(id);

            tickAfter = tick;

            // Store the new effective tick. `_beforeSwap` already advanced `lastUpdate` to this
            // block, so elapsed is zero here: nothing is credited and only the tick changes. That
            // is what stops the swap's own price impact from being applied backwards over time it
            // had not yet occurred. ADR-0003 § 13.1.
            // slither-disable-next-line unused-return
            accumulator[id].update(tick);
        }

        // Exact-input: custody already happened in `_beforeSwap`, but the RECORD is created here,
        // where `tickAfter` is finally known. The bond amount is recomputed deterministically from
        // the same inputs `_beforeSwap` used rather than carried across in temporary storage.
        if (params.amountSpecified < 0) {
            _recordExactInputBond(id, params, hookData, tickBefore, tickAfter, cumulativeAtOpen);

            return (BaseHook.afterSwap.selector, int128(0));
        }

        // Resolve the direction-dependent values here so the custody helper stays inside the EVM
        // stack limit. For exact-output the bond is taken in the INPUT currency (ADR-0002 § 4).
        return (
            BaseHook.afterSwap.selector,
            _takeExactOutputBond(
                id,
                params.zeroForOne ? key.currency0 : key.currency1,
                params.zeroForOne,
                int256(params.zeroForOne ? delta.amount0() : delta.amount1()),
                hookData,
                Observation({tickBefore: tickBefore, tickAfter: tickAfter, cumulativeAtOpen: cumulativeAtOpen})
            )
        );
    }

    /// @notice Computes and takes the exact-output bond, returning the delta to report to v4.
    ///
    /// @dev Split out of `_afterSwap` purely to stay under the EVM stack limit; the logic and the
    ///      delta behaviour are unchanged from T3B/T3C. Returns `0` when the swap is not bonded.
    ///
    /// @return bondDelta Collateral actually taken, as the unspecified-currency delta. For
    ///         exact-output the unspecified currency IS the input currency in both directions
    ///         (`Hooks.sol:307`), so a positive value makes the trader owe that much more input.
    /// @param id Pool the swap ran against.
    /// @param inputCurrency Currency the trader is spending; the bond is taken in it.
    /// @param zeroForOne Swap direction, used to pick the per-currency bonding threshold.
    /// @param inputDelta Raw pool input delta for the input currency, negative when the trader owes
    ///        the pool. Does NOT include the bond.
    /// @param hookData The trader's versioned payload, re-decoded rather than carried in storage.
    /// @param obs Pre-swap observation captured before the accumulator was moved forward.
    function _takeExactOutputBond(
        PoolId id,
        Currency inputCurrency,
        bool zeroForOne,
        int256 inputDelta,
        bytes calldata hookData,
        Observation memory obs
    ) private returns (int128 bondDelta) {
        PoolConfig memory cfg = poolConfig[id];

        // Bonding disabled for this pool: `_beforeSwap` wrote no provisional record either, so
        // there is nothing to finalize and nothing to clear.
        if (cfg.bondBps == 0) {
            return int128(0);
        }

        // The provisional record `_beforeSwap` placed. Recomputed, not carried: `pendingBonds` is
        // incremented only at finalization and one swap's callbacks never interleave with
        // another's, so both derivations see the same bucket count.
        // Scoped so `maturityBlock` does not stay live across the custody code below, which is
        // already at the EVM stack limit.
        bytes32 bondId;
        {
            uint32 maturityBlock = _maturityOf(_blockNumber32());

            bondId = _bondId(id, maturityBlock, maturity[id][maturityBlock].pendingBonds);
        }

        // No positive input was consumed, so there is nothing to bond.
        if (inputDelta >= 0) {
            _clearProvisionalBond(bondId);

            return int128(0);
        }

        uint256 poolInput = uint256(-inputDelta);

        // Exact-output `bondBps` still represents a percentage of GROSS input:
        //
        //     grossInput = poolInput + bond
        //     bond       = poolInput * bondBps / (10_000 - bondBps)
        uint256 candidateBond = FullMath.mulDiv(poolInput, cfg.bondBps, BPS - uint256(cfg.bondBps));

        // Threshold is compared against GROSS input, using this direction's input currency.
        // Below it the swap is unbonded: discard the provisional record so nothing is left behind.
        if (poolInput + candidateBond < (zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1)) {
            _clearProvisionalBond(bondId);

            return int128(0);
        }

        // A bonded swap must never continue with zero collateral.
        if (candidateBond == 0) {
            revert BondRoundsToZero(poolInput);
        }

        // Scoped to stay within the EVM stack limit. The decode is re-done here rather than
        // carried from `_beforeSwap` in temporary storage; validity is not at stake because
        // `_beforeSwap` already rejected malformed exact-output hookData before the pool ran, so
        // this decode only retrieves the two values.
        {
            (address refundRecipient, uint128 maxBondAmount) = HookDataCodec.decode(hookData);

            // Trader-provided limit on the bond itself.
            if (candidateBond > maxBondAmount) {
                revert BondExceedsTraderMax(candidateBond, maxBondAmount);
            }

            emit BondTaken(id, refundRecipient, inputCurrency, candidateBond, poolInput + candidateBond);
        }

        // Finalize the record `_beforeSwap` placed: a WARM update to slot 1, which already holds
        // `cumulativeAtOpen` and `tickBefore`. This is also where the maturity is registered.
        _finalizeBond(id, bondId, uint128(candidateBond), obs.tickAfter);

        inputCurrency.take(poolManager, address(this), candidateBond, false);

        return candidateBond.toInt128();
    }

    /*//////////////////////////////////////////////////////////////
                        MATURITY CHECKPOINT ADVANCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Freezes every crossed maturity checkpoint, then advances the accumulator to now.
    ///
    /// @dev THE STAGE 3 CORE. Called from `_beforeSwap`, before the swap moves the tick, on EVERY
    ///      swap regardless of configuration.
    ///
    ///      WHY ORDER MATTERS. A checkpoint records the cumulative EXACTLY at a maturity block `M`.
    ///      That value is computable only while the accumulator still sits at `lastUpdate <= M`
    ///      with the tick that was live across the interval. Once a swap moves the tick, the value
    ///      at `M` is gone — no history is kept and none can be reconstructed. So freezing happens
    ///      first, advancement second, and the swap third.
    ///
    ///      THE BOUNDED DOMAIN. With `L = lastUpdate` and `C = block.number`, only
    ///
    ///          (L, min(C, L + W)]
    ///
    ///      can contain an uncheckpointed matured bucket. ADR-0003 section 3.4 proves both ends:
    ///      nothing at or below `L` is still unfrozen, because the advancement that reached `L`
    ///      froze what it crossed; and nothing above `L + W` can exist yet, because opening a bond
    ///      requires a swap, a swap advances `lastUpdate`, and maturity is `openBlock + W` at most.
    ///
    ///      THE CLAMP IS WHAT KEEPS THIS BOUNDED. When a pool has been quiet for a month,
    ///      `C - L` is enormous but the loop still runs at most `W` times. A long gap does NOT
    ///      license skipping the scan: a bond opened at or before `L` may mature anywhere inside
    ///      `(L, L + W]`, and its checkpoint must be frozen before this swap changes the price.
    ///
    ///      OCCUPANCY. `pendingBonds[M] > 0` is the ONLY occupancy signal, per ADR-0004 Rule 3.
    ///      Because that counter holds finalized bonds only, provisional exact-output records are
    ///      structurally invisible here — they cannot create checkpoint work, cannot make a bucket
    ///      look occupied, and cannot cause a freeze. That is ADR-0004 Rule 1, satisfied by
    ///      construction rather than by an extra check.
    ///
    ///      Empty buckets are skipped without freezing: with no bond depending on `M` there is
    ///      nothing to settle against it.
    ///
    /// @param id Pool being advanced.
    /// @param currentTick Pool tick read this block, used only to seed an unseeded accumulator.
    function _advanceAndCheckpoint(PoolId id, int24 currentTick) private {
        TickAccumulatorLib.Accumulator storage acc = accumulator[id];

        uint32 lastUpdate = acc.lastUpdate;

        // First touch: nothing has elapsed and no maturity can exist yet.
        if (lastUpdate == 0) {
            // slither-disable-next-line unused-return
            acc.update(currentTick);

            return;
        }

        uint32 nowBlock = _blockNumber32();

        // Freeze before advancing. Skipped entirely when no block has elapsed, which is the
        // common case of a second swap in the same block.
        if (nowBlock > lastUpdate) {
            // The clamp. `scanEnd` never exceeds `lastUpdate + W`, so the loop below runs at most
            // W times however long the pool was quiet.
            uint32 horizon = lastUpdate + MAX_OBSERVATION_BLOCKS;
            uint32 scanEnd = nowBlock < horizon ? nowBlock : horizon;

            // Read once into memory: the loop must not re-read storage per candidate block.
            TickAccumulatorLib.Accumulator memory snapshot = acc;

            for (uint32 m = lastUpdate + 1; m <= scanEnd; m++) {
                MaturityCheckpoint storage bucket = maturity[id][m];

                // Unoccupied, or already frozen by an earlier advancement. Either way, nothing to
                // do. `checkpointed` is the sole authority on whether the checkpoint exists, and a
                // frozen one is never rewritten.
                if (bucket.pendingBonds == 0 || bucket.checkpointed) continue;

                // The cumulative exactly at `m`, from PRE-ADVANCE state. Valid because the tick
                // cannot have changed inside `(lastUpdate, nowBlock)` — a change needs a swap, and
                // a swap would have moved `lastUpdate`.
                int56 cumulative = snapshot.cumulativeAt(m);

                bucket.cumulative = cumulative;
                bucket.checkpointed = true;

                emit MaturityCheckpointed(id, m, cumulative);
            }
        }

        // Now advance. Credits the elapsed interval at the tick that was live across it and leaves
        // the effective tick unchanged; `_afterSwap` sets the new tick with zero elapsed blocks.
        // slither-disable-next-line unused-return
        acc.update(acc.lastTick);
    }

    /*//////////////////////////////////////////////////////////////
                          BOND RECORDS & MATURITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Current block, narrowed to the accumulator's `uint32` width.
    /// @dev Reverts rather than truncating. A wrapped block number would place maturity in the
    ///      past and produce a bond that can never settle correctly.
    function _blockNumber32() private view returns (uint32) {
        if (block.number > type(uint32).max) revert BlockNumberOutOfRange(block.number);

        return uint32(block.number);
    }

    /// @notice Maturity for a bond opening at `openBlock`. Fixed at open, never recomputed.
    /// @dev `uint32` arithmetic is safe here because `_blockNumber32` bounds `openBlock` and
    ///      `OBSERVATION_BLOCKS` is a small compile-time constant; the sum is widened first.
    function _maturityOf(uint32 openBlock) private pure returns (uint32) {
        uint256 m = uint256(openBlock) + uint256(OBSERVATION_BLOCKS);

        if (m > type(uint32).max) revert BlockNumberOutOfRange(m);

        return uint32(m);
    }

    /// @notice Deterministic bond id for a pool, maturity and position within that bucket.
    ///
    /// @dev `indexInBucket` is the bucket's `pendingBonds` value BEFORE this bond increments it.
    ///      That counter is already written for registration, so the id costs no extra storage.
    ///      Collision-free by construction: within one pool and maturity the index strictly
    ///      increases, and a differing pool or maturity changes the preimage. It therefore
    ///      distinguishes bonds sharing a block, a recipient, a direction and a swap kind.
    ///
    ///      SPLIT-PHASE ORDERING. Under ADR-0004 the exact-output id is computed twice — once in
    ///      `_beforeSwap` to place the provisional record and again in `_afterSwap` to find it.
    ///      Both reads see the same `pendingBonds` because it is incremented only at finalization
    ///      and the callbacks of one swap never interleave with another swap's.
    function _bondId(PoolId id, uint32 maturityBlock, uint32 indexInBucket) private pure returns (bytes32) {
        return keccak256(abi.encode(id, maturityBlock, indexInBucket));
    }

    /// @notice Writes the provisional header for an exact-output bond, in `_beforeSwap`.
    ///
    /// @dev ADR-0004 § 3. Everything knowable before the pool executes is written here — which is
    ///      everything except `amount` and `tickAfter`, and both of those live in slot 1. So this
    ///      pays the two cold SSTOREs in the callback that has ~140,000 of spare budget, and
    ///      leaves `_afterSwap` a single warm update.
    ///
    ///      This record is NOT a bond. Until `_finalizeBond` runs it is invisible to every
    ///      protocol path: `pendingBonds` is untouched, `getBond` reports it absent, and no claim,
    ///      refund right, slash liability or maturity obligation exists. ADR-0004 Rule 1.
    ///
    ///      If the transaction reverts for any reason, this write reverts with it.
    ///
    /// @param id Pool the swap is running against.
    /// @param inputIsCurrency0 Whether the input currency is the pool's currency0.
    /// @param refundRecipient Refund owner from already-validated hookData.
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param cumulativeAtOpen Accumulator value at the open block.
    /// @return bondId Identifier the finalize or clear step will use.
    function _openProvisionalBond(
        PoolId id,
        bool inputIsCurrency0,
        address refundRecipient,
        int24 tickBefore,
        int56 cumulativeAtOpen
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
            amount: 0,
            cumulativeAtOpen: cumulativeAtOpen,
            tickBefore: tickBefore,
            tickAfter: 0,
            inputIsCurrency0: inputIsCurrency0,
            state: BondState.PROVISIONAL
        });
    }

    /// @notice Turns a provisional record into a real bond, in `_afterSwap`.
    ///
    /// @dev The `PROVISIONAL -> FINALIZED` transition is a WARM non-zero -> non-zero update to
    ///      slot 1, which `_openProvisionalBond` already touched. It must never insert the bond
    ///      into a separate finalized mapping or index — that would be another cold SSTORE and
    ///      would defeat the entire purpose. ADR-0004 Rule 2.
    ///
    ///      Registration happens HERE and only here: `pendingBonds` counts finalized bonds
    ///      unconditionally, at every point in time. ADR-0004 Rule 3. Registration touches the
    ///      counter and nothing else — never the cumulative, never `checkpointed`.
    ///
    /// @param id Pool the bond belongs to.
    /// @param bondId Identifier returned by `_openProvisionalBond`.
    /// @param amount Collateral actually taken, raw input-currency units.
    /// @param tickAfter Pool tick immediately after the swap.
    function _finalizeBond(PoolId id, bytes32 bondId, uint128 amount, int24 tickAfter) private {
        Bond storage bond = bonds[bondId];

        bond.amount = amount;
        bond.tickAfter = tickAfter;
        bond.state = BondState.FINALIZED;

        uint32 maturityBlock = bond.maturityBlock;

        // Registration. Only now does a maturity obligation exist.
        maturity[id][maturityBlock].pendingBonds += 1;

        emit BondOpened(bondId, id, bond.refundRecipient, amount, maturityBlock);
    }

    /// @notice Discards a provisional record when the exact-output swap turns out unbonded.
    ///
    /// @dev Leaves nothing behind: both slots return to zero, so the entry reads as `NONE` — the
    ///      same state as "never existed". `pendingBonds` was never touched, so there is nothing
    ///      to roll back and no phantom count can exist. ADR-0004 Rule 1 and § 5.
    ///
    ///      Both slots were written from zero earlier in THIS transaction, so clearing them is
    ///      eligible for the same-transaction reset refund rather than EIP-3529's 4,800 clear.
    ///      The realised saving is capped at 20% of transaction gas and is therefore measured
    ///      end-to-end rather than estimated. ADR-0004 § 7.
    function _clearProvisionalBond(bytes32 bondId) private {
        delete bonds[bondId];
    }

    /// @notice Creates a complete bond record in one step and registers its maturity.
    ///
    /// @dev The EXACT-INPUT path, unchanged in shape from T5.1. Exact-input custody already
    ///      happens in `_beforeSwap`, so that callback is the expensive one on this path
    ///      (~43,000) while its `_afterSwap` has ample room. Splitting it would load the busier
    ///      callback to relieve the quieter one — backwards. The asymmetry with exact-output is
    ///      deliberate and load-bearing. ADR-0004 § 6.
    function _openBond(
        PoolId id,
        bool inputIsCurrency0,
        uint128 amount,
        address refundRecipient,
        int24 tickBefore,
        int24 tickAfter,
        int56 cumulativeAtOpen
    ) private returns (bytes32 bondId) {
        uint32 poolIndex = poolIndexOf[id];

        if (poolIndex == 0) revert PoolNotRegistered();

        uint32 openBlock = _blockNumber32();
        uint32 maturityBlock = _maturityOf(openBlock);

        MaturityCheckpoint storage bucket = maturity[id][maturityBlock];

        uint32 indexInBucket = bucket.pendingBonds;

        bondId = _bondId(id, maturityBlock, indexInBucket);

        bonds[bondId] = Bond({
            refundRecipient: refundRecipient,
            openBlock: openBlock,
            maturityBlock: maturityBlock,
            poolIndex: poolIndex,
            amount: amount,
            cumulativeAtOpen: cumulativeAtOpen,
            tickBefore: tickBefore,
            tickAfter: tickAfter,
            inputIsCurrency0: inputIsCurrency0,
            state: BondState.FINALIZED
        });

        bucket.pendingBonds = indexInBucket + 1;

        emit BondOpened(bondId, id, refundRecipient, amount, maturityBlock);
    }

    /*//////////////////////////////////////////////////////////////
                              BOND READ API
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a finalized bond.
    ///
    /// @dev THE SUPPORTED READ SURFACE. A `PROVISIONAL` record is reported as absent — it reverts
    ///      `BondNotFound`, exactly as a never-existent id does. ADR-0004 Rule 1 requires that no
    ///      protocol path or view treats a provisional record as a bond, so this must not return
    ///      it and must not distinguish it from "no such bond".
    ///
    ///      Raw storage inspection is outside that guarantee: a trace or `eth_getStorageAt` during
    ///      the transaction will see the provisional bytes. The guarantee is semantic.
    function getBond(bytes32 bondId) external view returns (Bond memory bond) {
        bond = bonds[bondId];

        if (bond.state != BondState.FINALIZED) revert BondNotFound(bondId);
    }

    /// @notice Whether a bond id identifies a finalized bond.
    /// @dev False for both `NONE` and `PROVISIONAL`, which are indistinguishable to callers.
    function bondExists(bytes32 bondId) external view returns (bool) {
        // Strict equality is correct and intended here. Slither's `incorrect-equality` detector
        // targets `==` on balances and timestamps, where a value can be skipped past. `state` is a
        // three-valued enum and the question is exactly "is it FINALIZED" — an ordered comparison
        // would silently accept any future state added above it.
        // slither-disable-next-line incorrect-equality
        return bonds[bondId].state == BondState.FINALIZED;
    }

    /// @notice Recreates the exact-input bond's deterministic parameters and records it.
    ///
    /// @dev Called from `_afterSwap`. Custody already happened in `_beforeSwap`; this only writes
    ///      the record, now that `tickAfter` is known. The bond amount is recomputed from exactly
    ///      the same inputs `_beforeSwap` used — `grossInput`, `bondBps` and the direction's
    ///      threshold — rather than being carried across in temporary storage. Both callbacks run
    ///      in one transaction against unchanged configuration, so the two computations agree.
    ///
    ///      Returns silently for unbonded swaps: no custody was taken, so there is nothing to
    ///      record.
    function _recordExactInputBond(
        PoolId id,
        SwapParams calldata params,
        bytes calldata hookData,
        int24 tickBefore,
        int24 tickAfter,
        int56 cumulativeAtOpen
    ) private {
        PoolConfig memory cfg = poolConfig[id];

        if (cfg.bondBps == 0) return;

        uint256 grossInput = uint256(-params.amountSpecified);

        if (grossInput < (params.zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1)) return;

        // Same expression as `_beforeSwap`, over the same unchanged inputs.
        uint256 bond = (grossInput * cfg.bondBps) / BPS;

        // Only the recipient is needed here; `maxBondAmount` was already enforced in
        // `_beforeSwap` before custody was taken.
        // slither-disable-next-line unused-return
        (address refundRecipient,) = HookDataCodec.decode(hookData);

        // slither-disable-next-line unused-return
        _openBond(id, params.zeroForOne, uint128(bond), refundRecipient, tickBefore, tickAfter, cumulativeAtOpen);
    }
}
