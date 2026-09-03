# Integrating with BondMeBro

For frontends, routers and anything else that quotes or executes swaps against a BondMeBro pool.

**Read § 1 before writing any slippage code.** The collateral rate depends on where the pool price
sat at the start of the block your transaction lands in, which you cannot know when you quote.

---

## 1. The one thing that makes this different

BondMeBro sizes collateral from **effective block impact**:

```
effectiveImpact = max( |tickAfter − tickBefore| , |tickAfter − tickAtBlockStart| )
collateralBps   = min(MAX_BOND_BPS, ceil(effectiveImpact × COLLATERAL_SCALE / 100))
```

`tickAtBlockStart` is a property of the **block your transaction is included in**, not of your
transaction. If a large trade lands ahead of you in the same block, your swap is priced against that
block's displacement — and you had no way to know that at quote time.

**Consequences:**

- A quote taken in an undisplaced block **can understate** the collateral your swap later pays.
- The collateral is nonetheless **bounded**: never more than `MAX_BOND_BPS` (1%) of your swap's
  variable leg, whatever the ordering.
- For a swap that is **first in its block**, effective impact equals that swap's own impact.
  That does not promise the execution price will equal an earlier quote.

Everything below follows from those three facts.

---

## 2. Exact input

**Collateral currency: the OUTPUT.** It is taken *out of* what you receive. Your input is untouched.

### The rule

```solidity
maxBondAmount    = type(uint128).max;
amountOutMinimum = yourAcceptableNetOutput;   // see below
```

### Why `maxBondAmount` is unbounded here, and why that is safe

Your net receipt is the realized output minus the collateral, with token amounts rounded down
when the bond is calculated. `amountOutMinimum` is checked against that final net receipt. The V4
quoter also returns net output, already reduced by the simulated collateral.

Use this minimum to state what you are willing to receive. A separate quote-based bond ceiling can
reject a swap even when its final net output meets your chosen minimum. Setting `maxBondAmount` to
`type(uint128).max` avoids that extra rejection; it does not remove the hook's 1% rate cap or the
router's net-output check. It is not protection against every kind of loss, including gas costs.

### Choosing `amountOutMinimum`

Use your **normal** slippage policy — whatever net output you are actually willing to accept. Do not
special-case this hook by picking some fixed percentage.

What you must account for is that the hook can withhold up to `MAX_BOND_BPS` of your realized output
**more than an undisplaced quote assumed**. So:

```
amountOutMinimum = quotedNetOutput × (BPS − toleranceBps) / BPS
```

where `toleranceBps` is your own budget. If you want to be insulated from the collateral term
entirely — that is, never to revert *because of block ordering alone* — set `toleranceBps` at or
above `MAX_BOND_BPS`. That is the smallest tolerance which guarantees it.

> **This does not mean "always use 1% slippage".** `MAX_BOND_BPS` is the collateral component only.
> Your real tolerance must also cover ordinary price movement between quote and execution, and for a
> volatile pair that can dominate. Add the collateral allowance to your normal budget; do not replace
> it.

### Callers without a router

If you call `PoolManager.unlock` directly, `maxBondAmount` is a collateral guard, not a substitute
for a minimum-output check. Add your own final-delta slippage check before using this path.
For the collateral ceiling:

```
maxBondAmount = legUpperBound × MAX_BOND_BPS / BPS
```

`legUpperBound` is **your** upper bound on the output you might receive, from your own execution-risk
policy. A quote-derived ceiling is **not** safe: a ceiling set at four times the undisplaced cost is
rejected behind a large same-block trade (this is covered by a test).

---

## 3. Exact output

**Collateral currency: the INPUT.** It is added *on top of* what the pool consumes:

```
totalSpend = poolInput + collateral
```

A larger collateral means a larger spend, so here a bound is genuinely required.

### The rule

Let `P` be the maximum pool input you are willing to pay, **before** refundable collateral — that is,
your ordinary price-slippage budget.

