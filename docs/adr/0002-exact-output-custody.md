# ADR-0002 — Exact-output bond custody in `afterSwap`

- **Status:** Accepted
- **Date:** 2026-08-29
- **Extends:** [ADR-0001](0001-in-hook-custody.md), which decided in-hook custody via
  `beforeSwapReturnDelta` and listed exact-output as **unsupported**. This ADR supersedes
  ADR-0001 § 8 on that one point only. Everything else in ADR-0001 stands.
- **Required by:** `AGENTS.md` § "Before editing" rule 5 — *"Do not change custody
  callback/delta strategy without an ADR."* T3B adds a **second** custody point and enables a
  new return-delta permission, so it is squarely a custody-strategy change.
- **Implemented by:** T3B. Bond records, maturity, settlement, refunds and the insurance pot
  remain out of scope (T5).

---

## 1. Context — the bypass

ADR-0001 shipped custody for exact-input swaps and deliberately let exact-output through
unbonded. That is a hole, and it is trivially exploitable: **anyone who wants to avoid the
bond just phrases their trade as exact-output.** Same economic trade, same price impact on
liquidity providers, no collateral. A collateral requirement that can be declined by
changing one field is not a requirement.

ADR-0001 § 9.1 rejected the separate-router design precisely because "anything that lives
outside the swap path can be bypassed." Leaving exact-output unbonded reintroduces the
same defect from a different direction.

## 2. Why exact-output cannot use the `beforeSwap` path

The two swap kinds differ in **what is known when**.

**Exact-input.** `amountSpecified` is negative and *is* the input. The gross input is known
in `beforeSwap`, before anything executes. The bond can be sized and carved out of it up
front, which is what ADR-0001 does.

**Exact-output.** `amountSpecified` is positive and is the **output** the trader wants. The
input is whatever the pool ends up charging — a function of liquidity, the fee tier, and how
far the price moves as the swap walks the curve. **It is not knowable before the swap
executes.**

Three non-options, for the record:

1. **Estimate the input in `beforeSwap`.** Requires exactly the liquidity math ADR-0001 § 3.4
   rejected, and would be wrong in the same direction — understating the input on large
   trades that cross into thinner liquidity.
2. **Bond a fraction of the requested output instead.** Changes which token backs the bond to
   the token the trader is *buying*, coupling collateral value to the price move being
   adjudicated. Rejected in ADR-0001 § 9.2 for that reason.
3. **Reject exact-output outright.** Honest, but it makes the pool unusable for a standard
   swap type, and the bypass argument in § 1 applies just as well to "route around this pool
   entirely."

So custody for exact-output must happen **after** the swap, at the first moment the actual
input is known. That is `afterSwap`.

## 3. Decision

**Two custody points, selected by swap kind. One rule each. They do not overlap.**

| | Exact-input (`amountSpecified < 0`) | Exact-output (`amountSpecified > 0`) |
|---|---|---|
| Custody callback | `beforeSwap` | `afterSwap` |
| Mechanism | `beforeSwapReturnDelta`, specified side | `afterSwapReturnDelta`, unspecified side |
| Bond is | **carved out of** the trader's input | **added on top of** the pool's input |
| Bond currency | input currency | input currency |
| Total trader outflow | `|amountSpecified|` | `poolInput + bond` |
| `beforeSwap` returns | `+bond` as `deltaSpecified` | `ZERO_DELTA` |
| `afterSwap` returns | `0` | `+bond` as the unspecified delta |

**Exact-input behaviour is unchanged from ADR-0001.** T3B must not alter it, and the T3A test
suite is the regression proof.

### The asymmetry, stated plainly

For exact-input the trader's total spend is fixed and the bond comes out of it — they get
less output. For exact-output the output is fixed by definition (that is what "exact output"
means), so the bond **must** come from somewhere else: the trader pays *more input*. There is
no third option that preserves both the output amount and the input amount.

