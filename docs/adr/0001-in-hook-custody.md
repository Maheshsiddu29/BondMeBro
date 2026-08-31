# ADR-0001 — In-hook bond custody via `beforeSwapReturnDelta`

- **Status:** Accepted
- **Date:** 2026-08-28
- **Supersedes:** the separate-router / pre-deposit custody sketch
- **Required by:** `AGENTS.md` § "Before editing" rule 5 — *"Do not change custody callback/delta
  strategy without an ADR."* This ADR is the precondition for the T3 implementation.
- **Implemented by:** T2 (hookData codec), T3 (custody path), T4 (accounting invariants),
  T5 (bond record + settle). No code lands under this ADR itself.

---

## 1. Context

BondMeBro asks high-impact swaps to post refundable collateral. For the collateral to exist,
tokens must physically move into the hook's control during the swap. Today the hook
(`src/BondMeBro.sol`) moves nothing: it has permission bits
`AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`, both swap callbacks fire, it captures
`lastTickBefore` / `lastTickAfter`, and it returns `BeforeSwapDeltaLibrary.ZERO_DELTA`.

The settlement side is finished and is **not** in scope here. `PersistenceMathLib` and
`TickAccumulatorLib` are implemented and tested (31 tests, 100% coverage, 0 Slither findings).
This ADR decides only **how the bond gets into the hook and how every token movement
reconciles**.

Two custody families were on the table, per the Full Development Guide § 14:

- **Before-swap input diversion** — part of the specified (input) amount is assigned to the hook
  through `beforeSwapReturnDelta`.
- **After-swap output withholding** — part of the realised output is assigned to the hook
  through `afterSwapReturnDelta`.

And, structurally separate from both, the design this ADR replaces:

- **Separate router / pre-deposit** — the trader sends collateral to a BondMeBro-owned router or
  vault in a prior call, and the hook reads a pre-existing deposit.

### Why this is high-risk work

Uniswap's own guidance rates `beforeSwapReturnDelta` **CRITICAL**. It is the NoOp rug-pull
vector: a hook returns a delta claiming it absorbed the entire swap and keeps the input. Our use
is legitimate — a bounded fraction taken as *refundable* collateral — but "legitimate intent" is
not a security property. § 6 turns it into an invariant that is enforced in code and proven by
test.

---

## 2. Decision

**Custody moves inside the hook, using `beforeSwapReturnDelta` on the input (specified)
currency of an exact-input, single-hop swap.**

Concretely, for a bonded swap:

1. `beforeSwap` decodes the versioned `hookData` to obtain the refund recipient.
2. It computes `bond` from the swap's own gross input (§ 3.2). A swap is bonded at all only when
   `grossInput >= minBondedAmount0` (currency0 in) or `>= minBondedAmount1` (currency1 in) — see § 3.1.
3. It calls `poolManager.take(inputCurrency, address(this), bond)`, pulling the real ERC-20 to
   the hook.
4. It returns `toBeforeSwapDelta(int128(bond), 0)` — a **positive** `deltaSpecified`.
5. v4 reduces the amount actually swapped by `bond`, and credits the hook `+bond` at the end of
   `PoolManager.swap`, netting the debt opened in step 3 to exactly zero.

The bond is therefore denominated in the **input currency**, is carved out of the trader's own
input, and never requires a second transaction, an approval to a BondMeBro contract, or a
separate router in front of the pool.

### Answers to the Full Development Guide § 14 gate questions

| # | Question | Answer |
|---|---|---|
| 1 | Which currency holds the bond? | The swap's **input currency** — `key.currency0` when `zeroForOne`, else `key.currency1`. For exact-input this is also the *specified* currency. |
| 2 | Is the user-entered amount gross spend, pool swap amount, or net output? | **Gross total spend.** `|amountSpecified|` is what leaves the trader's wallet. It is split into `bond` + pool swap amount. See § 7. |
| 3 | How is bond size known at the callback where collateral is taken? | From `|params.amountSpecified|` alone — a flat `bondBps` fraction, with the bonded/unbonded decision made by an absolute per-currency threshold in the input currency's own raw units. See § 3.1. |
| 4 | Price limit / partial fill? | Unaffected. The bond is carved out **before** the swap executes, from the gross input, so it does not depend on how much of the remainder actually fills. A swap that hits `sqrtPriceLimitX96` early still posts the full bond and still opens a bond record. Its realised impact will simply be smaller, which the settlement curve already handles. |
| 5 | Exact output? | **Not bonded.** See § 8. |
| 6 | Does the router still resolve PoolManager deltas to zero? | Yes. The trader's delta is `swapDelta - hookDelta`, and the hook's `+bond` credit is consumed by its own `take`. Both parties net to zero within the unlock. See § 4 and § 5. |
| 7 | Does actual token balance equal recorded liabilities? | That is the T4 invariant: `hookBalance >= unsettledBonds + insurancePot + claimable`, per currency, under a handler-based campaign. |

---

## 3. The bonding trigger, bond sizing, and parameter values

### 3.1 Trigger — absolute per-currency thresholds, not an impact threshold

