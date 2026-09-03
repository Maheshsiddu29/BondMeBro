import type { Address } from "viem";

import type { Deployment } from "@/lib/deployment";

/**
 * BMB-01 pool configuration.
 *
 * THREE DIFFERENT FIELD ORDERS EXIST AND THEY MUST NOT BE UNIFIED.
 *
 *   getter  poolConfig(bytes32) ->
 *             minBondedAmount0, minBondedAmount1, bondingEnabled, minVariableLeg0, minVariableLeg1
 *
 *   setter  setPoolConfig(PoolKey,
 *             minBondedAmount0, minBondedAmount1, minVariableLeg0, minVariableLeg1, bondingEnabled)
 *
 *   event   PoolConfigured(bytes32 indexed id,
 *             minBondedAmount0, minBondedAmount1, minVariableLeg0, minVariableLeg1, bondingEnabled)
 *
 * The struct puts `bondingEnabled` third so it packs beside the two input minimums; the
 * setter and event put it last. Reusing one positional tuple for all three would read the
 * enable flag as a threshold. Everything below therefore uses named fields.
 */
export type PoolConfig = {
  /** Minimum consumed input in raw currency0 units. Applies when zeroForOne. */
  minBondedAmount0: bigint;
  /** Minimum consumed input in raw currency1 units. Applies when oneForZero. uint96. */
  minBondedAmount1: bigint;
  /** Whether the pool takes collateral at all. Swapping is unaffected by this flag. */
  bondingEnabled: boolean;
  /** Minimum variable leg in raw currency0 units, used when collateral is currency0. */
  minVariableLeg0: bigint;
  /** Minimum variable leg in raw currency1 units, used when collateral is currency1. */
  minVariableLeg1: bigint;
};

/** Raw tuple returned by the getter, in getter order. */
export type PoolConfigGetterTuple = readonly [bigint, bigint, boolean, bigint, bigint];

export function poolConfigFromGetter(tuple: PoolConfigGetterTuple): PoolConfig {
  return {
    minBondedAmount0: tuple[0],
    minBondedAmount1: tuple[1],
    bondingEnabled: tuple[2],
    minVariableLeg0: tuple[3],
    minVariableLeg1: tuple[4],
  };
}

/**
 * Arguments for `setPoolConfig`, in SETTER order, with the pool key first.
 *
 * Note the boolean moves from position 3 in the getter to last here.
 */
export function poolConfigSetterArgs(
  deployment: Deployment,
  config: PoolConfig,
): readonly [
  { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address },
  bigint,
  bigint,
  bigint,
  bigint,
  boolean,
] {
  return [
    {
      currency0: deployment.currency0,
      currency1: deployment.currency1,
      fee: deployment.fee,
      tickSpacing: deployment.tickSpacing,
      hooks: deployment.hook,
    },
    config.minBondedAmount0,
    config.minBondedAmount1,
    config.minVariableLeg0,
    config.minVariableLeg1,
    config.bondingEnabled,
  ] as const;
}

/** Decoded `PoolConfigured` args, in EVENT order. */
export type PoolConfiguredEventArgs = {
  id?: `0x${string}`;
  minBondedAmount0?: bigint;
  minBondedAmount1?: bigint;
  minVariableLeg0?: bigint;
  minVariableLeg1?: bigint;
  bondingEnabled?: boolean;
};

/**
 * The event is NOT canonical.
 *
 * Disabling a pool clears all four stored thresholds, but the event still carries the
 * values that were supplied to the call. Always re-read `poolConfig(poolId)` after a
 * configuration transaction and treat the getter as the truth.
 */
export function poolConfigFromEvent(args: PoolConfiguredEventArgs): PoolConfig | undefined {
  if (
    args.minBondedAmount0 === undefined
    || args.minBondedAmount1 === undefined
    || args.minVariableLeg0 === undefined
    || args.minVariableLeg1 === undefined
    || args.bondingEnabled === undefined
  ) {
    return undefined;
  }
  return {
    minBondedAmount0: args.minBondedAmount0,
    minBondedAmount1: args.minBondedAmount1,
    bondingEnabled: args.bondingEnabled,
    minVariableLeg0: args.minVariableLeg0,
    minVariableLeg1: args.minVariableLeg1,
  };
}

export const UINT96_MAX = (1n << 96n) - 1n;
export const UINT128_MAX = (1n << 128n) - 1n;

/**
 * Validates a configuration the way `setPoolConfig` does.
 *
 * When enabling: both input minimums must be positive and both variable-leg minimums must
 * be at least `BPS` raw units — 10,000 on the current baseline. That floor is what makes a
 * bonded swap always produce at least one raw unit of collateral.
 *
 * 10,000 raw units is 0.00000000000001 tokens at 18 decimals, 0.0001 at 8 and 0.01 at 6.
 * It is a raw-unit floor, not a token amount, and must be labelled as such in any UI.
 */
