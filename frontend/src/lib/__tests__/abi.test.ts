import { describe, expect, it } from "vitest";
import { getAbiItem, toFunctionSelector, toEventSelector } from "viem";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";

/**
 * TEST 1 — the current ABI compiles and carries exactly the current surface.
 * TEST 2 — PoolConfig GETTER ordering.
 * TEST 3 — PoolConfig SETTER ordering.
 *
 * The audit found 17 of 20 hand-written function signatures and all 6 event signatures had
 * been removed from the contract. These assertions fail loudly if the generated ABI drifts.
 */
describe("BondMeBro ABI", () => {
  it("exposes the current function surface and none of the removed one", () => {
    const names = bondMeBroAbi.filter((entry) => entry.type === "function").map((entry) => entry.name);

    for (const required of [
      "BPS",
      "MAX_BOND_BPS",
      "OBSERVATION_BLOCKS",
      "poolConfig",
      "setPoolConfig",
      "getBond",
      "bondExists",
      "collateralAmountOf",
      "settleBond",
      "settleMany",
      "insurancePot",
      "accumulator",
    ]) {
      expect(names).toContain(required);
    }

    for (const removed of [
      "bondBps",
      "refundTolTicks",
      "observationBlocks",
      "maxAbsTickDelta",
      "settlerFeeBps",
      "maxSettlesPerSwap",
      "getPoolConfig",
      "getPoolConfigWithDecimals",
      "currencyDecimals",
      "queueLength",
      "queueBounds",
      "getAccumulator",
      "claimablePayments",
      "settleBonds",
      "donatePot",
      "claimPayments",
    ]) {
      expect(names).not.toContain(removed);
    }
  });

  it("carries the current events and none of the removed ones", () => {
    const names = bondMeBroAbi.filter((entry) => entry.type === "event").map((entry) => entry.name);
    expect(names).toEqual(expect.arrayContaining(["BondOpened", "BondTaken", "BondSettled", "PoolConfigured"]));
    for (const removed of ["PoolConfigUpdated", "PotDonated", "PaymentDeferred", "PaymentsClaimed"]) {
      expect(names).not.toContain(removed);
    }
  });

  it("pins the current event selectors", () => {
    expect(toEventSelector("BondOpened(bytes32,bytes32,address,uint128,uint32)")).toBe(
      toEventSelector(getAbiItem({ abi: bondMeBroAbi, name: "BondOpened" })),
    );
    expect(toEventSelector("BondSettled(bytes32,bytes32,address,address,uint128,uint128,uint128,uint16)")).toBe(
      toEventSelector(getAbiItem({ abi: bondMeBroAbi, name: "BondSettled" })),
    );
    expect(toEventSelector("BondTaken(bytes32,address,address,uint256,uint256)")).toBe(
      toEventSelector(getAbiItem({ abi: bondMeBroAbi, name: "BondTaken" })),
    );
  });

  it("pins the settlement selectors that replaced the removed FIFO call", () => {
    expect(toFunctionSelector(getAbiItem({ abi: bondMeBroAbi, name: "settleBond" }))).toBe(
      toFunctionSelector("settleBond(bytes32)"),
    );
    expect(toFunctionSelector(getAbiItem({ abi: bondMeBroAbi, name: "settleMany" }))).toBe(
      toFunctionSelector("settleMany(bytes32[])"),
    );
  });

  it("keeps the PoolConfig GETTER order, with bondingEnabled third", () => {
    const getter = getAbiItem({ abi: bondMeBroAbi, name: "poolConfig" });
    expect(getter.inputs.map((input) => input.type)).toEqual(["bytes32"]);
    expect(getter.outputs.map((output) => [output.name, output.type])).toEqual([
      ["minBondedAmount0", "uint128"],
      ["minBondedAmount1", "uint96"],
      ["bondingEnabled", "bool"],
      ["minVariableLeg0", "uint128"],
      ["minVariableLeg1", "uint128"],
    ]);
  });

  it("keeps the PoolConfig SETTER order, with bondingEnabled last", () => {
    const setter = getAbiItem({ abi: bondMeBroAbi, name: "setPoolConfig" });
    expect(setter.inputs.map((input) => [input.name, input.type])).toEqual([
      ["key", "tuple"],
      ["minBondedAmount0", "uint128"],
      ["minBondedAmount1", "uint96"],
      ["minVariableLeg0", "uint128"],
      ["minVariableLeg1", "uint128"],
      ["bondingEnabled", "bool"],
    ]);
  });

  it("keeps the PoolConfigured EVENT order, with bondingEnabled last", () => {
    const event = getAbiItem({ abi: bondMeBroAbi, name: "PoolConfigured" });
    expect(event.inputs.map((input) => [input.name, input.type])).toEqual([
      ["id", "bytes32"],
      ["minBondedAmount0", "uint128"],
      ["minBondedAmount1", "uint96"],
      ["minVariableLeg0", "uint128"],
      ["minVariableLeg1", "uint128"],
      ["bondingEnabled", "bool"],
    ]);
  });

  it("returns the ten-field bond tuple in the contract's order", () => {
    const getBond = getAbiItem({ abi: bondMeBroAbi, name: "getBond" });
    const components = getBond.outputs[0].components ?? [];
    expect(components.map((component) => [component.name, component.type])).toEqual([
      ["refundRecipient", "address"],
      ["openBlock", "uint32"],
      ["maturityBlock", "uint32"],
      ["poolIndex", "uint32"],
      ["variableLegAmount", "uint128"],
      ["tickBefore", "int24"],
      ["tickAfter", "int24"],
      ["collateralBps", "uint16"],
      ["collateralIsCurrency0", "bool"],
      ["state", "uint8"],
    ]);
  });
});
