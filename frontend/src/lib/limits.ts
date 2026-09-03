import { EXACT_INPUT_MAX_BOND_AMOUNT, UINT128_MAX } from "@/lib/hookData";

/**
 * Slippage and collateral limits for both swap kinds.
 *
 * All arithmetic here is bigint. Nothing in this file may become a JavaScript number:
 * these values are signed into transactions, and a float would silently lose raw units
 * on any 18-decimal amount above 2^53.
 *
 * `BPS` and `MAX_BOND_BPS` are read from the hook rather than written as literals, so a
 * redeployment with different frozen constants cannot leave stale divisors behind. The
 * literals 1.01, 101 and 100/101 must never appear.
 */
export type HookConstants = {
  /** hook.BPS() — 10,000 on the current baseline. */
  bps: bigint;
  /** hook.MAX_BOND_BPS() — 100 on the current baseline. */
  maxBondBps: bigint;
};

export class LimitError extends Error {}

function assertConstants({ bps, maxBondBps }: HookConstants) {
  if (bps <= 0n) throw new LimitError("The hook reported a non-positive BPS denominator.");
  if (maxBondBps <= 0n) throw new LimitError("The hook reported a non-positive collateral cap.");
  if (maxBondBps > bps) throw new LimitError("The hook reported a collateral cap above 100%.");
}

export type ExactInputLimits = {
  /** Always the uint128 maximum. Protection comes from `amountOutMinimum`. */
  maxBondAmount: bigint;
  /** The net output the router must deliver, or the swap reverts. */
  amountOutMinimum: bigint;
};

/**
 * Exact input: the user chooses the input, the hook withholds collateral from the output.
 *
 * `toleranceBps` is the user's ordinary slippage budget. Per INTEGRATION.md § 2 a budget
 * at or above `MAX_BOND_BPS` is what makes a swap immune to reverting on block ordering
 * alone; below that the swap can revert because a large same-block trade landed first.
 * That is the user's decision, not a value this code should override.
 */
export function exactInputLimits({
  quotedNetOutput,
  toleranceBps,
  constants,
}: {
  quotedNetOutput: bigint;
  toleranceBps: bigint;
  constants: HookConstants;
}): ExactInputLimits {
  assertConstants(constants);
  if (quotedNetOutput < 0n) throw new LimitError("The quoted output is negative.");
  if (toleranceBps < 0n || toleranceBps > constants.bps) {
    throw new LimitError("The slippage tolerance must be between 0 and 100%.");
  }

  return {
    maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
    amountOutMinimum: (quotedNetOutput * (constants.bps - toleranceBps)) / constants.bps,
  };
}

/** True when the chosen tolerance cannot be exhausted by block ordering alone. */
export function toleranceCoversCollateralCap(toleranceBps: bigint, constants: HookConstants) {
  return toleranceBps >= constants.maxBondBps;
}

export type ExactOutputLimits = {
  /** Q: the quoter's result. TOTAL input, already including simulated collateral. */
  quotedTotalInput: bigint;
  /** Maximum TOTAL input the user authorises, collateral included. Rounds UP. */
  amountInMaximum: bigint;
  /** Collateral ceiling carried in hookData, in input-token raw units. Rounds DOWN. */
  maxBondAmount: bigint;
  /**
   * True when the derived ceiling was zero and the trade was PROVEN unable to bond, so the
   * smallest valid ceiling is carried purely to satisfy the codec. See `exactOutputLimits`.
   */
  ceilingIsProvenUnbonded: boolean;
};

/**
 * ceil(Q * (BPS + toleranceBps) / BPS).
 *
 * Q is the exact-output quote, which is ALREADY the total input including the collateral
 * simulated at quote-time pool state. The only thing left to add is the user's own price
 * slippage budget. Multiplying by (BPS + MAX_BOND_BPS) / BPS on top of this would add a
 * second collateral allowance to a figure that already contains one.
 *
 * Rounds up: rounding down leaves the authorisation a raw unit too tight and can reject a
 * swap the user's own tolerance was meant to admit.
 */
