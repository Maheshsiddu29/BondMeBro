import { describe, expect, it } from "vitest";

import type { Deployment } from "@/lib/deployment";
import {
  bondEligibility,
  collateralIsCurrency0,
  poolConfigFromEvent,
  poolConfigFromGetter,
  poolConfigSetterArgs,
  thresholdsFor,
  validatePoolConfig,
  type PoolConfig,
} from "@/lib/poolConfig";

const CURRENCY0 = "0x00000000000000000000000000000000000000a1" as const;
const CURRENCY1 = "0x00000000000000000000000000000000000000b2" as const;

const deployment = {
  chainId: 31_337,
  networkName: "Local",
  explorerUrl: "https://example.invalid",
  hook: "0x7b5b5759918646ce36d7f5efd1a17aa6a5e7d0c4",
  poolManager: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  universalRouter: "0x0000000000000000000000000000000000000010",
  quoter: "0x0000000000000000000000000000000000000011",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  currency0: CURRENCY0,
  currency1: CURRENCY1,
  fee: 3_000,
  tickSpacing: 60,
  poolId: `0x${"11".repeat(32)}`,
  deploymentBlock: 1n,
} as unknown as Deployment;

const config: PoolConfig = {
  minBondedAmount0: 1_000_000n,
  minBondedAmount1: 2_000_000n,
  bondingEnabled: true,
  minVariableLeg0: 10_000n,
  minVariableLeg1: 20_000n,
};

/**
 * TESTS 5-8 — the collateral currency for each of the four mode/direction combinations.
 * TESTS 2-3 — getter and setter orderings are distinct and not interchangeable.
 * TEST 25   — a settled bond is not "active" merely because a record exists (see bond.test).
 */
describe("BMB-01 pool configuration", () => {
  it("reads the getter tuple with bondingEnabled in position three", () => {
    const parsed = poolConfigFromGetter([1n, 2n, true, 3n, 4n]);
    expect(parsed).toEqual({
      minBondedAmount0: 1n,
      minBondedAmount1: 2n,
      bondingEnabled: true,
      minVariableLeg0: 3n,
      minVariableLeg1: 4n,
    });
  });

  it("builds setter arguments with bondingEnabled LAST", () => {
    const args = poolConfigSetterArgs(deployment, config);
    expect(args[0]).toEqual({
      currency0: CURRENCY0,
      currency1: CURRENCY1,
      fee: 3_000,
      tickSpacing: 60,
      hooks: deployment.hook,
    });
    expect(args.slice(1)).toEqual([1_000_000n, 2_000_000n, 10_000n, 20_000n, true]);
    // The getter's third slot is the boolean; the setter's third argument is a threshold.
    expect(typeof args[3]).toBe("bigint");
    expect(typeof args[6 - 1]).toBe("boolean");
  });

  it("reads the event in EVENT order, which is not the getter order", () => {
    const parsed = poolConfigFromEvent({
      minBondedAmount0: 1n,
      minBondedAmount1: 2n,
      minVariableLeg0: 3n,
      minVariableLeg1: 4n,
      bondingEnabled: false,
    });
    expect(parsed).toEqual({
      minBondedAmount0: 1n,
      minBondedAmount1: 2n,
      bondingEnabled: false,
      minVariableLeg0: 3n,
      minVariableLeg1: 4n,
    });
  });

  it("enforces the 10,000 raw-unit variable-leg floor when enabling", () => {
    expect(validatePoolConfig(config, 10_000n)).toEqual([]);
    expect(validatePoolConfig({ ...config, minVariableLeg0: 9_999n }, 10_000n)).toEqual([
      "Enabling bonding requires both variable-leg minimums to be at least 10000 raw units.",
    ]);
    expect(validatePoolConfig({ ...config, minBondedAmount0: 0n }, 10_000n)).toContain(
      "Enabling bonding requires both input minimums to be greater than zero.",
    );
    // Disabling clears the thresholds, so it does not have to satisfy the floors.
    expect(
      validatePoolConfig({ ...config, bondingEnabled: false, minVariableLeg0: 0n }, 10_000n),
    ).toEqual([]);
  });

  it("rejects a currency1 input minimum wider than uint96", () => {
    expect(validatePoolConfig({ ...config, minBondedAmount1: 1n << 96n }, 10_000n)).toContain(
      "minBondedAmount1 does not fit in uint96.",
    );
  });
});

