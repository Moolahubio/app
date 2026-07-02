import { eq, isNotNull } from "drizzle-orm";
import {
  createPublicClient,
  http,
  parseAbiItem,
  getAddress,
  keccak256,
  stringToHex,
  type Address,
  type Hex,
} from "viem";
import { monadTestnet } from "viem/chains";
import { db, circlesTable, goalsTable, walletsTable, transactionsTable } from "@workspace/db";
import { acct, transfer } from "./ledger";
import { unitsToCents } from "./chain";
import { logger } from "./logger";

/**
 * On-chain → ledger indexer.
 *
 * In the user-signed model the contracts hold the money, so the ledger must be
 * populated from confirmed on-chain events rather than from server-side fund
 * moves. This poller scans recent blocks for the circle clones and the goal vault
 * and posts the matching double-entry ledger transactions, idempotently.
 *
 * Idempotency: every event is keyed by `${txHash}:${logIndex}` and stored on the
 * ledger transaction's `onchainXdr` column; an event already posted is skipped.
 * Best-effort and side-effect free on failure — safe to run on an interval.
 *
 * The ledger remains the app's source of truth for display; for custodied funds
 * the chain is authoritative and this reconciler makes the ledger match it.
 */

const CHAIN = monadTestnet; // Monad Testnet (10143, MON); no Monad mainnet chain in viem
const RPC_URL =
  process.env.CHAIN_RPC_URL || process.env.BASE_RPC_URL || "https://testnet-rpc.monad.xyz";
const GOAL_VAULT = (process.env.GOAL_VAULT_ADDRESS || "") as string;
const INDEX_INTERVAL_MS = Number(process.env.INDEXER_INTERVAL_MS) || 20_000;
// ~400ms Monad blocks: a fixed 9k lookback covers only ~1h of wall-clock (vs ~5h
// on Base). Widen to restore parity; override via env. A persisted high-water
// cursor is the robust follow-up for outages longer than this window (plan §2.5).
const BLOCK_LOOKBACK = BigInt(process.env.INDEXER_BLOCK_LOOKBACK ?? "50000");

// MODEL EXCLUSIVITY (M7): this indexer is the reconciler for the USER-SIGNED V2
// model (contracts custody funds; events drive the ledger). It must REPLACE, not
// run alongside, the server-custodied settlement reconciler (lib/settlement.ts)
// for the same flows — running both double-books, because the two use different
// idempotency keys (indexer: onchain_xdr = txHash:logIndex; settlement: bare
// tx_hash) and the unique tx_hash index only covers `deposit` rows. So when V2 is
// wired, start this loop and stop enqueuing those flows through settlement.
// (L1 cross-credit is fixed below in indexGoalVault.)

// --- Event signatures (must match the contracts) ---------------------------
const E_CONTRIBUTED = parseAbiItem("event Contributed(address indexed member, uint256 indexed round, uint256 amount)");
const E_ROUND_SETTLED = parseAbiItem("event RoundSettled(uint256 indexed round, address indexed recipient, uint256 payout, uint256 fee)");
// V2 accumulation settlement (replaces V1 `Withdrawn`): carries the principal /
// payout / fee / forfeited-yield split so the ledger can post yield & loss.
const E_ACC_SETTLED = parseAbiItem(
  "event AccumulationSettled(address indexed member, uint256 principal, uint256 payout, uint256 fee, uint256 yieldForfeited)"
);
const E_REFUNDED = parseAbiItem("event Refunded(address indexed member, uint256 amount)");
const E_GOAL_DEPOSITED = parseAbiItem("event GoalDeposited(address indexed owner, bytes32 indexed goalId, uint256 amount)");
const E_GOAL_WITHDRAWN = parseAbiItem("event GoalWithdrawn(address indexed owner, bytes32 indexed goalId, uint256 grossAmount, uint256 fee)");

function publicClient() {
  return createPublicClient({ chain: CHAIN, transport: http(RPC_URL) });
}

/** Whether the indexer has anything to do (RPC reachable + at least the goal vault or a circle). */
export function indexerEnabled(): boolean {
  return Boolean(RPC_URL);
}