export function exactOutputAmountInMaximum(
  quotedTotalInput: bigint,
  toleranceBps: bigint,
  constants: HookConstants,
): bigint {
  assertConstants(constants);
  return (quotedTotalInput * (constants.bps + toleranceBps) + constants.bps - 1n) / constants.bps;
}

/**
 * floor(amountInMaximum * MAX_BOND_BPS / (BPS + MAX_BOND_BPS)).
 *
 * The bond ceiling is derived from the SAME total-input cap the user authorises, so the two
 * bounds bind at the same moment: at a pool input of amountInMaximum * BPS / (BPS +
 * MAX_BOND_BPS), the collateral at the cap is exactly this amount. Rounds down.
 */
export function exactOutputMaxBondAmount(amountInMaximum: bigint, constants: HookConstants): bigint {
  assertConstants(constants);
  return (amountInMaximum * constants.maxBondBps) / (constants.bps + constants.maxBondBps);
}

/**
 * Exact output: the user chooses the output, the hook requires extra input as collateral.
 *
 * With Q the quoter result, S the user's tolerance in bps, B = hook.BPS() and
 * C = hook.MAX_BOND_BPS():
 *
 *   amountInMaximum = ceil( Q * (B + S) / B )
 *   maxBondAmount   = floor( amountInMaximum * C / (B + C) )
 *
 * `amountInMaximum` is the maximum TOTAL input the user authorises, collateral included. It
 * is not a pre-collateral pool input, and this model never tries to recover one: the exact
 * pre-collateral figure is not derivable from the quote, because the simulated rate can be
 * anywhere between zero and the cap. The quote is already the right starting point.
 *
 * Both C-derived expressions read C from the hook rather than a literal, so a redeployment
 * with a different cap changes both. The literals 1.01, 101 and 100/101 appear nowhere.
 */
