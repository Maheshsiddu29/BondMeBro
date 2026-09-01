# ADR 0001: Keep bond custody inside the hook

- **Status:** Accepted
- **Date:** 2026-08-31

## Context

A BondMeBro bond must be collected atomically with the swap. A separate deposit
transaction would add a router dependency, create a race between the quote and the
deposit, and make it possible for a swap to execute without the intended bond.

Uniswap v4 exposes hook-return deltas and an unlock-scoped `PoolManager.take` path.
Those mechanisms allow the hook to hold real ERC-20 or native currency while the
PoolManager's temporary balance sheet remains balanced.

## Decision

BondMeBro uses in-hook custody:

- exact-input swaps calculate the bond in `beforeSwap`, take it, and return a
  specified-side delta so the pool executes on net input while the trader pays gross
  input;
- exact-output swaps let the pool solve its real input first, then calculate and take
  the bond in `afterSwap` and return an unspecified-side delta;
- both paths store the bond in the hook's FIFO book only after the swap reaches
  `afterSwap`;
- a fixed 37-byte `HookDataCodec` payload supplies the refund recipient and the
  trader's maximum accepted bond;
- the contract rejects a bond that could consume the whole exact-input amount
  (`INV-NOOP`).

## Consequences

The callback permissions are part of the hook address. The current mask includes
`BEFORE_SWAP_RETURNS_DELTA_FLAG` and `AFTER_SWAP_RETURNS_DELTA_FLAG`, so changing the
custody flow requires a new CREATE2 deployment. Reverted swaps roll back both token
transfers and bond records because all work occurs in the same transaction.

The implementation intentionally supports standard ERC-20s and native currency. It
does not claim support for fee-on-transfer, rebasing, or multi-hop routes.
