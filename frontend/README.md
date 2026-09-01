# BondMeBro dashboard

A Next.js read-only monitoring dashboard for the BondMeBro Uniswap v4 hook.
The visual direction takes inspiration from the neon, editorial energy of
[ChainGPT](https://www.chaingpt.org/) without copying its brand assets. The ChainGPT
site is available as a collapsible visual reference in the left sidebar.

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

## Current scope

- Sepolia hook, pool, pair, and PoolManager identity.
- Live pool configuration and bond rate.
- Queue length and head-bond maturity state.
- Native and WETH insurance pots.
- Accumulator tick, block, and cumulative reading.
- Recent BondMeBro event stream.
- Wallet connection and Sepolia network prompt.

Write operations remain in the audited Foundry scripts and deployment runbook for
this first frontend phase.
