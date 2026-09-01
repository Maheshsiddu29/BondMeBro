"use client";

import { useEffect, useMemo, useState } from "react";
import { formatUnits, keccak256, toBytes, type Address, type Hex } from "viem";
import {
  useAccount,
  useBlockNumber,
  useConnect,
  useDisconnect,
  useReadContract,
  useSwitchChain,
} from "wagmi";
import { sepolia } from "wagmi/chains";

import { bondMeBroAbi } from "@/lib/abi";
import { deployment, explorerAddress, explorerTx, shortenHash } from "@/lib/config";

const ZERO_HASH = `0x${"0".repeat(64)}` as Hex;
const eventTopics = [
  keccak256(toBytes("BondOpened(bytes32,bytes32,address,address,uint128,int24,int24,uint48)")),
  keccak256(toBytes("BondSettled(bytes32,bytes32,address,address,uint128,uint128,uint128,int24,uint16)")),
  keccak256(toBytes("PoolConfigUpdated(bytes32,uint96,uint96,uint16,address)")),
  keccak256(toBytes("PotDonated(bytes32,address,uint256,address)")),
] as const;

type Theme = "light" | "dark";
type Screen = "overview" | "swap" | "bonds" | "pools" | "activity" | "learn";
type ActivityKind = "OPENED" | "SETTLED" | "CONFIG" | "DONATED";

type Activity = {
  kind: ActivityKind;
  block: string;
  hash?: string;
  detail: string;
};

type ConfigTuple = readonly [bigint, bigint, bigint];
type AccumulatorTuple = readonly [bigint, bigint, bigint];
type BoundsTuple = readonly [Hex, Hex];
type BondTuple = readonly [Address, bigint, bigint, bigint, Address, bigint, bigint, Hex];

function formatToken(value: unknown, decimals = 18, digits = 5) {
  if (typeof value !== "bigint") return "—";
  const formatted = formatUnits(value, decimals);
  const [whole, fraction = ""] = formatted.split(".");
  const trimmed = fraction.slice(0, digits).replace(/0+$/, "");
  return trimmed ? `${whole}.${trimmed}` : whole;
}

function formatInteger(value: unknown) {
  if (typeof value !== "bigint") return "—";
  return new Intl.NumberFormat("en-US").format(Number(value));
}