export function exactOutputLimits({
  quotedTotalInput,
  toleranceBps,
  constants,
  bondingEnabled,
  bondingMinimum,
}: {
  /** Q. The quoter's exact-output result: TOTAL input, collateral already included. */
  quotedTotalInput: bigint;
  /** S, in basis points. */
  toleranceBps: bigint;
  constants: HookConstants;
  /**
   * Whether this pool takes collateral at all. A disabled pool never decodes hookData, so a
   * zero-derived ceiling cannot reach the codec.
   */
  bondingEnabled: boolean;
  /**
   * The smallest total input at which this pool could bond this trade, in input-token raw
   * units: the larger of the consumed-input minimum and the variable-leg minimum for the
   * collateral currency. For exact output the collateral currency IS the input, and the
   * variable leg IS the consumed input, so both gates measure the same quantity.
   *
   * Undefined when the pool configuration has not been read. Without it no proof is
   * available and a zero-derived ceiling fails closed.
   */
  bondingMinimum?: bigint;
}): ExactOutputLimits {
  assertConstants(constants);
  if (quotedTotalInput < 0n) throw new LimitError("The quoted input is negative.");
  if (quotedTotalInput > UINT128_MAX) throw new LimitError("The quoted input does not fit in uint128.");
  if (toleranceBps < 0n || toleranceBps > constants.bps) {
    throw new LimitError("The slippage tolerance must be between 0 and 100%.");
  }

  const amountInMaximum = exactOutputAmountInMaximum(quotedTotalInput, toleranceBps, constants);
  if (amountInMaximum > UINT128_MAX) {
    throw new LimitError("The resulting maximum input does not fit the router's uint128 field.");
  }

  const derivedCeiling = exactOutputMaxBondAmount(amountInMaximum, constants);
  if (derivedCeiling > 0n) {
    return { quotedTotalInput, amountInMaximum, maxBondAmount: derivedCeiling, ceilingIsProvenUnbonded: false };
  }

  // ZERO-CEILING EDGE CASE.
  //
  // hookData rejects a zero ceiling, and an exact-output swap on a bonding-ENABLED pool
  // always decodes hookData: `_beforeSwap` only skips the decode for exact input below the
  // consumed-input minimum, and exact output has amountSpecified > 0. So a valid non-zero
  // ceiling is mandatory even for a trade that will end up unbonded.
  //
  // Substituting 1 blindly would be wrong — it would silently cap a real bond at one raw
  // unit and turn an ordinary bonded swap into a BondExceedsTraderMax revert. It is only
  // safe where the trade PROVABLY cannot bond, because the hook checks the ceiling last:
  // `_takeVariableLegBond` returns zero at the bonding, consumed-input and variable-leg
  // gates before it ever decodes hookData or compares the bond to the ceiling.
  if (!bondingEnabled) {
    // A disabled pool returns from both callbacks before decoding hookData at all, so the
    // value carried is never read. Carry the smallest valid one.
    return { quotedTotalInput, amountInMaximum, maxBondAmount: 1n, ceilingIsProvenUnbonded: true };
  }

  if (bondingMinimum !== undefined && amountInMaximum < bondingMinimum) {
    // The pool cannot consume more than amountInMaximum without the router reverting on its
    // own maximum-input check, and below `bondingMinimum` the hook returns zero before the
    // ceiling is consulted. Either way no bond can be taken against this ceiling.
    return { quotedTotalInput, amountInMaximum, maxBondAmount: 1n, ceilingIsProvenUnbonded: true };
  }

  // No proof available: the configuration is unread, or the trade is large enough that this
  // pool could bond it while the derived ceiling still rounds to zero. Fail closed rather
  // than sign a ceiling that could reject a legitimate bond.
  throw new LimitError(
    "This amount is too small for an exact-output swap on this route: the collateral ceiling it "
      + "implies rounds to zero, and this pool could still bond a trade of that size. Increase the "
      + "output amount.",
  );
}

/**
 * The rate curve from src/BondMeBro.sol, for labelled estimates only.
 *
 *   effectiveImpact = max(|tickAfter - tickBefore|, |tickAfter - blockStartTick|)
 *   collateralBps   = min(MAX_BOND_BPS, ceil(effectiveImpact * COLLATERAL_SCALE / 100))
 *
 * `blockStartTick` belongs to the block the transaction lands in, so a pre-trade figure
 * derived from quote-time state is an estimate and must be labelled as one.
 */
export const COLLATERAL_SCALE = 25n;
export const COLLATERAL_SCALE_DENOMINATOR = 100n;

function absDelta(a: bigint, b: bigint) {
  const d = a - b;
  return d < 0n ? -d : d;
}

export function effectiveImpactTicks({
  tickBefore,
  tickAfter,
  blockStartTick,
}: {
  tickBefore: bigint;
  tickAfter: bigint;
  blockStartTick: bigint;
}) {
  const own = absDelta(tickAfter, tickBefore);
  const blockDisplacement = absDelta(tickAfter, blockStartTick);
  return own > blockDisplacement ? own : blockDisplacement;
}

export function collateralBpsForImpact(effectiveImpact: bigint, constants: HookConstants) {
  if (effectiveImpact <= 0n) return 0n;
  const raw =
    (effectiveImpact * COLLATERAL_SCALE + COLLATERAL_SCALE_DENOMINATOR - 1n) / COLLATERAL_SCALE_DENOMINATOR;
  return raw > constants.maxBondBps ? constants.maxBondBps : raw;
}

/** collateral = floor(variableLeg * rate / BPS), as the hook computes it. */
export function collateralFromVariableLeg(variableLeg: bigint, collateralBps: bigint, constants: HookConstants) {
  if (variableLeg <= 0n || collateralBps <= 0n) return 0n;
  return (variableLeg * collateralBps) / constants.bps;
}