type Ctx = {
  circles: Map<string, { id: string; type: string }>; // lowercased address -> circle
  walletToUser: Map<string, string>; // lowercased address -> userId
  goalByHash: Map<string, { goalId: string; userId: string }>; // bytes32 -> goal
};

async function loadContext(): Promise<Ctx> {
  const [circles, wallets, goals] = await Promise.all([
    db
      .select({ id: circlesTable.id, type: circlesTable.type, addr: circlesTable.contractAddress })
      .from(circlesTable)
      .where(isNotNull(circlesTable.contractAddress)),
    db.select({ userId: walletsTable.userId, addr: walletsTable.address }).from(walletsTable),
    db.select({ id: goalsTable.id, userId: goalsTable.userId }).from(goalsTable),
  ]);

  const circleMap = new Map<string, { id: string; type: string }>();
  for (const c of circles) if (c.addr) circleMap.set(c.addr.toLowerCase(), { id: c.id, type: c.type });

  const walletToUser = new Map<string, string>();
  for (const w of wallets) walletToUser.set(w.addr.toLowerCase(), w.userId);

  const goalByHash = new Map<string, { goalId: string; userId: string }>();
  for (const g of goals) goalByHash.set(keccak256(stringToHex(g.id)).toLowerCase(), { goalId: g.id, userId: g.userId });

  return { circles: circleMap, walletToUser, goalByHash };
}

/** Skip if this event op was already turned into a ledger transaction. */
async function alreadyPosted(opId: string): Promise<boolean> {
  const [row] = await db
    .select({ id: transactionsTable.id })
    .from(transactionsTable)
    .where(eq(transactionsTable.onchainXdr, opId));
  return Boolean(row);
}

async function post(params: {
  opId: string;
  type: string;
  description: string;
  userId: string | null;
  fromKey: string;
  toKey: string;
  amountCents: number;
  txHash: string;
}) {
  if (params.amountCents <= 0) return;
  if (await alreadyPosted(params.opId)) return;
  await transfer({
    type: params.type,
    description: params.description,
    userId: params.userId,
    fromKey: params.fromKey,
    toKey: params.toKey,
    amountCents: params.amountCents,
    onchain: { txHash: params.txHash, onchainStatus: "confirmed", onchainXdr: params.opId },
  });
}