This is why § 8's router check is a hard requirement rather than a nicety: on exact-output
the bond genuinely increases what the trader pays, so the trader's own maximum-input limit
has to account for it.

## 4. Why the unspecified currency is the input currency for exact-output

Verified against the installed pin (v4-core `59d3ecf5`), not from memory.

`Hooks.afterSwap` — `lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol:298-312`:

```solidity
if (self.hasPermission(AFTER_SWAP_FLAG)) {
    hookDeltaUnspecified += self.callHookWithReturnDelta(          // :299 — our afterSwap return
        abi.encodeCall(IHooks.afterSwap, (msg.sender, key, params, swapDelta, hookData)),
        self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
    ).toInt128();
}

BalanceDelta hookDelta;
if (hookDeltaUnspecified != 0 || hookDeltaSpecified != 0) {
    hookDelta = (params.amountSpecified < 0 == params.zeroForOne)   // :307
        ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
        : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);

    // the caller has to pay for (or receive) the hook's delta
    swapDelta = swapDelta - hookDelta;                              // :312
}
```

Evaluate the selector at `:307` for exact-output, where `amountSpecified > 0` so
`amountSpecified < 0` is **false**:

| Direction | `false == zeroForOne` | Branch taken | `amount0` | `amount1` | Input currency | ⇒ unspecified is |
|---|---|---|---|---|---|---|
| `zeroForOne` (0→1) | `false == true` → **false** | `toBalanceDelta(unspecified, specified)` | unspecified | specified | currency0 | **currency0 = input** ✅ |
| `oneForZero` (1→0) | `false == false` → **true** | `toBalanceDelta(specified, unspecified)` | specified | unspecified | currency1 | **currency1 = input** ✅ |

**In both directions the unspecified side is the input currency.** The `afterSwap` return
value feeds `hookDeltaUnspecified` at `:299`, so it lands on the input currency — exactly
where the bond belongs.

The mirror case, for contrast: on exact-**input**, `amountSpecified < 0` is true, the table
inverts, and unspecified is the **output** currency. That is why our `afterSwap` returns `0`
for exact-input — a non-zero return there would take collateral out of the trader's proceeds.

### Sign convention

`:312` is `swapDelta = swapDelta - hookDelta`, and `PoolManager.sol:224` credits the hook
`+hookDelta`. So returning **`+bond`**:

- credits the hook `+bond`, cancelling the `-bond` debt opened by `take`;
- decreases the trader's input-currency delta by `bond`, i.e. **the trader owes `bond` more**.

The in-tree reference is `FeeTakingHook`
(`lib/v4-periphery/lib/v4-core/src/test/FeeTakingHook.sol:35-52`): it calls
`manager.take(feeCurrency, address(this), feeAmount)` and returns `feeAmount.toInt128()` —
a positive return paired with a take. We mirror that shape exactly.

## 5. Reading the actual pool input

`Hooks.afterSwap:300` passes `swapDelta` — the **raw pool result**, before any hook delta is
subtracted (the subtraction happens later, at `:312`). So the `delta` our callback receives
is precisely the pool's own accounting: what it consumed and what it produced.

```
inputDelta = zeroForOne ? delta.amount0() : delta.amount1()   // negative: trader owes the pool
poolInput  = -inputDelta                                       // widen to int256 before negating
```

This is byte-for-byte the derivation the installed router uses —
`V4Router.sol:240-242`:
```solidity
function _swapInput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
    return (uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()))).toUint128();
}
```
Using the same derivation as the router is deliberate: the number we size the bond off is the
same number the router bounds against `amountInMaximum`.

**Guard:** if `inputDelta >= 0` the pool consumed nothing (or the trader is somehow owed input
currency, which our own `beforeSwap` cannot cause since it returns `ZERO_DELTA` on this path).
Treated as unbonded — return zero — rather than negating into a wrapped value.

## 6. Bond arithmetic — solving for gross

`bondBps` means *a fraction of gross trader input* in ADR-0001, and it must keep that meaning
here or the two paths would charge differently for the same trade.