A swap is bonded when its gross input meets the threshold **for the currency it is spending**:

```
minBondedAmount = zeroForOne ? minBondedAmount0 : minBondedAmount1
bonded          = grossInput >= minBondedAmount
```

`minBondedAmount0` is in **raw units of currency0** and applies when currency0 is the input
(`zeroForOne == true`, per `PoolManager.sol:216`). `minBondedAmount1` is in **raw units of
currency1**. Both are set per pool by the owner. Everything below the applicable threshold is
unbonded.

#### Why two thresholds — the decimals asymmetry

**A pool has two possible input currencies, with different decimals and different values, so a
single raw-unit threshold is necessarily mis-scaled in one direction.** In a USDC/WETH pool a
threshold of `1e6` means *1 USDC* when USDC is the input and *1e-12 WETH* when WETH is — six
orders of magnitude apart in value. Whichever direction the owner calibrated for, the other one
was wrong: either bonding essentially every swap, including dust, or bonding almost none.

That is not a tuning problem, it is a units problem, and it cannot be fixed by choosing a better
single number. Each direction gets its own threshold, denominated in its own currency, so both
comparisons are like-for-like. The rate (`bondBps`) stays direction-independent — a ratio needs no
per-currency scaling; only absolute quantities do.

#### Why not an impact-based trigger

**The threshold is a rationing mechanism, not a toxicity classifier. The MVP uses absolute
per-currency input thresholds rather than introducing additional liquidity or impact estimation
into the custody path.**

This is a scope decision, and worth being precise about: a projected impact threshold *is*
computable in `beforeSwap` from `getLiquidity` and `sqrtPriceX96`. We are choosing not to, for the
same reasons § 3.4 gives for sizing — it adds cost to a gas-budgeted callback and creates a second
source of truth for "impact" — not because it is impossible.

Nor would it buy accuracy. The project simulations found that trade size predicts persistent
outcomes no better than the base rate, so a threshold in projected basis points would be the same
non-predictor wearing a more scientific-looking unit. The threshold exists to do two things:

1. **Ration risk** — keep the mechanism pointed at pool-moving trades rather than every swap.
2. **Control gas** — small trades skip the decode, the `take`, and the bond-record storage write
   entirely, so they pay nothing for a mechanism that was never going to cover them.

Neither job requires the number to predict anything. Guide § 15 already frames the impact
threshold this way; this decision stops the unit from implying otherwise.

#### Consequences accepted

An absolute threshold does not self-adjust for its token's price, so each one must be set per pool
and revisited if that token's value moves materially — now two numbers to maintain per pool rather
than one. That is a real operational cost, and it is the price of keeping liquidity math off the
custody path.

`minBondedAmount1` is a `uint96`, capping it at ~7.9e28 raw units (7.9e10 tokens at 18 decimals).
This keeps `PoolConfig` in a single storage slot — `128 + 96 + 16 = 240` bits — which matters
because a second slot would add a cold SLOAD to a path where bonded exact-output `afterSwap` is
already over its gas target. The cap is far above any realistic threshold; a larger value cannot
be expressed and is rejected rather than truncated.

**A zero threshold does not disable a direction.** The comparison is `>=`, so zero bonds *every*
swap in that direction, including dust, and forces `hookData` onto all of them. `setPoolConfig`
therefore requires all three fields set, or all three zero — the latter being the disable case.
Allowing a partial configuration would make the most dangerous setting the easiest typo.

### 3.2 Sizing

```
bond = bondBps * |amountSpecified| / 10_000
```

Computed in `beforeSwap`, from the swap parameters only. No pool state is read to size it.

**Realised impact (`tickAfter - tickBefore`) is recorded in `afterSwap` and used only for the
settlement decision — never for sizing.** This is a hard separation. Sizing is an ex-ante
rationing rule; settlement is an ex-post outcome measurement. They must not share an input.

### 3.3 Parameter values

| Parameter | Value | Units | Set by |
|---|---|---|---|
| `bondBps` | **25** (0.25% of gross input) | bps | owner, per pool |
| `MAX_BOND_BPS` | **100** (1%) | bps | compile-time constant, hard cap |
| `minBondedAmount0` | per pool, no default | raw units of **currency0** | owner, per pool |
| `minBondedAmount1` | per pool, no default | raw units of **currency1**, `uint96` | owner, per pool |

`MAX_BOND_BPS` is a hard ceiling enforced in configuration validation: any attempt to set
`bondBps > MAX_BOND_BPS` reverts with a custom error. It is a compile-time constant, not an
owner-settable value, so no owner action can raise it. It is the outer guard behind INV-NOOP
(§ 6) — at 1% of gross input, `bond < |amountSpecified|` has four orders of magnitude of margin,
which is a very different safety posture from a bound that merely happens to hold.

**Provenance — stated honestly.** These are **starting points requiring empirical validation, not
measured optima.** They are derived from simulation in which the bond was roughly **25–50% of
estimated impact at a 40 bp trigger**. That simulation sized bonds off *impact*; we size off
*gross input*. The translation between the two bases is therefore **approximate**, and no
simulation was run against the gross-input formulation. Treat 25 bps as a defensible opening
value, not as a calibrated one. Live calibration is future work and should be recorded in a
follow-up ADR rather than by quietly changing the constant.

