"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { decodeAbiParameters, formatUnits, keccak256, parseUnits, toBytes, type Address, type Hex } from "viem";
import {
  useAccount,
  useBalance,
  useBlockNumber,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { sepolia } from "wagmi/chains";

import { bondMeBroAbi } from "@/lib/abi";
import { deployment, explorerAddress, explorerTx, shortenHash } from "@/lib/config";
import { isConfiguredPair, tokenOptions, type TokenOption } from "@/lib/tokens";
import { encodeBondHookData, encodeExactInputRouterPlan, erc20Abi, permit2Abi, universalRouterAbi, v4QuoterAbi } from "@/lib/swap";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
const ZERO_HASH = `0x${"0".repeat(64)}` as Hex;
const MAX_UINT160 = (1n << 160n) - 1n;
const eventDescriptors = [
  {
    topic: keccak256(toBytes("BondOpened(bytes32,bytes32,address,address,uint128,int24,int24,uint48)")),
    kind: "OPENED" as const,
    detail: "Bond opened",
    poolScoped: true,
  },
  {
    topic: keccak256(toBytes("BondSettled(bytes32,bytes32,address,address,uint128,uint128,uint128,int24,uint16)")),
    kind: "SETTLED" as const,
    detail: "Bond settled",
    poolScoped: true,
  },
  {
    topic: keccak256(toBytes("PoolConfigUpdated(bytes32,uint96,uint96,uint16,address)")),
    kind: "CONFIG" as const,
    detail: "Pool config updated",
    poolScoped: true,
  },
  {
    topic: keccak256(toBytes("PotDonated(bytes32,address,uint256,address)")),
    kind: "DONATED" as const,
    detail: "Pot donated",
    poolScoped: true,
  },
  {
    topic: keccak256(toBytes("PaymentDeferred(address,address,uint256)")),
    kind: "DEFERRED" as const,
    detail: "Payment deferred",
    poolScoped: false,
  },
  {
    topic: keccak256(toBytes("PaymentsClaimed(address,address,uint256)")),
    kind: "CLAIMED" as const,
    detail: "Payment claimed",
    poolScoped: false,
  },
] as const;
const eventTopics = eventDescriptors.map((descriptor) => descriptor.topic);
const MAX_ACTIVITY_ITEMS = 50;
const activityStorageKey = `bondmebro-activity-${process.env.NEXT_PUBLIC_CHAIN_ID ?? 11155111}-${(process.env.NEXT_PUBLIC_HOOK_ADDRESS ?? "0xbFBa0c39308B5b189E8cd0686D3b41A64e8590cC").toLowerCase()}`;

type Theme = "light" | "dark" | "black";
type Screen = "overview" | "swap" | "bonds" | "pools" | "activity" | "learn";
type TransactionState = "idle" | "approving" | "sending" | "success" | "error";
type ProtocolTransactionState = "idle" | "sending" | "submitted" | "success" | "error";
type ActivityKind = (typeof eventDescriptors)[number]["kind"];

type Activity = {
  kind: ActivityKind;
  block: string;
  hash?: string;
  detail: string;
};

function isActivity(value: unknown): value is Activity {
  if (value === null || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  return typeof item.kind === "string" && eventDescriptors.some((descriptor) => descriptor.kind === item.kind)
    && typeof item.block === "string" && /^\d+$/.test(item.block) && typeof item.detail === "string"
    && (item.hash === undefined || typeof item.hash === "string");
}

function readSavedActivity() {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(activityStorageKey);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(isActivity).slice(0, MAX_ACTIVITY_ITEMS) : [];
  } catch {
    return [];
  }
}

type Settlement = {
  refundAmount: bigint;
  slashAmount: bigint;
  settlerFee: bigint;
  twaReference: bigint;
  persistenceBps: bigint;
  block: bigint;
  hash?: Hex;
};

type UserBond = {
  id: Hex;
  owner: Address;
  openBlock: bigint;
  tickBefore: bigint;
  tickAfter: bigint;
  currency: Address;
  amount: bigint;
  maturesAtBlock: bigint;
  hash?: Hex;
  settlement?: Settlement;
};

type RpcLog = {
  topics?: string[];
  data?: string;
  blockNumber?: string;
  transactionHash?: string;
};

type ConfigTuple = readonly [bigint, bigint, bigint];
type AccumulatorTuple = readonly [bigint, bigint, bigint];
type BoundsTuple = readonly [Hex, Hex];
type BondTuple = readonly [Address, bigint, bigint, bigint, Address, bigint, bigint, Hex];

/** viem decodes named ABI tuples as objects, while unnamed returns are arrays. */
function tupleItem(value: unknown, index: number, name: string): unknown {
  if (Array.isArray(value)) return value[index];
  if (value !== null && typeof value === "object") return (value as Record<string, unknown>)[name];
  return undefined;
}

/** viem may return small Solidity integers as numbers and wider values as bigint. */
function asBigInt(value: unknown): bigint | undefined {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value);
  return undefined;
}

function normalizeConfig(value: unknown): ConfigTuple | undefined {
  const result = [
    asBigInt(tupleItem(value, 0, "minBondedAmount0")),
    asBigInt(tupleItem(value, 1, "minBondedAmount1")),
    asBigInt(tupleItem(value, 2, "bondBps")),
  ];
  return result.every((item): item is bigint => item !== undefined) ? (result as unknown as ConfigTuple) : undefined;
}

function normalizeAccumulator(value: unknown): AccumulatorTuple | undefined {
  const result = [
    asBigInt(tupleItem(value, 0, "lastTick")),
    asBigInt(tupleItem(value, 1, "lastUpdate")),
    asBigInt(tupleItem(value, 2, "tickCumulative")),
  ];
  return result.every((item): item is bigint => item !== undefined) ? (result as unknown as AccumulatorTuple) : undefined;
}

function normalizeBounds(value: unknown): BoundsTuple | undefined {
  const result = [tupleItem(value, 0, "head"), tupleItem(value, 1, "tail")];
  return result.every((item): item is string => typeof item === "string") ? (result as unknown as BoundsTuple) : undefined;
}

function normalizeBond(value: unknown): BondTuple | undefined {
  const result = [
    tupleItem(value, 0, "owner"),
    asBigInt(tupleItem(value, 1, "openBlock")),
    asBigInt(tupleItem(value, 2, "tickBefore")),
    asBigInt(tupleItem(value, 3, "tickAfter")),
    tupleItem(value, 4, "currency"),
    asBigInt(tupleItem(value, 5, "cumulativeAtOpen")),
    asBigInt(tupleItem(value, 6, "amount")),
    tupleItem(value, 7, "next"),
  ];
  const valid = typeof result[0] === "string" && result[1] !== undefined && result[2] !== undefined && result[3] !== undefined && typeof result[4] === "string" && result[5] !== undefined && result[6] !== undefined && typeof result[7] === "string";
  return valid ? (result as unknown as BondTuple) : undefined;
}

function topicAddress(value?: string): Address | undefined {
  if (!value || value.length < 42) return undefined;
  return `0x${value.slice(-40)}` as Address;
}

function decodeOpenedLog(log: RpcLog): UserBond | undefined {
  const topics = log.topics ?? [];
  if (topics.length < 4 || !log.data || !log.blockNumber || !topics[2]) return undefined;
  const owner = topicAddress(topics[3]);
  if (!owner) return undefined;
  try {
    const [currency, amount, tickBefore, tickAfter, maturesAtBlock] = decodeAbiParameters(
      [
        { type: "address" },
        { type: "uint128" },
        { type: "int24" },
        { type: "int24" },
        { type: "uint48" },
      ],
      log.data as Hex,
    );
    const block = BigInt(log.blockNumber);
    const normalized = [asBigInt(amount), asBigInt(tickBefore), asBigInt(tickAfter), asBigInt(maturesAtBlock)];
    if (normalized.some((value) => value === undefined)) return undefined;
    return {
      id: topics[2] as Hex,
      owner,
      openBlock: block,
      tickBefore: normalized[1] as bigint,
      tickAfter: normalized[2] as bigint,
      currency: currency as Address,
      amount: normalized[0] as bigint,
      maturesAtBlock: normalized[3] as bigint,
      hash: log.transactionHash as Hex | undefined,
    };
  } catch {
    return undefined;
  }
}

function decodeSettledLog(log: RpcLog): { id: Hex; owner: Address; settlement: Settlement } | undefined {
  const topics = log.topics ?? [];
  if (topics.length < 4 || !log.data || !log.blockNumber || !topics[2]) return undefined;
  const owner = topicAddress(topics[3]);
  if (!owner) return undefined;
  try {
    const [settler, refundAmount, slashAmount, settlerFee, twaReference, persistenceBps] = decodeAbiParameters(
      [
        { type: "address" },
        { type: "uint128" },
        { type: "uint128" },
        { type: "uint128" },
        { type: "int24" },
        { type: "uint16" },
      ],
      log.data as Hex,
    );
    const values = [asBigInt(refundAmount), asBigInt(slashAmount), asBigInt(settlerFee), asBigInt(twaReference), asBigInt(persistenceBps)];
    if (values.some((value) => value === undefined)) return undefined;
    // `settler` is decoded to validate the event shape even though the UI only needs the
    // settlement outcome. Keeping the decode here makes malformed RPC data non-fatal.
    void settler;
    return {
      id: topics[2] as Hex,
      owner,
      settlement: {
        refundAmount: values[0] as bigint,
        slashAmount: values[1] as bigint,
        settlerFee: values[2] as bigint,
        twaReference: values[3] as bigint,
        persistenceBps: values[4] as bigint,
        block: BigInt(log.blockNumber),
        hash: log.transactionHash as Hex | undefined,
      },
    };
  } catch {
    return undefined;
  }
}

async function rpcRequest<T>(method: string, params: unknown[]): Promise<T> {
  const response = await fetch("/api/rpc", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
  });
  if (!response.ok) throw new Error("RPC unavailable");
  const payload = (await response.json()) as { result?: T; error?: { message?: string } };
  if (payload.error || payload.result === undefined) throw new Error(payload.error?.message ?? "RPC request failed");
  return payload.result;
}

function poolKey() {
  return {
    currency0: deployment.currency0,
    currency1: deployment.currency1,
    fee: deployment.poolFee,
    tickSpacing: deployment.tickSpacing,
    hooks: deployment.hook,
  } as const;
}

function tokenSymbolForCurrency(currency: string) {
  return currency.toLowerCase() === deployment.currency0.toLowerCase() ? "ETH" : currency.toLowerCase() === deployment.currency1.toLowerCase() ? "WETH" : "TOKEN";
}

function tokenDecimalsForCurrency(currency: string) {
  return currency.toLowerCase() === "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238" ? 6 : 18;
}

function bondProgress(bond: Pick<UserBond, "openBlock" | "maturesAtBlock">, currentBlock?: bigint) {
  if (currentBlock === undefined || bond.maturesAtBlock <= bond.openBlock) return 0;
  if (currentBlock <= bond.openBlock) return 0;
  if (currentBlock >= bond.maturesAtBlock) return 100;
  return Math.round((Number(currentBlock - bond.openBlock) / Number(bond.maturesAtBlock - bond.openBlock)) * 100);
}

