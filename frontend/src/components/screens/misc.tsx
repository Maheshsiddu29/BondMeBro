"use client";

import { activityIcon, type Activity } from "@/lib/activity";
import { explorerTx, shortenHash, type Deployment } from "@/lib/deployment";
import { formatAmount } from "@/lib/format";
import type { BondRecord } from "@/lib/useBonds";
import type { ProtocolState } from "@/lib/useProtocol";
import { Badge, MetricCard, StatusDot } from "@/components/ui";

export function OverviewScreen({
  protocol,
  unsettled,
  settled,
  activity,
  onSwap,
  onLearn,
  onViewBonds,
  onViewActivity,
}: {
  protocol: ProtocolState;
  unsettled: BondRecord[];
  settled: BondRecord[];
  activity: Activity[];
  onSwap: () => void;
  onLearn: () => void;
  onViewBonds: () => void;
  onViewActivity: () => void;
}) {
  const { deployment, token0, token1 } = protocol;

  return (
    <>
      <section className="welcome-grid">
        <div className="welcome-copy">
          <span className="eyebrow">{deployment.networkName.toUpperCase()} / CHAIN {deployment.chainId}</span>
          <h1>
            Swap.
            <br />
            <em>Settle.</em>
          </h1>
          <p>Refundable collateral, settled against a fixed observation window.</p>
          <div className="welcome-actions">
            <button type="button" className="primary-button large-button" onClick={onSwap}>
              Swap now <span>↗</span>
            </button>
            <button type="button" className="text-button" onClick={onLearn}>
              Learn <span>→</span>
            </button>
          </div>
        </div>
        <div className="hero-visual">
          <div className="hero-orb">
            <span>01</span>
            <div className="orb-ring orb-ring-one" />
            <div className="orb-ring orb-ring-two" />
            <div className="orb-dot" />
          </div>
          <div className="floating-card floating-status">
            <div className="floating-card-label">POOL</div>
            <div className="status-line">
              <StatusDot live={protocol.rpcOnline} />
              <strong>
                {token0?.symbol ?? "TOKEN0"} / {token1?.symbol ?? "TOKEN1"}
              </strong>
              <span>{protocol.poolConfig?.bondingEnabled ? "bonding enabled" : "bonding disabled"}</span>
            </div>
          </div>
        </div>
      </section>

      <section className="metric-grid">
        <MetricCard
          label="UNSETTLED BONDS"
          value={String(unsettled.length)}
          detail="state FINALIZED"
          accent
          icon="◈"
        />
        <MetricCard label="SETTLED BONDS" value={String(settled.length)} detail="state SETTLED" icon="✓" />
        <MetricCard
          label="RESERVE"
          value={token0 ? `${formatAmount(protocol.insurancePot0, token0.decimals)} ${token0.symbol}` : "—"}
          detail={token1 ? `${formatAmount(protocol.insurancePot1, token1.decimals)} ${token1.symbol}` : "—"}
          icon="♢"
        />
        <MetricCard
          label="POOL READY"
          value={!protocol.rpcOnline ? "OFFLINE" : protocol.canTrade ? "YES" : "CONFIG ERROR"}
          detail={protocol.poolConfig?.bondingEnabled ? "bonding enabled" : "swaps run unbonded"}
          icon="⌁"
        />
      </section>

      <section className="content-grid overview-grid overview-grid-single">
        <article className="neo-card active-bonds-card">
          <div className="card-heading">
            <div>
              <span className="eyebrow">01 / PORTFOLIO</span>
              <h2>Unsettled bonds</h2>
            </div>
            <button className="card-link" type="button" onClick={onViewBonds}>
              View all <span>→</span>
            </button>
          </div>
          {unsettled.length === 0 ? (
            <div className="empty-card active-bonds-empty">
              <strong>No unsettled bonds</strong>
              <span>A settled bond stays on record but is not outstanding.</span>
              <button type="button" className="text-button" onClick={onSwap}>
                Make a swap →
              </button>
            </div>
          ) : (
            <div className="bond-table">
              <div className="bond-table-head">
                <span>BOND</span>
                <span>COLLATERAL</span>
                <span>MATURITY</span>
                <span>STATUS</span>
              </div>
              {unsettled.slice(0, 4).map((record) => {
                const meta = record.collateralCurrency?.toLowerCase() === token0?.address.toLowerCase() ? token0 : token1;
                const ready =
                  record.bond && protocol.blockNumber !== undefined
                    ? protocol.blockNumber >= record.bond.maturityBlock
                    : false;
                return (
                  <div className="bond-table-row" key={record.bondId}>
                    <div className="pool-cell">
                      <div>
                        <strong>
                          {token0?.symbol ?? "TOKEN0"} / {token1?.symbol ?? "TOKEN1"}
                        </strong>
                        <small>{shortenHash(record.bondId, 7, 5)}</small>
                      </div>
                    </div>
                    <strong className="orange-text">
                      {meta ? `${formatAmount(record.collateral, meta.decimals)} ${meta.symbol}` : "—"}
                    </strong>
                    <div>
                      <strong>Block {record.bond ? record.bond.maturityBlock.toString() : "—"}</strong>
                      <small>opened {record.bond ? record.bond.openBlock.toString() : "—"}</small>
                    </div>
                    <Badge tone={ready ? "orange" : "neutral"}>{ready ? "READY" : "MATURING"}</Badge>
                  </div>
                );
              })}
            </div>
          )}
          <div className="card-footer">
            <span>Maturity comes from each bond&apos;s stored maturityBlock.</span>
            <span className="footer-status">
              <StatusDot live={protocol.rpcOnline} /> {protocol.rpcOnline ? "synced" : "rpc offline"}
            </span>
          </div>
        </article>
      </section>

      <ActivityPreview deployment={deployment} activity={activity} onViewAll={onViewActivity} />
    </>
  );
}

