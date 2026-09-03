# BondMeBro

**Refundable, outcome-linked collateral for Uniswap v4 liquidity providers.**

BondMeBro takes a **refundable deposit** from eligible swaps and observes the pool for ten blocks.
If the price stays displaced in the trade's direction, some or all of the deposit goes into an LP
insurance pot. The rest goes back to the named refund recipient. This shares risk using an observed
pool outcome; it does not tell us what the trader knew or intended. LP means liquidity provider.

Contract: `BondMeBro` · Built for UHI10 (Atrium Academy) · Solidity 0.8.26 · Foundry

---

## 1. What BondMeBro is

A Uniswap v4 hook. It sits on a pool, watches swaps, and for swaps large enough to matter it:

1. takes a small **refundable collateral** out of the swap,
2. records where the price was before and after,
3. ten blocks later, measures how much of that price move was still there,
4. **refunds** the collateral if the move reverted, or moves part of it into an **LP insurance pot**
   if the move stuck.

No external oracle, off-chain classifier or wallet scoring is used. The hook reads the pool's own
price history. Anyone can call settlement after maturity; refunds are not sent automatically just
because ten blocks have passed.

## 2. The problem

After a price-moving trade, the pool price may move back, stay displaced, or move further. LPs face
different risks along those paths, but a pool's price history alone does not prove who caused a loss
or why someone traded.

BondMeBro treats persistent same-direction displacement as an **LP-risk proxy** — a measurable
signal used to split the deposit, not proof of actual LP loss. A reversal does not prove no one was
harmed, and persistence does not prove the trader had inside information. This is outcome-linked
risk sharing, not a classifier of trader knowledge, intent or maliciousness.

## 3. Why the collateral is refundable

The late price observations do not exist when the trade executes. The hook therefore holds a
deposit first and decides its refundable part after the observation window.

If both late windows show no chargeable displacement, the deposit is fully refunded. Otherwise,
part or all is credited to the insurance pot. Swap fees and gas still apply. Pot funds stay inside
the hook; this version does not distribute them to LPs.

## 4. Exact-input swaps — where the money comes from

For an exact-input swap you fix what you spend. So the collateral comes out of the **output**:

```
you spend       1,000 USDC     ← exactly what you asked, untouched
pool swaps      1,000 USDC     ← the whole amount hits the curve
pool returns    ~0.30 WETH
hook holds       0.00045 WETH  ← the collateral, refundable, 15 bps here
you receive     ~0.29955 WETH  ← output minus the collateral
```

**The hook does not change your specified input.** It has no `beforeSwapReturnDelta` permission.
For exact input, its post-swap collateral adjustment applies only to output. These examples assume
a fully filled swap; a pool price limit can still cause a partial fill.

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
what the simpler own-impact rule would have charged for the same execution.

The rate calculation is **pool-level and identity-free**: it does not use the sender, recipient or
router as a score. Block-cumulative impact materially mitigates the old per-swap rule's unbounded
same-block dilution. It does **not** make splitting invariant: splitting can still reduce collateral
and the amount forfeited. See limitations D and E.

## 7. C6 / C8 / C10 — what settlement looks at

The hook keeps a running time-weighted tick accumulator per pool. When a bond opens at block `B`, it
matures at `B + 10`, and three readings are frozen along the way:

| reading | block | what it is |
|---|---|---|
| **C6** | `B + 6` | accumulator value six blocks in |
| **C8** | `B + 8` | eight blocks in |
| **C10** | `B + 10` | at maturity |

Settlement scores the **late** windows — blocks 6–7 and 8–9 — relative to the bond's **pre-trade
tick**. It does not directly charge the opening block. However, displacement created by the opening
trade can still contribute to a slash if it persists into those late windows. The larger of the two
direction-aligned readings is used, so changing one block cannot directly change both windows.

**Before maturity, settlement reverts.** At maturity or any time later, it uses the same C6/C8/C10
endpoints. Swaps after maturity cannot change the result. Quiet periods are filled using the last
observed tick; the hook does not refund automatically because no swaps occurred.

## 8. Refund and slash

```
R        = the larger of the two late-window displacements, in the trade's own direction, clamped at 0
Q        = 0 if R ≤ 5 ;  2(R − 5) if R < 10 ;  R otherwise      ← the 5-tick dead zone
slashBps = min(collateralBps, ceil(Q × 0.25))

slash    = variableLeg × slashBps / 10,000
refund   = collateral − slash
```

- Both late-window readings reverted → `R = 0` → **full refund**.
- Both late-window readings are within 5 ticks → **full refund** (the chosen dead zone).
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
and gains nothing; the result is identical whoever calls it at or after maturity. `settleMany`
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

Prerequisites: Foundry (`forge`, `cast`, `anvil`), Git, Make, Python 3 with `slither-analyzer`, and
`jq` for the local deployment commands. Solidity 0.8.26 and Cancun are selected by `foundry.toml`.
Install Slither locally if needed with `pip3 install slither-analyzer`.

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

Run the local release checks:

```bash
make ci          # fmt-check, slither, build, optimized tests, coverage
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariant/*' -vv
```

