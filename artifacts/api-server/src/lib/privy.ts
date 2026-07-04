import { PrivyClient } from "@privy-io/server-auth";

/**
 * Privy server-side auth. Activates when PRIVY_APP_ID + PRIVY_APP_SECRET are
 * set. The client authenticates with Privy, then posts its access token to
 * /api/auth/privy, which verifies it here and establishes our own session.
 */
const APP_ID = process.env.PRIVY_APP_ID;
const APP_SECRET = process.env.PRIVY_APP_SECRET;

let client: PrivyClient | null = null;

export function privyEnabled() {
  return Boolean(APP_ID && APP_SECRET);
}

function privy(): PrivyClient {
  if (!client) {
    if (!APP_ID || !APP_SECRET) throw new Error("Privy is not configured");
    client = new PrivyClient(APP_ID, APP_SECRET);
  }
  return client;
}

/** Verify a Privy access token; returns the Privy DID (userId). */
export async function verifyPrivyToken(token: string): Promise<string> {
  const claims = await privy().verifyAuthToken(token);
  return claims.userId;
}

/**
 * The address of a user's Privy EMBEDDED Ethereum wallet — the self-custody EOA
 * Privy provisions for them and whose key only the user controls. Read
 * server-side from Privy so the platform never trusts a client-supplied address.
 * Returns null when the user has no embedded EOA (e.g. they authenticated with an
 * external wallet rather than creating an embedded one), so callers fail closed.
 */
export async function getPrivyEmbeddedWalletAddress(did: string): Promise<string | null> {
  const user = await privy().getUser(did);
  for (const account of user.linkedAccounts ?? []) {
    const a = account as unknown as Record<string, unknown>;
    if (
      a.type === "wallet" &&
      a.walletClientType === "privy" &&
      a.chainType === "ethereum" &&
      typeof a.address === "string"
    ) {
      return a.address;
    }
  }
  return null;
}

/** Pull email + display name from a Privy user's linked accounts. */
export async function getPrivyProfile(did: string): Promise<{ email?: string; name?: string }> {
  const user = await privy().getUser(did);
  let email: string | undefined;
  let name: string | undefined;
  for (const account of user.linkedAccounts ?? []) {
    const a = account as unknown as Record<string, unknown>;
    if (a.type === "email" && typeof a.address === "string") email ??= a.address;
    if (a.type === "google_oauth") {
      if (typeof a.email === "string") email ??= a.email;
      if (typeof a.name === "string") name ??= a.name;
    }
    if (a.type === "phone" && typeof a.number === "string") name ??= a.number;
  }
  return { email, name };
}
