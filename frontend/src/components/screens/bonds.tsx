"use client";

import { useState } from "react";
import type { Address, Hex } from "viem";
import { usePublicClient, useSwitchChain, useWriteContract } from "wagmi";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import type { Activity } from "@/lib/activity";
import {
  blocksUntilMaturity,
  collectBondEvents,
  normalizeBond,
  BondState,
  type BondSettledEvent,
} from "@/lib/bond";
import { canOfferSettlement, type BondRecord } from "@/lib/bondStore";
import { explorerTx } from "@/lib/deployment";
import { describeError, describePreflightError } from "@/lib/errors";
import { formatAmount, formatBps } from "@/lib/format";
import { submitWithBoundedGas } from "@/lib/gas";
import {
  assertContext,
  assertReceiptSucceeded,
  TransactionFailedError,
  type IntendedContext,
} from "@/lib/guards";
import { resolveSettlementOutcome, settlementPreflight } from "@/lib/settlement";
import { metaForCurrency } from "@/lib/tokenMetadata";
import type { ProtocolState } from "@/lib/useProtocol";

type SettleState = "idle" | "preflight" | "submitted" | "success" | "error";

export function BondsScreen({
  protocol,
  records,
  unsettled,
  settled,
  loading,
  historyStatus,
  account,
  walletChainId,
  isConnected,
  onConnect,
  onSwap,
  onActivity,
  onRefresh,
  onSettledFromReceipt,
}: {
  protocol: ProtocolState;
  records: BondRecord[];
  unsettled: BondRecord[];
  settled: BondRecord[];
  loading: boolean;
  historyStatus: "ok" | "syncing" | "unavailable";
  account?: Address;
  walletChainId?: number;
  isConnected: boolean;
  onConnect: () => void;
  onSwap: () => void;
  onActivity: (item: Activity) => void;
  onRefresh: () => void;
  onSettledFromReceipt: (bondId: Hex, settlement?: BondSettledEvent, txHash?: Hex) => void;
}) {
  const { deployment, blockNumber, token0, token1 } = protocol;
  const publicClient = usePublicClient({ chainId: deployment.chainId });
  const { writeContractAsync } = useWriteContract();
  const { switchChain } = useSwitchChain();

  const [state, setState] = useState<SettleState>("idle");
  const [activeBondId, setActiveBondId] = useState<Hex | undefined>();
  const [hash, setHash] = useState<Hex | undefined>();
  const [settlementError, setSettlementError] = useState("");
  const [settlementNote, setSettlementNote] = useState("");

  const networkCorrect = walletChainId === deployment.chainId;
  const busy = state === "preflight" || state === "submitted";

  async function settle(bondId: Hex) {
    if (!account || walletChainId === undefined || !publicClient) return;
    const intended: IntendedContext = { address: account, chainId: walletChainId };

    // A new attempt clears the previous failure. A stale "reverted" message must never sit
    // underneath a bond that has since settled.
    setState("preflight");
    setActiveBondId(bondId);
    setSettlementError("");
    setSettlementNote("");
    setHash(undefined);

    let submitted: Hex | undefined;

    try {
      assertContext(intended, { address: account, chainId: walletChainId });

      // READ-ONLY PREFLIGHT. An immature, absent or already-settled bond must not reach the
      // wallet at all.
      const [fresh, currentBlock] = await Promise.all([
        publicClient.readContract({
          address: deployment.hook,
          abi: bondMeBroAbi,
          functionName: "getBond",
          args: [bondId],
        }),
        publicClient.getBlockNumber(),
      ]);

      const check = settlementPreflight(normalizeBond(fresh as never), currentBlock);
      if (!check.ok) {
        // Storage is the authority: if it says settled, show settled rather than an error.
        setState(check.alreadySettled ? "success" : "error");
        if (check.alreadySettled) setSettlementNote(check.reason);
        else setSettlementError(check.reason);
        onRefresh();
        protocol.refresh();
        return;
      }

      // Settlement is permissionless. The caller does not have to be the refund recipient,
      // and cannot change where the refund goes: it is the bond's stored recipient.
      const call = {
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "settleBond",
        args: [bondId],
        account: intended.address,
      } as const;

      let gasResult;
      try {
        gasResult = await submitWithBoundedGas({
          call,
          chainId: intended.chainId,
          label: "settleBond",
          estimateGas: (c) => publicClient.estimateContractGas(c),
          write: (c) => writeContractAsync(c),
        });
      } catch (preflightError) {
        // Decode the REAL revert rather than surfacing an empty reason.
        setState("error");
        setSettlementError(describePreflightError(preflightError, "Settlement"));
        return;
      }

      submitted = gasResult.hash;
      setHash(submitted);
      setState("submitted");

      const receipt = assertReceiptSucceeded(
        await publicClient.waitForTransactionReceipt({ hash: submitted }),
        "settlement",
      );

      // ---------------------------------------------------------------------------------
      // FROM HERE THE SETTLEMENT HAS SUCCEEDED. Nothing below may mark it failed.
      // ---------------------------------------------------------------------------------
      setState("success");
      setSettlementError("");

      // Highest-priority observation, applied BEFORE any read-back. The settle button
      // disappears now and no later read may bring it back.
      onSettledFromReceipt(bondId, undefined, submitted);

      let storageState: BondState | undefined;
      let postReceiptFailed = false;

      try {
        const { settled: settledEvents } = collectBondEvents(
          receipt.logs,
          deployment.hook,
          deployment.poolId,
        );
        const event = settledEvents.find((item) => item.bondId.toLowerCase() === bondId.toLowerCase());

        const after = normalizeBond(
          (await publicClient.readContract({
            address: deployment.hook,
            abi: bondMeBroAbi,
            functionName: "getBond",
            args: [bondId],
          })) as never,
        );
        storageState = after.state;

        if (event) onSettledFromReceipt(bondId, event, submitted);

        const currencyMeta = metaForCurrency(event?.currency, { currency0: token0, currency1: token1 });
        onActivity({
          kind: "SETTLED",
          block: receipt.blockNumber.toString(),
          hash: submitted,
          logIndex: event?.logIndex,
          detail:
            event && currencyMeta
              ? `Bond settled · refund ${formatAmount(event.refund, currencyMeta.decimals)} ${currencyMeta.symbol} · retained ${formatAmount(event.slash, currencyMeta.decimals)} ${currencyMeta.symbol}`
              : "Bond settled",
        });
      } catch {
        // Parsing or reading back failed. The settlement still happened.
        postReceiptFailed = true;
      }

      const outcome = resolveSettlementOutcome({
        receiptSucceeded: true,
        storageState,
        postReceiptFailed,
      });
      setSettlementNote(outcome.note);

      onRefresh();
      protocol.refresh();
    } catch (settleError) {
      if (submitted && !(settleError instanceof TransactionFailedError)) {
        // A hash exists but confirmation could not be obtained. Do not claim failure.
        setState("submitted");
        setSettlementNote("Submitted. The receipt could not be read yet; check the transaction.");
      } else {
        setState("error");
        setSettlementError(describeError(settleError));
      }
    }
  }

  const pair = `${token0?.symbol ?? "TOKEN0"} / ${token1?.symbol ?? "TOKEN1"}`;

  return (
    <div className="page page-wide">
      <span className="eyebrow">Portfolio</span>
      <h1 className="page-title">Your Bonds</h1>
      <p className="page-sub">
        {unsettled.length} active · {settled.length} settled. Updates automatically.
      </p>

      {!isConnected ? (
        <div className="empty">
          <strong>Wallet not connected</strong>
          <button type="button" className="cta-ghost" style={{ maxWidth: 220, margin: "14px auto 0" }} onClick={onConnect}>
            Connect wallet
          </button>
        </div>
      ) : loading && records.length === 0 ? (
        <div className="empty">Reading bonds…</div>
      ) : records.length === 0 ? (
        <div className="empty">
          <strong>No bonds yet</strong>
          Not every swap creates one. Small trades execute unbonded.
          <button type="button" className="cta-ghost" style={{ maxWidth: 220, margin: "14px auto 0" }} onClick={onSwap}>
            Make a swap
          </button>
        </div>
      ) : (
        <div className="bond-list">
          {records.map((record) => (
            <BondCard
              key={record.bondId}
              record={record}
              pair={pair}
              currentBlock={blockNumber}
              token0={token0}
              token1={token1}
              deployment={deployment}
              isConnected={isConnected}
              networkCorrect={networkCorrect}
              busy={busy}
              isActive={activeBondId === record.bondId}
              state={state}
              onConnect={onConnect}
              onSwitchNetwork={() => switchChain({ chainId: deployment.chainId })}
              onSettle={() => void settle(record.bondId)}
            />
          ))}
        </div>
      )}

      {state === "error" && settlementError && <div className="transaction-message transaction-error">{settlementError}</div>}

      {historyStatus !== "ok" && (
        <p className="note">
          {historyStatus === "syncing" ? "Syncing bond history…" : "Bond history temporarily unavailable."}{" "}
          Bonds already known stay listed and can still be settled.
        </p>
      )}
      <p className="note">
        Settlement is permissionless — anyone may settle a matured bond, and the refund always goes to the recipient
        stored in the bond.{" "}
        <button type="button" className="link-btn" onClick={onRefresh}>
          Refresh
        </button>
      </p>
    </div>
  );
}