```
amountInMaximum = ceil( P × (BPS + MAX_BOND_BPS) / BPS )

maxBondAmount   = amountInMaximum × MAX_BOND_BPS / (BPS + MAX_BOND_BPS)
```

**Derive both from the constants.** Read `BPS` and `MAX_BOND_BPS` from the hook. They are frozen in
this deployment; do not replace the expressions with a hard-coded divisor or multiplier.

### Why those two expressions

Since `collateral = poolInput × bps / BPS` and `bps ≤ MAX_BOND_BPS`:

```
totalSpend = poolInput × (1 + bps/BPS) ≤ poolInput × (1 + MAX_BOND_BPS/BPS)
```

so `amountInMaximum` must carry that much headroom above `P` for the swap to survive the worst
ordering. And the two checks bind at the same moment when
`poolInput = amountInMaximum × BPS / (BPS + MAX_BOND_BPS)`, at which point the collateral is exactly
`amountInMaximum × MAX_BOND_BPS / (BPS + MAX_BOND_BPS)` — which is the `maxBondAmount` above.

This ceiling does not reject an otherwise permitted total spend: if the swap meets
`amountInMaximum` and the hook's rate cap, its bond also fits this `maxBondAmount`. This is a statement
about the amounts, not the order of errors. The hook checks its ceiling before the router checks
the final total, so do not promise which error a failing swap will return.

### Rounding

`amountInMaximum` rounds **up** — rounding down leaves the allowance a wei too tight and can reject a
swap the rule is meant to admit. `maxBondAmount` rounds **down** to the whole-token-unit ceiling
given by the expression. Keep the router's final maximum-input check in place in both cases.

---

## 4. Reference implementation

```solidity
uint256 BPS          = hook.BPS();            // 10_000
uint256 MAX_BOND_BPS = hook.MAX_BOND_BPS();   // 100

// EXACT INPUT: use this branch for an exact-input request.
{
    require(toleranceBps <= BPS);
    uint128 maxBondAmount = type(uint128).max;
    uint256 amountOutMinimum = quotedNetOutput * (BPS - toleranceBps) / BPS;
    // toleranceBps is the user's budget for ordinary price movement plus any collateral allowance.
}

// EXACT OUTPUT: use this branch for an exact-output request.
{
    uint256 P = maximumAcceptablePoolInput; // chosen BEFORE collateral, including price slippage
    require(P <= type(uint128).max);
    uint256 amountInMaximum = (P * (BPS + MAX_BOND_BPS) + BPS - 1) / BPS; // ceil
    require(amountInMaximum <= type(uint128).max); // router amount fields must fit
    uint128 maxBondAmount = uint128(amountInMaximum * MAX_BOND_BPS / (BPS + MAX_BOND_BPS));
}
```

`maxBondAmount` travels in the swap's `hookData`, alongside the refund recipient:

```solidity
bytes memory hookData = HookDataCodec.encode(refundRecipient, maxBondAmount);
```

**The refund recipient comes only from `hookData`.** It is never inferred from `msg.sender`,
`tx.origin` or the router. If you route through a contract, that contract must pass the end user's
address here or the refund goes to the wrong place.

---

## 5. Quoting

The standard `V4Quoter` works and accounts for the hook:

| kind | what the quote returns |
|---|---|
| exact input | the **net output**, already reduced by the collateral |
| exact output | the **total input**, already including the collateral |

Both are quoted **against the pool state at quote time**. Ordering and intervening swaps can change
both the collateral rate and the realized variable leg. A quote is an estimate, not a guaranteed
token ceiling. In particular, the quoter's exact-output result already includes collateral; do not
silently treat it as a quote of pool input before collateral.

---

## 6. Reading a bond back

Bond IDs are deterministic:

```solidity
bondId = keccak256(abi.encode(poolId, maturityBlock, indexInBucket));
```

where `maturityBlock = openBlock + OBSERVATION_BLOCKS` and `indexInBucket` is the bucket's
`pendingBonds` count *before* your bond incremented it. In practice you should take the ID from the
`BondOpened` event rather than recomputing it.

