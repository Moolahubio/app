import { eq } from "drizzle-orm";
import { getAddress } from "viem";
import { db, walletsTable } from "@workspace/db";
import { AppError } from "./errors";
import { encryptSecret, decryptSecret } from "./crypto";
import {
  generateAccount,
  ensureGas,
  onchainEnabled,
  networkName,
  isValidAddress,
  faucetEnabled,
  privyCustodyEnabled,
} from "./chain";
import { isUniqueViolation } from "./dbErrors";
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
    throw new AppError("We couldn't finish setting up your account. Please try again.");
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
 * LOCAL DEV / OFFLINE ONLY. Whether a user with no wallet may get one on demand
 * so the ledger-only test faucet (POST /wallet/deposit) works for a freshly
 * registered account. Outside this case wallets are only ever created by the
 * explicit "Continue with Privy" link flow, unchanged. Every condition must hold:
 *  - NODE_ENV is not "production";
 *  - the test faucet is explicitly enabled (ENABLE_TEST_FAUCET=true);
 *  - on-chain settlement is NOT configured (no platform key / USDC contract), so
 *    nothing this wallet holds can ever settle, sign or reach a chain;
 *  - Privy custody is off (with it on, every wallet must be the user's own
 *    Privy embedded EOA, never a server-created one).
 */
export function devLedgerWalletAllowed(): boolean {
  return (
    process.env.NODE_ENV !== "production" &&
    faucetEnabled() &&
    !onchainEnabled() &&
    !privyCustodyEnabled()
  );
}

/**
 * The user's wallet, provisioning a ledger-only dev wallet first when
 * devLedgerWalletAllowed() (see there); otherwise exactly getWalletForUser.
 * The dev wallet is the same row createWalletForUser has always made offline
 * (what every offline e2e suite uses): a throwaway address whose generated key
 * is encrypted at rest and, with on-chain disabled, never used to sign. Safe
 * under concurrent first deposits: a lost insert race re-reads the winner.
 */
export async function getOrCreateDevLedgerWallet(userId: string) {
  const existing = await getWalletForUser(userId);
  if (existing || !devLedgerWalletAllowed()) return existing;
  try {
    const wallet = await createWalletForUser(userId);
    logger.info({ userId }, "provisioned ledger-only dev wallet for the offline test faucet");
    return wallet;
  } catch (e) {
    if (isUniqueViolation(e)) return getWalletForUser(userId);
    throw e;
  }
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
    throw new AppError("Finish setting up your account on the Balance page to move money.");
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