async function indexCircle(addr: Address, circle: { id: string; type: string }, ctx: Ctx, from: bigint, to: bigint) {
  const pub = publicClient();
  const [contribs, settled, accSettled, refunded] = await Promise.all([
    pub.getLogs({ address: addr, event: E_CONTRIBUTED, fromBlock: from, toBlock: to }),
    circle.type === "accumulation"
      ? Promise.resolve([])
      : pub.getLogs({ address: addr, event: E_ROUND_SETTLED, fromBlock: from, toBlock: to }),
    circle.type === "accumulation"
      ? pub.getLogs({ address: addr, event: E_ACC_SETTLED, fromBlock: from, toBlock: to })
      : Promise.resolve([]),
    pub.getLogs({ address: addr, event: E_REFUNDED, fromBlock: from, toBlock: to }),
  ]);

  for (const log of contribs) {
    const member = ctx.walletToUser.get(((log.args.member ?? "") as string).toLowerCase());
    if (!member) continue;
    const cents = unitsToCents((log.args.amount ?? 0n) as bigint);
    await post({
      opId: `${log.transactionHash}:${log.logIndex}`,
      type: "contribution",
      description: `Contribution · round ${(log.args.round ?? 0n).toString()}`,
      userId: member,
      fromKey: acct.wallet(member),
      toKey: acct.pool(circle.id),
      amountCents: cents,
      txHash: log.transactionHash ?? "",
    });
  }

  for (const log of settled) {
    const recipient = ctx.walletToUser.get(((log.args.recipient ?? "") as string).toLowerCase());
    const payout = unitsToCents((log.args.payout ?? 0n) as bigint);
    const fee = unitsToCents((log.args.fee ?? 0n) as bigint);
    const op = `${log.transactionHash}:${log.logIndex}`;
    if (recipient) {
      await post({
        opId: op,
        type: "payout",
        description: `Circle payout · round ${(log.args.round ?? 0n).toString()}`,
        userId: recipient,
        fromKey: acct.pool(circle.id),
        toKey: acct.wallet(recipient),
        amountCents: payout,
        txHash: log.transactionHash ?? "",
      });
    }
    await post({
      opId: `${op}:fee`,
      type: "fee",
      description: "Platform fee",
      userId: null,
      fromKey: acct.pool(circle.id),
      toKey: acct.fees,
      amountCents: fee,
      txHash: log.transactionHash ?? "",
    });
  }

  // Accumulation settlement (V2). The member's pool-ledger balance equals their
  // contributed principal; on settlement they redeem `payout` (+ `fee` to the
  // treasury), where payout+fee = the redeemed assets. We reconcile the pool's
  // ledger backing to the realized value FIRST, then move the funds out:
  //   realized = (payout + fee) − principal
  //     > 0  this member's accrued yield → credit yield → pool
  //     < 0  a realized loss             → debit  pool  → external
  //   = 0    no yield/loss (e.g. Passthrough launch, or a delinquent capped at
  //          principal — their forfeited yield STAYS in the pool and surfaces as
  //          other members' realized yield when they later withdraw).
  // §Phase4 default: yield is recognized at withdrawal (not accrued continuously).
  for (const log of accSettled) {
    const member = ctx.walletToUser.get(((log.args.member ?? "") as string).toLowerCase());
    if (!member) continue;
    const principal = unitsToCents((log.args.principal ?? 0n) as bigint);
    const payout = unitsToCents((log.args.payout ?? 0n) as bigint);
    const fee = unitsToCents((log.args.fee ?? 0n) as bigint);
    const op = `${log.transactionHash}:${log.logIndex}`;
    const realized = payout + fee - principal;
    if (realized > 0) {
      await post({
        opId: `${op}:yield`,
        type: "yield",
        description: "Savings yield",
        userId: member,
        fromKey: acct.yield,
        toKey: acct.pool(circle.id),
        amountCents: realized,
        txHash: log.transactionHash ?? "",
      });
    } else if (realized < 0) {
      await post({
        opId: `${op}:loss`,
        type: "loss",
        description: "Savings loss",
        userId: member,
        fromKey: acct.pool(circle.id),
        toKey: acct.external,
        amountCents: -realized,
        txHash: log.transactionHash ?? "",
      });
    }
    await post({
      opId: op,
      type: "payout",
      description: "Savings withdrawn",
      userId: member,
      fromKey: acct.pool(circle.id),
      toKey: acct.wallet(member),
      amountCents: payout,
      txHash: log.transactionHash ?? "",
    });
    await post({
      opId: `${op}:fee`,
      type: "fee",
      description: "Platform fee",
      userId: null,
      fromKey: acct.pool(circle.id),
      toKey: acct.fees,
      amountCents: fee,
      txHash: log.transactionHash ?? "",
    });
  }

  for (const log of refunded) {
    const member = ctx.walletToUser.get(((log.args.member ?? "") as string).toLowerCase());
    if (!member) continue;
    await post({
      opId: `${log.transactionHash}:${log.logIndex}`,
      type: "refund",
      description: "Circle refund",
      userId: member,
      fromKey: acct.pool(circle.id),
      toKey: acct.wallet(member),
      amountCents: unitsToCents((log.args.amount ?? 0n) as bigint),
      txHash: log.transactionHash ?? "",
    });
  }
}

