# BondMeBro

**Refundable, outcome-linked collateral for Uniswap v4 liquidity providers.**

A swap that moves the price and leaves it moved has cost liquidity providers something. A swap whose
price impact bounces straight back has not. You cannot tell those apart at the moment of the trade —
so BondMeBro doesn't try. It takes a **refundable deposit** from large swaps, waits ten blocks, looks
at what the price actually did, and returns whatever the price did not keep.

Contract: `BondMeBro` · Built for UHI10 (Atrium Academy) · Solidity 0.8.26 · Foundry

---

## 1. What BondMeBro is

A Uniswap v4 hook. It sits on a pool, watches swaps, and for swaps large enough to matter it:

1. takes a small **refundable collateral** out of the swap,
2. records where the price was before and after,
3. ten blocks later, measures how much of that price move was still there,
4. **refunds** the collateral if the move reverted, or moves part of it into an **LP insurance pot**
   if the move stuck.

No external oracle. No keeper bot. No off-chain service. No wallet scoring. The hook reads the
pool's own price history and settles from it.

## 2. The problem

When a large swap moves the pool price, one of two things happens next:

- **The price bounces back.** The trade was noise. Nobody was really harmed.
- **The price stays there.** The trader knew something the pool didn't. They traded against LPs who
  had no way to react — this is *adverse selection*, and it quietly eats LP returns.

These look **identical at execution time**. A big trade is a big trade. The difference only shows up
afterwards. Fee-based approaches have to guess up front, so they charge everyone — including the
harmless traders — for damage only some of them cause.

## 3. Why the collateral is refundable

Because the information needed to price the trade **does not exist yet** when the trade executes.

A fee is a decision made too early. Refundable collateral defers the decision to the moment the
answer is knowable. A trader whose impact reverts gets everything back and has paid only the time
value of the collateral for ten blocks. A trader whose impact persists forfeits a part of it to the
LPs who absorbed the move.

It is closer to **insurance that prices itself after the fact** than to a fee.

## 4. Exact-input swaps — where the money comes from

For an exact-input swap you fix what you spend. So the collateral comes out of the **output**:

```
you spend       1,000 USDC     ← exactly what you asked, untouched
pool swaps      1,000 USDC     ← the whole amount hits the curve
pool returns    ~0.30 WETH
hook holds       0.00045 WETH  ← the collateral, refundable, 15 bps here
you receive     ~0.29955 WETH  ← output minus the collateral
```

**Your specified amount is never touched.** The hook does not hold the permission that would let it
change the input side of a swap at all — that is enforced by the hook's address, not by convention.

## 5. Exact-output swaps — the mirror

For an exact-output swap you fix what you receive. So the collateral comes from the **input**, added
on top:

```
you want          0.30 WETH    ← exactly what you asked, untouched
pool consumes    1,000 USDC
hook takes           1.5 USDC  ← the collateral, refundable
you spend        1,001.5 USDC  ← pool input plus the collateral
```

Either way the **specified** leg of your swap is exact, and the collateral comes from the other one.

## 6. How much — effective block impact

The collateral rate scales with how far the price moved, measured in ticks:

```
ownImpact         = |tick after − tick before|
blockDisplacement = |tick after − tick at the start of this block|

effectiveImpact   = max(ownImpact, blockDisplacement)

collateralBps     = min(100, ceil(effectiveImpact × 0.25))
collateral        = variableLeg × collateralBps / 10,000
```

So roughly **0.25 basis points of collateral per tick of price impact, capped at 1%**.

**Why the block term.** If the rate looked only at each swap's own impact, one big price move could
be split into many small same-block swaps, each posting almost nothing, while the pool ended the
block at exactly the same price. Measuring each swap against **where the block started** prices a
trade on where it left the pool, not merely on how far it personally pushed it.

**A swap that is first in its block is unaffected** — the two terms are equal, and it pays exactly
what the simpler own-impact rule would have charged. Most swaps are first in their block.

This is **pool-level and identity-free**: nothing reads the sender, the recipient, `tx.origin` or the
router, so the charge cannot be reduced by splitting a trade across addresses or transactions — only
by not moving the price.

## 7. C6 / C8 / C10 — what settlement looks at

The hook keeps a running time-weighted tick accumulator per pool. When a bond opens at block `B`, it
matures at `B + 10`, and three readings are frozen along the way:

| reading | block | what it is |
|---|---|---|
| **C6** | `B + 6` | accumulator value six blocks in |
| **C8** | `B + 8` | eight blocks in |
| **C10** | `B + 10` | at maturity |