describe("collateral currency mapping", () => {
  it("EXACT INPUT zeroForOne takes collateral in currency1", () => {
    expect(collateralIsCurrency0("exactInput", true)).toBe(false);
    const mapping = thresholdsFor({ config, deployment, kind: "exactInput", zeroForOne: true });
    expect(mapping.collateralCurrency).toBe(CURRENCY1);
    expect(mapping.consumedInputMinimum).toBe(config.minBondedAmount0);
    expect(mapping.variableLegMinimum).toBe(config.minVariableLeg1);
    expect(mapping.inputCurrency).toBe(CURRENCY0);
  });

  it("EXACT INPUT oneForZero takes collateral in currency0", () => {
    expect(collateralIsCurrency0("exactInput", false)).toBe(true);
    const mapping = thresholdsFor({ config, deployment, kind: "exactInput", zeroForOne: false });
    expect(mapping.collateralCurrency).toBe(CURRENCY0);
    expect(mapping.consumedInputMinimum).toBe(config.minBondedAmount1);
    expect(mapping.variableLegMinimum).toBe(config.minVariableLeg0);
    expect(mapping.inputCurrency).toBe(CURRENCY1);
  });

  it("EXACT OUTPUT zeroForOne takes collateral in currency0", () => {
    expect(collateralIsCurrency0("exactOutput", true)).toBe(true);
    const mapping = thresholdsFor({ config, deployment, kind: "exactOutput", zeroForOne: true });
    expect(mapping.collateralCurrency).toBe(CURRENCY0);
    expect(mapping.consumedInputMinimum).toBe(config.minBondedAmount0);
    expect(mapping.variableLegMinimum).toBe(config.minVariableLeg0);
  });

  it("EXACT OUTPUT oneForZero takes collateral in currency1", () => {
    expect(collateralIsCurrency0("exactOutput", false)).toBe(false);
    const mapping = thresholdsFor({ config, deployment, kind: "exactOutput", zeroForOne: false });
    expect(mapping.collateralCurrency).toBe(CURRENCY1);
    expect(mapping.consumedInputMinimum).toBe(config.minBondedAmount1);
    expect(mapping.variableLegMinimum).toBe(config.minVariableLeg1);
  });
});

describe("bond eligibility versus swap availability", () => {
  const thresholds = thresholdsFor({ config, deployment, kind: "exactInput", zeroForOne: true });

  it("treats a disabled pool as unbonded, not unswappable", () => {
    const result = bondEligibility({
      config: { ...config, bondingEnabled: false },
      thresholds,
      consumedInput: 10n ** 18n,
      variableLeg: 10n ** 18n,
    });
    expect(result.eligible).toBe(false);
    expect(result.reason).toMatch(/executes unbonded/);
  });

  it("treats a below-minimum trade as unbonded, not as an error", () => {
    expect(
      bondEligibility({ config, thresholds, consumedInput: 1n, variableLeg: 10n ** 18n }).reason,
    ).toMatch(/input minimum/);
    expect(
      bondEligibility({ config, thresholds, consumedInput: 10n ** 18n, variableLeg: 1n }).reason,
    ).toMatch(/variable leg/);
  });

  it("reports eligibility when both minimums are met", () => {
    expect(
      bondEligibility({ config, thresholds, consumedInput: 10n ** 18n, variableLeg: 10n ** 18n }),
    ).toEqual({ eligible: true });
  });
});
