import { describe, expect, it } from "vitest";
import { encodeAbiParameters, encodeEventTopics, type Address, type Hex } from "viem";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import {
  BondState,
  blocksUntilMaturity,
  canSettle,
  collectBondEvents,
  interpretSwapReceipt,
  isMature,
  isSettled,
  isUnsettled,
  normalizeBond,
} from "@/lib/bond";

const HOOK = "0x7b5b5759918646ce36d7f5efd1a17aa6a5e7d0c4" as Address;
const OTHER = "0x00000000000000000000000000000000000000ff" as Address;
const POOL_ID = `0x${"11".repeat(32)}` as Hex;
const OTHER_POOL = `0x${"22".repeat(32)}` as Hex;
const BOND_ID = `0x${"33".repeat(32)}` as Hex;
const RECIPIENT = "0x1111111111111111111111111111111111111111" as Address;
const CURRENCY = "0x00000000000000000000000000000000000000b2" as Address;

function bondOpenedLog({
  address = HOOK,
  poolId = POOL_ID,
  bondId = BOND_ID,
  refundRecipient = RECIPIENT,
  variableLegAmount = 1_000_000n,
  maturityBlock = 110,
  logIndex = 0,
}: Partial<{
  address: Address;
  poolId: Hex;
  bondId: Hex;
  refundRecipient: Address;
  variableLegAmount: bigint;
  maturityBlock: number;
  logIndex: number;
}> = {}) {
  return {
    address,
    // encodeEventTopics widens to allow array-valued indexed filters; a concrete log's
    // topics are always single hex words.
    topics: encodeEventTopics({
      abi: bondMeBroAbi,
      eventName: "BondOpened",
      args: { bondId, id: poolId, refundRecipient },
    }) as Hex[],
    data: encodeAbiParameters(
      [{ type: "uint128" }, { type: "uint32" }],
      [variableLegAmount, maturityBlock],
    ),
    transactionHash: `0x${"ab".repeat(32)}` as Hex,
    blockNumber: 100n,
    logIndex,
  };
}

function bondTakenLog({ bond = 1_000n, variableLegAmount = 1_000_000n, logIndex = 1 } = {}) {
  return {
    address: HOOK,
    topics: encodeEventTopics({
      abi: bondMeBroAbi,
      eventName: "BondTaken",
      args: { id: POOL_ID, refundRecipient: RECIPIENT, currency: CURRENCY },
    }) as Hex[],
    data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [bond, variableLegAmount]),
    transactionHash: `0x${"ab".repeat(32)}` as Hex,
    blockNumber: 100n,
    logIndex,
  };
}

function bondSettledLog({ collateral = 1_000n, refund = 700n, slash = 300n, slashBps = 3_000 } = {}) {
  return {
    address: HOOK,
    topics: encodeEventTopics({
      abi: bondMeBroAbi,
      eventName: "BondSettled",
      args: { bondId: BOND_ID, id: POOL_ID, refundRecipient: RECIPIENT },
    }) as Hex[],
    data: encodeAbiParameters(
      [{ type: "address" }, { type: "uint128" }, { type: "uint128" }, { type: "uint128" }, { type: "uint16" }],
      [CURRENCY, collateral, refund, slash, slashBps],
    ),
    transactionHash: `0x${"cd".repeat(32)}` as Hex,
    blockNumber: 120n,
    logIndex: 0,
  };
}

/**
 * TEST 12 — maturity uses the bond's STORED maturityBlock.
 * TEST 13 — there is no 25-block (or any) fallback horizon.
 * TEST 19 — current BondOpened decoding.
 * TEST 20 — current BondSettled decoding.
 * TEST 21 — an unbonded swap has no BondOpened and is reported as such.
 * TEST 25 — a settled bond is not classified as active.
 */
describe("maturity", () => {
  it("uses the stored maturityBlock, never openBlock plus a constant", () => {
    // A bond stored with an unusual maturity is honoured exactly as stored.
    const bond = { openBlock: 100n, maturityBlock: 117n, state: BondState.Finalized };
    expect(blocksUntilMaturity(bond.maturityBlock, 100n)).toBe(17n);
    expect(isMature(bond.maturityBlock, 116n)).toBe(false);
    expect(isMature(bond.maturityBlock, 117n)).toBe(true);
    expect(canSettle(bond, 117n)).toBe(true);
    expect(canSettle(bond, 116n)).toBe(false);
  });

  it("clamps remaining blocks at zero and never goes negative", () => {
    expect(blocksUntilMaturity(110n, 500n)).toBe(0n);
  });

  it("has no 25-block or 50-block fallback anywhere in the module", () => {
    // A ten-block horizon is the contract's value; the API takes maturity as an argument,
    // so there is no default a failed read could silently fall back to.
    expect(blocksUntilMaturity.length).toBe(2);
    expect(blocksUntilMaturity(100n + 10n, 100n)).toBe(10n);
    expect(blocksUntilMaturity(100n + 10n, 100n)).not.toBe(25n);
  });

  it("never lets settlement expire after maturity", () => {
    const bond = { openBlock: 100n, maturityBlock: 110n, state: BondState.Finalized };
    expect(canSettle(bond, 110n)).toBe(true);
    expect(canSettle(bond, 10_000_000n)).toBe(true);
  });
});

