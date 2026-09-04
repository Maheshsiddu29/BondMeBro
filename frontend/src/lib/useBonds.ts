"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Address, Hex } from "viem";
import { usePublicClient } from "wagmi";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import {
  collectBondEvents,
  normalizeBond,
  type BondOpenedEvent,
  type BondSettledEvent,
  type BondTakenEvent,
} from "@/lib/bond";
import {
  BondSource,
  isSettled as recordIsSettled,
  mergeBondRecords,
  settledFromReceipt,
  type BondRecord,
} from "@/lib/bondStore";
import type { Deployment } from "@/lib/deployment";

/** How often visible bonds are re-read from storage, so nobody has to press Refresh. */
const STORAGE_POLL_MS = 2_000;

/** Transient scan failures stay quiet until this many in a row. */
const HISTORY_FAILURES_BEFORE_WARNING = 3;

const MAX_LOG_CHUNK = 10_000n;
const MAX_CHUNKS = 20;

function indexKey(deployment: Deployment) {
  return `bondmebro-bond-index-${deployment.chainId}-${deployment.hook.toLowerCase()}`;
}

type StoredEntry = { bondId: Hex; refundRecipient: Address; txHash?: Hex; block?: string };

function readStoredIndex(deployment: Deployment): StoredEntry[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(indexKey(deployment));
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is StoredEntry => {
      if (item === null || typeof item !== "object") return false;
      const entry = item as Record<string, unknown>;
      return typeof entry.bondId === "string" && typeof entry.refundRecipient === "string";
    });
  } catch {
    return [];
  }
}

function writeStoredIndex(deployment: Deployment, entries: StoredEntry[]) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(indexKey(deployment), JSON.stringify(entries.slice(0, 200)));
  } catch {
    // Storage can be full or disabled; the log scan still finds recent bonds.
  }
}

/**
 * Bond discovery and state.
 *
 * Identity comes from `BondOpened` logs and from a local index of bonds this browser has
 * seen, so a bond that has fallen out of the scan window is still resolvable. State always
 * comes from `getBond(bondId)`: a bond is unsettled because its state says FINALIZED, never
 * because a settlement log happened to be missed.
 *
 * KNOWN LIMITATION: the scan covers at most the most recent
 * MAX_CHUNKS x MAX_LOG_CHUNK blocks above the deployment block. A different browser opening
 * this app after that window has passed will not rediscover an older bond from logs alone.
 *
 * A FAILED SCAN IS NOT A FAILED BOND. History discovery is recovery and indexing only: when
 * it fails the store keeps everything it already holds, and a known mature bond stays
 * settleable, because settlement needs only the bond id, a fresh `getBond` and the block.
 */
