import { BondState, type Bond } from "@/lib/bond";

/**
 * Settlement decision logic, kept pure so it can be pinned by tests.
 *
 * Two rules drive everything here:
 *
 *  1. A SUCCESSFUL RECEIPT IS FINAL. Once the settlement transaction is mined successfully,
 *     nothing that happens afterwards — a failed log parse, a flaky refetch, an RPC blip —
 *     may present it as a failure. The chain has already decided.
 *
 *  2. STORAGE WINS. `getBond(...).state` is the authority on whether a bond is settled. A
 *     locally cached FINALIZED record must never keep offering a settle button for a bond the
 *     contract already reports as SETTLED, whoever settled it.
 */

export type SettlementPreflight =
  | { ok: true; bond: Bond }
  | { ok: false; reason: string; alreadySettled: boolean };

/**
 * Checks, from freshly read state, whether settlement can even be attempted.
 *
 * Running this before the wallet prompt means an immature or already-settled bond never
 * opens MetaMask at all.
 *
 * @param bond Freshly read bond record.
 * @param currentBlock Current chain head.
 */
export function settlementPreflight(bond: Bond, currentBlock: bigint): SettlementPreflight {
  if (bond.state === BondState.Settled) {
    return {
      ok: false,
      alreadySettled: true,
      reason: "This bond has already been settled. Refreshing its details.",
    };
  }

  if (bond.state !== BondState.Finalized) {
    return {
      ok: false,
      alreadySettled: false,
      reason: `This bond is not in a settleable state (state ${bond.state}).`,
    };
  }

  if (currentBlock < bond.maturityBlock) {
    const remaining = bond.maturityBlock - currentBlock;
    return {
      ok: false,
      alreadySettled: false,
      reason: `This bond matures at block ${bond.maturityBlock}; ${remaining} block${
        remaining === 1n ? "" : "s"
      } to go.`,
    };
  }

  return { ok: true, bond };
}

export type SettlementPhase = "confirmed" | "confirming" | "failed";

export type SettlementOutcome = {
  phase: SettlementPhase;
  /** Shown alongside the transaction link; empty when there is nothing to explain. */
  note: string;
};

/**
 * Decides what the UI may claim about a settlement.
 *
 * @param receiptSucceeded Whether a receipt came back with status success.
 * @param storageState `getBond(...).state` if it could be read after the receipt.
 * @param postReceiptFailed Whether anything after the receipt threw — parsing, refetching.
 */
export function resolveSettlementOutcome({
  receiptSucceeded,
  storageState,
  postReceiptFailed = false,
}: {
  receiptSucceeded: boolean;
  storageState?: BondState;
  postReceiptFailed?: boolean;
}): SettlementOutcome {
  // STORAGE WINS, even without a receipt of our own: somebody else may have settled it.
  if (storageState === BondState.Settled) {
    return { phase: "confirmed", note: "" };
  }

  if (receiptSucceeded) {
    // A SUCCESSFUL RECEIPT IS FINAL. A later parsing or refresh problem downgrades the
    // message, never the outcome.
    return postReceiptFailed || storageState === undefined
      ? { phase: "confirming", note: "Settlement confirmed. Refreshing bond details…" }
      : { phase: "confirmed", note: "" };
  }

  return { phase: "failed", note: "" };
}

/** True when the contract itself reports this bond as settled. */
export function isSettledByStorage(bond: Pick<Bond, "state"> | undefined): boolean {
  return bond?.state === BondState.Settled;
}
