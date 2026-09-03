"use client";

import { useEffect, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";

import {
  mergeActivity,
  readSavedActivity,
  saveActivity,
  type Activity,
} from "@/lib/activity";
import type { BondOpenedEvent } from "@/lib/bond";
import { explorerAddress, type Deployment } from "@/lib/deployment";
import { formatAddress } from "@/lib/format";
import { useBondIndex } from "@/lib/useBonds";
import { useProtocol } from "@/lib/useProtocol";
import { BondsScreen } from "@/components/screens/bonds";
import { ActivityScreen, LearnScreen, OverviewScreen } from "@/components/screens/misc";
import { PoolsScreen } from "@/components/screens/pools";
import { SwapScreen } from "@/components/screens/swap";
import { StatusDot } from "@/components/ui";

type Theme = "light" | "dark" | "black";
type Screen = "overview" | "swap" | "bonds" | "pools" | "activity" | "learn";

const NAV: { id: Screen; label: string; icon: string }[] = [
  { id: "overview", label: "Overview", icon: "⌂" },
  { id: "swap", label: "Swap", icon: "↕" },
  { id: "bonds", label: "My bonds", icon: "◈" },
  { id: "pools", label: "Pools", icon: "◫" },
  { id: "activity", label: "Activity", icon: "≋" },
  { id: "learn", label: "Learn", icon: "?" },
];

function nextTheme(theme: Theme): Theme {
  if (theme === "light") return "dark";
  if (theme === "dark") return "black";
  return "light";
}

function themeLabel(theme: Theme) {
  if (theme === "black") return "Black mode";
  if (theme === "dark") return "Dark mode";
  return "Light mode";
}

function themeIcon(theme: Theme) {
  if (theme === "black") return "●";
  if (theme === "dark") return "☾";
  return "☼";
}

export function Dashboard({ deployment }: { deployment: Deployment }) {
  const { address, chainId, isConnected } = useAccount();
  const { connect, connectors, isPending: isConnecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  const protocol = useProtocol(deployment);
  const bonds = useBondIndex(deployment, address);

  const [screen, setScreen] = useState<Screen>("overview");
  const [theme, setTheme] = useState<Theme>("light");
  const [activity, setActivity] = useState<Activity[]>([]);
  const [activityReady, setActivityReady] = useState(false);

  const networkCorrect = chainId === deployment.chainId;

  useEffect(() => {
    const saved = window.localStorage.getItem("bondmebro-theme") as Theme | null;
    if (saved === "light" || saved === "dark" || saved === "black") setTheme(saved);
  }, []);

  useEffect(() => {
    window.localStorage.setItem("bondmebro-theme", theme);
  }, [theme]);

  useEffect(() => {
    setActivity((previous) => mergeActivity(previous, readSavedActivity(deployment)));
    setActivityReady(true);
  }, [deployment]);

  useEffect(() => {
    if (activityReady) saveActivity(deployment, activity);
  }, [activity, activityReady, deployment]);

  function recordActivity(item: Activity) {
    setActivity((previous) => mergeActivity(previous, [item]));
  }

  function onBondDiscovered(opened: BondOpenedEvent) {
    bonds.addDiscoveredBond(opened);
  }

  function goTo(next: Screen) {
    setScreen(next);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function connectWallet() {
    const connector = connectors[0];
    if (connector) connect({ connector });
  }

  return (
    <div className={`app-shell theme-${theme}`}>
      <aside className="sidebar">
        <div className="sidebar-brand">
          <div className="brand-symbol">B</div>
          <div>
            <div className="brand-name">BondMeBro</div>
            <div className="brand-subtitle">ACCOUNTABLE LIQUIDITY</div>
          </div>
        </div>

        <div className="sidebar-section-label">APPLICATION</div>
        <nav className="sidebar-nav" aria-label="Application navigation">
          {NAV.map((item) => (
            <button
              key={item.id}
              className={`sidebar-nav-item ${screen === item.id ? "sidebar-nav-active" : ""}`}
              onClick={() => goTo(item.id)}
              type="button"
            >
              <span className="nav-icon">{item.icon}</span>
              <span>{item.label}</span>
              {screen === item.id && <span className="nav-active-mark" />}
            </button>
          ))}
        </nav>

        <div className="sidebar-section-label sidebar-flow-label">PROTOCOL FLOW</div>
        <div className="sidebar-flow-card" aria-label="BondMeBro flow">
          <div className={`sidebar-flow-step ${screen === "swap" ? "sidebar-flow-step-active" : ""}`}>
            <span>01</span>
            <div>
              <strong>Swap</strong>
              <small>Quote</small>
            </div>
            <i>↕</i>
          </div>
          <div className={`sidebar-flow-step ${screen === "bonds" ? "sidebar-flow-step-active" : ""}`}>
            <span>02</span>
            <div>
              <strong>Bond</strong>
              <small>Collateral held</small>
            </div>
            <i>◈</i>
          </div>
          <div className={`sidebar-flow-step ${screen === "bonds" ? "sidebar-flow-step-active" : ""}`}>
            <span>03</span>
            <div>
              <strong>Settle</strong>
              <small>At maturity</small>
            </div>
            <i>✓</i>
          </div>
          <div className="sidebar-flow-step">
            <span>04</span>
            <div>
              <strong>Refund</strong>
              <small>To stored recipient</small>
            </div>
            <i>↗</i>
          </div>
          <div className={`sidebar-flow-step ${screen === "pools" ? "sidebar-flow-step-active" : ""}`}>
            <span>05</span>
            <div>
              <strong>Reserve</strong>
              <small>Retained amount</small>
            </div>
            <i>♢</i>
          </div>
        </div>

        <div className="sidebar-spacer" />
        <div className="sidebar-section-label">NETWORK</div>
        <div className="network-card">
          <StatusDot live={protocol.rpcOnline} />
          <div>
            <strong>{deployment.networkName}</strong>
            <span>Chain {deployment.chainId}</span>
          </div>
          <span className="network-check">{protocol.rpcOnline ? "✓" : "!"}</span>
        </div>

        <div className="sidebar-tools">
          <button type="button" onClick={() => setTheme(nextTheme(theme))}>
            <span>{themeIcon(theme)}</span>
            {themeLabel(theme)}
            <b>SWITCH</b>
          </button>
          <a href={explorerAddress(deployment, deployment.hook)} target="_blank" rel="noreferrer">
            <span>↗</span>Contract explorer
          </a>
        </div>
        <div className="sidebar-foot">
          <span>{deployment.networkName.toUpperCase()} BUILD</span>
          <span>01 / 05</span>
        </div>
      </aside>

      <div className="main-column">
        <header className="topbar">
          <div className="mobile-brand">
            <div className="brand-symbol">B</div>
            <span>BondMeBro</span>
          </div>
          <div className="topbar-location">
            <span>APP</span>
            <i>/</i>
            <strong>{NAV.find((item) => item.id === screen)?.label}</strong>
          </div>
          <div className="topbar-actions">
            <button
              type="button"
              className={`rpc-chip ${protocol.rpcOnline ? "" : "rpc-chip-offline"}`}
              onClick={() => {
                protocol.refresh();
                bonds.refresh();
              }}
              title="Refresh chain data"
            >
              <StatusDot live={protocol.rpcOnline} />
              {protocol.rpcOnline ? "Live data" : "RPC offline · retry"}
            </button>
            {!isConnected ? (
              <button
                className="wallet-button primary-button"
                type="button"
                onClick={connectWallet}
                disabled={isConnecting}
              >
                {isConnecting ? "Connecting…" : "Connect wallet"}
              </button>
            ) : !networkCorrect ? (
              <button
                className="wallet-button primary-button"
                type="button"
                onClick={() => switchChain({ chainId: deployment.chainId })}
              >
                Switch to {deployment.networkName}
              </button>
            ) : (
              <button className="wallet-button" type="button" onClick={() => disconnect()}>
                <StatusDot live />
                {formatAddress(address)}
              </button>
            )}
          </div>
        </header>

        <section className="protocol-status-bar" aria-label="Protocol status" aria-live="polite">
          <div className="protocol-status-intro">
            <span className={`protocol-pulse ${protocol.rpcOnline ? "protocol-pulse-live" : ""}`} />
            <div>
              <strong>BondMeBro</strong>
              <small>{protocol.rpcOnline ? `${deployment.networkName} live` : "RPC wait"}</small>
            </div>
          </div>
          <div className="protocol-status-item">
            <span>Pool</span>
            <strong>
              {protocol.token0?.symbol ?? "TOKEN0"} / {protocol.token1?.symbol ?? "TOKEN1"}
            </strong>
          </div>
          <div className="protocol-status-item">
            <span>Collateral cap</span>
            <strong>{protocol.constants ? `${protocol.constants.maxBondBps} bps` : "—"}</strong>
          </div>
          <div className="protocol-status-item">
            <span>Observation</span>
            <strong>
              {protocol.observationBlocks === undefined ? "—" : `${protocol.observationBlocks} blocks`}
            </strong>
          </div>
          <button
            type="button"
            className="protocol-refresh"
            onClick={() => {
              protocol.refresh();
              bonds.refresh();
            }}
          >
            Sync <span>↻</span>
          </button>
        </section>

        {!protocol.canTrade && (
          <section className="pair-warning" role="alert">
            Configuration error — trading is disabled. {protocol.configurationProblems.join(" ")}
          </section>
        )}

        <main className="page-content">
          {screen === "overview" && (
            <OverviewScreen
              protocol={protocol}
              unsettled={bonds.unsettled}
              settled={bonds.settled}
              activity={activity}
              onSwap={() => goTo("swap")}
              onLearn={() => goTo("learn")}
              onViewBonds={() => goTo("bonds")}
              onViewActivity={() => goTo("activity")}
            />
          )}
          {screen === "swap" && (
            <SwapScreen
              protocol={protocol}
              account={address}
              walletChainId={chainId}
              isConnected={isConnected}
              onConnect={connectWallet}
              onViewBonds={() => goTo("bonds")}
              onActivity={recordActivity}
              onBondDiscovered={onBondDiscovered}
              onSwapConfirmed={() => {
                protocol.refresh();
                bonds.refresh();
              }}
            />
          )}
          {screen === "bonds" && (
            <BondsScreen
              protocol={protocol}
              records={bonds.records}
              unsettled={bonds.unsettled}
              settled={bonds.settled}
              loading={bonds.loading}
              error={bonds.error}
              scanNote={bonds.scanNote}
              account={address}
              walletChainId={chainId}
              isConnected={isConnected}
              onConnect={connectWallet}
              onSwap={() => goTo("swap")}
              onActivity={recordActivity}
              onRefresh={bonds.refresh}
            />
          )}
          {screen === "pools" && (
            <PoolsScreen
              protocol={protocol}
              account={address}
              walletChainId={chainId}
              isConnected={isConnected}
              onConnect={connectWallet}
              onActivity={recordActivity}
            />
          )}
          {screen === "activity" && (
            <ActivityScreen deployment={deployment} activity={activity} onRefresh={bonds.refresh} />
          )}
          {screen === "learn" && <LearnScreen onSwap={() => goTo("swap")} />}
        </main>

        <footer className="page-footer">
          <span>BondMeBro / outcome-linked LP-risk sharing</span>
          <span>{deployment.networkName.toUpperCase()} / CHAIN {deployment.chainId}</span>
        </footer>
      </div>

      <nav className="mobile-nav" aria-label="Mobile navigation">
        {NAV.slice(0, 5).map((item) => (
          <button
            key={item.id}
            type="button"
            className={screen === item.id ? "mobile-nav-active" : ""}
            onClick={() => goTo(item.id)}
          >
            <span>{item.icon}</span>
            {item.label}
          </button>
        ))}
      </nav>
    </div>
  );
}
