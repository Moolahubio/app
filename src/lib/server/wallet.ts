import "server-only";
import { db } from "@/lib/db";
import { encryptSecret, decryptSecret } from "./crypto";
import { generateKeypair, fundWithFriendbot, onchainEnabled } from "./stellar";

/**
 * Create a Stellar wallet for a user. The keypair is real; on-chain funding is
 * attempted (testnet friendbot) and recorded if it succeeds. Where the network
 * is unreachable the wallet still exists and funds on next provisioning.
 */
export async function createWalletForUser(userId: string) {
  const existing = await db.wallet.findUnique({ where: { userId } });
  if (existing) return existing;

  const { publicKey, secret } = generateKeypair();
  const wallet = await db.wallet.create({
    data: {
      userId,
      stellarPublicKey: publicKey,
      stellarSecretEnc: encryptSecret(secret),
    },
  });

  if (onchainEnabled()) {
    const funded = await fundWithFriendbot(publicKey);
    if (funded.status === "confirmed") {
      await db.wallet.update({
        where: { id: wallet.id },
        data: { fundedAt: new Date() },
      });
    }
  }
  return wallet;
}

/** Server-only: decrypt a user's signing key for an on-chain operation. */
export async function getSigningSecret(userId: string): Promise<string | null> {
  const wallet = await db.wallet.findUnique({ where: { userId } });
  if (!wallet) return null;
  return decryptSecret(wallet.stellarSecretEnc);
}