function formatAddress(value?: string) {
  if (!value) return "—";
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function formatBlock(value: unknown) {
  return typeof value === "bigint" ? value.toString() : "—";
}

function StatusDot({ live = false }: { live?: boolean }) {
  return <span className={`status-dot${live ? " status-dot-live" : ""}`} aria-hidden="true" />;
}

function Badge({ children, tone = "neutral" }: { children: React.ReactNode; tone?: "neutral" | "orange" | "green" | "muted" }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

function MetricCard({ label, value, detail, icon, accent = false }: { label: string; value: string; detail: string; icon: string; accent?: boolean }) {
  return (
    <article className={`metric-card ${accent ? "metric-card-accent" : ""}`}>
      <div className="metric-card-top"><span>{label}</span><span className="metric-icon">{icon}</span></div>
      <strong>{value}</strong>
      <span className="metric-detail">{detail}</span>
    </article>
  );
}

function SectionHeading({ eyebrow, title, copy }: { eyebrow: string; title: string; copy?: string }) {
  return (
    <div className="section-heading">
      <span className="eyebrow">{eyebrow}</span>
      <h2>{title}</h2>
      {copy && <p>{copy}</p>}
    </div>
  );
}

export function Dashboard() {
  const { address, chainId, isConnected } = useAccount();
  const { connect, connectors, isPending: isConnecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { data: blockNumber } = useBlockNumber({ watch: true });
  const [screen, setScreen] = useState<Screen>("overview");
  const [theme, setTheme] = useState<Theme>("light");
  const [swapMode, setSwapMode] = useState<"exactIn" | "exactOut">("exactIn");
  const [swapAmount, setSwapAmount] = useState("1,000");
  const [activity, setActivity] = useState<Activity[]>([]);
  const [activityError, setActivityError] = useState(false);

  const managerRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "poolManager",
    query: { refetchInterval: 15_000 },
  });
  const ownerRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "owner",
    query: { refetchInterval: 15_000 },
  });
  const configRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "getPoolConfig",
    args: [deployment.poolId],
    query: { refetchInterval: 15_000 },
  });
  const observationRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "observationBlocks",
    query: { refetchInterval: 30_000 },
  });
  const settlerFeeRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "settlerFeeBps",
    query: { refetchInterval: 30_000 },
  });
  const clampRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "maxAbsTickDelta",
    query: { refetchInterval: 30_000 },
  });
  const queueRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "queueLength",
    args: [deployment.poolId],
    query: { refetchInterval: 8_000 },
  });
  const boundsRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "queueBounds",
    args: [deployment.poolId],
    query: { refetchInterval: 8_000 },
  });
  const accumulatorRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "getAccumulator",
    args: [deployment.poolId],
    query: { refetchInterval: 8_000 },
  });
  const pot0Read = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "insurancePot",
    args: [deployment.poolId, deployment.currency0],
    query: { refetchInterval: 15_000 },
  });
  const pot1Read = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "insurancePot",
    args: [deployment.poolId, deployment.currency1],
    query: { refetchInterval: 15_000 },
  });

  const bounds = boundsRead.data as BoundsTuple | undefined;
  const headId = bounds?.[0];
  const headBondRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "getBond",
    args: [deployment.poolId, headId ?? ZERO_HASH],
    query: { enabled: Boolean(headId && headId !== ZERO_HASH), refetchInterval: 8_000 },
  });

  const config = configRead.data as ConfigTuple | undefined;
  const accumulator = accumulatorRead.data as AccumulatorTuple | undefined;
  const headBond = headBondRead.data as BondTuple | undefined;
  const observationValue = (observationRead as unknown as { data?: unknown }).data;
  const settlerFeeValue = (settlerFeeRead as unknown as { data?: unknown }).data;
  const clampValue = (clampRead as unknown as { data?: unknown }).data;
  const observationBlocks = typeof observationValue === "bigint" ? observationValue : 50n;
  const settlerFeeBps = typeof settlerFeeValue === "bigint" ? settlerFeeValue : 500n;
  const clampTicks = typeof clampValue === "bigint" ? clampValue : 506n;
  const queueLength = typeof queueRead.data === "bigint" ? queueRead.data : 0n;
  const pot0 = typeof pot0Read.data === "bigint" ? pot0Read.data : 0n;
  const pot1 = typeof pot1Read.data === "bigint" ? pot1Read.data : 0n;
  const totalPot = pot0 + pot1;
  const poolConnected = managerRead.data?.toLowerCase() === deployment.poolManager.toLowerCase();
  const rpcOnline = !managerRead.isError && Boolean(managerRead.data);
  const networkCorrect = chainId === sepolia.id;
  const bondingEnabled = Boolean(config && config[0] > 0n && config[1] > 0n && config[2] > 0n);
  const maturityBlock = headBond ? headBond[1] + observationBlocks : undefined;
  const headCurrency = headBond && headBond[4].toLowerCase() === deployment.currency0.toLowerCase() ? "ETH" : "WETH";
  const maturityProgress = useMemo(() => {
    if (!headBond || blockNumber === undefined || maturityBlock === undefined) return 0;
    if (blockNumber >= maturityBlock) return 100;
    if (blockNumber <= headBond[1]) return 0;
    return Math.round((Number(blockNumber - headBond[1]) / Number(maturityBlock - headBond[1])) * 100);
  }, [blockNumber, headBond, maturityBlock]);

  useEffect(() => {
    const saved = window.localStorage.getItem("bondmebro-theme") as Theme | null;
    if (saved === "light" || saved === "dark") setTheme(saved);
  }, []);

  useEffect(() => {
    window.localStorage.setItem("bondmebro-theme", theme);
  }, [theme]);

  useEffect(() => {
    let cancelled = false;
    async function loadActivity() {
      if (!managerRead.data) return;
      try {
        const blockResponse = await fetch("/api/rpc", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method: "eth_blockNumber", params: [] }),
        });
        if (!blockResponse.ok) throw new Error("RPC unavailable");
        const blockPayload = (await blockResponse.json()) as { result?: string };
        if (!blockPayload.result) throw new Error("No block number");
        const latest = BigInt(blockPayload.result);
        const fromBlock = latest > 5_000n ? latest - 5_000n : 0n;
        const responses = await Promise.all(
          eventTopics.map((topic, index) =>
            fetch("/api/rpc", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                jsonrpc: "2.0",
                id: Date.now() + index,
                method: "eth_getLogs",
                params: [{ address: deployment.hook, topics: [topic], fromBlock: `0x${fromBlock.toString(16)}`, toBlock: `0x${latest.toString(16)}` }],
              }),
            }).then((response) => response.json()),
          ),
        );
        const nextActivity: Activity[] = [];
        const kinds: ActivityKind[] = ["OPENED", "SETTLED", "CONFIG", "DONATED"];
        const details = [
          "Bond opened and added to the FIFO queue",
          "Bond settled against the pool-local TWA",
          "Pool custody thresholds updated",
          "Insurance pot donated to in-range LPs",
        ];
        responses.forEach((response, index) => {
          const logs = Array.isArray(response.result) ? response.result : [];
          logs.slice(-6).forEach((log: { blockNumber?: string; transactionHash?: string }) => {
            nextActivity.push({
              kind: kinds[index],
              block: log.blockNumber ? BigInt(log.blockNumber).toString() : "—",
              hash: log.transactionHash,
              detail: details[index],
            });
          });
        });
        nextActivity.sort((a, b) => Number(BigInt(b.block) - BigInt(a.block)));
        if (!cancelled) {
          setActivity(nextActivity.slice(0, 8));
          setActivityError(false);
        }
      } catch {
        if (!cancelled) setActivityError(true);
      }
    }
    void loadActivity();
    const timer = window.setInterval(loadActivity, 30_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [managerRead.data]);

  function goTo(next: Screen) {
    setScreen(next);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function connectWallet() {
    const connector = connectors[0];
    if (connector) connect({ connector });
  }

  const navItems: { id: Screen; label: string; icon: string }[] = [
    { id: "overview", label: "Overview", icon: "⌂" },
    { id: "swap", label: "Swap", icon: "↕" },
    { id: "bonds", label: "My bonds", icon: "◈" },
    { id: "pools", label: "Pools", icon: "◫" },
    { id: "activity", label: "Activity", icon: "≋" },
    { id: "learn", label: "Learn", icon: "?" },
  ];

  return (
    <div className={`app-shell theme-${theme}`}>
      <aside className="sidebar">
        <div className="sidebar-brand">
          <div className="brand-symbol">B</div>
          <div><div className="brand-name">BondMeBro</div><div className="brand-subtitle">ACCOUNTABLE LIQUIDITY</div></div>
        </div>

        <div className="sidebar-section-label">APPLICATION</div>
        <nav className="sidebar-nav" aria-label="Application navigation">
          {navItems.map((item) => (
            <button key={item.id} className={`sidebar-nav-item ${screen === item.id ? "sidebar-nav-active" : ""}`} onClick={() => goTo(item.id)} type="button">
              <span className="nav-icon">{item.icon}</span><span>{item.label}</span>{screen === item.id && <span className="nav-active-mark" />}
            </button>
          ))}
        </nav>

        <div className="sidebar-spacer" />
        <div className="sidebar-section-label">NETWORK</div>
        <div className="network-card"><StatusDot live={rpcOnline} /><div><strong>Sepolia</strong><span>Chain {deployment.chainId}</span></div><span className="network-check">{rpcOnline ? "✓" : "!"}</span></div>

        <div className="sidebar-tools">
          <button type="button" onClick={() => setTheme(theme === "light" ? "dark" : "light")}><span>{theme === "light" ? "☼" : "☾"}</span>{theme === "light" ? "Light mode" : "Dark mode"}<b>{theme === "light" ? "ON" : "ON"}</b></button>
          <a href={explorerAddress(deployment.hook)} target="_blank" rel="noreferrer"><span>↗</span>Contract explorer</a>
        </div>
        <div className="sidebar-foot"><span>TESTNET BUILD</span><span>01 / 05</span></div>
      </aside>

      <div className="main-column">
        <header className="topbar">
          <div className="mobile-brand"><div className="brand-symbol">B</div><span>BondMeBro</span></div>
          <div className="topbar-location"><span>APP</span><i>/</i><strong>{navItems.find((item) => item.id === screen)?.label}</strong></div>
          <div className="topbar-actions">
            <div className={`rpc-chip ${rpcOnline ? "" : "rpc-chip-offline"}`}><StatusDot live={rpcOnline} />{rpcOnline ? "Live data" : "RPC offline"}</div>
            {!isConnected ? (
              <button className="wallet-button primary-button" type="button" onClick={connectWallet} disabled={isConnecting}>{isConnecting ? "Connecting…" : "Connect wallet"}</button>
            ) : !networkCorrect ? (
              <button className="wallet-button primary-button" type="button" onClick={() => switchChain({ chainId: sepolia.id })}>Switch to Sepolia</button>
            ) : (
              <button className="wallet-button" type="button" onClick={() => disconnect()}><StatusDot live />{formatAddress(address)}</button>
            )}
          </div>
        </header>

        <main className="page-content">
          {screen === "overview" && (
            <>
              <section className="welcome-grid">
                <div className="welcome-copy">
                  <span className="eyebrow">GOOD AFTERNOON / {deployment.networkName.toUpperCase()}</span>
                  <h1>Trade now.<br /><em>Prove the impact later.</em></h1>
                  <p>BondMeBro temporarily holds a small bond from qualifying swaps. At maturity, the outcome is measured and the bond is refunded or retained.</p>
                  <div className="welcome-actions"><button type="button" className="primary-button large-button" onClick={() => goTo("swap")}>Launch swap <span>↗</span></button><button type="button" className="text-button" onClick={() => goTo("learn")}>How it works <span>→</span></button></div>
                </div>
                <div className="hero-visual">
                  <div className="hero-orb"><span>01</span><div className="orb-ring orb-ring-one" /><div className="orb-ring orb-ring-two" /><div className="orb-dot" /></div>
                  <div className="floating-card floating-swap"><div className="floating-card-label">SWAP PREVIEW <span>↗</span></div><div className="floating-token-row"><div className="token-bubble token-orange">$</div><div><strong>1,000 USDC</strong><span>Exact input</span></div><b>→</b></div><div className="floating-result"><span>EST. BOND</span><strong>1.00 USDC</strong></div></div>
                  <div className="floating-card floating-status"><div className="floating-card-label">BOND STATUS</div><div className="status-line"><StatusDot live /><strong>Active</strong><span>matures after checkpoint</span></div></div>
                </div>
              </section>

              <section className="metric-grid">
                <MetricCard label="ACTIVE BONDED VALUE" value={headBond ? `${formatToken(headBond[6])} ${headCurrency}` : "0.00 ETH"} detail={headBond ? "current queue head" : "no active bonds"} icon="◈" accent />
                <MetricCard label="OPEN BONDS" value={formatInteger(queueLength)} detail="FIFO queue length" icon="◌" />
                <MetricCard label="INSURANCE POT" value={`${formatToken(totalPot)} ETH`} detail="ETH + WETH / testnet" icon="♢" />
                <MetricCard label="POOL STATUS" value={poolConnected ? "BOUND" : "CHECKING"} detail={bondingEnabled ? "bonding enabled" : "configuration pending"} icon="⌁" />
              </section>

              <section className="content-grid overview-grid">
                <article className="neo-card active-bonds-card">
                  <div className="card-heading"><div><span className="eyebrow">01 / PORTFOLIO</span><h2>Active bonds</h2></div><button className="card-link" type="button" onClick={() => goTo("bonds")}>View all <span>→</span></button></div>
                  {headBond ? <div className="bond-table"><div className="bond-table-head"><span>POOL</span><span>BOND</span><span>MATURITY</span><span>STATUS</span></div><div className="bond-table-row"><div className="pool-cell"><div className="pair-icon"><span>Ξ</span><span>W</span></div><div><strong>ETH / WETH</strong><small>{shortenHash(headId ?? ZERO_HASH, 7, 5)}</small></div></div><strong className="orange-text">{formatToken(headBond[6])} {headCurrency}</strong><div><strong>Block {formatBlock(maturityBlock)}</strong><small>opened {formatBlock(headBond[1])}</small></div><Badge tone={maturityProgress >= 100 ? "orange" : "neutral"}>{maturityProgress >= 100 ? "READY" : "ACTIVE"}</Badge></div></div> : <div className="empty-card"><div className="empty-icon">◈</div><strong>No active bonds</strong><span>Qualifying swaps will appear here.</span><button type="button" className="text-button" onClick={() => goTo("swap")}>Preview a swap →</button></div>}
                  <div className="card-footer"><span>{queueLength > 0n ? `${formatInteger(queueLength)} bond${queueLength === 1n ? "" : "s"} in queue` : "Queue is clear"}</span><span className="footer-status"><StatusDot live={rpcOnline} /> synced</span></div>
                </article>
                <article className="glass-card portfolio-card">
                  <div className="card-heading"><div><span className="eyebrow">02 / PROTOCOL</span><h2>Portfolio summary</h2></div><Badge tone="green"><StatusDot live /> TESTNET</Badge></div>
                  <div className="portfolio-total"><span>INSURANCE POT / TOTAL</span><strong>{formatToken(totalPot)} <small>ETH</small></strong></div>
                  <div className="stacked-bar"><span style={{ width: totalPot > 0n ? "58%" : "4%" }} /><span style={{ width: pot0 > 0n ? "24%" : "3%" }} /></div>
                  <div className="legend-row"><span><i className="dot-orange" />WETH pot <b>{formatToken(pot1)} WETH</b></span><span><i className="dot-warm" />ETH pot <b>{formatToken(pot0)} ETH</b></span></div>
                  <div className="summary-list"><div><span>Bond rate</span><strong>{config?.[2]?.toString() ?? "—"} bps</strong></div><div><span>Observation</span><strong>{observationBlocks.toString()} blocks</strong></div><div><span>Settler reward</span><strong>{settlerFeeBps.toString()} bps</strong></div></div>
                  <button type="button" className="outline-button full-button" onClick={() => goTo("pools")}>View pool analytics <span>→</span></button>
                </article>
              </section>

              <section className="process-strip"><div><span className="eyebrow">THE MECHANISM</span><h2>Swap <i>→</i> Bond <i>→</i> Settle</h2></div><p>Temporary collateral makes price impact accountable without an external classifier.</p><button type="button" className="round-arrow" onClick={() => goTo("learn")}>↗</button></section>
              <ActivityPreview activity={activity} activityError={activityError} onViewAll={() => goTo("activity")} />
            </>
          )}

          {screen === "swap" && <SwapScreen isConnected={isConnected} swapMode={swapMode} setSwapMode={setSwapMode} swapAmount={swapAmount} setSwapAmount={setSwapAmount} onConnect={connectWallet} onLearn={() => goTo("learn")} />}
          {screen === "bonds" && <BondsScreen headBond={headBond} headId={headId} queueLength={queueLength} maturityBlock={maturityBlock} maturityProgress={maturityProgress} currentBlock={blockNumber} headCurrency={headCurrency} onSwap={() => goTo("swap")} />}
          {screen === "pools" && <PoolsScreen config={config} accumulator={accumulator} clampTicks={clampTicks} observationBlocks={observationBlocks} settlerFeeBps={settlerFeeBps} queueLength={queueLength} pot0={pot0} pot1={pot1} poolConnected={poolConnected} owner={ownerRead.data} />}
          {screen === "activity" && <ActivityScreen activity={activity} activityError={activityError} />}
          {screen === "learn" && <LearnScreen onSwap={() => goTo("swap")} />}
        </main>
        <footer className="page-footer"><span>BondMeBro / outcome-linked LP insurance</span><span>READ-ONLY TESTNET BUILD / SEPOLIA</span></footer>
      </div>

      <nav className="mobile-nav" aria-label="Mobile navigation">{navItems.slice(0, 5).map((item) => <button key={item.id} type="button" className={screen === item.id ? "mobile-nav-active" : ""} onClick={() => goTo(item.id)}><span>{item.icon}</span>{item.label}</button>)}</nav>
    </div>
  );
}

