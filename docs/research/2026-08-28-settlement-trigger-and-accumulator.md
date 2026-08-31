# Research: settlement trigger (Problem 2) & the accumulation problem (Problem 3)

> **Historical research note:** this document records the design state before the
> settlement implementation. The current hook now includes bond records, capped
> piggyback settlement, permissionless settlement, insurance-pot accounting, and the
> truncation-aware accumulator described by the implementation README.

> Date: 2026-08-28 · Prepared overnight for tomorrow's sync (Akshay see §5)
> Scope: validate the two open design problems against the actual code, run the
> concrete calculations, and collect the prior art worth building from.
>
> **Historical note:** this document records the milestone-1 audit that preceded the
> implementation in `src/`. The verdicts below describe the starting state; the
> recommendation is now implemented by `BondMeBro` and `TickAccumulatorLib`.

---

## 0. Verdicts up front

| Claim from the notes | Verified? | Result |
|---|---|---|
| `settleBond` is an unsolved "who calls it" problem | ✅ confirmed | **No `settleBond` exists anywhere in `src/`** — the hook is a Milestone-1 skeleton (counters + tick reads only). This is a genuinely open design decision. |
| Accumulator updates only on swaps | ✅ confirmed | `TickAccumulatorLib.update()` is called from swap path only; nothing else writes it. |
| `observe()` already solves quiet-pool resolution | ✅ confirmed | Extrapolation at `lastTick` means a quiet pool TWA == `tickAfter` → full slash, **by design**. Code comments explicitly forbid adding an auto-refund escape hatch. |
| Truncation kills 1-block flash pushes; pinning resisted by window length | ✅ confirmed (see §4.1) | 20,000-tick push × 1 block over a 7,200-block window = **2.78 raw → truncates to 2–3 ticks**. Matches the "~3 ticks" simulation exactly. |
| "Worth a concrete calculation" on int56 overflow | ✅ done (see §4.3) | **Not a risk.** At the extreme tick (±887,272) held continuously, overflow needs **4.06 × 10¹⁰ blocks** — ~15,400 years on mainnet's 12s blocks, ~322 years even on a hypothetical 0.25s chain. |
| Perfect drift removal only helps modestly | ✅ consistent with code | `PersistenceMathLib` already documents drift contamination as an unfixable known limitation. Recommendation: document, don't fix (see §4.2). |

---

## 1. Problem 2 — who triggers `settleBond`, and when

### The options

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **A. Trader self-settles** | Bond owner calls `settleBond` after maturity | Simple | Funds get forgotten/stuck. **Worse: a game-theoretic hole** — if the owner picks *when* after maturity to settle, they settle at whatever TWA is most favorable to their refund ("free option"). Settlement timing must not be owner-chosen. |
| **B. Dedicated keeper bot** | Off-chain service watches matured bonds | Always timely | Breaks the project's key property: *no external dependency*. Exactly what the README is proud of avoiding. |
| **C. Piggyback on later swaps** ("lazy settlement") | Every swap first settles any matured bonds it finds | Keeperless; zero new infrastructure | (i) Unbounded loop = gas/DoS risk; (ii) unfair gas burden on the unlucky swapper; (iii) quiet pools: settlements stall until the next swap. |
| **D. Hybrid: C + permissionless call with reward** | Later swaps settle a capped prefix and the current swap's resolved owner receives a small fee; anyone may also call `settleBonds` and receive a fee taken from the bond itself (Ajna kicker / MakerDAO liquidation-incentive pattern) | Keeper**less**, not keeper-*hostile*: works with zero keepers, and both active swappers and quiet-pool settlers have an incentive. | Must size the reward: too small → no volunteers; too large → bonds bleed value. |

### Recommendation

**D** — piggyback settlement inside `_beforeSwap`, **capped at K bonds per swap** (K a small constant, e.g. 4), with the current swap's resolved owner receiving the configured share of slashes, **plus** a `settleBonds(PoolKey, maxCount)` external function anyone may call, paying the caller the same bounded percentage fee. This preserves "no external dependency" as a *safety* property (nothing breaks without a keeper) while removing the quiet-pool stall as a *liveness* concern.

### Design notes