Settlement scores only the **late** part of the window — blocks 6–7 and 8–9 — so the swap's own
opening impact is never part of what it is charged for. Two separate windows are used, and the
**larger** is taken, because a single opposing block can erase one window but not both.

Readings are frozen when they come due, so **settling early, on time, or ten thousand blocks late
gives the identical answer**.

## 8. Refund and slash

```
R        = the larger of the two late-window displacements, in the trade's own direction, clamped at 0
Q        = 0 if R ≤ 5 ;  2(R − 5) if R < 10 ;  R otherwise      ← the 5-tick dead zone
slashBps = min(collateralBps, ceil(Q × 0.25))

slash    = variableLeg × slashBps / 10,000
refund   = collateral − slash
```

- Price fully reverted → `R = 0` → **full refund**.
- Price moved back inside 5 ticks → **full refund** (the dead zone; small moves are noise).
- Price partly persisted → **partial slash**, the rest refunded.
- Price fully persisted → **slash up to the whole collateral**.

Displacement is measured **in the trade's own direction and clamped at zero**, so a price move the
*other* way can never manufacture a charge.

## 9. The LP insurance pot

Slashed collateral is credited to a per-pool, per-currency `insurancePot`. Nothing moves when a bond
is slashed — the tokens are already inside the hook; the slash just reclassifies them from "owed back
to a trader" to "retained for LPs".

**There is deliberately no withdrawal path in this version.** Distribution policy is a separate
design problem, and shipping a withdrawal before that policy exists is the easiest way to get it
wrong. Nobody — not the owner, not an LP, not a settler — can remove pot funds today.

## 10. Permissionless settlement

`settleBond(bondId)` can be called by **anyone** once the bond has matured. The settler is not paid
and gains nothing; the result is identical whoever calls it and whenever they call it. `settleMany`
settles up to 32 bonds in one transaction.

There is no privileged settler, no keeper incentive, and no way for a settler to influence the
outcome.

## 11. Supported modes

- ERC-20 ↔ ERC-20, **single-hop**
- **exact-input** and **exact-output**
- both directions (`zeroForOne` and `oneForZero`)
- multiple pools per hook deployment, including pools sharing a currency

## 12. NOT supported — and not tested

- multi-hop routes
- native ETH
- fee-on-transfer tokens
- rebasing or otherwise non-standard ERC-20s
- pools configured with `minBondedAmount` below ~1,000 raw units (see limitation F)

Do not assume these work. They have no tests and are outside the design.

## 13. Build and test

Dependencies are pinned git submodules. **Clone with them**, or the `lib/` folders come down empty
and the build fails:

```bash
git clone --recurse-submodules https://github.com/Maheshsiddu29/BondMeBro.git
cd BondMeBro
```

Already cloned without them?

```bash
git submodule update --init --recursive
```

Then:

```bash
forge build
forge test
```

The full gate CI runs:

```bash
make ci          # fmt-check, slither, build, test, coverage
```

Current state of that gate on a clean clone:

| | |
|---|---|
| tests | **461 passing**, 0 failing, 35 suites |
| stateful invariant campaign | **26 invariants**, 512 runs × depth 100 |
| Slither | **0 findings**, 102 detectors |
| coverage (`src/BondMeBro.sol`) | 99.14% lines · 86.05% branches · 100% functions |
| runtime bytecode | **15,953 bytes** (8,623 under the EIP-170 limit) |
| `beforeSwap` worst case | **107,543 gas** (limit 150,000) |
| `afterSwap` worst case | **73,999 gas** (limit 100,000) |

## 14. Demo

Three deterministic scenarios, each printing a narrated trace:

```bash
make demo                                  # all three
forge test --match-path test/Demo.t.sol -vv
```

| scenario | what it shows |
|---|---|
| **1 — benign** | collateral posted, price reverts, **full refund** |
| **2 — persistent** | collateral posted, price sticks, **slash into the insurance pot** |
| **3 — same-block split** | one move split across many swaps, priced under both rules side by side |

Deployment (to a testnet, never mainnet from this repo):

```bash
cp .env.example .env      # then fill it in
forge script script/DeployBondMeBro.s.sol --rpc-url "$RPC_URL" --broadcast
```

Uniswap v4 encodes a hook's permissions in its **address**, so this cannot be deployed with a plain
`forge create`. The script mines a CREATE2 salt until it finds an address carrying the right
permission bits. Changing the constructor arguments changes the address, so expect to re-mine.

**Integrating a frontend or router?** Read [INTEGRATION.md](./INTEGRATION.md) first — quoting and
slippage need specific handling.

## 15. Security model

**What is protected, and by what:**