function ActivityPreview({ activity, activityError, onViewAll }: { activity: Activity[]; activityError: boolean; onViewAll: () => void }) {
  return (
    <section className="activity-preview"><div className="card-heading"><div><span className="eyebrow">03 / ACTIVITY</span><h2>Recent activity</h2></div><button type="button" className="card-link" onClick={onViewAll}>View activity <span>→</span></button></div>{activityError ? <div className="inline-empty">Event history is unavailable. Core reads remain visible.</div> : activity.length === 0 ? <div className="inline-empty">No protocol events in the recent block window.</div> : <div className="activity-rows">{activity.slice(0, 4).map((item, index) => <a className="activity-row" href={item.hash ? explorerTx(item.hash) : "#"} target="_blank" rel="noreferrer" key={`${item.kind}-${item.block}-${index}`}><span className={`event-icon event-${item.kind.toLowerCase()}`}>{item.kind === "OPENED" ? "◈" : item.kind === "SETTLED" ? "✓" : item.kind === "DONATED" ? "♢" : "⌁"}</span><div><strong>{item.detail}</strong><small>Block {item.block}</small></div><span className="activity-row-hash">{item.hash ? shortenHash(item.hash) : "—"} ↗</span></a>)}</div>}</section>
  );
}

function SwapScreen({ isConnected, swapMode, setSwapMode, swapAmount, setSwapAmount, onConnect, onLearn }: { isConnected: boolean; swapMode: "exactIn" | "exactOut"; setSwapMode: (mode: "exactIn" | "exactOut") => void; swapAmount: string; setSwapAmount: (value: string) => void; onConnect: () => void; onLearn: () => void }) {
  return (
    <>
      <section className="screen-intro"><div><span className="eyebrow">01 / TRADE WITH CONTEXT</span><h1>Make a swap.<br /><em>See the bond first.</em></h1></div><p>The bond is temporary collateral carved from qualifying input. It is not an extra fee, and the settlement outcome is decided at the protocol checkpoint.</p></section>
      <section className="swap-layout"><article className="neo-card swap-card"><div className="swap-card-top"><div className="segmented-control"><button type="button" className={swapMode === "exactIn" ? "segment-active" : ""} onClick={() => setSwapMode("exactIn")}>Exact in</button><button type="button" className={swapMode === "exactOut" ? "segment-active" : ""} onClick={() => setSwapMode("exactOut")}>Exact out</button></div><Badge tone="muted">PREVIEW</Badge></div><div className="swap-field"><div className="field-label"><span>You pay</span><span>Balance —</span></div><div className="amount-line"><input aria-label="Swap amount" value={swapAmount} onChange={(event) => setSwapAmount(event.target.value)} inputMode="decimal" /><button type="button" className="token-select"><span className="token-bubble token-orange">$</span>USDC <b>⌄</b></button></div></div><button type="button" className="direction-button" aria-label="Switch swap direction">↕</button><div className="swap-field"><div className="field-label"><span>You receive</span><span>Estimated output</span></div><div className="amount-line"><input aria-label="Estimated output" value="—" readOnly /><button type="button" className="token-select"><span className="token-bubble token-purple">W</span>WETH <b>⌄</b></button></div></div><div className="swap-settings"><span>Slippage <b>0.50%</b></span><span>Pool <b>ETH / WETH</b></span><span>Route <b>Single hop</b></span></div><button type="button" className="primary-button large-button full-button" onClick={isConnected ? onLearn : onConnect}>{isConnected ? "Review swap" : "Connect wallet"} <span>→</span></button><span className="readonly-note">Transaction wiring uses the audited Universal Router path.</span></article><aside className="swap-context"><article className="glass-card bond-preview-card"><div className="card-heading"><div><span className="eyebrow">BOND PREVIEW</span><h2>Accountability, up front.</h2></div><span className="preview-lock">⌁</span></div><div className="preview-amount"><span>ESTIMATED BOND</span><strong>— <small>USDC</small></strong></div><div className="preview-rows"><div><span>Pool input after bond</span><strong>—</strong></div><div><span>Bond rate</span><strong>25 bps</strong></div><div><span>Maturity checkpoint</span><strong>50 blocks</strong></div><div><span>Refund recipient</span><strong>{isConnected ? "Connected wallet" : "Connect wallet"}</strong></div></div><div className="risk-callout"><span>ⓘ</span><p>This is temporary collateral, not a guaranteed refund. Settlement is permissionless and uses the protocol-defined outcome rule.</p></div></article><button type="button" className="learn-link" onClick={onLearn}>Why is there a bond? <span>→</span></button></aside></section>
    </>
  );
}

