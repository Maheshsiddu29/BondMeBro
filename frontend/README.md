# BondMeBro dashboard

A Next.js dashboard for the BondMeBro Uniswap v4 hook. It combines live protocol
reads with the browser flow for the deployed Sepolia ETH/WETH pool.

## Run locally

```bash
cd frontend
cp .env.example .env.local
# Set SEPOLIA_RPC_URL to a server-side Sepolia RPC endpoint in .env.local.
npm install
npm run dev
```

Open `http://localhost:3000` locally. The browser talks to the relative `/api/rpc`
route; the server route forwards JSON-RPC requests to `SEPOLIA_RPC_URL`, so an RPC
key is not exposed in client-side JavaScript.

## Browser lifecycle

1. **Swap** — the dashboard asks the official Sepolia Uniswap v4 Quoter for an
   exact-input ETH/WETH estimate as the amount changes, then submits through the
   configured Universal Router. The BondMeBro hook receives the 37-byte recipient
   and bond-limit payload. The exact output is read-only; minimum received is
   automatically set to the quote less 0.50% slippage and can be tightened manually.
2. **Bond opened** — after confirmation, the dashboard refreshes `BondOpened` events
   and filters the recent bond history to the connected wallet.
3. **Observe** — the bond remains active until the configured observation window has
   elapsed. The Bonds screen shows the opening block, maturity block, progress, and a
   live estimate of the refund if the reference tick has moved back toward the
   pre-swap tick.
4. **Settle** — once the FIFO head is mature, any connected Sepolia wallet can call
   `settleBonds` for one matured FIFO item at a time to keep gas and confirmation latency bounded. The hook calculates the outcome automatically: a reference tick that
   returns toward the pre-swap tick refunds the bond, while persistent impact sends the
   slash to the insurance pot. The UI shows the settlement transaction and final
   refund/slash result once `BondSettled` is indexed.
5. **Claim fallback payments** — if a recipient could not receive an inline refund or
   settler reward, the hook records a pull payment. The connected recipient can retry
   it from **My bonds → Available to claim**.
6. **Distribute insurance** — a non-zero ETH or WETH insurance pot can be distributed
   by anyone from **Pools → Insurance balances**. The call is permissionless and can
   revert if the pool has no in-range liquidity; a reverted donation leaves the pot
   untouched.
7. **Verify** — every write surface links to Sepolia Etherscan, and Activity indexes
   BondMeBro openings, settlements, configuration updates, pot donations, and payment
   claims from the recent block window.

There is no automatic transaction at maturity: a user, operator, or public keeper
must send the permissionless settlement transaction. A later swap can also piggyback
settlement according to the hook's configured cap.

## Current scope and limits

- Sepolia hook, pool, pair, PoolManager identity, configuration, and accumulator reads.
- Queue length, FIFO head, user-filtered recent bond records, maturity progress, and
  settlement outcome cards.
- ETH and WETH claimable-payment reads and browser claim transactions.
- ETH and WETH insurance-pot reads and browser donation transactions.
- Wallet connection and Sepolia network switching.
- Exact-input browser swaps for the configured ETH/WETH pool, including scoped
  ERC-20 and Permit2 approvals. A positive minimum output is required for slippage
  protection.
- Token selector entries for ETH, WETH, and Sepolia USDC. USDC remains blocked until
  a real BondMeBro USDC pool is initialized and funded.

Exact-output browser execution, owner configuration, liquidity minting/management,
multiple-pool discovery, and a production pool registry are not implemented yet.
Arbitrary-token swaps are not supported by the single deployed pool. Do not put a
private key in frontend environment variables; only the server-side RPC URL and
public deployment addresses belong there.