function activityKey(item: Activity) {
  return `${item.kind}:${item.hash ?? item.block}`;
}

function mergeActivity(previous: Activity[], fetched: Activity[]) {
  const fetchedKeys = new Set(fetched.map(activityKey));
  const retained = previous.filter((item) => !fetchedKeys.has(activityKey(item)));
  const merged = [...fetched, ...retained];
  merged.sort((a, b) => {
    const blockA = a.block === "—" ? -1n : BigInt(a.block);
    const blockB = b.block === "—" ? -1n : BigInt(b.block);
    return blockB > blockA ? 1 : blockB < blockA ? -1 : 0;
  });
  return merged.slice(0, MAX_ACTIVITY_ITEMS);
}

function mergeUserBonds(previous: UserBond[], fetched: UserBond[]) {
  const fetchedById = new Map(fetched.map((bond) => [bond.id.toLowerCase(), bond]));
  const merged = fetched.map((bond) => {
    const prior = previous.find((item) => item.id.toLowerCase() === bond.id.toLowerCase());
    // Keep a receipt-reconciled settlement result if the RPC has not indexed it yet.
    return prior?.settlement && !bond.settlement ? { ...bond, settlement: prior.settlement } : bond;
  });
  previous.forEach((bond) => {
    if (!fetchedById.has(bond.id.toLowerCase())) merged.push(bond);
  });
  merged.sort((a, b) => (a.openBlock > b.openBlock ? -1 : a.openBlock < b.openBlock ? 1 : 0));
  return merged;
}

function observedAccumulatorCumulative(accumulator: AccumulatorTuple, currentBlock?: bigint) {
  if (currentBlock === undefined || currentBlock <= accumulator[1]) return accumulator[2];
  return accumulator[2] + accumulator[0] * (currentBlock - accumulator[1]);
}

function previewPersistenceBps(tickBefore: bigint, tickAfter: bigint, referenceTick: bigint, refundTolTicks: bigint) {
  const impact = tickAfter - tickBefore;
  if (impact === 0n) return 0n;
  const impactAbs = impact > 0n ? impact : -impact;
  if (impactAbs <= refundTolTicks) return 0n;
  const direction = impact > 0n ? 1n : -1n;
  const remaining = direction * (referenceTick - tickBefore);
  const numerator = (remaining - refundTolTicks) * 10_000n;
  if (numerator <= 0n) return 0n;
  const raw = numerator / (impactAbs - refundTolTicks);
  return raw >= 10_000n ? 10_000n : raw;
}

