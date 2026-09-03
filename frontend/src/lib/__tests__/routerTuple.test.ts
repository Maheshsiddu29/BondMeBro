import { describe, expect, it } from "vitest";
import { decodeAbiParameters, encodeAbiParameters, type Address } from "viem";

import {
  exactInputSingleParamsType,
  exactOutputSingleParamsType,
  poolKeyComponents,
} from "@/lib/abi/external";
import { resolveDeployment } from "@/lib/deployment";
import { decodeHookData, EXACT_INPUT_MAX_BOND_AMOUNT } from "@/lib/hookData";
import { buildExactInputPlan, buildExactOutputPlan } from "@/lib/swapPlan";

/**
 * THE DEPLOYED UNIVERSAL ROUTER'S TUPLE SHAPE.
 *
 * The Universal Router deployed on Unichain Sepolia at
 * 0x7f9b8d606e0f35e5073abf93695814530b28a37b was built against a v4-periphery that predates
 * the `minHopPriceX36` field. Its calldata decoder is STRICT: an extra word shifts the
 * `hookData` offset and the call reverts inside `unlockCallback` with no revert reason,
 * before any swap happens.
 *
 * This was established empirically against a Unichain Sepolia fork in
 * `test/fork/DemoPoolForkRehearsal.t.sol` — encoding the pinned struct reverts, encoding this
 * shape swaps. These tests exist so the field cannot come back unnoticed.
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

/**
 * Golden vectors produced by Solidity's own `abi.encode` of the deployed-router struct:
 *
 *   cast abi-encode "f(((address,address,uint24,int24,address),bool,uint128,uint128,bytes))" ...
 *
 * The same struct shape is what actually executed a swap against the live router on the fork.
 * If the frontend's tuple gains or loses a field, these no longer match.
 */
const EI_GOLDEN =
  "0x0000000000000000000000000000000000000000000000000000000000000020"
  + "00000000000000000000000000000000000000000000000000000000000000a1"
  + "00000000000000000000000000000000000000000000000000000000000000b2"
  + "0000000000000000000000000000000000000000000000000000000000000bb8"
  + "000000000000000000000000000000000000000000000000000000000000003c"
  + "0000000000000000000000007b5b5759918646ce36d7f5efd1a17aa6a5e7d0c4"
  + "0000000000000000000000000000000000000000000000000000000000000001"
  + "00000000000000000000000000000000000000000000000000000000000f4240"
  + "00000000000000000000000000000000000000000000000000000000000dbba0"
  + "0000000000000000000000000000000000000000000000000000000000000120"
  + "0000000000000000000000000000000000000000000000000000000000000025"
  + "021111111111111111111111111111111111111111ffffffffffffffffffffffff"
  + "ffffffff000000000000000000000000000000000000000000000000000000";

const EO_GOLDEN =
  "0x0000000000000000000000000000000000000000000000000000000000000020"
  + "00000000000000000000000000000000000000000000000000000000000000a1"
  + "00000000000000000000000000000000000000000000000000000000000000b2"
  + "0000000000000000000000000000000000000000000000000000000000000bb8"
  + "000000000000000000000000000000000000000000000000000000000000003c"
  + "0000000000000000000000007b5b5759918646ce36d7f5efd1a17aa6a5e7d0c4"
  + "0000000000000000000000000000000000000000000000000000000000000001"
  + "000000000000000000000000000000000000000000000000000000000007a120"
  + "00000000000000000000000000000000000000000000000000000000000f4240"
  + "0000000000000000000000000000000000000000000000000000000000000120"
  + "0000000000000000000000000000000000000000000000000000000000000025"
  + "021111111111111111111111111111111111111111000000000000000000000000"
  + "000026ac000000000000000000000000000000000000000000000000000000";

/** The rejected shape, reconstructed locally so the divergence can be measured. */
const pinnedExactInputSingleParamsType = {
  type: "tuple",
  components: [
    { name: "poolKey", type: "tuple", components: poolKeyComponents },
    { name: "zeroForOne", type: "bool" },
    { name: "amountIn", type: "uint128" },
    { name: "amountOutMinimum", type: "uint128" },
    { name: "minHopPriceX36", type: "uint256" },
    { name: "hookData", type: "bytes" },
  ],
} as const;

