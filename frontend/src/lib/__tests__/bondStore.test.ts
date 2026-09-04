import { describe, expect, it } from "vitest";
import type { Address, Hex } from "viem";

import { BondState, type Bond, type BondSettledEvent } from "@/lib/bond";
import {
  BondSource,
  canOfferSettlement,
  isSettled,
  mergeBondRecord,
  mergeBondRecords,
  settledFromReceipt,
  type BondRecord,
} from "@/lib/bondStore";

const BOND_ID = `0x${"33".repeat(32)}` as Hex;
const OTHER_ID = `0x${"44".repeat(32)}` as Hex;
const RECIPIENT = "0xA5B709025224bA08B8eFfF1b0D1d28E970A34Cf3" as Address;
const CURRENCY = "0x00000000000000000000000000000000000000b2" as Address;

function bond(state: BondState, overrides: Partial<Bond> = {}): Bond {
  return {
    refundRecipient: RECIPIENT,
    openBlock: 61_621_708n,
    maturityBlock: 61_621_718n,
    poolIndex: 1n,
    variableLegAmount: 3_948_632_137_588_245_195n,
    tickBefore: -198_080n,
    tickAfter: -197_882n,
    collateralBps: 50n,
    collateralIsCurrency0: true,
    state,
    ...overrides,
  };
}

function record(state: BondState, source: BondSource, overrides: Partial<BondRecord> = {}): BondRecord {
  return { bondId: BOND_ID, bond: bond(state), stateSource: source, ...overrides };
}

const MATURED_BLOCK = 61_624_750n;

/**
 * The exact demo glitch: settle succeeds, the card shows SETTLED, then a 30-second log scan
 * taken before the settlement puts FINALIZED back and re-offers the button.
 */
describe("a confirmed SETTLED is never downgraded", () => {
  it("survives a stale log scan that still reads FINALIZED", () => {
    const confirmed = record(BondState.Settled, BondSource.Receipt);
    const staleScan = record(BondState.Finalized, BondSource.LogScan);

    const merged = mergeBondRecord(confirmed, staleScan);

    expect(merged.bond?.state).toBe(BondState.Settled);
    expect(merged.stateSource).toBe(BondSource.Receipt);
  });

  it("survives a lagging storage read that still reads FINALIZED", () => {
    const confirmed = record(BondState.Settled, BondSource.Receipt);
    const laggingStorage = record(BondState.Finalized, BondSource.Storage);

    expect(mergeBondRecord(confirmed, laggingStorage).bond?.state).toBe(BondState.Settled);
  });

  it("survives a cached record from a previous session", () => {
    const confirmed = record(BondState.Settled, BondSource.Storage);
    expect(mergeBondRecord(confirmed, record(BondState.Finalized, BondSource.Cache)).bond?.state).toBe(
      BondState.Settled,
    );
  });

  it("still accepts genuine forward progress from any source", () => {
    // Somebody else settled it; a plain storage read is how we find out.
    const held = record(BondState.Finalized, BondSource.Receipt);
    const settledElsewhere = record(BondState.Settled, BondSource.LogScan);

    expect(mergeBondRecord(held, settledElsewhere).bond?.state).toBe(BondState.Settled);
  });

  it("refreshes same-state data when the source is at least as trustworthy", () => {
    const held = record(BondState.Finalized, BondSource.LogScan, { collateral: 1n });
    const fresher = record(BondState.Finalized, BondSource.Storage, { collateral: 2n });

    const merged = mergeBondRecord(held, fresher);
    expect(merged.collateral).toBe(2n);
    expect(merged.stateSource).toBe(BondSource.Storage);
  });
});

describe("a settlement receipt marks the bond settled immediately", () => {
  it("produces SETTLED at the highest priority", () => {
    const receipt = settledFromReceipt({
      bondId: BOND_ID,
      previousBond: bond(BondState.Finalized),
      settlementTxHash: `0x${"cd".repeat(32)}`,
    });

    expect(receipt.bond?.state).toBe(BondState.Settled);
    expect(receipt.stateSource).toBe(BondSource.Receipt);
    expect(isSettled(receipt)).toBe(true);
  });

  it("removes the settle button the moment it is applied", () => {
    const before = record(BondState.Finalized, BondSource.Storage);
    expect(canOfferSettlement(before, MATURED_BLOCK)).toBe(true);

    const after = mergeBondRecord(
      before,
      settledFromReceipt({ bondId: BOND_ID, previousBond: before.bond }),
    );
    expect(canOfferSettlement(after, MATURED_BLOCK)).toBe(false);
  });

  it("keeps the settlement event and transaction hash", () => {
    const settlement = { bondId: BOND_ID, refund: 7n, slash: 3n } as unknown as BondSettledEvent;
    const merged = mergeBondRecord(
      record(BondState.Finalized, BondSource.Storage),
      settledFromReceipt({ bondId: BOND_ID, settlement, settlementTxHash: `0x${"cd".repeat(32)}` }),
    );
    expect(merged.settlement).toBe(settlement);
    expect(merged.settlementTxHash).toBe(`0x${"cd".repeat(32)}`);
  });
});