function formatToken(value: unknown, decimals = 18, digits = 8) {
  if (typeof value !== "bigint") return "—";
  const formatted = formatUnits(value, decimals);
  const [whole, fraction = ""] = formatted.split(".");
  const trimmed = fraction.slice(0, digits).replace(/0+$/, "");
  if (trimmed) return `${whole}.${trimmed}`;
  if (value > 0n && whole === "0") return `<0.${"0".repeat(Math.max(0, digits - 1))}1`;
  return whole;
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

function StatusDot({ live = false }: { live?: boolean }) {
  return <span className={`status-dot${live ? " status-dot-live" : ""}`} aria-hidden="true" />;
}

function Badge({ children, tone = "neutral" }: { children: React.ReactNode; tone?: "neutral" | "orange" | "green" | "muted" }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

function MetricCard({ label, value, detail, icon, accent = false }: { label: string; value: string; detail: string; icon?: string; accent?: boolean }) {
  return (
    <article className={`metric-card ${accent ? "metric-card-accent" : ""}`}>
      <div className="metric-card-top"><span>{label}</span>{icon && <span className="metric-icon">{icon}</span>}</div>
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

function TokenPicker({ label, token, options, onChange }: { label: string; token: TokenOption; options: TokenOption[]; onChange: (symbol: string) => void }) {
  return (
    <label className="uniswap-token-picker" aria-label={label}>
      <span className={`token-bubble ${token.symbol === "ETH" ? "token-orange" : "token-purple"}`}>{token.icon}</span>
      <strong>{token.symbol}</strong>
      <span className="token-picker-chevron">⌄</span>
      <select value={token.symbol} onChange={(event) => onChange(event.target.value)}>
        {options.map((option) => <option value={option.symbol} key={option.symbol}>{option.symbol}</option>)}
      </select>
    </label>
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
  const swapMode: "exactIn" | "exactOut" = "exactIn";
  const [swapAmount, setSwapAmount] = useState("0.001");
  const [activity, setActivity] = useState<Activity[]>([]);
  const [activityError, setActivityError] = useState(false);
  const [activityStorageReady, setActivityStorageReady] = useState(false);
  const [userBonds, setUserBonds] = useState<UserBond[]>([]);
  const [chainRefresh, setChainRefresh] = useState(0);
  const indexedWalletRef = useRef<string | undefined>(undefined);

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
  const refundTolRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "refundTolTicks",
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
  const claimable0Read = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "claimablePayments",
    args: [address ?? deployment.hook, deployment.currency0],
    query: { enabled: Boolean(address), refetchInterval: 15_000 },
  });
  const claimable1Read = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "claimablePayments",
    args: [address ?? deployment.hook, deployment.currency1],
    query: { enabled: Boolean(address), refetchInterval: 15_000 },
  });

  const bounds = normalizeBounds(boundsRead.data);
  const headId = bounds?.[0];
  const headBondRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    functionName: "getBond",
    args: [deployment.poolId, headId ?? ZERO_HASH],
    query: { enabled: Boolean(headId && headId !== ZERO_HASH), refetchInterval: 8_000 },
  });

  const config = normalizeConfig(configRead.data);
  const accumulator = normalizeAccumulator(accumulatorRead.data);
  const headBond = normalizeBond(headBondRead.data);
  const observationValue = (observationRead as unknown as { data?: unknown }).data;
  const refundTolValue = (refundTolRead as unknown as { data?: unknown }).data;
  const settlerFeeValue = (settlerFeeRead as unknown as { data?: unknown }).data;
  const clampValue = (clampRead as unknown as { data?: unknown }).data;
  const observationBlocks = asBigInt(observationValue) ?? 25n;
  const refundTolTicks = asBigInt(refundTolValue) ?? 10n;
  const settlerFeeBps = asBigInt(settlerFeeValue) ?? 500n;
  const clampTicks = asBigInt(clampValue) ?? 506n;
  const queueLength = typeof queueRead.data === "bigint" ? queueRead.data : 0n;
  const pot0 = typeof pot0Read.data === "bigint" ? pot0Read.data : 0n;
  const pot1 = typeof pot1Read.data === "bigint" ? pot1Read.data : 0n;
  const claimable0 = typeof claimable0Read.data === "bigint" ? claimable0Read.data : 0n;
  const claimable1 = typeof claimable1Read.data === "bigint" ? claimable1Read.data : 0n;
  const totalPot = pot0 + pot1;
  const poolConnected = managerRead.data?.toLowerCase() === deployment.poolManager.toLowerCase();
  const rpcOnline = !managerRead.isError && Boolean(managerRead.data);
  const networkCorrect = chainId === sepolia.id;
  const poolConfigLoading = configRead.isLoading || managerRead.isLoading;
  const poolConfigError = configRead.isError;
  const bondingEnabled = Boolean(config && config[0] > 0n && config[1] > 0n && config[2] > 0n);
  const maturityBlock = headBond ? headBond[1] + observationBlocks : undefined;
  const headCurrency = headBond ? headBond[4].toLowerCase() === deployment.currency0.toLowerCase() ? "ETH" : "WETH" : "ETH";
  const maturityProgress = useMemo(() => {
    if (!headBond || blockNumber === undefined || maturityBlock === undefined) return 0;
    if (blockNumber >= maturityBlock) return 100;
    if (blockNumber <= headBond[1]) return 0;
    return Math.round((Number(blockNumber - headBond[1]) / Number(maturityBlock - headBond[1])) * 100);
  }, [blockNumber, headBond, maturityBlock]);

  useEffect(() => {
    const saved = window.localStorage.getItem("bondmebro-theme") as Theme | null;
    if (saved === "light" || saved === "dark" || saved === "black") setTheme(saved);
  }, []);

  useEffect(() => {
    setActivity((previous) => mergeActivity(previous, readSavedActivity()));
    setActivityStorageReady(true);
  }, []);

  useEffect(() => {
    if (!activityStorageReady) return;
    try {
      window.localStorage.setItem(activityStorageKey, JSON.stringify(activity.slice(0, MAX_ACTIVITY_ITEMS)));
    } catch {
      // Storage can be disabled or full; the live activity stream must still work.
    }
  }, [activity, activityStorageReady]);

  useEffect(() => {
    window.localStorage.setItem("bondmebro-theme", theme);
  }, [theme]);

  useEffect(() => {
    let cancelled = false;
    async function loadChainData() {
      if (!managerRead.data) return;
      try {
        const latestHex = await rpcRequest<string>("eth_blockNumber", []);
        const latest = BigInt(latestHex);
        const fromBlock = latest > 5_000n ? latest - 5_000n : 0n;
        let allLogs: RpcLog[];
        try {
          // Query only this hook address. It is more portable than a topic-0 OR filter
          // across hosted RPC providers, and this hook has a small log surface.
          allLogs = await rpcRequest<RpcLog[]>("eth_getLogs", [{
            address: deployment.hook,
            fromBlock: `0x${fromBlock.toString(16)}`,
            toBlock: `0x${latest.toString(16)}`,
          }]);
        } catch {
          // Keep a provider-specific fallback for nodes that require a topic filter.
          const groupedLogs = await Promise.all(eventDescriptors.map((descriptor) => rpcRequest<RpcLog[]>("eth_getLogs", [{
            address: deployment.hook,
            topics: descriptor.poolScoped ? [descriptor.topic, deployment.poolId] : [descriptor.topic],
            fromBlock: `0x${fromBlock.toString(16)}`,
            toBlock: `0x${latest.toString(16)}`,
          }])));
          allLogs = groupedLogs.flat();
        }
        const logsByEvent = eventDescriptors.map((descriptor) => allLogs.filter((log) => {
          const topics = log.topics ?? [];
          if (topics[0]?.toLowerCase() !== descriptor.topic.toLowerCase()) return false;
          return !descriptor.poolScoped || topics[1]?.toLowerCase() === deployment.poolId.toLowerCase();
        }));

        const nextActivity: Activity[] = [];
        logsByEvent.forEach((logs, index) => {
          const descriptor = eventDescriptors[index];
          logs.slice(-12).forEach((log) => {
            let detail: string = descriptor.detail;
            if (descriptor.kind === "OPENED") {
              const opened = decodeOpenedLog(log);
              if (opened) detail = `Bond opened · ${formatToken(opened.amount)} ${tokenSymbolForCurrency(opened.currency)}`;
            } else if (descriptor.kind === "SETTLED") {
              const settled = decodeSettledLog(log);
              if (settled) detail = `Bond settled · refund ${formatToken(settled.settlement.refundAmount)} · slash ${formatToken(settled.settlement.slashAmount)}`;
            }
            nextActivity.push({
              kind: descriptor.kind,
              block: log.blockNumber ? BigInt(log.blockNumber).toString() : "—",
              hash: log.transactionHash,
              detail,
            });
          });
        });
        nextActivity.sort((a, b) => {
          const blockA = a.block === "—" ? -1n : BigInt(a.block);
          const blockB = b.block === "—" ? -1n : BigInt(b.block);
          return blockB > blockA ? 1 : blockB < blockA ? -1 : 0;
        });

        const bonds = new Map<string, UserBond>();
        const wallet = address?.toLowerCase();
        if (wallet) {
          (logsByEvent[0] ?? []).forEach((log) => {
            const bond = decodeOpenedLog(log);
            if (bond && bond.owner.toLowerCase() === wallet) bonds.set(bond.id.toLowerCase(), bond);
          });
          (logsByEvent[1] ?? []).forEach((log) => {
            const decoded = decodeSettledLog(log);
            if (!decoded || decoded.owner.toLowerCase() !== wallet) return;
            const existing = bonds.get(decoded.id.toLowerCase());
            if (existing) bonds.set(decoded.id.toLowerCase(), { ...existing, settlement: decoded.settlement });
          });
        }
        const nextUserBonds = Array.from(bonds.values()).sort((a, b) => (a.openBlock > b.openBlock ? -1 : a.openBlock < b.openBlock ? 1 : 0));
        const walletChanged = indexedWalletRef.current !== wallet;
        indexedWalletRef.current = wallet;
        if (!cancelled) {
          // Do not blank a confirmed history during a temporary RPC/indexer lag. A wallet
          // change still resets the filter, while a successful response is merged with local receipts.
          setActivity((previous) => mergeActivity(previous, nextActivity));
          if (walletChanged) setUserBonds(nextUserBonds);
          else setUserBonds((previous) => mergeUserBonds(previous, nextUserBonds));
          setActivityError(false);
        }
      } catch {
        if (!cancelled) setActivityError(true);
      }
    }
    void loadChainData();
    const timer = window.setInterval(loadChainData, 30_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [managerRead.data, address, chainRefresh]);

  function recordProtocolActivity(item: Activity) {
    setActivity((previous) => mergeActivity(previous, [item]));
  }

  function recordSettlementConfirmation(item: Activity, bondId?: Hex, settlement?: Settlement) {
    recordProtocolActivity(item);
    if (bondId && settlement) {
      setUserBonds((previous) => previous.map((bond) => bond.id.toLowerCase() === bondId.toLowerCase() ? { ...bond, settlement } : bond));
    }
  }

  function refreshChainData() {
    setChainRefresh((value) => value + 1);
    // Refresh only the state that writes can change. Invalidating every wagmi query made
    // the post-transaction screen wait on unrelated metadata reads as well.
    void Promise.all([
      queueRead.refetch(),
      boundsRead.refetch(),
      pot0Read.refetch(),
      pot1Read.refetch(),
      claimable0Read.refetch(),
      claimable1Read.refetch(),
    ]);
  }

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

        <div className="sidebar-section-label sidebar-flow-label">PROTOCOL FLOW</div>
        <div className="sidebar-flow-card" aria-label="BondMeBro flow">
          <div className={`sidebar-flow-step ${screen === "swap" ? "sidebar-flow-step-active" : ""}`}><span>01</span><div><strong>Swap</strong><small>Quote</small></div><i>↕</i></div>
          <div className={`sidebar-flow-step ${screen === "bonds" ? "sidebar-flow-step-active" : ""}`}><span>02</span><div><strong>Bond</strong><small>Bond</small></div><i>◈</i></div>
          <div className={`sidebar-flow-step ${screen === "bonds" ? "sidebar-flow-step-active" : ""}`}><span>03</span><div><strong>Settle</strong><small>Settle</small></div><i>✓</i></div>
          <div className="sidebar-flow-step"><span>04</span><div><strong>Refund</strong><small>Refund</small></div><i>↗</i></div>
          <div className={`sidebar-flow-step ${screen === "pools" ? "sidebar-flow-step-active" : ""}`}><span>05</span><div><strong>Donate</strong><small>Donate</small></div><i>♢</i></div>
        </div>

        <div className="sidebar-spacer" />
        <div className="sidebar-section-label">NETWORK</div>
        <div className="network-card"><StatusDot live={rpcOnline} /><div><strong>Sepolia</strong><span>Chain {deployment.chainId}</span></div><span className="network-check">{rpcOnline ? "✓" : "!"}</span></div>

        <div className="sidebar-tools">
          <button type="button" onClick={() => setTheme(nextTheme(theme))}><span>{themeIcon(theme)}</span>{themeLabel(theme)}<b>SWITCH</b></button>
          <a href={explorerAddress(deployment.hook)} target="_blank" rel="noreferrer"><span>↗</span>Contract explorer</a>
        </div>
        <div className="sidebar-foot"><span>TESTNET BUILD</span><span>01 / 05</span></div>
      </aside>

      <div className="main-column">
        <header className="topbar">
          <div className="mobile-brand"><div className="brand-symbol">B</div><span>BondMeBro</span></div>
          <div className="topbar-location"><span>APP</span><i>/</i><strong>{navItems.find((item) => item.id === screen)?.label}</strong></div>
          <div className="topbar-actions">
            <button type="button" className={`rpc-chip ${rpcOnline ? "" : "rpc-chip-offline"}`} onClick={refreshChainData} title="Refresh chain data"><StatusDot live={rpcOnline} />{rpcOnline ? "Live data" : "RPC offline · retry"}</button>
            {!isConnected ? (
              <button className="wallet-button primary-button" type="button" onClick={connectWallet} disabled={isConnecting}>{isConnecting ? "Connecting…" : "Connect wallet"}</button>
            ) : !networkCorrect ? (
              <button className="wallet-button primary-button" type="button" onClick={() => switchChain({ chainId: sepolia.id })}>Switch to Sepolia</button>
            ) : (
              <button className="wallet-button" type="button" onClick={() => disconnect()}><StatusDot live />{formatAddress(address)}</button>
            )}
          </div>
        </header>

        <section className="protocol-status-bar" aria-label="Protocol status" aria-live="polite">
          <div className="protocol-status-intro"><span className={`protocol-pulse ${rpcOnline ? "protocol-pulse-live" : ""}`} /><div><strong>BondMeBro</strong><small>{rpcOnline ? "Sepolia live" : "RPC wait"}</small></div></div>
          <div className="protocol-status-item"><span>Pool</span><strong>ETH / WETH</strong></div>
          <div className="protocol-status-item"><span>Bond rate</span><strong>{config?.[2]?.toString() ?? "—"} bps</strong></div>
          <div className="protocol-status-item"><span>Observation</span><strong>{observationBlocks.toString()} blocks</strong></div>
          <button type="button" className="protocol-refresh" onClick={refreshChainData}>Sync <span>↻</span></button>
        </section>

        <main className="page-content">
          {screen === "overview" && (
            <>
              <section className="welcome-grid">
                <div className="welcome-copy">
                  <span className="eyebrow">GOOD AFTERNOON / {deployment.networkName.toUpperCase()}</span>
                  <h1>Swap.<br /><em>Settle.</em></h1>
                  <p>Refund or cover.</p>
                  <div className="welcome-actions"><button type="button" className="primary-button large-button" onClick={() => goTo("swap")}>Swap now <span>↗</span></button><button type="button" className="text-button" onClick={() => goTo("learn")}>Learn <span>→</span></button></div>
                </div>
                <div className="hero-visual">
                  <div className="hero-orb"><span>01</span><div className="orb-ring orb-ring-one" /><div className="orb-ring orb-ring-two" /><div className="orb-dot" /></div>
                  <div className="floating-card floating-swap"><div className="floating-card-label">SWAP PREVIEW <span>↗</span></div><div className="floating-token-row"><div className="token-bubble token-orange">Ξ</div><div><strong>0.001 ETH</strong><span>ETH → WETH / exact input</span></div><b>→</b></div><div className="floating-result"><span>EST. BOND</span><strong>0.0000025 ETH</strong></div></div>
                  <div className="floating-card floating-status"><div className="floating-card-label">BOND STATUS</div><div className="status-line"><StatusDot live /><strong>Active</strong><span>maturing</span></div></div>
                </div>
              </section>

              <section className="metric-grid">
                <MetricCard label="BONDED VALUE" value={headBond ? `${formatToken(headBond[6])} ${headCurrency}` : "0.00 ETH"} detail={headBond ? "queue head" : "clear"} accent />
                <MetricCard label="OPEN BONDS" value={formatInteger(queueLength)} detail="queue" icon="◌" />
                <MetricCard label="POT" value={`${formatToken(pot0)} ETH`} detail={`${formatToken(pot1)} WETH`} icon="♢" />
                <MetricCard label="POOL" value={!rpcOnline ? "OFFLINE" : poolConnected ? "BOUND" : "CHECKING"} detail={bondingEnabled ? "enabled" : "pending"} icon="⌁" />
              </section>

              <section className="content-grid overview-grid">
                <article className="neo-card active-bonds-card">
                  <div className="card-heading"><div><span className="eyebrow">01 / PORTFOLIO</span><h2>Active bonds</h2></div><button className="card-link" type="button" onClick={() => goTo("bonds")}>View all <span>→</span></button></div>
                  {headBond ? <div className="bond-table"><div className="bond-table-head"><span>POOL</span><span>BOND</span><span>MATURITY</span><span>STATUS</span></div><div className="bond-table-row"><div className="pool-cell"><div><strong>ETH / WETH</strong><small>{shortenHash(headId ?? ZERO_HASH, 7, 5)}</small></div></div><strong className="orange-text">{formatToken(headBond[6])} {headCurrency}</strong><div><strong>Block {formatBlock(maturityBlock)}</strong><small>opened {formatBlock(headBond[1])}</small></div><Badge tone={maturityProgress >= 100 ? "orange" : "neutral"}>{maturityProgress >= 100 ? "READY" : "ACTIVE"}</Badge></div></div> : <div className="empty-card active-bonds-empty"><strong>No active bonds</strong><span>New bonds appear here.</span><button type="button" className="text-button" onClick={() => goTo("swap")}>Preview a swap →</button></div>}
                  <div className="card-footer"><span>{queueLength > 0n ? `${formatInteger(queueLength)} bond${queueLength === 1n ? "" : "s"} in queue` : "Queue is clear"}</span><span className="footer-status"><StatusDot live={rpcOnline} /> synced</span></div>
                </article>
                <article className="glass-card portfolio-card">
                  <div className="card-heading"><div><span className="eyebrow">02 / PROTOCOL</span><h2>Portfolio summary</h2></div><Badge tone="green"><StatusDot live /> TESTNET</Badge></div>
                  <div className="portfolio-total"><span>INSURANCE POT / ETH</span><strong>{formatToken(pot0)} <small>ETH</small></strong></div>
                  <div className="stacked-bar"><span style={{ width: totalPot > 0n ? "58%" : "4%" }} /><span style={{ width: pot0 > 0n ? "24%" : "3%" }} /></div>
                  <div className="legend-row"><span><i className="dot-orange" />WETH pot <b>{formatToken(pot1)} WETH</b></span><span><i className="dot-warm" />ETH pot <b>{formatToken(pot0)} ETH</b></span></div>
                  <div className="summary-list"><div><span>Bond rate</span><strong>{config?.[2]?.toString() ?? "—"} bps</strong></div><div><span>Observation</span><strong>{observationBlocks.toString()} blocks</strong></div><div><span>Settler reward</span><strong>{settlerFeeBps.toString()} bps</strong></div></div>
                  <button type="button" className="outline-button full-button" onClick={() => goTo("pools")}>View pool analytics <span>→</span></button>
                </article>
              </section>

              <section className="process-strip"><div><span className="eyebrow">FLOW</span><h2>Swap <i>→</i> Bond <i>→</i> Settle</h2></div><button type="button" className="round-arrow" onClick={() => goTo("learn")}>↗</button></section>
              <ActivityPreview activity={activity} activityError={activityError} onViewAll={() => goTo("activity")} />
            </>
          )}

          {screen === "swap" && <SwapScreen isConnected={isConnected} address={address} networkCorrect={networkCorrect} poolConfig={config} rpcOnline={rpcOnline} poolConfigLoading={poolConfigLoading} poolConfigError={poolConfigError} onSwitchNetwork={() => switchChain({ chainId: sepolia.id })} swapMode={swapMode} swapAmount={swapAmount} setSwapAmount={setSwapAmount} onConnect={connectWallet} onViewBonds={() => goTo("bonds")} onProtocolActivity={recordProtocolActivity} onSwapConfirmed={refreshChainData} />}
          {screen === "bonds" && <BondsScreen headBond={headBond} headId={headId} queueLength={queueLength} maturityBlock={maturityBlock} maturityProgress={maturityProgress} currentBlock={blockNumber} headCurrency={headCurrency} accumulator={accumulator} refundTolTicks={refundTolTicks} userBonds={userBonds} isConnected={isConnected} networkCorrect={networkCorrect} claimable0={claimable0} claimable1={claimable1} onRefresh={refreshChainData} onSettlementConfirmed={recordSettlementConfirmation} onProtocolActivity={recordProtocolActivity} onConnect={connectWallet} onSwitchNetwork={() => switchChain({ chainId: sepolia.id })} onSwap={() => goTo("swap")} />}
          {screen === "pools" && <PoolsScreen config={config} accumulator={accumulator} clampTicks={clampTicks} observationBlocks={observationBlocks} settlerFeeBps={settlerFeeBps} queueLength={queueLength} pot0={pot0} pot1={pot1} poolConnected={poolConnected} owner={ownerRead.data} rpcOnline={rpcOnline} isConnected={isConnected} networkCorrect={networkCorrect} onRefresh={refreshChainData} onProtocolActivity={recordProtocolActivity} onConnect={connectWallet} onSwitchNetwork={() => switchChain({ chainId: sepolia.id })} />}
          {screen === "activity" && <ActivityScreen activity={activity} activityError={activityError} onRefresh={refreshChainData} />}
          {screen === "learn" && <LearnScreen onSwap={() => goTo("swap")} />}
        </main>
        <footer className="page-footer"><span>BondMeBro / outcome-linked LP insurance</span><span>TESTNET BUILD / SEPOLIA</span></footer>
      </div>

      <nav className="mobile-nav" aria-label="Mobile navigation">{navItems.slice(0, 5).map((item) => <button key={item.id} type="button" className={screen === item.id ? "mobile-nav-active" : ""} onClick={() => goTo(item.id)}><span>{item.icon}</span>{item.label}</button>)}</nav>
    </div>
  );
}