### 3.4 Rejected alternative: liquidity-derived ex-ante impact estimate

Size the bond from a projected impact computed in `beforeSwap` off `getLiquidity` and
`sqrtPriceX96` — i.e. `estimatedImpactValue = notional * projectedImpactBps / 10_000`, then
`bond = estimatedImpactValue * bondCoverageBps / 10_000`, as sketched in the Full Development
Guide § 16.

Rejected for three reasons:

1. **It buys no accuracy.** The project simulations deliberately overlapped informed and noise
   trade sizes and found that trade size predicts persistent outcomes no better than the base
   rate. A more elaborate size-derived number is a more elaborate way of being no more right.
2. **It is biased in the worst direction.** A constant-liquidity projection assumes the swap
   stays inside the current tick's liquidity. Large swaps cross into thinner liquidity, so the
   projection **understates** impact precisely on the trades the mechanism exists to cover.
3. **It is expensive and it forks the truth.** It puts liquidity math on a gas-budgeted callback
   (`beforeSwap` target < 50,000 gas, hard ceiling 150,000) and creates a *second* source of
   truth for "impact" alongside the realised `tickAfter - tickBefore`. Two impact numbers that
   can disagree is a bug surface, and reconciling them would be permanent maintenance cost.

The flat fraction is honest about what it is: § 15 of the Guide already frames the impact
threshold as a **risk-rationing and gas-control rule**, not a classifier. Sizing inherits that
framing.

---

## 4. The delta flow, traced

Read from the installed pins — v4-core `59d3ecf5` (`v4.0.0-12`), reached via
`@uniswap/v4-core/ = lib/v4-periphery/lib/v4-core/`. Nothing below is from memory.

### 4.1 What v4 actually does

`PoolManager.swap` — `src/PoolManager.sol:187`:

```solidity
(amountToSwap, beforeSwapDelta, lpFeeOverride) = key.hooks.beforeSwap(key, params, hookData);   // :202
swapDelta = _swap(pool, id, Pool.SwapParams({ ... amountSpecified: amountToSwap ... }), inputCurrency);
(swapDelta, hookDelta) = key.hooks.afterSwap(key, params, swapDelta, hookData, beforeSwapDelta); // :221
if (hookDelta != BalanceDeltaLibrary.ZERO_DELTA)
    _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));                                // :224
_accountPoolBalanceDelta(key, swapDelta, msg.sender);                                            // :226
```

`Hooks.beforeSwap` — `src/libraries/Hooks.sol:266`, only when `BEFORE_SWAP_RETURNS_DELTA_FLAG`
is set:

```solidity
int128 hookDeltaSpecified = hookReturn.getSpecifiedDelta();
if (hookDeltaSpecified != 0) {
    bool exactInput = amountToSwap < 0;
    amountToSwap += hookDeltaSpecified;                                    // :275
    if (exactInput ? amountToSwap > 0 : amountToSwap < 0)
        HookDeltaExceedsSwapAmount.selector.revertWith();                  // :277
}
```

`Hooks.afterSwap` — `src/libraries/Hooks.sol:307`:

```solidity
hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
    ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
    : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);
swapDelta = swapDelta - hookDelta;   // :312  "the caller has to pay for (or receive) the hook's delta"
```

### 4.2 Our path through it — exact-input, `zeroForOne`, `amountSpecified = -A`

| Step | Where | Effect |
|---|---|---|
| 1 | `beforeSwap` | Hook calls `take(currency0, hook, bond)`. Hook's currency0 delta becomes **−bond** (a debt). `bond` of real ERC-20 leaves PoolManager for the hook. |
| 2 | `beforeSwap` returns | `toBeforeSwapDelta(+bond, 0)`. |
| 3 | `Hooks.sol:275` | `amountToSwap = -A + bond` — **less negative**, i.e. a *smaller* exact-input swap. The bond is carved out of the input. |
| 4 | `_swap` | Pool swaps `A - bond` of currency0. `swapDelta.amount0() = -(A - bond)`, `swapDelta.amount1() = +out`. |
| 5 | `afterSwap` | Hook records ticks and opens the bond record. Returns `int128(0)` — we take nothing here. |
| 6 | `Hooks.sol:307` | `amountSpecified < 0 == zeroForOne` → `true == true` → specified maps to **amount0**. `hookDelta = toBalanceDelta(+bond, 0)`. |
| 7 | `Hooks.sol:312` | `swapDelta = swapDelta - hookDelta` → trader's amount0 becomes `-(A - bond) - bond = -A`. **The trader owes the full `A`.** |
| 8 | `PoolManager.sol:224` | `_accountPoolBalanceDelta(key, +bond, hook)` — credits the hook `+bond`, netting step 1's `−bond` to **exactly zero**. |
| 9 | `PoolManager.sol:226` | `_accountPoolBalanceDelta(key, swapDelta, msg.sender)` — the router owes `A` of currency0 and is owed `out` of currency1, and settles both. |

