# BondMeBro backend status

This status file is the current implementation reference. The original simple
explanation described an earlier custody-only milestone; the repository now includes
settlement and operational tooling as well.

## Implemented

- exact-input single-hop custody in `beforeSwap`;
- exact-output single-hop custody in `afterSwap`;
- separate raw-input thresholds for `currency0` and `currency1`;
- owner-only per-pool configuration with an all-or-nothing enable/disable rule;
- 1% maximum pool bond rate;
- versioned 37-byte `hookData` with refund recipient and maximum bond amount;
- INV-NOOP protection and atomic rollback on reverted swaps;
- FIFO bond records and configurable observation maturity;
- time-weighted persistence settlement with refunds and slashes;
- capped piggyback settlement and permissionless settlement;
- settler rewards funded only from slash value;
- per-pool, per-currency insurance pots and permissionless donation;
- deferred payments for rejecting token/native recipients;
- native ETH and standard ERC-20 paths;
- truncation-aware, once-per-block accumulator;
- deployment, initialization, liquidity, swap, configuration, settlement, and donation
  scripts;
- unit, fuzz, integration, and stateful custody invariants.

## Verification completed locally

The current suite passes:

```text
69 tests passed, 0 failed
```

The invariant suite includes 64 runs and 2,048 generated calls for the custody
accounting invariant.

## Deployment note

The earlier Sepolia hook address belongs to the pre-threshold, pre-codec permission
mask and is not compatible with this backend revision. A new hook must be deployed
and the new `BOND_HOOK` recorded before repeating the pool rehearsal.

## Still required before mainnet

- independently review/audit the Solidity and economic model;
- choose thresholds and observation/clamp parameters using the target token decimals
  and expected volatility;
- verify official chain-specific PoolManager, PositionManager, Permit2, and Universal
  Router addresses;
- set bounded liquidity and swap slippage limits;
- rehearse the current hook deployment on a clean testnet wallet;
- deploy with a hardware wallet or multisig instead of a raw private key;
- record a deployment manifest and monitor `BondOpened`, `BondSettled`,
  `PaymentDeferred`, `PaymentsClaimed`, `PoolConfigUpdated`, and `PotDonated`.