function ActivityPreview({ activity, activityError, onViewAll }: { activity: Activity[]; activityError: boolean; onViewAll: () => void }) {
  return (
    <section className="activity-preview"><div className="card-heading"><div><span className="eyebrow">03 / ACTIVITY</span><h2>Recent activity</h2></div><button type="button" className="card-link" onClick={onViewAll}>View activity <span>→</span></button></div>{activity.length === 0 ? <div className="inline-empty">{activityError ? "RPC unavailable." : "No recent events."}</div> : <>{activityError && <div className="inline-empty activity-cache-note">Showing saved activity.</div>}<div className="activity-rows">{activity.slice(0, 4).map((item, index) => <a className="activity-row" href={item.hash ? explorerTx(item.hash) : "#"} target="_blank" rel="noreferrer" key={`${item.kind}-${item.block}-${index}`}><span className={`event-icon event-${item.kind.toLowerCase()}`}>{item.kind === "OPENED" ? "◈" : item.kind === "SETTLED" ? "✓" : item.kind === "DONATED" ? "♢" : item.kind === "CLAIMED" ? "$" : item.kind === "DEFERRED" ? "!" : "⌁"}</span><div><strong>{item.detail}</strong><small>Block {item.block}</small></div><span className="activity-row-hash">{item.hash ? shortenHash(item.hash) : "—"} ↗</span></a>)}</div></>}</section>
  );
}