For `oneForZero` exact-input the same argument holds with currency1 as the specified/input
currency; step 6 takes the `false == false → true` branch, again mapping specified to the input
side.

### 4.3 Who owns every delta

| Delta | Owner | Sign | Closed by |
|---|---|---|---|
| `-bond` (input currency) | the hook | debt | the `+bond` credit at `PoolManager.sol:224` |
| `+bond` (input currency) | the hook | credit | consumed by the hook's `take` in step 1 |
| `-A` (input currency) | `msg.sender` (the router) | debt | router settles — `sync → transfer → settle` |
| `+out` (output currency) | `msg.sender` (the router) | credit | router `take`s to the trader |

The hook's net delta at the end of the unlock is **zero in both currencies**. It ends the
transaction holding `bond` more real ERC-20 than it started with, and owing the PoolManager
nothing. That is the whole point: real custody, no residual delta.

### 4.4 In-tree references we are mirroring

Both are in the installed pin, so they compile against exactly our v4-core:

- **`DeltaReturningHook`** — `lib/v4-periphery/lib/v4-core/src/test/DeltaReturningHook.sol`.
  The `beforeSwap` shape we are copying: sort specified/unspecified currency by
  `params.zeroForOne == (params.amountSpecified < 0)`, `take` when the hook's delta is positive,
  `settle` when negative, and return `toBeforeSwapDelta(deltaSpecified, deltaUnspecified)`.
  This is the direct precedent for taking inside `beforeSwap` *before* the credit exists.
- **`FeeTakingHook`** — `lib/v4-periphery/lib/v4-core/src/test/FeeTakingHook.sol`. The
  `afterSwap` variant (`manager.take(...)` then return the amount as `int128`). We are **not**
  using this path for custody, but it is the reference for the rejected output-withholding
  design in § 9.2, and for any future fee-like taking.

For the token movements themselves we use `CurrencySettler` from
`lib/uniswap-hooks/src/utils/CurrencySettler.sol` — note this is the **`src/`** copy in
uniswap-hooks, not v4-core's `test/utils/` copy. Its non-burn ERC-20 `settle` path is
`poolManager.sync(currency)` → `safeTransfer` / `safeTransferFrom` → `poolManager.settle()`,
which is the ordering `AGENTS.md` requires, and its `take` is
`poolManager.take(currency, recipient, amount)` when `claims == false`. Both early-return on
`amount == 0`.

---

## 5. How real balances reconcile

Within the swap transaction:

- PoolManager's currency0 reserve: `−bond` from the hook's `take`, then `+A` from the router's
  settle → net `+(A − bond)`, which is exactly what the pool swapped.
- The hook's currency0 balance: `+bond`.
- The trader's currency0 balance: `−A`.

Across transactions, the hook's holdings are partitioned into three named buckets, per currency:

- **`unsettledBonds`** — collateral for bond records that have not reached maturity or have not
  been settled.
- **`insurancePot`** — slashed proceeds owed to LPs.
- **`claimable`** — refunds computed at settlement and not yet withdrawn.

The T4 invariant is `hookBalance >= unsettledBonds + insurancePot + claimable`, per currency.
It is stated as `>=`, not `==`, deliberately: a donated or airdropped token balance must not
break the invariant, and `PersistenceMathLib.split` rounds the slash **down**, so rounding error
always accrues in the hook's favour and can only widen the margin. The hook can never owe out
more than it holds.

---

## 6. The NoOp risk, and the bound

### The vector

A hook with `beforeSwapReturnDelta` can return `deltaSpecified == -amountSpecified`, making
`amountToSwap == 0`. No swap occurs, the hook is credited the entire input, and the trader
receives nothing. This is the NoOp rug pull, and it is why Uniswap rates this flag CRITICAL.

### What core does and does not protect

`Hooks.sol:277` reverts with `HookDeltaExceedsSwapAmount` **only when the delta flips the swap
between exact-input and exact-output** — for exact input, only when `amountToSwap > 0`. The
boundary case `amountToSwap == 0` — the full 100% NoOp — **passes that check.** Core will not
stop it.

> **This bound is ours to enforce and ours to test.** Nothing in v4-core prevents a
> `beforeSwapReturnDelta` hook from taking a swap's entire input.

### The invariant

> **INV-NOOP.** For every bonded swap, the hook's returned `deltaSpecified` satisfies
>
> ```
> 0 < deltaSpecified < |amountSpecified|
> ```
>
> — **strictly** less than, never equal. Equivalently: `bond < |amountSpecified|`, and
> `amountToSwap` is strictly non-zero and retains the sign of `amountSpecified`.

Two things follow, and both must be true independently:

- **The hook never takes more than the computed bond.** The `take` amount and the returned
  `deltaSpecified` are the same variable, computed once. There is no path that takes one amount
  and declares another.
- **The hook never takes more than the swap's input.** `bond` is a fraction of
  `|amountSpecified|` with `bondBps < 10_000`, checked at the point of use and not merely at
  configuration time.

### How it is enforced