- **Cap the loop.** Settling all matured bonds in one swap is a classic unbounded-iteration DoS. Settle oldest-first from a FIFO queue of open bonds, stop after K or when the next bond is immature (queue head check is ~1 storage read in the common case → near-zero added gas for most swaps).
- **Delayed settlement does not bias the math.** `observe()` extrapolates at `lastTick`, so settling late reads the same extension-by-stasis a quiet pool implies. The bias is one-directional (toward slash) and shrinks with window length — the documented, accepted direction.
- **Worst case analysis for piggyback gas:** one settlement ≈ TWA read (view math) + bps math + two token transfers + storage clear. Budget it concretely in the test suite; if a bond is small relative to that gas × fee, the fee floor matters.
- **Funds-stuck risk is bounded:** bonds are prepaid, so a stalled settlement never creates insolvency — only lockup. Settlement uses pull-payment fallback for rejecting owners/receivers, so one malicious callback cannot freeze the FIFO queue. That makes liveness a UX problem, not a safety problem, which is why D (opportunistic reward) is sufficient without a mandated keeper.

---

## 2. Problem 3 — the accumulation problem

### 2.0 What is already solved (don't re-solve it)

`observe()` extrapolates the open trailing interval at `lastTick`, so a pool with **zero swaps during the window resolves as TWA == `tickAfter` → full slash**. The code is explicit that this is the *correct* answer under the thesis ("the price moved and no arbitrageur found it worth reverting"), and that an "invalid reference → auto-refund" branch would be a grindable free exit, cheapest in exactly the thin pools this mechanism targets. **Status: done; add a test pinning this behavior, not a fix.**

### 2.1 Manipulation — two attacks, two defenses (validated)

The simulation split in the notes is correct, and the arithmetic checks out:

- **Attack 1 — single-block flash push.** Attacker pushes the tick P ticks for 1 block, over a window of N blocks the TWA moves by `P·1/N` and integer division truncates. With P = 20,000, N = 7,200: `20,000/7,200 = 2.78 → 2 ticks`. Below any sane `refundTol`. **Dead on arrival.**
- **Attack 2 — patient pinning.** Attacker *holds* a distorted price for b blocks: TWA moves `P·b/N`. No truncation saves you here; the defense is that holding price costs arbitrage losses every block, so window length N sets the cost floor. **Defense = window length.**

**The build (small, well-specified — matches "one clamp + one config param"):** clamp per-update tick movement in the accumulator,

```
clampedTick = clamp(newTick, lastTick ± maxAbsTickDelta)
```

so a flash push records at most `maxAbsTickDelta` per update regardless of reality. This converts a *capital* attack (huge 1-block move) into a *time* attack (many blocks), which the window already prices.

**Prior art — build from the official implementation:**

- **Uniswap v4-periphery `TruncatedOracle.sol`** — shipped in the official repo, `MAX_ABS_TICK_MOVE = 9116`, with a `transform()` doing exactly the clamp above. Hacken walkthrough: https://hacken.io/discover/uniswap-v4-truncated-oracle/
- **Uniswap Labs research** ("Uniswap v3 TWAP Oracles in Proof of Stake") derives ~9,116 as the cap forcing ≥ 30 blocks of manipulation to move a 30-min TWAP by 20%: https://blog.uniswap.org/uniswap-v3-oracles
- Rigoblock's truncated geomean oracle hook documents the same construction with multi-block safeguards: https://docs.rigoblock.com/oracles-and-price-feeds

