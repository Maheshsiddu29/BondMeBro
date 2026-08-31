# ADR-0003 — Maturity checkpoints

- **Status:** Accepted (design). **No implementation exists.**
- **Date:** 2026-08-30
- **Builds on:** [ADR-0001](0001-in-hook-custody.md) (in-hook custody, exact-input),
  [ADR-0002](0002-exact-output-custody.md) (exact-output custody in `afterSwap`).
- **Required by:** `AGENTS.md` line 12 — *"Settlement is permissionless and uses a fixed maturity
  checkpoint; post-maturity swaps must not change the result."* This ADR specifies that checkpoint.
  Also required by `TickAccumulatorLib`'s own docstring, which defers the freeze mechanism to T5.
- **Implemented by:** T5.1 and later. **This document contains no Solidity and authorises none.**

---

## 1. The governing correctness invariant

Everything below is judged against one rule:

```
settlement at M  ==  settlement at M+1  ==  settlement at M+10,000
```

**A bond's outcome must not depend on when anyone calls `settleBond`.** Settlement is
permissionless, so the caller and the timing are adversarially chosen. If the answer moves with
the calling block, then whoever picks the block picks the answer, and the mechanism is a game
about transaction timing rather than about what the price did.

This is the reason the accumulator alone is not enough. `TickAccumulatorLib.observe()` reads the
cumulative *at the current block* — its own docstring says so, and warns that T5 must not use it
directly for settlement. A cumulative read at settlement time includes every block between
maturity and settlement, so a bond settled late measures a different window than the same bond
settled promptly. The fix is to capture the cumulative **at maturity** and never recompute it.

---

## 2. Decision

### 2.1 Maturity is fixed when the bond opens

```
maturityBlock = openBlock + observationBlocks
```

Written into the bond record at open, never recomputed. The trader knows their maturity before
the swap completes. Nothing later can move it.

### 2.2 Checkpoints are bucketed by block, not stored per bond

Bonds maturing at the same block share one checkpoint:

```
checkpoint[poolId][maturityBlock]  ->  the cumulative frozen at that block
```

The cumulative at block M is a property of **the pool**, not of any individual bond. A thousand
bonds opened in the same block mature in the same block and need **one** write between them, not
a thousand. This is what keeps the swap path free of work proportional to bond count, as
`AGENTS.md` line 41 requires.

### 2.3 Advancement splits at M, before the swap changes the tick

In `beforeSwap`, at block `C`, with the accumulator last advanced at block `L`:

1. read the stored accumulator (`lastTick`, `lastUpdate = L`, `tickCumulative`);
2. determine which maturity blocks lie in the crossing range (§ 3);
3. **for each crossed maturity `M`, compute the cumulative exactly at `M` and freeze
   `checkpoint[M]`** — using the pre-advance state, so the value is the true value at `M`;
4. advance the accumulator the rest of the way to `C`;
5. only then return, letting the pool execute and move the tick.

`afterSwap` stores the new effective tick.

**This is why no ring buffer is needed.** A v3-style observations array exists to answer "what was
the cumulative at an arbitrary past block?" — a question that requires history because the value
was never captured. Here the value at `M` is never lost, because advancement *stops at `M` first*
and writes it down. We never need to look backwards.

### 2.4 Quiet pools settle for free

If nothing swapped between `L` and `M`, the cumulative at `M` is derivable from unchanged state:

```
cumulativeAt(M) = tickCumulative + lastTick * (M - L)
```

The tick was constant across the whole interval — it can only change in a swap, and a swap would
have advanced the accumulator. So a quiet pool needs **no keeper and no transaction at M**.
Settlement can derive and freeze the checkpoint itself when it is the first interaction after
maturity (§ 5.3).

---

## 3. The scan bound — proof

This is the load-bearing argument. If it is wrong, the swap path is unbounded.

### 3.1 Setup

