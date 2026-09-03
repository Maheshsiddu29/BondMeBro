import { describe, expect, it } from "vitest";

import { EXACT_INPUT_MAX_BOND_AMOUNT } from "@/lib/hookData";
import {
  collateralBpsForImpact,
  collateralFromVariableLeg,
  effectiveImpactTicks,
  exactInputLimits,
  exactOutputAmountInMaximum,
  exactOutputLimits,
  exactOutputMaxBondAmount,
  LimitError,
  toleranceCoversCollateralCap,
  type HookConstants,
} from "@/lib/limits";

/** The current baseline: hook.BPS() = 10,000 and hook.MAX_BOND_BPS() = 100. */
const constants: HookConstants = { bps: 10_000n, maxBondBps: 100n };

/** Enough headroom that the zero-ceiling branch is never the thing under test. */
const bondable = { bondingEnabled: true, bondingMinimum: 10_000n };

/**
 * TEST 9  — exact-input maxBondAmount == uint128 max.
 * TEST 10 — exact-output amountInMaximum rounds UP.
 * TEST 11 — exact-output maxBondAmount rounds DOWN.
 */
describe("exact-input limits", () => {
  it("always uses the unbounded ceiling and protects with the net minimum", () => {
    const limits = exactInputLimits({ quotedNetOutput: 1_000_000n, toleranceBps: 150n, constants });
    expect(limits.maxBondAmount).toBe(EXACT_INPUT_MAX_BOND_AMOUNT);
    expect(limits.amountOutMinimum).toBe((1_000_000n * 9_850n) / 10_000n);
  });

  it("reports whether the chosen tolerance can absorb the whole collateral cap", () => {
    expect(toleranceCoversCollateralCap(100n, constants)).toBe(true);
    expect(toleranceCoversCollateralCap(99n, constants)).toBe(false);
  });
});

/**
 * The exact-output quote is the TOTAL input, collateral already included. These tests exist
 * because an earlier revision treated it as a pre-collateral pool input and then applied the
 * (B + C) / B headroom on top, adding a second collateral allowance to a figure that already
 * contained one.
 */
