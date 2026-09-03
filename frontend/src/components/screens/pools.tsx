"use client";

import { useMemo, useState } from "react";
import type { Address, Hex } from "viem";
import { usePublicClient, useReadContract, useSwitchChain, useWriteContract } from "wagmi";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import type { Activity } from "@/lib/activity";
import { explorerAddress, hookPermissionMask } from "@/lib/deployment";
import { describeError } from "@/lib/errors";
import { formatAddress, formatAmount, formatRawUnits } from "@/lib/format";
import { assertContext, assertReceiptSucceeded, type IntendedContext } from "@/lib/guards";
import { poolConfigSetterArgs, validatePoolConfig, type PoolConfig } from "@/lib/poolConfig";
import type { ProtocolState } from "@/lib/useProtocol";
import { Badge, SectionHeading, StatusDot } from "@/components/ui";

type ConfigState = "idle" | "sending" | "success" | "error";

export function PoolsScreen({
  protocol,
  account,
  walletChainId,
  isConnected,
  onConnect,
  onActivity,
}: {
  protocol: ProtocolState;
  account?: Address;
  walletChainId?: number;
  isConnected: boolean;
  onConnect: () => void;
  onActivity: (item: Activity) => void;
}) {
  const { deployment, poolConfig, constants, token0, token1 } = protocol;
  const publicClient = usePublicClient({ chainId: deployment.chainId });
  const { writeContractAsync } = useWriteContract();
  const { switchChain } = useSwitchChain();

  const accumulatorRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    chainId: deployment.chainId,
    functionName: "accumulator",
    args: [deployment.poolId],
    query: { refetchInterval: 10_000 },
  });
  const accumulator = accumulatorRead.data as readonly [number, number, number, bigint] | undefined;

  const isOwner = Boolean(
    account && protocol.owner && account.toLowerCase() === protocol.owner.toLowerCase(),
  );
  const networkCorrect = walletChainId === deployment.chainId;

  const mask = useMemo(() => hookPermissionMask(deployment.hook), [deployment.hook]);

  return (
    <>
      <section className="screen-intro">
        <div>
          <span className="eyebrow">03 / POOL ANALYTICS</span>
          <h1>
            Pool health.
            <br />
            <em>Live.</em>
          </h1>
        </div>
        <p>Configuration is read back from the hook after every change; the event is not treated as canonical.</p>
      </section>

      <section className="content-grid pool-analytics-grid">
        <article className="neo-card analytics-card">
          <div className="card-heading">
            <div>
              <span className="eyebrow">SELECTED POOL</span>
              <h2>
                {token0?.symbol ?? "TOKEN0"} / {token1?.symbol ?? "TOKEN1"}
              </h2>
            </div>
            <Badge tone={protocol.poolManagerMatches ? "green" : "neutral"}>
              <StatusDot live={protocol.poolManagerMatches} />{" "}
              {protocol.poolManagerMatches ? "HOOK BOUND" : "CHECKING"}
            </Badge>
          </div>
          <div className="pool-stat-grid">
            <div>
              <span>CHAIN</span>
              <strong>
                {deployment.networkName} ({deployment.chainId})
              </strong>
            </div>
            <div>
              <span>FEE TIER</span>
              <strong>{(deployment.fee / 10_000).toFixed(2)}%</strong>
            </div>
            <div>
              <span>TICK SPACING</span>
              <strong>{deployment.tickSpacing}</strong>
            </div>
            <div>
              <span>HOOK PERMISSION BITS</span>
              <strong>0x{mask.toString(16).toUpperCase()}</strong>
            </div>
            <div>
              <span>POOL ID (DERIVED)</span>
              <strong>{deployment.poolId.slice(0, 18)}…</strong>
            </div>
            <div>
              <span>LAST TICK</span>
              <strong>{accumulator ? String(accumulator[0]) : "—"}</strong>
            </div>
            <div>
              <span>BLOCK-START TICK</span>
              <strong>{accumulator ? String(accumulator[2]) : "—"}</strong>
            </div>
            <div>
              <span>OBSERVATION HORIZON</span>
              <strong>
                {protocol.observationBlocks === undefined ? "—" : `${protocol.observationBlocks} blocks`}
              </strong>
            </div>
          </div>
          <a
            className="outline-button full-button button-as-link"
            href={explorerAddress(deployment, deployment.hook)}
            target="_blank"
            rel="noreferrer"
          >
            View hook contract ↗
          </a>
        </article>

        <article className="glass-card configuration-card">
          <div className="card-heading">
            <div>
              <span className="eyebrow">BOND CONFIGURATION</span>
              <h2>Pool parameters</h2>
            </div>
            <Badge tone={poolConfig?.bondingEnabled ? "orange" : "muted"}>
              {protocol.poolConfigError ? "READ FAILED" : poolConfig?.bondingEnabled ? "BONDING ENABLED" : "BONDING DISABLED"}
            </Badge>
          </div>
          {protocol.poolConfigError && <div className="pair-warning">The pool configuration could not be read.</div>}
          <p className="card-copy">
            Bonding being disabled does not stop swapping. A disabled pool trades normally and simply creates no bond.
          </p>
          <div className="config-list">
            <div>
              <span>Minimum input / {token0?.symbol ?? "currency0"}</span>
              <strong>
                {token0 ? formatAmount(poolConfig?.minBondedAmount0, token0.decimals) : "—"}{" "}
                <small>{formatRawUnits(poolConfig?.minBondedAmount0)} raw</small>
              </strong>
            </div>
            <div>
              <span>Minimum input / {token1?.symbol ?? "currency1"}</span>
              <strong>
                {token1 ? formatAmount(poolConfig?.minBondedAmount1, token1.decimals) : "—"}{" "}
                <small>{formatRawUnits(poolConfig?.minBondedAmount1)} raw</small>
              </strong>
            </div>
            <div>
              <span>Minimum variable leg / {token0?.symbol ?? "currency0"}</span>
              <strong>
                {token0 ? formatAmount(poolConfig?.minVariableLeg0, token0.decimals) : "—"}{" "}
                <small>{formatRawUnits(poolConfig?.minVariableLeg0)} raw</small>
              </strong>
            </div>
            <div>
              <span>Minimum variable leg / {token1?.symbol ?? "currency1"}</span>
              <strong>
                {token1 ? formatAmount(poolConfig?.minVariableLeg1, token1.decimals) : "—"}{" "}
                <small>{formatRawUnits(poolConfig?.minVariableLeg1)} raw</small>
              </strong>
            </div>
            <div>
              <span>Collateral cap</span>
              <strong>
                {constants ? `${constants.maxBondBps} bps` : "—"} <small>frozen</small>
              </strong>
            </div>
            <div>
              <span>Collateral scale</span>
              <strong>
                0.25 bps <small>per effective tick</small>
              </strong>
            </div>
          </div>
          <div className="owner-row">
            <span>OWNER</span>
            <a
              href={protocol.owner ? explorerAddress(deployment, protocol.owner) : "#"}
              target="_blank"
              rel="noreferrer"
            >
              {formatAddress(protocol.owner)} ↗
            </a>
          </div>
        </article>
      </section>

      <section className="content-grid pool-analytics-grid analytics-lower">
        <article className="neo-card">
          <SectionHeading
            eyebrow="RESERVE"
            title="LP-risk compensation reserve"
            copy="Retained collateral is accounted per pool and per currency. There is no payout path in this version."
          />
          <div className="mini-stats">
            <div>
              <span>{token0?.symbol ?? "CURRENCY0"}</span>
              <strong>{token0 ? formatAmount(protocol.insurancePot0, token0.decimals) : "—"}</strong>
            </div>
            <div>
              <span>{token1?.symbol ?? "CURRENCY1"}</span>
              <strong>{token1 ? formatAmount(protocol.insurancePot1, token1.decimals) : "—"}</strong>
            </div>
          </div>
        </article>

        <AdminCard
          protocol={protocol}
          account={account}
          walletChainId={walletChainId}
          isConnected={isConnected}
          isOwner={isOwner}
          networkCorrect={networkCorrect}
          onConnect={onConnect}
          onSwitchNetwork={() => switchChain({ chainId: deployment.chainId })}
          onActivity={onActivity}
          publicClient={publicClient}
          writeContractAsync={writeContractAsync}
        />
      </section>
    </>
  );
}