/** Strips the two-value abi.encode(actions, params) wrapper the Universal Router expects. */
function unwrap(input: `0x${string}`) {
  return decodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], input) as unknown as [
    `0x${string}`,
    `0x${string}`[],
  ];
}

function componentNames(tuple: { components: readonly { name: string }[] }) {
  return tuple.components.map((component) => component.name);
}

/** Reads the nth 32-byte word of an ABI blob. */
function wordAt(encoded: string, index: number) {
  const body = encoded.slice(2);
  return BigInt(`0x${body.slice(index * 64, (index + 1) * 64)}`);
}

/**
 * In the DEPLOYED shape the head is five slots, so word 9 — after the tuple offset, the five
 * poolKey words, zeroForOne and the two amounts — is the hookData offset, and it reads 0x120.
 * A sixth head field pushes hookData to 0x140 and moves it to word 10, which is precisely the
 * shift that makes the live router revert.
 */
function hookDataOffset(encoded: string) {
  return wordAt(encoded, 9);
}

describe("deployed-router tuple shape: minHopPriceX36 must stay out", () => {
  it("EXACT INPUT tuple has no minHopPriceX36", () => {
    expect(componentNames(exactInputSingleParamsType)).not.toContain("minHopPriceX36");
    expect(
      exactInputSingleParamsType.components.some((c) => /minhop/i.test(c.name)),
    ).toBe(false);
  });

  it("EXACT OUTPUT tuple has no minHopPriceX36", () => {
    expect(componentNames(exactOutputSingleParamsType)).not.toContain("minHopPriceX36");
    expect(
      exactOutputSingleParamsType.components.some((c) => /minhop/i.test(c.name)),
    ).toBe(false);
  });

  it("pins the EXACT INPUT component list exactly", () => {
    expect(exactInputSingleParamsType.components.map((c) => [c.name, c.type])).toEqual([
      ["poolKey", "tuple"],
      ["zeroForOne", "bool"],
      ["amountIn", "uint128"],
      ["amountOutMinimum", "uint128"],
      ["hookData", "bytes"],
    ]);
  });

  it("pins the EXACT OUTPUT component list exactly", () => {
    expect(exactOutputSingleParamsType.components.map((c) => [c.name, c.type])).toEqual([
      ["poolKey", "tuple"],
      ["zeroForOne", "bool"],
      ["amountOut", "uint128"],
      ["amountInMaximum", "uint128"],
      ["hookData", "bytes"],
    ]);
  });

  it("keeps hookData LAST and the amount bound immediately before it", () => {
    const ei = exactInputSingleParamsType.components;
    expect(ei[ei.length - 1].name).toBe("hookData");
    expect(ei[ei.length - 1].type).toBe("bytes");
    expect(ei[ei.length - 2].name).toBe("amountOutMinimum");

    const eo = exactOutputSingleParamsType.components;
    expect(eo[eo.length - 1].name).toBe("hookData");
    expect(eo[eo.length - 1].type).toBe("bytes");
    expect(eo[eo.length - 2].name).toBe("amountInMaximum");
  });

  it("keeps the head at five slots, which is what fixes the hookData offset", () => {
    // Six head slots would put hookData at 0x140 and the deployed router would revert.
    expect(exactInputSingleParamsType.components).toHaveLength(5);
    expect(exactOutputSingleParamsType.components).toHaveLength(5);
  });
});