export function validatePoolConfig(config: PoolConfig, bps: bigint): string[] {
  const problems: string[] = [];

  if (config.minBondedAmount0 < 0n || config.minBondedAmount0 > UINT128_MAX) {
    problems.push("minBondedAmount0 does not fit in uint128.");
  }
  if (config.minBondedAmount1 < 0n || config.minBondedAmount1 > UINT96_MAX) {
    problems.push("minBondedAmount1 does not fit in uint96.");
  }
  if (config.minVariableLeg0 < 0n || config.minVariableLeg0 > UINT128_MAX) {
    problems.push("minVariableLeg0 does not fit in uint128.");
  }
  if (config.minVariableLeg1 < 0n || config.minVariableLeg1 > UINT128_MAX) {
    problems.push("minVariableLeg1 does not fit in uint128.");
  }

  if (config.bondingEnabled) {
    if (config.minBondedAmount0 === 0n || config.minBondedAmount1 === 0n) {
      problems.push("Enabling bonding requires both input minimums to be greater than zero.");
    }
    if (config.minVariableLeg0 < bps || config.minVariableLeg1 < bps) {
      problems.push(
        `Enabling bonding requires both variable-leg minimums to be at least ${bps} raw units.`,
      );
    }
  }

  return problems;
}

export type SwapKind = "exactInput" | "exactOutput";

/**
 * Which currency the collateral is taken in.
 *
 * `_collateralIsCurrency0(zeroForOne, exactInput) = exactInput ? !zeroForOne : zeroForOne`
 * in src/BondMeBro.sol. Exact input pays collateral out of what it receives; exact output
 * pays it as extra input.
 */
export function collateralIsCurrency0(kind: SwapKind, zeroForOne: boolean): boolean {
  return kind === "exactInput" ? !zeroForOne : zeroForOne;
}

export type ThresholdMapping = {
  /** Threshold applied to the input the pool actually consumes. */
  consumedInputMinimum: bigint;
  /** Threshold applied to the leg the collateral is carved from. */
  variableLegMinimum: bigint;
  /** The token collateral will be taken in. */
  collateralCurrency: Address;
  collateralIsCurrency0: boolean;
  /** The token the pool consumes. */
  inputCurrency: Address;
};

/**
 * Maps a swap kind and direction onto the four BMB-01 thresholds and the collateral token.
 *
 *   EI zeroForOne  input min = minBondedAmount0   leg min = minVariableLeg1  collateral = currency1
 *   EI oneForZero  input min = minBondedAmount1   leg min = minVariableLeg0  collateral = currency0
 *   EO zeroForOne  input min = minBondedAmount0   leg min = minVariableLeg0  collateral = currency0
 *   EO oneForZero  input min = minBondedAmount1   leg min = minVariableLeg1  collateral = currency1
 *
 * The consumed-input minimum always follows the direction; only the variable-leg minimum
 * and the collateral currency depend on the swap kind as well.
 */
export function thresholdsFor({
  config,
  deployment,
  kind,
  zeroForOne,
}: {
  config: PoolConfig;
  deployment: Deployment;
  kind: SwapKind;
  zeroForOne: boolean;
}): ThresholdMapping {
  const isCurrency0 = collateralIsCurrency0(kind, zeroForOne);
  return {
    consumedInputMinimum: zeroForOne ? config.minBondedAmount0 : config.minBondedAmount1,
    variableLegMinimum: isCurrency0 ? config.minVariableLeg0 : config.minVariableLeg1,
    collateralCurrency: isCurrency0 ? deployment.currency0 : deployment.currency1,
    collateralIsCurrency0: isCurrency0,
    inputCurrency: zeroForOne ? deployment.currency0 : deployment.currency1,
  };
}

/**
 * Whether this particular trade can produce a bond.
 *
 * A trade that fails either minimum still executes normally; it simply produces no bond.
 * "Bonding is disabled" and "swapping is unavailable" are different statements, and the
 * UI must never turn the first into the second.
 */
export function bondEligibility({
  config,
  thresholds,
  consumedInput,
  variableLeg,
}: {
  config: PoolConfig;
  thresholds: ThresholdMapping;
  consumedInput?: bigint;
  variableLeg?: bigint;
}): { eligible: boolean; reason?: string } {
  if (!config.bondingEnabled) {
    return { eligible: false, reason: "Bonding is disabled for this pool. The swap executes unbonded." };
  }
  if (consumedInput !== undefined && consumedInput < thresholds.consumedInputMinimum) {
    return { eligible: false, reason: "This trade is below the pool's input minimum, so it executes unbonded." };
  }
  if (variableLeg !== undefined && variableLeg < thresholds.variableLegMinimum) {
    return {
      eligible: false,
      reason: "This trade's variable leg is below the pool's minimum, so it executes unbonded.",
    };
  }
  return { eligible: true };
}