1. `bondBps` is bounded at configuration by the `MAX_BOND_BPS = 100` compile-time constant
   (§ 3.3), reverting with a custom error otherwise. At 1% of gross input the invariant holds
   with four orders of magnitude to spare, and no owner action can raise the ceiling.
2. `beforeSwap` re-checks `bond < |amountSpecified|` at the point of use and reverts with a
   custom error if it does not hold — a redundant check by design, because the consequence of
   the arithmetic being wrong is total loss of a trader's input.
3. `bond == 0` short-circuits to `ZERO_DELTA` and the unbonded path; a zero delta is never
   returned alongside a `take`.
4. The safe-cast to `int128` is explicit; `|amountSpecified|` is widened to `int256`/`uint256`
   before any subtraction, per the `AGENTS.md` arithmetic rule.

### How it is proven

T3 must ship, at minimum:

- a v4 integration test through `PoolSwapTest` asserting the swapper's input-currency balance
  fell by **exactly** `|amountSpecified|`, the hook's rose by **exactly** `bond`, and the
  swapper received a strictly positive output;
- a fuzz test over `(amountSpecified, bondBps)` asserting `deltaSpecified < |amountSpecified|`
  strictly, across the whole domain including `|amountSpecified| == 1`;
- a test at the `bondBps = MAX_BOND_BPS` boundary confirming the swap still executes with a
  non-zero `amountToSwap`;
- a negative test confirming a configuration that would produce `bond >= |amountSpecified|`
  reverts rather than silently NoOps.

T4 adds the stateful campaign asserting the § 5 balance invariant holds across arbitrary
interleavings.

---

## 7. Consequence for the trader — gross spend, not extra spend

**The trader's total outflow is unchanged at `|amountSpecified|`.** The bond is *not* charged on
top. It is carved out of the amount they already committed, so they receive **proportionally
less output** than the same swap would return on an unhooked pool — roughly `(1 − bondBps/10_000)`
of it, before slippage.

Stated plainly: the number the trader types is **gross total spend**, and the pool only sees
`|amountSpecified| − bond` of it. If the bond is later refunded in full, their net cost is the
same as an ordinary swap plus the time-value of the bond; if it is slashed, they paid the slash.

This is a UX fact, not an implementation detail, and it is the single most likely thing for an
integrator or a demo viewer to misread. **It belongs in the README**, not only in this ADR, and
any frontend must show gross spend and expected output as two distinct numbers. A README
subsection under "The three moments that matter" is the minimum.

---

## 8. Supported and unsupported modes

**Supported and tested:** exact-input, single-hop, ERC-20 ↔ ERC-20.

**Not supported. Documented, not implemented:**

- **Exact output.** ⚠️ **SUPERSEDED by [ADR-0002](0002-exact-output-custody.md).** Exact-output
  is now bonded, with custody in `afterSwap` via `afterSwapReturnDelta`. The reasoning below
  remains correct about why exact-output cannot use *this* ADR's `beforeSwap` path — it is
  exactly why ADR-0002 uses a different callback — but the conclusion "out of scope" no longer
  holds.
  <br><br>
  *Original text:* For `amountSpecified > 0` the specified currency is the *output* currency, so
  a positive `deltaSpecified` would take collateral out of the trader's proceeds rather than
  their input, changing which token backs the bond and inverting the § 4.2 reasoning. Bonded
  exact-output is out of scope. `beforeSwap` treats an exact-output swap as **unbonded** and
  returns `ZERO_DELTA`; it does not revert, and it does not silently bond.
- **Multi-hop.** Each hop is a separate `swap` call with its own `hookData`; per-hop bonding has
  not been analysed and must not be claimed to work.
- **Native currency (`address(0)`).** `CurrencySettler` handles it, but the settle path differs
  (`settle{value:}`) and there are no tests. Out of scope.
- **Fee-on-transfer and other non-standard ERC-20s.** The § 5 reconciliation assumes transferred
  amount equals received amount. Untested, therefore unsupported.

Per `AGENTS.md`: do not claim any of these without dedicated tests.

---

## 9. Rejected alternatives

### 9.1 Separate router / pre-deposit — *the design this ADR replaces*

The trader deposits collateral into a BondMeBro-owned router or vault in a prior call; the hook
reads the pre-existing deposit and consumes it.

Rejected because:

1. **The bond is optional, and therefore not a bond.** Anything that lives outside the swap path
   can be bypassed by swapping through any other route to the same pool — the canonical
   `PoolSwapTest`, the Universal Router, a direct `unlock`. A collateral requirement that a
   trader can decline by changing their router is not a collateral requirement. This is the
   "Bond bypass" row of the Guide's threat table, and in-hook custody is its stated mitigation.
2. **It breaks router compatibility, which is the opposite of the intent.** A pre-deposit
   forces traders through BondMeBro's own front door, so the hook only works with a bespoke
   integration — while the in-hook path works with any router that can pass `hookData`.
3. **Two-transaction UX.** An approval and a deposit before every bonded swap, with the deposit
   stranded if the swap then reverts or is never sent.