function ActivityPreview({
  deployment,
  activity,
  onViewAll,
}: {
  deployment: Deployment;
  activity: Activity[];
  onViewAll: () => void;
}) {
  return (
    <section className="activity-preview">
      <div className="card-heading">
        <div>
          <span className="eyebrow">03 / ACTIVITY</span>
          <h2>Recent activity</h2>
        </div>
        <button type="button" className="card-link" onClick={onViewAll}>
          View activity <span>→</span>
        </button>
      </div>
      {activity.length === 0 ? (
        <div className="inline-empty">No recorded events yet.</div>
      ) : (
        <div className="activity-rows">
          {activity.slice(0, 4).map((item) => (
            <a
              className="activity-row"
              href={item.hash ? explorerTx(deployment, item.hash) : "#"}
              target="_blank"
              rel="noreferrer"
              key={`${item.kind}-${item.hash ?? "local"}-${item.logIndex ?? 0}-${item.block}`}
            >
              <span className={`event-icon event-${item.kind.toLowerCase()}`}>{activityIcon(item.kind)}</span>
              <div>
                <strong>{item.detail}</strong>
                <small>Block {item.block}</small>
              </div>
              <span className="activity-row-hash">{item.hash ? shortenHash(item.hash) : "—"} ↗</span>
            </a>
          ))}
        </div>
      )}
    </section>
  );
}

export function ActivityScreen({
  deployment,
  activity,
  onRefresh,
}: {
  deployment: Deployment;
  activity: Activity[];
  onRefresh: () => void;
}) {
  return (
    <>
      <section className="screen-intro">
        <div>
          <span className="eyebrow">04 / EVENT STREAM</span>
          <h1>
            Activity.
            <br />
            <em>Live.</em>
          </h1>
        </div>
        <p>Events this browser has confirmed, decoded from the current contract ABI.</p>
      </section>
      <article className="neo-card full-activity-card">
        <div className="card-heading">
          <div>
            <span className="eyebrow">THIS BROWSER</span>
            <h2>Protocol activity</h2>
          </div>
          <div className="activity-heading-actions">
            <button type="button" className="outline-button activity-refresh" onClick={onRefresh}>
              Refresh
            </button>
          </div>
        </div>
        {activity.length === 0 ? (
          <div className="inline-empty">No events recorded yet.</div>
        ) : (
          <div className="activity-table">
            <div className="activity-table-head">
              <span>EVENT</span>
              <span>DETAIL</span>
              <span>BLOCK</span>
              <span>TRANSACTION</span>
            </div>
            {activity.map((item) => (
              <a
                className="activity-table-row"
                href={item.hash ? explorerTx(deployment, item.hash) : "#"}
                target="_blank"
                rel="noreferrer"
                key={`${item.kind}-${item.hash ?? "local"}-${item.logIndex ?? 0}-${item.block}`}
              >
                <span className={`event-pill event-${item.kind.toLowerCase()}`}>{item.kind}</span>
                <strong>{item.detail}</strong>
                <span>#{item.block}</span>
                <span>{item.hash ? shortenHash(item.hash) : "—"} ↗</span>
              </a>
            ))}
          </div>
        )}
      </article>
    </>
  );
}