function BondCard({
  record,
  pair,
  currentBlock,
  token0,
  token1,
  deployment,
  isConnected,
  networkCorrect,
  busy,
  isActive,
  state,
  onConnect,
  onSwitchNetwork,
  onSettle,
}: {
  record: BondRecord;
  pair: string;
  currentBlock?: bigint;
  token0?: ReturnType<typeof metaForCurrency>;
  token1?: ReturnType<typeof metaForCurrency>;
  deployment: ProtocolState["deployment"];
  isConnected: boolean;
  networkCorrect: boolean;
  busy: boolean;
  isActive: boolean;
  state: SettleState;
  onConnect: () => void;
  onSwitchNetwork: () => void;
  onSettle: () => void;
}) {
  const bond = record.bond;
  const meta = metaForCurrency(record.collateralCurrency, { currency0: token0, currency1: token1 });
  const isSettled = bond?.state === BondState.Settled;
  const ready = canOfferSettlement(record, currentBlock);
  const remaining =
    bond && currentBlock !== undefined ? blocksUntilMaturity(bond.maturityBlock, currentBlock) : undefined;

  const badge = isSettled
    ? { className: "badge badge-settled", text: "SETTLED" }
    : ready
      ? { className: "badge badge-ready", text: "READY" }
      : bond
        ? { className: "badge badge-active", text: "ACTIVE" }
        : { className: "badge badge-muted", text: "UNAVAILABLE" };

  return (
    <article className="bond-card">
      <div className="bond-card-head">
        <div>
          <div className="bond-pair">{pair}</div>
          <code className="bond-id">
            {record.bondId.slice(0, 10)}…{record.bondId.slice(-6)}
          </code>
        </div>
        <span className={badge.className}>{badge.text}</span>
      </div>

      {record.readError && <div className="pair-warning">{record.readError}</div>}

      {bond && !isSettled && (
        <>
          <div className="bond-grid">
            <div className="bond-metric">
              <span>Collateral</span>
              <strong className="pink">{meta ? formatAmount(record.collateral, meta.decimals, 6) : "—"}</strong>
            </div>
            <div className="bond-metric">
              <span>Rate</span>
              <strong>{formatBps(bond.collateralBps)}</strong>
            </div>
            <div className="bond-metric">
              <span>Opened</span>
              <strong>{bond.openBlock.toString()}</strong>
            </div>
            <div className="bond-metric">
              <span>Maturity</span>
              <strong>{bond.maturityBlock.toString()}</strong>
            </div>
          </div>

          <div className="bond-foot">
            <span className="countdown">
              {remaining === undefined
                ? "Syncing…"
                : remaining === 0n
                  ? "Matured"
                  : `${remaining} block${remaining === 1n ? "" : "s"} left`}
            </span>
            {!isConnected ? (
              <button type="button" className="settle-btn" onClick={onConnect}>
                CONNECT
              </button>
            ) : !networkCorrect ? (
              <button type="button" className="settle-btn" onClick={onSwitchNetwork}>
                SWITCH NETWORK
              </button>
            ) : (
              <button type="button" className="settle-btn" disabled={!ready || busy} onClick={onSettle}>
                {isActive && state === "preflight"
                  ? "CHECKING…"
                  : isActive && state === "submitted"
                    ? "SETTLING…"
                    : ready
                      ? "SETTLE BOND"
                      : "NOT MATURE"}
              </button>
            )}
          </div>
        </>
      )}

      {bond && isSettled && (
        <>
          <div className="bond-grid">
            <div className="bond-metric">
              <span>Refunded</span>
              <strong className="good">
                {record.settlement && meta ? formatAmount(record.settlement.refund, meta.decimals, 6) : "—"}
              </strong>
            </div>
            <div className="bond-metric">
              <span>Retained</span>
              <strong>
                {record.settlement && meta ? formatAmount(record.settlement.slash, meta.decimals, 6) : "—"}
              </strong>
            </div>
            <div className="bond-metric">
              <span>Slash rate</span>
              <strong>{record.settlement ? formatBps(record.settlement.slashBps) : "—"}</strong>
            </div>
            <div className="bond-metric">
              <span>Collateral</span>
              <strong>{meta ? formatAmount(record.collateral, meta.decimals, 6) : "—"}</strong>
            </div>
          </div>
          <div className="bond-foot">
            <span className="countdown">Settled at block {bond.maturityBlock.toString()} or later</span>
            {(record.settlementTxHash ?? record.settlement?.transactionHash) && (
              <a
                className="tx-link"
                href={explorerTx(deployment, (record.settlementTxHash ?? record.settlement?.transactionHash) as Hex)}
                target="_blank"
                rel="noreferrer"
              >
                Settlement tx ↗
              </a>
            )}
          </div>
        </>
      )}
    </article>
  );
}
