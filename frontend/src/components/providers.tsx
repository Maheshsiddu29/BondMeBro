"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { defineChain } from "viem";
import { injected } from "@wagmi/core";
import { WagmiProvider, createConfig, http } from "wagmi";

import type { Deployment } from "@/lib/deployment";

/**
 * Builds the single chain this build talks to, from the deployment manifest.
 *
 * The previous version hardwired Ethereum Sepolia into wagmi while letting an environment
 * variable relabel the UI, so a "Unichain Sepolia" label could sit on top of Sepolia reads.
 * Here the chain ID, name and explorer all come from the same manifest that supplies the
 * hook, router and pool, so they cannot disagree.
 */
export function chainForDeployment(deployment: Deployment) {
  return defineChain({
    id: deployment.chainId,
    name: deployment.networkName,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: ["/api/rpc"] } },
    blockExplorers: { default: { name: "Explorer", url: deployment.explorerUrl } },
  });
}

export function Providers({
  deployment,
  children,
}: {
  deployment: Deployment;
  children: React.ReactNode;
}) {
  const [queryClient] = useState(() => new QueryClient());

  const config = useMemo(() => {
    const chain = chainForDeployment(deployment);
    return createConfig({
      chains: [chain],
      connectors: [injected()],
      // Reads go through the server proxy only. The previous build preferred the injected
      // wallet's own transport, which returns whatever chain the wallet happens to be on:
      // a wrong-chain balance could then be rendered under this network's label. The proxy
      // verifies its upstream chain ID, so a read is either from this chain or an error.
      transports: { [chain.id]: http("/api/rpc") },
      ssr: true,
      pollingInterval: 2_000,
    });
  }, [deployment]);

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
