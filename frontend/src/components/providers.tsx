"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { injected } from "@wagmi/core";
import { sepolia } from "wagmi/chains";
import { WagmiProvider, createConfig, http } from "wagmi";

const config = createConfig({
  chains: [sepolia],
  connectors: [injected()],
  transports: {
    [sepolia.id]: http("/api/rpc"),
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
