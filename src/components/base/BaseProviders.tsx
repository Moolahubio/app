"use client";

import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { getWagmiConfig } from "@/lib/base/wagmi";

/** Wraps Base Account / wagmi consumers. Mount only when the feature is on. */
export function BaseProviders({ children }: { children: React.ReactNode }) {
  const [config] = useState(() => getWagmiConfig());
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
