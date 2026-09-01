# ADR 0002: Use per-currency pool thresholds

- **Status:** Accepted
- **Date:** 2026-08-31

## Context

The same raw integer amount does not represent the same economic size for two tokens.
For example, `1 USDC` is `1_000_000` raw units while `1 WETH` is
`1_000_000_000_000_000_000` raw units. One threshold cannot safely gate both input
directions.

The bond rate is also an economic parameter. Letting a configuration exceed 1% makes
small pools vulnerable to an accidental no-op swap or an unexpectedly large custody
obligation.

## Decision

Each initialized pool stores one packed `PoolConfig`:

```text
uint96 minBondedAmount0
uint96 minBondedAmount1
uint16 bondBps
```

The owner may update it after initialization. All three values must be non-zero to
enable bonding; all three zero disables it. Partial configurations revert. The bond
rate is capped at 100 basis points.

The default values are supplied at deployment and copied when `afterInitialize` runs.
The `ConfigureBondMeBroPool` script changes a pool without redeploying the hook.

## Consequences

The threshold is based on total input. Exact-input uses the requested gross input;
exact-output uses the solved pool input plus the calculated bond. Token decimals and
slippage limits remain the operator's responsibility when selecting thresholds.

Changing immutable default values changes the CREATE2 address. Updating a pool's
stored configuration does not change the hook address, but it is owner-controlled and
must be emitted and monitored through `PoolConfigUpdated`.