`make ci` runs every test normally, including every gas ceiling. Coverage then excludes only
`test_adversarial_victimCallbackStaysInsideTheCeiling` in `test/ObservationCheckpointGas.t.sol`.
Coverage disables optimization, so that one test's gas assertion is not meaningful in a coverage
build. Its original 150,000 limit remains enforced by the optimized test run. No adversarial suite
is excluded. GitHub CI uses the same `make coverage` command, the larger `ci` profile, and a
separate committed-snapshot check.

The local P-L2-9.2 checks passed with the figures below. These are local results, not a fresh-clone
certification; the committed candidate needs that separate check.

| | |
|---|---|
| tests | **461 passing**, 0 failing, 35 suites |
| stateful invariant campaign | **26 invariant-suite tests: 20 invariant properties + 6 reachability/regression tests**, 512 runs × depth 100 |
| Slither | **0 findings**, 102 detectors |
| coverage run | **460 passing**, 0 failing; only the named gas assertion excluded |
| coverage (`src/BondMeBro.sol`) | 99.14% lines · 86.05% branches · 100% functions |
| runtime bytecode | **15,953 bytes** (8,623 under the EIP-170 limit) |
| `beforeSwap` worst case | **107,543 gas** (limit 150,000) |
| `afterSwap` worst case | **73,999 gas** (limit 100,000) |

The callback maxima are above the targets of 50,000 (`beforeSwap`) and 30,000 (`afterSwap`), but
below the hard ceilings shown. These release-documentation fixes do not change callback code.

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

### Local deployment on fresh Anvil

This deploys only to a throwaway chain on your own computer. It does not create a pool or supply
liquidity; `make demo` creates its own complete test fixture for those parts. Do not use these
unlocked-account commands on a public network. No env file or signing secret is needed.

In terminal 1, start a fresh node with no saved state or fork. Keep it running:

```bash
anvil --host 127.0.0.1 --port 8545 --chain-id 31337 --hardfork cancun --quiet
```

If port 8545 is already in use, stop your own old local node first. Do not use an unknown node.
In terminal 2, from the repository root, run the following in Bash or Zsh:

```bash
set -euo pipefail
export RPC_URL=http://127.0.0.1:8545
test "$(cast chain-id --rpc-url "$RPC_URL")" = 31337

HOOK_OWNER=$(cast rpc --rpc-url "$RPC_URL" eth_accounts | jq -er '.[0]')
export HOOK_OWNER

POOL_MANAGER=$(forge create lib/v4-periphery/lib/v4-core/src/PoolManager.sol:PoolManager \
  --rpc-url "$RPC_URL" --unlocked --from "$HOOK_OWNER" --broadcast --json \
  --constructor-args "$HOOK_OWNER" | jq -er '.deployedTo')
export POOL_MANAGER

forge script script/DeployBondMeBro.s.sol \
  --rpc-url "$RPC_URL" --sender "$HOOK_OWNER" --unlocked --broadcast
```

These are all the environment values this flow needs:

- `RPC_URL` is the HTTP connection to this fresh local Anvil, not a mainnet or testnet service.
- `HOOK_OWNER` is the first funded, unlocked account returned by this Anvil. It owns the hook's
  pool-eligibility configuration. In this example it also owns the new PoolManager and signs both
  deployments. `--from` selects it for `forge create`; `--sender` selects it for `forge script`.
  `--unlocked` asks the local node to sign. The hook owner and deployment signer need not be the same
  address in other deployment setups.
- `POOL_MANAGER` is the actual contract address returned by the successful PoolManager deployment,
  not a guessed or copied address. Its installed constructor takes `address initialOwner`.

The BondMeBro script itself reads only `POOL_MANAGER` and `HOOK_OWNER`. It mines its CREATE2 salt,
deploys, checks its address and permissions, then prints `deployed` and `addr bits`. Success means
the broadcast completes and `addr bits` is **4292**, which is **0x10C4** in hexadecimal.

The deployed hook address must have its low 14 permission bits equal to `0x10C4`. The visible
hexadecimal suffix does not need to be literally `10C4`; addresses ending in `10C4`, `50C4`, `90C4`,
or `D0C4` can all satisfy the same permission mask. The equivalent Solidity check is:

```solidity
require((uint160(address(hook)) & 0x3FFF) == 0x10C4);
```

`BEFORE_SWAP_RETURNS_DELTA` is absent. This is a permission-bit property, not a text suffix check.
Stop Anvil with Ctrl-C when finished; its throwaway state is discarded.

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
> In the representative **58-tick / 32-piece** scenario, collateral dilution fell from about
> **15×** under the old rule to about **1.88×** under the current rule. The slash retained compared
> with a single trade rose from about **6%** to about **27%**.
>
> **A residual advantage remains**: roughly **2× on collateral and 4× on the amount actually
> forfeited**. Splitting is still cheaper than trading at once. This is a mitigation, not immunity.
> The figures are **SYNTHETIC SIMULATION — NOT HISTORICAL UNISWAP EVIDENCE**, and are not universal
> mainnet ratios.

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