| property | how |
|---|---|
| The hook cannot alter your specified amount | It does not hold `beforeSwapReturnDelta`. Enforced by the hook's address bits, not by code discipline. |
| Collateral is strictly between zero and the leg it comes from | Checked on every bonded swap; a swap that would violate it reverts. |
| Refund + slash always equals the collateral taken | Exact integer conservation, no rounding dust. |
| Pushing the price *further* can never reduce what you forfeit | The rate is non-decreasing in harmful displacement. |
| An opposite-direction move cannot manufacture a charge | Displacement is direction-aligned and clamped at zero. |
| Settlement is time-independent | Endpoints are frozen when due; post-maturity trading cannot change the answer. |
| A bond cannot be settled twice | State machine, checked before any transfer. |
| Per-swap work is bounded | The maturity scan is bounded by a fixed horizon, independent of how many bonds exist. |
| Multiple pools cannot drain each other | Solvency is tracked per currency across pools; pool state is isolated. |

**What BondMeBro does *not* claim.** It is not manipulation-proof, not MEV-proof, not split-proof,
and not audited. It does not detect or label traders, and it does not price toxicity. It is a
**pool-local LP-risk proxy**: measured price displacement over a fixed window, and nothing more.
Manipulation is demonstrably possible — the limitations below name several ways and price them.

The economic parameters (0.25 bps/tick, the 1% cap, the 5-tick dead zone, the ten-block window) were
chosen against a **synthetic simulated population**. They are **SYNTHETIC SIMULATION — NOT HISTORICAL
UNISWAP EVIDENCE.** No historical Uniswap trade was ever fetched or replayed.

## 16. Known limitations

These are real, measured, and **not solved**. They are documented rather than hidden.

**A — Two-block straddle.** The two late windows are disjoint but adjacent. A trader who moves the
real price across *both* windows for two consecutive blocks can drive the measured residual to zero
and recover the whole collateral. The cost is holding a real price displacement for two blocks,
exposed to arbitrage the whole time.

**B — Grinding under the dead zone.** Displacement built at 5 ticks or less per observation window
costs nothing, without bound. This is inherent to having a noise floor at all. Each step is a
separate swap paying fees and gas, and leaves the price exposed for a full window.

**C — The 1% cap.** Above roughly 397 ticks of impact the collateral saturates at 1% while the
harm keeps growing, so the largest persistent moves are systematically under-collateralized. LP
protection stops scaling there.

**D — Threshold splitting.** Swaps below a pool's `minBondedAmount` never bond. Splitting a large
trade into many below-threshold pieces avoids collateral entirely. The threshold is a raw-amount
ration, not a classifier, and this is the direct consequence.

**E — Same-block splitting: materially mitigated, NOT eliminated.**

> Under the earlier per-swap rule, splitting one price move into `N` same-block pieces diluted the
> collateral **without bound** — the advantage grew linearly with `N` (Θ(N)), because pieces moving
> less than a full tick bonded nothing at all.
>
> The effective-block-impact rule (§ 6) removes that unbounded behaviour. In a synthetic 58-tick
> scenario, dilution at 32 pieces fell from about **15×** to about **1.9×**, and it stops growing
> with `N`.
>
> **A residual advantage remains**: roughly **2× on collateral and 4× on the amount actually
> forfeited**. Splitting is still cheaper than trading at once. This is a mitigation, not immunity,
> and the figures above are **synthetic scenario measurements, not a mainnet guarantee**.

**F — Very low `minBondedAmount`.** Configuring a pool with `minBondedAmount` below roughly 1,000 raw
units is unsupported. It admits swaps whose variable leg is small enough that a positive collateral
rate still rounds down to zero tokens, which the hook rejects by reverting rather than by creating a
zero-collateral bond. Any realistic threshold is many orders of magnitude above this.

## Repository layout

| path | what |
|---|---|
| `src/BondMeBro.sol` | the hook |
| `src/libraries/TickAccumulatorLib.sol` | per-pool time-weighted tick accumulator (one storage slot) |
| `src/libraries/ModelL2SettlementLib.sol` | settlement arithmetic — windows, dead zone, refund/slash split |
| `src/libraries/HookDataCodec.sol` | the versioned per-swap payload (refund recipient + collateral ceiling) |
| `script/DeployBondMeBro.s.sol` | CREATE2 salt mining and deployment |
| `test/` | 461 tests, including adversarial, stateful-invariant and demo suites |
| `INTEGRATION.md` | frontend and router integration rules |

## Dependency note

`BaseHook` was **removed from `v4-periphery`** and now lives in `OpenZeppelin/uniswap-hooks` at
`src/base/BaseHook.sol`. Most tutorials still point at the old path and will not compile. Dependency
commits are pinned deliberately for that reason.

## License

See [LICENSE](./LICENSE).