function SwapScreen({
  isConnected,
  address,
  networkCorrect,
  poolConfig,
  rpcOnline,
  poolConfigLoading,
  poolConfigError,
  onSwitchNetwork,
  swapMode,
  swapAmount,
  setSwapAmount,
  onConnect,
  onViewBonds,
  onProtocolActivity,
  onSwapConfirmed,
}: {
  isConnected: boolean;
  address?: Address;
  networkCorrect: boolean;
  poolConfig?: ConfigTuple;
  rpcOnline: boolean;
  poolConfigLoading: boolean;
  poolConfigError: boolean;
  onSwitchNetwork: () => void;
  swapMode: "exactIn" | "exactOut";
  swapAmount: string;
  setSwapAmount: (value: string) => void;
  onConnect: () => void;
  onViewBonds: () => void;
  onProtocolActivity: (item: Activity) => void;
  onSwapConfirmed: () => void;
}) {
  const [paySymbol, setPaySymbol] = useState("ETH");
  const [receiveSymbol, setReceiveSymbol] = useState("WETH");
  const [minimumOutput, setMinimumOutput] = useState("");
  const [minimumOutputEdited, setMinimumOutputEdited] = useState(false);
  const [transactionState, setTransactionState] = useState<TransactionState>("idle");
  const [transactionHash, setTransactionHash] = useState<Hex | undefined>();
  const [transactionError, setTransactionError] = useState("");
  const publicClient = usePublicClient({ chainId: sepolia.id });
  const { writeContractAsync } = useWriteContract();
  const swapTokenOptions = tokenOptions;

  const payToken = swapTokenOptions.find((token) => token.symbol === paySymbol) ?? swapTokenOptions[0];
  const receiveToken = swapTokenOptions.find((token) => token.symbol === receiveSymbol) ?? swapTokenOptions[1];
  const amountIn = parseSwapAmount(swapAmount, payToken.decimals);
  const minimumAmountOut = parseSwapAmount(minimumOutput, receiveToken.decimals) ?? 0n;
  const bondBps = poolConfig?.[2] ?? 0n;
  const estimatedBond = amountIn && bondBps > 0n ? (amountIn * bondBps) / 10_000n : 0n;
  const activePair = isConfiguredPair(payToken, receiveToken, deployment.currency0, deployment.currency1);
  const zeroForOne = payToken.address.toLowerCase() === deployment.currency0.toLowerCase();
  const supportedDirection = activePair && (zeroForOne
    ? receiveToken.address.toLowerCase() === deployment.currency1.toLowerCase()
    : receiveToken.address.toLowerCase() === deployment.currency0.toLowerCase());
  const nativeBalance = useBalance({
    address,
    chainId: sepolia.id,
    query: { enabled: Boolean(address && payToken.kind === "native"), refetchInterval: 10_000 },
  });
  const tokenBalanceRead = useReadContract({
    address: payToken.address,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [address ?? deployment.hook],
    query: { enabled: Boolean(address && payToken.kind === "erc20"), refetchInterval: 10_000 },
  });
  const tokenAllowanceRead = useReadContract({
    address: payToken.address,
    abi: erc20Abi,
    functionName: "allowance",
    args: [address ?? deployment.hook, deployment.permit2],
    query: { enabled: Boolean(address && payToken.kind === "erc20"), refetchInterval: 10_000 },
  });
  const permit2AllowanceRead = useReadContract({
    address: deployment.permit2,
    abi: permit2Abi,
    functionName: "allowance",
    args: [address ?? deployment.hook, payToken.address, deployment.universalRouter],
    query: { enabled: Boolean(address && payToken.kind === "erc20"), refetchInterval: 10_000 },
  });
  const payBalance = payToken.kind === "native" ? nativeBalance.data?.value : tokenBalanceRead.data as bigint | undefined;
  const tokenAllowance = typeof tokenAllowanceRead.data === "bigint" ? tokenAllowanceRead.data : 0n;
  const permit2AllowanceAmount = asBigInt(tupleItem(permit2AllowanceRead.data, 0, "amount")) ?? 0n;
  const permit2AllowanceExpiration = asBigInt(tupleItem(permit2AllowanceRead.data, 1, "expiration")) ?? 0n;
  const permit2Live = permit2AllowanceExpiration > BigInt(Math.floor(Date.now() / 1000) + 60);
  const tokenSpendingReady = payToken.kind === "native" || (amountIn !== undefined && tokenAllowance >= amountIn && permit2AllowanceAmount >= amountIn && permit2Live);
  const maxBondAmount = estimatedBond > 0n ? estimatedBond + estimatedBond / 10n + 1n : 1n;
  const routerConfigured = deployment.universalRouter.toLowerCase() !== ZERO_ADDRESS;
  const quoterConfigured = deployment.quoter.toLowerCase() !== ZERO_ADDRESS;
  const quoteHookData = encodeBondHookData(address ?? deployment.hook, maxBondAmount);
  const quoteArgs = useMemo(
    () => [{
      poolKey: {
        currency0: deployment.currency0,
        currency1: deployment.currency1,
        fee: deployment.poolFee,
        tickSpacing: deployment.tickSpacing,
        hooks: deployment.hook,
      },
      zeroForOne,
      exactAmount: amountIn ?? 0n,
      hookData: quoteHookData,
    }] as const,
    [amountIn, quoteHookData, zeroForOne],
  );
  const quoteEnabled = Boolean(
    isConnected
    && networkCorrect
    && rpcOnline
    && !poolConfigLoading
    && !poolConfigError
    && swapMode === "exactIn"
    && supportedDirection
    && amountIn !== undefined
    && amountIn > 0n
    && quoterConfigured,
  );
  const quoteRead = useReadContract({
    address: deployment.quoter,
    abi: v4QuoterAbi,
    functionName: "quoteExactInputSingle",
    args: quoteArgs,
    query: {
      enabled: quoteEnabled,
      refetchInterval: 5_000,
    },
  });
  const quoteAmountOut = quoteEnabled && swapMode === "exactIn"
    ? asBigInt(tupleItem(quoteRead.data, 0, "amountOut"))
    : undefined;
  const quoteLoading = quoteEnabled && (quoteRead.isLoading || quoteRead.isFetching);
  const quoteError = quoteEnabled && quoteRead.isError;
  const quoteHasNoLiquidity = quoteEnabled
    && !quoteLoading
    && (quoteAmountOut === 0n || (quoteError && isLiquidityQuoteError(quoteRead.error)));
  const quoteReady = quoteEnabled
    && !quoteLoading
    && !quoteError
    && quoteAmountOut !== undefined
    && quoteAmountOut > 0n;
  const amountFitsBalance = payBalance === undefined || (amountIn !== undefined && amountIn <= payBalance);

  useEffect(() => {
    setMinimumOutputEdited(false);
    setMinimumOutput("");
  }, [swapAmount, paySymbol, receiveSymbol, swapMode]);

  useEffect(() => {
    if (minimumOutputEdited) return;

    if (
      swapMode !== "exactIn"
      || !quoteEnabled
      || quoteRead.isError
      || quoteAmountOut === undefined
      || quoteAmountOut <= 0n
    ) {
      setMinimumOutput("");
      return;
    }

    // Keep the existing 0.50% protection while using the live v4 quote as the source
    // amount. The editable field lets an advanced user tighten the bound explicitly.
    if (quoteRead.isFetching) return;
    const protectedOutput = (quoteAmountOut * 9_950n) / 10_000n;
    setMinimumOutput(formatUnits(protectedOutput, receiveToken.decimals));
  }, [
    amountIn,
    minimumOutputEdited,
    paySymbol,
    quoteAmountOut,
    quoteEnabled,
    quoteRead.isError,
    quoteRead.isFetching,
    receiveToken.decimals,
    swapMode,
  ]);

  const canSubmit = isConnected && networkCorrect && rpcOnline && !poolConfigLoading && !poolConfigError && swapMode === "exactIn" && supportedDirection && routerConfigured && bondingEnabledForSwap(poolConfig) && amountIn !== undefined && amountIn > 0n && quoteReady && minimumAmountOut > 0n && amountFitsBalance && tokenSpendingReady && transactionState !== "approving" && transactionState !== "sending";
  const actionDisabled = transactionState === "approving" || transactionState === "sending" || (isConnected && networkCorrect && !canSubmit);
  const status = getSwapStatus({ isConnected, networkCorrect, rpcOnline, poolConfigLoading, poolConfigError, supportedDirection, routerConfigured, quoterConfigured, poolConfig, amountIn, minimumAmountOut, amountFitsBalance, payBalance, payTokenKind: payToken.kind, tokenSpendingReady, swapMode, quoteLoading, quoteError, quoteHasNoLiquidity, quoteAmountOut, transactionState });

  function choosePayToken(symbol: string) {
    if (symbol === receiveSymbol) setReceiveSymbol(paySymbol);
    setPaySymbol(symbol);
  }

  function chooseReceiveToken(symbol: string) {
    if (symbol === paySymbol) setPaySymbol(receiveSymbol);
    setReceiveSymbol(symbol);
  }

  async function prepareTokenSpending() {
    if (!address || !publicClient || payToken.kind !== "erc20" || amountIn === undefined || amountIn <= 0n) return;
    setTransactionState("approving");
    setTransactionError("");
    try {
      if (tokenAllowance < amountIn) {
        const tokenApproval = await writeContractAsync({
          address: payToken.address,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.permit2, amountIn],
        });
        await publicClient.waitForTransactionReceipt({ hash: tokenApproval });
      }
      if (permit2AllowanceAmount < amountIn || !permit2Live) {
        const permitApproval = await writeContractAsync({
          address: deployment.permit2,
          abi: permit2Abi,
          functionName: "approve",
          args: [payToken.address, deployment.universalRouter, MAX_UINT160, Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60],
        });
        await publicClient.waitForTransactionReceipt({ hash: permitApproval });
      }
      await Promise.all([tokenAllowanceRead.refetch(), permit2AllowanceRead.refetch()]);
      setTransactionState("idle");
    } catch (error) {
      setTransactionState("error");
      setTransactionError(friendlyTransactionError(error));
    }
  }

  async function submitSwap() {
    if (!canSubmit || !address || !publicClient || amountIn === undefined) return;
    setTransactionState("idle");
    setTransactionError("");
    setTransactionHash(undefined);
    try {
      const plan = encodeExactInputRouterPlan({
        currency0: deployment.currency0,
        currency1: deployment.currency1,
        hooks: deployment.hook,
        fee: deployment.poolFee,
        tickSpacing: deployment.tickSpacing,
        zeroForOne,
        amountIn,
        amountOutMinimum: minimumAmountOut,
        refundRecipient: address,
        maxBondAmount,
      });
      setTransactionState("sending");
      const hash = await writeContractAsync({
        address: deployment.universalRouter,
        abi: universalRouterAbi,
        functionName: "execute",
        args: [plan.commands, plan.inputs, BigInt(Math.floor(Date.now() / 1000) + 1_200)],
        value: payToken.kind === "native" ? amountIn : 0n,
      });
      setTransactionHash(hash);
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      const openedReceiptLog = receipt.logs.find((log) => log.address.toLowerCase() === deployment.hook.toLowerCase() && log.topics[0]?.toLowerCase() === eventDescriptors[0].topic.toLowerCase());
      if (openedReceiptLog) {
        const opened = decodeOpenedLog({
          topics: [...openedReceiptLog.topics],
          data: openedReceiptLog.data,
          blockNumber: `0x${receipt.blockNumber.toString(16)}`,
          transactionHash: hash,
        });
        if (opened) onProtocolActivity({ kind: "OPENED", block: receipt.blockNumber.toString(), hash, detail: `Bond opened · ${formatToken(opened.amount)} ${tokenSymbolForCurrency(opened.currency)}` });
      }
      setTransactionState("success");
      onSwapConfirmed();
    } catch (error) {
      setTransactionState("error");
      setTransactionError(friendlyTransactionError(error));
    }
  }

  return (
    <div className="swap-screen-uniswap swap-screen-minimal">
      <section className="swap-layout swap-layout-uniswap swap-layout-solo">
        <article className="neo-card swap-card">
          <div className="swap-token-panel swap-sell-panel"><div className="field-label uniswap-field-label"><span>Sell</span><span>Balance {payBalance === undefined ? "—" : `${formatToken(payBalance, payToken.decimals)} ${payToken.symbol}`}</span></div><div className="amount-line uniswap-amount-line"><input aria-label="Swap amount" value={swapAmount} onChange={(event) => setSwapAmount(event.target.value)} inputMode="decimal" placeholder="0.00" /><TokenPicker label="Pay token" token={payToken} options={swapTokenOptions} onChange={choosePayToken} /></div></div>
          <button type="button" className="direction-button swap-direction-button" aria-label="Switch swap direction" onClick={() => { const oldPay = paySymbol; setPaySymbol(receiveSymbol); setReceiveSymbol(oldPay); }}>↕</button>
          <div className="swap-token-panel swap-buy-panel"><div className="field-label uniswap-field-label"><span>Buy</span><span>{quoteLoading ? "Quoting…" : "Output"}</span></div><div className="amount-line uniswap-amount-line"><strong className="quoted-output-value" aria-live="polite">{quoteAmountOut !== undefined && quoteAmountOut > 0n && !quoteError ? formatToken(quoteAmountOut, receiveToken.decimals) : quoteLoading ? "…" : "—"}</strong><TokenPicker label="Receive token" token={receiveToken} options={swapTokenOptions} onChange={chooseReceiveToken} /></div><div className="minimum-output-control"><div><span>Minimum received</span><small>0.50%</small></div><input aria-label="Minimum output" value={minimumOutput} onChange={(event) => { setMinimumOutput(event.target.value); setMinimumOutputEdited(true); }} inputMode="decimal" placeholder="0" /></div></div>
          {!rpcOnline && <div className="pair-warning">RPC offline.</div>}{rpcOnline && poolConfigLoading && <div className="pair-warning">Reading pool…</div>}{rpcOnline && poolConfigError && <div className="pair-warning">Pool unavailable.</div>}{swapMode === "exactIn" && quoteHasNoLiquidity && <div className="pair-warning">No liquidity.</div>}{swapMode === "exactIn" && quoteError && !quoteHasNoLiquidity && <div className="pair-warning">Quote unavailable.</div>}{swapMode === "exactIn" && quoteReady && minimumAmountOut === 0n && <div className="pair-warning">Set minimum.</div>}{!supportedDirection && <div className="pair-warning">Only ETH/WETH is live. Other coins need pools.</div>}{payToken.kind === "erc20" && supportedDirection && amountIn !== undefined && amountIn > 0n && !tokenSpendingReady && <div className="pair-warning">Approve {payToken.symbol} once.</div>}
          <div className={`swap-status swap-status-${status.tone}`}><StatusDot live={status.tone === "ready" || status.tone === "success"} /><div><strong>{status.title}</strong><span>{status.detail}</span></div></div>
          {payToken.kind === "erc20" && supportedDirection && amountIn !== undefined && amountIn > 0n && !tokenSpendingReady && isConnected && networkCorrect && <button type="button" className="outline-button full-button prepare-token-button" disabled={transactionState === "approving" || transactionState === "sending"} onClick={() => void prepareTokenSpending()}>{transactionState === "approving" ? `Approving ${payToken.symbol}…` : `Approve ${payToken.symbol} once`}</button>}
          <button type="button" className="primary-button large-button full-button swap-submit-button" disabled={actionDisabled} onClick={() => { if (!isConnected) onConnect(); else if (!networkCorrect) onSwitchNetwork(); else void submitSwap(); }}>{transactionState === "approving" ? `Approving ${payToken.symbol}…` : transactionState === "sending" ? "Confirming…" : transactionState === "success" ? "Done" : !isConnected ? "Connect wallet" : !networkCorrect ? "Switch to Sepolia" : !rpcOnline ? "RPC offline" : poolConfigLoading ? "Reading pool…" : poolConfigError ? "Retry" : !supportedDirection ? "Pool not live" : !bondingEnabledForSwap(poolConfig) ? "Pool pending" : swapMode === "exactOut" ? "Preview only" : quoteLoading ? "Getting quote" : quoteError || quoteHasNoLiquidity || !quoteReady ? "Quote unavailable" : minimumAmountOut <= 0n ? "Set minimum" : !amountFitsBalance && payBalance !== undefined ? "Insufficient balance" : !tokenSpendingReady ? "Approve first" : "Swap"} <span>→</span></button>
          {transactionState === "error" && <div className="transaction-message transaction-error">{transactionError}</div>}{transactionState === "success" && transactionHash && <div className="transaction-message transaction-success">Confirmed. <a href={explorerTx(transactionHash)} target="_blank" rel="noreferrer">View ↗</a><button type="button" className="text-button success-next-button" onClick={onViewBonds}>Track →</button></div>}
        </article>
      </section>
    </div>
  );
}

function parseSwapAmount(value: string, decimals: number): bigint | undefined {
  const normalized = value.replace(/,/g, "").trim();
  if (!normalized || !/^\d*(\.\d*)?$/.test(normalized)) return undefined;
  try {
    return parseUnits(normalized, decimals);
  } catch {
    return undefined;
  }
}

function bondingEnabledForSwap(config?: ConfigTuple) {
  return Boolean(config && config[0] > 0n && config[1] > 0n && config[2] > 0n);
}