describe("settlement availability follows storage", () => {
  it("offers the button only for a matured FINALIZED bond", () => {
    expect(canOfferSettlement(record(BondState.Finalized, BondSource.Storage), MATURED_BLOCK)).toBe(true);
  });

  it("never offers it for a SETTLED bond, whoever settled it", () => {
    expect(canOfferSettlement(record(BondState.Settled, BondSource.LogScan), MATURED_BLOCK)).toBe(false);
  });

  it("never offers it before maturity", () => {
    expect(canOfferSettlement(record(BondState.Finalized, BondSource.Storage), 61_621_717n)).toBe(false);
    // The block after which it becomes available is the stored maturity, exactly.
    expect(canOfferSettlement(record(BondState.Finalized, BondSource.Storage), 61_621_718n)).toBe(true);
  });

  it("never offers it while the current block is unknown", () => {
    expect(canOfferSettlement(record(BondState.Finalized, BondSource.Storage), undefined)).toBe(false);
  });

  it("updates automatically when another account settles it", () => {
    // No click involved: a routine storage poll carries the news.
    const held = [record(BondState.Finalized, BondSource.Storage)];
    const polled = [record(BondState.Settled, BondSource.Storage)];

    const merged = mergeBondRecords(held, polled);
    expect(merged[0].bond?.state).toBe(BondState.Settled);
    expect(canOfferSettlement(merged[0], MATURED_BLOCK)).toBe(false);
  });
});

describe("a receipt-discovered bond cannot be erased by a stale scan", () => {
  const fromReceipt: BondRecord = {
    bondId: BOND_ID,
    stateSource: BondSource.ReceiptEvent,
    openedTxHash: `0x${"ab".repeat(32)}`,
    openedBlock: 61_621_708n,
    collateral: 19_743_160_687_941_225n,
    collateralCurrency: CURRENCY,
  };

  it("appears immediately, before any historical scan", () => {
    const merged = mergeBondRecords([], [fromReceipt]);
    expect(merged).toHaveLength(1);
    expect(merged[0].bondId).toBe(BOND_ID);
    expect(merged[0].collateral).toBe(19_743_160_687_941_225n);
  });

  it("survives a scan that does not mention it yet", () => {
    // The sweep predates the swap's block and only knows about an older bond.
    const staleScan: BondRecord[] = [
      { bondId: OTHER_ID, bond: bond(BondState.Settled), stateSource: BondSource.LogScan },
    ];

    const merged = mergeBondRecords([fromReceipt], staleScan);
    expect(merged.map((r) => r.bondId)).toContain(BOND_ID);
    expect(merged).toHaveLength(2);
  });

  it("keeps its collateral when a later read omits it", () => {
    const thinRead: BondRecord = {
      bondId: BOND_ID,
      bond: bond(BondState.Finalized),
      stateSource: BondSource.Storage,
    };
    const merged = mergeBondRecord(fromReceipt, thinRead);
    expect(merged.collateral).toBe(19_743_160_687_941_225n);
    expect(merged.openedTxHash).toBe(`0x${"ab".repeat(32)}`);
    expect(merged.bond?.state).toBe(BondState.Finalized);
  });

  it("clears a read error once the bond is readable", () => {
    const failed: BondRecord = { bondId: BOND_ID, stateSource: BondSource.Storage, readError: "boom" };
    const merged = mergeBondRecord(failed, record(BondState.Finalized, BondSource.Storage));
    expect(merged.readError).toBeUndefined();
  });
});

describe("maturity tracks the current block automatically", () => {
  const held = record(BondState.Finalized, BondSource.Storage);

  it("flips to settleable as the chain advances, with no user action", () => {
    expect(canOfferSettlement(held, 61_621_716n)).toBe(false);
    expect(canOfferSettlement(held, 61_621_717n)).toBe(false);
    expect(canOfferSettlement(held, 61_621_718n)).toBe(true);
    expect(canOfferSettlement(held, 61_621_719n)).toBe(true);
  });
});

/**
 * SETTLEMENT MUST NOT DEPEND ON THE HISTORY SCAN.
 *
 * The scan is recovery and indexing only. A bond already in the store is settleable from its
 * id, a fresh getBond and the current block — so a throttled or failing sweep must neither
 * erase it nor take its button away.
 */
describe("a failing history scan cannot break settlement", () => {
  const known = record(BondState.Finalized, BondSource.ReceiptEvent, {
    collateral: 18_246_000_000_000_000n,
    openedTxHash: `0x${"b4".repeat(32)}`,
  });

  it("keeps the bond when the scan returns nothing at all", () => {
    // A failed sweep contributes no observations; the union keeps what is already held.
    const merged = mergeBondRecords([known], []);
    expect(merged).toHaveLength(1);
    expect(merged[0].bondId).toBe(BOND_ID);
  });

  it("keeps the settle button available for a known mature bond", () => {
    const merged = mergeBondRecords([known], []);
    expect(canOfferSettlement(merged[0], MATURED_BLOCK)).toBe(true);
  });

  it("still exposes everything settlement needs: id, state and maturity", () => {
    const merged = mergeBondRecords([known], []);
    const bond = merged[0].bond;
    expect(merged[0].bondId).toBe(BOND_ID);
    expect(bond?.state).toBe(BondState.Finalized);
    expect(bond?.maturityBlock).toBe(61_621_718n);
  });

  it("a storage read alone is enough to settle, with no scan involved", () => {
    // This is the path a settlement preflight actually takes.
    const fromStorageOnly = mergeBondRecords([], [record(BondState.Finalized, BondSource.Storage)]);
    expect(canOfferSettlement(fromStorageOnly[0], MATURED_BLOCK)).toBe(true);
  });
});
