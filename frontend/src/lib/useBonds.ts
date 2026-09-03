"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Address, Hex } from "viem";
import { usePublicClient } from "wagmi";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import {
  collectBondEvents,
  normalizeBond,
  type Bond,
  type BondOpenedEvent,
  type BondSettledEvent,
  type BondTakenEvent,
} from "@/lib/bond";
import type { Deployment } from "@/lib/deployment";

/** One bond as the UI knows it: identity from logs, truth from `getBond`. */
export type BondRecord = {
  bondId: Hex;
  /** Undefined while loading, or when the read failed. Never invented. */
  bond?: Bond;
  /** ORIGINAL collateral taken. Unchanged after settlement; not remaining liability. */
  collateral?: bigint;
  collateralCurrency?: Address;
  openedTxHash?: Hex;
  openedBlock?: bigint;
  settlement?: BondSettledEvent;
  readError?: string;
};

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
 * `scanNote` reports the window actually covered so the UI can say so.
 */
export function useBondIndex(deployment: Deployment, account?: Address) {
  const publicClient = usePublicClient({ chainId: deployment.chainId });
  const [records, setRecords] = useState<BondRecord[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | undefined>();
  const [scanNote, setScanNote] = useState<string | undefined>();
  const [nonce, setNonce] = useState(0);
  const lastAccount = useRef<string | undefined>(undefined);

  const accountKey = account?.toLowerCase();

  // An account change invalidates every account-scoped row immediately, before the next
  // load resolves, so a stale list is never shown under a new address.
  useEffect(() => {
    if (lastAccount.current !== accountKey) {
      lastAccount.current = accountKey;
      setRecords([]);
      setError(undefined);
    }
  }, [accountKey]);

  const addDiscoveredBond = useCallback(
    (opened: BondOpenedEvent) => {
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
      setNonce((value) => value + 1);
    },
    [deployment],
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
      setError(undefined);
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

        setScanNote(
          from > deployment.deploymentBlock
            ? `Scanned blocks ${from}–${latest}. Bonds opened before block ${from} are only listed if this browser recorded them.`
            : `Scanned blocks ${from}–${latest} — the whole deployment history.`,
        );

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

        if (!cancelled) setRecords(resolved);
      } catch (loadError) {
        if (!cancelled) {
          setError(
            loadError instanceof Error
              ? `Bond history unavailable: ${loadError.message.split("\n")[0]}`
              : "Bond history unavailable.",
          );
        }
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

  const summary = useMemo(() => {
    // "A bond exists" is not "a bond is unsettled": settled bonds are retained records and
    // `collateralAmountOf` keeps returning their original collateral forever.
    const unsettled = records.filter((record) => record.bond?.state === 2);
    const settled = records.filter((record) => record.bond?.state === 3);
    return { unsettled, settled };
  }, [records]);

  return { records, ...summary, loading, error, scanNote, refresh, addDiscoveredBond };
}
