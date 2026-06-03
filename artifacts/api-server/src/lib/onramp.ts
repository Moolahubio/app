import { generateJwt } from "@coinbase/cdp-sdk/auth";

/**
 * Coinbase Onramp (fiat → USDC) — secure server-side initialization.
 *
 * The CDP API key/secret never leave the server. We mint a short-lived session
 * token bound to a specific destination address + asset/network, then the
 * client opens pay.coinbase.com with ONLY that token.
 */
const KEY_ID = process.env.CDP_API_KEY_ID;
const KEY_SECRET = process.env.CDP_API_KEY_SECRET;
const HOST = "api.developer.coinbase.com";
const TOKEN_PATH = "/onramp/v1/token";

export function onrampEnabled(): boolean {
  return Boolean(KEY_ID && KEY_SECRET);
}

/** Mint a one-time Onramp session token for `address` (CDP-authenticated). */
export async function createOnrampSessionToken(address: string, clientIp: string): Promise<string> {
  if (!KEY_ID || !KEY_SECRET) throw new Error("Onramp is not configured");

  const jwt = await generateJwt({
    apiKeyId: KEY_ID,
    apiKeySecret: KEY_SECRET.includes("\\n") ? KEY_SECRET.replace(/\\n/g, "\n") : KEY_SECRET,
    requestMethod: "POST",
    requestHost: HOST,
    requestPath: TOKEN_PATH,
    expiresIn: 120,
  });

  const res = await fetch(`https://${HOST}${TOKEN_PATH}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify({
      addresses: [{ address, blockchains: ["base"] }],
      assets: ["USDC"],
      clientIp,
    }),
  });

  if (!res.ok) {
    const detail = await res.text();
    throw new Error(`CDP onramp token failed: ${res.status} ${detail.slice(0, 200)}`);
  }
  const data = (await res.json()) as { token?: string };
  if (!data.token) throw new Error("CDP onramp token missing in response");
  return data.token;
}

/** Build the hosted Onramp URL from a session token. */
export function buildOnrampUrl(
  sessionToken: string,
  opts?: { presetFiatAmount?: number; fiatCurrency?: string },
): string {
  const u = new URL("https://pay.coinbase.com/buy/select-asset");
  u.searchParams.set("sessionToken", sessionToken);
  u.searchParams.set("defaultNetwork", "base");
  u.searchParams.set("defaultAsset", "USDC");
  u.searchParams.set("fiatCurrency", opts?.fiatCurrency ?? "USD");
  if (opts?.presetFiatAmount) u.searchParams.set("presetFiatAmount", String(opts.presetFiatAmount));
  return u.toString();
}
