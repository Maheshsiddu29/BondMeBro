import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import {
  GAS_MARGIN_DIVISOR,
  GasEstimateError,
  MAX_TRANSACTION_GAS,
  submitWithBoundedGas,
  withGasMargin,
} from "@/lib/gas";
import { resolveDeployment } from "@/lib/deployment";
import { decodeHookData, EXACT_INPUT_MAX_BOND_AMOUNT } from "@/lib/hookData";
import { exactInputSingleParamsType, exactOutputSingleParamsType } from "@/lib/abi/external";
import { buildExactInputPlan, buildExactOutputPlan } from "@/lib/swapPlan";

/**
 * The browser transaction that failed did so at `eth_sendRawTransaction` with "gas limit too
 * high" — after signing. The wallet had been left to choose the limit and picked one above
 * the network's per-transaction ceiling. These tests pin the replacement: estimate the exact
 * transaction, add a bounded margin, and refuse rather than clamp.
 */
describe("gas margin", () => {
  it("adds exactly 20%", () => {
    expect(withGasMargin(500_000n)).toBe(600_000n);
    expect(withGasMargin(1_000_000n)).toBe(1_200_000n);
    expect(GAS_MARGIN_DIVISOR).toBe(5n);
  });

  it("accepts an ordinary estimate below the ceiling", () => {
    const gas = withGasMargin(350_000n);
    expect(gas).toBe(420_000n);
    expect(gas).toBeLessThan(MAX_TRANSACTION_GAS);
  });

  it("rejects a zero estimate rather than signing one", () => {
    // A zero estimate means the node never really simulated the transaction.
    expect(() => withGasMargin(0n)).toThrow(GasEstimateError);
    expect(() => withGasMargin(0n)).toThrow(/zero/i);
  });

  it("rejects a negative estimate", () => {
    expect(() => withGasMargin(-1n)).toThrow(GasEstimateError);
  });

  it("rejects when the margined limit REACHES the ceiling", () => {
    // 13,981,013 * 1.2 = 16,777,215 — the largest limit that still fits.
    const largestUsable = 13_981_013n;
    expect(withGasMargin(largestUsable)).toBe(MAX_TRANSACTION_GAS - 1n);

    // One raw unit more lands exactly on the ceiling, which is already too high.
    const firstRefused = 13_981_014n;
    expect(firstRefused + firstRefused / GAS_MARGIN_DIVISOR).toBe(MAX_TRANSACTION_GAS);
    expect(() => withGasMargin(firstRefused)).toThrow(GasEstimateError);
  });

  it("rejects an estimate far above the ceiling instead of clamping it", () => {
    // Clamping here would sign a transaction that is expected to fail.
    expect(() => withGasMargin(30_000_000n)).toThrow(
      /outside the supported transaction limit/i,
    );
    expect(() => withGasMargin(60_000_000n)).toThrow(GasEstimateError);
  });

  it("uses the per-transaction ceiling, never a block gas limit", () => {
    expect(MAX_TRANSACTION_GAS).toBe(16_777_216n);
    expect(MAX_TRANSACTION_GAS).toBe(2n ** 24n);
    // Unichain Sepolia's block limit is 60,000,000; it must not be the transaction limit.
    expect(MAX_TRANSACTION_GAS).not.toBe(60_000_000n);
    expect(MAX_TRANSACTION_GAS).not.toBe(30_000_000n);
  });
});

/**
 * The gas change must be additive. These re-pin the encoding so a future edit to the
 * submission path cannot quietly alter what is actually signed.
 */
const ACCOUNT = "0x1111111111111111111111111111111111111111" as Address;

const resolved = resolveDeployment({
  chainId: "31337",
  networkName: "Local",
  explorerUrl: "https://explorer.example",
  hook: "0x7b5b5759918646ce36d7f5efd1a17aa6a5e7d0c4",
  poolManager: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  universalRouter: "0x0000000000000000000000000000000000000010",
  quoter: "0x0000000000000000000000000000000000000011",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  currency0: "0x00000000000000000000000000000000000000a1",
  currency1: "0x00000000000000000000000000000000000000b2",
  fee: "3000",
  tickSpacing: "60",
  deploymentBlock: "1",
});
if (resolved.status !== "ready") throw new Error("test fixture deployment is invalid");
const deployment = resolved.deployment;