function BondsScreen({ headBond, headId, queueLength, maturityBlock, maturityProgress, currentBlock, headCurrency, onSwap }: { headBond?: BondTuple; headId?: Hex; queueLength: bigint; maturityBlock?: bigint; maturityProgress: number; currentBlock?: bigint; headCurrency: string; onSwap: () => void }) {
  return (
    <><section className="screen-intro"><div><span className="eyebrow">02 / PORTFOLIO</span><h1>My bonds<br /><em>in one view.</em></h1></div><p>Track active and matured collateral. Any account may settle a matured bond; the refund is always sent to its encoded recipient.</p></section><section className="bond-summary-grid"><MetricCard label="OPEN BONDS" value={formatInteger(queueLength)} detail="across selected pool" icon="◈" accent /><MetricCard label="READY TO SETTLE" value={headBond && maturityProgress >= 100 ? "1" : "0"} detail="maturity checkpoint" icon="✓" /><MetricCard label="POOL" value="ETH / WETH" detail="0.30% fee tier" icon="◫" /></section><article className="neo-card detail-card"><div className="card-heading"><div><span className="eyebrow">BOND QUEUE / FIFO HEAD</span><h2>{headBond ? "Active bond" : "No bonds yet"}</h2></div><Badge tone={headBond && maturityProgress >= 100 ? "orange" : "neutral"}>{headBond ? maturityProgress >= 100 ? "READY" : "ACTIVE" : "CLEAR"}</Badge></div>{headBond ? <><div className="detail-hero"><div><span className="eyebrow">BOND AMOUNT</span><strong>{formatToken(headBond[6])} <small>{headCurrency}</small></strong></div><div className="detail-id"><span>BOND ID</span><b>{shortenHash(headId ?? ZERO_HASH, 10, 8)}</b></div></div><div className="timeline"><div className="timeline-line"><span style={{ width: `${maturityProgress}%` }} /></div><div className="timeline-step timeline-done"><i>✓</i><span>Swap submitted</span><b>Block {formatBlock(headBond[1])}</b></div><div className={maturityProgress >= 100 ? "timeline-step timeline-done" : "timeline-step"}><i>{maturityProgress >= 100 ? "✓" : "2"}</i><span>Maturity checkpoint</span><b>Block {formatBlock(maturityBlock)}</b></div><div className="timeline-step"><i>3</i><span>Settlement</span><b>{maturityProgress >= 100 ? "Ready now" : `${maturityProgress}% complete`}</b></div></div><div className="detail-info-grid"><div><span>REFUND RECIPIENT</span><strong>{formatAddress(headBond[0])}</strong></div><div><span>OPENED</span><strong>{formatBlock(headBond[1])}</strong></div><div><span>CURRENT BLOCK</span><strong>{formatBlock(currentBlock)}</strong></div><div><span>IMPACT TICKS</span><strong>{(headBond[3] - headBond[2]).toString()}</strong></div></div><div className="detail-actions"><button type="button" className="primary-button large-button" disabled={maturityProgress < 100}>Settle bond <span>→</span></button><span>Settlement transactions will be enabled in the next frontend phase.</span></div></> : <div className="empty-card large-empty"><div className="empty-icon">◈</div><strong>Your bond portfolio is empty</strong><span>Use the swap preview to see how qualifying input becomes temporary collateral.</span><button type="button" className="primary-button" onClick={onSwap}>Preview a swap →</button></div>}</article></>
  );
}

