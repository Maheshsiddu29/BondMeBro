# ADR 0003: Hybrid settlement with a pool-local accumulator

- **Status:** Accepted
- **Date:** 2026-08-31

## Context

A blockchain does not call `settleBonds` automatically. Requiring a keeper would make
the protocol fail operationally when that service is offline, while letting a bond
owner choose the settlement time creates a favourable timing option.

Uniswap v4 also no longer supplies the v3 observation ring buffer. BondMeBro needs a
small pool-local reference that can resolve during quiet periods and cannot be
ratcheted by many same-block swaps.

## Decision

BondMeBro uses two settlement triggers:

1. every later swap settles a matured FIFO prefix, capped by `maxSettlesPerSwap`;
2. anyone can call `settleBonds(key, maxCount)`, capped at 32, and receives a fee only
   from slash value.

`TickAccumulatorLib` is updated on every swap, credits elapsed blocks at the previous
recorded tick, accepts only the first update per block, clamps a recorded move by a
fixed per-block amount, and extrapolates the last tick during quiet periods.

Settlement compares the time-weighted reference with the raw ticks before and after
the opening swap. Refunds and slashes conserve the bond exactly. Slashed value is
held in a per-pool, per-currency insurance pot and can be donated permissionlessly to
in-range LPs.

## Consequences

There is no required keeper, but an operator can still run the settlement script for
quiet pools. A pool-local reference cannot distinguish trade persistence from broad
market drift; this is documented economic risk, not an oracle guarantee. A separate
audit and parameter review remain mandatory before mainnet.
