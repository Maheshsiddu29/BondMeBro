# BondMeBro dashboard

A Next.js monitoring and swap dashboard for the BondMeBro Uniswap v4 hook.
The visual direction uses a dark, neon, editorial system with high-contrast signal
cards and a collapsible style sample in the left sidebar.

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
- Exact-input browser swap for the configured ETH/WETH pool, including the ERC-20
  and Permit2 approval sequence.
- Token selector entries for ETH, WETH, and Sepolia USDC. Unsupported pairs are
  blocked instead of pretending that a pool or route exists.

Settlement, donation, liquidity minting, and exact-output execution remain in the
Foundry scripts for now. A browser swap requires the configured Universal Router and
an active BondMeBro pool for the selected pair. Do not put a private key in frontend
environment variables; only the server-side RPC URL and public addresses belong there.