For exact-input, gross is given: `bond = grossInput * bondBps / 10_000`.

For exact-output we know `poolInput`, not gross, and `grossInput = poolInput + bond`. Solving:

```
bond = grossInput * bondBps / 10_000
bond = (poolInput + bond) * bondBps / 10_000
bond * (10_000 - bondBps) = poolInput * bondBps

bond = floor( poolInput * bondBps / (10_000 - bondBps) )
```

Worked example: `poolInput = 100`, `bondBps = 100` (1%) →
`bond = 100 × 100 / 9_900 = 1.0101…` → floor `1`. `grossInput = 101`, and
`1 / 101 ≈ 0.99%` — the intended 1% of gross, off only by flooring.

**Denominator is provably non-zero.** `bondBps <= MAX_BOND_BPS = 100`, so
`10_000 - bondBps >= 9_900`. The `MAX_BOND_BPS` cap is load-bearing for this path in a way it
is not for exact-input.

**Overflow.** `poolInput * bondBps` can exceed 256 bits for large inputs, so the multiply and
divide use `FullMath.mulDiv`
(`lib/v4-periphery/lib/v4-core/src/libraries/FullMath.sol:14`), which computes the full
512-bit product. Flooring matches `mulDiv`'s rounding and matches ADR-0001's rule that
rounding favours the trader.

## 7. Threshold — compare gross, not `amountSpecified`

The threshold means *gross input* (ADR-0001 § 3.1), and is selected by direction —
`minBondedAmount0` when currency0 is the input, `minBondedAmount1` when currency1 is.
For exact-output, `amountSpecified` is
an **output** amount and comparing it to the threshold would be comparing two different
tokens. Instead:

```
candidateBond  = floor(poolInput * bondBps / (10_000 - bondBps))
candidateGross = poolInput + candidateBond
minBondedAmount = zeroForOne ? minBondedAmount0 : minBondedAmount1
if candidateGross < minBondedAmount  ->  unbonded, return zero delta
else                                 ->  bond = candidateBond
```

The threshold therefore means the same thing on both paths: *the total the trader puts in*.

## 8. Router maximum-input protection — and its limits

The bond increases what an exact-output trader pays, so their slippage ceiling must cover it.
Verified against the installed router:

`lib/v4-periphery/src/V4Router.sol:149-150` (in `_swapExactOutputSingle`):
```solidity
uint128 amountIn = _swapInput(delta, params.zeroForOne);
if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
```

`delta` here is the return of `poolManager.swap` (`V4Router.sol:225`), and
`PoolManager.sol:221-226` reassigns that return to the **post-hook** value before accounting
it to the caller. So `amountIn` is `poolInput + bond`, and the check covers the bond.

**Confirmed: the trader's ceiling includes our collateral.** Test 13/14 prove it end to end.

### The caveat that must not be lost

**Router-level slippage protection is a property of the router, not of the pool.** A caller
that reaches `PoolManager.unlock` directly — including v4-core's `PoolSwapTest`, which our own
integration tests use — performs **no** `amountInMaximum` check whatsoever. Nothing in this
hook can impose one.

So the honest claim is narrow: *traders routing through `V4Router` or a descendant are
protected by their own `amountInMaximum`, and that ceiling accounts for the bond.* Traders
who hand-roll a direct `unlock` are protected only by `maxBondAmount` in their `hookData` —
which is precisely why that field is mandatory rather than optional.

## 9. `hookData` is mandatory on exact-output, and validated twice

For exact-input, the size test happens in `beforeSwap` and small swaps never read `hookData`
at all. **That cannot work for exact-output**, because whether the swap crosses the threshold
depends on the input, which is unknown until after execution. By then the swap has run.

So: **every exact-output swap on a bonding-enabled pool must carry valid `hookData`**, even
if it turns out to be below the threshold and pays nothing.

`beforeSwap` decodes and validates it, discards the result, and returns `ZERO_DELTA`.
`afterSwap` decodes it again and uses it.