function PoolsScreen({ config, accumulator, clampTicks, observationBlocks, settlerFeeBps, queueLength, pot0, pot1, poolConnected, owner }: { config?: ConfigTuple; accumulator?: AccumulatorTuple; clampTicks: bigint; observationBlocks: bigint; settlerFeeBps: bigint; queueLength: bigint; pot0: bigint; pot1: bigint; poolConnected: boolean; owner?: Address }) {
  return (
    <><section className="screen-intro"><div><span className="eyebrow">03 / POOL ANALYTICS</span><h1>Pool health.<br /><em>Clearly stated.</em></h1></div><p>Protocol-level state for the selected Uniswap v4 pool. Values below come from the deployed hook and are labeled as testnet data.</p></section><section className="content-grid pool-analytics-grid"><article className="neo-card analytics-card"><div className="card-heading"><div><span className="eyebrow">SELECTED POOL</span><h2>ETH / WETH</h2></div><Badge tone={poolConnected ? "green" : "neutral"}><StatusDot live={poolConnected} /> {poolConnected ? "HOOK ACTIVE" : "CHECKING"}</Badge></div><div className="pool-identity-large"><div className="large-pair-icon"><span>Ξ</span><span>W</span></div><div><strong>ETH / WETH</strong><span>PoolManager bound · Sepolia</span></div></div><div className="pool-stat-grid"><div><span>FEE TIER</span><strong>0.30%</strong></div><div><span>TICK SPACING</span><strong>60</strong></div><div><span>QUEUE</span><strong>{formatInteger(queueLength)}</strong></div><div><span>LAST TICK</span><strong>{accumulator?.[0]?.toString() ?? "—"}</strong></div></div><a className="outline-button full-button button-as-link" href={explorerAddress(deployment.hook)} target="_blank" rel="noreferrer">View hook contract ↗</a></article><article className="glass-card configuration-card"><div className="card-heading"><div><span className="eyebrow">BOND CONFIGURATION</span><h2>Pool parameters</h2></div><Badge tone={config && config[2] > 0n ? "orange" : "muted"}>{config && config[2] > 0n ? "ENABLED" : "DISABLED"}</Badge></div><div className="config-list"><div><span>Bond BPS</span><strong>{config?.[2]?.toString() ?? "—"} <small>basis points</small></strong></div><div><span>Minimum / currency 0</span><strong>{formatToken(config?.[0])} <small>ETH</small></strong></div><div><span>Minimum / currency 1</span><strong>{formatToken(config?.[1])} <small>WETH</small></strong></div><div><span>Observation window</span><strong>{observationBlocks.toString()} <small>blocks</small></strong></div><div><span>Settler reward</span><strong>{settlerFeeBps.toString()} <small>bps of slash</small></strong></div></div><div className="owner-row"><span>OWNER</span><a href={owner ? explorerAddress(owner) : "#"} target="_blank" rel="noreferrer">{formatAddress(owner)} ↗</a></div></article></section><section className="content-grid pool-analytics-grid analytics-lower"><article className="neo-card"><SectionHeading eyebrow="ACCUMULATOR" title="Pool-local reference" copy="The accumulator updates once per block and clamps large movements before they become settlement reference data." /><div className="tick-display"><strong>{accumulator?.[0]?.toString() ?? "—"}</strong><span>LAST RECORDED TICK</span></div><div className="mini-stats"><div><span>LAST UPDATE</span><strong>{accumulator?.[1]?.toString() ?? "—"}</strong></div><div><span>CLAMP</span><strong>{clampTicks.toString()} ticks</strong></div><div><span>CUMULATIVE</span><strong>{accumulator ? shortenHash(`0x${accumulator[2].toString(16)}`, 8, 5) : "—"}</strong></div></div></article><article className="glass-card"><SectionHeading eyebrow="LP COVERAGE" title="Insurance balances" /><div className="coverage-balance"><div><span>ETH POT</span><strong>{formatToken(pot0)} ETH</strong></div><div><span>WETH POT</span><strong>{formatToken(pot1)} WETH</strong></div></div><div className="risk-callout"><span>ⓘ</span><p>Donations are permissionless and reward in-range LPs at donation time.</p></div></article></section></>
  );
}

