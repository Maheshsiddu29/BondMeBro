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

type Activity = {
  kind: "OPENED" | "SETTLED" | "CONFIG" | "DONATED";
  block: string;
  hash?: string;
  detail: string;
};

type BondTuple = readonly [
  Address,
  bigint,
  bigint,
  bigint,
  Address,
  bigint,
  bigint,
  Hex,
];

type ConfigTuple = readonly [bigint, bigint, bigint];
type AccumulatorTuple = readonly [bigint, bigint, bigint];

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
  if (typeof value !== "bigint") return "—";
  return value.toString();
}

function relativeBlock(openBlock: bigint | undefined, currentBlock?: bigint) {
  if (openBlock === undefined || currentBlock === undefined || currentBlock < openBlock) return "—";
  return `${formatInteger(currentBlock - openBlock)} blocks ago`;
}

function Metric({ label, value, detail, accent = false }: { label: string; value: string; detail: string; accent?: boolean }) {
  return (
    <article className={`metric-card${accent ? " metric-card-accent" : ""}`}>
      <div className="metric-label">{label}</div>
      <div className="metric-value">{value}</div>
      <div className="metric-detail">{detail}</div>
    </article>
  );
}

function StatusDot({ live }: { live: boolean }) {
  return <span className={`status-dot${live ? " status-dot-live" : ""}`} aria-hidden="true" />;
}