Let `W` be a per-pool cap on `observationBlocks`, so `observationBlocks <= W` always. Let `L` be
the block at which the accumulator was last advanced, and `C >= L` the current block.

### 3.2 Precondition — every swap advances the accumulator

**The bound depends entirely on this, and it is not automatic.** `TickAccumulatorLib`'s docstring
already states it as a requirement:

> This function must be called for every swap in the pool, including swaps that do not post a
> bond.

The library requires it for *accuracy* (a gap biases every window spanning it). The scan bound
requires it for *termination*. Any code path that swaps without advancing the accumulator breaks
both. The pool's own initialisation must also seed the accumulator, so `L` is well-defined from
the first block onward rather than sitting at the `lastUpdate == 0` first-touch sentinel.

### 3.3 Claim

At a swap at block `C`, every maturity block that is both **uncheckpointed** and **already
matured** lies in:

```
(L, min(C, L + W)]
```

### 3.4 Proof

**Lower bound — nothing at or below `L` is still uncheckpointed.**
By induction on advancements. The accumulator was advanced to `L`, and by step 3 of § 2.3 that
advancement froze every maturity it crossed. So every `M <= L` was checkpointed at or before that
advancement. The base case is pool initialisation, at which `L` is the init block and no bonds
exist.

**Upper bound from the present — nothing above `C` has matured.**
A maturity `M > C` has not been reached. It is not crossed and must not be frozen.

So candidates lie in `(L, C]`.

**Upper bound from `W` — nothing above `L + W` can exist yet.**
Take any uncheckpointed bond, opened at block `b`. Opening a bond requires a swap. By § 3.2 that
swap advanced the accumulator, setting the last-advanced block to `b`. Since `L` is the *last*
such block:

```
b <= L
```

And since maturity is fixed at open with `observationBlocks <= W`:

```
M = b + observationBlocks  <=  L + W
```

Combining: `M ∈ (L, min(C, L + W)]`. **∎**

### 3.5 What this does and does not prove

It proves the number of maturity blocks a swap must consider is **at most `W`**, independent of
how many bonds exist, how long the pool was quiet, or how far `C` is from `L`.

It does **not** prove the gas cost is acceptable. See § 6.

### 3.6 Long quiet gaps

If `C - L >> W`, the range is `(L, L + W]` — the `min` binds. The implementation inspects at most
`W` buckets and then advances to `C` in one step.

**The implementation must never iterate from `L` to `C`.** A pool quiet for a month must cost the
same as a pool quiet for `W` blocks.

**A long gap does not license skipping the scan.** This is the trap worth naming explicitly:
"nothing happened for a month, so there is nothing to do" is false. Bonds opened at or before `L`
may have maturities anywhere in `(L, L + W]`, all of them still unfrozen, and every one must be
frozen **before this swap moves the tick** — otherwise their windows would silently absorb a price
move that happened after they matured, which is precisely the invariant in § 1.

An O(1) skip is legitimate **only** when explicit pool state proves there are no uncheckpointed
buckets in the range. Absence of recent activity is not such a proof. See § 7 for the candidate
metadata, which is an optimisation to be measured, not part of the correctness argument.

---

## 4. Bucket lifecycle — three states, not one flag

**A pending bond and a pending maturity checkpoint are different things, and conflating them is
the likeliest way to get this wrong.** A bond can sit unsettled for 10,000 blocks after its
checkpoint is frozen. Conversely, after a quiet period a bond can be *mature* and still need its
checkpoint frozen before the next price-changing swap. Neither state implies the other.

```
registered    — a maturity block exists and bonds point at it;
                the cumulative has NOT been written
       |
       v
checkpointed  — the cumulative at M is written and IMMUTABLE
       |
       v
settled       — an individual bond's liability is resolved
                (per bond, not per bucket)
```

`registered → checkpointed` is a property of the **bucket**. `settled` is a property of a
**bond**. The bucket does not become "settled"; its bonds do, one at a time.

---