function ActivityScreen({ activity, activityError }: { activity: Activity[]; activityError: boolean }) {
  return <><section className="screen-intro"><div><span className="eyebrow">04 / EVENT STREAM</span><h1>Everything<br /><em>on record.</em></h1></div><p>A unified view of BondMeBro events from the recent block window. Select any transaction to inspect it on the network explorer.</p></section><article className="neo-card full-activity-card"><div className="card-heading"><div><span className="eyebrow">LAST 5,000 BLOCKS</span><h2>Protocol activity</h2></div><Badge tone={activityError ? "neutral" : "green"}><StatusDot live={!activityError} /> {activityError ? "UNAVAILABLE" : "SYNCED"}</Badge></div>{activityError ? <div className="inline-empty">Event history is unavailable. Check the server-side RPC configuration.</div> : activity.length === 0 ? <div className="empty-card large-empty"><div className="empty-icon">≋</div><strong>No events in this window</strong><span>Bond openings, settlements, configuration, and donations will appear here.</span></div> : <div className="activity-table"><div className="activity-table-head"><span>EVENT</span><span>DETAIL</span><span>BLOCK</span><span>TRANSACTION</span></div>{activity.map((item, index) => <a className="activity-table-row" href={item.hash ? explorerTx(item.hash) : "#"} target="_blank" rel="noreferrer" key={`${item.kind}-${item.block}-${index}`}><span className={`event-pill event-${item.kind.toLowerCase()}`}>{item.kind}</span><strong>{item.detail}</strong><span>#{item.block}</span><span>{item.hash ? shortenHash(item.hash) : "—"} ↗</span></a>)}</div>}</article></>;
}

function LearnScreen({ onSwap }: { onSwap: () => void }) {
  return <><section className="screen-intro"><div><span className="eyebrow">05 / LEARN</span><h1>Accountable<br /><em>liquidity.</em></h1></div><p>BondMeBro is outcome-linked LP insurance. It does not label intent; it waits for the pool&apos;s price outcome and settles temporary collateral accordingly.</p></section><section className="learn-steps"><article className="learn-step"><span>01</span><div><h2>Swap</h2><p>Submit a normal single-hop swap. If the requested input crosses the pool&apos;s threshold, a bond preview appears before confirmation.</p></div><b>→</b></article><article className="learn-step learn-step-active"><span>02</span><div><h2>Bond</h2><p>A small portion of the input is held as temporary collateral. The trader chooses the maximum bond they accept.</p></div><b>→</b></article><article className="learn-step"><span>03</span><div><h2>Settle</h2><p>At the maturity checkpoint, anyone can settle. Reverted impact refunds the bond; persistent impact supports the LP insurance pot.</p></div><b>✓</b></article></section><section className="learn-bottom"><article className="glass-card learn-example"><span className="eyebrow">SIMPLE EXAMPLE</span><h2>1,000 units in.<br /><em>999 units to the pool.</em></h2><div className="example-list"><div><span>Gross input</span><strong>1,000</strong></div><div><span>Temporary bond</span><strong>1</strong></div><div><span>Effective pool input</span><strong>999</strong></div></div></article><article className="neo-card faq-card"><span className="eyebrow">FAQ / RISK</span><h2>Not a guarantee.<br />A defined checkpoint.</h2><p>Settlement uses the configured maturity rule and pool-local observation data. Market drift and unrelated flow remain economic limitations.</p><button type="button" className="primary-button" onClick={onSwap}>Preview a swap <span>→</span></button></article></section></>;
}