describe("exact output: the quote is already the total input", () => {
  it("returns the quote unchanged when the user asks for no slippage headroom", () => {
    const limits = exactOutputLimits({
      quotedTotalInput: 1_000_000n,
      toleranceBps: 0n,
      constants,
      ...bondable,
    });
    // Zero tolerance means zero headroom. Anything above the quote here would be a second
    // collateral allowance layered on one the quote already carries.
    expect(limits.amountInMaximum).toBe(1_000_000n);
    expect(limits.quotedTotalInput).toBe(1_000_000n);
  });

  it("applies the slippage tolerance exactly once", () => {
    const q = 10_000_000n;
    const s = 50n;
    const limits = exactOutputLimits({ quotedTotalInput: q, toleranceBps: s, constants, ...bondable });

    // ceil(Q * (B + S) / B), applied one time.
    expect(limits.amountInMaximum).toBe((q * (constants.bps + s)) / constants.bps);

    // Applying the tolerance twice would give this. It must not.
    const twice = (q * (constants.bps + s) * (constants.bps + s)) / (constants.bps * constants.bps);
    expect(limits.amountInMaximum).not.toBe(twice);
  });

  it("does NOT inflate by (B + C) / B after the quote", () => {
    const q = 10_000_000n;
    const s = 50n;
    const limits = exactOutputLimits({ quotedTotalInput: q, toleranceBps: s, constants, ...bondable });

    const withSecondCollateralHeadroom =
      (limits.amountInMaximum * (constants.bps + constants.maxBondBps) + constants.bps - 1n) / constants.bps;

    expect(limits.amountInMaximum).toBeLessThan(withSecondCollateralHeadroom);
    expect(limits.amountInMaximum).not.toBe(withSecondCollateralHeadroom);
    // The rejected model's exact output for these inputs.
    expect(withSecondCollateralHeadroom).toBe(10_150_500n);
    expect(limits.amountInMaximum).toBe(10_050_000n);
  });

  it("pins the worked example: Q = 100 units, S = 50 bps, C = 100 bps", () => {
    // 100 units at six decimals, so the half-unit is representable in raw units.
    const q = 100_000_000n;
    const limits = exactOutputLimits({ quotedTotalInput: q, toleranceBps: 50n, constants, ...bondable });

    // 100.5 units, not 101.505 units.
    expect(limits.amountInMaximum).toBe(100_500_000n);
    expect(limits.amountInMaximum).not.toBe(101_505_000n);

    // The bond ceiling comes from that same 100.5 cap.
    expect(limits.maxBondAmount).toBe((100_500_000n * 100n) / 10_100n);
    expect(limits.maxBondAmount).toBe(995_049n);
  });

  it("rounds amountInMaximum UP", () => {
    // Q = 100, S = 50: 100 * 10050 / 10000 = 100.5, which must become 101, not 100.
    expect(exactOutputAmountInMaximum(100n, 50n, constants)).toBe(101n);
    expect(exactOutputAmountInMaximum(100n, 50n, constants)).not.toBe(100n);

    // An exact multiple does not gain a spurious unit.
    expect(exactOutputAmountInMaximum(10_000n, 50n, constants)).toBe(10_050n);

    // Zero tolerance is the identity.
    expect(exactOutputAmountInMaximum(123_457n, 0n, constants)).toBe(123_457n);

    // One raw unit above an exact multiple: 10,001 * 10,050 / 10,000 = 10,051.005, so the
    // ceiling is 10,052 — one unit of slack, never a unit short.
    expect(exactOutputAmountInMaximum(10_001n, 50n, constants)).toBe(10_052n);
  });

  it("rounds maxBondAmount DOWN", () => {
    // 103 * 100 / 10100 = 1.0198… -> 1.
    expect(exactOutputMaxBondAmount(103n, constants)).toBe(1n);
    // 202 -> exactly 2; 201 -> 1.99… -> 1, not 2.
    expect(exactOutputMaxBondAmount(202n, constants)).toBe(2n);
    expect(exactOutputMaxBondAmount(201n, constants)).toBe(1n);
    // 101 -> exactly 1.
    expect(exactOutputMaxBondAmount(101n, constants)).toBe(1n);
  });

  it("derives the bond ceiling from the SAME total cap the user authorises", () => {
    for (const [q, s] of [
      [1_000_000n, 0n],
      [1_000_000n, 150n],
      [999_983n, 37n],
      [10n ** 18n, 100n],
    ] as const) {
      const limits = exactOutputLimits({ quotedTotalInput: q, toleranceBps: s, constants, ...bondable });
      expect(limits.maxBondAmount).toBe(exactOutputMaxBondAmount(limits.amountInMaximum, constants));

      // The two bounds bind at the same moment: at the pool input where the total cap is
      // exhausted, the collateral at the cap is exactly the ceiling.
      const bindingPoolInput =
        (limits.amountInMaximum * constants.bps) / (constants.bps + constants.maxBondBps);
      const bondAtCap = (bindingPoolInput * constants.maxBondBps) / constants.bps;
      expect(bondAtCap).toBeLessThanOrEqual(limits.maxBondAmount);
    }
  });
});

describe("exact output: both expressions come from the hook's constants", () => {
  const q = 1_000_000n;

  it.each([
    { cap: 50n, expectedCeiling: (q * 50n) / 10_050n },
    { cap: 100n, expectedCeiling: (q * 100n) / 10_100n },
    { cap: 200n, expectedCeiling: (q * 200n) / 10_200n },
  ])("uses MAX_BOND_BPS = $cap for the ceiling", ({ cap, expectedCeiling }) => {
    const withCap: HookConstants = { bps: 10_000n, maxBondBps: cap };
    const limits = exactOutputLimits({
      quotedTotalInput: q,
      toleranceBps: 0n,
      constants: withCap,
      ...bondable,
    });

    // The cap does NOT touch the total-input authorisation any more — only the ceiling.
    expect(limits.amountInMaximum).toBe(q);
    expect(limits.maxBondAmount).toBe(expectedCeiling);
  });

  it("gives three different ceilings for three different caps, from one quote", () => {
    const ceilings = [50n, 100n, 200n].map(
      (cap) =>
        exactOutputLimits({
          quotedTotalInput: q,
          toleranceBps: 0n,
          constants: { bps: 10_000n, maxBondBps: cap },
          ...bondable,
        }).maxBondAmount,
    );
    expect(new Set(ceilings).size).toBe(3);
    expect(ceilings[0]).toBeLessThan(ceilings[1]);
    expect(ceilings[1]).toBeLessThan(ceilings[2]);
  });

  it("refuses to invent a cap when the hook reports an unusable one", () => {
    // Nothing here substitutes a default for a missing or nonsensical constant.
    expect(() =>
      exactOutputLimits({
        quotedTotalInput: q,
        toleranceBps: 0n,
        constants: { bps: 10_000n, maxBondBps: 0n },
        ...bondable,
      }),
    ).toThrow(LimitError);
    expect(() =>
      exactOutputLimits({
        quotedTotalInput: q,
        toleranceBps: 0n,
        constants: { bps: 0n, maxBondBps: 100n },
        ...bondable,
      }),
    ).toThrow(LimitError);
    expect(() =>
      exactOutputLimits({
        quotedTotalInput: q,
        toleranceBps: 0n,
        constants: { bps: 10_000n, maxBondBps: 10_001n },
        ...bondable,
      }),
    ).toThrow(LimitError);
  });
});