describe("lifecycle classification", () => {
  it("does not treat a settled bond as unsettled just because the record exists", () => {
    const settled = normalizeBond({
      refundRecipient: RECIPIENT,
      openBlock: 100,
      maturityBlock: 110,
      poolIndex: 0,
      variableLegAmount: 1_000_000n,
      tickBefore: 0,
      tickAfter: 5,
      collateralBps: 2,
      collateralIsCurrency0: false,
      state: BondState.Settled,
    });
    expect(isSettled(settled)).toBe(true);
    expect(isUnsettled(settled)).toBe(false);
    // Still settleable? No: state gates it, not maturity or existence.
    expect(canSettle(settled, 10_000n)).toBe(false);
  });

  it("widens every narrow integer the ABI returns as a number", () => {
    const bond = normalizeBond({
      refundRecipient: RECIPIENT,
      openBlock: 100,
      maturityBlock: 110,
      poolIndex: 3,
      variableLegAmount: 1n,
      tickBefore: -5,
      tickAfter: 5,
      collateralBps: 2,
      collateralIsCurrency0: true,
      state: 2,
    });
    expect(bond.openBlock).toBe(100n);
    expect(bond.maturityBlock).toBe(110n);
    expect(bond.tickBefore).toBe(-5n);
    expect(bond.state).toBe(BondState.Finalized);
  });
});

describe("event decoding", () => {
  it("decodes the current BondOpened, with bondId in topic 1 and pool in topic 2", () => {
    const { opened } = collectBondEvents([bondOpenedLog()], HOOK, POOL_ID);
    expect(opened).toHaveLength(1);
    expect(opened[0]).toMatchObject({
      bondId: BOND_ID,
      poolId: POOL_ID,
      refundRecipient: RECIPIENT,
      variableLegAmount: 1_000_000n,
      maturityBlock: 110n,
    });
  });

  it("decodes the current BondSettled with its refund, slash and rate", () => {
    const { settled } = collectBondEvents([bondSettledLog()], HOOK, POOL_ID);
    expect(settled).toHaveLength(1);
    expect(settled[0]).toMatchObject({
      bondId: BOND_ID,
      currency: CURRENCY,
      collateral: 1_000n,
      refund: 700n,
      slash: 300n,
      slashBps: 3_000n,
    });
    expect(settled[0].refund + settled[0].slash).toBe(settled[0].collateral);
  });

  it("ignores logs from any address other than the configured hook", () => {
    const { opened } = collectBondEvents([bondOpenedLog({ address: OTHER })], HOOK, POOL_ID);
    expect(opened).toHaveLength(0);
  });

  it("ignores events from another pool", () => {
    const { opened } = collectBondEvents([bondOpenedLog({ poolId: OTHER_POOL })], HOOK, POOL_ID);
    expect(opened).toHaveLength(0);
  });

  it("keeps distinct identities for two bonds in one transaction", () => {
    const second = `0x${"44".repeat(32)}` as Hex;
    const { opened } = collectBondEvents(
      [bondOpenedLog({ logIndex: 0 }), bondOpenedLog({ bondId: second, logIndex: 2 })],
      HOOK,
      POOL_ID,
    );
    expect(opened.map((event) => event.bondId)).toEqual([BOND_ID, second]);
    expect(opened.map((event) => event.logIndex)).toEqual([0, 2]);
  });
});

describe("swap receipt interpretation", () => {
  it("finds this transaction's own bond and its actual collateral", () => {
    const outcome = interpretSwapReceipt({
      logs: [bondOpenedLog(), bondTakenLog({ bond: 1_234n })],
      hookAddress: HOOK,
      poolId: POOL_ID,
      refundRecipient: RECIPIENT,
    });
    expect(outcome.kind).toBe("bonded");
    if (outcome.kind !== "bonded") throw new Error("unreachable");
    expect(outcome.opened.bondId).toBe(BOND_ID);
    expect(outcome.taken?.bond).toBe(1_234n);
    expect(outcome.taken?.currency).toBe(CURRENCY);
  });

  it("reports an unbonded swap when no BondOpened is present", () => {
    const outcome = interpretSwapReceipt({
      logs: [],
      hookAddress: HOOK,
      poolId: POOL_ID,
      refundRecipient: RECIPIENT,
    });
    expect(outcome).toEqual({ kind: "unbonded" });
  });

  it("does not claim another wallet's bond from the same block", () => {
    const outcome = interpretSwapReceipt({
      logs: [bondOpenedLog({ refundRecipient: OTHER })],
      hookAddress: HOOK,
      poolId: POOL_ID,
      refundRecipient: RECIPIENT,
    });
    expect(outcome).toEqual({ kind: "unbonded" });
  });
});
