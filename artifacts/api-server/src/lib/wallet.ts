import { eq } from "drizzle-orm";
import { db, walletsTable } from "@workspace/db";
import { encryptSecret, decryptSecret } from "./crypto";
import { generateAccount, ensureGas, onchainEnabled, networkName } from "./chain";

/**
 * Create a Base (EVM) wallet for a user. The account is generated locally and
 * its private key encrypted at rest. When on-chain is configured, the wallet is
 * gas-funded (best-effort, in the background) so it can transact.
 */
export async function createWalletForUser(userId: string) {
  const [existing] = await db.select().from(walletsTable).where(eq(walletsTable.userId, userId));
  if (existing) return existing;

  const { address, privateKey } = generateAccount();
  const [wallet] = await db
    .insert(walletsTable)
    .values({
      userId,
      address,
      privateKeyEnc: encryptSecret(privateKey),
      network: networkName(),
    })
    .returning();

  if (onchainEnabled()) {
    // Fund gas in the background so signup stays fast.
    void ensureGas(address)
      .then(() => db.update(walletsTable).set({ fundedAt: new Date() }).where(eq(walletsTable.id, wallet.id)))
      .catch(() => undefined);
  }
  return wallet;
}

export async function getWalletForUser(userId: string) {
  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, userId));
  return wallet ?? null;
}

/** Server-only: decrypt a user's signing key for an on-chain operation. */
export async function getSigningSecret(userId: string): Promise<string | null> {
  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, userId));
  if (!wallet) return null;
  return decryptSecret(wallet.privateKeyEnc);
}