describe("exact output: rounding boundaries", () => {
  it("crosses the ceil boundary one raw unit at a time", () => {
    // With S = 1 bp the divisor is 10,000, so every 10,000 raw units adds exactly one.
    expect(exactOutputAmountInMaximum(10_000n, 1n, constants)).toBe(10_001n);
    expect(exactOutputAmountInMaximum(9_999n, 1n, constants)).toBe(10_000n);
    expect(exactOutputAmountInMaximum(1n, 1n, constants)).toBe(2n);
    expect(exactOutputAmountInMaximum(0n, 1n, constants)).toBe(0n);
  });

  it("crosses the floor boundary of the ceiling one raw unit at a time", () => {
    // maxBondAmount steps from 1 to 2 exactly at amountInMaximum = 202.
    expect(exactOutputMaxBondAmount(200n, constants)).toBe(1n);
    expect(exactOutputMaxBondAmount(201n, constants)).toBe(1n);
    expect(exactOutputMaxBondAmount(202n, constants)).toBe(2n);
    // …and from 0 to 1 exactly at 101.
    expect(exactOutputMaxBondAmount(100n, constants)).toBe(0n);
    expect(exactOutputMaxBondAmount(101n, constants)).toBe(1n);
  });

  it("rejects a total that would not fit the router's uint128 field", () => {
    const almost = (1n << 128n) - 1n;
    expect(() =>
      exactOutputLimits({ quotedTotalInput: almost, toleranceBps: 100n, constants, ...bondable }),
    ).toThrow(LimitError);
  });
});

/**
 * TESTS 14-17, exact-output side. Raw units are the unit of account throughout; the decimals
 * of the pair only change what the same raw number means, never the arithmetic.
 */
describe("exact output: mixed decimals", () => {
  // 100 tokens of the INPUT side, expressed in raw units at each width.
  const cases = [
    { label: "18/6 pair, 18-decimal input", decimals: 18, q: 100n * 10n ** 18n },
    { label: "6/18 pair, 6-decimal input", decimals: 6, q: 100n * 10n ** 6n },
    { label: "18/8 pair, 18-decimal input", decimals: 18, q: 100n * 10n ** 18n },
    { label: "8/18 pair, 8-decimal input", decimals: 8, q: 100n * 10n ** 8n },
  ];

  for (const item of cases) {
    it(`applies the same one-shot rule for a ${item.label}`, () => {
      const limits = exactOutputLimits({
        quotedTotalInput: item.q,
        toleranceBps: 50n,
        constants,
        bondingEnabled: true,
        bondingMinimum: 10_000n,
      });
      // 100.5 tokens of the input side, in that side's own raw units.
      expect(limits.amountInMaximum).toBe((item.q * 10_050n) / 10_000n);
      // And never the doubly-inflated 101.505 tokens.
      expect(limits.amountInMaximum).not.toBe((item.q * 10_050n * 10_100n) / (10_000n * 10_000n));
      expect(limits.maxBondAmount).toBe((limits.amountInMaximum * 100n) / 10_100n);
    });
  }

  it("keeps a 6-decimal input's ceiling small in raw units without losing it entirely", () => {
    // 1 USDC of total input: the ceiling is ~9,900 raw units, not zero and not 18-decimal sized.
    const limits = exactOutputLimits({
      quotedTotalInput: 1_000_000n,
      toleranceBps: 0n,
      constants,
      ...bondable,
    });
    expect(limits.maxBondAmount).toBe(9_900n);
  });
});

