import "server-only";
import { db } from "@/lib/db";
import { encryptSecret, decryptSecret } from "./crypto";
import { generateAccount, ensureGas, onchainEnabled } from "./chain";

/**
 * Create a Base (EVM) wallet for a user. The account is generated locally and
 * its private key encrypted at rest. When on-chain is configured, the wallet is
 * gas-funded so it can transact; otherwise it still exists and funds later.
 */
export async function createWalletForUser(userId: string) {
  const existing = await db.wallet.findUnique({ where: { userId } });
  if (existing) return existing;

  const { address, privateKey } = generateAccount();
  const wallet = await db.wallet.create({
    data: {
      userId,
      address,
      privateKeyEnc: encryptSecret(privateKey),
    },
  });

  if (onchainEnabled()) {
    await ensureGas(address);
    await db.wallet.update({ where: { id: wallet.id }, data: { fundedAt: new Date() } });
  }
  return wallet;
}

/** Server-only: decrypt a user's signing key for an on-chain operation. */
export async function getSigningSecret(userId: string): Promise<string | null> {
  const wallet = await db.wallet.findUnique({ where: { userId } });
  if (!wallet) return null;
  return decryptSecret(wallet.privateKeyEnc);
}
