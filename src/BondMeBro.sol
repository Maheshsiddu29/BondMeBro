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
///
/// @notice A Uniswap v4 hook that takes REFUNDABLE COLLATERAL from swaps large enough to matter,
///         holds it for ten blocks, and returns whatever the price did not keep.
///
///         The idea in one line: a swap that moves the price and leaves it moved has imposed a
///         cost on liquidity providers; a swap whose price impact reverts has not. BondMeBro
///         measures which happened and charges accordingly, rather than charging everyone a fee
///         up front.
///
/// @dev SUPPORTED MODES. Single-hop ERC-20 <-> ERC-20, exact-input and exact-output, both
///      directions. NOT supported, and not tested: multi-hop, native currency, fee-on-transfer
///      tokens, and rebasing or otherwise non-standard tokens.
///
///      HOW MUCH IS TAKEN — impact-scaled, from realized execution (ADR-0005, ADR-0006, ADR-0008).
///
///          ownImpact         = |tickAfter - tickBefore|
///          blockDisplacement = |tickAfter - blockStartTick|
///          effectiveImpact   = max(ownImpact, blockDisplacement)
///
///          collateralBps = min(100, ceil(effectiveImpact * 0.25))
///          collateral    = variableLegAmount * collateralBps / 10_000
///
///      Both inputs are REALIZED, never requested: a swap that asks for a large amount and fills a
///      small one is charged on what it actually did. Eligibility works the same way — a trade
///      participates only if the input the pool actually CONSUMED clears the pool's threshold.
///
///      WHY THE BLOCK TERM EXISTS (ADR-0008). Sizing collateral from a swap's OWN impact alone
///      lets one price move be split into N same-block pieces, each posting about `leg × impact /
///      N²`, so the total falls as `1/N` while the pool ends the block at exactly the same price.
///      Below one tick per piece the rate rounds to zero and the pieces stop bonding at all, so
///      the dilution is unbounded — measured at 132x for 512 pieces of a 58-tick move.
///
///      `blockStartTick` is the tick the pool sat at when the block's FIRST swap was about to
///      execute, so `blockDisplacement` prices a trade on WHERE IT LEFT THE POOL relative to where
///      the block started, not merely on how far it personally moved it.
///
///      IT IS POOL-LEVEL AND IDENTITY-FREE. Nothing here reads `sender`, `refundRecipient`,
///      `tx.origin` or the router, so the charge cannot be reduced by spreading a trade across
///      addresses, routers or transactions — only by not moving the price.
///
///      A TRADE FIRST IN ITS BLOCK IS UNAFFECTED. Then `blockStartTick == tickBefore`, the two
///      terms are equal, and the collateral is bit-identical to what the pre-ADR-0008 rule took.
///      Isolated traffic is priced exactly as before.
///
///      THIS IS MITIGATION, NOT IMMUNITY. A same-block split still dilutes the charge by about 2x
///      on collateral and 4x on the slash. ADR-0008 § 7 states the measured limits and explicitly
///      does not claim split invariance.
///
///      WHICH TOKEN IT COMES FROM — the swap's VARIABLE leg, which the swap KIND decides:
///
///          exact-input  : the input is fixed, so the collateral comes out of the OUTPUT
///          exact-output : the output is fixed, so the collateral comes out of the INPUT
///
///      Either way the SPECIFIED leg is untouched: a trader who asks to spend exactly 1,000 USDC
///      spends exactly 1,000 USDC. The hook does not hold `BEFORE_SWAP_RETURNS_DELTA` and so has
///      no mechanism to alter the specified amount at all.
///
///      HOW MUCH IS KEPT — Model L2's surviving-displacement residual (ADR-0005, ADR-0007).
///      Settlement reads the pool's tick cumulative at three frozen endpoints and asks how much of
///      the original displacement was still there late in the window:
///
///          R = max( aligned TWA over blocks 6-7, aligned TWA over blocks 8-9, 0 )
///          Q = 0 if R <= 5 ; 2(R - 5) if R < 10 ; R otherwise      <- the D = 5 dead zone
///          slashBps = min(collateralBps, ceil(Q * 0.25))
///          slash    = variableLegAmount * slashBps / 10_000
///          refund   = collateral - slash
///
///      Displacement is measured in the trade's OWN direction and clamped at zero, so a price move
///      the other way can never manufacture a charge. Settlement is permissionless and its answer
///      does not depend on when it is called.
///
///      WHAT THIS IS NOT. It does not detect or label traders, it does not price toxicity, and it
///      does not make manipulation impossible. It is an LP-risk PROXY: measured price displacement
///      over a fixed window, nothing more. Its known limitations are documented rather than
///      hidden — see ADR-0005 § 6 for the two-block straddle, the noise floor below which
///      displacement is free, and the 1% cap above which protection stops scaling.
///
///      THE PARAMETERS ARE FROZEN AND NOT GOVERNABLE. The collateral scale, the 1% cap, the
///      ten-block horizon and the dead zone are compile-time constants. A pool owner can enable or
///      disable the mechanism and set which trades are large enough to participate; nobody can
///      change what participation costs.
///
///      STATE. The hook is NOT stateless: it keeps a per-pool tick accumulator, one record per
///      bond, and one maturity bucket per block holding that cohort's three observation endpoints.
///      See ADR-0003, ADR-0004 and ADR-0007.

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

    /// @notice The collateral rate cap: 1% of the variable leg, i.e. 100 bps.
    ///
    /// @dev ADR-0005 calls this `MAX_COLLATERAL_BPS`; the name here keeps the contract's own
    ///      "bond" vocabulary, which `settleBond`, `bondExists` and `maxBondAmount` also use.
    ///      They are the same constant.
    ///
    ///      A cap is required rather than merely prudent: it is what keeps the collateral a small
    ///      fraction of the trade, which is what makes INV-NOOP-VL's strict upper bound
    ///      unreachable in practice. Raising it is an economic decision needing its own ADR, and
    ///      ADR-0005 § 6.3 records what is given up by holding it here.
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
    ///      trade-off can only be settled against simulation and market-impact research, none of
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

    /*              OBSERVATION CHECKPOINTS (ADR-0007)               /*/

    /// @notice `frozenMask` bit for C6, the endpoint at `M - 4`.
    uint8 public constant FROZEN_C6 = 1;

    /// @notice `frozenMask` bit for C8, the endpoint at `M - 2`.
    uint8 public constant FROZEN_C8 = 2;

    /// @notice `frozenMask` bit for C10, the endpoint at `M`. The previous sole checkpoint.
    uint8 public constant FROZEN_C10 = 4;

    /// @notice All three endpoints frozen. Used as an early-out, never as a lifecycle state.
    uint8 public constant FROZEN_ALL = 7;

    /// @notice Blocks between a bucket's earliest endpoint (C6) and its maturity block.
    /// @dev `M - C6 = 4`. Named because it appears in the scheduler's `dueEnd` and in every
    ///      endpoint derivation, and an off-by-one here silently shifts the whole observation
    ///      window.
    uint32 public constant C6_OFFSET_FROM_MATURITY = 4;

    /// @notice Blocks between C8 and the maturity block. `M - C8 = 2`.
    uint32 public constant C8_OFFSET_FROM_MATURITY = 2;

    /*              MODEL L2 COLLATERAL SIZING (ADR-0005)            /*/

    /// @notice Collateral rate, in bps of the variable leg per tick of REALIZED impact, carried as
    ///         an integer numerator over 100 so every operation stays integral.
    ///
    /// @dev 25 == 0.25 bps/tick, the V7.1 selected value, FROZEN by ADR-0005 section 2.1. It is a
    ///      calibration choice made against a synthetic population, not a historically validated
    ///      optimum — see ADR-0005 section 6.4 before changing it, and open a new ADR.
    uint16 public constant COLLATERAL_SCALE = 25;

    /// @notice Denominator for `COLLATERAL_SCALE`, making the rate `25/100 == 0.25` bps per tick.
    ///
    /// @dev Named rather than written as a bare `100`, because the pair is what expresses the
    ///      frozen 0.25 and a reader seeing only `+ 99) / 100` has to reconstruct that. The `+ 99`
    ///      is the ceiling, which is load-bearing: with `floor`, impacts of 1-3 ticks would price
    ///      at ZERO and a swap that visibly moved the price would post nothing.
    uint256 public constant COLLATERAL_SCALE_DENOMINATOR = 100;

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

    /// @param minBondedAmount0 Minimum CONSUMED input that makes a swap participate when currency0
    ///        is the input (`zeroForOne == true`), in raw currency0 units. Measured against what the
    ///        pool actually took, never against what was requested.

    /// @param minBondedAmount1 The same for currency1 as the input (`zeroForOne == false`), in raw
    ///        currency1 units. Separate because the two currencies may differ in decimals and
    ///        value.

    /// @param bondingEnabled Whether this pool bonds at all.
    ///
    ///        THE ONLY ECONOMIC CONTROL AN OWNER HAS, and that is deliberate. Everything that
    ///        decides how much a trade pays is a compile-time constant: the collateral scale, the
    ///        1% cap, the observation horizon and the `D = 5` dead zone. An owner can turn the
    ///        mechanism on or off for a pool and choose which trades are large enough to
    ///        participate; they cannot change what participation costs.
    ///
    ///        This replaced two `uint16` fields in P-L2-7. `bondBps` had been vestigial as a rate
    ///        since P-L2-3/4 — Model L derives the rate from realized impact — and survived only
    ///        as a `!= 0` enable sentinel; `refundToleranceTicks` was Model B's noise floor and
    ///        became unread in P-L2-6. Keeping either would have left a field whose name promised
    ///        control it did not have, which is the most dangerous kind of configuration surface.
    ///
    ///        ADR-0005 § 4 anticipated repurposing the two fields as an owner-settable scale and
    ///        dead zone. That was NOT done: it would hand governance direct control over the
    ///        economics, which needs its own research and its own ADR rather than arriving as a
    ///        side effect of cleanup.
    struct PoolConfig {
        uint128 minBondedAmount0;
        uint96 minBondedAmount1;
        bool bondingEnabled;
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
    ///        slot 1: variableLegAmount 16 + tickBefore 3 + tickAfter 3 + collateralBps 2
    ///                + flag 1 + state 1 = 26 bytes
    ///
    ///      Two slots is the floor for this field set: `refundRecipient` (20) plus any useful
    ///      `amount` width already fills the first slot. P-L2-8.2's `collateralBps` went into slot
    ///      1's existing spare bytes and did NOT add a third slot — 6 bytes remain.
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
    /// @param tickBefore Pool tick immediately before the swap. The SETTLEMENT displacement's ZERO:
    ///        every Model L2 late window is measured against it. Since ADR-0008 it is no longer the
    ///        sole input to the collateral RATE — see `collateralBps`.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @param collateralBps The rate custody ACTUALLY charged, in bps of the variable leg.
    ///
    ///        STORED RATHER THAN RECOMPUTED, AND THAT IS FORCED BY ADR-0008 rather than chosen.
    ///        Before ADR-0008 the rate was a pure function of the two ticks this record already
    ///        held, so settlement recomputed it and reproduced the physically-taken amount by
    ///        construction. The effective rate now also depends on `blockStartTick`, which is
    ///        PER-POOL state that every later block overwrites — unrecoverable by the time anyone
    ///        settles. Recomputing would silently return a DIFFERENT number from the one taken,
    ///        which is the one failure mode this record exists to prevent.
    ///
    ///        Two bytes, into slot 1's existing spare: 16 + 3 + 3 + 2 + 1 + 1 = 26 of 32. `uint8`
    ///        would also have fitted and is enough for a rate capped at 100; `uint16` is used
    ///        because it survives a future cap change without a layout migration, and the byte it
    ///        costs was already paid for.
    ///
    ///        ADR-0005 § 3.2's argument for storing the LEG rather than the COLLATERAL is
    ///        untouched and still governs: the leg is what the only INV-L2-4-safe token slash form
    ///        needs, and the `leg = 102` counterexample still rules out the ratio form. This adds
    ///        the rate; it does not replace the leg.
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
        int24 tickBefore;
        int24 tickAfter;
        uint16 collateralBps;
        bool collateralIsCurrency0;
        BondState state;
    }

    /// @notice One maturity bucket, shared by every bond maturing in the same block, carrying all
    ///         THREE observation endpoints. Still exactly one slot.
    ///
    /// @dev ADR-0007. Model L2's residual is `max(TWA(6,8), TWA(8,10))`, which needs the pool's
    ///      tick cumulative at three blocks per bond rather than one:
    ///
    ///          C6  = cumulative at open+6  = M - 4     (frozenMask bit 0)
    ///          C8  = cumulative at open+8  = M - 2     (bit 1)
    ///          C10 = cumulative at open+10 = M         (bit 2)  <- the previous sole endpoint
    ///
    ///      WHY ONE BUCKET SUFFICES, and it is not a packing trick. Maturity is
    ///      `openBlock + OBSERVATION_BLOCKS`, an injective map, so every bond in bucket `M` opened
    ///      at exactly `M - 10`. One bucket therefore describes one opening block, and its three
    ///      endpoints are shared by every bond in it. A thousand bonds opened in the same block
    ///      still need one bucket and one freeze per endpoint.
    ///
    ///      WHY A MASK RATHER THAN A BOOLEAN. The three endpoints become frozen at three different
    ///      blocks, so a single flag could not express the state at, say, `lastUpdate == open+7` --
    ///      where C6 is already frozen while C8 and C10 are still exactly derivable. ADR-0003
    ///      section 4's "three lifecycle states, not one flag" argument is unchanged; it simply has
    ///      three of the middle state now.
    ///
    ///      PACKING IS LOAD-BEARING: 56*3 + 32 + 8 = 208 bits, one slot, at offsets
    ///      0 / 7 / 14 / 21 / 25. `test/StorageLayout.t.sol` proves this from the compiler's own
    ///      layout AND by decoding a raw `vm.load` word field by field. A spill to a second slot
    ///      would put a cold SSTORE on the swap path and is a hard failure, not a regression.
    ///
    ///      That the slot is already non-zero when an endpoint freezes is the whole cost argument
    ///      (ADR-0007 section 4): `pendingBonds` made it non-zero at bond registration, so every
    ///      freeze is an `SSTORE_RESET` on an already-loaded slot rather than an `SSTORE_SET`.
    ///      Giving interior endpoints their own buckets would have allowed a fresh-slot write and
    ///      projected ~217,000 gas against a 150,000 ceiling, reachable with four cheap swaps.
    ///
    /// @param cumulativeMinus4 C6 -- accumulator value exactly at `M - 4`. Immutable once frozen.
    /// @param cumulativeMinus2 C8 -- accumulator value exactly at `M - 2`. Immutable once frozen.
    /// @param cumulativeAtM C10 -- accumulator value exactly at `M`. Immutable once frozen.
    /// @param pendingBonds Registered-but-unsettled bonds depending on this bucket. A liability
    ///        count only — it must NEVER decide whether the bucket needs checkpointing. It is also
    ///        the SOLE occupancy signal (ADR-0004 Rule 3).
    /// @param frozenMask Which endpoints have been permanently written. Three independent bits;
    ///        a set bit is never cleared.
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

    struct MaturityCheckpoint {
        int56 cumulativeMinus4;
        int56 cumulativeMinus2;
        int56 cumulativeAtM;
        uint32 pendingBonds;
        uint8 frozenMask;
    }

    /*//////////////////////////////////////////////////////////////
                                  STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The only address that may configure pools.
    /// @dev ownership cannot be transferred or renounced. This avoids ownership-transfer complexity at the cost of key rotation. Owner powers are limited to configuring per-pool bonding parameters.
    address public immutable owner;

    /// @notice Bonding parameters per pool. A pool with no entry never bonds.
    mapping(PoolId => PoolConfig) public poolConfig;

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

    /// @notice Emitted when bonding parameters are changed for a pool.
    /// @param id Pool being configured.
    /// @param minBondedAmount0 Minimum bonded input when currency0 is the input.
    /// @param minBondedAmount1 Minimum bonded input when currency1 is the input.
    /// @param bondingEnabled Whether the pool bonds at all after this call.
    event PoolConfigured(PoolId indexed id, uint128 minBondedAmount0, uint96 minBondedAmount1, bool bondingEnabled);

    /// @notice Emitted when BondMeBro takes collateral from a swap.
    /// @param id Pool where the swap occurred.
    /// @param refundRecipient Address intended to receive a future refund.
    /// @param currency Currency used for the bond.
    /// @param bond Amount of collateral taken, in raw token units.
    /// @param variableLegAmount The swap's realized VARIABLE leg -- the output for exact-input, the
    ///        pool input for exact-output. This is the quantity the collateral is a fraction of,
    ///        and the quantity the record stores.
    ///
    ///        RENAMED FROM `grossInput` IN P-L2-7. The emitted VALUE has been the variable leg
    ///        since P-L2-3/4 moved custody; only the parameter name was left behind, describing a
    ///        quantity this event has not carried for two stages. Same type, same position, same
    ///        topic.
    event BondTaken(
        PoolId indexed id,
        address indexed refundRecipient,
        Currency indexed currency,
        uint256 bond,
        uint256 variableLegAmount
    );

    /// @notice Emitted when a bond record is created and its maturity registered.
    /// @param bondId Deterministic identifier of the new bond.
    /// @param id Pool the bond belongs to.
    /// @param refundRecipient Address the refund is owed to.
    /// @param variableLegAmount The realized VARIABLE leg the record stores -- the output for an
    ///        exact-input swap, the pool input for an exact-output one.
    ///
    ///        RENAMED FROM `amount` IN P-L2-7, and the old doc was wrong in two ways at once: it
    ///        said "collateral held" and "input-currency units", and the value is neither. The
    ///        record has stored the variable leg since P-L2-3/4 (ADR-0005 § 3.2), and for
    ///        exact-input the collateral currency is the OUTPUT. Read the collateral with
    ///        `collateralAmountOf`, which derives it.
    ///
    ///        Same type, same position, same event topic.
    /// @param maturityBlock Block at which the bond's observation window closes.
    event BondOpened(
        bytes32 indexed bondId,
        PoolId indexed id,
        address indexed refundRecipient,
        uint128 variableLegAmount,
        uint32 maturityBlock
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

    /// @notice Thrown when bonding is enabled without both direction thresholds.
    ///
    /// @dev A ZERO THRESHOLD DOES NOT MEAN "DISABLE THIS DIRECTION". Eligibility is
    ///      `consumedInput >= threshold`, so a zero threshold bonds EVERY positive swap in that
    ///      direction — the most aggressive possible setting, reached by omission. Requiring both
    ///      explicitly keeps the most punitive configuration from being the easiest typo.
    ///
    ///      Disabling is `bondingEnabled == false`, which is unambiguous and needs no sentinel.
    ///      `BondBpsAboveCap` was removed alongside this in P-L2-7: with no owner-settable rate
    ///      there is no rate left to cap.
    error IncompleteBondingConfig(uint128 minBondedAmount0, uint96 minBondedAmount1);

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
    /// @param slashBps Realized slash rate, in bps of the variable leg.
    ///
    ///        RENAMED FROM `persistenceBps` IN P-L2-7. Under Model B this carried a persistence
    ///        FRACTION -- how much of the original displacement survived, as a ratio. Model L2
    ///        emits a RATE instead: `min(collateralBps, ceil(Q * 0.25))`, in bps of the variable
    ///        leg. Same type, same position, same event topic, so decoders are unaffected; only
    ///        the name and its meaning changed, and leaving the old name would have described the
    ///        value wrongly.
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

    /// @notice Enables or disables refundable collateral for a pool, and sets its participation
    ///         thresholds.
    ///
    /// @dev THE OWNER CHOOSES WHO PARTICIPATES, NOT WHAT IT COSTS. Enabling bonding requires both
    ///      direction thresholds; the collateral rate, the 1% cap, the 10-block observation
    ///      horizon and the `D = 5` dead zone are compile-time constants and are not configurable
    ///      by anyone. See `PoolConfig`.
    ///
    ///      Separate thresholds are needed because the two currencies may have different decimals
    ///      and values. Example for a USDC/WETH pool:
    ///
    ///          minBondedAmount0 = 100e6      // 100 USDC
    ///          minBondedAmount1 = 0.03e18    // 0.03 WETH
    ///          bondingEnabled   = true
    ///
    ///      Lowering a threshold can make a previously unbonded quote require collateral at
    ///      execution time. If that transaction carries no valid hookData, it reverts — which is
    ///      the intended failure, since the alternative is taking collateral the trader never
    ///      authorised a recipient or a ceiling for.
    ///
    ///      Disabling clears both thresholds so a disabled pool cannot carry stale numbers that
    ///      would take effect the moment it is re-enabled.
    ///
    /// @param key Pool to configure.
    /// @param minBondedAmount0 Minimum CONSUMED input that participates when currency0 is the
    ///        input, in raw currency0 units. Ignored when disabling.
    /// @param minBondedAmount1 The same for currency1. Ignored when disabling.
    /// @param bondingEnabled Whether this pool takes refundable collateral at all.
    function setPoolConfig(PoolKey calldata key, uint128 minBondedAmount0, uint96 minBondedAmount1, bool bondingEnabled)
        external
        onlyOwner
    {
        // Enabling requires BOTH thresholds. Disabling ignores them: whatever is passed alongside
        // `false` is irrelevant, because nothing will read it.
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
        PoolId id = key.toId();

        // Register the pool so bonds can reference it by a 4-byte index instead of a 32-byte
        // PoolId plus a 20-byte currency. Indices start at 1 so zero stays a sentinel. This is a
        // one-off cost at pool creation, deliberately traded against per-swap record size.
        if (poolIndexOf[id] == 0) {
            uint32 index = ++poolCount;

            poolIndexOf[id] = index;
            poolRefByIndex[index] = PoolRef({id: id, currency0: key.currency0, currency1: key.currency1});
        }

        // ADR-0008. Seed the block-start tick alongside the accumulator's first observation, so a
        // swap in the pool's very first block measures its displacement from the initialization
        // price rather than from an unwritten zero. `beginBlock` before `update`, always: after
        // `update` the `lastUpdate == 0` test it keys off is already false.
        accumulator[id].beginBlock(tick);

        // slither-disable-next-line unused-return
        accumulator[id].update(tick);

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Pre-swap validation, the checkpoint scan, and the provisional bond record.
    ///
    /// @dev NO CUSTODY HAPPENS HERE, for either swap kind. This callback returns `ZERO_DELTA` on
    ///      every path and the hook does not hold `BEFORE_SWAP_RETURNS_DELTA`, so it has no
    ///      mechanism to touch the swap's specified amount at all. That is ADR-0006's central
    ///      security property, and it is structural rather than a matter of restraint.
    ///
    ///      What this callback does, in order:
    ///
    ///        1. advances the tick accumulator and freezes every observation endpoint the cursor
    ///           has now crossed (ADR-0007);
    ///        2. short-circuits when the pool has bonding disabled;
    ///        3. short-circuits an exact-input swap whose REQUESTED input is already below the
    ///           threshold, since no fill can bring it above one;
    ///        4. otherwise decodes and validates hookData, and writes the provisional record.
    ///
    ///      Step 3 is an exact filter, not a heuristic: a swap requesting less than the threshold
    ///      cannot consume more than it requested, so it can never become eligible. Exact-output
    ///      gets no such filter, because its input is unknown until the pool executes.
    ///
    ///      Sizing and custody both happen in `_afterSwap`, where the realized legs and the
    ///      realized tick impact are known. See `_takeVariableLegBond`.
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
        if (!cfg.bondingEnabled) {
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

        // The provisional header is written for BOTH swap kinds. That moves two cold SSTOREs out
        // of `_afterSwap` and into this callback -- deliberately, because `_afterSwap` must also
        // perform the token transfer and has the tighter ceiling. ADR-0004 Rule 2.
        //
        // `lastTick` is the pool tick from BEFORE this swap: `_advanceAndCheckpoint` above moved
        // time forward but left the tick alone. It is the displacement's zero, and Model L2
        // measures every late window against it (ADR-0005 § 3.3).
        //
        // The currency flag is written provisionally from the DIRECTION and corrected to the
        // collateral currency at finalization, where the swap KIND is what decides it. A
        // provisional record is invisible to every protocol path (ADR-0004 Rule 1), so the
        // intermediate value is never observable.
        // slither-disable-next-line unused-return
        _openProvisionalBond(id, params.zeroForOne, refundRecipient, accumulator[id].lastTick);

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
            _takeVariableLegBond(
                id,
                hookData,
                // `blockStartTick` is read INLINE rather than into a named local. This frame is at
                // the EVM stack limit under this project's non-viaIR settings -- the note above on
                // `tickBefore` records the same constraint -- and one more live `int24` is the
                // difference between compiling and "stack too deep".
                //
                // It is safe to read here: `_advanceAndCheckpoint` latched it in `beforeSwap` and
                // `update` above never touches it, so this is still THIS block's starting tick. It
                // is a warm SLOAD of the slot `lastTick` was just read from.
                _custodyContext(key, params, delta, tickBefore, tickAfter, accumulator[id].blockStartTick)
            )
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
    /// @param collateralBps Model L rate from the EFFECTIVE tick impact (ADR-0008), in bps of the
    ///        variable leg: `max(ownImpact, blockDisplacement)` through the frozen curve.
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
        collateralBps = (impactTicks * uint256(COLLATERAL_SCALE) + (COLLATERAL_SCALE_DENOMINATOR - 1))
            / COLLATERAL_SCALE_DENOMINATOR;

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

    /// @notice The BLOCK-CUMULATIVE collateral rate actually charged (ADR-0008 § 3).
    ///
    /// @dev ```
    ///          ownImpact       = |tickAfter - tickBefore|
    ///          blockDisplacement = |tickAfter - blockStartTick|
    ///          effectiveImpact = max(ownImpact, blockDisplacement)
    ///          collateralBps   = min(MAX_BOND_BPS, ceil(effectiveImpact * SCALE / 100))
    ///      ```
    ///
    ///      THE CURVE IS UNTOUCHED. `COLLATERAL_SCALE`, `MAX_BOND_BPS` and the `ceil` are the same
    ///      frozen constants `_collateralBpsFor` uses; only the impact fed into them changes. That
    ///      is what keeps this a mitigation rather than a re-calibration of ADR-0005's economics.
    ///
    ///      THE `max` IS LOAD-BEARING IN BOTH DIRECTIONS and neither term subsumes the other. A
    ///      swap REVERTING a displaced block has a large own impact and a small block
    ///      displacement; a swap adding a sliver to an already-displaced block has the reverse.
    ///      Charging either term alone would leave a cheaper path open.
    ///
    ///      IT IS A NO-OP ON A BLOCK'S FIRST SWAP. Then `blockStartTick == tickBefore`, the two
    ///      terms are equal, and this returns exactly what `_collateralBpsFor` returns —
    ///      bit-identical to pre-ADR-0008 behaviour. `test/BlockCumulativeImpact.t.sol` asserts
    ///      that equivalence across all four modes rather than leaving it to inspection.
    ///
    ///      MONOTONICITY, PRECISELY. This is NOT monotone in `ownImpact`: a trade reverting toward
    ///      `blockStartTick` raises its own impact while lowering its block displacement, and the
    ///      `max` has an interior minimum at the midpoint. That is why INV-L2-4 was superseded by
    ///      INV-L2-4a/4b/4c — see ADR-0008 § 5. What IS guaranteed:
    ///        - among trades moving FURTHER from `blockStartTick`, the rate is non-decreasing in
    ///          own impact, because both terms are (INV-L2-4a);
    ///        - the result is never below `_collateralBpsFor`'s, because `max(a, b) >= a`
    ///          (INV-L2-4b).
    ///
    ///      O(1), like the function it wraps: two subtractions, two absolute values, a comparison,
    ///      a multiply and a ceiling division. No tick walk, no bitmap read, no liquidity read.
    ///
    ///      Widened to `int256` before subtracting, per the project's signed-arithmetic rule: the
    ///      differences are not representable in `int24` at the extremes of the tick range.
    ///
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @param blockStartTick Pool tick when this block's first swap was about to execute.
    /// @return collateralBps Rate in bps of the variable leg, capped at `MAX_BOND_BPS`. Zero only
    ///         when the swap moved the price by less than a tick AND left the pool exactly where
    ///         the block started.
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

        // ceil(effectiveTicks * COLLATERAL_SCALE / 100), integral throughout. Identical arithmetic
        // to `_collateralBpsFor`; only the numerator's source differs.
        collateralBps = (effectiveTicks * uint256(COLLATERAL_SCALE) + (COLLATERAL_SCALE_DENOMINATOR - 1))
            / COLLATERAL_SCALE_DENOMINATOR;

        if (collateralBps > MAX_BOND_BPS) collateralBps = MAX_BOND_BPS;
    }

    /// @notice The block-cumulative rate for a hypothetical trade, exposed for callers and tests.
    ///
    /// @dev The ADR-0008 counterpart of `collateralBpsFor`. A caller sizing `maxBondAmount` can
    ///      price a hypothetical impact against a hypothetical block displacement before sending —
    ///      though ADR-0008 § 8 is explicit that the block displacement at EXECUTION is not
    ///      knowable at quote time, and states the conservative policy that follows.
    ///
    ///      `blockStartTickOf` below returns the live latch, so an off-chain caller can read the
    ///      pool's current block-start tick and feed it here.
    function effectiveCollateralBpsFor(int24 tickBefore, int24 tickAfter, int24 blockStartTick)
        external
        pure
        returns (uint256 collateralBps)
    {
        return _effectiveCollateralBps(tickBefore, tickAfter, blockStartTick);
    }

    /// @notice The tick this pool's current block started at, as the collateral rate will use it.
    ///
    /// @dev A convenience over the public `accumulator` getter, which returns four fields. NOTE
    ///      that this reads the latch as it stands NOW: if no swap has touched the pool yet in the
    ///      current block, the value still describes the PREVIOUS block and will be re-latched to
    ///      `lastTick` by the next swap. A caller that needs the value a swap sent now would see
    ///      must apply that rule itself — `lastUpdate < block.number` means "the next swap
    ///      re-latches to `lastTick`".
    function blockStartTickOf(PoolId id) external view returns (int24) {
        TickAccumulatorLib.Accumulator memory acc = accumulator[id];

        if (acc.lastUpdate != 0 && acc.lastUpdate < _blockNumber32()) return acc.lastTick;

        return acc.blockStartTick;
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
    ///      with `collateralBps` read from the record rather than recomputed.
    ///      `test_collateral_recomputationIsExact` pins this to the wei.
    ///
    ///      READING THE STORED RATE IS REQUIRED SINCE ADR-0008, not merely convenient. The
    ///      effective rate depends on `blockStartTick`, which is per-pool state that every later
    ///      block overwrites, so it is unrecoverable by the time anyone reads this bond.
    ///      Recomputing from `tickBefore`/`tickAfter` would return the OWN-impact rate — a
    ///      different, smaller number than the one physically taken — and would silently
    ///      under-refund every bond opened behind another trade in its block.
    function _collateralOf(Bond memory bond) private pure returns (uint128) {
        return uint128((uint256(bond.variableLegAmount) * uint256(bond.collateralBps)) / BPS);
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
        if (!cfg.bondingEnabled) {
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
        _finalizeBond(id, bondId, uint128(variableLeg), c.tickAfter, uint16(c.collateralBps));

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

        // ADR-0008 § 3.3. THE ONLY STATE WRITE THIS MIGRATION ADDS TO THE SWAP PATH, and it must
        // happen HERE — before `acc.update` below moves `lastUpdate` onto this block, and before
        // `_afterSwap` moves `lastTick` onto the post-swap price. One comparison, plus a warm
        // SSTORE into the accumulator's existing slot on a block's FIRST swap only; that slot is
        // written by `update` in this same call regardless, so no cold write is introduced.
        //
        // Deliberately unconditional on `bondingEnabled`, exactly like the accumulator advance it
        // sits next to: a pool whose owner enables bonding mid-block must not find its first
        // bonded swap measuring displacement from a stale or unwritten latch.
        acc.beginBlock(currentTick);

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
            // THE SCAN IS BUCKET-CENTRIC, AND THAT IS A MEASURED DECISION (ADR-0007 section 3.2).
            //
            // The obvious shape is block-centric: walk blocks, and for each block ask "does a bond
            // mature here, or two blocks from here, or four". That needs THREE mapping lookups per
            // block. It was built and measured: +22,548 gas on a scan with nothing registered at
            // all, and 158,313 in the worst case -- over the 150,000 ceiling. The lookups, not the
            // writes, dominated.
            //
            // This loop inverts it: walk candidate maturity BUCKETS, and for each one ask which of
            // its own three endpoints have been reached. One lookup per candidate, and up to three
            // fields written into the single warm slot it has already loaded.
            //
            // Do not reintroduce the block-centric form. It is recorded as a measured failure.
            //
            // TWO DIFFERENT BOUNDS MEET HERE, and conflating them is how the loop gets too big or
            // too small:
            //
            //   occupancyEnd -- no bucket ABOVE this can be occupied. A bucket at `m` needs a bond
            //       opened at `m - OBSERVATION_BLOCKS`, and opening a bond is a swap, which sets
            //       `lastUpdate` to its own block. So `m <= lastUpdate + OBSERVATION_BLOCKS` for
            //       every bucket that exists.
            //
            //   dueEnd -- no bucket ABOVE this has any work yet. A bucket's earliest endpoint is
            //       `m - 4`, so it acquires its first due endpoint only once `nowBlock >= m - 4`.
            //
            // `OBSERVATION_BLOCKS` (10), not `MAX_OBSERVATION_BLOCKS` (16), is the right bound for
            // occupancy. The two constants are not the same concept and must not be swapped:
            // `MAX_OBSERVATION_BLOCKS` is the accumulator's supported domain and the hard maximum
            // `OBSERVATION_BLOCKS` may ever be raised to; `OBSERVATION_BLOCKS` is how far ahead an
            // occupied maturity bucket can actually sit. Scanning to the former would pay for six
            // positions that provably cannot be occupied -- ADR-0007 measured that at 14,794 gas
            // of wasted work per full-horizon scan, at 2,466 gas per scanned position.
            uint32 occupancyEnd = lastUpdate + OBSERVATION_BLOCKS;
            uint32 dueEnd = nowBlock + C6_OFFSET_FROM_MATURITY;

            uint32 bucketEnd = dueEnd < occupancyEnd ? dueEnd : occupancyEnd;

            // Read once into memory: the loop must not re-read accumulator storage per candidate.
            // Every endpoint is derived from this PRE-ADVANCE snapshot, which is valid because the
            // tick cannot have changed inside `(lastUpdate, nowBlock)` -- a change needs a swap,
            // and a swap would have moved `lastUpdate`.
            TickAccumulatorLib.Accumulator memory snapshot = acc;

            for (uint32 m = lastUpdate + 1; m <= bucketEnd; m++) {
                _freezeDueEndpoints(id, m, snapshot, lastUpdate, nowBlock);
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

    /// @notice Writes the provisional header for a bond, in `_beforeSwap`, for BOTH swap kinds.
    ///
    /// @dev ADR-0004 § 3. Everything knowable before the pool executes is written here — which is
    ///      everything except `variableLegAmount` and `tickAfter`, and both of those live in
    ///      slot 1. So this pays the two cold SSTOREs in the callback with the larger spare budget
    ///      and leaves `_afterSwap`, which must also move tokens, a single warm update.
    ///
    ///      This record is NOT a bond. Until `_finalizeBond` runs it is invisible to every
    ///      protocol path: `pendingBonds` is untouched, `getBond` reports it absent, and no claim,
    ///      refund right, slash liability or maturity obligation exists. ADR-0004 Rule 1.
    ///
    ///      If the transaction reverts for any reason, this write reverts with it.
    ///
    /// @param id Pool the swap is running against.
    /// @param provisionalCollateralIsCurrency0 The collateral-currency flag as the DIRECTION alone
    ///        implies it. It is provisional because the swap KIND also decides — exact-input bonds
    ///        in the output, exact-output in the input — and the kind is only acted on at
    ///        finalization, which corrects this flag. Never observable in between (Rule 1).
    /// @param refundRecipient Refund owner from already-validated hookData.
    /// @param tickBefore Pool tick immediately before the swap: the displacement's zero, and the
    ///        baseline every Model L2 late window is measured against.
    /// @return bondId Identifier the finalize or clear step will use.
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
            // Written at finalization, once the realized ticks and the block latch are known. A
            // provisional record is invisible to every protocol path (ADR-0004 Rule 1), so the
            // intermediate zero is never observable.
            collateralBps: 0,
            collateralIsCurrency0: provisionalCollateralIsCurrency0,
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
    /// @param variableLegAmount Realized variable leg to record: the output for exact-input,
    ///        the pool input for exact-output. The collateral is DERIVED from it and the two
    ///        stored ticks, never stored alongside it (ADR-0005 s3.2).
    /// @param tickAfter Pool tick immediately after the swap.
    /// @param collateralBps The EFFECTIVE rate custody charged (ADR-0008 § 6). Safe to narrow to
    ///        `uint16`: `_effectiveCollateralBps` caps at `MAX_BOND_BPS == 100`.
    function _finalizeBond(PoolId id, bytes32 bondId, uint128 variableLegAmount, int24 tickAfter, uint16 collateralBps)
        private
    {
        Bond storage bond = bonds[bondId];

        bond.variableLegAmount = variableLegAmount;
        bond.tickAfter = tickAfter;
        // ADR-0008 § 6. Same slot, same warm write as the two fields above it: no extra SSTORE.
        // This is the rate custody is about to take tokens at, so settlement recomputing anything
        // else would be a second source of truth for an amount that has already moved.
        bond.collateralBps = collateralBps;
        bond.state = BondState.FINALIZED;

        uint32 maturityBlock = bond.maturityBlock;

        // Registration. Only now does a maturity obligation exist.
        maturity[id][maturityBlock].pendingBonds += 1;

        emit BondOpened(bondId, id, bond.refundRecipient, variableLegAmount, maturityBlock);
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
    /// @notice The Model L2 settlement calculation for one bond.
    ///
    /// @dev SPLIT OUT OF `_settleBond` FOR THE STACK, not for style. Resolving three endpoints and
    ///      carrying a collateral rate alongside the four results puts `_settleBond` past the EVM
    ///      stack limit under this project's non-viaIR settings. Keeping `c6`, `c8`, `c10` and
    ///      `collateralBps` inside their own frame means they are dead by the time the caller
    ///      performs its effects.
    ///
    ///      ALL THREE ENDPOINTS NOW, which is what P-L2-5 deliberately deferred. That stage
    ///      migrated checkpoint STATE and left settlement reading C10 alone, because the curve it
    ///      still ran took a single maturity reading. Model L2 needs two late windows, so it needs
    ///      C6 and C8 as well. Each resolves independently: a frozen endpoint is read, an unfrozen
    ///      but still-derivable one is derived exactly and frozen, and one the cursor has passed
    ///      without a stored value reverts naming the EARLIEST endpoint actually lost. All three
    ///      come out of a single already-loaded slot (ADR-0007), so the extra readings cost
    ///      arithmetic rather than SLOADs.
    ///
    ///      `PersistenceMathLib` is not reachable from here, or from anywhere else in this
    ///      contract. P-L2-7 deletes it; leaving dead Model B behaviour CALLABLE would be worse
    ///      than leaving it present but unreferenced.
    ///
    /// @param bondId Bond being settled, for the resolver's revert diagnostics.
    /// @param id Pool the bond belongs to.
    /// @param bond Storage pointer to the record.
    /// @param maturityBlock The bond's maturity, `M`.
    function _computeL2Settlement(bytes32 bondId, PoolId id, Bond storage bond, uint32 maturityBlock)
        private
        returns (uint128 collateral, uint128 slash, uint128 refund, uint16 slashBps)
    {
        (int56 c6, int56 c8, int56 c10) = resolveEndpoints(bondId, id, maturityBlock);

        int24 tickBefore = bond.tickBefore;
        int24 tickAfter = bond.tickAfter;

        // THE RATE CUSTODY ACTUALLY CHARGED, read from the record (ADR-0008 § 6).
        //
        // Before ADR-0008 this was recomputed from the two ticks, and reproduced the physically
        // taken amount by construction because the rate was a pure function of them. The effective
        // rate now also depends on `blockStartTick` -- per-pool state that later blocks overwrite
        // -- so recomputation is no longer possible even in principle, and the record carries the
        // rate instead. ADR-0005 § 3.2's requirement is unchanged: settlement must reproduce the
        // amount physically taken to the wei. Only the mechanism for meeting it moved.
        uint256 collateralBps = uint256(bond.collateralBps);

        // MODEL L2: two direction-aligned late windows, the larger clamped at zero, the D = 5
        // catch-up dead zone, and a token split whose denominator is the VARIABLE LEG rather than
        // the collateral. `refund` comes back derived by subtraction, which is what makes
        // INV-L2-3 exact rather than approximate.
        return ModelL2SettlementLib.settle(bond.variableLegAmount, collateralBps, tickBefore, tickAfter, c6, c8, c10);
    }

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

        (uint128 collateral, uint128 slash, uint128 refund, uint16 slashBps) =
            _computeL2Settlement(bondId, id, bond, maturityBlock);

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

        emit BondSettled(bondId, id, refundRecipient, currency, collateral, refund, slash, slashBps);

        // ---- INTERACTION, last ----

        if (refund > 0) {
            currency.transfer(refundRecipient, refund);
        }
    }

    /// @notice Freezes whichever of one bucket's three endpoints have just become due.
    ///
    /// @dev THE THREE GUARANTEES (ADR-0007 section 3.3), each of which is a test in
    ///      `test/MaturityCheckpoints.t.sol`:
    ///
    ///      1. IT NEVER CREATES A BUCKET. `pendingBonds == 0` returns before any write. This is
    ///         not a mere optimisation: the loop writes into buckets AHEAD of the accumulator
    ///         cursor, so without this guard a scan could conjure a maturity cohort for a bond
    ///         that never existed, and `pendingBonds` is the sole occupancy signal (ADR-0004
    ///         Rule 3) that everything else keys off.
    ///
    ///      2. IT NEVER REWRITES AND NEVER REACHES BACK. A set mask bit is final. An endpoint at
    ///         or below `lastUpdate` is SKIPPED rather than recomputed -- below `lastUpdate` the
    ///         accumulator cannot answer and `cumulativeAt` would revert rather than guess.
    ///
    ///      3. ONE EVENT PER BUCKET, emitted when the MATURITY endpoint freezes. The two interior
    ///         freezes are deliberately silent: three events per bucket measured as the single
    ///         largest avoidable cost in the scheduler.
    ///
    ///      WHY FORWARD WRITES ARE SAFE. Writing bucket `m` while the cursor sits at `lastUpdate`
    ///      can reach up to four blocks past `nowBlock`. That bucket needs a bond opened at
    ///      `m - OBSERVATION_BLOCKS`, which is strictly in the past. A bond cannot be registered
    ///      for a maturity whose C6 has already been scanned, because registration happens in the
    ///      bond's own opening block and that block is six blocks before its own C6. Combined with
    ///      guarantee (1), a forward write can only ever land on a cohort that already exists, and
    ///      a bond opening later cannot inherit anything.
    ///
    ///      THE MASK IS WRITTEN ONCE, after all three checks, so a bucket that freezes two
    ///      endpoints in one advancement pays one mask write rather than two.
    ///
    /// @param id Pool the bucket belongs to.
    /// @param m Candidate maturity block, i.e. the bucket's key.
    /// @param snapshot PRE-ADVANCE accumulator state; the only valid source for these values.
    /// @param lastUpdate Cursor before this advancement. Endpoints at or below it are not ours.
    /// @param nowBlock Current block. Endpoints above it are not due yet.
    function _freezeDueEndpoints(
        PoolId id,
        uint32 m,
        TickAccumulatorLib.Accumulator memory snapshot,
        uint32 lastUpdate,
        uint32 nowBlock
    ) private {
        MaturityCheckpoint storage bucket = maturity[id][m];

        // GUARANTEE 1 -- occupancy first, before anything can be written.
        if (bucket.pendingBonds == 0) return;

        uint8 mask = bucket.frozenMask;

        // Nothing left to do. Checked before the endpoint arithmetic so a fully frozen bucket
        // crossed repeatedly costs one SLOAD and no more.
        if (mask == FROZEN_ALL) return;

        // `pendingBonds > 0` means a bond was registered for this bucket, so
        // `m == openBlock + OBSERVATION_BLOCKS >= OBSERVATION_BLOCKS`, and the subtractions below
        // cannot underflow. The guard is kept anyway: an underflow here would revert inside a swap
        // callback and brick the pool, which is far worse than the comparison it costs.
        if (m < C6_OFFSET_FROM_MATURITY) return;

        uint8 startingMask = mask;

        // C6 at M - 4.
        uint32 c6Block = m - C6_OFFSET_FROM_MATURITY;

        if (mask & FROZEN_C6 == 0 && c6Block > lastUpdate && c6Block <= nowBlock) {
            bucket.cumulativeMinus4 = snapshot.cumulativeAt(c6Block);
            mask |= FROZEN_C6;
        }

        // C8 at M - 2.
        uint32 c8Block = m - C8_OFFSET_FROM_MATURITY;

        if (mask & FROZEN_C8 == 0 && c8Block > lastUpdate && c8Block <= nowBlock) {
            bucket.cumulativeMinus2 = snapshot.cumulativeAt(c8Block);
            mask |= FROZEN_C8;
        }

        // C10 at M.
        if (mask & FROZEN_C10 == 0 && m > lastUpdate && m <= nowBlock) {
            int56 cumulative = snapshot.cumulativeAt(m);

            bucket.cumulativeAtM = cumulative;
            mask |= FROZEN_C10;

            // GUARANTEE 3 -- the one event, with production's existing name and signature.
            emit MaturityCheckpointed(id, m, cumulative);
        }

        // One mask write, and only if something actually changed.
        if (mask != startingMask) {
            bucket.frozenMask = mask;
        }
    }

    /// @notice Resolves ONE endpoint of a maturity bucket, freezing it if that is still possible.
    ///
    /// @dev ADR-0003 section 5.3's three cases, now applied PER ENDPOINT rather than once per bond
    ///      (ADR-0007 section 3.5). The interesting case the single-boolean design could not
    ///      express: at `lastUpdate == open+7`, C6 must already be frozen while C8 and C10 are
    ///      still exactly derivable. A per-bond flag would have had to choose one answer.
    ///
    ///      ALREADY FROZEN — the normal path. A swap crossed this endpoint and captured it.
    ///
    ///      NOT FROZEN, CURSOR STILL AT OR BEFORE IT — the quiet-pool path. Nothing has swapped
    ///      since before the endpoint, so the tick has not changed and the value is still exactly
    ///      derivable from unchanged state. Derive it, freeze it, use it. The result is identical
    ///      to what a crossing swap would have frozen, which is what lets a quiet pool settle with
    ///      no keeper and no transaction at the endpoint.
    ///
    ///      NOT FROZEN, CURSOR PAST IT — revert. The tick has moved since and the exact value is
    ///      unrecoverable. Approximating from live state would make the outcome depend on WHEN
    ///      settlement was called, which is precisely what ADR-0003's governing invariant forbids:
    ///      settlement is permissionless, so whoever picked the block would be picking the answer.
    ///      This is an upstream invariant violation (a missed NO-MISSED-Cx), not a case to paper
    ///      over.
    ///
    ///      A QUIET DERIVATION EMITS ONLY FOR C10, matching the scheduler's event policy so the
    ///      per-bucket event count is one whichever path froze it.
    ///
    /// @param bondId Bond being settled, for the revert's diagnostics.
    /// @param id Pool the bucket belongs to.
    /// @param maturityBlock The bucket key, `M`.
    /// @param endpointBlock The block whose cumulative is wanted: `M-4`, `M-2` or `M`.
    /// @param bit The `frozenMask` bit that governs this endpoint.
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

        // `cumulativeAt` enforces its own domain, so a block outside `[lastUpdate, block.number]`
        // cannot be reconstructed even by accident.
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

    /// @notice Resolves all three endpoints of a bucket, in the order that names the earliest loss.
    ///
    /// @dev NOT ON THE P-L2-5 SETTLEMENT PATH, and that is deliberate staging. Settlement still
    ///      runs the previous persistence curve, which needs C10 alone, so `settleBond` resolves
    ///      only C10 and pays for only what it uses. C6 and C8 are frozen and stored from this
    ///      stage onward so that P-L2-6 has them, but nothing consumes them economically yet.
    ///
    ///      Resolution order is C6, then C8, then C10, so a revert names the EARLIEST unrecoverable
    ///      endpoint — the one whose value is actually lost. Reporting a later one would send an
    ///      operator looking in the wrong place.
    ///
    ///      Exposed for tests and for P-L2-6. It is `public` rather than `external` only so the
    ///      settlement path could adopt it without an external call when the economics land.
    function resolveEndpoints(bytes32 bondId, PoolId id, uint32 maturityBlock)
        public
        returns (int56 c6, int56 c8, int56 c10)
    {
        c6 = _resolveEndpoint(bondId, id, maturityBlock, maturityBlock - C6_OFFSET_FROM_MATURITY, FROZEN_C6);
        c8 = _resolveEndpoint(bondId, id, maturityBlock, maturityBlock - C8_OFFSET_FROM_MATURITY, FROZEN_C8);
        c10 = _resolveEndpoint(bondId, id, maturityBlock, maturityBlock, FROZEN_C10);
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