4. **It contradicts the project's own architecture rule.** Guide § 177: *"Do not create separate
   router, keeper, oracle, and vault contracts unless an integration requirement proves they are
   necessary. The current design intentionally removed a custom BondRouter."* No such
   requirement has been proven.
5. **More contracts, more surface.** A vault holding trader funds is an independently
   attackable, independently auditable component that in-hook custody simply does not need.

### 9.2 After-swap output withholding (`afterSwapReturnDelta`)

Take the bond out of the realised output in `afterSwap`, mirroring `FeeTakingHook`.

Rejected because:

1. **It changes which token backs the bond.** Collateral would sit in the *output* currency —
   the token the trader was buying, and on a directional trade the more volatile leg. The bond's
   value would then drift with the very price move being adjudicated, coupling collateral value
   to the settlement outcome.
2. **The specified/unspecified mapping is the harder one to reason about.** `afterSwap`'s
   contribution lands in the *unspecified* delta (`Hooks.sol:305`), which is the output side for
   exact-input — workable, but the § 4.2 trace is materially less obvious, and this is code where
   obviousness is a security property.
3. **No compensating benefit at MVP scope.** Its real advantage is cleaner partial-fill
   accounting, and § 2 gate answer 4 shows we do not have a partial-fill problem: sizing from
   gross input is independent of fill.

Not rejected on merit for a future revision — recorded here so the switch, if ever made, is
deliberate and documented rather than silent. The Guide is explicit: *"Do not switch between
these silently."*

---

## 10. Missing or malformed `hookData`

Per the settled product rules in `AGENTS.md` and Guide § 11:

- The refund recipient comes **only** from versioned `hookData`. Never `sender` (normally a
  router, not the human), never `tx.origin`.
- **A bonded swap with missing or malformed `hookData` REVERTS** with a custom error. There is
  no fallback to `sender` and no silent non-refundable bond. The failure modes are distinct
  errors, not one catch-all: empty data, wrong version byte, truncated/oversized payload, and
  zero recipient.
- **An unbonded swap with empty `hookData` proceeds normally.** The decode is only reached on
  the bonded path.

The consequence is deliberate and worth stating: **a trader whose swap is large enough to bond,
but whose router cannot attach `hookData`, cannot trade on this pool.** They get a clean revert
instead of collateral they can never reclaim. That is the correct trade — an unrefundable bond
is strictly worse than a failed transaction — but it means the demo frontend must build the swap
calldata itself, and the stock Uniswap web UI will not work against a BondMeBro pool.

### Schema

The codec is a pure library with a version byte first, specified and tested in **T2**, ahead of
any custody code. Version 1 carries three fields:

| Field | Type | Purpose |
|---|---|---|
| `version` | `uint8` | Schema version. Anything other than `1` reverts with a distinct error. |
| `refundRecipient` | `address` | Who the refund is owed to. Frozen at bond creation; never re-supplied at settlement. |
| `maxBondAmount` | `uint128` | **Trader-side slippage protection for the bond.** |

### Why `maxBondAmount` exists

`bondBps` and both `minBondedAmount` thresholds are owner-settable per pool (§ 3.1, § 3.3). Between the moment a
trader is quoted a bond and the moment their transaction lands, either can change — by an owner
transaction, or simply by their transaction being reordered behind one. Without a trader-supplied
ceiling, the trader has **no on-chain guarantee about the size of the collateral they are about
to post**, and an owner (or anyone who can influence ordering around an owner's config
transaction) can front-run them into a materially larger bond than they agreed to.

`maxBondAmount` closes that. If the computed bond exceeds it, the swap **reverts**. It is exactly
analogous to a slippage limit — the trader states the worst outcome they will accept, and the
transaction fails rather than silently delivering something worse. It should be documented,
surfaced, and reasoned about as bond slippage protection, not as an obscure calldata field.

Note the direction of trust this establishes: the ceiling is supplied by the trader, in the same
calldata as the refund recipient, and is not owner-modifiable. `maxBondAmount == 0` is rejected
at decode — a zero ceiling can never be satisfied by a bonded swap, so accepting it would only
create a confusing failure at a later, more expensive point.

---

## 11. Permission bits and the mined salt

Enabling the flag changes the hook's address, because v4 encodes permissions in the low 14 bits.

| | Bits | Value |
|---|---|---|
| Today | `AFTER_INITIALIZE (1<<12)` \| `BEFORE_SWAP (1<<7)` \| `AFTER_SWAP (1<<6)` | `0x10C0` |
| After T3 | the above \| `BEFORE_SWAP_RETURNS_DELTA (1<<3)` | `0x10C8` |

`Hooks.isValidHookAddress` (`Hooks.sol:111`) requires `BEFORE_SWAP_FLAG` whenever
`BEFORE_SWAP_RETURNS_DELTA_FLAG` is set. We already have it, so the combination is valid.

Consequences:

- `src/BondMeBro.sol` — `beforeSwapReturnDelta: false` → `true`.
- **The salt must be re-mined.** `script/DeployBondMeBro.s.sol` mines at run time via
  `HookMiner.find`, so no hardcoded salt needs editing — but every previously deployed instance
  is at a now-invalid address and must be redeployed. Mining must continue to target
  `CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C` under `forge script`, and
  `address(this)` under `forge test`.