/**
 * ZERO-CEILING EDGE CASE.
 *
 * floor(amountInMaximum * C / (B + C)) is zero for any total below (B + C) / C — 101 raw
 * units on the current baseline. hookData rejects a zero ceiling, and an exact-output swap on
 * a bonding-enabled pool always decodes hookData, so something valid must be carried.
 * Substituting 1 is only safe where the trade provably cannot bond.
 */
describe("exact output: zero-derived ceiling", () => {
  it("fails closed when nothing proves the trade cannot bond", () => {
    // Configuration unread: no minimum to reason from.
    expect(() =>
      exactOutputLimits({
        quotedTotalInput: 100n,
        toleranceBps: 0n,
        constants,
        bondingEnabled: true,
        bondingMinimum: undefined,
      }),
    ).toThrow(LimitError);

    // Configured, but the pool could bond a trade this small, so a ceiling of 1 could
    // wrongly reject a legitimate bond.
    expect(() =>
      exactOutputLimits({
        quotedTotalInput: 100n,
        toleranceBps: 0n,
        constants,
        bondingEnabled: true,
        bondingMinimum: 50n,
      }),
    ).toThrow(/too small for an exact-output swap/);
  });

  it("carries the smallest valid ceiling when the trade provably cannot bond", () => {
    // amountInMaximum 100 < the pool's 10,000 raw-unit gate, so the hook returns zero at the
    // variable-leg check before it ever decodes hookData or compares the ceiling.
    const limits = exactOutputLimits({
      quotedTotalInput: 100n,
      toleranceBps: 0n,
      constants,
      bondingEnabled: true,
      bondingMinimum: 10_000n,
    });
    expect(limits.amountInMaximum).toBe(100n);
    expect(exactOutputMaxBondAmount(limits.amountInMaximum, constants)).toBe(0n);
    expect(limits.maxBondAmount).toBe(1n);
    expect(limits.ceilingIsProvenUnbonded).toBe(true);
  });

  it("carries the smallest valid ceiling when the pool does not bond at all", () => {
    // A disabled pool returns from both callbacks before decoding hookData.
    const limits = exactOutputLimits({
      quotedTotalInput: 100n,
      toleranceBps: 0n,
      constants,
      bondingEnabled: false,
    });
    expect(limits.maxBondAmount).toBe(1n);
    expect(limits.ceilingIsProvenUnbonded).toBe(true);
  });

  it("never substitutes a ceiling once the derived one is positive", () => {
    const limits = exactOutputLimits({
      quotedTotalInput: 101n,
      toleranceBps: 0n,
      constants,
      bondingEnabled: true,
      bondingMinimum: 10_000n,
    });
    expect(limits.maxBondAmount).toBe(1n);
    expect(limits.ceilingIsProvenUnbonded).toBe(false);
  });
});

describe("collateral rate curve", () => {
  it("uses the larger of own impact and block displacement", () => {
    // Own impact 4, block displacement 40: the block displacement wins.
    expect(effectiveImpactTicks({ tickBefore: 100n, tickAfter: 104n, blockStartTick: 64n })).toBe(40n);
    // First trade in its block: blockStartTick == tickBefore, so own impact is used.
    expect(effectiveImpactTicks({ tickBefore: 100n, tickAfter: 104n, blockStartTick: 100n })).toBe(4n);
  });

  it("applies 0.25 bps per effective tick, rounded up and capped at 100", () => {
    expect(collateralBpsForImpact(0n, constants)).toBe(0n);
    expect(collateralBpsForImpact(1n, constants)).toBe(1n);
    expect(collateralBpsForImpact(4n, constants)).toBe(1n);
    expect(collateralBpsForImpact(5n, constants)).toBe(2n);
    expect(collateralBpsForImpact(40n, constants)).toBe(10n);
    expect(collateralBpsForImpact(396n, constants)).toBe(99n);
    expect(collateralBpsForImpact(397n, constants)).toBe(100n);
    expect(collateralBpsForImpact(100_000n, constants)).toBe(100n);
  });

  it("floors the token amount as the hook does", () => {
    expect(collateralFromVariableLeg(10_000n, 1n, constants)).toBe(1n);
    expect(collateralFromVariableLeg(9_999n, 1n, constants)).toBe(0n);
  });
});
