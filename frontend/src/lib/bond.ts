import { decodeEventLog, type Address, type Hex } from "viem";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";

/**
 * Bond lifecycle and receipt-based discovery.
 *
 * NONE -> PROVISIONAL -> FINALIZED -> SETTLED. Only FINALIZED and SETTLED are publicly
 * readable; a provisional record is cleared during the same transaction that created it if
 * the trade turns out to be unbonded.
 */
export enum BondState {
  None = 0,
  Provisional = 1,
  Finalized = 2,
  Settled = 3,
}

export function bondStateLabel(state: BondState | number | undefined): string {
  switch (state) {
    case BondState.Finalized:
      return "FINALIZED";
    case BondState.Settled:
      return "SETTLED";
    case BondState.Provisional:
      return "PROVISIONAL";
    case BondState.None:
      return "NONE";
    default:
      return "UNKNOWN";
  }
}

/** `getBond` return, in the contract's field order. */
export type Bond = {
  refundRecipient: Address;
  openBlock: bigint;
  maturityBlock: bigint;
  poolIndex: bigint;
  variableLegAmount: bigint;
  tickBefore: bigint;
  tickAfter: bigint;
  collateralBps: bigint;
  collateralIsCurrency0: boolean;
  state: BondState;
};

type RawBond = {
  refundRecipient: Address;
  openBlock: number | bigint;
  maturityBlock: number | bigint;
  poolIndex: number | bigint;
  variableLegAmount: bigint;
  tickBefore: number | bigint;
  tickAfter: number | bigint;
  collateralBps: number | bigint;
  collateralIsCurrency0: boolean;
  state: number | bigint;
};

/** viem returns narrow Solidity integers as numbers; widen every one of them. */
export function normalizeBond(raw: RawBond): Bond {
  return {
    refundRecipient: raw.refundRecipient,
    openBlock: BigInt(raw.openBlock),
    maturityBlock: BigInt(raw.maturityBlock),
    poolIndex: BigInt(raw.poolIndex),
    variableLegAmount: BigInt(raw.variableLegAmount),
    tickBefore: BigInt(raw.tickBefore),
    tickAfter: BigInt(raw.tickAfter),
    collateralBps: BigInt(raw.collateralBps),
    collateralIsCurrency0: raw.collateralIsCurrency0,
    state: Number(raw.state) as BondState,
  };
}

/**
 * `bondExists` is TRUE for a settled bond as well as an unsettled one, and
 * `collateralAmountOf` keeps returning the ORIGINAL collateral after settlement.
 * Neither answers "is anything still owed". Only the state does.
 */
export function isUnsettled(bond: Pick<Bond, "state">): boolean {
  return bond.state === BondState.Finalized;
}

export function isSettled(bond: Pick<Bond, "state">): boolean {
  return bond.state === BondState.Settled;
}

/**
 * Blocks left until a bond can be settled.
 *
 * The authority is the bond's own STORED `maturityBlock`. It is never recomputed from
 * `openBlock + OBSERVATION_BLOCKS` for an existing bond, and there is no fallback horizon:
 * if the read fails the caller shows an unavailable state rather than inventing a number.
 */
export function blocksUntilMaturity(maturityBlock: bigint, currentBlock: bigint): bigint {
  return currentBlock >= maturityBlock ? 0n : maturityBlock - currentBlock;
}

export function isMature(maturityBlock: bigint, currentBlock: bigint): boolean {
  return currentBlock >= maturityBlock;
}

/** Settleable means finalized AND at or past its stored maturity. There is no expiry. */
export function canSettle(bond: Pick<Bond, "state" | "maturityBlock">, currentBlock: bigint): boolean {
  return isUnsettled(bond) && isMature(bond.maturityBlock, currentBlock);
}

/** Progress towards maturity, for the timeline bar only. */
export function maturityProgress(bond: Pick<Bond, "openBlock" | "maturityBlock">, currentBlock?: bigint): number {
  if (currentBlock === undefined) return 0;
  if (bond.maturityBlock <= bond.openBlock) return 0;
  if (currentBlock >= bond.maturityBlock) return 100;
  if (currentBlock <= bond.openBlock) return 0;
  return Math.round(
    (Number(currentBlock - bond.openBlock) / Number(bond.maturityBlock - bond.openBlock)) * 100,
  );
}

export type BondOpenedEvent = {
  bondId: Hex;
  poolId: Hex;
  refundRecipient: Address;
  variableLegAmount: bigint;
  maturityBlock: bigint;
  transactionHash?: Hex;
  blockNumber?: bigint;
  logIndex?: number;
};

export type BondTakenEvent = {
  poolId: Hex;
  refundRecipient: Address;
  currency: Address;
  bond: bigint;
  variableLegAmount: bigint;
  transactionHash?: Hex;
  blockNumber?: bigint;
  logIndex?: number;
};

export type BondSettledEvent = {
  bondId: Hex;
  poolId: Hex;
  refundRecipient: Address;
  currency: Address;
  collateral: bigint;
  refund: bigint;
  slash: bigint;
  slashBps: bigint;
  transactionHash?: Hex;
  blockNumber?: bigint;
  logIndex?: number;
};

/**
 * The parts of a log this module needs, loose enough to accept both a receipt's logs and
 * a `getLogs` result. `topics` is widened because viem types a decoded topic array more
 * narrowly than the encoder that produces one in tests.
 */
type MinimalLog = {
  address: Address | string;
  topics: readonly (string | null)[];
  data: string;
  transactionHash?: Hex | null;
  blockNumber?: bigint | null;
  logIndex?: number | null;
};

