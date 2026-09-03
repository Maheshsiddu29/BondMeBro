# BondMeBro dashboard

A Next.js dashboard for swapping through a BondMeBro pool, watching refundable collateral
mature, and settling it permissionlessly.

This app is built against the hook in `../src/BondMeBro.sol`. Its contract ABI is generated
from that build rather than hand-maintained.

---

## Deployment is required before anything runs

There are **no default addresses**. If any part of the deployment is missing, invalid or
inconsistent, the app renders a `DEPLOYMENT REQUIRED` screen and makes no chain calls at
all. This is deliberate: a successful transaction against the wrong hook looks exactly like
a working demo.

Configuration is validated before the wallet layer is even mounted:

- the hook's low 14 address bits must equal **`0x10C4`** — the permission set this contract
  requires. An address with `0x10CC` carries `BEFORE_SWAP_RETURNS_DELTA`, which this hook
  does not have, so it cannot be a deployment of this source.
- `currency0` and `currency1` must both be standard ERC20s, sorted low to high. Native
  currency is not a supported pool side; supported swaps are single-hop ERC20 ↔ ERC20.
- the pool ID is **derived** from the key. If you also supply one, it is checked against the
  derived value and a mismatch is fatal.
- the server-side RPC endpoint is verified to serve the configured chain before any request
  is forwarded.

### Environment

Set these in your environment or a local `.env.local` file. This repository does not track
any `.env` file, including examples — create yours locally and keep it out of git.

| name | scope | meaning |
|---|---|---|
| `RPC_URL` | server | JSON-RPC endpoint. Must serve `NEXT_PUBLIC_CHAIN_ID`. Keep provider keys here, never in a `NEXT_PUBLIC_*` value. |
| `NEXT_PUBLIC_CHAIN_ID` | client | Chain ID of the deployment. |
| `NEXT_PUBLIC_NETWORK_NAME` | client | Display name for that chain. |
| `NEXT_PUBLIC_EXPLORER_URL` | client | Base explorer URL, `https://…`, no trailing slash. |
| `NEXT_PUBLIC_HOOK_ADDRESS` | client | Deployed BondMeBro hook. Permission bits must be `0x10C4`. |
| `NEXT_PUBLIC_POOL_MANAGER` | client | Uniswap v4 PoolManager the hook was constructed with. |
| `NEXT_PUBLIC_UNIVERSAL_ROUTER` | client | Universal Router used for both swap kinds. |
| `NEXT_PUBLIC_QUOTER` | client | V4Quoter. |
| `NEXT_PUBLIC_PERMIT2` | client | Permit2 the router pulls through. |
| `NEXT_PUBLIC_CURRENCY0` | client | Pool currency0, ERC20, sorts below currency1. |
| `NEXT_PUBLIC_CURRENCY1` | client | Pool currency1, ERC20. |
| `NEXT_PUBLIC_POOL_FEE` | client | Pool fee, e.g. `3000`. |
| `NEXT_PUBLIC_TICK_SPACING` | client | Pool tick spacing, e.g. `60`. |
| `NEXT_PUBLIC_DEPLOYMENT_BLOCK` | client | First block worth scanning for this hook's logs. |
| `NEXT_PUBLIC_POOL_ID` | client | Optional. Checked against the derived pool ID. |

Token decimals and symbols are **read from the tokens themselves** and cached per chain and
address. There is no shipped token list and no 18-decimal fallback.

---

## Commands

```bash
npm ci
npm run lint        # eslint
npm run typecheck   # tsc --noEmit --incremental false
npm run test        # vitest: contract-integration unit tests
npm run build       # next build
npm run dev         # local development server

npm run abi:sync    # regenerate src/lib/abi/bondMeBro.ts from ../out/BondMeBro.sol
npm run abi:check   # fail if the checked-in ABI has drifted from that build
```

Run `forge build` at the repository root before `abi:sync` or `abi:check`.

---

## What the app does

### Exact input

You choose how much input to swap. Your input reaches the pool in full — nothing is carved
out of it. BondMeBro may temporarily withhold a small part of the **output** as refundable
collateral, so what you receive is the realized output minus that amount.

The collateral ceiling sent with the swap is `type(uint128).max`, and your protection is the
**minimum received**, which the router checks against the net amount. A quote-derived
ceiling would reject swaps whose final net output is still acceptable to you.

