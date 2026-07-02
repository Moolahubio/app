import { eq } from "drizzle-orm";
import { db, walletsTable } from "@workspace/db";
import { AppError } from "./errors";
import { encryptSecret, decryptSecret } from "./crypto";
import { generateAccount, ensureGas, onchainEnabled, networkName } from "./chain";

/**
 * Create a Monad (EVM) wallet for a user. The account is generated locally and
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

/**
 * Guard for money-movement: wallets are no longer auto-created, so any flow that
 * spends or settles funds must fail clearly when the user hasn't set one up yet
 * (via "Continue with Privy" in the Wallet section) rather than surfacing a
 * confusing "insufficient balance" or hitting a missing signing key.
 */
export async function requireWalletForUser(userId: string) {
  const wallet = await getWalletForUser(userId);
  if (!wallet) {
    throw new AppError("Set up your wallet first to move money.");
  }
  return wallet;
}

/** Server-only: decrypt a user's signing key for an on-chain operation. */
export async function getSigningSecret(userId: string): Promise<string | null> {
  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, userId));
  if (!wallet) return null;
  return decryptSecret(wallet.privateKeyEnc);
}