export function useBondIndex(deployment: Deployment, account?: Address) {
  const publicClient = usePublicClient({ chainId: deployment.chainId });
  const [records, setRecords] = useState<BondRecord[]>([]);
  const [loading, setLoading] = useState(false);
  const [historyFailures, setHistoryFailures] = useState(0);
  const [nonce, setNonce] = useState(0);
  const lastAccount = useRef<string | undefined>(undefined);

  const accountKey = account?.toLowerCase();

  // An account change invalidates every account-scoped row immediately, before the next
  // load resolves, so a stale list is never shown under a new address.
  useEffect(() => {
    if (lastAccount.current !== accountKey) {
      lastAccount.current = accountKey;
      // Only an ACCOUNT CHANGE clears the store. A failed scan never does.
      setRecords([]);
      setHistoryFailures(0);
    }
  }, [accountKey]);

  /**
   * Records a bond straight from a confirmed swap receipt.
   *
   * This is deliberately synchronous with respect to the UI: the card appears immediately and
   * does not wait for the historical scan, which is only there for reload and cross-device
   * recovery. A later scan that predates this block cannot remove it — the store merges by
   * id and never replaces wholesale.
   */
  const addDiscoveredBond = useCallback(
    (opened: BondOpenedEvent, taken?: BondTakenEvent) => {
      const stored = readStoredIndex(deployment);
      if (!stored.some((entry) => entry.bondId.toLowerCase() === opened.bondId.toLowerCase())) {
        writeStoredIndex(deployment, [
          {
            bondId: opened.bondId,
            refundRecipient: opened.refundRecipient,
            txHash: opened.transactionHash,
            block: opened.blockNumber?.toString(),
          },
          ...stored,
        ]);
      }

      setRecords((previous) =>
        mergeBondRecords(previous, [
          {
            bondId: opened.bondId,
            stateSource: BondSource.ReceiptEvent,
            openedTxHash: opened.transactionHash,
            openedBlock: opened.blockNumber,
            collateral: taken?.bond,
            collateralCurrency: taken?.currency,
          },
        ]),
      );

      setNonce((value) => value + 1);
    },
    [deployment],
  );

  /**
   * Marks a bond settled from a confirmed settlement receipt.
   *
   * Highest priority in the store. Nothing read afterwards may put it back to FINALIZED, so
   * the settle button disappears at once and stays gone.
   */
  const markSettledFromReceipt = useCallback(
    (bondId: Hex, settlement?: BondSettledEvent, settlementTxHash?: Hex) => {
      setRecords((previous) => {
        const existing = previous.find((r) => r.bondId.toLowerCase() === bondId.toLowerCase());
        return mergeBondRecords(previous, [
          settledFromReceipt({
            bondId,
            previousBond: existing?.bond,
            settlement,
            settlementTxHash,
          }),
        ]);
      });
      setNonce((value) => value + 1);
    },
    [],
  );

  const refresh = useCallback(() => setNonce((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    if (!publicClient || !account) {
      setRecords([]);
      return;
    }

    async function load() {
      if (!publicClient || !account) return;
      setLoading(true);
      try {
        const latest = await publicClient.getBlockNumber();
        const span = MAX_LOG_CHUNK * BigInt(MAX_CHUNKS);
        const floor = deployment.deploymentBlock;
        const from = latest > floor + span ? latest - span : floor;

        const opened: BondOpenedEvent[] = [];
        const taken: BondTakenEvent[] = [];
        const settled: BondSettledEvent[] = [];

        for (let start = from; start <= latest; start += MAX_LOG_CHUNK) {
          const end = start + MAX_LOG_CHUNK - 1n > latest ? latest : start + MAX_LOG_CHUNK - 1n;
          const logs = await publicClient.getLogs({
            address: deployment.hook,
            fromBlock: start,
            toBlock: end,
          });
          const batch = collectBondEvents(logs, deployment.hook, deployment.poolId);
          opened.push(...batch.opened);
          taken.push(...batch.taken);
          settled.push(...batch.settled);
        }

        setHistoryFailures(0);

        const stored = readStoredIndex(deployment);
        const mineFromLogs = opened.filter(
          (event) => event.refundRecipient.toLowerCase() === account.toLowerCase(),
        );

        // Persist newly seen bonds so a later session outside the scan window still has them.
        const merged = [...stored];
        for (const event of mineFromLogs) {
          if (!merged.some((entry) => entry.bondId.toLowerCase() === event.bondId.toLowerCase())) {
            merged.unshift({
              bondId: event.bondId,
              refundRecipient: event.refundRecipient,
              txHash: event.transactionHash,
              block: event.blockNumber?.toString(),
            });
          }
        }
        writeStoredIndex(deployment, merged);

        const candidates = merged.filter(
          (entry) => entry.refundRecipient.toLowerCase() === account.toLowerCase(),
        );

        const resolved: BondRecord[] = [];
        for (const entry of candidates) {
          const fromLog = mineFromLogs.find(
            (event) => event.bondId.toLowerCase() === entry.bondId.toLowerCase(),
          );
          const record: BondRecord = {
            bondId: entry.bondId,
            // A sweep can be many blocks behind; it must never outrank a receipt.
            stateSource: BondSource.LogScan,
            openedTxHash: fromLog?.transactionHash ?? entry.txHash,
            openedBlock: fromLog?.blockNumber ?? (entry.block ? BigInt(entry.block) : undefined),
            settlement: settled.find(
              (event) => event.bondId.toLowerCase() === entry.bondId.toLowerCase(),
            ),
          };
          try {
            const [bond, collateral] = await Promise.all([
              publicClient.readContract({
                address: deployment.hook,
                abi: bondMeBroAbi,
                functionName: "getBond",
                args: [entry.bondId],
              }),
              publicClient.readContract({
                address: deployment.hook,
                abi: bondMeBroAbi,
                functionName: "collateralAmountOf",
                args: [entry.bondId],
              }),
            ]);
            record.bond = normalizeBond(bond as never);
            record.collateral = BigInt(collateral as bigint);
            record.collateralCurrency = record.bond.collateralIsCurrency0
              ? deployment.currency0
              : deployment.currency1;
          } catch {
            // getBond rejects absent and provisional records. Report it rather than
            // fabricating a state or a maturity.
            record.readError = "This bond could not be read from the hook.";
          }
          const takenEvent = taken.find(
            (event) =>
              record.bond
              && event.refundRecipient.toLowerCase() === account.toLowerCase()
              && event.variableLegAmount === record.bond.variableLegAmount,
          );
          if (takenEvent) record.collateralCurrency = takenEvent.currency;
          resolved.push(record);
        }

        resolved.sort((a, b) => {
          const left = a.bond?.openBlock ?? 0n;
          const right = b.bond?.openBlock ?? 0n;
          return left > right ? -1 : left < right ? 1 : 0;
        });

        // UNION, never replacement: a receipt-discovered bond survives a scan that predates it.
        if (!cancelled) setRecords((previous) => mergeBondRecords(previous, resolved));
      } catch {
        // A failed sweep is an indexing problem, not a bond problem. The store keeps every
        // record it already holds, settlement stays available, and the user sees a calm
        // status rather than raw JSON-RPC plumbing.
        if (!cancelled) setHistoryFailures((count) => count + 1);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    void load();
    const timer = window.setInterval(() => void load(), 30_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [publicClient, account, deployment, nonce]);

  // -----------------------------------------------------------------------------------
  // Fast reconciliation: re-read the bonds actually on screen every couple of seconds, so a
  // settlement — ours or anyone else's — lands in the UI without the user pressing Refresh.
  // Reads are tagged Storage, which outranks the log scan but never a settlement receipt.
  // -----------------------------------------------------------------------------------
  const knownIds = records.map((record) => record.bondId).join(",");

  useEffect(() => {
    if (!publicClient || !account || knownIds.length === 0) return;
    let cancelled = false;

    async function reconcile() {
      if (!publicClient) return;
      const ids = knownIds.split(",") as Hex[];

      const observations = await Promise.all(
        ids.map(async (bondId): Promise<BondRecord | undefined> => {
          try {
            const [bond, collateral] = await Promise.all([
              publicClient.readContract({
                address: deployment.hook,
                abi: bondMeBroAbi,
                functionName: "getBond",
                args: [bondId],
              }),
              publicClient.readContract({
                address: deployment.hook,
                abi: bondMeBroAbi,
                functionName: "collateralAmountOf",
                args: [bondId],
              }),
            ]);
            const normalized = normalizeBond(bond as never);
            return {
              bondId,
              stateSource: BondSource.Storage,
              bond: normalized,
              collateral: BigInt(collateral as bigint),
              collateralCurrency: normalized.collateralIsCurrency0
                ? deployment.currency0
                : deployment.currency1,
            };
          } catch {
            // A transient read failure changes nothing; the held record stands.
            return undefined;
          }
        }),
      );

      const fresh = observations.filter((item): item is BondRecord => item !== undefined);
      if (!cancelled && fresh.length > 0) {
        setRecords((previous) => mergeBondRecords(previous, fresh));
      }
    }

    void reconcile();
    const timer = window.setInterval(() => void reconcile(), STORAGE_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [publicClient, account, knownIds, deployment]);

  const summary = useMemo(() => {
    // "A bond exists" is not "a bond is unsettled": settled bonds are retained records and
    // `collateralAmountOf` keeps returning their original collateral forever.
    const unsettled = records.filter((record) => record.bond?.state === 2);
    const settled = records.filter((record) => recordIsSettled(record));
    return { unsettled, settled };
  }, [records]);

  // Transient failures are "syncing"; only a sustained outage is worth naming.
  const historyStatus: "ok" | "syncing" | "unavailable" =
    historyFailures === 0 ? "ok" : historyFailures < HISTORY_FAILURES_BEFORE_WARNING ? "syncing" : "unavailable";

  return {
    records,
    ...summary,
    loading,
    historyStatus,
    refresh,
    addDiscoveredBond,
    markSettledFromReceipt,
  };
}
