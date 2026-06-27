import { useQuery } from "@tanstack/react-query";

/** On-chain addresses the client needs, served by GET /api/onchain/config. */
export type OnchainConfig = {
  network: string;
  explorerUrl: string;
  usdc: `0x${string}` | null;
  goalVault: `0x${string}` | null;
  circleFactory: `0x${string}` | null;
  accumulationFactory: `0x${string}` | null;
};

async function fetchOnchainConfig(): Promise<OnchainConfig> {
  const res = await fetch("/api/onchain/config", { credentials: "include" });
  if (!res.ok) throw new Error("Failed to load on-chain config");
  return res.json();
}

export function useOnchainConfig() {
  return useQuery({
    queryKey: ["onchain-config"],
    queryFn: fetchOnchainConfig,
    staleTime: Infinity,
  });
}

/** Build an explorer tx link. */
export function txLink(explorerUrl: string, hash: string): string {
  return `${explorerUrl.replace(/\/$/, "")}/tx/${hash}`;
}
