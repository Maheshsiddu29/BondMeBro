# Security verification status

This repository is a Sepolia testnet build, not an audited production protocol. The
checks below document the current engineering verification boundary.

## Checks run

- Frontend `npm run build`: passed.
- Frontend `npm run lint`: passed.
- Frontend `npm audit --omit=dev --audit-level=high`: passed with no high or critical
  findings after pinning Next 15.5.25, PostCSS 8.5.23, Axios 1.20.0, and ws 8.21.3.
- Solidity production build completed with Solidity 0.8.26; the full local suite passed
  with 70 tests, including 25,000 CI-profile fuzz cases and a 512-run invariant with
  51,200 generated calls.
- `forge fmt --check`, gas snapshot generation, the non-invariant gas snapshot check,
  and Slither `--fail-medium` passed. Slither reports only documented low/informational
  findings for bounded payout loops,
  guarded callbacks, and deliberate low-level token/ETH transfer handling.
- RPC route checks: read-only requests are accepted; state-changing RPC methods are
  rejected; invalid JSON and bodies over 64 KiB are rejected; security response headers
  are present.
- The sandbox uses a temporary Forge 1.7.1/solc-js adapter because the native Solidity
  compiler download endpoint is unavailable here. Re-run the canonical native Foundry
  CI workflow before release.

## Hardening included

- Browser and operational-script ERC-20/Permit2 approvals are scoped to the operation
  amount instead of using unlimited router allowances.
- Browser exact-input swaps require a positive minimum output, preventing the default
  zero-minimum slippage setting from being submitted accidentally.
- The server-side RPC proxy accepts only read-oriented JSON-RPC methods and caps body
  size and upstream request time.
- Settlement state is reconciled from the confirmed receipt; bond history and activity
  are retained during temporary RPC/indexer lag.
- Pool-key write paths validate that the key belongs to the deployed BondMeBro hook.

## Deployment boundary

The additional pool-key validation and scoped operational approvals are source and
script hardening. The existing Sepolia hook address must be redeployed and its
frontend deployment manifest updated before those Solidity changes exist on-chain.
Never infer that the already deployed address contains a source change until its
runtime bytecode and deployment transaction have been verified.

## Known boundaries

- The persistence decision is an outcome-linked TWA signal. Market drift and unrelated
  flow can affect refund/slash results; this is documented protocol economics, not a
  causal toxicity oracle.
- A successful settlement refund is an inline transfer in the settlement transaction;
  there is no second refund transaction. Wallet balance changes must be evaluated net
  of gas.
- Remaining npm findings are moderate transitive wallet-connector findings. Moving to
  the major wagmi 3 release is intentionally deferred until its browser flow is
  regression-tested.
- Before any production deployment, obtain an independent smart-contract audit, review
  economic parameters and slippage bounds, rehearse on a testnet, and use a multisig or
  hardware wallet for ownership and deployment.
