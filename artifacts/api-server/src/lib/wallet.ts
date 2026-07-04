import { eq } from "drizzle-orm";
import { getAddress } from "viem";
import { db, walletsTable } from "@workspace/db";
import { AppError } from "./errors";
import { encryptSecret, decryptSecret } from "./crypto";
import { generateAccount, ensureGas, onchainEnabled, networkName, isValidAddress } from "./chain";
import { logger } from "./logger";

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

/**
 * Provision a NON-CUSTODIAL wallet from a user's Privy embedded EOA address
 * (captured server-side from Privy — never trusted from the client). No private
 * key is stored: the user alone controls the key inside Privy, so custody is
 * 'privy' and private_key_enc is NULL (enforced by the DB CHECK). Idempotent —
 * returns any existing wallet unchanged, so a re-link NEVER mutates custody or
 * address on a wallet that already exists.
 */
export async function createPrivyWalletForUser(userId: string, embeddedAddress: string) {
  const [existing] = await db.select().from(walletsTable).where(eq(walletsTable.userId, userId));
  if (existing) return existing;
  if (!isValidAddress(embeddedAddress)) {
    throw new AppError("Your Privy wallet address looks invalid. Please try again.");
  }
  const address = getAddress(embeddedAddress);
  const [wallet] = await db
    .insert(walletsTable)
    .values({
      userId,
      address,
      privateKeyEnc: null,
      custody: "privy",
      network: networkName(),
    })
    .returning();

  if (onchainEnabled()) {
    // Fund gas in the background so linking stays fast. The user signs their own
    // withdrawals, but the embedded EOA still needs MON to pay for gas.
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

/**
 * Guard for server-signed money movement (custodial-only flows). A Privy-custody
 * wallet holds NO server key, so any server settlement path would debit the
 * ledger and then fail forever in the reconciler (resolveSourceKey → null →
 * markFailed), stranding the debit. Flows that still require the platform to
 * sign (server withdrawals, goal vault deposits/releases, circle contributions —
 * all Phase 2 for non-custodial wallets) must call this BEFORE booking anything
 * so a Privy user gets a clear, up-front error instead of a stuck transfer.
 */
export async function requireServerCustody(userId: string, message: string) {
  const wallet = await requireWalletForUser(userId);
  if (wallet.custody !== "server") {
    throw new AppError(message);
  }
  return wallet;
}

/**
 * Server-only: decrypt a user's signing key for an on-chain operation.
 *
 * This is the single hot spot for custodial key exposure — every call
 * decrypts a real private key into process memory. `reason` should identify
 * the calling flow (e.g. "wallet.withdraw", "goal.release") so the audit
 * trail can distinguish legitimate money-movement from anomalous access if
 * this function is ever called from an unexpected code path.
 */
export async function getSigningSecret(userId: string, reason: string): Promise<string | null> {
  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, userId));
  if (!wallet) return null;
  // Non-custodial (Privy embedded EOA): the platform holds NO signing key by
  // design. Fail closed so no server path can ever sign for a wallet the user
  // alone controls — the defense-in-depth backstop that stays correct even
  // independently of the DB CHECK guaranteeing private_key_enc IS NULL for it.
  if (wallet.custody !== "server" || wallet.privateKeyEnc === null) {
    logger.warn(
      { userId, reason, custody: wallet.custody },
      "refused server signing for non-custodial wallet",
    );
    return null;
  }
  logger.info({ userId, reason }, "signing key decrypted for on-chain operation");
  return decryptSecret(wallet.privateKeyEnc);
}
