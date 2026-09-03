"use client";

import { useEffect, useMemo, useState } from "react";
import type { Address } from "viem";
import { useAccount, useBlockNumber, usePublicClient, useReadContract } from "wagmi";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import { erc20Abi } from "@/lib/abi/external";
import type { Deployment } from "@/lib/deployment";
import type { TokenMeta } from "@/lib/format";
import { tradingReadiness } from "@/lib/guards";
import type { HookConstants } from "@/lib/limits";
import { poolConfigFromGetter, type PoolConfig, type PoolConfigGetterTuple } from "@/lib/poolConfig";
import { loadTokenMeta } from "@/lib/tokenMetadata";

/**
 * Everything read from the chain that the whole app shares.
 *
 * Every read here is bound to `deployment.chainId`, so a wallet on another network cannot
 * cause this data to describe a different chain.
 */
export type ProtocolState = {
  deployment: Deployment;
  chainId: number;
  blockNumber?: bigint;
  constants?: HookConstants;
  observationBlocks?: bigint;
  owner?: Address;
  poolManager?: Address;
  /** True only when the hook's reported PoolManager equals the configured one. */
  poolManagerMatches: boolean;
  poolConfig?: PoolConfig;
  poolConfigError: boolean;
  poolConfigLoading: boolean;
  token0?: TokenMeta;
  token1?: TokenMeta;
  tokenMetadataError?: string;
  insurancePot0?: bigint;
  insurancePot1?: bigint;
  rpcOnline: boolean;
  /** Client-side configuration check; false disables every transaction. */
  canTrade: boolean;
  configurationProblems: string[];
  refresh: () => void;
};

export function useProtocol(deployment: Deployment): ProtocolState {
  const chainId = deployment.chainId;
  const publicClient = usePublicClient({ chainId });
  const { data: blockNumber } = useBlockNumber({ chainId, watch: true });
  const [nonce, setNonce] = useState(0);
  const [tokens, setTokens] = useState<{ token0?: TokenMeta; token1?: TokenMeta; error?: string }>({});

  const readiness = useMemo(() => tradingReadiness(deployment), [deployment]);

  const base = { address: deployment.hook, abi: bondMeBroAbi, chainId } as const;

  const bpsRead = useReadContract({ ...base, functionName: "BPS", query: { staleTime: Infinity } });
  const capRead = useReadContract({ ...base, functionName: "MAX_BOND_BPS", query: { staleTime: Infinity } });
  const observationRead = useReadContract({
    ...base,
    functionName: "OBSERVATION_BLOCKS",
    query: { staleTime: Infinity },
  });
  const ownerRead = useReadContract({ ...base, functionName: "owner", query: { refetchInterval: 30_000 } });
  const managerRead = useReadContract({ ...base, functionName: "poolManager", query: { refetchInterval: 30_000 } });
  const poolConfigRead = useReadContract({
    ...base,
    functionName: "poolConfig",
    args: [deployment.poolId],
    query: { refetchInterval: 15_000 },
  });
  const pot0Read = useReadContract({
    ...base,
    functionName: "insurancePot",
    args: [deployment.poolId, deployment.currency0],
    query: { refetchInterval: 15_000 },
  });
  const pot1Read = useReadContract({
    ...base,
    functionName: "insurancePot",
    args: [deployment.poolId, deployment.currency1],
    query: { refetchInterval: 15_000 },
  });

  // Token decimals and symbols are read from the tokens themselves. Nothing here falls
  // back to 18 decimals or to a shipped symbol; an unreadable token fails closed.
  useEffect(() => {
    let cancelled = false;
    if (!publicClient) return;
    const reader = {
      readDecimals: (address: Address) =>
        publicClient.readContract({ address, abi: erc20Abi, functionName: "decimals" }).then(Number),
      readSymbol: (address: Address) =>
        publicClient.readContract({ address, abi: erc20Abi, functionName: "symbol" }),
    };
    void Promise.all([
      loadTokenMeta(chainId, deployment.currency0, reader),
      loadTokenMeta(chainId, deployment.currency1, reader),
    ])
      .then(([token0, token1]) => {
        if (!cancelled) setTokens({ token0, token1 });
      })
      .catch((error: unknown) => {
        if (!cancelled) {
          setTokens({
            error:
              error instanceof Error
                ? `Token metadata unavailable: ${error.message}`
                : "Token metadata unavailable.",
          });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [chainId, deployment.currency0, deployment.currency1, publicClient, nonce]);

  const constants: HookConstants | undefined =
    bpsRead.data !== undefined && capRead.data !== undefined
      ? { bps: BigInt(bpsRead.data), maxBondBps: BigInt(capRead.data) }
      : undefined;

  const poolConfig = poolConfigRead.data
    ? poolConfigFromGetter(poolConfigRead.data as unknown as PoolConfigGetterTuple)
    : undefined;

  const poolManager = managerRead.data as Address | undefined;

  function refresh() {
    setNonce((value) => value + 1);
    void Promise.all([
      ownerRead.refetch(),
      managerRead.refetch(),
      poolConfigRead.refetch(),
      pot0Read.refetch(),
      pot1Read.refetch(),
    ]);
  }

  const configurationProblems = readiness.canTrade ? [] : readiness.problems;

  return {
    deployment,
    chainId,
    blockNumber,
    constants,
    observationBlocks: observationRead.data === undefined ? undefined : BigInt(observationRead.data),
    owner: ownerRead.data as Address | undefined,
    poolManager,
    poolManagerMatches: Boolean(
      poolManager && poolManager.toLowerCase() === deployment.poolManager.toLowerCase(),
    ),
    poolConfig,
    poolConfigError: poolConfigRead.isError,
    poolConfigLoading: poolConfigRead.isLoading,
    token0: tokens.token0,
    token1: tokens.token1,
    tokenMetadataError: tokens.error,
    insurancePot0: pot0Read.data as bigint | undefined,
    insurancePot1: pot1Read.data as bigint | undefined,
    rpcOnline: !managerRead.isError && managerRead.data !== undefined,
    canTrade: readiness.canTrade,
    configurationProblems,
    refresh,
  };
}

/** The wallet context every write is bound to. */
export function useWalletContext() {
  const { address, chainId, isConnected } = useAccount();
  return { address, chainId, isConnected };
}
