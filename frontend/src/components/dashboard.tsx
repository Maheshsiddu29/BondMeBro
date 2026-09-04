"use client";

import { useEffect, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";

import { mergeActivity, readSavedActivity, saveActivity, type Activity } from "@/lib/activity";
import type { BondOpenedEvent, BondTakenEvent } from "@/lib/bond";
import { type Deployment } from "@/lib/deployment";
import { formatAddress } from "@/lib/format";
import { useBondIndex } from "@/lib/useBonds";
import { useProtocol } from "@/lib/useProtocol";
import { BondsScreen } from "@/components/screens/bonds";
import { LearnScreen } from "@/components/screens/misc";
import { PoolsScreen } from "@/components/screens/pools";
import { SwapScreen } from "@/components/screens/swap";

/**
 * The demo journey is three screens: Swap, Bonds, Learn.
 *
 * Pool administration is real functionality but not part of the recording, so it stays
 * reachable only for the hook owner, from a quiet link at the foot of the sidebar.
 */
type Screen = "swap" | "bonds" | "learn" | "pools";

const NAV: { id: Screen; label: string }[] = [
  { id: "swap", label: "Swap" },
  { id: "bonds", label: "Bonds" },
  { id: "learn", label: "Learn" },
];

export function Dashboard({ deployment }: { deployment: Deployment }) {
  const { address, chainId, isConnected } = useAccount();
  const { connect, connectors, isPending: isConnecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  const protocol = useProtocol(deployment);
  const bonds = useBondIndex(deployment, address);

  const [screen, setScreen] = useState<Screen>("swap");
  const [activity, setActivity] = useState<Activity[]>([]);
  const [activityReady, setActivityReady] = useState(false);

  const networkCorrect = chainId === deployment.chainId;
  const isOwner = Boolean(address && protocol.owner && address.toLowerCase() === protocol.owner.toLowerCase());

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

  function connectWallet() {
    const connector = connectors[0];
    if (connector) connect({ connector });
  }

  function goTo(next: Screen) {
    setScreen(next);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-logo">B</span>
          BondMeBro
        </div>

        <nav className="nav" aria-label="Main">
          {NAV.map((item) => (
            <button
              key={item.id}
              type="button"
              className={`nav-item${screen === item.id ? " active" : ""}`}
              onClick={() => goTo(item.id)}
            >
              <span className="nav-dot" />
              {item.label}
            </button>
          ))}
        </nav>

        <div className="sidebar-foot">
          <div className="mini-card">
            <strong>{deployment.networkName}</strong>
            Chain {deployment.chainId}
          </div>
          {isOwner && (
            <button type="button" className="owner-link" onClick={() => goTo(screen === "pools" ? "swap" : "pools")}>
              {screen === "pools" ? "← Back to demo" : "Pool admin"}
            </button>
          )}
        </div>
      </aside>

      <div className="main-column">
        <header className="topbar">
          <span className="net-chip">
            <span className={`live-dot${protocol.rpcOnline ? " on" : ""}`} />
            {deployment.networkName}
          </span>
          {!isConnected ? (
            <button className="wallet-chip" type="button" onClick={connectWallet} disabled={isConnecting}>
              {isConnecting ? "Connecting…" : "Connect wallet"}
            </button>
          ) : !networkCorrect ? (
            <button className="wallet-chip" type="button" onClick={() => switchChain({ chainId: deployment.chainId })}>
              Switch network
            </button>
          ) : (
            <button className="wallet-chip" type="button" onClick={() => disconnect()}>
              <span className="live-dot on" />
              {formatAddress(address)}
            </button>
          )}
        </header>

        {!protocol.canTrade && (
          <div className="page">
            <div className="pair-warning">Configuration error. {protocol.configurationProblems.join(" ")}</div>
          </div>
        )}

        <main>
          {screen === "swap" && (
            <SwapScreen
              protocol={protocol}
              account={address}
              walletChainId={chainId}
              isConnected={isConnected}
              onConnect={connectWallet}
              onViewBonds={() => goTo("bonds")}
              onActivity={recordActivity}
              onBondDiscovered={(opened: BondOpenedEvent, taken?: BondTakenEvent) =>
                // Straight from the swap receipt, so the card is on screen before any scan.
                bonds.addDiscoveredBond(opened, taken)
              }
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
              historyStatus={bonds.historyStatus}
              account={address}
              walletChainId={chainId}
              isConnected={isConnected}
              onConnect={connectWallet}
              onSwap={() => goTo("swap")}
              onActivity={recordActivity}
              onRefresh={bonds.refresh}
              onSettledFromReceipt={bonds.markSettledFromReceipt}
            />
          )}
          {screen === "learn" && <LearnScreen onSwap={() => goTo("swap")} />}
          {screen === "pools" && isOwner && (
            <div className="page page-wide">
              <PoolsScreen
                protocol={protocol}
                account={address}
                walletChainId={chainId}
                isConnected={isConnected}
                onConnect={connectWallet}
                onActivity={recordActivity}
              />
            </div>
          )}
        </main>
      </div>
    </div>
  );
}
