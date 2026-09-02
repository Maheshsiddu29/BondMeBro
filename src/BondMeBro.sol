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
import {PersistenceMathLib} from "./libraries/PersistenceMathLib.sol";
import {TickAccumulatorLib} from "./libraries/TickAccumulatorLib.sol";

// below constant is important for the hook to work properly. It is the permission bits that the hook's deployed address must encode. It is a single source of truth shared with getHookPermissions() and the test suite.getHookPermissions(), test suite, and the deploy script's miner all three derive from this one constant.

// BEFORE_SWAP_RETURNS_DELTA_FLAG is deliberately ABSENT (ADR-0006 section 4).
//
// Under variable-leg custody `beforeSwap` returns `ZERO_DELTA` on every path for both swap kinds,
// so the permission is unused. Dropping it removes the hook's ABILITY to return a
// specified-currency delta at all: Uniswap rates `beforeSwapReturnDelta` CRITICAL because it is
// the NoOp rug vector, and the legacy INV-NOOP existed to bound it. Removing the bit makes that
// vector unreachable by construction rather than bounded by an invariant, which is strictly
// stronger.
//
// The flags are encoded in the hook ADDRESS, so this value changing means every mined address
// changes: 0x10CC -> 0x10C4. `test/HookWiring.t.sol` pins the numeric value on purpose.
uint160 constant HOOK_FLAGS = uint160(
    Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
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
    /// @dev PUBLIC, because under variable-leg custody it is part of the information a caller
    ///      needs before it can size `maxBondAmount`. The collateral is
    ///      `variableLeg * collateralBps / BPS`, so a caller that can read `collateralBpsFor` but
    ///      not the denominator can still only guess. Exposing it costs no storage and no gas: it
    ///      is a compile-time constant.
    uint256 public constant BPS = 10_000;

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
    /// @notice Largest batch `settleMany` will accept.
    ///
    /// @dev Bounds the only loop in the settlement path. Chosen from measurement, not preference:
    ///      a single settlement costs roughly 60-80k depending on path, so 32 entries land near
    ///      2.2M — comfortably inside a 30M block while leaving room for the caller's own
    ///      overhead. Larger batches buy little: the per-entry cost is dominated by the ERC-20
    ///      transfer and two cold SSTOREs, neither of which amortises across a batch.
    ///
    ///      A cap is required rather than merely advisable. Without one a caller could submit an
    ///      array long enough to exceed the block limit, and the revert would be an out-of-gas
    ///      rather than a diagnosable error.
    uint256 public constant MAX_SETTLE_BATCH = 32;

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

    /*              MODEL L2 COLLATERAL SIZING (ADR-0005)            /*/

    /// @notice Collateral rate, in bps of the variable leg per tick of REALIZED impact, carried as
    ///         an integer numerator over 100 so every operation stays integral.
    ///
    /// @dev 25 == 0.25 bps/tick, the V7.1 selected value, FROZEN by ADR-0005 section 2.1. It is a
    ///      calibration choice made against a synthetic population, not a historically validated
    ///      optimum — see ADR-0005 section 6.4 before changing it, and open a new ADR.
    uint16 public constant COLLATERAL_SCALE = 25;

    /// @notice Realized impact at which the `MAX_BOND_BPS` cap first binds.
    /// @dev `ceil(397 * 25 / 100) == 100`, and `ceil(396 * 25 / 100) == 99`. Stated as a constant
    ///      so the boundary is pinned by name rather than rediscovered.
    uint32 public constant CAP_ACTIVATION_TICKS = 397;

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

    /// @param refundToleranceTicks Noise floor for settlement, in TICKS. Price displacement at or
    ///        below this is never slashed. Passed to `PersistenceMathLib.computeBps`, which
    ///        subtracts it from both sides of the persistence fraction so the curve rises smoothly
    ///        from zero rather than stepping — a discontinuity there would be a boundary an
    ///        attacker could profitably sit on. Widened to `uint24` at the call site to match the
    ///        frozen library's parameter type.
    ///
    ///        `uint16` keeps `PoolConfig` at exactly 128 + 96 + 16 + 16 = 256 bits, ONE slot. That
    ///        matters: the swap path already reads this struct, and a second slot would add a cold
    ///        SLOAD to every swap. Verified with `forge inspect BondMeBro storage-layout`.
    struct PoolConfig {
        uint128 minBondedAmount0;
        uint96 minBondedAmount1;
        uint16 bondBps;
        uint16 refundToleranceTicks;
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
    /// @param variableLegAmount The realized VARIABLE leg of the swap, in raw units of the
    ///        collateral currency: the actual output for exact-input, the actual pool input for
    ///        exact-output. NOT the collateral held.
    ///
    ///        WHY THE LEG AND NOT THE COLLATERAL (ADR-0005 section 3.2). The collateral is a pure
    ///        function of fields this record already holds --
    ///        `variableLegAmount * collateralBps / BPS`, with `collateralBps` derived from
    ///        `tickBefore`/`tickAfter` -- so storing the leg costs nothing extra and keeps the
    ///        leg available to settlement. Storing the collateral instead loses the leg, and the
    ///        only slash form that preserves INV-L2-4 exactly in integer arithmetic needs it: the
    ///        ratio form `collateral * slashBps / collateralBps` was measured to lose one wei as
    ///        the opening impact rises, over 606,000,000 combinations.
    ///
    ///        Use `collateralAmountOf` to read the collateral actually held.
    /// @param cumulativeAtOpen Tick accumulator value at `openBlock`; the window's start reading.
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @param collateralIsCurrency0 True when the COLLATERAL is the pool's currency0. Under
    ///        variable-leg custody this is decided by the swap KIND as well as the direction, so
    ///        it must be read from the record and never re-derived from direction alone
    ///        (INV-L2-10).
    /// @param state Lifecycle marker. `NONE` / `PROVISIONAL` / `FINALIZED` — see `BondState`.
    ///        Packed into slot 1 deliberately: slot 1 is the slot `_afterSwap` must write anyway
    ///        to record `amount` and `tickAfter`, so finalization is a WARM update to an
    ///        already-touched slot rather than a second cold write. ADR-0004 Rule 2.
    struct Bond {
        address refundRecipient;
        uint32 openBlock;
        uint32 maturityBlock;
        uint32 poolIndex;
        uint128 variableLegAmount;
        int56 cumulativeAtOpen;
        int24 tickBefore;
        int24 tickAfter;
        bool collateralIsCurrency0;
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
        FINALIZED,
        SETTLED
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

    /// @notice Slashed collateral held by the hook, per pool and per currency, in raw units.
    ///
    /// @dev ACCOUNTING ONLY — slashing moves no tokens. The collateral is already inside the hook
    ///      from the moment it was taken; settlement merely reclassifies it from "owed back to a
    ///      trader" to "retained as LP-risk compensation". So a slash decreases unsettled bond
    ///      liability and increases this, and the hook's physical balance does not change.
    ///
    ///      T5B deliberately provides NO withdrawal path. Nothing — not the owner, not an LP, not
    ///      a settler — can remove pot funds. Distribution policy is a later task, and shipping a
    ///      withdrawal before that policy exists would be the easiest way to get it wrong.
    mapping(PoolId => mapping(Currency => uint256)) public insurancePot;

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
    event PoolConfigured(
        PoolId indexed id,
        uint128 minBondedAmount0,
        uint96 minBondedAmount1,
        uint16 bondBps,
        uint16 refundToleranceTicks
    );

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
    error IncompletePoolConfig(
        uint128 minBondedAmount0, uint96 minBondedAmount1, uint16 bondBps, uint16 refundToleranceTicks
    );

    /// @notice INV-NOOP-VL. Thrown when the collateral would not sit strictly inside the swap's
    ///         variable leg.
    ///
    /// @dev THE REPLACEMENT FOR INV-NOOP, AND THE HOOK'S OWN RESPONSIBILITY.
    ///
    ///      `Hooks.sol` bounds `hookDeltaSpecified` at line 277, inside `beforeSwap`. It bounds
    ///      `hookDeltaUnspecified` NOWHERE: it is read at 296, accumulated at 299 and applied at
    ///      306-312 without any check. A hook returning an `afterSwap` delta equal to the entire
    ///      variable leg passes everything v4 does. `V4Router` happens to revert on the resulting
    ///      negative cast, but a direct `PoolManager.unlock` caller gets no such help, so this
    ///      bound can never be delegated.
    ///
    ///      The lower bound is not decoration either. `bond = leg * bps / BPS` floors, so a leg
    ///      below `BPS / bps` rounds the collateral away entirely; recording a zero-amount bond
    ///      would create a maturity obligation with nothing behind it.
    ///
    /// @param bond Collateral the hook would have taken.
    /// @param variableLegAmount Realized variable leg it had to sit strictly inside.
    error BondViolatesNoOpVLBound(uint256 bond, uint256 variableLegAmount);

    /// TWO ERRORS WERE REMOVED HERE BY P-L2-3/4, and their removal is recorded rather than silent
    /// because both were part of this contract's ABI.
    ///
    ///   `BondViolatesNoOpBound(uint256 bond, uint256 grossInput)` -- the exact-input INV-NOOP
    ///       bound. Superseded by `BondViolatesNoOpVLBound` above: the quantity the collateral
    ///       must sit inside is now the variable leg, not the gross input, and under a single
    ///       unified custody path there is no longer a separate exact-input rule to violate.
    ///
    ///   `BondRoundsToZero(uint256 poolInput)` -- the exact-output zero-bond guard. Its condition
    ///       is now the LOWER half of `BondViolatesNoOpVLBound`, which covers both swap kinds and
    ///       reports the leg alongside the bond instead of the pool input alone.
    ///
    /// Neither was reachable after the unified lifecycle landed: the code paths that raised them
    /// were `_takeExactOutputBond`, `_recordExactInputBond` and `_openBond`, all deleted in this
    /// stage. Leaving unreachable errors declared would advertise failure modes this contract can
    /// no longer produce, and integrators decode by selector.

    /// @notice Thrown when the calculated bond is larger than the trader allowed.
    /// @dev `maxBondAmount` protects the trader if pool configuration changes between
    ///      quote time and execution time.
    error BondExceedsTraderMax(uint256 bond, uint128 maxBondAmount);

    /// @notice Emitted when a bond is settled.
    /// @param bondId Bond that was settled.
    /// @param id Pool the bond belonged to.
    /// @param refundRecipient Address the refund was sent to, bound at open.
    /// @param currency Currency the collateral was held in.
    /// @param collateral Original collateral, in raw units.
    /// @param refund Portion returned to the recipient.
    /// @param slash Portion retained in the pool's insurance pot.
    /// @param persistenceBps Fraction of the original displacement that survived, in bps.
    event BondSettled(
        bytes32 indexed bondId,
        PoolId indexed id,
        address indexed refundRecipient,
        Currency currency,
        uint128 collateral,
        uint128 refund,
        uint128 slash,
        uint16 persistenceBps
    );

    /// @notice Thrown when settlement is attempted before the bond's maturity block.
    error BondNotMature(bytes32 bondId, uint32 maturityBlock, uint256 currentBlock);

    /// @notice Thrown when settling a bond that is not FINALIZED.
    /// @dev Covers NONE, PROVISIONAL and SETTLED alike. A PROVISIONAL bond reports as absent to
    ///      every supported path, so it must not be settleable — ADR-0004 Rule 1.
    error BondNotSettleable(bytes32 bondId, BondState state);

    /// @notice Thrown when a matured bond's maturity checkpoint is missing and unrecoverable.
    ///
    /// @dev AN INVARIANT VIOLATION, NOT A RECOVERABLE CONDITION. If the accumulator cursor has
    ///      already advanced past M without the checkpoint being frozen, the exact cumulative at M
    ///      is gone — no history is kept and none can be reconstructed. Settlement reverts rather
    ///      than approximating from live state, because an approximation would silently make the
    ///      outcome depend on when settlement was called, which is exactly what ADR-0003 § 1
    ///      forbids. Reaching this means NO-MISSED-MATURITY was violated upstream.
    error MaturityCheckpointMissing(bytes32 bondId, uint32 maturityBlock, uint32 lastUpdate);

    /// @notice Thrown when a settle batch exceeds `MAX_SETTLE_BATCH`.
    error SettleBatchTooLarge(uint256 length, uint256 cap);

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
            beforeSwapReturnDelta: false,
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
    function setPoolConfig(
        PoolKey calldata key,
        uint128 minBondedAmount0,
        uint96 minBondedAmount1,
        uint16 bondBps,
        uint16 refundToleranceTicks
    ) external onlyOwner {
        if (bondBps > MAX_BOND_BPS) {
            revert BondBpsAboveCap(bondBps, MAX_BOND_BPS);
        }

        // All zero disables bonding. Otherwise ALL FOUR values must be set.
        //
        // `refundToleranceTicks` joins the completeness rule rather than being optional: a zero
        // tolerance is a real and dangerous setting, not "unset". With no noise floor the
        // persistence curve slashes on any surviving displacement at all, including a single tick
        // of ordinary market drift, so a pool configured by omission would slash far more than
        // intended. Requiring it explicitly keeps the most punitive setting from being the easiest
        // typo — the same reasoning that made the two thresholds mandatory in T3C.
        bool anySet = minBondedAmount0 != 0 || minBondedAmount1 != 0 || bondBps != 0 || refundToleranceTicks != 0;

        bool allSet = minBondedAmount0 != 0 && minBondedAmount1 != 0 && bondBps != 0 && refundToleranceTicks != 0;

        if (anySet && !allSet) {
            revert IncompletePoolConfig(minBondedAmount0, minBondedAmount1, bondBps, refundToleranceTicks);
        }

        PoolId id = key.toId();

        poolConfig[id] = PoolConfig({
            minBondedAmount0: minBondedAmount0,
            minBondedAmount1: minBondedAmount1,
            bondBps: bondBps,
            refundToleranceTicks: refundToleranceTicks
        });

        emit PoolConfigured(id, minBondedAmount0, minBondedAmount1, bondBps, refundToleranceTicks);
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

        // ONE LIFECYCLE FOR BOTH SWAP KINDS, AND NO DELTA ON EITHER (ADR-0006 section 7).
        //
        // Collateral is sized from the REALIZED tick impact and taken from the REALIZED variable
        // leg, and neither exists until the pool has executed. So neither kind can be sized here.
        // ADR-0002 already reached that conclusion for exact-output, for a different reason; Model
        // L extends it to exact-input, and the response is to stop having two custody
        // architectures. `beforeSwap` now does what ADR-0004 already does for exact-output:
        //
        //   1. validate `hookData` BEFORE the pool executes, so bad data cannot execute a swap;
        //   2. write the provisional record header from everything already knowable;
        //   3. take NO custody and return ZERO delta.
        //
        // FINAL eligibility is deliberately NOT decided here -- `_afterSwap` decides it on the
        // input the pool ACTUALLY consumed, because a partially filled swap was not a big trade.

        // THE EXACT-INPUT PRE-FILTER, and it is a correctness requirement rather than an
        // optimisation (ADR-0006 section 7.1).
        //
        // `hookData` has to be validated before execution so invalid data reverts rather than
        // silently degrading to unbonded. If that validation ran on EVERY swap, every small
        // exact-input swap on a bonded pool would suddenly be required to carry `hookData`, which
        // today it is not -- a silent product break.
        //
        // For exact-input the filter is EXACT, not heuristic: the pool can never consume more than
        // the requested amount, so
        //
        //     requested < minBondedAmount  =>  actual < minBondedAmount  =>  unbonded
        //
        // and skipping is sound. For exact-output the input is unknowable here, so every bonded
        // pool's exact-output swap must carry `hookData` -- which is exactly today's behaviour.
        if (params.amountSpecified < 0) {
            uint256 requestedInput = uint256(-params.amountSpecified);

            if (requestedInput < (params.zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1)) {
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
        }

        // Invalid hookData must revert rather than silently falling back to unbonded.
        // slither-disable-next-line unused-return
        (address refundRecipient,) = HookDataCodec.decode(hookData);

        TickAccumulatorLib.Accumulator storage acc = accumulator[id];

        // The provisional header is now written for exact-INPUT too, which production did not do.
        // That moves two cold SSTOREs out of `_afterSwap` and into this callback -- deliberately,
        // because `_afterSwap` must also perform the token transfer and has the tighter ceiling.
        // ADR-0004 Rule 2's argument, applied to the path ADR-0004 section 6 left alone.
        //
        // The currency flag is written provisionally from the DIRECTION and corrected to the
        // collateral currency at finalization, where the swap kind is what decides it. A
        // provisional record is invisible to every protocol path (ADR-0004 Rule 1), so the
        // intermediate value is never observable.
        // slither-disable-next-line unused-return
        _openProvisionalBond(id, params.zeroForOne, refundRecipient, acc.lastTick, acc.tickCumulative);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
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

        // Read the pre-swap tick BEFORE moving the accumulator forward. `_beforeSwap` advanced
        // time but left the tick alone, so `lastTick` is still the tick from before this swap:
        // tickBefore. It must be captured here because `accumulator[id].update` below overwrites
        // it.
        //
        // The window's opening accumulator reading is NOT captured here any more. Under the
        // unified lifecycle it is written into the provisional record by `_beforeSwap`, which
        // reads it at the only moment it is unambiguously the pre-swap value. Re-reading it here
        // would be a second source of truth for the same number, and it would cost a stack slot
        // this frame does not have.
        int24 tickBefore = accumulator[id].lastTick;

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

        // ONE CUSTODY PATH. The swap kind selects the currency; nothing else differs.
        //
        //   exact-input  : specified = input  (fixed) -> variable leg is the OUTPUT
        //   exact-output : specified = output (fixed) -> variable leg is the INPUT
        //
        // Verified against installed `Hooks.sol:305-313` by enumerating the four cases of
        // `params.amountSpecified < 0 == params.zeroForOne`: the unspecified currency is the
        // variable leg in BOTH kinds. `Hooks.sol:298-303` adds this callback's return to
        // `hookDeltaUnspecified`, never to `hookDeltaSpecified`, and `PoolManager.sol:224-226`
        // credits the hook while subtracting from the caller. So a POSITIVE return here is always
        // a claim on the variable leg.
        return (
            BaseHook.afterSwap.selector,
            _takeVariableLegBond(id, hookData, _custodyContext(key, params, delta, tickBefore, tickAfter))
        );
    }

    /*//////////////////////////////////////////////////////////////
                        VARIABLE-LEG CUSTODY (ADR-0006)
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything the custody path needs, resolved once.
    ///
    /// @dev A memory struct rather than seven arguments, and that is a compile-time necessity
    ///      rather than a style choice: `_afterSwap` plus a seven-argument custody helper is
    ///      "stack too deep" under this project's non-viaIR settings. One struct pointer costs one
    ///      stack slot.
    ///
    /// @param collateralCurrency The VARIABLE leg's currency: output for exact-input, input for
    ///        exact-output.
    /// @param collateralBps Model L rate from the realized tick impact, in bps of the variable leg.
    /// @param inputDelta Pool delta for the input currency. Negative when the trader owes.
    /// @param outputDelta Pool delta for the output currency. Positive when the trader receives.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @param zeroForOne Swap direction.
    /// @param exactInput True when `amountSpecified < 0`.
    struct VLCustody {
        Currency collateralCurrency;
        uint256 collateralBps;
        int256 inputDelta;
        int256 outputDelta;
        int24 tickAfter;
        bool zeroForOne;
        bool exactInput;
    }

    /// @notice Resolves the swap's legs, collateral currency and collateral rate into one context.
    ///
    /// @dev Split out of `_afterSwap` so neither function carries the other's locals. All four
    ///      modes reduce to one expression each, because the mapping is a clean mirror:
    ///
    ///        exact-input  zeroForOne : input c0, output c1, collateral = c1 (output)
    ///        exact-input  oneForZero : input c1, output c0, collateral = c0 (output)
    ///        exact-output zeroForOne : input c0, output c1, collateral = c0 (input)
    ///        exact-output oneForZero : input c1, output c0, collateral = c1 (input)
    function _custodyContext(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        int24 tickBefore,
        int24 tickAfter
    ) private pure returns (VLCustody memory c) {
        bool exactInput = params.amountSpecified < 0;
        bool collateralIsCurrency0 = _collateralIsCurrency0(params.zeroForOne, exactInput);

        c = VLCustody({
            collateralCurrency: collateralIsCurrency0 ? key.currency0 : key.currency1,
            collateralBps: _collateralBpsFor(tickBefore, tickAfter),
            inputDelta: int256(params.zeroForOne ? delta.amount0() : delta.amount1()),
            outputDelta: int256(params.zeroForOne ? delta.amount1() : delta.amount0()),
            tickAfter: tickAfter,
            zeroForOne: params.zeroForOne,
            exactInput: exactInput
        });
    }

    /// @notice The collateral currency, from the swap kind and direction.
    ///
    /// @dev The whole unified rule in one expression, and the two kinds are exact mirrors:
    ///
    ///          exactInput  -> collateralIsCurrency0 == !zeroForOne     (collateral is the OUTPUT)
    ///          exactOutput -> collateralIsCurrency0 ==  zeroForOne     (collateral is the INPUT)
    ///
    /// @param zeroForOne Swap direction.
    /// @param exactInput True when `amountSpecified < 0`.
    function _collateralIsCurrency0(bool zeroForOne, bool exactInput) private pure returns (bool) {
        return exactInput ? !zeroForOne : zeroForOne;
    }

    /// @notice Model L collateral rate from the REALIZED tick impact (ADR-0005 section 2.2).
    ///
    /// @dev `collateralBps = min(MAX_BOND_BPS, ceil(|tickAfter - tickBefore| * SCALE))`.
    ///
    ///      O(1) IN IMPACT, and that is an architectural requirement rather than an optimisation:
    ///      one subtraction, one absolute value, one multiply, one ceiling division. It never
    ///      walks ticks, never reads a tick bitmap and never reads liquidity, so a 10,000-tick
    ///      move costs exactly what a 1-tick move costs. An implementation that had to traverse
    ///      ticks would be an unbounded loop on the swap path, which `AGENTS.md` forbids outright.
    ///
    ///      `ceil` is load-bearing: `floor` yields a ZERO rate for impacts of 1-3 ticks, so a
    ///      positive impact would post nothing at all.
    ///
    ///      Widened to `int256` before subtracting, per the signed-arithmetic rule: `tickAfter`
    ///      and `tickBefore` are `int24` and their difference is not representable in `int24` at
    ///      the extremes of the tick range.
    ///
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @return collateralBps Rate in bps of the variable leg. Zero only when the impact is zero.
    function _collateralBpsFor(int24 tickBefore, int24 tickAfter) private pure returns (uint256 collateralBps) {
        int256 signedImpact = int256(tickAfter) - int256(tickBefore);
        uint256 impactTicks = uint256(signedImpact < 0 ? -signedImpact : signedImpact);

        // ceil(impactTicks * COLLATERAL_SCALE / 100), integral throughout.
        collateralBps = (impactTicks * uint256(COLLATERAL_SCALE) + 99) / 100;

        if (collateralBps > MAX_BOND_BPS) collateralBps = MAX_BOND_BPS;
    }

    /// @notice The Model L collateral rate for a given realized tick impact, in bps.
    ///
    /// @dev A view over the pure rate function, exposed for two distinct reasons.
    ///
    ///      FOR CALLERS. Under variable-leg custody the collateral is no longer a fixed fraction
    ///      of a known input: it depends on the impact the swap turns out to have. A caller
    ///      choosing `maxBondAmount` needs to be able to price a hypothetical impact BEFORE
    ///      sending the swap, and quoting the swap gives it the two ticks. Without this, the only
    ///      safe ceiling is an over-generous one, which defeats the purpose of the ceiling.
    ///
    ///      FOR TESTS. It lets the suite compare the hook against `ModelLReference`, an
    ///      independent restatement of ADR-0005, over the whole curve rather than at the handful
    ///      of impacts a pool happens to produce. See `test/ModelLReferenceAgreement.t.sol` for
    ///      why that reference deliberately does not import from this file.
    ///
    ///      Pure and O(1): it never walks ticks and never touches storage, so it is safe to call
    ///      off-chain at any impact, including impacts no pool could reach.
    ///
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @return collateralBps Rate in bps of the variable leg, capped at `MAX_BOND_BPS`.
    function collateralBpsFor(int24 tickBefore, int24 tickAfter) external pure returns (uint256 collateralBps) {
        return _collateralBpsFor(tickBefore, tickAfter);
    }

    /// @notice The collateral actually held for a bond, recomputed from its record.
    ///
    /// @dev The record stores the realized VARIABLE LEG, not the collateral (ADR-0005 section
    ///      3.2). The collateral is recovered by the same expression that took it, from the same
    ///      stored inputs, so the two are equal by construction and not merely approximately:
    ///
    ///          taken at custody : bond      = variableLeg * collateralBps / BPS
    ///          recomputed here  : collateral = variableLegAmount * collateralBps / BPS
    ///
    ///      with `collateralBps` derived from the `tickBefore` / `tickAfter` the record froze.
    ///      `test_collateral_recomputationIsExact` pins this to the wei.
    function _collateralOf(Bond memory bond) private pure returns (uint128) {
        return uint128((uint256(bond.variableLegAmount) * _collateralBpsFor(bond.tickBefore, bond.tickAfter)) / BPS);
    }

    /// @notice Sizes and takes the variable-leg collateral, returning the delta v4 must apply.
    ///
    /// @dev THE ORDER IS THE SAFETY ARGUMENT, and it is checks -> effects -> interactions:
    ///
    ///      1. resolve the realized legs from the pool's own `BalanceDelta`;
    ///      2. decide eligibility on the ACTUAL consumed input;
    ///      3. size the collateral from the REALIZED impact and the REALIZED variable leg;
    ///      4. enforce INV-NOOP-VL, then the trader's own `maxBondAmount`;
    ///      5. finalize the record and register the maturity liability;
    ///      6. take the tokens;
    ///      7. return `+bond`.
    ///
    ///      Steps 2 and 3 are what removes the requested-gross oversizing: the previous
    ///      implementation sized the exact-input bond from `uint256(-params.amountSpecified)`, the
    ///      amount REQUESTED, so a swap filling a tenth still posted a full-size bond. Here both
    ///      the eligibility test and the collateral come from the `BalanceDelta` the pool actually
    ///      produced, and the impact term shrinks with the fill as well, so the collateral tracks
    ///      execution twice over (INV-L2-13).
    ///
    /// @param id Pool the swap ran against.
    /// @param hookData The trader's versioned payload, re-decoded rather than carried in storage.
    /// @param c Resolved custody context.
    /// @return bondDelta Collateral taken, as the unspecified-currency delta. Positive makes the
    ///         trader receive that much less output (exact-input) or owe that much more input
    ///         (exact-output). Zero when the swap turns out unbonded.
    function _takeVariableLegBond(PoolId id, bytes calldata hookData, VLCustody memory c)
        private
        returns (int128 bondDelta)
    {
        // A STORAGE pointer, not a memory copy: `_afterSwap` is at the EVM stack limit on this
        // path and a four-field `PoolConfig memory` is the difference between compiling and
        // "stack too deep". Only two of its fields are read here.
        PoolConfig storage cfg = poolConfig[id];

        // Bonding disabled: `_beforeSwap` wrote no provisional record either.
        if (cfg.bondBps == 0) {
            return int128(0);
        }

        bytes32 bondId;
        {
            uint32 maturityBlock = _maturityOf(_blockNumber32());

            bondId = _bondId(id, maturityBlock, maturity[id][maturityBlock].pendingBonds);
        }

        // The realized legs, straight from the pool's own delta. Direction decides which side is
        // the input; the swap KIND decides which side is variable. Eligibility is settled inside
        // this scope so `actualInput` does not stay live afterwards.
        uint256 variableLeg;
        {
            int256 inputDelta = c.inputDelta;

            // No input consumed: nothing executed, so nothing to bond and nothing left behind.
            if (inputDelta >= 0) {
                _clearProvisionalBond(bondId);

                return int128(0);
            }

            uint256 actualInput = uint256(-inputDelta);

            // Eligibility on the ACTUAL consumed input (INV-L2-13). The product rule is unchanged
            // -- a raw-amount ration on which trades are bonded -- but it is measured against what
            // happened rather than what was asked for. Realized impact is NOT the classifier here
            // and must not become one: impact SIZES the collateral, the threshold decides whether
            // the trade participates at all.
            if (actualInput < (c.zeroForOne ? cfg.minBondedAmount0 : cfg.minBondedAmount1)) {
                _clearProvisionalBond(bondId);

                return int128(0);
            }

            variableLeg = c.exactInput ? (c.outputDelta > 0 ? uint256(c.outputDelta) : 0) : actualInput;
        }

        // A swap that moved the price by less than one tick creates no LP-risk signal to price, so
        // it is UNBONDED -- not a bonded swap carrying a zero bond. The distinction matters: a
        // zero-amount record would be a maturity obligation with nothing behind it.
        // The strict equality is the semantics, not a comparison against a manipulable quantity.
        // `collateralBps` is a pure function of a tick difference, and ZERO has a specific,
        // distinct meaning here -- the price did not move a whole tick -- which is exactly the
        // case being branched on. A tolerance would make sub-tick swaps bond, which is the
        // behaviour this branch exists to prevent.
        // slither-disable-next-line incorrect-equality
        if (c.collateralBps == 0) {
            _clearProvisionalBond(bondId);

            return int128(0);
        }

        uint256 bond = (variableLeg * c.collateralBps) / BPS;

        // INV-NOOP-VL. Neither half is guaranteed by core -- see `BondViolatesNoOpVLBound`.
        // `bond == 0` is INV-NOOP-VL's lower bound stated exactly as the invariant states it. The
        // detector flags strict equality because it is dangerous against values an attacker can
        // nudge, such as balances or timestamps; `bond` is a truncating division of two values
        // fixed earlier in this same call, and zero is precisely the forbidden outcome. Widening
        // it to a tolerance would reject legitimate small bonds and still admit the zero case.
        // slither-disable-next-line incorrect-equality
        if (bond == 0 || bond >= variableLeg) {
            revert BondViolatesNoOpVLBound(bond, variableLeg);
        }

        {
            (address refundRecipient, uint128 maxBondAmount) = HookDataCodec.decode(hookData);

            // The trader's own ceiling, independent of the mechanism. Under hookData v2 it is
            // denominated in the COLLATERAL currency, which for exact-input is the token being
            // bought. The ceiling is on the COLLATERAL, never on the variable leg.
            if (bond > maxBondAmount) {
                revert BondExceedsTraderMax(bond, maxBondAmount);
            }

            emit BondTaken(id, refundRecipient, c.collateralCurrency, bond, variableLeg);
        }

        // Correct the provisional record's currency flag to the COLLATERAL currency before
        // finalizing. `_beforeSwap` could not know it: the swap kind decides, and for exact-input
        // the collateral is the OUTPUT.
        bonds[bondId].collateralIsCurrency0 = _collateralIsCurrency0(c.zeroForOne, c.exactInput);

        // The record stores the realized VARIABLE LEG (ADR-0005 section 3.2), not the collateral.
        _finalizeBond(id, bondId, uint128(variableLeg), c.tickAfter);

        c.collateralCurrency.take(poolManager, address(this), bond, false);

        return bond.toInt128();
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
            variableLegAmount: 0,
            cumulativeAtOpen: cumulativeAtOpen,
            tickBefore: tickBefore,
            tickAfter: 0,
            collateralIsCurrency0: inputIsCurrency0,
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

        bond.variableLegAmount = amount;
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

    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Settles one matured bond: refunds the surviving portion and retains the rest.
    ///
    /// @dev PERMISSIONLESS. Anyone may settle any matured finalized bond, and who calls it cannot
    ///      affect the outcome. The caller supplies only `bondId`; every economic input —
    ///      recipient, currency, collateral, maturity, opening observation — was bound when the
    ///      bond opened and cannot be supplied or influenced now.
    ///
    ///      THE GOVERNING GUARANTEE (ADR-0003 § 1):
    ///
    ///          settlement at M == settlement at M+1 == settlement at M+10,000
    ///
    ///      The settlement reference is derived from the cumulative FROZEN AT MATURITY, never from
    ///      the current tick, a current `observe()`, or any post-maturity pool state. Settlement
    ///      is permissionless, so the caller and the timing are adversarially chosen; if the
    ///      answer moved with the calling block, whoever picked the block would pick the answer.
    ///
    /// @param bondId Bond to settle.
    function settleBond(bytes32 bondId) external {
        _settleBond(bondId);
    }

    /// @notice Settles several bonds in one transaction.
    ///
    /// @dev ATOMIC. Any invalid entry — immature, already settled, provisional, unknown — reverts
    ///      the WHOLE batch. Skip-and-continue was deliberately not implemented: a caller must be
    ///      able to read a successful batch as "all of these settled", and partial success would
    ///      require inspecting per-entry results to learn what actually happened.
    ///
    ///      Bounded by `MAX_SETTLE_BATCH`. Both entry points share `_settleBond`, so the single
    ///      and batch paths cannot drift semantically; no external self-call is used for reuse.
    ///
    /// @param bondIds Bonds to settle. At most `MAX_SETTLE_BATCH`.
    function settleMany(bytes32[] calldata bondIds) external {
        uint256 length = bondIds.length;

        if (length > MAX_SETTLE_BATCH) revert SettleBatchTooLarge(length, MAX_SETTLE_BATCH);

        for (uint256 i = 0; i < length; i++) {
            _settleBond(bondIds[i]);
        }
    }

    /// @notice The single settlement implementation, shared by both entry points.
    ///
    /// @dev CHECKS -> EFFECTS -> INTERACTIONS, and this is the first path that sends bonded
    ///      collateral back out of the hook, so the ordering is load-bearing rather than stylistic.
    ///      The bond is marked SETTLED, `pendingBonds` decremented and the pot credited BEFORE the
    ///      transfer. A reentrant token cannot settle the same bond twice: on re-entry the state
    ///      is already SETTLED and `BondNotSettleable` fires. If the transfer reverts, every one of
    ///      those effects reverts with it.
    function _settleBond(bytes32 bondId) private {
        Bond storage bond = bonds[bondId];

        // Only a FINALIZED bond can settle. NONE, PROVISIONAL and SETTLED are all rejected with
        // the same error, so a provisional record stays indistinguishable from an absent one.
        BondState state = bond.state;
        if (state != BondState.FINALIZED) revert BondNotSettleable(bondId, state);

        uint32 maturityBlock = bond.maturityBlock;

        if (block.number < maturityBlock) {
            revert BondNotMature(bondId, maturityBlock, block.number);
        }

        PoolRef memory poolRef = poolRefByIndex[bond.poolIndex];
        PoolId id = poolRef.id;

        // The cumulative exactly at M — frozen earlier by a crossing swap, or derived now if the
        // pool has been quiet since before M.
        int56 cumulativeAtMaturity = _cumulativeAtMaturity(bondId, id, maturityBlock);

        // The settlement reference the frozen library expects is a TICK, not a cumulative: the
        // time-weighted average tick across the bond's own window, [openBlock, maturityBlock].
        // Two accumulator readings give it — the one recorded when the bond opened and the one
        // frozen at maturity.
        int24 settlementRef =
            TickAccumulatorLib.twaTick(bond.cumulativeAtOpen, cumulativeAtMaturity, maturityBlock - bond.openBlock);

        // The single slash curve. Not reimplemented here and not duplicated: `PersistenceMathLib`
        // is the only source of a slash result anywhere in the protocol.
        uint16 persistenceBps = PersistenceMathLib.computeBps(
            bond.tickBefore, bond.tickAfter, settlementRef, uint24(poolConfig[id].refundToleranceTicks)
        );

        // TRANSITIONAL, AND IT IS REMOVED IN P-L2-6.
        //
        // The record now stores the realized variable leg, so the collateral this settlement
        // needs is recomputed from the leg and the two frozen ticks. That recomputation is exact
        // -- same expression, same stored inputs as custody used -- so this stage's settlement
        // OUTCOME is byte-identical to the previous implementation's for the same bond.
        //
        // The slash curve below is still the legacy `PersistenceMathLib` one. P-L2-6 replaces it
        // with the L2 residual and dead zone, at which point the leg is consumed directly and this
        // recomputation is no longer a bridge but the intended read.
        uint128 collateral = _collateralOf(bond);

        // Conservation is exact by construction. `split` computes the slash and derives the refund
        // by subtraction, so `slash + refund == collateral` with no residual wei — computing both
        // sides independently from bps would leave rounding dust unaccounted for.
        (uint128 slash, uint128 refund) = PersistenceMathLib.split(collateral, persistenceBps);

        Currency currency = bond.collateralIsCurrency0 ? poolRef.currency0 : poolRef.currency1;
        address refundRecipient = bond.refundRecipient;

        // ---- EFFECTS, all before the transfer ----

        bond.state = BondState.SETTLED;

        // ADR-0004 Rule 3: the count tracks FINALIZED, UNSETTLED bonds, so it drops by exactly one
        // here. Reaching zero does NOT delete the bucket — the checkpoint stays frozen and stored
        // forever, per ADR-0003 § 5.4.
        maturity[id][maturityBlock].pendingBonds -= 1;

        // The slash never moves. It was already inside the hook; this reclassifies it.
        if (slash > 0) {
            insurancePot[id][currency] += slash;
        }

        emit BondSettled(bondId, id, refundRecipient, currency, collateral, refund, slash, persistenceBps);

        // ---- INTERACTION, last ----

        if (refund > 0) {
            currency.transfer(refundRecipient, refund);
        }
    }

    /// @notice Returns the cumulative exactly at a bond's maturity, freezing it if still possible.
    ///
    /// @dev Three cases, in the order ADR-0003 § 5.3 requires.
    ///
    ///      ALREADY FROZEN — the normal path. A swap crossed M and captured it. Return it.
    ///
    ///      NOT FROZEN, CURSOR STILL AT OR BEFORE M — the quiet-pool path. Nothing has swapped
    ///      since before M, so the tick has not changed and the value at M is still exactly
    ///      derivable from unchanged state. Derive it, freeze it, and use it. The result is
    ///      identical to what a crossing swap would have frozen, which is what lets a quiet pool
    ///      settle with no keeper and no transaction at M.
    ///
    ///      NOT FROZEN, CURSOR PAST M — revert. The tick has moved since M and the exact value is
    ///      unrecoverable. Approximating from live state would make the outcome depend on when
    ///      settlement was called. This is an upstream invariant violation, not a case to paper
    ///      over.
    function _cumulativeAtMaturity(bytes32 bondId, PoolId id, uint32 maturityBlock) private returns (int56 cumulative) {
        MaturityCheckpoint storage bucket = maturity[id][maturityBlock];

        if (bucket.checkpointed) {
            return bucket.cumulative;
        }

        TickAccumulatorLib.Accumulator memory acc = accumulator[id];

        if (acc.lastUpdate > maturityBlock) {
            revert MaturityCheckpointMissing(bondId, maturityBlock, acc.lastUpdate);
        }

        // Quiet path. `cumulativeAt` enforces its own domain, so a block outside
        // [lastUpdate, block.number] cannot be reconstructed even by accident.
        cumulative = acc.cumulativeAt(maturityBlock);

        bucket.cumulative = cumulative;
        bucket.checkpointed = true;

        emit MaturityCheckpointed(id, maturityBlock, cumulative);
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

        // FINALIZED and SETTLED are both real bonds and both readable — a settled bond is
        // historical record, and hiding it would make the settlement result unauditable.
        // Only NONE and PROVISIONAL report as absent, which is exactly what ADR-0004 Rule 1
        // requires: the rule is about provisional records, not about settled ones.
        // Strict equality on an enum, same as `bondExists`. Slither's `incorrect-equality`
        // detector targets `==` on balances and timestamps, where a value can be skipped past;
        // `state` is a four-valued enum and these are exactly the two values that mean "absent".
        // slither-disable-next-line incorrect-equality
        if (bond.state == BondState.NONE || bond.state == BondState.PROVISIONAL) revert BondNotFound(bondId);
    }

    /// @notice The refundable collateral actually held for a bond, in raw units of its
    ///         collateral currency.
    ///
    /// @dev THE SUPPORTED WAY TO READ THE COLLATERAL. `getBond(...).variableLegAmount` is the
    ///      realized variable LEG, not the collateral — the field was renamed rather than
    ///      silently repurposed precisely so that a caller reading the old `amount` fails to
    ///      compile instead of quietly reading a different quantity (ADR-0005 section 3.2).
    ///
    ///      The value is recomputed, not stored, and the recomputation is exact rather than
    ///      approximate: it is the same expression over the same frozen inputs that custody used.
    ///
    ///      Reverts for `NONE` and `PROVISIONAL` exactly as `getBond` does, so a provisional
    ///      record stays indistinguishable from an absent one (ADR-0004 Rule 1).
    ///
    /// @param bondId Bond to read.
    /// @return collateral Collateral held, in raw units of the bond's collateral currency.
    function collateralAmountOf(bytes32 bondId) external view returns (uint128 collateral) {
        Bond memory bond = bonds[bondId];

        // slither-disable-next-line incorrect-equality
        if (bond.state == BondState.NONE || bond.state == BondState.PROVISIONAL) revert BondNotFound(bondId);

        return _collateralOf(bond);
    }

    /// @notice Whether a bond id identifies a real bond — FINALIZED or SETTLED.
    /// @dev False for both `NONE` and `PROVISIONAL`, which are indistinguishable to callers.
    function bondExists(bytes32 bondId) external view returns (bool) {
        // Strict equality is correct and intended here. Slither's `incorrect-equality` detector
        // targets `==` on balances and timestamps, where a value can be skipped past. `state` is a
        // three-valued enum and the question is exactly "is it FINALIZED" — an ordered comparison
        // would silently accept any future state added above it.
        BondState state = bonds[bondId].state;

        // slither-disable-next-line incorrect-equality
        return state == BondState.FINALIZED || state == BondState.SETTLED;
    }
}