## 5. Lifecycle rules

### 5.1 Registration — when a bond opens

Increment `pendingBonds` for the bond's fixed `maturityBlock`.

- Registration **does not write the maturity cumulative.** At open, `M` is in the future and its
  cumulative is not yet determined.
- Registration **must never overwrite a frozen checkpoint** or clear the frozen flag. A bond can
  open at block `b` for a maturity `M` that — in a degenerate configuration where
  `observationBlocks` is very small relative to a long quiet gap — has already been frozen in the
  same transaction's advancement. Registration touches only the counter.

### 5.2 Checkpoint — when advancement crosses M

Write the cumulative at `M`, set the frozen flag, **once**.

- **Once frozen, immutable.** No later swap, settlement, configuration change or owner action may
  modify it. This is the invariant of § 1 expressed as a storage rule.
- A bucket with no registered bonds may be skipped without freezing — there is nothing to settle
  against it. (Whether the implementation can *cheaply know* it is empty is § 6/§ 7's problem, not
  a correctness question.)

### 5.3 Settlement — `settleBond`

Read the already-frozen checkpoint and compute.

- If settlement is the **first interaction after maturity** and no swap has intervened, settlement
  may derive the cumulative at `M` from unchanged accumulator state (§ 2.4) and freeze it before
  calculating. This is the quiet-pool path. The derived value is identical to what an intervening
  swap would have frozen, because the tick did not change.
- **Settlement delay must never change the cumulative used.** Settling at `M + 10,000` reads the
  same frozen value as settling at `M`.
- `pendingBonds` may be decremented as bonds settle, if it is used for cleanup.

### 5.4 Deletion — decision: **do not delete**

**Empty settled buckets are never deleted in the MVP.** Checkpoints are permanent.

The reasoning is asymmetric risk, not gas:

- **The saving is small and lands in the wrong place.** A storage refund is capped
  (post-EIP-3529, 4,800 per cleared slot, and at most 20% of the transaction's gas) and would
  accrue on the `settleBond` path. The gas problem this ADR actually has is on the **swap** path,
  which deletion does not help at all.
- **The cost of being wrong is unbounded.** Deleting on `pendingBonds == 0` trusts the counter
  completely. If any bond is ever registered without incrementing it, or double-decremented on
  settle, the bucket is deleted while a live bond still points at it — and that bond permanently
  loses its settlement input. Making the checkpoint permanent removes that entire failure class
  for a saving we do not need.

**If deletion is ever added**, it must satisfy: gated on `checkpointed == true && pendingBonds == 0`;
it may clear only `pendingBonds`; and it must **never** clear the cumulative or the frozen flag,
or an equivalent tombstone must remain, so that no unsettled bond can lose access to its maturity
checkpoint. That would need its own amendment.

---

## 6. Storage shape

### 6.1 Proposed

```solidity
mapping(PoolId => mapping(uint32 => MaturityCheckpoint)) internal maturity;

struct MaturityCheckpoint {
    int56  cumulative;    // tick-blocks, frozen at M; matches TickAccumulatorLib
    uint32 pendingBonds;  // registered-but-unsettled bonds for this maturity block
    bool   checkpointed;  // the cumulative at M has been permanently written
}
```

Two revisions from the brief's starting point, both deliberate.

### 6.2 Cumulative width — `int56`, not `int128`

**Match the installed accumulator exactly.** `TickAccumulatorLib.Accumulator.tickCumulative` is
`int56`. The checkpoint stores a snapshot of that same quantity, in the same unit (tick-blocks).

Widening to `int128` would be false comfort: the value's *source* is `int56`, so it overflows
there first. A wider field records an already-wrong number more precisely, and introduces a
narrow↔wide cast on the settlement path for no benefit.

**Overflow horizon.** `int56` maxes at `2^55 - 1 ≈ 3.60e16`. The Uniswap tick bound is
`|tick| <= 887,272 ≈ 8.87e5`. Sustained at the extreme tick:

```
3.60e16 / 8.87e5  ≈  4.06e10 blocks
```

≈ 15,400 years at 12 s/block, ≈ 2,570 years at 2 s/block. This matches the horizon the library's
own docstring already states, which is the point — one number, one place.

### 6.3 Key width — `uint32`, not `uint40`

`TickAccumulatorLib.Accumulator.lastUpdate` is `uint32` and the library does
`uint32(block.number)`. A `uint40` maturity key would advertise a block range the accumulator
cannot represent: past block `2^32`, `lastUpdate` truncates and the accumulator is broken long
before the key width matters.

Mapping key width costs nothing either way — keys are hashed to 32 bytes regardless — so this is
purely about not implying unsupported range. **`uint32` is the honest width.**

Horizon: `2^32 - 1 = 4,294,967,295` blocks ≈ 1,634 years at 12 s, ≈ 272 years at 2 s. This limit
is **inherited from the installed accumulator, not introduced here**, and is recorded rather than
fixed.

### 6.4 Naming

`checkpointed` (or `frozen`), never `initialized`. The boolean means exactly one thing: *the
maturity cumulative has been permanently written*. It must not be overloaded to mean "this bucket
exists", "bonds are registered here", or "everything settled" — those are the other two states in
§ 4 and are tracked separately (`pendingBonds`, and per-bond settlement state).

### 6.5 Packing and slot count

```
int56   cumulative     7 bytes
uint32  pendingBonds   4 bytes
bool    checkpointed   1 byte
-----------------------------
                      12 bytes  =  96 bits  ->  ONE slot, 20 bytes spare
```

**One slot per maturity bucket.** The spare 20 bytes are deliberate headroom; any future field
must fit within them or this section must be revisited, because a second slot doubles the cold
read cost of the scan in § 6/§ 7 — the exact cost that sets `W`.

`pendingBonds` as `uint32` caps at ~4.29e9 bonds sharing one maturity block. Reaching it would
require ~4.29e9 swaps in a single block.

---

## 7. The gas question — OPEN, and it is the deciding one

**§ 3 proves `work <= W`. It does not prove `gas < ceiling`. `W` is not chosen in this ADR.**

### 7.1 Why this is the real risk

The § 2.3 design inspects maturity buckets **per block** across the crossing range. Most of those
buckets are empty. An empty bucket still costs a cold `SLOAD` (2,100 gas) to discover it is empty.

An a-priori estimate — **an estimate to be replaced by measurement, not a result**:

| `W` | worst-case empty cold reads | vs 150,000 `beforeSwap` ceiling |
|---:|---:|---|
| 10 | ~21,000 | comfortable |
| 20 | ~42,000 | workable |
| 32 | ~67,200 | tight against exact-input bonded (43,965 today) |
| 50 | ~105,000 | over, once existing cost is added |
| 100 | ~210,000 | **exceeds the ceiling on its own** |

Today's worst `beforeSwap` is exact-input bonded at **43,965**, leaving ~106,000 of headroom —
roughly **50 empty cold reads** before the ceiling, with no margin.

**The blunt reading: the per-block scan is viable for `W` in the low tens of blocks.** If the
product wants an observation window of hundreds or thousands of blocks, the § 9 fallback — or the
§ 7.3 metadata — is likely required. That is a finding to confirm by measurement, and it is why
`W` is deliberately left unset here.

### 7.2 Required benchmarks before `W` is chosen

The implementation task must measure, on the swap path:

1. **Zero crossed maturities** — the common case, and the one that must stay cheap.
2. **One occupied crossed maturity** — the marginal cost of an actual freeze.
3. **`W` scanned buckets, zero occupied** — the empty-scan worst case.
4. **`W` scanned buckets, many occupied** — the write-heavy worst case.
5. **A long quiet gap, `C - L >> W`** — proving work stays capped at `W` and does not scale with
   `C - L`.
6. **If a § 7.3 fast path is introduced:** the same long-gap case using it, measured separately.

**Empty-bucket read cost must be reported separately from occupied-bucket write cost.** They scale
differently and they answer different questions: cheap empty reads make a larger `W` affordable;
expensive ones force `W` small. **That measurement sets `W`.**

### 7.3 The optional fast path — named, not adopted

The § 3.6 escape hatch requires explicit state proving the range is clear. One candidate, recorded
so the implementation does not have to invent it under time pressure:

**Maturities are generated in non-decreasing order.** With a fixed `observationBlocks`,
`maturityBlock = openBlock + observationBlocks`, and `openBlock` is non-decreasing across bonds.
So the set of registered maturities behaves as a **FIFO queue**, and advancement can pop from the
front while `front <= min(C, L + W)` — making work proportional to **occupied** buckets crossed
rather than to `W`.

Three caveats, all disqualifying if unmet:

- **It requires `observationBlocks` to be effectively fixed per pool.** If the owner may lower it,
  a later bond can mature *before* an earlier one and the ordering assumption fails silently.
  Adopting this makes `observationBlocks` immutable-per-pool, or restricted to non-decreasing
  changes — a product constraint, not just an implementation detail.
- **It costs writes on the bond-open path** (queue tail, and possibly head) to save reads on the
  swap path. That trade must be measured, not assumed.
- **It is an optimisation layered on § 3, not a replacement for it.** The correctness argument
  stays the per-block bound; the queue is a way to skip provably-empty blocks within it. If the
  queue and the bound ever disagree, the bound is right.

Not adopted here. Benchmark 6 in § 7.2 exists to price it.

---

## 8. Recovered headroom — today's numbers are not the T5 baseline

### 8.1 The diagnostic globals are going away

`lastTickBefore` and `lastTickAfter` (`src/BondMeBro.sol:102-103`) are diagnostic globals. The
contract's own comment calls them debug information. **Real accumulator state replaces them** —
`Accumulator.lastTick` is the effective tick, carrying strictly more information, and the
accumulator is the thing settlement actually reads.

The T3B trace attributed **~20,000 gas** to the `lastTickAfter` cold `SSTORE` on bonded
exact-output `afterSwap`.

**Therefore: the current 60,199 figure for bonded exact-output `afterSwap` is NOT the T5
baseline.** Comparing T5's cost against 60,199 would overstate the regression by roughly the cost
of a write that T5 removes. The true equation is only knowable after those writes are gone, and
the implementation must re-baseline before drawing any conclusion about whether checkpointing
"made things worse".

### 8.2 The headroom is in `beforeSwap`, where the work goes

Checkpoint advancement **must** happen in `beforeSwap` — before the swap moves the tick (§ 2.3).
That is fortunate, because that is where the room is.

Current measured costs (T3C):

| Path | `beforeSwap` | ceiling 150,000 | `afterSwap` | ceiling 100,000 |
|---|---:|---:|---:|---:|
| exact-input bonded | 43,965 | ~106,000 spare | 25,171 | ~75,000 spare |
| exact-input unbonded | 9,883 | ~140,000 spare | 25,171 | — |
| exact-output unbonded | 10,305 | ~140,000 spare | 27,389 | — |
| exact-output bonded | **10,305** | **~140,000 spare** | **60,199** | ~40,000 spare |

The path under most pressure on `afterSwap` (bonded exact-output, 60,199) is the path with the
**most** `beforeSwap` headroom (10,305). Advancement lands where the room is. This is a genuine
structural fit, not a coincidence to rely on blindly — § 7.2 still has to prove it.

---

## 9. Approved fallback — stride-rounded maturity

If the exact-bucket design fails its measured gas gate (§ 10), fall back to:

```
baseMaturity = openBlock + observationBlocks
maturity     = ceil(baseMaturity / CHECKPOINT_STRIDE) * CHECKPOINT_STRIDE
```

Maturities collapse onto a lattice, so the number of distinct buckets in any range falls by a
factor of `CHECKPOINT_STRIDE` and the scan shortens proportionally.

**The governing invariant still holds.** Maturity is still computed and fixed **at open**, so the
trader knows it before the swap completes and no settlement-time input affects it.

**The cost is economic, not correctness.** The observation window becomes a range rather than a
constant:

```
observationBlocks  ..  observationBlocks + CHECKPOINT_STRIDE - 1
```

Two bonds opened one block apart may get windows differing by up to `CHECKPOINT_STRIDE - 1`
blocks, so identical trades can receive slightly different settlement references. That is a change
to what traders are promised.

**Approved as a fallback, not as the default.** Taking it requires its own amendment recording the
measured numbers that forced it and the chosen `CHECKPOINT_STRIDE`.

---

## 10. Gas gate — stop condition for the implementation task

> **Bonded exact-output `afterSwap` must stay under 100,000 gas, and worst-case `beforeSwap`
> under 150,000 gas.**
>
> If either breaches, **the implementation stops** and switches to the § 9 fallback under a new
> amendment. It does not raise the ceiling, does not partially implement, and does not proceed
> while over.

These are the `AGENTS.md` hard ceilings, not the targets. The targets (50,000 / 30,000) are
reported, and bonded exact-output `afterSwap` is already over its target today — that is a known,
recorded condition from T3B, not a new one introduced here.

---

## 11. Rejected

### 11.1 Settlement-time dilution

Computing the average over `[open, settlementBlock]` and scaling by elapsed time.

**Breaks § 1 outright.** The window is chosen by whoever calls `settleBond`. A trader whose price
move persisted can wait for the pool to drift back and settle into a favourable average; an
adversary can settle a competitor's bond at a chosen moment. It converts an outcome measurement
into a timing game, and permissionless settlement hands the timing to anyone.

### 11.2 Measuring from open until whenever `settleBond` is called

The same defect stated without the scaling. `TickAccumulatorLib.observe()` is documented as
current-block-only precisely to stop this, and `twaTick`'s NatSpec says `cumulativeNow` "should be
the fixed maturity checkpoint, not an arbitrarily late settlement reading."

Both also violate `AGENTS.md` line 12: *"post-maturity swaps must not change the result."*

---

## 12. Quiet pools — recorded design, unchanged

If nobody swaps during the observation window, extrapolation holds the last tick across the whole
interval, so the TWA equals `tickAfter` and **the bond fully slashes**.

That is the correct answer under the thesis, not an error: the price moved and nobody found it
worth moving back. The LP ate the adverse selection.

**No auto-refund branch.** "No swap occurred, therefore refund" would be a free, grindable exit —
and cheapest in exactly the thin pools this mechanism exists to protect. `AGENTS.md` line 10 makes
this non-negotiable, and `TickAccumulatorLib`'s docstring already implements the extrapolation
that makes a quiet pool produce a valid observation rather than missing data.

---

## 13. Impact on `TickAccumulatorLib`

**No behavioural change is required. `update()`, `observe()` and `twaTick()` keep their current
semantics exactly.** This was checked against the installed source, not assumed.

### 13.1 The two-phase update already works

The § 2.3 split needs the accumulator advanced in `beforeSwap` *without* changing the tick, then
the tick set in `afterSwap`. The existing single-function `update(acc, newTick)` expresses both:

- **`beforeSwap` at `C`:** call `update(acc, acc.lastTick)`. Elapsed is `C - L`; the cumulative is
  credited at `lastTick` — the tick genuinely live over that interval — and `lastTick` is
  rewritten to itself. `lastUpdate` becomes `C`.
- **`afterSwap` at `C`:** call `update(acc, tickAfter)`. Elapsed is now `C - C = 0`, so nothing is
  credited, and `lastTick` becomes `tickAfter`.

Both phases fall out of the existing implementation. No new library function is needed for the
advancement itself.

### 13.2 The freeze needs arithmetic the library already implies

```
cumulativeAt(M) = acc.tickCumulative + acc.lastTick * (M - acc.lastUpdate)
```

evaluated **before** the `beforeSwap` advancement, while `lastUpdate` is still `L`. Valid because
`L < M <= C` and the tick cannot have changed inside `(L, C)` — a change requires a swap, and a
swap would have advanced `lastUpdate`.

This is exactly `observe()`'s formula with `M` substituted for `block.number`. It can live in the
hook with no library change at all.

### 13.3 The one authorised, optional addition

The library's docstring says changes need an ADR. **This ADR authorises exactly one optional,
additive change and nothing else:**

> a pure helper `cumulativeAt(Accumulator memory acc, uint32 atBlock) internal pure returns (int56)`,
> of which `observe(acc)` is the special case `atBlock == block.number`.

It is additive, changes no existing behaviour, and merely puts the § 13.2 formula next to the
`observe()` it generalises rather than duplicating it in the hook. **It is optional** — the
implementation may skip it. Any change beyond this requires a further amendment.

### 13.4 What the library still requires of the caller

The § 3.2 precondition is now a **correctness** requirement, not only an accuracy one: every swap
must advance the accumulator, and pool initialisation must seed it. The library cannot enforce
this; the hook must, and the implementation task must test it.

---

## 14. Consequences

**Positive**

- Settlement is timing-independent, satisfying § 1 and `AGENTS.md` line 12.
- Work per swap is bounded by `W`, independent of bond count, matching `AGENTS.md` line 41.
- No ring buffer, no binary search, no keeper, no oracle.
- Quiet pools cost nothing extra and need no transaction at maturity.
- One storage slot per maturity block, shared by every bond maturing in it.

**Negative / accepted**

- The swap path gains a bounded scan whose cost is **not yet known**, and which may force a small
  `W` or the § 9 fallback.
- A new per-pool cap `W` becomes a parameter with a gas-driven upper bound.
- Checkpoints are permanent storage that is never reclaimed (§ 5.4).
- Block-number range is capped at `uint32`, inherited from the accumulator.
- `observationBlocks` may need to be fixed-per-pool if the § 7.3 fast path is adopted.

---

## 15. What the implementation task must do

1. Remove `lastTickBefore` / `lastTickAfter`; wire `TickAccumulatorLib` into both callbacks
   (§ 13.1). **Re-baseline gas before comparing anything** (§ 8.1).
2. Ensure **every** swap advances the accumulator and initialisation seeds it (§ 3.2, § 13.4) —
   this is the scan bound's precondition and must be tested, not assumed.
3. Implement registration / checkpoint / settlement as three distinct states (§ 4, § 5).
4. Run the six benchmarks in § 7.2 and **choose `W` from the measurement**.
5. Honour the § 10 stop condition. If breached, stop and amend toward § 9.
6. Do not delete buckets (§ 5.4).

---

## 16. References

- `src/libraries/TickAccumulatorLib.sol` — `Accumulator` (`int24 lastTick`, `uint32 lastUpdate`,
  `int56 tickCumulative`), `update`, `observe`, `twaTick`, and the docstring deferring the freeze
  mechanism to T5.
- `src/BondMeBro.sol:102-103` — `lastTickBefore` / `lastTickAfter`, the diagnostic globals § 8.1
  removes. The accumulator is **not yet wired in** (zero references as of this ADR).
- `AGENTS.md` line 10 (quiet pools), line 12 (fixed maturity checkpoint), line 41 (no loops
  proportional to bond count), § Gas budgets (the § 10 ceilings).
- [ADR-0001](0001-in-hook-custody.md) § 3 — bonding trigger and sizing.
- [ADR-0002](0002-exact-output-custody.md) — exact-output custody in `afterSwap`; the source of
  the 60,199 figure § 8.1 retires.