**This decodes twice, and that cost is real and is reported rather than hidden** (~691 gas per
decode). The alternative — stashing the decoded values in transient storage between callbacks —
adds cross-callback state to the swap path for a sub-1k saving, and creates a state that must
be proven correct under nesting and reentrancy. Two independent stateless validations of the
same calldata is the simpler and more robust shape. `PoolManager` passes the identical
`hookData` bytes to both callbacks, so they cannot disagree.

Validating early also means malformed data fails **before** the pool executes, which is a
cheaper revert and puts the error at the site the integrator can act on.

Pool not configured for bonding (`bondBps == 0`) → no `hookData` requirement, because no bond
can ever arise.

## 10. Accounting invariants

For every **successful bonded exact-output** swap, per currency:

```
poolInput  > 0
bond       > 0
bond       = floor(poolInput * bondBps / (10_000 - bondBps))
grossInput = poolInput + bond
bond      <= maxBondAmount                        (trader's own ceiling, from hookData)
hook input-currency balance increase == bond      exactly
trader receives exactly the requested output
hook's PoolManager delta == 0 in both currencies at the end of the unlock
hook holds zero ERC-6909 claims
```

The hook's delta nets to zero because the `-bond` debt from `take` is cancelled by the `+bond`
credit `PoolManager.sol:224` applies from the returned `hookDelta`. If those two ever
disagreed, `PoolManager` would revert the whole unlock with `CurrencyNotSettled` — the
accounting cannot silently drift.

### On INV-NOOP

`AGENTS.md` § Delta safety defines INV-NOOP as
`0 < deltaSpecified < |amountSpecified|`, strictly, and its rationale is entirely about
`beforeSwapReturnDelta` and `Hooks.sol:277`.

**Exact-output does not use `beforeSwapReturnDelta` at all** — `beforeSwap` returns
`ZERO_DELTA` on this path. The NoOp rug-pull vector INV-NOOP guards is therefore
**structurally absent** here: there is no specified-side delta to inflate, the pool has already
executed by the time we act, and the bond is added on top rather than carved out, so there is
no "leave the pool nothing to swap" failure mode to reach.

INV-NOOP continues to hold, unchanged and unweakened, on the exact-input path, which is the
only path that returns a non-zero `deltaSpecified`.

The exact-output path needs its own bound, because "added on top" means the trader's cost can
in principle grow without limit. Three independent ceilings apply:

1. **`MAX_BOND_BPS = 100`**, a compile-time constant no owner can raise, bounding the bond at
   `poolInput × 100 / 9_900 ≈ 1.0101%` of pool input.
2. **`maxBondAmount`**, supplied by the trader in `hookData`, not owner-modifiable.
3. **`amountInMaximum`**, enforced by the router on `poolInput + bond` (§ 8).

## 11. Rollback and revert behaviour

Every failure on the exact-output path **reverts the entire transaction**, including the pool
swap that has already executed by the time `afterSwap` runs. This is not something the hook
arranges — it is the EVM's atomicity. A revert thrown from `afterSwap` unwinds the whole
`unlock`, so the swap is not merely un-settled, it never happened.

The consequence worth stating: **there is no state in which the pool swap stands but bond
validation failed.** The trader either gets their exact output *and* pays the bond, or nothing
happens at all.

Reverting failures on this path: missing/malformed/wrong-version `hookData`
(`beforeSwap`, before execution); bond rounding to zero on a swap that qualified as bonded;
bond exceeding `maxBondAmount`; and — outside the hook — the router's `V4TooMuchRequested`
when `poolInput + bond` breaches the trader's ceiling.

## 12. Permission bits and deployment

`afterSwapReturnDelta` (`AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2`) must be enabled.
`Hooks.isValidHookAddress` (`Hooks.sol:112`) requires `AFTER_SWAP_FLAG` alongside it; we
already have it.