export function Dashboard() {
  const { address, chainId, isConnected } = useAccount();
  const { connect, connectors, isPending: isConnecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { data: blockNumber } = useBlockNumber({ watch: true });
  const [referenceOpen, setReferenceOpen] = useState(false);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
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

  const bounds = boundsRead.data as readonly [Hex, Hex] | undefined;
  const headId = bounds?.[0];
  const headBondRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "getBond",
    args: [deployment.poolId, headId ?? ZERO_HASH],
    query: {
      enabled: Boolean(headId && headId !== ZERO_HASH),
      refetchInterval: 8_000,
    },
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
  const poolConnected = managerRead.data?.toLowerCase() === deployment.poolManager.toLowerCase();
  const rpcOnline = !managerRead.isError && Boolean(managerRead.data);
  const networkCorrect = chainId === sepolia.id;
  const bondingEnabled = Boolean(config && config[0] > 0n && config[1] > 0n && config[2] > 0n);
  const maturityBlock = headBond ? headBond[1] + observationBlocks : undefined;
  const maturityProgress = useMemo(() => {
    if (!headBond || blockNumber === undefined) return 0;
    const start = headBond[1];
    const end = maturityBlock ?? start;
    if (end <= start || blockNumber >= end) return 100;
    if (blockNumber <= start) return 0;
    return Math.round((Number(blockNumber - start) / Number(end - start)) * 100);
  }, [blockNumber, headBond, maturityBlock]);

  useEffect(() => {
    let cancelled = false;
    async function loadActivity() {
      if (!managerRead.data) return;
      try {
        const rpcResponse = await fetch("/api/rpc", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: Date.now(),
            method: "eth_blockNumber",
            params: [],
          }),
        });
        if (!rpcResponse.ok) throw new Error("RPC unavailable");
        const blockPayload = (await rpcResponse.json()) as { result?: string };
        if (!blockPayload.result) throw new Error("No block number");
        const latest = BigInt(blockPayload.result);
        const fromBlock = latest > 5_000n ? latest - 5_000n : 0n;
        const eventRequests = eventTopics.map((topic) =>
          fetch("/api/rpc", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              jsonrpc: "2.0",
              id: Date.now() + Math.random(),
              method: "eth_getLogs",
              params: [
                {
                  address: deployment.hook,
                  topics: [topic],
                  fromBlock: `0x${fromBlock.toString(16)}`,
                  toBlock: `0x${latest.toString(16)}`,
                },
              ],
            }),
          }).then((response) => response.json()),
        );
        const responses = await Promise.all(eventRequests);
        const nextActivity: Activity[] = [];
        responses.forEach((response, index) => {
          const logs = Array.isArray(response.result) ? response.result : [];
          logs.slice(-6).forEach((log: { blockNumber?: string; transactionHash?: string }) => {
            const kinds: Activity["kind"][] = ["OPENED", "SETTLED", "CONFIG", "DONATED"];
            const details = [
              "Bond opened and added to the FIFO queue",
              "Bond settled against the pool-local TWA",
              "Pool custody thresholds updated",
              "Insurance pot donated to in-range LPs",
            ];
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

  function connectWallet() {
    const connector = connectors[0];
    if (connector) connect({ connector });
  }

  return (
    <div className="app-shell">
      <aside className={`sidebar${mobileNavOpen ? " sidebar-open" : ""}`}>
        <div className="brand-lockup">
          <div className="brand-mark">B</div>
          <div>
            <div className="brand-name">BOND<span>ME</span>BRO</div>
            <div className="brand-caption">LP INSURANCE PROTOCOL</div>
          </div>
        </div>

        <div className="sidebar-network">
          <StatusDot live={rpcOnline} />
          <span>{deployment.networkName.toUpperCase()}</span>
          <span className="network-id">#{deployment.chainId}</span>
        </div>

        <nav className="side-nav" aria-label="Dashboard navigation">
          <a className="side-nav-item side-nav-active" href="#overview" onClick={() => setMobileNavOpen(false)}>
            <span className="nav-number">01</span>
            <span>Overview</span>
            <span className="nav-arrow">↗</span>
          </a>
          <a className="side-nav-item" href="#queue" onClick={() => setMobileNavOpen(false)}>
            <span className="nav-number">02</span>
            <span>Bond queue</span>
          </a>
          <a className="side-nav-item" href="#insurance" onClick={() => setMobileNavOpen(false)}>
            <span className="nav-number">03</span>
            <span>Insurance pot</span>
          </a>
          <a className="side-nav-item" href="#activity" onClick={() => setMobileNavOpen(false)}>
            <span className="nav-number">04</span>
            <span>Activity</span>
          </a>
        </nav>

        <div className="sidebar-spacer" />

        <div className="reference-card">
          <div className="reference-kicker">VISUAL REFERENCE</div>
          <div className="reference-title">ChainGPT</div>
          <div className="reference-copy">Neon editorial energy, adapted for BondMeBro monitoring.</div>
          <button className="reference-toggle" type="button" onClick={() => setReferenceOpen((current) => !current)}>
            {referenceOpen ? "Hide sample" : "Show sample"}
            <span>↗</span>
          </button>
          {referenceOpen && (
            <div className="reference-embed">
              <iframe
                src="https://www.chaingpt.org/"
                title="ChainGPT visual reference"
                loading="lazy"
                referrerPolicy="no-referrer"
              />
              <a href="https://www.chaingpt.org/" target="_blank" rel="noreferrer">
                Open ChainGPT ↗
              </a>
            </div>
          )}
        </div>

        <div className="sidebar-footer">
          <span>UHI10 / SEPOLIA</span>
          <a href={explorerAddress(deployment.hook)} target="_blank" rel="noreferrer">EXPLORER ↗</a>
        </div>
      </aside>

      <section className="content-area">
        <header className="topbar">
          <button className="mobile-menu" type="button" aria-label="Toggle navigation" onClick={() => setMobileNavOpen((open) => !open)}>
            <span />
            <span />
          </button>
          <div className="breadcrumb"><span>APP</span><span>/</span><strong>POOL MONITOR</strong></div>
          <div className="topbar-actions">
            <div className={`connection-state${rpcOnline ? "" : " connection-state-offline"}`}>
              <StatusDot live={rpcOnline} />
              {rpcOnline ? "LIVE RPC" : "RPC OFFLINE"}
            </div>
            {!isConnected ? (
              <button className="connect-button" type="button" onClick={connectWallet} disabled={isConnecting}>
                {isConnecting ? "CONNECTING…" : "CONNECT WALLET"}
              </button>
            ) : !networkCorrect ? (
              <button className="connect-button" type="button" onClick={() => switchChain({ chainId: sepolia.id })}>
                SWITCH TO SEPOLIA
              </button>
            ) : (
              <button className="wallet-button" type="button" onClick={() => disconnect()} title="Disconnect wallet">
                <StatusDot live /> {formatAddress(address)}
              </button>
            )}
          </div>
        </header>

        <main>
          <section className="hero-section" id="overview">
            <div className="hero-copy">
              <div className="section-index">01 <span>/</span> SYSTEM VIEW</div>
              <h1>Price impact.<br /><em>Accounted for.</em></h1>
              <p className="hero-lede">BondMeBro turns persistent swap impact into outcome-linked insurance for liquidity providers.</p>
              <div className="hero-links">
                <a href={explorerAddress(deployment.hook)} target="_blank" rel="noreferrer">VIEW HOOK <span>↗</span></a>
                <span className="hero-divider" />
                <span className="hero-note">NO KEEPER REQUIRED</span>
              </div>
            </div>
            <div className="hero-console" aria-label="Protocol status visualization">
              <div className="console-topline"><span>ACCUMULATOR / TICK</span><span>{accumulator ? "SYNCED" : "WAITING"}</span></div>
              <div className="console-grid-lines" />
              <div className="console-tick">{accumulator ? accumulator[0].toString() : "000000"}</div>
              <div className="console-wave"><span /><span /><span /><span /><span /><span /><span /><span /><span /></div>
              <div className="console-bottomline"><span>LIVE POOL STATE</span><span>BLOCK {blockNumber?.toString() ?? "—"}</span></div>
            </div>
          </section>

          <section className="metrics-grid" aria-label="Protocol metrics">
            <Metric label="QUEUE LENGTH" value={formatInteger(queueRead.data)} detail="matured bonds settle FIFO" accent={Boolean(queueRead.data && queueRead.data > 0n)} />
            <Metric label="CURRENCY 0 POT" value={`${formatToken(pot0Read.data)} ETH`} detail="native insurance balance" />
            <Metric label="CURRENCY 1 POT" value={`${formatToken(pot1Read.data)} WETH`} detail="ERC-20 insurance balance" />
            <Metric label="BOND RATE" value={config ? `${config[2].toString()} BPS` : "—"} detail={bondingEnabled ? "pool bonding enabled" : "pool bonding disabled"} accent={bondingEnabled} />
          </section>

          <section className="dashboard-grid">
            <article className="panel pool-panel">
              <div className="panel-heading">
                <div><div className="panel-index">A / 01</div><h2>Pool identity</h2></div>
                <span className={`tag ${poolConnected ? "tag-live" : ""}`}><StatusDot live={poolConnected} /> {poolConnected ? "BOUND" : "CHECKING"}</span>
              </div>
              <div className="identity-list">
                <div className="identity-row"><span>HOOK</span><a href={explorerAddress(deployment.hook)} target="_blank" rel="noreferrer">{formatAddress(deployment.hook)} ↗</a></div>
                <div className="identity-row"><span>POOL MANAGER</span><a href={explorerAddress(deployment.poolManager)} target="_blank" rel="noreferrer">{formatAddress(deployment.poolManager)} ↗</a></div>
                <div className="identity-row"><span>POOL ID</span><span className="mono-value">{shortenHash(deployment.poolId, 8, 6)}</span></div>
                <div className="identity-row"><span>PAIR</span><span>ETH <b className="pair-slash">/</b> WETH</span></div>
              </div>
              <div className="pool-footer"><span>FEE {deployment.poolFee / 10000}%</span><span>SPACING {deployment.tickSpacing}</span><span>CHAIN {deployment.chainId}</span></div>
            </article>

            <article className="panel config-panel">
              <div className="panel-heading">
                <div><div className="panel-index">B / 02</div><h2>Bond controls</h2></div>
                <span className={`tag ${bondingEnabled ? "tag-accent" : ""}`}>{bondingEnabled ? "ACTIVE" : "PAUSED"}</span>
              </div>
              <div className="control-rows">
                <div className="control-row"><span>MIN INPUT / CURRENCY 0</span><strong>{formatToken(config?.[0])}</strong></div>
                <div className="control-row"><span>MIN INPUT / CURRENCY 1</span><strong>{formatToken(config?.[1])}</strong></div>
                <div className="control-row"><span>OBSERVATION WINDOW</span><strong>{observationBlocks.toString()} <small>BLOCKS</small></strong></div>
                <div className="control-row"><span>SETTLER REWARD</span><strong>{settlerFeeBps.toString()} <small>BPS</small></strong></div>
              </div>
              <div className="owner-line"><span>CONFIG OWNER</span><a href={ownerRead.data ? explorerAddress(ownerRead.data) : "#"} target="_blank" rel="noreferrer">{formatAddress(ownerRead.data)} ↗</a></div>
            </article>
          </section>

          <section className="dashboard-grid second-row">
            <article className="panel queue-panel" id="queue">
              <div className="panel-heading">
                <div><div className="panel-index">C / 03</div><h2>Bond queue</h2></div>
                <span className="tag">FIFO</span>
              </div>
              {headBond ? (
                <div className="bond-detail">
                  <div className="bond-id-line"><span>HEAD BOND</span><span className="mono-value">{shortenHash(headId ?? "", 10, 6)}</span></div>
                  <div className="bond-amount">{formatToken(headBond[6])} <small>{headBond[4].toLowerCase() === deployment.currency0.toLowerCase() ? "ETH" : "WETH"}</small></div>
                  <div className="bond-meta"><span>OWNER <b>{formatAddress(headBond[0])}</b></span><span>OPENED <b>{formatBlock(headBond[1])}</b></span></div>
                  <div className="maturity-track"><div className="maturity-bar" style={{ width: `${maturityProgress}%` }} /></div>
                  <div className="maturity-label"><span>{maturityProgress >= 100 ? "MATURED / READY TO SETTLE" : `MATURITY IN BLOCK ${formatBlock(maturityBlock)}`}</span><span>{relativeBlock(headBond[1], blockNumber)}</span></div>
                </div>
              ) : (
                <div className="empty-state"><div className="empty-glyph">∅</div><strong>QUEUE CLEAR</strong><span>No open bonds are waiting for settlement.</span></div>
              )}
              <div className="panel-footnote"><span>HEAD {shortenHash(bounds?.[0] ?? ZERO_HASH, 8, 4)}</span><span>TAIL {shortenHash(bounds?.[1] ?? ZERO_HASH, 8, 4)}</span></div>
            </article>

            <article className="panel accumulator-panel">
              <div className="panel-heading">
                <div><div className="panel-index">D / 04</div><h2>Accumulator</h2></div>
                <span className="tag tag-live"><StatusDot live={Boolean(accumulator)} /> {accumulator ? "TRACKING" : "WAITING"}</span>
              </div>
              <div className="accumulator-visual"><div className="acc-line acc-line-one" /><div className="acc-line acc-line-two" /><div className="acc-pulse" /></div>
              <div className="accumulator-stats"><div><span>LAST TICK</span><strong>{accumulator?.[0]?.toString() ?? "—"}</strong></div><div><span>LAST UPDATE</span><strong>{accumulator?.[1]?.toString() ?? "—"}</strong></div><div><span>CUMULATIVE</span><strong>{accumulator ? shortenHash(`0x${accumulator[2].toString(16)}`, 8, 4) : "—"}</strong></div></div>
              <div className="panel-footnote"><span>ONCE / BLOCK UPDATE</span><span>CLAMP {clampTicks.toString()} TICKS</span></div>
            </article>
          </section>

          <section className="insurance-section" id="insurance">
            <div className="insurance-heading"><div className="section-index">02 <span>/</span> LP COVERAGE</div><h2>Insurance pot <em>in motion.</em></h2><p>Slashed bonds accumulate by currency, then route to in-range liquidity providers through permissionless donation.</p></div>
            <div className="pot-cards">
              <div className="pot-card"><div className="pot-card-top"><span>01 / NATIVE</span><span>ETH</span></div><strong>{formatToken(pot0Read.data)} <small>ETH</small></strong><div className="pot-line"><span className="pot-line-fill" style={{ width: pot0Read.data && pot0Read.data > 0n ? "74%" : "3%" }} /></div><span className="pot-note">{pot0Read.data && pot0Read.data > 0n ? "READY FOR DONATION" : "NO SLASHED VALUE"}</span></div>
              <div className="pot-card pot-card-highlight"><div className="pot-card-top"><span>02 / ERC-20</span><span>WETH</span></div><strong>{formatToken(pot1Read.data)} <small>WETH</small></strong><div className="pot-line"><span className="pot-line-fill" style={{ width: pot1Read.data && pot1Read.data > 0n ? "58%" : "3%" }} /></div><span className="pot-note">{pot1Read.data && pot1Read.data > 0n ? "READY FOR DONATION" : "NO SLASHED VALUE"}</span></div>
            </div>
          </section>

          <section className="activity-section" id="activity">
            <div className="activity-header"><div><div className="section-index">03 <span>/</span> EVENT STREAM</div><h2>Protocol activity</h2></div><span className="stream-status"><StatusDot live={!activityError} /> LAST 5,000 BLOCKS</span></div>
            {activityError ? <div className="activity-empty">RPC event history is unavailable. Core pool reads are still shown above.</div> : activity.length === 0 ? <div className="activity-empty">No BondMeBro events found in the recent block window.</div> : <div className="activity-list">{activity.map((item, index) => <a className="activity-row" href={item.hash ? explorerTx(item.hash) : "#"} target="_blank" rel="noreferrer" key={`${item.kind}-${item.block}-${index}`}><span className={`activity-kind activity-kind-${item.kind.toLowerCase()}`}>{item.kind}</span><span className="activity-detail">{item.detail}</span><span className="activity-block">BLOCK {item.block}</span><span className="activity-hash">{item.hash ? shortenHash(item.hash) : "—"} ↗</span></a>)}</div>}
          </section>
        </main>

        <footer className="app-footer"><span>BOND<span>ME</span>BRO / OUTCOME-LINKED LP INSURANCE</span><span>READ-ONLY DASHBOARD / FRONTEND PHASE 01</span></footer>
      </section>
    </div>
  );
}