function AdminCard({
  protocol,
  account,
  walletChainId,
  isConnected,
  isOwner,
  networkCorrect,
  onConnect,
  onSwitchNetwork,
  onActivity,
  publicClient,
  writeContractAsync,
}: {
  protocol: ProtocolState;
  account?: Address;
  walletChainId?: number;
  isConnected: boolean;
  isOwner: boolean;
  networkCorrect: boolean;
  onConnect: () => void;
  onSwitchNetwork: () => void;
  onActivity: (item: Activity) => void;
  publicClient: ReturnType<typeof usePublicClient>;
  writeContractAsync: ReturnType<typeof useWriteContract>["writeContractAsync"];
}) {
  const { deployment, constants, poolConfig } = protocol;
  const [minInput0, setMinInput0] = useState("");
  const [minInput1, setMinInput1] = useState("");
  const [minLeg0, setMinLeg0] = useState("");
  const [minLeg1, setMinLeg1] = useState("");
  const [enabled, setEnabled] = useState(true);
  const [state, setState] = useState<ConfigState>("idle");
  const [message, setMessage] = useState("");
  const [hash, setHash] = useState<Hex | undefined>();

  // Thresholds are RAW UNITS of their own currency, not token amounts. The 10,000 floor on
  // each variable-leg minimum is a raw-unit floor: 0.01 at 6 decimals, 0.0001 at 8.
  const draft: PoolConfig | undefined = useMemo(() => {
    const parse = (value: string) => (/^\d+$/.test(value.trim()) ? BigInt(value.trim()) : undefined);
    const values = [parse(minInput0), parse(minInput1), parse(minLeg0), parse(minLeg1)];
    if (values.some((value) => value === undefined)) return undefined;
    return {
      minBondedAmount0: values[0] as bigint,
      minBondedAmount1: values[1] as bigint,
      minVariableLeg0: values[2] as bigint,
      minVariableLeg1: values[3] as bigint,
      bondingEnabled: enabled,
    };
  }, [minInput0, minInput1, minLeg0, minLeg1, enabled]);

  const problems = draft && constants ? validatePoolConfig(draft, constants.bps) : ["Enter all four raw-unit minimums."];

  function loadCurrent() {
    if (!poolConfig) return;
    setMinInput0(poolConfig.minBondedAmount0.toString());
    setMinInput1(poolConfig.minBondedAmount1.toString());
    setMinLeg0(poolConfig.minVariableLeg0.toString());
    setMinLeg1(poolConfig.minVariableLeg1.toString());
    setEnabled(poolConfig.bondingEnabled);
  }

  async function apply() {
    if (!draft || !account || walletChainId === undefined || !publicClient || problems.length > 0) return;
    const intended: IntendedContext = { address: account, chainId: walletChainId };
    setState("sending");
    setMessage("");
    setHash(undefined);
    try {
      assertContext(intended, { address: account, chainId: walletChainId });
      const submitted = await writeContractAsync({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "setPoolConfig",
        // Setter order puts bondingEnabled LAST, unlike the getter which puts it third.
        args: poolConfigSetterArgs(deployment, draft),
        account: intended.address,
        chainId: intended.chainId,
      });
      setHash(submitted);
      const receipt = assertReceiptSucceeded(
        await publicClient.waitForTransactionReceipt({ hash: submitted }),
        "configuration",
      );
      // Re-read the getter. Disabling clears the stored thresholds while the event still
      // carries the supplied values, so the event is not the truth here.
      protocol.refresh();
      onActivity({
        kind: "CONFIG",
        block: receipt.blockNumber.toString(),
        hash: submitted,
        detail: draft.bondingEnabled ? "Pool bonding configured" : "Pool bonding disabled",
      });
      setState("success");
    } catch (error) {
      setState("error");
      setMessage(describeError(error));
    }
  }

  return (
    <article className="glass-card configuration-card">
      <div className="card-heading">
        <div>
          <span className="eyebrow">OWNER CONTROLS</span>
          <h2>BMB-01 participation</h2>
        </div>
        <Badge tone={isOwner ? "orange" : "muted"}>{isOwner ? "OWNER" : "READ ONLY"}</Badge>
      </div>
      <p className="card-copy">
        All four minimums are raw units of their own currency. Enabling requires both input minimums above zero and both
        variable-leg minimums at or above {constants ? constants.bps.toString() : "10,000"} raw units. Disabling clears
        all four stored thresholds.
      </p>

      <div className="config-list">
        <label>
          <span>minBondedAmount0 (raw {protocol.token0?.symbol ?? "currency0"})</span>
          <input value={minInput0} onChange={(event) => setMinInput0(event.target.value)} inputMode="numeric" placeholder="0" />
        </label>
        <label>
          <span>minBondedAmount1 (raw {protocol.token1?.symbol ?? "currency1"})</span>
          <input value={minInput1} onChange={(event) => setMinInput1(event.target.value)} inputMode="numeric" placeholder="0" />
        </label>
        <label>
          <span>minVariableLeg0 (raw {protocol.token0?.symbol ?? "currency0"})</span>
          <input value={minLeg0} onChange={(event) => setMinLeg0(event.target.value)} inputMode="numeric" placeholder="10000" />
        </label>
        <label>
          <span>minVariableLeg1 (raw {protocol.token1?.symbol ?? "currency1"})</span>
          <input value={minLeg1} onChange={(event) => setMinLeg1(event.target.value)} inputMode="numeric" placeholder="10000" />
        </label>
        <label className="config-toggle">
          <span>bondingEnabled</span>
          <input type="checkbox" checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />
        </label>
      </div>

      {problems.length > 0 && <div className="pair-warning">{problems[0]}</div>}

      <div className="detail-actions">
        <button type="button" className="outline-button" onClick={loadCurrent} disabled={!poolConfig}>
          Load current values
        </button>
        {!isConnected ? (
          <button type="button" className="primary-button" onClick={onConnect}>
            Connect wallet <span>→</span>
          </button>
        ) : !networkCorrect ? (
          <button type="button" className="primary-button" onClick={onSwitchNetwork}>
            Switch to {deployment.networkName} <span>→</span>
          </button>
        ) : (
          <button
            type="button"
            className="primary-button"
            disabled={!isOwner || problems.length > 0 || state === "sending"}
            onClick={() => void apply()}
          >
            {state === "sending" ? "Confirming…" : "Apply configuration"} <span>→</span>
          </button>
        )}
      </div>

      {state === "error" && <div className="transaction-message transaction-error">{message}</div>}
      {state === "success" && hash && (
        <div className="transaction-message transaction-success">
          Configuration applied and re-read from the hook.{" "}
          <a href={`${deployment.explorerUrl}/tx/${hash}`} target="_blank" rel="noreferrer">
            View ↗
          </a>
        </div>
      )}
    </article>
  );
}
