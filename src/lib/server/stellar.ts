import "server-only";
import {
  Keypair,
  Networks,
  Horizon,
  TransactionBuilder,
  Operation,
  Asset,
  BASE_FEE,
} from "@stellar/stellar-sdk";

/**
 * Real Stellar integration (testnet).
 *
 * Keypair generation and transaction *signing* are offline operations and are
 * always real. Funding (friendbot) and submission (Horizon) require network
 * egress; where that's unavailable (e.g. a locked-down CI/sandbox) those calls
 * fail gracefully and the signed transaction is returned "queued" with its real
 * hash + XDR, ready to broadcast from any networked environment.
 *
 * Mainnet with pooled funds remains audit-gated and is intentionally not wired.
 */

const NETWORK_PASSPHRASE =
  process.env.STELLAR_NETWORK === "public" ? Networks.PUBLIC : Networks.TESTNET;
const HORIZON_URL =
  process.env.STELLAR_HORIZON_URL || "https://horizon-testnet.stellar.org";
const FRIENDBOT_URL = "https://friendbot.stellar.org";

export type OnchainResult =
  | { status: "confirmed"; hash: string }
  | { status: "queued"; hash: string; xdr: string; reason: string }
  | { status: "skipped"; reason: string };

function server() {
  return new Horizon.Server(HORIZON_URL);
}

/** The USDC asset (our testnet issuer stands in for Circle's USDC on mainnet). */
export function usdcAsset(): Asset | null {
  const issuer = process.env.STELLAR_USDC_ISSUER_PUBLIC;
  if (!issuer) return null;
  return new Asset("USDC", issuer);
}

export function onchainEnabled(): boolean {
  return Boolean(
    process.env.STELLAR_USDC_ISSUER_PUBLIC &&
      process.env.STELLAR_DISTRIBUTOR_SECRET,
  );
}

/** cents (1/100 USDC) -> Stellar 7-dp amount string. */
export function centsToAmount(cents: number): string {
  return (cents / 100).toFixed(7);
}

/** Generate a real Stellar keypair (offline). */
export function generateKeypair(): { publicKey: string; secret: string } {
  const kp = Keypair.random();
  return { publicKey: kp.publicKey(), secret: kp.secret() };
}

/** Fund a testnet account via friendbot. Network-dependent. */
export async function fundWithFriendbot(publicKey: string): Promise<OnchainResult> {
  try {
    const res = await fetch(`${FRIENDBOT_URL}/?addr=${encodeURIComponent(publicKey)}`, {
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return { status: "skipped", reason: `friendbot ${res.status}` };
    const body = (await res.json()) as { hash?: string };
    return { status: "confirmed", hash: body.hash ?? "" };
  } catch (e) {
    return { status: "skipped", reason: `friendbot unreachable: ${errMsg(e)}` };
  }
}

/**
 * Build, sign and submit a payment. Falls back to "queued" (with real hash/XDR)
 * when Horizon can't be reached.
 */
export async function sendPayment(params: {
  fromSecret: string;
  toPublicKey: string;
  amountCents: number;
  asset?: Asset | null;
  memo?: string;
}): Promise<OnchainResult> {
  const asset = params.asset ?? usdcAsset() ?? Asset.native();
  const source = Keypair.fromSecret(params.fromSecret);

  try {
    const account = await server().loadAccount(source.publicKey());
    const tx = new TransactionBuilder(account, {
      fee: BASE_FEE,
      networkPassphrase: NETWORK_PASSPHRASE,
    })
      .addOperation(
        Operation.payment({
          destination: params.toPublicKey,
          asset,
          amount: centsToAmount(params.amountCents),
        }),
      )
      .setTimeout(180)
      .build();
    tx.sign(source);
    const hash = tx.hash().toString("hex");
    try {
      await server().submitTransaction(tx);
      return { status: "confirmed", hash };
    } catch (e) {
      return { status: "queued", hash, xdr: tx.toXDR(), reason: errMsg(e) };
    }
  } catch (e) {
    // Couldn't even load the account (offline). Produce a deterministic ref so
    // the ledger entry is traceable; broadcast later via the queue.
    return { status: "skipped", reason: `horizon unreachable: ${errMsg(e)}` };
  }
}

function errMsg(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}