| | Bits | Value |
|---|---|---|
| After T3A | `AFTER_INITIALIZE` \| `BEFORE_SWAP` \| `AFTER_SWAP` \| `BEFORE_SWAP_RETURNS_DELTA` | `0x10C8` |
| **After T3B** | the above \| `AFTER_SWAP_RETURNS_DELTA (1<<2)` | **`0x10CC`** |

**Consequences.** The hook's address changes, so the CREATE2 salt must be re-mined and every
existing deployment is at a now-invalid address and must be redeployed. Mining stays run-time
via `HookMiner.find`, targeting `CREATE2_DEPLOYER` under `forge script` and `address(this)`
under `forge test`. **No address is hardcoded anywhere.** The bits live in one shared
`HOOK_FLAGS` constant (ADR-0001 § 11), and `test_hookFlagsConstantMatchesPermissions` pins it
against `getHookPermissions()`.

Enabling the flag does **not** change exact-input behaviour: our `afterSwap` returns `0` on
that path, and `hookDeltaUnspecified` stays zero exactly as before.

## 13. Supported and unsupported after T3B

**Supported and tested:** exact-input single-hop ERC-20↔ERC-20; **exact-output single-hop
ERC-20↔ERC-20**, both directions.

**Still unsupported.** Not claimed, not tested, and — importantly — **not detected**:

- **Multi-hop.** Each hop is a separate `swap` with its own `hookData`. A route through two
  BondMeBro pools bonds each hop separately and reuses the same `hookData` for both. No revert.
- **Native currency.** `CurrencySettler` handles it, but the settle path differs and nothing
  here is tested against it.
- **Fee-on-transfer / rebasing tokens.** § 10's reconciliation assumes transferred equals
  received. Custody would come up silently short.

Per `AGENTS.md`: do not claim support merely because the router accepts the call.

## 14. Consequences

**Positive**

- The bypass is closed. Exact-output no longer avoids collateral.
- One economic rule — `bondBps` of gross input — across both swap kinds.
- The bond is in the input currency on both paths, so settlement stays uniform.
- The router's existing slippage check already covers the bond; no new trader-facing
  protection had to be invented.

**Negative / accepted**

- A second custody point means two code paths to keep correct.
- Exact-output pays for two `hookData` decodes (§ 9).
- Exact-output `afterSwap` now performs a token transfer and is expected over its 30,000 gas
  target. Ceilings still hold. Measured figures are in the review report.
- Every exact-output swap on a bonding pool must carry `hookData`, even sub-threshold ones —
  a stricter integration requirement than exact-input.
- Redeploy at a newly mined address.

## 15. References

Paths relative to repo root; line numbers against the installed pins (v4-periphery
`dce236d4`, v4-core `59d3ecf5`, uniswap-hooks `acbd604c` / v1.2.1).

- `lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol:298-312` — `afterSwap` delta assembly;
  `:307` the specified/unspecified mapping; `:312` `swapDelta - hookDelta`; `:45`
  `AFTER_SWAP_RETURNS_DELTA_FLAG`; `:112` flag dependency.
- `lib/v4-periphery/lib/v4-core/src/PoolManager.sol:221-226` — post-hook `swapDelta`, hook and
  caller delta accounting.
- `lib/v4-periphery/src/V4Router.sol:143-150` — exact-output `amountInMaximum` check;
  `:240-242` `_swapInput`; `:225` the `poolManager.swap` call.
- `lib/v4-periphery/test/mocks/MockV4Router.sol` — concrete `V4Router` descendant; implements
  only `_pay` and `msgSender`, inherits the real slippage check.
- `lib/v4-periphery/lib/v4-core/src/test/FeeTakingHook.sol:35-52` — the take-and-return-positive
  shape mirrored here.
- `lib/v4-periphery/lib/v4-core/src/libraries/FullMath.sol:14` — `mulDiv`.
- [ADR-0001](0001-in-hook-custody.md) — in-hook custody, exact-input path, INV-NOOP, bond
  economics.