async function indexGoalVault(ctx: Ctx, from: bigint, to: bigint) {
  if (!GOAL_VAULT) return;
  const vault = getAddress(GOAL_VAULT);
  const pub = publicClient();
  const [deposits, withdrawals] = await Promise.all([
    pub.getLogs({ address: vault, event: E_GOAL_DEPOSITED, fromBlock: from, toBlock: to }),
    pub.getLogs({ address: vault, event: E_GOAL_WITHDRAWN, fromBlock: from, toBlock: to }),
  ]);

  for (const log of deposits) {
    const goal = ctx.goalByHash.get(((log.args.goalId ?? "") as string).toLowerCase());
    if (!goal) continue;
    // L1 — the vault keys slots by (owner, goalId), so a deposit made under a goalId
    // that belongs to someone else is the DEPOSITOR's own slot, not this goal. Only
    // credit when the on-chain depositor is the goal's owner; never cross-credit.
    if (ctx.walletToUser.get(((log.args.owner ?? "") as string).toLowerCase()) !== goal.userId) continue;
    await post({
      opId: `${log.transactionHash}:${log.logIndex}`,
      type: "goal_allocate",
      description: "Goal deposit",
      userId: goal.userId,
      fromKey: acct.wallet(goal.userId),
      toKey: acct.goal(goal.goalId),
      amountCents: unitsToCents((log.args.amount ?? 0n) as bigint),
      txHash: log.transactionHash ?? "",
    });
  }

  // NOTE (goal yield): GoalVaultV2's GoalWithdrawn carries only grossAmount/fee, no
  // principal/yield split — so goal *yield* cannot be reconciled from the event the
  // way accumulation can. Correct as-is on the Passthrough adapter (no yield). When
  // the Curvance adapter is switched on, enrich GoalWithdrawn (emit principal/yield
  // or shares) and add the same yield/loss posting here. Tracked as M7 follow-up.
  for (const log of withdrawals) {
    const goal = ctx.goalByHash.get(((log.args.goalId ?? "") as string).toLowerCase());
    if (!goal) continue;
    // L1 — same ownership guard as deposits (the withdrawer must be the goal owner).
    if (ctx.walletToUser.get(((log.args.owner ?? "") as string).toLowerCase()) !== goal.userId) continue;
    const gross = unitsToCents((log.args.grossAmount ?? 0n) as bigint);
    const fee = unitsToCents((log.args.fee ?? 0n) as bigint);
    const op = `${log.transactionHash}:${log.logIndex}`;
    await post({
      opId: op,
      type: "goal_release",
      description: "Goal withdrawal",
      userId: goal.userId,
      fromKey: acct.goal(goal.goalId),
      toKey: acct.wallet(goal.userId),
      amountCents: gross - fee,
      txHash: log.transactionHash ?? "",
    });
    await post({
      opId: `${op}:fee`,
      type: "fee",
      description: "Platform fee",
      userId: null,
      fromKey: acct.goal(goal.goalId),
      toKey: acct.fees,
      amountCents: fee,
      txHash: log.transactionHash ?? "",
    });
  }
}

let running = false;

/** One indexing pass over recent blocks. Safe to call concurrently (guarded). */
export async function runIndexer(): Promise<void> {
  if (running) return;
  running = true;
  try {
    const pub = publicClient();
    const latest = await pub.getBlockNumber();
    const from = latest > BLOCK_LOOKBACK ? latest - BLOCK_LOOKBACK : 0n;
    const ctx = await loadContext();
    for (const [addr, circle] of ctx.circles) {
      try {
        await indexCircle(getAddress(addr), circle, ctx, from, latest);
      } catch (e) {
        logger.warn({ err: e instanceof Error ? e.message : String(e), circle: circle.id }, "circle index failed");
      }
    }
    try {
      await indexGoalVault(ctx, from, latest);
    } catch (e) {
      logger.warn({ err: e instanceof Error ? e.message : String(e) }, "goal-vault index failed");
    }
  } catch (e) {
    logger.warn({ err: e instanceof Error ? e.message : String(e) }, "indexer pass failed");
  } finally {
    running = false;
  }
}

let loopStarted = false;

/** Start the indexer interval. Call once at server boot. */
export function startIndexerLoop(): void {
  if (loopStarted || !indexerEnabled()) return;
  loopStarted = true;
  const timer = setInterval(() => {
    void runIndexer().catch((e) => logger.warn({ err: e }, "indexer tick failed"));
  }, INDEX_INTERVAL_MS);
  timer.unref();
  void runIndexer();
}