describe("the gas change did not touch the encoding", () => {
  const ei = buildExactInputPlan({
    deployment,
    zeroForOne: true,
    amountIn: 1_000_000n,
    amountOutMinimum: 900_000n,
    refundRecipient: ACCOUNT,
    recipient: ACCOUNT,
    maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
  });

  const eo = buildExactOutputPlan({
    deployment,
    zeroForOne: true,
    amountOut: 500_000n,
    amountInMaximum: 1_000_000n,
    refundRecipient: ACCOUNT,
    recipient: ACCOUNT,
    maxBondAmount: 9_900n,
  });

  it("EI plan is byte-identical to the fork-proven encoding", () => {
    expect(ei.commands).toBe("0x10");
    expect(ei.actions).toBe("0x060b0e");
    expect(ei.inputs).toHaveLength(1);
    // Pinned in full by routerTuple.test.ts; this guards the plan builder itself.
    expect(ei.inputs[0]).toMatch(/^0x[0-9a-f]+$/);
    expect(ei.hookData).toBe(
      "0x02" + "1111111111111111111111111111111111111111" + "f".repeat(32),
    );
  });

  it("EO plan is byte-identical to the fork-proven encoding", () => {
    expect(eo.commands).toBe("0x10");
    expect(eo.actions).toBe("0x080b0e");
    expect(eo.inputs).toHaveLength(1);
    expect(eo.hookData).toBe(
      "0x02" + "1111111111111111111111111111111111111111" + "000000000000000000000000000026ac",
    );
  });

  it("router tuples still carry no minHopPriceX36", () => {
    for (const tuple of [exactInputSingleParamsType, exactOutputSingleParamsType]) {
      expect(tuple.components.map((c) => c.name)).not.toContain("minHopPriceX36");
      expect(tuple.components).toHaveLength(5);
    }
  });

  it("hookData v2 is unchanged: 37 packed bytes, version 2", () => {
    for (const hookData of [ei.hookData, eo.hookData]) {
      expect((hookData.length - 2) / 2).toBe(37);
      expect(hookData.slice(0, 4)).toBe("0x02");
    }
    expect(decodeHookData(ei.hookData)).toEqual({
      refundRecipient: ACCOUNT,
      maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
    });
    expect(decodeHookData(eo.hookData)).toEqual({
      refundRecipient: ACCOUNT,
      maxBondAmount: 9_900n,
    });
  });
});

/**
 * Every write in the app goes through one pipeline, so these prove the shared behaviour once
 * rather than per call site: the estimate and the signature always describe the SAME call.
 */
describe("submitWithBoundedGas is the single write pipeline", () => {
  const hash = `0x${"ab".repeat(32)}` as const;

  function fakePipeline(estimate: bigint) {
    const seen: { estimated?: unknown; written?: Record<string, unknown> } = {};
    return {
      seen,
      run: (call: Record<string, unknown>) =>
        submitWithBoundedGas({
          call,
          chainId: 1301,
          estimateGas: async (c) => {
            seen.estimated = c;
            return estimate;
          },
          write: async (c) => {
            seen.written = c;
            return hash;
          },
        }),
    };
  }

  it("signs the estimate plus 20%, and nothing else", async () => {
    const { run } = fakePipeline(81_474n); // the live settleBond estimate
    const result = await run({ address: "0x1", functionName: "settleBond" });
    expect(result.gas).toBe(97_768n);
    expect(result.hash).toBe(hash);
  });

  it("estimates the SAME call object it signs", async () => {
    const { seen, run } = fakePipeline(500_000n);
    const call = { address: "0xhook", functionName: "settleBond", args: ["0xbond"] };
    await run(call);

    // The estimator sees the call untouched.
    expect(seen.estimated).toEqual(call);
    // The writer sees that call plus only chainId and gas.
    expect(seen.written).toEqual({ ...call, chainId: 1301, gas: 600_000n });
  });

  it("never opens the wallet when the estimate is refused", async () => {
    let wrote = false;
    await expect(
      submitWithBoundedGas({
        call: {},
        chainId: 1301,
        estimateGas: async () => 0n,
        write: async () => {
          wrote = true;
          return hash;
        },
      }),
    ).rejects.toThrow(GasEstimateError);
    expect(wrote).toBe(false);
  });

  it("never opens the wallet when the margined estimate exceeds the ceiling", async () => {
    let wrote = false;
    await expect(
      submitWithBoundedGas({
        call: {},
        chainId: 1301,
        estimateGas: async () => 30_000_000n,
        write: async () => {
          wrote = true;
          return hash;
        },
      }),
    ).rejects.toThrow(/outside the supported transaction limit/i);
    expect(wrote).toBe(false);
  });

  it.each([
    ["ERC20 approve", 46_000n, 55_200n],
    ["Permit2 approve", 55_000n, 66_000n],
    ["Universal Router execute", 320_000n, 384_000n],
    ["settleBond", 81_474n, 97_768n],
  ])("bounds %s explicitly", async (_label, estimate, expected) => {
    const { seen, run } = fakePipeline(estimate);
    await run({ address: "0x1" });
    expect((seen.written as { gas: bigint }).gas).toBe(expected);
  });
});