function isLiquidityQuoteError(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  const lower = message.toLowerCase();
  return lower.includes("notenoughliquidity")
    || lower.includes("insufficient liquidity")
    || lower.includes("no liquidity");
}

function friendlyTransactionError(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  if (message.toLowerCase().includes("user rejected")) return "The wallet rejected the transaction.";
  if (message.toLowerCase().includes("insufficient")) return "The wallet does not have enough balance for this swap and gas.";
  if (message.toLowerCase().includes("bondslippage")) return "The estimated bond exceeded the maximum accepted bond.";
  return "The transaction could not be completed. Open the browser console for technical details.";
}

function friendlyProtocolError(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  const lower = message.toLowerCase();
  if (lower.includes("user rejected") || lower.includes("user denied")) return "The wallet rejected the transaction.";
  if (lower.includes("insufficient funds") || lower.includes("insufficient balance")) return "The wallet does not have enough ETH for this transaction and gas.";
  if (lower.includes("nothingtodonate")) return "There is no insurance pot to distribute yet.";
  if (lower.includes("nothingtoclaim")) return "This wallet has no deferred payment for that currency.";
  if (lower.includes("no in-range") || lower.includes("insufficient liquidity") || lower.includes("liquidity")) return "The pool has no usable in-range liquidity for this distribution right now.";
  if (lower.includes("not mature") || lower.includes("maturity")) return "The bond has not reached its observation checkpoint yet.";
  if (lower.includes("settlementreentrancy")) return "Settlement was already in progress. Wait for the next block and retry.";
  return "The protocol rejected this transaction. Check the selected network and try again.";
}

function getSwapStatus({
  isConnected,
  networkCorrect,
  rpcOnline,
  poolConfigLoading,
  poolConfigError,
  supportedDirection,
  routerConfigured,
  quoterConfigured,
  poolConfig,
  amountIn,
  minimumAmountOut,
  amountFitsBalance,
  payBalance,
  payTokenKind,
  tokenSpendingReady,
  swapMode,
  quoteLoading,
  quoteError,
  quoteHasNoLiquidity,
  quoteAmountOut,
  transactionState,
}: {
  isConnected: boolean;
  networkCorrect: boolean;
  rpcOnline: boolean;
  poolConfigLoading: boolean;
  poolConfigError: boolean;
  supportedDirection: boolean;
  routerConfigured: boolean;
  quoterConfigured: boolean;
  poolConfig?: ConfigTuple;
  amountIn?: bigint;
  minimumAmountOut: bigint;
  amountFitsBalance: boolean;
  payBalance?: bigint;
  payTokenKind: TokenOption["kind"];
  tokenSpendingReady: boolean;
  swapMode: "exactIn" | "exactOut";
  quoteLoading: boolean;
  quoteError: boolean;
  quoteHasNoLiquidity: boolean;
  quoteAmountOut?: bigint;
  transactionState: TransactionState;
}) {
  if (transactionState === "approving") return { tone: "pending", title: "Token approval", detail: "Approve once, then one-confirm swap." };
  if (transactionState === "sending") return { tone: "pending", title: "Confirm swap", detail: "One Universal Router transaction is being submitted." };
  if (transactionState === "success") return { tone: "success", title: "Swap confirmed", detail: "Indexing bond event." };
  if (transactionState === "error") return { tone: "error", title: "Swap not completed", detail: "Check message and retry." };
  if (!isConnected) return { tone: "warning", title: "Connect your wallet", detail: "Wallet is payer and recipient." };
  if (!networkCorrect) return { tone: "warning", title: "Switch to Sepolia", detail: "Use Sepolia." };
  if (!rpcOnline) return { tone: "warning", title: "RPC offline", detail: "Retry RPC." };
  if (poolConfigLoading) return { tone: "pending", title: "Reading pool configuration", detail: "Reading hook config." };
  if (poolConfigError) return { tone: "error", title: "Pool configuration unavailable", detail: "Retry RPC." };
  if (!supportedDirection) return { tone: "warning", title: "Pool not configured", detail: "Live pool: ETH/WETH only." };
  if (!routerConfigured) return { tone: "warning", title: "Router address missing", detail: "Set router address." };
  if (!bondingEnabledForSwap(poolConfig)) return { tone: "warning", title: "Pool configuration pending", detail: "Enable pool config." };
  if (amountIn === undefined || amountIn <= 0n) return { tone: "warning", title: "Enter an amount", detail: "Enter amount." };
  if (swapMode === "exactOut") return { tone: "warning", title: "Exact-output preview", detail: "Preview only." };
  if (!quoterConfigured) return { tone: "warning", title: "Quoter address missing", detail: "Set Quoter address." };
  if (quoteLoading) return { tone: "pending", title: "Getting live quote", detail: "Quoting route." };
  if (quoteHasNoLiquidity) return { tone: "warning", title: "Pool has no liquidity", detail: "No liquidity." };
  if (quoteError) return { tone: "error", title: "Quote unavailable", detail: "Quote failed." };
  if (quoteAmountOut === undefined) return { tone: "error", title: "Quote unavailable", detail: "Wait for quote." };
  if (minimumAmountOut <= 0n && transactionState === "idle") return { tone: "warning", title: "Set minimum output", detail: "Set minimum." };
  if (!amountFitsBalance && payBalance !== undefined) return { tone: "warning", title: "Insufficient balance", detail: "Low balance." };
  if (payTokenKind === "erc20" && !tokenSpendingReady) return { tone: "warning", title: "Approve WETH once", detail: "Approve once, then one-confirm swap." };
  if (transactionState === "idle") return { tone: "ready", title: "Ready", detail: "One confirmation submits." };
  return { tone: "ready", title: "Ready", detail: "Review and swap." };
}

