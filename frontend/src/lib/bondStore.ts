import type { Address, Hex } from "viem";

import { BondState, type Bond, type BondSettledEvent } from "@/lib/bond";

/**
 * State priority for bond records.
 *
 * The demo exposed a real ordering bug: a settlement receipt would confirm, the card would
 * show SETTLED, and then a 30-second historical log scan that predated the settlement would
 * overwrite it with FINALIZED — putting the settle button back on an already-settled bond.
 *
 * Sources are ranked, and a lower-ranked observation may never overwrite a higher-ranked one
 * of the same lifecycle state. On top of that the lifecycle itself is monotonic: the contract
 * moves NONE -> PROVISIONAL -> FINALIZED -> SETTLED and never backwards, so a regression in
 * `state` is always staleness rather than news.
 */
export enum BondSource {
  /** Anything remembered from a previous session. */
  Cache = 1,
  /** A historical `eth_getLogs` sweep, which can be many blocks behind. */
  LogScan = 2,
  /** An event decoded from a transaction receipt we did not send. */
  ReceiptEvent = 3,
  /** A direct `getBond` read. */
  Storage = 4,
  /** A receipt for a transaction this session sent and confirmed. */
  Receipt = 5,
}

export type BondRecord = {
  bondId: Hex;
  bond?: Bond;
  /** ORIGINAL collateral taken. Unchanged after settlement; not remaining liability. */
  collateral?: bigint;
  collateralCurrency?: Address;
  openedTxHash?: Hex;
  openedBlock?: bigint;
  settlement?: BondSettledEvent;
  settlementTxHash?: Hex;
  readError?: string;
  /** What produced the `bond.state` currently held. */
  stateSource: BondSource;
};

function pick<T>(incoming: T | undefined, existing: T | undefined): T | undefined {
  return incoming !== undefined ? incoming : existing;
}

/**
 * Merges one observation into an existing record without ever regressing it.
 *
 * @param existing Record already held, or undefined for a first sighting.
 * @param incoming Newly observed record.
 */
export function mergeBondRecord(existing: BondRecord | undefined, incoming: BondRecord): BondRecord {
  if (!existing) return incoming;

  const existingState = existing.bond?.state;
  const incomingState = incoming.bond?.state;

  // Decide which record's `bond` — and therefore which lifecycle state — survives.
  let bond = existing.bond;
  let stateSource = existing.stateSource;

  if (incoming.bond !== undefined) {
    if (existingState === undefined) {
      bond = incoming.bond;
      stateSource = incoming.stateSource;
    } else if (incomingState !== undefined && incomingState > existingState) {
      // Genuine forward progress: FINALIZED -> SETTLED. Always accept it.
      bond = incoming.bond;
      stateSource = incoming.stateSource;
    } else if (incomingState === existingState && incoming.stateSource >= existing.stateSource) {
      // Same state, at least as trustworthy a source: refresh the other fields.
      bond = incoming.bond;
      stateSource = incoming.stateSource;
    }
    // Otherwise the incoming observation is stale and its `bond` is discarded.
  }

  return {
    bondId: existing.bondId,
    bond,
    stateSource,
    // Enrichments are additive: a value once known is never unlearned by a source that
    // simply has not caught up.
    collateral: pick(incoming.collateral, existing.collateral),
    collateralCurrency: pick(incoming.collateralCurrency, existing.collateralCurrency),
    openedTxHash: pick(incoming.openedTxHash, existing.openedTxHash),
    openedBlock: pick(incoming.openedBlock, existing.openedBlock),
    settlement: pick(incoming.settlement, existing.settlement),
    settlementTxHash: pick(incoming.settlementTxHash, existing.settlementTxHash),
    // A read error only sticks while nothing has ever been read successfully.
    readError: bond !== undefined ? undefined : pick(incoming.readError, existing.readError),
  };
}

/**
 * Folds a batch of observations into the held list.
 *
 * This is a UNION, never a replacement. A bond discovered from a receipt must not vanish
 * because a log scan taken before that block does not mention it yet.
 */
export function mergeBondRecords(previous: BondRecord[], incoming: BondRecord[]): BondRecord[] {
  const byId = new Map<string, BondRecord>();

  for (const record of previous) {
    byId.set(record.bondId.toLowerCase(), record);
  }

  for (const record of incoming) {
    const key = record.bondId.toLowerCase();
    byId.set(key, mergeBondRecord(byId.get(key), record));
  }

  return [...byId.values()].sort((a, b) => {
    const left = a.bond?.openBlock ?? a.openedBlock ?? 0n;
    const right = b.bond?.openBlock ?? b.openedBlock ?? 0n;
    return left > right ? -1 : left < right ? 1 : 0;
  });
}

/**
 * Whether a settle button may be offered for this record.
 *
 * Storage is the authority: a bond the contract reports as SETTLED never offers the button
 * again, no matter what a cached record says, and no matter who settled it.
 */
export function canOfferSettlement(record: BondRecord, currentBlock: bigint | undefined): boolean {
  if (!record.bond) return false;
  if (record.bond.state !== BondState.Finalized) return false;
  if (currentBlock === undefined) return false;
  return currentBlock >= record.bond.maturityBlock;
}

/** True once the record's lifecycle state is SETTLED, whatever produced that observation. */
export function isSettled(record: BondRecord): boolean {
  return record.bond?.state === BondState.Settled;
}

/**
 * Builds the record a confirmed settlement receipt produces.
 *
 * This is the highest-priority observation in the system: we sent the transaction and saw a
 * successful receipt, so the bond IS settled regardless of what any read says next.
 */
export function settledFromReceipt({
  bondId,
  previousBond,
  settlement,
  settlementTxHash,
}: {
  bondId: Hex;
  previousBond?: Bond;
  settlement?: BondSettledEvent;
  settlementTxHash?: Hex;
}): BondRecord {
  return {
    bondId,
    bond: previousBond ? { ...previousBond, state: BondState.Settled } : undefined,
    stateSource: BondSource.Receipt,
    settlement,
    settlementTxHash,
  };
}