| you want | where to get it |
|---|---|
| bond id, pool, recipient, variable leg, maturity | `BondOpened` event |
| collateral amount taken, collateral currency | `BondTaken` event |
| collateral **rate** (bps) | `getBond(bondId).collateralBps` — see the note below |
| refund, slash, realized slash rate | `BondSettled` event |
| whether a finalized or settled bond exists | `bondExists(bondId)` |
| original collateral taken, including after settlement | `collateralAmountOf(bondId)` |
| pot balance | `insurancePot(poolId, currency)` |

`bondExists` returns true for both `FINALIZED` and `SETTLED`; false means `NONE` or `PROVISIONAL`.
For status, read `getBond(bondId).state`: `FINALIZED` is unsettled and `SETTLED` is already settled.
`getBond` rejects absent and provisional records.

`collateralAmountOf` returns `variableLegAmount * stored collateralBps / BPS`, rounded down. These
inputs are frozen in the bond, so the value stays the same after settlement. It is **not remaining
unsettled liability**. Use state to decide whether a bond is unsettled, and `BondSettled` to read its
actual refund and slash. The slash is credited to the insurance pot; this version has no LP
distribution or pot-withdrawal function.

> **Note on the collateral rate.** It is not emitted directly. From logs alone you can approximate it
> as `bond × BPS / variableLegAmount` from `BondTaken`, but that reconstruction can read one basis
> point low, because the collateral was computed with a truncating division. If you need the exact
> rate — for a UI that displays it, or for reconciliation — read `getBond(bondId).collateralBps`,
> which is the authoritative stored value.

---

## 7. Settlement

`settleBond(bondId)` is **permissionless** and can be called by anyone once `block.number >=
maturityBlock`. The settler is not paid and cannot influence the result. `settleMany(bondIds)`
handles up to `MAX_SETTLE_BATCH` (32) at once and is atomic — one bad entry reverts the batch.

Settling early reverts. Settling late gives the identical answer as settling on time, so there is no
race and no incentive to wait.

---

## 8. UI fields

**Before the trade**

| field | source |
|---|---|
| quote (net output / total input) | `V4Quoter` |
| estimated collateral, if available | raw variable leg and effective rate from a simulation of this swap; label it an estimate |
| exact-input protection | chosen `amountOutMinimum`; collateral rate is capped at 1% of realized output, not a fixed quoted token amount |
| exact-output protection | `amountInMaximum` and `maxBondAmount` derived in § 3, in input-token units |
| maturity estimate | current block + `OBSERVATION_BLOCKS` |

The standard quoter returns net output or total input, not the raw variable leg itself. An optional
collateral estimate needs the additional simulation data. Multiplying a quoted raw leg by the cap
shows a cap **at that quoted leg only**; it is not the maximum number of collateral tokens at execution.

**After the trade**

| field | source |
|---|---|
| bond id | `BondOpened` |
| original collateral taken | `collateralAmountOf(bondId)`; unchanged after settlement |
| collateral currency | `BondTaken.currency`, or `getBond(...).collateralIsCurrency0` |
| open block, maturity block | `getBond(bondId)` |
| status | `bondExists(bondId)` plus `getBond(...).state` |

**After maturity**

| field | source |
|---|---|
| settle action | `settleBond(bondId)` — anyone may call |
| refund, slash, slash rate | `BondSettled` |
| insurance-pot contribution | the `slash` field, and `insurancePot(poolId, currency)` |

### Required warning

Show any estimate separately from the actual protections the user approves. For exact input, show
the minimum net output and the cap as a percentage of realized output. For exact output, show the
approved maximum total input and the derived token bond ceiling. Explain:

> Your refundable deposit depends on how far this pool's price has already moved in the block your
> transaction lands in. That depends on transaction ordering and cannot be known in advance. It will
> never exceed 1% of the realized variable side of your trade. That realized amount can differ from
> the quote, so a quoted token estimate is not a guaranteed maximum.

Showing only the estimate invites a user to treat it as a promise. It is not one.