- **The bits are currently duplicated in three places** — `getHookPermissions()`, the script's
  `FLAGS`, and `test/HookWiring.t.sol:30`. Updating one and not the others mines a wrong address
  and fails at `initialize` with `HookAddressNotValid`. T3 hoists them to **one shared
  constant** that all three derive from, plus a test asserting the constant matches
  `getHookPermissions()`, so the two cannot drift.

---

## 12. Constraints this places on future work

- **`Hooks.sol:253` — the self-call skip.**
  ```solidity
  if (msg.sender == address(self)) return (amountToSwap, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
  ```
  When the hook itself is the caller of `PoolManager.swap`, `beforeSwap` is **not invoked** and
  the returned delta is forced to zero. `Hooks.afterSwap` has the matching guard. Any future
  hook-initiated action that swaps — unwinding the insurance pot, rebalancing, a
  liquidation-style close — therefore gets **no custody callback and no bond**, and must do its
  own accounting explicitly. It also means the hook cannot recursively bond its own trades, which
  is a safety property worth keeping rather than engineering around.
- **`BaseHook` in uniswap-hooks v1.2.1 has no `unlockCallback`.** Its `NotPoolManager` docstring
  mentions one, but the contract does not implement it. Any hook-initiated `poolManager.unlock`
  — which settlement and pot management may need — must implement `IUnlockCallback` and its own
  `onlyPoolManager` guard from scratch.
- **Gas budgets.** `beforeSwap` target < 50,000 / ceiling 150,000; `afterSwap` target < 30,000 /
  ceiling 100,000. In-hook custody adds a `take`, a decode, and a storage write to the swap path.
  T3 must report measured gas for both callbacks and flag any overrun rather than proceeding. No
  unbounded or bond-count-proportional loop may go on this path.
- **No arbitrary external calls in swap callbacks.** The only external calls on the custody path
  are to `poolManager` and to the pool's own currencies via `CurrencySettler`.

---

## 13. Consequences

**Positive**

- The bond is not bypassable — it is part of the swap, not a precondition to it.
- One contract. No router, vault, keeper, or oracle.
- Works with any router that can pass `hookData` through to the pool.
- Single transaction for the trader.
- The bond is denominated in the token the trader is already spending.

**Negative / accepted**

- The hook now custodies real user funds. It moves from "reads pool state" to "holds
  collateral", which is a step change in risk and is why § 6 and T4 exist.
- Traders receive less output for the same gross spend (§ 7), and this will be misread unless
  the UI is explicit.
- Any router that cannot attach `hookData` cannot execute a bonded swap on the pool (§ 10).
- Every deployed instance must be redeployed at a newly mined address (§ 11).
- `.gas-snapshot` moves, and the swap path gains gas that must stay inside budget.

---

## 14. References

All paths relative to the repository root; all line numbers against the installed pins
(v4-periphery `dce236d4`, v4-core `59d3ecf5` / `v4.0.0-12`, uniswap-hooks `acbd604c` / v1.2.1).

- `lib/v4-periphery/lib/v4-core/src/PoolManager.sol:187` — `swap`; `:202` `beforeSwap` call;
  `:221` `afterSwap` call; `:224` hook delta accounting; `:226` caller delta accounting.
- `lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol:253` — self-call skip; `:266`
  return-delta branch; `:275` `amountToSwap += hookDeltaSpecified`; `:277`
  `HookDeltaExceedsSwapAmount`; `:307` hook delta assembly; `:312` `swapDelta - hookDelta`;
  `:111` `isValidHookAddress` flag dependency.
- `lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol` — `toBeforeSwapDelta`,
  `getSpecifiedDelta`, `getUnspecifiedDelta`.
- `lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol` — `SwapParams`.
- `lib/v4-periphery/lib/v4-core/src/test/DeltaReturningHook.sol` — mirrored `beforeSwap` custody
  shape.
- `lib/v4-periphery/lib/v4-core/src/test/FeeTakingHook.sol` — `afterSwap` taking reference
  (rejected path, § 9.2).
- `lib/uniswap-hooks/src/utils/CurrencySettler.sol` — `settle` / `take`.
- `lib/uniswap-hooks/src/base/BaseHook.sol` — hook base; note the absent `unlockCallback`.
- `AGENTS.md` — custody ADR requirement, product rules, gas budgets, style, test matrix.
- `Documents/BondMeBro_Full_Development_Guide.md` § 11 (`hookData`), § 14 (custody gate),
  § 15 (impact trigger), § 16 (bond sizing).

---

## 15. Changelog

This ADR is revised in place. Amendments are recorded here rather than by superseding the
document, because the custody decision itself has not changed — only its parameters and the
trigger that gates it.

### 2026-08-28 — accepted (original)

In-hook custody via `beforeSwapReturnDelta`; separate-router / pre-deposit rejected;
`bond = bondBps × |amountSpecified|`; INV-NOOP; hookData revert semantics; permission bits
`0x10C0 → 0x10C8`.