describe("EXACT INPUT encoding matches the live router", () => {
  const plan = buildExactInputPlan({
    deployment,
    zeroForOne: true,
    amountIn: 1_000_000n,
    amountOutMinimum: 900_000n,
    refundRecipient: ACCOUNT,
    recipient: ACCOUNT,
    maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
  });
  const [actions, params] = unwrap(plan.inputs[0]);

  it("produces the byte-for-byte encoding Solidity produces for the deployed struct", () => {
    expect(params[0]).toBe(EI_GOLDEN);
  });

  it("places hookData at offset 0x120, not 0x140", () => {
    expect(hookDataOffset(params[0])).toBe(0x120n);
    expect(hookDataOffset(params[0])).not.toBe(0x140n);
  });

  it("keeps the live-router-compatible command and action layout", () => {
    expect(plan.commands).toBe("0x10");
    expect(actions).toBe("0x060b0e");
  });

  it("round-trips through the deployed tuple with hookData v2 intact", () => {
    const [decoded] = decodeAbiParameters([exactInputSingleParamsType], params[0]) as unknown as [
      { amountIn: bigint; amountOutMinimum: bigint; zeroForOne: boolean; hookData: `0x${string}` },
    ];
    expect(decoded.amountIn).toBe(1_000_000n);
    expect(decoded.amountOutMinimum).toBe(900_000n);
    expect(decoded.zeroForOne).toBe(true);

    // hookData survives unchanged: 37 packed bytes, version 2.
    expect((decoded.hookData.length - 2) / 2).toBe(37);
    expect(decoded.hookData.slice(0, 4)).toBe("0x02");
    expect(decodeHookData(decoded.hookData)).toEqual({
      refundRecipient: ACCOUNT,
      maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
    });
  });

  it("differs from the rejected pinned shape by exactly one word", () => {
    const rejected = encodeAbiParameters(
      [pinnedExactInputSingleParamsType],
      [
        {
          poolKey: {
            currency0: deployment.currency0,
            currency1: deployment.currency1,
            fee: deployment.fee,
            tickSpacing: deployment.tickSpacing,
            hooks: deployment.hook,
          },
          zeroForOne: true,
          amountIn: 1_000_000n,
          amountOutMinimum: 900_000n,
          minHopPriceX36: 0n,
          hookData: plan.hookData,
        },
      ],
    );

    expect(rejected).not.toBe(params[0]);
    expect((rejected.length - params[0].length) / 2).toBe(32);

    // In the rejected shape word 9 is the extra minHopPriceX36 slot and the hookData offset
    // has been pushed out to word 10, reading 0x140. That displacement is the whole bug.
    expect(wordAt(rejected, 9)).toBe(0n);
    expect(wordAt(rejected, 10)).toBe(0x140n);
    expect(hookDataOffset(params[0])).toBe(0x120n);
  });
});

describe("EXACT OUTPUT encoding matches the live router", () => {
  const plan = buildExactOutputPlan({
    deployment,
    zeroForOne: true,
    amountOut: 500_000n,
    amountInMaximum: 1_000_000n,
    refundRecipient: ACCOUNT,
    recipient: ACCOUNT,
    maxBondAmount: 9_900n,
  });
  const [actions, params] = unwrap(plan.inputs[0]);

  it("produces the byte-for-byte encoding Solidity produces for the deployed struct", () => {
    expect(params[0]).toBe(EO_GOLDEN);
  });

  it("places hookData at offset 0x120, not 0x140", () => {
    expect(hookDataOffset(params[0])).toBe(0x120n);
    expect(hookDataOffset(params[0])).not.toBe(0x140n);
  });

  it("keeps the live-router-compatible command and action layout", () => {
    expect(plan.commands).toBe("0x10");
    expect(actions).toBe("0x080b0e");
  });

  it("round-trips through the deployed tuple with hookData v2 intact", () => {
    const [decoded] = decodeAbiParameters([exactOutputSingleParamsType], params[0]) as unknown as [
      { amountOut: bigint; amountInMaximum: bigint; hookData: `0x${string}` },
    ];
    expect(decoded.amountOut).toBe(500_000n);
    expect(decoded.amountInMaximum).toBe(1_000_000n);

    expect((decoded.hookData.length - 2) / 2).toBe(37);
    expect(decoded.hookData.slice(0, 4)).toBe("0x02");
    expect(decodeHookData(decoded.hookData)).toEqual({
      refundRecipient: ACCOUNT,
      maxBondAmount: 9_900n,
    });
  });
});