/**
 * Decodes one hook log using the compiled ABI.
 *
 * There are no hand-written topic hashes anywhere in this app. Indexed-versus-data
 * placement changed between the old and current contracts — current `BondOpened` puts the
 * bond ID in topic 1 and the pool ID in topic 2, the reverse of the old event — and a
 * hand-maintained hash cannot express that.
 */
export function decodeHookLog(log: MinimalLog, hookAddress: Address) {
  if (log.address.toLowerCase() !== hookAddress.toLowerCase()) return undefined;
  try {
    return decodeEventLog({
      abi: bondMeBroAbi,
      topics: log.topics as [Hex, ...Hex[]],
      data: log.data as Hex,
    });
  } catch {
    // Any other event from this address, or a future event this build does not know.
    return undefined;
  }
}

function logMeta(log: MinimalLog) {
  return {
    transactionHash: log.transactionHash ?? undefined,
    blockNumber: log.blockNumber ?? undefined,
    logIndex: log.logIndex ?? undefined,
  };
}

/**
 * Extracts every bond event belonging to one transaction receipt.
 *
 * Only logs emitted by the configured hook are considered, and every matching log is
 * processed — not just the first — so two bonds opened in one transaction keep distinct
 * identities. `logIndex` is preserved so history entries stay distinguishable.
 *
 * An empty `opened` array is a legitimate result: a swap below either minimum, or on a
 * pool with bonding disabled, executes in full and creates no bond.
 */
export function collectBondEvents(
  logs: MinimalLog[],
  hookAddress: Address,
  poolId?: Hex,
): { opened: BondOpenedEvent[]; taken: BondTakenEvent[]; settled: BondSettledEvent[] } {
  const opened: BondOpenedEvent[] = [];
  const taken: BondTakenEvent[] = [];
  const settled: BondSettledEvent[] = [];

  for (const log of logs) {
    const decoded = decodeHookLog(log, hookAddress);
    if (!decoded) continue;
    const meta = logMeta(log);

    if (decoded.eventName === "BondOpened") {
      const args = decoded.args as unknown as {
        bondId: Hex;
        id: Hex;
        refundRecipient: Address;
        variableLegAmount: bigint;
        maturityBlock: number | bigint;
      };
      if (poolId && args.id.toLowerCase() !== poolId.toLowerCase()) continue;
      opened.push({
        bondId: args.bondId,
        poolId: args.id,
        refundRecipient: args.refundRecipient,
        variableLegAmount: BigInt(args.variableLegAmount),
        maturityBlock: BigInt(args.maturityBlock),
        ...meta,
      });
    } else if (decoded.eventName === "BondTaken") {
      const args = decoded.args as unknown as {
        id: Hex;
        refundRecipient: Address;
        currency: Address;
        bond: bigint;
        variableLegAmount: bigint;
      };
      if (poolId && args.id.toLowerCase() !== poolId.toLowerCase()) continue;
      taken.push({
        poolId: args.id,
        refundRecipient: args.refundRecipient,
        currency: args.currency,
        bond: BigInt(args.bond),
        variableLegAmount: BigInt(args.variableLegAmount),
        ...meta,
      });
    } else if (decoded.eventName === "BondSettled") {
      const args = decoded.args as unknown as {
        bondId: Hex;
        id: Hex;
        refundRecipient: Address;
        currency: Address;
        collateral: bigint;
        refund: bigint;
        slash: bigint;
        slashBps: number | bigint;
      };
      if (poolId && args.id.toLowerCase() !== poolId.toLowerCase()) continue;
      settled.push({
        bondId: args.bondId,
        poolId: args.id,
        refundRecipient: args.refundRecipient,
        currency: args.currency,
        collateral: BigInt(args.collateral),
        refund: BigInt(args.refund),
        slash: BigInt(args.slash),
        slashBps: BigInt(args.slashBps),
        ...meta,
      });
    }
  }

  return { opened, taken, settled };
}

export type SwapOutcome =
  | { kind: "unbonded" }
  | {
      kind: "bonded";
      opened: BondOpenedEvent;
      /** Present whenever the matching BondTaken log is in the same receipt. */
      taken?: BondTakenEvent;
    };

/**
 * Interprets a successful swap receipt.
 *
 * Bond IDs are never guessed, never taken from a FIFO head and never assumed to be "the
 * latest bond in the pool": the ID comes from this transaction's own `BondOpened` log,
 * filtered to the configured hook, pool and — when a recipient is supplied — that
 * recipient. Absence of the event is reported as an ordinary unbonded swap, not an error,
 * and the caller must not wait for an event that will never arrive.
 */
export function interpretSwapReceipt({
  logs,
  hookAddress,
  poolId,
  refundRecipient,
}: {
  logs: MinimalLog[];
  hookAddress: Address;
  poolId: Hex;
  refundRecipient?: Address;
}): SwapOutcome {
  const { opened, taken } = collectBondEvents(logs, hookAddress, poolId);
  const mine = refundRecipient
    ? opened.filter((event) => event.refundRecipient.toLowerCase() === refundRecipient.toLowerCase())
    : opened;

  const chosen = mine[0];
  if (!chosen) return { kind: "unbonded" };

  const matchingTaken = taken.find(
    (event) =>
      event.refundRecipient.toLowerCase() === chosen.refundRecipient.toLowerCase()
      && event.variableLegAmount === chosen.variableLegAmount,
  );

  return { kind: "bonded", opened: chosen, taken: matchingTaken };
}
