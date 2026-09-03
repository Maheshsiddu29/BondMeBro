"use client";

import { useState } from "react";
import type { Address, Hex } from "viem";
import { usePublicClient, useSwitchChain, useWriteContract } from "wagmi";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import type { Activity } from "@/lib/activity";
import {
  blocksUntilMaturity,
  bondStateLabel,
  canSettle,
  collectBondEvents,
  maturityProgress,
  normalizeBond,
  BondState,
} from "@/lib/bond";
import { explorerTx } from "@/lib/deployment";
import { describeError } from "@/lib/errors";
import { formatAddress, formatAmount, formatBps, formatBlock } from "@/lib/format";
import { assertContext, assertReceiptSucceeded, type IntendedContext } from "@/lib/guards";
import { metaForCurrency } from "@/lib/tokenMetadata";
import type { BondRecord } from "@/lib/useBonds";
import type { ProtocolState } from "@/lib/useProtocol";
import { Badge, MetricCard, StatusDot } from "@/components/ui";

type SettleState = "idle" | "sending" | "success" | "error";

export function BondsScreen({
  protocol,
  records,
  unsettled,
  settled,
  loading,
  error,
  scanNote,
  account,
  walletChainId,
  isConnected,
  onConnect,
  onSwap,
  onActivity,
  onRefresh,
}: {
  protocol: ProtocolState;
  records: BondRecord[];
  unsettled: BondRecord[];
  settled: BondRecord[];
  loading: boolean;
  error?: string;
  scanNote?: string;
  account?: Address;
  walletChainId?: number;
  isConnected: boolean;
  onConnect: () => void;
  onSwap: () => void;
  onActivity: (item: Activity) => void;
  onRefresh: () => void;
}) {
  const { deployment, blockNumber, token0, token1 } = protocol;
  const publicClient = usePublicClient({ chainId: deployment.chainId });
  const { writeContractAsync } = useWriteContract();
  const { switchChain } = useSwitchChain();

  const [state, setState] = useState<SettleState>("idle");
  const [activeBondId, setActiveBondId] = useState<Hex | undefined>();
  const [hash, setHash] = useState<Hex | undefined>();
  const [message, setMessage] = useState("");

  const networkCorrect = walletChainId === deployment.chainId;
  const busy = state === "sending";

  async function settle(bondId: Hex) {
    if (!account || walletChainId === undefined || !publicClient) return;
    const intended: IntendedContext = { address: account, chainId: walletChainId };
    setState("sending");
    setActiveBondId(bondId);
    setMessage("");
    setHash(undefined);
    try {
      assertContext(intended, { address: account, chainId: walletChainId });

      // Settlement is permissionless. The caller does not have to be the refund recipient,
      // and cannot change where the refund goes: it is the bond's stored recipient.
      const submitted = await writeContractAsync({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "settleBond",
        args: [bondId],
        account: intended.address,
        chainId: intended.chainId,
      });
      setHash(submitted);

      const receipt = assertReceiptSucceeded(
        await publicClient.waitForTransactionReceipt({ hash: submitted }),
        "settlement",
      );

      const { settled: settledEvents } = collectBondEvents(receipt.logs, deployment.hook, deployment.poolId);
      const event = settledEvents.find((item) => item.bondId.toLowerCase() === bondId.toLowerCase());

      // Confirm the stored state actually moved to SETTLED before saying so.
      const after = normalizeBond(
        (await publicClient.readContract({
          address: deployment.hook,
          abi: bondMeBroAbi,
          functionName: "getBond",
          args: [bondId],
        })) as never,
      );
      if (after.state !== BondState.Settled) {
        throw new Error("The settlement transaction succeeded but the bond is not marked settled.");
      }

      const currencyMeta = metaForCurrency(event?.currency, { currency0: token0, currency1: token1 });
      onActivity({
        kind: "SETTLED",
        block: receipt.blockNumber.toString(),
        hash: submitted,
        logIndex: event?.logIndex,
        detail: event && currencyMeta
          ? `Bond settled · refund ${formatAmount(event.refund, currencyMeta.decimals)} ${currencyMeta.symbol} · retained ${formatAmount(event.slash, currencyMeta.decimals)} ${currencyMeta.symbol}`
          : "Bond settled",
      });

      setState("success");
      onRefresh();
      protocol.refresh();
    } catch (settleError) {
      setState("error");
      setMessage(describeError(settleError));
    }
  }

  const readyCount = unsettled.filter(
    (record) => record.bond && blockNumber !== undefined && canSettle(record.bond, blockNumber),
  ).length;

  return (
    <>
      <section className="screen-intro">
        <div>
          <span className="eyebrow">02 / PORTFOLIO</span>
          <h1>
            My bonds.
            <br />
            <em>Track.</em>
          </h1>
        </div>
        <p>Every figure below comes from the hook&apos;s stored bond record, not from a local guess.</p>
      </section>

      <section className="bond-summary-grid">
        <MetricCard label="UNSETTLED BONDS" value={String(unsettled.length)} detail="state FINALIZED" icon="◈" accent />
        <MetricCard label="READY TO SETTLE" value={String(readyCount)} detail="at or past maturity" icon="✓" />
        <MetricCard label="SETTLED BONDS" value={String(settled.length)} detail="state SETTLED" icon="↗" />
      </section>

      <article className="neo-card user-bonds-card">
        <div className="card-heading">
          <div>
            <span className="eyebrow">YOUR BONDS</span>
            <h2>Bond records</h2>
          </div>
          <div className="activity-heading-actions">
            <Badge tone={isConnected ? "green" : "muted"}>
              {isConnected ? "WALLET FILTERED" : "CONNECT TO FILTER"}
            </Badge>
            <button type="button" className="outline-button activity-refresh" onClick={onRefresh}>
              Refresh
            </button>
          </div>
        </div>

        {scanNote && <div className="inline-empty activity-cache-note">{scanNote}</div>}
        {error && <div className="pair-warning">{error}</div>}

        {!isConnected ? (
          <div className="inline-empty">
            <button type="button" className="text-button" onClick={onConnect}>
              Connect wallet
            </button>{" "}
            to load bonds.
          </div>
        ) : loading && records.length === 0 ? (
          <div className="inline-empty">Reading bonds…</div>
        ) : records.length === 0 ? (
          <div className="empty-card large-empty">
            <div className="empty-icon">◈</div>
            <strong>No bonds for this wallet</strong>
            <span>Not every swap creates one; a trade below either minimum executes unbonded.</span>
            <button type="button" className="primary-button" onClick={onSwap}>
              Make a swap →
            </button>
          </div>
        ) : (
          <div className="user-bond-list">
            {records.map((record) => {
              const bond = record.bond;
              const currencyMeta = metaForCurrency(record.collateralCurrency, {
                currency0: token0,
                currency1: token1,
              });
              const ready = bond && blockNumber !== undefined && canSettle(bond, blockNumber);
              const progress = bond ? maturityProgress(bond, blockNumber) : 0;
              const remaining =
                bond && blockNumber !== undefined ? blocksUntilMaturity(bond.maturityBlock, blockNumber) : undefined;

              return (
                <div
                  className={`user-bond-record ${bond?.state === BondState.Settled ? "user-bond-settled" : ""}`}
                  key={record.bondId}
                >
                  <div className="user-bond-record-top">
                    <div>
                      <span className="bond-record-pair">
                        {token0?.symbol ?? "TOKEN0"} / {token1?.symbol ?? "TOKEN1"}
                      </span>
                      <strong>{record.bondId}</strong>
                    </div>
                    <Badge
                      tone={
                        bond?.state === BondState.Settled ? "green" : ready ? "orange" : bond ? "neutral" : "muted"
                      }
                    >
                      {bond ? bondStateLabel(bond.state) : "UNAVAILABLE"}
                    </Badge>
                  </div>

                  {record.readError && <div className="pair-warning">{record.readError}</div>}

                  {bond && (
                    <>
                      <div className="user-bond-record-grid">
                        <div>
                          <span>ORIGINAL COLLATERAL</span>
                          <strong>
                            {currencyMeta
                              ? `${formatAmount(record.collateral, currencyMeta.decimals)} ${currencyMeta.symbol}`
                              : "—"}
                          </strong>
                        </div>
                        <div>
                          <span>COLLATERAL CURRENCY</span>
                          <strong>{currencyMeta?.symbol ?? "—"}</strong>
                        </div>
                        <div>
                          <span>OPENED</span>
                          <strong>Block {formatBlock(bond.openBlock)}</strong>
                        </div>
                        <div>
                          <span>MATURITY (STORED)</span>
                          <strong>Block {formatBlock(bond.maturityBlock)}</strong>
                        </div>
                        <div>
                          <span>COLLATERAL RATE</span>
                          <strong>{formatBps(bond.collateralBps)}</strong>
                        </div>
                        <div>
                          <span>REFUND RECIPIENT</span>
                          <strong>{formatAddress(bond.refundRecipient)}</strong>
                        </div>
                        <div>
                          <span>SWAP TX</span>
                          {record.openedTxHash ? (
                            <a href={explorerTx(deployment, record.openedTxHash)} target="_blank" rel="noreferrer">
                              View ↗
                            </a>
                          ) : (
                            <strong>—</strong>
                          )}
                        </div>
                        <div>
                          <span>CURRENT BLOCK</span>
                          <strong>{formatBlock(blockNumber)}</strong>
                        </div>
                      </div>

                      {bond.state === BondState.Finalized && (
                        <>
                          <div className="bond-progress">
                            <span>
                              <i style={{ width: `${progress}%` }} />
                            </span>
                            <b>
                              {remaining === undefined
                                ? "Current block unavailable"
                                : remaining === 0n
                                  ? "Matured — settle now"
                                  : `${remaining} block${remaining === 1n ? "" : "s"} until maturity`}
                            </b>
                          </div>
                          <div className="detail-actions">
                            {!isConnected ? (
                              <button type="button" className="primary-button large-button" onClick={onConnect}>
                                Connect wallet <span>→</span>
                              </button>
                            ) : !networkCorrect ? (
                              <button
                                type="button"
                                className="primary-button large-button"
                                onClick={() => switchChain({ chainId: deployment.chainId })}
                              >
                                Switch to {deployment.networkName} <span>→</span>
                              </button>
                            ) : (
                              <button
                                type="button"
                                className="primary-button large-button"
                                disabled={!ready || busy}
                                onClick={() => void settle(record.bondId)}
                              >
                                {busy && activeBondId === record.bondId
                                  ? "Confirming…"
                                  : ready
                                    ? "Settle this bond"
                                    : "Not yet mature"}{" "}
                                <span>→</span>
                              </button>
                            )}
                            <span>
                              Anyone may settle a matured bond. The refund always goes to the stored recipient, not the
                              caller, and settling later gives the identical result.
                            </span>
                          </div>
                        </>
                      )}

                      {bond.state === BondState.Settled && (
                        <div
                          className={`settlement-result ${
                            record.settlement && record.settlement.slash > 0n
                              ? "settlement-result-slash"
                              : "settlement-result-refund"
                          }`}
                        >
                          {record.settlement && currencyMeta ? (
                            <>
                              <div>
                                <span>ORIGINAL COLLATERAL</span>
                                <strong>
                                  {formatAmount(record.settlement.collateral, currencyMeta.decimals)}{" "}
                                  {currencyMeta.symbol}
                                </strong>
                              </div>
                              <div>
                                <span>REFUNDED</span>
                                <strong>
                                  {formatAmount(record.settlement.refund, currencyMeta.decimals)} {currencyMeta.symbol}
                                </strong>
                              </div>
                              <div>
                                <span>RETAINED (SLASH)</span>
                                <strong>
                                  {formatAmount(record.settlement.slash, currencyMeta.decimals)} {currencyMeta.symbol}
                                </strong>
                              </div>
                              <div>
                                <span>SLASH RATE</span>
                                <strong>{formatBps(record.settlement.slashBps)}</strong>
                              </div>
                              {record.settlement.transactionHash && (
                                <a
                                  href={explorerTx(deployment, record.settlement.transactionHash)}
                                  target="_blank"
                                  rel="noreferrer"
                                >
                                  Settlement tx ↗
                                </a>
                              )}
                              <p className="refund-delivery-note">
                                Refund sent to {formatAddress(bond.refundRecipient)}. The retained amount is held in the
                                pool&apos;s insurance reserve.
                              </p>
                            </>
                          ) : (
                            <p className="refund-delivery-note">
                              This bond is settled. Its BondSettled event is outside the scanned log window, so the
                              refund and retained split are not shown here.
                            </p>
                          )}
                        </div>
                      )}
                    </>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {state === "error" && <div className="transaction-message transaction-error">{message}</div>}
        {state === "success" && hash && (
          <div className="transaction-message transaction-success">
            Settlement succeeded and the bond now reads SETTLED.{" "}
            <a href={explorerTx(deployment, hash)} target="_blank" rel="noreferrer">
              View ↗
            </a>
          </div>
        )}
      </article>

      <article className="glass-card claims-card">
        <div className="card-heading">
          <div>
            <span className="eyebrow">RESERVE</span>
            <h2>Insurance reserve</h2>
          </div>
          <Badge tone="neutral">
            <StatusDot live={protocol.rpcOnline} /> ACCOUNTING ONLY
          </Badge>
        </div>
        <p className="card-copy">
          Retained collateral accumulates in a per-pool, per-currency LP-risk compensation reserve. This version has no
          payout, donation or claim function, and no settler reward.
        </p>
        <div className="claim-list">
          <div className="claim-row">
            <div>
              <span>{token0?.symbol ?? "CURRENCY0"} RESERVE</span>
              <strong>
                {token0 ? `${formatAmount(protocol.insurancePot0, token0.decimals)} ${token0.symbol}` : "—"}
              </strong>
            </div>
          </div>
          <div className="claim-row">
            <div>
              <span>{token1?.symbol ?? "CURRENCY1"} RESERVE</span>
              <strong>
                {token1 ? `${formatAmount(protocol.insurancePot1, token1.decimals)} ${token1.symbol}` : "—"}
              </strong>
            </div>
          </div>
        </div>
      </article>
    </>
  );
}