**Param derivation (don't copy 9,116 blindly).** Choose `maxAbsTickDelta` and N such that moving the TWA by `refundTol` requires pinning for b ≥ `refundTol · N / maxAbsTickDelta` blocks — long enough that arb losses exceed any bond-refund gain. That's an inequality in terms of *our* window and *our* tolerance, not Uniswap's 30-minute-oracle numbers.

**One honest trade-off to record:** the clamp also delays *honest* violent moves (real news gapping the price). The accumulator lags → reads more "reverted" → tilts toward refunds for ~one window. Bonud that lag: `|gap| ≤ maxRealMove − maxAbsTickDelta`, recovered within `⌈move/cap⌉` blocks. One-directional, bounded, document it alongside the existing KNOWN BIAS note.

### 2.2 Drift — document, don't fix

Consistent with `PersistenceMathLib`'s own docstring: the settlement reference cannot separate *surviving impact* from *market drift*, and no pool-local math can. The only true fix is a market-wide reference = external oracle = the exact dependency class the project rejects. Combined with the simulation result that even *perfect* drift removal helps only modestly, the call is:

1. **Document** it in the README and demo script (already half-done in code comments + `test_driftDominatesSignal_KnownLimitation`).
2. Keep **window length** as the one real signal-to-noise lever (impact is instantaneous; drift accumulates with elapsed time).

### 2.3 Overflow & window length — the concrete calculation (done)

Bounds for `int56 tickCumulative` (max 2⁵⁵ − 1 ≈ 3.60 × 10¹⁶), extreme sustained tick 887,272:

| Block time | Blocks to wrap at extreme tick | Years |
|---|---|---|
| 12 s (mainnet) | 4.06 × 10¹⁰ | ~15,400 |
| 1 s (typical L2) | 4.06 × 10¹⁰ | ~1,287 |
| 0.25 s (very fast chain) | 4.06 × 10¹⁰ | ~322 |

**Conclusion: overflow is not a design constraint.** Even adversarially pinned at the maximum tick on an absurdly fast chain, first overflow is centuries out. The *useful* check instead: per-bond window accumulation `|tick| · N` is ≤ 887,272 · N — for any sane N (≤ 100k blocks) that's ≤ 8.9 × 10¹⁰, ~5 orders below int56 range.

**One real (minor) finding while doing this:** `lastUpdate` is `uint32` block numbers. Wrap horizon: 12 s → ~1,633 yrs ✅; 0.25 s chain → **~34 years** ⚠️. Fine for every chain worth targeting, but if a sub-second L2 is ever in scope, bump to `uint48`/`uint64` (slot packing: `int24 + uint48 + int56` still fits ≤ 128 bits). Cheap decision, make it now rather than after audits read it.

---

## 3. Are these *all* the problems?

Within settlement mechanics + oracle design: **yes** — these two are the genuinely open design questions, and both now have a recommended path (Problem 2 → §1 recommendation D; Problem 3 → clamp build + drift documented + overflow closed).

Everything else in the README's flow is *implementation* work, not open design: bond custody (beforeSwap delta accounting), bond-record storage layout, insurance-pot accounting and LP distribution, window-length governance, deploy/migration. Those are Phase-1-style build tasks with known answers, not research questions.

---

## 4. Open questions (good research work for Akshay)

1. **Derive `maxAbsTickDelta`** from *our* N and `refundTol` using the inequality in §2.1; validate by re-running the two-attack simulations (flash push, patient pin) against a clamped accumulator fork.
2. **Size the settler reward**: measure real settle gas in forge tests (~est. 25–40k with two transfers) and pick `min(fixed, % of bond)` so the fee clears gas × 2 even on the smallest bond we allow. Window: what bond minimum does that imply?
3. **Queue structure**: FIFO linked list vs. per-block bucket mapping for matured bonds — gas-compare head-check in `_beforeSwap` for both at 0 / 1 / 10 / 100 open bonds.
4. **Confirm the owner-time-option is closed**: settlement must trigger at first touch ≥ maturity (anyone-incentivized), never at a time the owner picks. Add a test: owner's own later swap auto-settles their matured bond.
5. **uint32 → uint48 `lastUpdate`**: confirm no packing regression; flag whether sub-second chains are in target scope at all.

---

## 5. References

1. Uniswap v3 TWAP Oracles in Proof of Stake — Uniswap Labs research (truncation proposal, 20% / 30-block / 9,116-tick derivation): https://blog.uniswap.org/uniswap-v3-oracles
2. Truncated Oracle in production — v4-periphery `TruncatedOracle.sol` walkthrough: https://hacken.io/discover/uniswap-v4-truncated-oracle/
3. Truncated geomean oracle hook, multi-block safeguards: https://docs.rigoblock.com/oracles-and-price-feeds
4. TWAP + truncated-oracle overview: https://medium.com/@regis-graptin/twap-in-defi-how-time-weighted-average-prices-protect-oracles-swaps-from-manipulation-53bcf59029fd
5. Incentivized-permissionless-settlement pattern (Ajna kicker bonds / MakerDAO liquidation incentives) — reward drawn from the position itself, never from a required keeper.
