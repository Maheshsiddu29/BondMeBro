import { describe, expect, it } from "vitest";
import { decodeAbiParameters, type Address } from "viem";

import { exactInputSingleParamsType, exactOutputSingleParamsType } from "@/lib/abi/external";
import { resolveDeployment } from "@/lib/deployment";
import { decodeHookData, EXACT_INPUT_MAX_BOND_AMOUNT } from "@/lib/hookData";
import { exactOutputLimits, type HookConstants } from "@/lib/limits";
import { buildExactInputPlan, buildExactOutputPlan, spendRequirement } from "@/lib/swapPlan";

const ACCOUNT = "0x1111111111111111111111111111111111111111" as Address;
const constants: HookConstants = { bps: 10_000n, maxBondBps: 100n };

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

/** Strips the two-value abi.encode(actions, params) wrapper the Universal Router expects. */
function unwrap(input: `0x${string}`) {
  return decodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], input) as unknown as [
    `0x${string}`,
    `0x${string}`[],
  ];
}

describe("exact-input router plan", () => {
  const plan = buildExactInputPlan({
    deployment,
    zeroForOne: true,
    amountIn: 1_000_000n,
    amountOutMinimum: 900_000n,
    refundRecipient: ACCOUNT,
    recipient: ACCOUNT,
    maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
  });

  it("uses SWAP_EXACT_IN_SINGLE, SETTLE and TAKE", () => {
    expect(plan.commands).toBe("0x10");
    expect(plan.actions).toBe("0x060b0e");
  });

  it("passes the FULL specified input to the pool, with no carve-out", () => {
    const [, params] = unwrap(plan.inputs[0]);
    const [swap] = decodeAbiParameters([exactInputSingleParamsType], params[0]) as unknown as [
      { amountIn: bigint; amountOutMinimum: bigint; zeroForOne: boolean; hookData: `0x${string}` },
    ];
    expect(swap.amountIn).toBe(1_000_000n);
    expect(swap.amountOutMinimum).toBe(900_000n);
    expect(swap.zeroForOne).toBe(true);
  });

  it("carries a version 2 payload with the unbounded ceiling", () => {
    expect(decodeHookData(plan.hookData)).toEqual({
      refundRecipient: ACCOUNT,
      maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
    });
  });

  it("requires only the input amount to be approved", () => {
    expect(
      spendRequirement({ deployment, kind: "exactInput", zeroForOne: true, amountIn: 1_000_000n }),
    ).toEqual({ currency: deployment.currency0, amount: 1_000_000n });
  });
});

describe("exact-output router plan", () => {
  // Q is the quoter's TOTAL input, collateral already included; S = 0 leaves it untouched.
  const limits = exactOutputLimits({
    quotedTotalInput: 1_000_000n,
    toleranceBps: 0n,
    constants,
    bondingEnabled: true,
    bondingMinimum: 10_000n,
  });
  const plan = buildExactOutputPlan({
    deployment,
    zeroForOne: true,
    amountOut: 500_000n,
    amountInMaximum: limits.amountInMaximum,
    refundRecipient: ACCOUNT,
    recipient: ACCOUNT,
    maxBondAmount: limits.maxBondAmount,
  });

  it("uses SWAP_EXACT_OUT_SINGLE, SETTLE and TAKE", () => {
    expect(plan.commands).toBe("0x10");
    expect(plan.actions).toBe("0x080b0e");
  });

  it("keeps the specified output exact and bounds the total input", () => {
    const [, params] = unwrap(plan.inputs[0]);
    const [swap] = decodeAbiParameters([exactOutputSingleParamsType], params[0]) as unknown as [
      { amountOut: bigint; amountInMaximum: bigint },
    ];
    expect(swap.amountOut).toBe(500_000n);
    // The quote passes through as the total cap; no second collateral headroom is added.
    expect(swap.amountInMaximum).toBe(1_000_000n);
    expect(swap.amountInMaximum).not.toBe(1_010_000n);
  });

  it("carries a bounded collateral ceiling derived from that same total cap", () => {
    expect(decodeHookData(plan.hookData)).toEqual({
      refundRecipient: ACCOUNT,
      maxBondAmount: (1_000_000n * 100n) / 10_100n,
    });
    expect(limits.maxBondAmount).toBe(9_900n);
  });

  it("requires the MAXIMUM TOTAL INPUT to be approved, collateral included", () => {
    expect(
      spendRequirement({
        deployment,
        kind: "exactOutput",
        zeroForOne: true,
        amountInMaximum: limits.amountInMaximum,
      }),
    ).toEqual({ currency: deployment.currency0, amount: limits.amountInMaximum });
  });

  it("grows the approval with the tolerance, once", () => {
    const withSlippage = exactOutputLimits({
      quotedTotalInput: 1_000_000n,
      toleranceBps: 50n,
      constants,
      bondingEnabled: true,
      bondingMinimum: 10_000n,
    });
    expect(withSlippage.amountInMaximum).toBe(1_005_000n);
  });

  it("uses currency1 as the input when the direction is reversed", () => {
    expect(
      spendRequirement({ deployment, kind: "exactOutput", zeroForOne: false, amountInMaximum: 5n }),
    ).toEqual({ currency: deployment.currency1, amount: 5n });
  });
});