export function LearnScreen({ onSwap }: { onSwap: () => void }) {
  return (
    <>
      <section className="screen-intro">
        <div>
          <span className="eyebrow">05 / LEARN</span>
          <h1>
            Outcome-linked
            <br />
            <em>LP-risk sharing.</em>
          </h1>
        </div>
        <p>Refundable collateral, a fixed observation window, and an insurance reserve.</p>
      </section>

      <section className="learn-steps">
        <article className="learn-step">
          <span>01</span>
          <div>
            <h2>Swap</h2>
            <p>Quote the trade. The quote is already net of any collateral at quote-time state.</p>
          </div>
          <b>→</b>
        </article>
        <article className="learn-step learn-step-active">
          <span>02</span>
          <div>
            <h2>Bond</h2>
            <p>If the trade is large enough and moves the price, a small part is held as refundable collateral.</p>
          </div>
          <b>→</b>
        </article>
        <article className="learn-step">
          <span>03</span>
          <div>
            <h2>Settle</h2>
            <p>Ten blocks later anyone can settle it. The refund goes to the recipient stored in the bond.</p>
          </div>
          <b>✓</b>
        </article>
      </section>

      <section className="learn-bottom">
        <article className="glass-card learn-example">
          <span className="eyebrow">HOW IT WORKS</span>
          <h2>
            Exact input.
            <br />
            <em>Collateral comes out of the output.</em>
          </h2>
          <p className="card-copy">
            You choose how much input to swap. Your input is passed to the pool in full. BondMeBro may temporarily
            withhold a small part of the <strong>output</strong> as refundable collateral, so what you receive is the
            realized output minus that amount. Your minimum-received figure is checked against that net amount.
          </p>
          <h2>
            Exact output.
            <br />
            <em>Collateral is extra input.</em>
          </h2>
          <p className="card-copy">
            You choose the exact output. BondMeBro may temporarily require <strong>additional input</strong> as
            refundable collateral, so your total spend is the pool input plus that amount. The maximum total input you
            approve already covers it.
          </p>
          <div className="example-list">
            <div>
              <span>Rate</span>
              <strong>0.25 bps per effective tick</strong>
            </div>
            <div>
              <span>Cap</span>
              <strong>100 bps (1%)</strong>
            </div>
            <div>
              <span>Maturity</span>
              <strong>opening block + 10</strong>
            </div>
          </div>
        </article>

        <article className="neo-card faq-card">
          <span className="eyebrow">WHAT THIS IS NOT</span>
          <h2>
            A defined checkpoint.
            <br />
            Not a guarantee.
          </h2>
          <p className="card-copy">
            The collateral rate is sized from <strong>effective block impact</strong>: the larger of this swap&apos;s own
            tick movement and the pool&apos;s movement since the start of the block it lands in. That depends on
            transaction ordering and is not knowable when you quote, so any pre-trade figure is an estimate.
          </p>
          <p className="card-copy">
            Settlement reads fixed cumulative-price checkpoints at opening block + 6, + 8 and + 10. Because those points
            are frozen, settling later gives the identical answer — there is no race and no reason to wait. Retained
            collateral goes to a per-pool insurance reserve; this version has no LP payout, no donation and no settler
            reward.
          </p>
          <p className="card-copy">
            Same-block splitting is <strong>mitigated, not eliminated</strong>. This measures later pool price, not
            intent: there is no oracle, no classifier and no claim of being MEV-proof or manipulation-proof.
          </p>
          <button type="button" className="primary-button" onClick={onSwap}>
            Go to swap <span>→</span>
          </button>
        </article>
      </section>
    </>
  );
}