### 2026-08-28 — amendment A: the bonding trigger is absolute, not impact-based

**Changed:** § 3 restructured into § 3.1–3.4. New § 3.1 replaces the impact-based trigger with
`minBondedAmount`, an absolute per-pool threshold in raw units of the input currency, owner-set.
(T3C later split this into `minBondedAmount0` / `minBondedAmount1` — see amendment E.)

**Why:** an `impactThresholdBps` is not computable in `beforeSwap` without the liquidity math
this ADR rejects in § 3.4 — pre-swap impact can only ever be a *projection* off `getLiquidity` and
`sqrtPriceX96`. Having rejected that for sizing, it cannot return as a trigger. And nothing is
lost by dropping it: simulation showed trade size predicts persistent outcomes no better than the
base rate, so the threshold is a **rationing and gas-control device, not a classifier**, and a
bps-denominated non-predictor is no better than a raw-units one. § 3.1 states this explicitly,
along with the accepted cost — an absolute threshold does not self-adjust for token price or
decimals and must be maintained per pool.

**Consequential edits:** § 2 gate answer 3, § 2 decision step 2.

### 2026-08-28 — amendment B: parameter values fixed

**Changed:** new § 3.3. `bondBps = 25` (0.25% of gross input); `MAX_BOND_BPS = 100` (1%) as a
compile-time hard cap enforced in config validation. § 6 enforcement point 1 updated to cite the
concrete constant.

**Provenance, recorded honestly:** derived from simulation where the bond was ≈ 25–50% of
estimated impact at a 40 bp trigger. That simulation sized bonds off *impact*; we size off *gross
input*, so the translation is **approximate** and was not itself simulated. These are **starting
points requiring empirical validation, not measured optima.** Recalibration belongs in a
follow-up ADR, not in a quiet constant change.

### 2026-08-28 — amendment C: `maxBondAmount` added to the hookData schema

**Changed:** § 10 gains a schema table and a rationale subsection. Version 1 hookData carries
`version`, `refundRecipient`, **and `maxBondAmount`**.

**Why:** `bondBps` and the `minBondedAmount` thresholds are owner-settable, so a config change or a reordering
between quote and execution can hand a trader a larger bond than they agreed to. `maxBondAmount`
is trader-supplied, not owner-modifiable, and reverts the swap when the computed bond exceeds it
— bond slippage protection, and documented as such. `maxBondAmount == 0` is rejected at decode.

**Note:** this amendment was not in the T1 review instruction; it is recorded here because T2
implements the three-field codec and § 10 would otherwise be stale the moment T2 lands.

### 2026-08-29 — amendment D: exact-output superseded by ADR-0002

**Changed:** § 8's exact-output bullet is marked superseded. Original text retained beneath the
notice, because its *reasoning* is still correct and is the direct motivation for ADR-0002.

**Why:** leaving exact-output unbonded was a bypass — the same trade phrased as exact-output
avoided collateral entirely. [ADR-0002](0002-exact-output-custody.md) closes it with a second
custody point in `afterSwap` using `afterSwapReturnDelta`, where the actual pool input is first
knowable. Exact-input custody as decided in this ADR is unchanged.

**Also changed by ADR-0002, and not restated in this document's body:** the permission bits move
from `0x10C8` to `0x10CC` (§ 11 records the T3A value), and the partial-fill wrinkle recorded in
the T3 review has still not been amended into § 2 gate answer 4 / § 7 — that remains outstanding.

### 2026-08-29 — amendment E: per-currency thresholds, and a corrected trigger rationale

**Changed:** § 3.1 rewritten. `minBondedAmount` becomes **two** fields —
`minBondedAmount0` (raw units of currency0, `uint128`) and `minBondedAmount1` (raw units of
currency1, `uint96`) — selected by `zeroForOne`. § 3.3's parameter table and § 2's gate answer 3
follow. `PoolConfig` is now `128 + 96 + 16 = 240` bits, still one slot.

**Why (the decimals asymmetry):** a pool has two possible input currencies with different decimals
and different values, so one raw-unit threshold is necessarily mis-scaled in one direction. In a
USDC/WETH pool `1e6` means 1 USDC one way and 1e-12 WETH the other — six orders of magnitude apart
in value. It is a units problem, not a tuning problem, and no single number fixes it.

**Correction, not just an addition.** The previous § 3.1 claimed an impact-based trigger "cannot"
be used because it "is not computable in `beforeSwap` without the liquidity math". **That
overstated the case.** A projected impact threshold *is* computable from `getLiquidity` and
`sqrtPriceX96`; we decline it on cost and single-source-of-truth grounds, which is a scope
decision, not an impossibility. The replacement wording is:

> The threshold is a rationing mechanism, not a toxicity classifier. The MVP uses absolute
> per-currency input thresholds rather than introducing additional liquidity or impact estimation
> into the custody path.

**Also recorded in § 3.1:** why `uint96` (single-slot packing, and the exact-output `afterSwap`
path already being over its gas target), and why a zero threshold does not disable a direction —
`>=` means zero bonds everything — hence `setPoolConfig` requiring all three fields or none.