function BondsScreen({
  headBond,
  headId,
  queueLength,
  maturityBlock,
  maturityProgress,
  currentBlock,
  headCurrency,
  accumulator,
  refundTolTicks,
  userBonds,
  isConnected,
  networkCorrect,
  claimable0,
  claimable1,
  onRefresh,
  onSettlementConfirmed,
  onProtocolActivity,
  onConnect,
  onSwitchNetwork,
  onSwap,
}: {
  headBond?: BondTuple;
  headId?: Hex;
  queueLength: bigint;
  maturityBlock?: bigint;
  maturityProgress: number;
  currentBlock?: bigint;
  headCurrency: string;
  accumulator?: AccumulatorTuple;
  refundTolTicks: bigint;
  userBonds: UserBond[];
  isConnected: boolean;
  networkCorrect: boolean;
  claimable0: bigint;
  claimable1: bigint;
  onRefresh: () => void;
  onSettlementConfirmed: (item: Activity, bondId?: Hex, settlement?: Settlement) => void;
  onProtocolActivity: (item: Activity) => void;
  onConnect: () => void;
  onSwitchNetwork: () => void;
  onSwap: () => void;
}) {
  const publicClient = usePublicClient({ chainId: sepolia.id });
  const { writeContractAsync } = useWriteContract();
  const [settlementState, setSettlementState] = useState<ProtocolTransactionState>("idle");
  const [settlementHash, setSettlementHash] = useState<Hex | undefined>();
  const [settlementError, setSettlementError] = useState("");
  const headMatured = Boolean(headBond && maturityProgress >= 100);
  const activeUserBonds = userBonds.filter((bond) => !bond.settlement);
  const settledUserBonds = userBonds.filter((bond) => Boolean(bond.settlement));
  const latestSettled = settledUserBonds[0];
  const liveReferenceTick = headBond && accumulator && currentBlock !== undefined ? (() => {
    const elapsed = currentBlock > headBond[1] ? currentBlock - headBond[1] : 0n;
    if (elapsed === 0n) return undefined;
    const cumulativeNow = observedAccumulatorCumulative(accumulator, currentBlock);
    return (cumulativeNow - headBond[5]) / elapsed;
  })() : undefined;
  const previewPersistence = headBond && liveReferenceTick !== undefined
    ? previewPersistenceBps(headBond[2], headBond[3], liveReferenceTick, refundTolTicks)
    : undefined;
  const previewRefund = headBond && previewPersistence !== undefined
    ? (headBond[6] * (10_000n - previewPersistence)) / 10_000n
    : undefined;

  async function settleMaturedBonds() {
    if (!headMatured || !isConnected || !networkCorrect || !publicClient) return;
    setSettlementState("sending");
    setSettlementHash(undefined);
    setSettlementError("");
    try {
      const hash = await writeContractAsync({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "settleBonds",
        args: [poolKey(), 1n],
      });
      setSettlementHash(hash);
      setSettlementState("submitted");
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      const settledReceiptLog = receipt.logs.find((log) => log.topics[0]?.toLowerCase() === eventDescriptors[1].topic.toLowerCase());
      const decodedReceiptSettlement = settledReceiptLog ? decodeSettledLog({
        topics: [...settledReceiptLog.topics],
        data: settledReceiptLog.data,
        blockNumber: `0x${receipt.blockNumber.toString(16)}`,
        transactionHash: hash,
      }) : undefined;
      const settlementDetail = decodedReceiptSettlement?.settlement
        ? `Bond settled · refund ${formatToken(decodedReceiptSettlement.settlement.refundAmount)} · slash ${formatToken(decodedReceiptSettlement.settlement.slashAmount)}`
        : "Bond settled";
      onSettlementConfirmed(
        { kind: "SETTLED", block: receipt.blockNumber.toString(), hash, detail: settlementDetail },
        decodedReceiptSettlement?.id ?? headId,
        decodedReceiptSettlement?.settlement,
      );
      setSettlementState("success");
      onRefresh();
    } catch (error) {
      setSettlementState("error");
      setSettlementError(friendlyProtocolError(error));
    }
  }

  return (
    <>
      <section className="screen-intro">
        <div><span className="eyebrow">02 / PORTFOLIO</span><h1>My bonds.<br /><em>Track.</em></h1></div>
        <p>Track and settle outcomes.</p>
      </section>
      <section className="bond-summary-grid">
        <MetricCard label="YOUR OPEN BONDS" value={formatInteger(BigInt(activeUserBonds.length))} detail="recent history" icon="◈" accent />
        <MetricCard label="READY TO SETTLE" value={headMatured ? "1" : "0"} detail="FIFO head" icon="✓" />
        <MetricCard label="SETTLED BONDS" value={formatInteger(BigInt(settledUserBonds.length))} detail="settled history" icon="↗" />
      </section>

      <article className="neo-card detail-card">
        <div className="card-heading">
          <div><span className="eyebrow">FIFO HEAD</span><h2>{headBond ? "Settle bond" : "Queue is clear"}</h2></div>
          <Badge tone={headMatured ? "orange" : headBond ? "neutral" : "green"}>{headBond ? headMatured ? "READY" : "ACTIVE" : "CLEAR"}</Badge>
        </div>
        {headBond ? (
          <>
            <div className="detail-hero">
              <div><span className="eyebrow">BOND AMOUNT</span><strong>{formatToken(headBond[6])} <small>{headCurrency}</small></strong></div>
              <div className="detail-id"><span>BOND ID</span><b>{shortenHash(headId ?? ZERO_HASH, 10, 8)}</b></div>
            </div>
            <div className="timeline">
              <div className="timeline-line"><span style={{ width: `${maturityProgress}%` }} /></div>
              <div className="timeline-step timeline-done"><i>✓</i><span>Swap submitted</span><b>Block {formatBlock(headBond[1])}</b></div>
              <div className={headMatured ? "timeline-step timeline-done" : "timeline-step"}><i>{headMatured ? "✓" : "2"}</i><span>Maturity</span><b>Block {formatBlock(maturityBlock)}</b></div>
              <div className={headMatured ? "timeline-step timeline-ready" : "timeline-step"}><i>{headMatured ? "3" : "3"}</i><span>Settlement</span><b>{headMatured ? "Ready" : `${maturityProgress}% complete`}</b></div>
            </div>
            <div className="detail-info-grid">
              <div><span>REFUND RECIPIENT</span><strong>{formatAddress(headBond[0])}</strong></div>
              <div><span>OPENED</span><strong>{formatBlock(headBond[1])}</strong></div>
              <div><span>CURRENT BLOCK</span><strong>{formatBlock(currentBlock)}</strong></div>
              <div><span>IMPACT TICKS</span><strong>{(headBond[3] - headBond[2]).toString()}</strong></div>
            </div>
            {previewPersistence !== undefined && previewRefund !== undefined && liveReferenceTick !== undefined && <div className={`settlement-preview ${previewPersistence === 0n ? "settlement-preview-refund" : ""}`}><div><span>LIVE REFERENCE TICK</span><strong>{liveReferenceTick.toString()}</strong></div><div><span>EST. REFUND IF SETTLED NOW</span><strong>{formatToken(previewRefund, tokenDecimalsForCurrency(headBond[4]))} {headCurrency}</strong></div><div><span>EST. PERSISTENCE</span><strong>{previewPersistence.toString()} bps</strong></div><p>{headBond[3] > headBond[2] ? "A lower reference tick means the upward move is reverting." : "A higher reference tick means the downward move is reverting."} Final refund is calculated at the settlement block and can change with later swaps.</p></div>}
            <div className="detail-actions">
              {!isConnected ? (
                <button type="button" className="primary-button large-button" onClick={onConnect}>Connect wallet <span>→</span></button>
              ) : !networkCorrect ? (
                <button type="button" className="primary-button large-button" onClick={onSwitchNetwork}>Switch to Sepolia <span>→</span></button>
              ) : (
                <button type="button" className="primary-button large-button" disabled={!headMatured || settlementState === "sending" || settlementState === "submitted"} onClick={() => void settleMaturedBonds()}>
                  {settlementState === "sending" ? "Confirm in wallet…" : settlementState === "submitted" ? "Settlement pending…" : settlementState === "success" ? "Settlement confirmed" : headMatured ? "Settle next matured bond" : `Wait ${Math.max(0, Number((maturityBlock ?? 0n) - (currentBlock ?? 0n)))} blocks`} <span>→</span>
                </button>
              )}
              <span>Anyone can settle; fees come from slashes.</span>
            </div>
            {settlementState === "error" && <div className="transaction-message transaction-error">{settlementError}</div>}
            {settlementState === "success" && settlementHash && <div className="transaction-message transaction-success">Confirmed. <a href={explorerTx(settlementHash)} target="_blank" rel="noreferrer">View settlement ↗</a></div>}
          </>
        ) : latestSettled?.settlement ? (
          <div className="empty-card large-empty settled-summary">
            <div className="empty-icon">✓</div><strong>Your latest bond is settled</strong><span>Completed bond history stays below.</span>
            <div className="settled-summary-grid"><div><span>REFUND SENT</span><strong>{formatToken(latestSettled.settlement.refundAmount, tokenDecimalsForCurrency(latestSettled.currency))} {tokenSymbolForCurrency(latestSettled.currency)}</strong></div><div><span>SLASHED TO POT</span><strong>{formatToken(latestSettled.settlement.slashAmount, tokenDecimalsForCurrency(latestSettled.currency))} {tokenSymbolForCurrency(latestSettled.currency)}</strong></div><div><span>SETTLED AT</span><strong>Block {latestSettled.settlement.block.toString()}</strong></div></div>
            <a className="settled-summary-link" href={latestSettled.settlement.hash ? explorerTx(latestSettled.settlement.hash) : "#"} target="_blank" rel="noreferrer">View settlement transaction ↗</a>
          </div>
        ) : settlementState === "success" && settlementHash ? (
          <div className="empty-card large-empty settled-summary">
            <div className="empty-icon">✓</div><strong>Settlement confirmed</strong><span>Waiting for the event index.</span><a className="settled-summary-link" href={explorerTx(settlementHash)} target="_blank" rel="noreferrer">View settlement transaction ↗</a>
          </div>
        ) : (
          <div className="empty-card large-empty">
            <div className="empty-icon">◈</div><strong>Your bond queue is empty</strong><span>New bonds appear after indexing.</span><button type="button" className="primary-button" onClick={onSwap}>Make a swap →</button>
          </div>
        )}
      </article>

      <article className="neo-card user-bonds-card">
        <div className="card-heading"><div><span className="eyebrow">YOUR HISTORY</span><h2>Bond records</h2></div><Badge tone={isConnected ? "green" : "muted"}>{isConnected ? "WALLET FILTERED" : "CONNECT TO FILTER"}</Badge></div>
        {!isConnected ? (
          <div className="inline-empty"><button type="button" className="text-button" onClick={onConnect}>Connect wallet</button> to load bonds.</div>
        ) : userBonds.length === 0 ? (
          <div className="inline-empty">No recent bonds for this wallet.</div>
        ) : (
          <div className="user-bond-list">
            {userBonds.map((bond) => {
              const progress = bondProgress(bond, currentBlock);
              const symbol = tokenSymbolForCurrency(bond.currency);
              const decimals = tokenDecimalsForCurrency(bond.currency);
              const settled = bond.settlement;
              const ready = !settled && progress >= 100;
              return (
                <div className={`user-bond-record ${settled ? "user-bond-settled" : ""}`} key={bond.id}>
                  <div className="user-bond-record-top">
                    <div><span className="bond-record-pair">ETH / WETH</span><strong>{shortenHash(bond.id, 9, 7)}</strong></div>
                    <Badge tone={settled ? "green" : ready ? "orange" : "neutral"}>{settled ? "SETTLED" : ready ? "READY" : "ACTIVE"}</Badge>
                  </div>
                  <div className="user-bond-record-grid">
                    <div><span>AMOUNT</span><strong>{formatToken(bond.amount, decimals)} {symbol}</strong></div>
                    <div><span>OPENED</span><strong>Block {bond.openBlock.toString()}</strong></div>
                    <div><span>MATURES</span><strong>Block {bond.maturesAtBlock.toString()}</strong></div>
                    <div><span>SWAP TX</span><a href={bond.hash ? explorerTx(bond.hash) : "#"} target="_blank" rel="noreferrer">{bond.hash ? shortenHash(bond.hash) : "—"} ↗</a></div>
                  </div>
                  {!settled && <div className="bond-progress"><span><i style={{ width: `${progress}%` }} /></span><b>{progress}% through observation window</b></div>}
                  {settled && <div className={`settlement-result ${settled.slashAmount > 0n ? "settlement-result-slash" : "settlement-result-refund"}`}><div><span>REFUND SENT</span><strong>{formatToken(settled.refundAmount, decimals)} {symbol}</strong></div><div><span>SLASHED TO POT</span><strong>{formatToken(settled.slashAmount, decimals)} {symbol}</strong></div><div><span>PERSISTENCE</span><strong>{settled.persistenceBps.toString()} bps</strong></div><a href={settled.hash ? explorerTx(settled.hash) : "#"} target="_blank" rel="noreferrer">Settlement tx ↗</a><p className="refund-delivery-note">{settled.refundAmount > 0n ? `Refund sent to ${formatAddress(bond.owner)}.` : "No refund; sent to pot."}</p></div>}
                </div>
              );
            })}
          </div>
        )}
      </article>

      <ClaimsCard claimable0={claimable0} claimable1={claimable1} isConnected={isConnected} networkCorrect={networkCorrect} onRefresh={onRefresh} onProtocolActivity={onProtocolActivity} onConnect={onConnect} onSwitchNetwork={onSwitchNetwork} />
    </>
  );
}

function ClaimsCard({
  claimable0,
  claimable1,
  isConnected,
  networkCorrect,
  onRefresh,
  onProtocolActivity,
  onConnect,
  onSwitchNetwork,
}: {
  claimable0: bigint;
  claimable1: bigint;
  isConnected: boolean;
  networkCorrect: boolean;
  onRefresh: () => void;
  onProtocolActivity: (item: Activity) => void;
  onConnect: () => void;
  onSwitchNetwork: () => void;
}) {
  const publicClient = usePublicClient({ chainId: sepolia.id });
  const { writeContractAsync } = useWriteContract();
  const [claimState, setClaimState] = useState<ProtocolTransactionState>("idle");
  const [claimCurrency, setClaimCurrency] = useState<Address | undefined>();
  const [claimHash, setClaimHash] = useState<Hex | undefined>();
  const [claimError, setClaimError] = useState("");
  const rows = [
    { currency: deployment.currency0, symbol: "ETH", amount: claimable0 },
    { currency: deployment.currency1, symbol: "WETH", amount: claimable1 },
  ];
  const hasClaims = claimable0 > 0n || claimable1 > 0n;

  async function claim(currency: Address) {
    if (!isConnected || !networkCorrect || !publicClient) return;
    setClaimState("sending");
    setClaimCurrency(currency);
    setClaimHash(undefined);
    setClaimError("");
    try {
      const hash = await writeContractAsync({ address: deployment.hook, abi: bondMeBroAbi, functionName: "claimPayments", args: [currency] });
      setClaimHash(hash);
      setClaimState("submitted");
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      setClaimState("success");
      onProtocolActivity({ kind: "CLAIMED", block: receipt.blockNumber.toString(), hash, detail: `${tokenSymbolForCurrency(currency)} deferred payment claimed` });
      onRefresh();
    } catch (error) {
      setClaimState("error");
      setClaimError(friendlyProtocolError(error));
    }
  }

  return (
    <article className="glass-card claims-card">
      <div className="card-heading"><div><span className="eyebrow">SETTLEMENT PAYMENTS</span><h2>Available to claim</h2></div><Badge tone={hasClaims ? "orange" : "neutral"}>{hasClaims ? "ACTION NEEDED" : "CLEAR"}</Badge></div>
      <p className="card-copy">Fallback credits only. Normal refunds arrive during settlement.</p>
      <div className="claim-list">
        {rows.map((row) => (
          <div className="claim-row" key={row.symbol}><div><span>{row.symbol} CREDIT</span><strong>{formatToken(row.amount)} {row.symbol}</strong></div><button type="button" className="outline-button" disabled={!isConnected || !networkCorrect || row.amount === 0n || (claimState === "sending" || claimState === "submitted")} onClick={() => void claim(row.currency)}>{claimState === "sending" && claimCurrency?.toLowerCase() === row.currency.toLowerCase() ? "Confirm…" : claimState === "submitted" && claimCurrency?.toLowerCase() === row.currency.toLowerCase() ? "Pending…" : "Claim"}</button></div>
        ))}
      </div>
      {!isConnected && <div className="inline-empty"><button type="button" className="text-button" onClick={onConnect}>Connect wallet</button> to check deferred payments.</div>}
      {isConnected && !networkCorrect && <div className="inline-empty"><button type="button" className="text-button" onClick={onSwitchNetwork}>Switch to Sepolia</button> to claim.</div>}
      {claimState === "error" && <div className="transaction-message transaction-error">{claimError}</div>}
      {claimState === "success" && claimHash && <div className="transaction-message transaction-success">Payment claimed. <a href={explorerTx(claimHash)} target="_blank" rel="noreferrer">View transaction ↗</a></div>}
    </article>
  );
}