### Exact output

You choose the exact output. BondMeBro may temporarily require **additional input** as
refundable collateral, so your total spend is the pool input plus that amount. Here a bound
is genuinely required.

**The exact-output quote is already the total input**, including the collateral simulated at
quote-time pool state. It is not a pre-collateral figure, and this app never tries to turn it
into one. With `Q` the quote, `S` your tolerance in basis points, and `B` and `C` read from the
hook:

```
amountInMaximum = ceil( Q * (B + S) / B )              // rounds UP
maxBondAmount   = amountInMaximum * C / (B + C)        // rounds DOWN
```

`amountInMaximum` is the maximum **total** input you authorise, collateral included. The
collateral cap `C` never touches it — applying `(B + C) / B` on top of `Q` would add a second
collateral allowance to a figure that already carries one. `C` appears only in the bond
ceiling, which is derived from that same total cap so the two bounds bind together.

Your allowance and balance must cover `amountInMaximum`.

If the derived ceiling rounds to zero, the app does **not** quietly substitute 1: it does so
only where the trade provably cannot bond — the pool has bonding disabled, or the whole total
cap is below the pool's own bonding minimum, in which case the hook returns before the ceiling
is ever consulted. Otherwise it refuses the swap and tells you the amount is too small for
this route.

### Collateral is an estimate before the trade

The rate is sized from **effective block impact** — the larger of this swap's own tick
movement and the pool's movement since the start of the block it lands in. That depends on
transaction ordering and cannot be known when you quote. Any pre-trade figure is labelled
*estimated collateral*; the actual amount comes from the `BondTaken` event and
`collateralAmountOf(bondId)` after execution.

### Not every swap creates a bond

A pool sets two minimums in two different currencies: one on the input the trade consumes,
and one on the leg the collateral is carved from. A trade under either, a trade that does
not move the price enough to produce a positive rate, and any trade on a pool with bonding
disabled all execute in full and create no bond. The app shows this as **Unbonded swap**,
which is a normal outcome and not an error. Bonding being disabled never blocks swapping.

### Maturity and settlement

Maturity is each bond's **stored `maturityBlock`**. It is never recomputed and there is no
fallback horizon: if the read fails the app says so rather than inventing a number.

Settlement is permissionless — anyone may call `settleBond(bondId)` at or after that block.
The refund always goes to the recipient stored in the bond, never to the caller. There is no
expiry and no settler reward, and because the observation checkpoints are frozen, settling
later gives the identical result.

### Insurance reserve

Retained collateral accumulates in a per-pool, per-currency **LP-risk compensation reserve**,
readable through `insurancePot(poolId, currency)`. This version has no payout, donation or
claim function, and the app offers none.

---

## Transaction safety

- Every read is bound to the configured chain and goes through the server proxy, which
  verifies its upstream chain ID. The injected wallet is never used as a read transport.
- Every write passes an explicit `account` and `chainId`, and the live wallet is re-checked
  immediately before each one — including *between* the two approvals. A changed account or
  network aborts the flow and requires a new quote.
- Approvals are **bounded**: the ERC20 allowance to Permit2 and the Permit2 allowance to the
  router are both exactly this swap's requirement, expiring in one hour. The token, spender,
  amount and duration are shown before you are asked to sign.
- Every receipt is checked for `status === "success"`. A mined but reverted transaction is
  reported as a failure, never as a confirmation.
- The submitted request is frozen on screen, so editing the form afterwards cannot change
  what the result appears to describe.

---

## Known limitations

- **Log window.** Bond discovery scans at most the most recent 200,000 blocks above the
  configured deployment block, and remembers bonds this browser has seen. A different
  browser opening the app long after that window will not rediscover an older bond from
  logs alone. The scanned range is shown on the bonds screen.
- **Estimated collateral is a floor, not a bound.** It is computed from the pool's current
  displacement at quote time. Ordering inside your block can only be known afterwards.
- **Same-block splitting is mitigated, not eliminated.** This measures later pool price, not
  intent. There is no oracle and no classifier, and no claim of being MEV-proof or
  manipulation-proof.
- Supported swaps are single-hop ERC20 ↔ ERC20 only. Native currency, multi-hop,
  fee-on-transfer and rebasing tokens are not supported.
