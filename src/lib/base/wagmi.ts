import { createConfig, http, cookieStorage, createStorage } from "wagmi";
import { base, baseSepolia } from "viem/chains";
import { coinbaseWallet } from "wagmi/connectors";

/**
 * Base Account (smart wallet) + Paymaster client config.
 *
 * Feature-flagged: nothing here loads unless NEXT_PUBLIC_BASE_ACCOUNT === "true".
 * When enabled, users sign in with a Coinbase Smart Wallet (passkey) and sign
 * gasless USDC UserOps sponsored by the Coinbase Paymaster (proxied via
 * /api/paymaster so the paymaster URL/secret stays server-side).
 */
export const BASE_CHAIN = process.env.NEXT_PUBLIC_BASE_CHAIN === "base" ? base : baseSepolia;

/** Whether the Base Account experience is turned on (set in production). */
export function baseAccountEnabled(): boolean {
  return process.env.NEXT_PUBLIC_BASE_ACCOUNT === "true";
}

/** Our server-side paymaster proxy — keeps the CDP paymaster secret off the client. */
export const PAYMASTER_PROXY_URL = "/api/paymaster";

let cached: ReturnType<typeof createConfig> | undefined;

export function getWagmiConfig() {
  if (cached) return cached;
  const rpc = http(process.env.NEXT_PUBLIC_BASE_RPC_URL || undefined);
  cached = createConfig({
    chains: [BASE_CHAIN],
    connectors: [
      coinbaseWallet({ appName: "MoolaHub", preference: { options: "smartWalletOnly" } }),
    ],
    storage: createStorage({ storage: cookieStorage }),
    ssr: true,
    transports: {
      [base.id]: rpc,
      [baseSepolia.id]: rpc,
    },
  });
  return cached;
}