function PoolsScreen({
  config,
  accumulator,
  clampTicks,
  observationBlocks,
  settlerFeeBps,
  queueLength,
  pot0,
  pot1,
  poolConnected,
  owner,
  rpcOnline,
  isConnected,
  networkCorrect,
  onRefresh,
  onProtocolActivity,
  onConnect,
  onSwitchNetwork,
}: {
  config?: ConfigTuple;
  accumulator?: AccumulatorTuple;
  clampTicks: bigint;
  observationBlocks: bigint;
  settlerFeeBps: bigint;
  queueLength: bigint;
  pot0: bigint;
  pot1: bigint;
  poolConnected: boolean;
  owner?: Address;
  rpcOnline: boolean;
  isConnected: boolean;
  networkCorrect: boolean;
  onRefresh: () => void;
  onProtocolActivity: (item: Activity) => void;
  onConnect: () => void;
  onSwitchNetwork: () => void;
}) {
  const publicClient = usePublicClient({ chainId: sepolia.id });
  const { writeContractAsync } = useWriteContract();
  const [donationState, setDonationState] = useState<ProtocolTransactionState>("idle");
  const [donationCurrency, setDonationCurrency] = useState<Address | undefined>();
  const [donationHash, setDonationHash] = useState<Hex | undefined>();
  const [donationError, setDonationError] = useState("");

  async function donate(currency: Address, amount: bigint) {
    if (!isConnected || !networkCorrect || !publicClient || amount === 0n) return;
    setDonationState("sending");
    setDonationCurrency(currency);
    setDonationHash(undefined);
    setDonationError("");
    try {
      const hash = await writeContractAsync({ address: deployment.hook, abi: bondMeBroAbi, functionName: "donatePot", args: [poolKey(), currency] });
      setDonationHash(hash);
      setDonationState("submitted");
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      setDonationState("success");
      onProtocolActivity({ kind: "DONATED", block: receipt.blockNumber.toString(), hash, detail: `${tokenSymbolForCurrency(currency)} insurance pot donated` });
      onRefresh();
    } catch (error) {
      setDonationState("error");
      setDonationError(friendlyProtocolError(error));
    }
  }

  const pots = [
    { currency: deployment.currency0, symbol: "ETH", amount: pot0 },
    { currency: deployment.currency1, symbol: "WETH", amount: pot1 },
  ];

  return (
    <>
      <section className="screen-intro"><div><span className="eyebrow">03 / POOL ANALYTICS</span><h1>Pool health.<br /><em>Live.</em></h1></div><p>Live pool state.</p></section>
      <section className="content-grid pool-analytics-grid">
        <article className="neo-card analytics-card"><div className="card-heading"><div><span className="eyebrow">SELECTED POOL</span><h2>ETH / WETH</h2></div><Badge tone={poolConnected ? "green" : "neutral"}><StatusDot live={poolConnected} /> {poolConnected ? "HOOK ACTIVE" : "CHECKING"}</Badge></div><div className="pool-identity-large"><div className="large-pair-icon"><span>Ξ</span><span>W</span></div><div><strong>ETH / WETH</strong><span>Sepolia</span></div></div><div className="pool-stat-grid"><div><span>FEE TIER</span><strong>0.30%</strong></div><div><span>TICK SPACING</span><strong>60</strong></div><div><span>QUEUE</span><strong>{formatInteger(queueLength)}</strong></div><div><span>LAST TICK</span><strong>{accumulator?.[0]?.toString() ?? "—"}</strong></div></div><a className="outline-button full-button button-as-link" href={explorerAddress(deployment.hook)} target="_blank" rel="noreferrer">View hook contract ↗</a></article>
        <article className="glass-card configuration-card"><div className="card-heading"><div><span className="eyebrow">BOND CONFIGURATION</span><h2>Pool parameters</h2></div><Badge tone={!rpcOnline ? "muted" : config && config[2] > 0n ? "orange" : "muted"}>{!rpcOnline ? "RPC OFFLINE" : config && config[2] > 0n ? "ENABLED" : "DISABLED"}</Badge></div>{!rpcOnline && <div className="pair-warning">RPC offline.</div>}<div className="config-list"><div><span>Bond BPS</span><strong>{config?.[2]?.toString() ?? "—"} <small>basis points</small></strong></div><div><span>Minimum / currency 0</span><strong>{formatToken(config?.[0])} <small>ETH</small></strong></div><div><span>Minimum / currency 1</span><strong>{formatToken(config?.[1])} <small>WETH</small></strong></div><div><span>Observation window</span><strong>{observationBlocks.toString()} <small>blocks</small></strong></div><div><span>Settler reward</span><strong>{settlerFeeBps.toString()} <small>bps of slash</small></strong></div></div><div className="owner-row"><span>OWNER</span><a href={owner ? explorerAddress(owner) : "#"} target="_blank" rel="noreferrer">{formatAddress(owner)} ↗</a></div></article>
      </section>
      <section className="content-grid pool-analytics-grid analytics-lower">
        <article className="neo-card"><SectionHeading eyebrow="ACCUMULATOR" title="Pool-local reference" copy="Clamped settlement data." /><div className="tick-display"><strong>{accumulator?.[0]?.toString() ?? "—"}</strong><span>LAST RECORDED TICK</span></div><div className="mini-stats"><div><span>LAST UPDATE</span><strong>{accumulator?.[1]?.toString() ?? "—"}</strong></div><div><span>CLAMP</span><strong>{clampTicks.toString()} ticks</strong></div><div><span>CUMULATIVE</span><strong>{accumulator ? shortenHash(`0x${accumulator[2].toString(16)}`, 8, 5) : "—"}</strong></div></div></article>
        <article className="glass-card pot-card"><div className="card-heading"><div><span className="eyebrow">LP COVERAGE</span><h2>Insurance balances</h2></div><Badge tone={pot0 > 0n || pot1 > 0n ? "orange" : "neutral"}>{pot0 > 0n || pot1 > 0n ? "READY TO DISTRIBUTE" : "EMPTY"}</Badge></div><p className="card-copy">Slash value waiting for LP donation.</p><div className="coverage-balance">{pots.map((pot) => <div key={pot.symbol}><span>{pot.symbol} POT</span><strong>{formatToken(pot.amount)} {pot.symbol}</strong><button type="button" className="outline-button" disabled={!isConnected || !networkCorrect || pot.amount === 0n || (donationState === "sending" || donationState === "submitted")} onClick={() => void donate(pot.currency, pot.amount)}>{donationState === "sending" && donationCurrency?.toLowerCase() === pot.currency.toLowerCase() ? "Confirm…" : donationState === "submitted" && donationCurrency?.toLowerCase() === pot.currency.toLowerCase() ? "Pending…" : pot.amount > 0n ? `Donate ${pot.symbol} pot` : "No pot yet"}</button></div>)}</div><div className="risk-callout"><span>ⓘ</span><p>Donates to in-range LPs; failed donations keep the pot.</p></div>{!isConnected && <div className="inline-empty"><button type="button" className="text-button" onClick={onConnect}>Connect wallet</button> to donate.</div>}{isConnected && !networkCorrect && <div className="inline-empty"><button type="button" className="text-button" onClick={onSwitchNetwork}>Switch to Sepolia</button> to donate.</div>}{donationState === "error" && <div className="transaction-message transaction-error">{donationError}</div>}{donationState === "success" && donationHash && <div className="transaction-message transaction-success">Pot distributed. <a href={explorerTx(donationHash)} target="_blank" rel="noreferrer">View transaction ↗</a></div>}</article>
      </section>
    </>
  );
}

function ActivityScreen({ activity, activityError, onRefresh }: { activity: Activity[]; activityError: boolean; onRefresh: () => void }) {
  return <><section className="screen-intro"><div><span className="eyebrow">04 / EVENT STREAM</span><h1>Activity.<br /><em>Live.</em></h1></div><p>Recent events.</p></section><article className="neo-card full-activity-card"><div className="card-heading"><div><span className="eyebrow">LAST 5,000 BLOCKS</span><h2>Protocol activity</h2></div><div className="activity-heading-actions"><Badge tone={activityError ? "neutral" : "green"}><StatusDot live={!activityError} /> {activityError ? "SAVED VIEW" : "SYNCED"}</Badge><button type="button" className="outline-button activity-refresh" onClick={onRefresh}>Refresh</button></div></div>{activity.length === 0 ? <div className="inline-empty">{activityError ? "RPC unavailable." : "No events in this window"}</div> : <>{activityError && <div className="inline-empty activity-cache-note">Showing saved activity.</div>}<div className="activity-table"><div className="activity-table-head"><span>EVENT</span><span>DETAIL</span><span>BLOCK</span><span>TRANSACTION</span></div>{activity.map((item, index) => <a className="activity-table-row" href={item.hash ? explorerTx(item.hash) : "#"} target="_blank" rel="noreferrer" key={`${item.kind}-${item.block}-${index}`}><span className={`event-pill event-${item.kind.toLowerCase()}`}>{item.kind}</span><strong>{item.detail}</strong><span>#{item.block}</span><span>{item.hash ? shortenHash(item.hash) : "—"} ↗</span></a>)}</div></>}</article></>;
}

function LearnScreen({ onSwap }: { onSwap: () => void }) {
  return <><section className="screen-intro"><div><span className="eyebrow">05 / LEARN</span><h1>Accountable<br /><em>liquidity.</em></h1></div><p>Outcome-linked LP insurance.</p></section><section className="learn-steps"><article className="learn-step"><span>01</span><div><h2>Swap</h2><p>Swap and preview the bond.</p></div><b>→</b></article><article className="learn-step learn-step-active"><span>02</span><div><h2>Bond</h2><p>A small bond is held.</p></div><b>→</b></article><article className="learn-step"><span>03</span><div><h2>Settle</h2><p>At maturity, settle the outcome.</p></div><b>✓</b></article></section><section className="learn-bottom"><article className="glass-card learn-example"><span className="eyebrow">SIMPLE EXAMPLE</span><h2>1,000 units in.<br /><em>999 units to the pool.</em></h2><div className="example-list"><div><span>Gross input</span><strong>1,000</strong></div><div><span>Temporary bond</span><strong>1</strong></div><div><span>Effective pool input</span><strong>999</strong></div></div></article><article className="neo-card faq-card"><span className="eyebrow">FAQ / RISK</span><h2>Not a guarantee.<br />A defined checkpoint.</h2><p>Pool-local data decides refunds.</p><button type="button" className="primary-button" onClick={onSwap}>Preview a swap <span>→</span></button></article></section></>;
}
