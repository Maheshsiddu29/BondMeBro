"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { custom, fallback, type EIP1193Provider } from "viem";
import { injected } from "@wagmi/core";
import { sepolia } from "wagmi/chains";
import { WagmiProvider, createConfig, http } from "wagmi";

const walletProvider = typeof window !== "undefined"
  ? (window as Window & { ethereum?: EIP1193Provider }).ethereum
  : undefined;

// Prefer the connected wallet's Sepolia node when available, then use the server proxy.
// This keeps reads working locally even when a hosted RPC key is missing or rate-limited.
const sepoliaTransport = walletProvider
  ? fallback([custom(walletProvider), http("/api/rpc")])
  : http("/api/rpc");

const config = createConfig({
  chains: [sepolia],
  connectors: [injected()],
  transports: {
    [sepolia.id]: sepoliaTransport,
  },
  ssr: true,
  // Keep the post-write UI responsive without waiting for the default long poll interval.
  pollingInterval: 2_000,
});

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
