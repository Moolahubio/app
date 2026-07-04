import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  getAddress,
  parseAbi,
  parseEventLogs,
  keccak256,
  toHex,
  formatEther,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { monadTestnet } from "viem/chains";

/**
 * Monad Testnet (EVM) chain integration via viem. USDC is an ERC-20 (6 decimals).
 *
 * Account generation and signing are local; reads, log queries, and submission
 * need network egress to the Monad RPC. Where that's unavailable, calls fail
 * gracefully so the ledger-backed app keeps working; real on-chain settlement
 * happens wherever the app runs with RPC access (Monad Testnet).
 */

// Monad Testnet (chainId 10143, MON gas). viem has no Monad mainnet chain, so
// there is no mainnet branch to select. Prefer CHAIN_RPC_URL; the legacy
// BASE_RPC_URL is still read for a clean transition (plan §7).
const CHAIN = monadTestnet;
const RPC_URL =
  process.env.CHAIN_RPC_URL || process.env.BASE_RPC_URL || "https://testnet-rpc.monad.xyz";
const USDC_ADDRESS = (process.env.USDC_CONTRACT_ADDRESS || "") as string;
const FACTORY_ADDRESS = (process.env.CIRCLE_FACTORY_ADDRESS || "") as string;
const GOAL_VAULT_ADDRESS = (process.env.GOAL_VAULT_ADDRESS || "") as string;

function platformKey(): Hex | undefined {
  const raw = process.env.PLATFORM_PRIVATE_KEY;
  if (!raw) return undefined;
  return (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
}

const USDC_DECIMALS = 6;
// Gas top-ups in MON (18-dp native; same wei math as ETH). Monad bills on the
// gas LIMIT, not gas used, so per-tx cost runs higher than the gas consumed —
// these defaults are deliberately generous and overridable via env. [VERIFY]
// against real Monad costs before relying on them in production.
const GAS_TOPUP_WEI = BigInt(process.env.GAS_TOPUP_WEI ?? "50000000000000000"); // 0.05 MON
const GAS_MIN_WEI = BigInt(process.env.GAS_MIN_WEI ?? "10000000000000000"); // top up below 0.01 MON

const ERC20_ABI = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "event Transfer(address indexed from, address indexed to, uint256 value)",
]);

// MockUSDC (test USDC): 6 decimals, EIP-2612 permit, and a permissionless mint
// used by the faucet. The escrow pulls contributions via transferFrom, so each
// member approves the escrow before contributing.
const MOCK_USDC_ABI = parseAbi([
  "function mint(address to, uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
]);

const FACTORY_ABI = parseAbi([
  "function createCircle(bytes32 circleId, uint256 contributionAmount, address[] members, uint64 roundDuration, uint64 gracePeriod) returns (address)",
  "function escrowOf(bytes32 circleId) view returns (address)",
  "function predictAddress(bytes32 circleId) view returns (address)",
]);

const ESCROW_ABI = parseAbi([
  "function contribute()",
  "function currentRound() view returns (uint256)",
  "function status() view returns (uint8)",
  "function hasContributed(uint256 round, address member) view returns (bool)",
  // A member's own collateral withheld from an earlier payout (see
  // MoolaHubSusuEscrow's reserve mechanism). Always an exact multiple of the
  // circle's contribution amount. When it covers a future round, the escrow
  // draws from it instead of pulling a fresh transfer from the member.
  "function heldReserve(address member) view returns (uint256)",
  "event Contributed(address indexed member, uint256 indexed round, uint256 amount)",
  "event RoundSettled(uint256 indexed round, address indexed recipient, uint256 payout, uint256 fee)",
  "event ReserveWithheld(address indexed member, uint256 amount)",
  "event ReserveDrawn(address indexed member, uint256 indexed round, uint256 amount)",
  "event ReserveForfeited(address indexed member, uint256 amount)",
]);

// Singleton GoalVault: holds USDC per (owner, goalId). Deposits are free;
// withdrawals charge a 2% fee to the treasury, collected on-chain. At the
// contract level only the owning account can withdraw its own balance — but
// the platform currently custodies that account's private key server-side
// and signs on its behalf, so this is access control against OTHER users,
// not a non-custodial guarantee against the platform itself (see wallet.ts).
const GOAL_VAULT_ABI = parseAbi([
  "function deposit(bytes32 goalId, uint256 amount)",
  "function withdraw(bytes32 goalId, uint256 grossAmount)",
  "function balanceOf(address owner, bytes32 goalId) view returns (uint256)",
  "function quoteWithdraw(uint256 grossAmount) view returns (uint256 net, uint256 fee)",
  "function quoteWithdrawFor(address owner, bytes32 goalId, uint256 grossAmount) view returns (uint256 net, uint256 fee)",
  "function lockedFeeBpsOf(address owner, bytes32 goalId) view returns (uint16)",
  "function feeBps() view returns (uint16)",
  "event GoalDeposited(address indexed owner, bytes32 indexed goalId, uint256 amount)",
  "event GoalWithdrawn(address indexed owner, bytes32 indexed goalId, uint256 grossAmount, uint256 fee)",
]);

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export type OnchainResult =
  | { status: "confirmed"; hash: string }
  | { status: "queued"; hash: string; xdr: string; reason: string }
  | { status: "skipped"; reason: string };

export type IncomingPayment = {
  opId: string;
  hash: string;
  amountCents: number;
  from: string;
};

function publicClient() {
  return createPublicClient({ chain: CHAIN, transport: http(RPC_URL) });
}

function walletClientFor(privateKey: Hex) {
  return createWalletClient({
    account: privateKeyToAccount(privateKey),
    chain: CHAIN,
    transport: http(RPC_URL),
  });
}

/** Whether on-chain operations are configured (platform key + USDC contract). */
export function onchainEnabled(): boolean {
  return Boolean(platformKey() && USDC_ADDRESS);
}

/**
 * Whether the test-USDC faucet may mint balances. The faucet is a *testnet
 * convenience only* — it credits the ledger without a real funding source, so
 * it must never be reachable on mainnet (where it would let any user mint
 * spendable balance from nothing).
 *
 * On non-mainnet the faucet is **disabled by default** to prevent production
 * deployments on testnets (e.g. Monad Testnet) from being an open synthetic
 * funding endpoint. An operator may explicitly opt in by setting
 * `ENABLE_TEST_FAUCET=true` only in intentional dev/test environments.
 */
export function faucetEnabled(): boolean {
  // Opt-in only (synthetic funding with no real source); no Monad mainnet target exists.
  return process.env.ENABLE_TEST_FAUCET === "true";
}

/**
 * Whether on-chain deposit sync (`POST /wallet/sync`) is allowed to credit
 * incoming USDC transfers into the ledger.
 *
 * On mainnet the configured USDC is the real asset, so sync is enabled by
 * default. On any non-mainnet deployment the configured token is typically a
 * mock-mintable asset (e.g. MockUSDC on Monad Testnet): any caller can invoke
 * `mint(userWallet, amount)` from any EOA, then trigger sync to import those
 * fabricated tokens as real spendable balance. To prevent that attack, sync is
 * **disabled by default on non-mainnet** and can only be turned on when an
 * operator explicitly sets `ENABLE_DEPOSIT_SYNC=true` (for testnets that use a
 * genuinely non-mintable token).
 */
export function depositSyncEnabled(): boolean {
  // Opt-in only: a mock-mintable testnet token would otherwise let anyone mint
  // then sync fabricated balance into the ledger. No Monad mainnet target exists yet.
  return process.env.ENABLE_DEPOSIT_SYNC === "true";
}

/**
 * Whether NEW wallets are provisioned as non-custodial Privy embedded EOAs
 * (custody='privy') instead of legacy server-custody wallets. Off by default:
 * the client-signed withdrawal path must be verified end-to-end top-level before
 * new users are made non-custodial. Existing server-custody wallets are
 * unaffected by this flag either way (dual custody).
 */
export function privyCustodyEnabled(): boolean {
  return process.env.ENABLE_PRIVY_CUSTODY === "true";
}

export function usdcContract(): Address | null {
  return USDC_ADDRESS && isAddress(USDC_ADDRESS) ? getAddress(USDC_ADDRESS) : null;
}

/** The platform account address (escrow / distributor), if configured. */
export function platformAddress(): string | null {
  const pk = platformKey();
  if (!pk) return null;
  try {
    return privateKeyToAccount(pk).address;
  } catch {
    return null;
  }
}

export function networkName(): string {
  return "monad-testnet";
}

export function explorerUrl(): string {
  return (
    process.env.CHAIN_EXPLORER_URL || process.env.MONAD_EXPLORER_URL || "https://testnet.monadvision.com"
  );
}

/** Generate a fresh EVM account (offline). */
export function generateAccount(): { address: string; privateKey: string } {
  const privateKey = generatePrivateKey();
  return { address: privateKeyToAccount(privateKey).address, privateKey };
}

/** Validate an EVM (0x…) address. */
export function isValidAddress(addr: string): boolean {
  try {
    return isAddress(addr);
  } catch {
    return false;
  }
}

const CENTS_PER_UNIT = 10n ** BigInt(USDC_DECIMALS - 2);

/** integer cents (1/100 USDC) -> USDC base units (6 dp). */
export function centsToUnits(cents: number): bigint {
  return BigInt(Math.round(cents)) * CENTS_PER_UNIT;
}

/** USDC base units (6 dp) -> integer cents. */
export function unitsToCents(units: bigint): number {
  return Math.round(Number(units / CENTS_PER_UNIT));
}

function errMsg(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}

/**
 * Whether a failed tx submission is a *transient* rejection from Monad's
 * load-balanced RPC (read-your-write lag), not a genuine revert. A stale
 * `getTransactionCount` from a lagging node collides two txs on one nonce
 * ("existing transaction had higher priority" / "nonce too low"), and a freshly
 * funded balance may not be visible yet ("insufficient balance"). All are
 * pre-inclusion rejections — the tx never entered the mempool — so re-sending is
 * safe.
 */
function isTransientSubmitError(e: unknown): boolean {
  const m = errMsg(e).toLowerCase();
  return (
    m.includes("higher priority") ||
    m.includes("nonce too low") ||
    m.includes("replacement transaction underpriced") ||
    m.includes("insufficient balance")
  );
}

/**
 * Best-effort: scan a short window of recent blocks for a transaction FROM
 * `address` that used `nonce` AND was sent `to` the expected contract/target.
 * There is no RPC method that directly answers "what landed at this nonce",
 * so we walk recent blocks looking for it. Used to detect a broadcast that
 * actually reached the chain right before a transient submit error, so a
 * retry doesn't blindly resend on a fresh nonce and double the action. Monad's
 * ~400ms blocks make ~50 blocks cover the ~15-20s a `submitTx` retry loop
 * spans.
 *
 * The `to` check matters: `nonceBefore` is read from a possibly-lagging
 * load-balanced RPC node, so it can be stale (behind the account's true
 * on-chain nonce). If we trusted "any mined tx at that nonce" without
 * checking its destination, a stale nonce could match a completely unrelated
 * prior transaction from the same signer (e.g. a gas top-up or a different
 * money-movement call) and get misreported as "the intended tx already
 * landed" — silently skipping the real send. Matching `to` as well rules that
 * out; it is still not a full guarantee (calldata could differ against the
 * same contract), which is why this is only used to avoid a same-attempt
 * double-broadcast, not as the sole cross-attempt idempotency mechanism (see
 * the `knownTxHash` reconciliation in the money-movement functions below).
 */
async function findMinedTxByNonce(
  address: Address,
  nonce: number,
  to: Address,
  lookbackBlocks = 50n,
): Promise<Hex | null> {
  try {
    const pub = publicClient();
    const latest = await pub.getBlockNumber();
    const from = latest > lookbackBlocks ? latest - lookbackBlocks : 0n;
    for (let bn = latest; bn >= from; bn--) {
      const block = await pub.getBlock({ blockNumber: bn, includeTransactions: true });
      for (const t of block.transactions) {
        if (typeof t === "string") continue;
        if (
          t.from.toLowerCase() === address.toLowerCase() &&
          t.nonce === nonce &&
          t.to?.toLowerCase() === to.toLowerCase()
        ) {
          return t.hash;
        }
      }
      if (bn === 0n) break;
    }
  } catch {
    /* best-effort — fall through and let the caller retry normally */
  }
  return null;
}

/**
 * Submit a transaction (returning its hash) with bounded retries for the
 * transient RPC rejections above. viem re-fetches a fresh nonce each attempt, so
 * once the lagging node catches up the send goes through. Genuine reverts and
 * config errors are not matched and surface immediately.
 *
 * Idempotency guard: if the RPC response for the first broadcast was lost but
 * the tx actually landed, blindly resending on the fresh nonce viem fetches
 * would submit a second, distinct transaction — double-debiting a withdrawal,
 * double-paying a payout, etc. When `account` AND `to` are supplied we
 * snapshot the account's pending nonce before the first attempt and, before
 * ANY retry, check whether a transaction at that nonce AND destination
 * already landed; if so we return that hash instead of resending. Callers
 * that move money should always pass both.
 */
async function submitTx(
  send: () => Promise<Hex>,
  opts?: { attempts?: number; account?: Address; to?: Address },
): Promise<Hex> {
  const attempts = opts?.attempts ?? 5;
  const account = opts?.account;
  const to = opts?.to;
  let nonceBefore: number | null = null;
  if (account && to) {
    try {
      nonceBefore = await publicClient().getTransactionCount({ address: account, blockTag: "pending" });
    } catch {
      nonceBefore = null;
    }
  }
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await send();
    } catch (e) {
      lastErr = e;
      if (i === attempts - 1 || !isTransientSubmitError(e)) throw e;
      if (account && to && nonceBefore != null) {
        const landed = await findMinedTxByNonce(account, nonceBefore, to);
        if (landed) return landed;
      }
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
  throw lastErr;
}

export type KnownHashOutcome =
  | { kind: "confirmed"; receipt: import("viem").TransactionReceipt }
  | { kind: "reverted" }
  | { kind: "pending" };

/**
 * Deterministically reconcile a PREVIOUSLY-PERSISTED tx hash (from an earlier
 * attempt on this same queue row) against on-chain state, rather than
 * guessing from coarse event matching (from/to/amount). This is the primary
 * cross-attempt idempotency mechanism for every money-moving call: settlement
 * callers persist the hash returned by `submitTx` (via `onSubmitted`) into the
 * queue row BEFORE waiting for a receipt, so a crash between submit and
 * confirm leaves an exact, unambiguous pointer to check next time — no
 * amount/address heuristics, no risk of matching an unrelated legitimate
 * transfer of the same amount.
 *
 * "pending" covers both "still in the mempool" and "unknown to this RPC node
 * (dropped, or a stale node)" — `getTransactionReceipt` can't distinguish
 * these, and treating "not found" as "safe to resend" is exactly the
 * double-send risk we're avoiding, so callers must NOT submit a fresh tx on
 * "pending" and should simply retry later instead.
 */
async function reconcileKnownHash(hash: Hex): Promise<KnownHashOutcome> {
  try {
    const receipt = await publicClient().getTransactionReceipt({ hash });
    return receipt.status === "reverted" ? { kind: "reverted" } : { kind: "confirmed", receipt };
  } catch {
    return { kind: "pending" };
  }
}

function isLikelyTxHash(h: string | null | undefined): h is Hex {
  return typeof h === "string" && /^0x[0-9a-fA-F]{64}$/.test(h);
}

/**
 * Poll until `address` reports at least `minWei` for several consecutive reads.
 *
 * Monad's public RPC is load-balanced with read-your-write lag: a freshly
 * credited native balance is not visible on every backend node at once, so a
 * user-signed tx submitted immediately after a gas top-up can be admitted by a
 * node that still sees a zero balance and rejected with "Signer had
 * insufficient balance". Requiring a short run of consecutive confirming reads
 * (each sampling a possibly-different node) waits out that lag before we let a
 * caller sign against the new balance. Mirrors the escrow-address poll in
 * `deployCircleEscrow`. Best-effort: returns after `timeoutMs` regardless.
 */
async function awaitBalanceVisible(
  address: Address,
  minWei: bigint,
  timeoutMs = 30_000,
): Promise<void> {
  const pub = publicClient();
  const deadline = Date.now() + timeoutMs;
  let streak = 0;
  while (Date.now() < deadline) {
    let bal = 0n;
    try {
      bal = await pub.getBalance({ address });
    } catch {
      /* transient RPC error — keep polling */
    }
    streak = bal >= minWei ? streak + 1 : 0;
    if (streak >= 4) return;
    await new Promise((r) => setTimeout(r, 1500));
  }
}

/**
 * Ensure a wallet holds enough MON for gas (testnet, platform-funded). Best
 * effort: silently no-ops if the platform key/RPC is unavailable.
 */
export async function ensureGas(address: string): Promise<void> {
  const pk = platformKey();
  if (!pk) return;
  try {
    const pub = publicClient();
    const addr = getAddress(address);
    const balance = await pub.getBalance({ address: addr });
    if (balance >= GAS_MIN_WEI) return;
    const wallet = walletClientFor(pk);
    const hash = await submitTx(() => wallet.sendTransaction({ to: addr, value: GAS_TOPUP_WEI }));
    await pub.waitForTransactionReceipt({ hash });
    // Wait out the load-balanced RPC's read-your-write lag so the freshly funded
    // gas is visible to whichever node admits the next user-signed tx.
    await awaitBalanceVisible(addr, GAS_MIN_WEI);
  } catch {
    /* gas top-up is best-effort on testnet */
  }
}

/**
 * Verify that `hash` is a MINED, SUCCESSFUL on-chain USDC transfer of exactly
 * `amountCents` from `from` to `to`.
 *
 * This is the sole source of truth for confirming a client-signed (non-custodial)
 * withdrawal: the server never signs it, so it must independently prove the money
 * left the user's wallet for the destination before booking the ledger. We match
 * the ERC-20 Transfer LOG emitted by the USDC contract — NOT the tx's top-level
 * `to`, which for a token transfer is the USDC contract, not the recipient. All
 * addresses are checksum-normalized, and we require EXACTLY ONE matching Transfer
 * so a tx that also moves an unrelated amount can't slip a wrong booking through.
 */
export async function verifyUsdcTransferReceipt(params: {
  hash: string;
  from: string;
  to: string;
  amountCents: number;
}): Promise<{ ok: true } | { ok: false; reason: string }> {
  const usdc = usdcContract();
  if (!usdc) return { ok: false, reason: "onchain-not-configured" };
  const hash = params.hash;
  if (!isLikelyTxHash(hash)) return { ok: false, reason: "malformed-hash" };
  if (!isValidAddress(params.from) || !isValidAddress(params.to)) {
    return { ok: false, reason: "malformed-address" };
  }

  let receipt: import("viem").TransactionReceipt;
  try {
    receipt = await publicClient().waitForTransactionReceipt({ hash, timeout: 60_000 });
  } catch {
    return { ok: false, reason: "receipt-unavailable" };
  }
  if (receipt.status !== "success") return { ok: false, reason: "tx-reverted" };

  const want = centsToUnits(params.amountCents);
  const fromAddr = getAddress(params.from);
  const toAddr = getAddress(params.to);
  const transfers = parseEventLogs({ abi: ERC20_ABI, eventName: "Transfer", logs: receipt.logs });
  const matches = transfers.filter((log) => {
    try {
      const args = log.args as { from: string; to: string; value: bigint };
      return (
        getAddress(log.address) === usdc &&
        getAddress(args.from) === fromAddr &&
        getAddress(args.to) === toAddr &&
        args.value === want
      );
    } catch {
      return false;
    }
  });
  if (matches.length !== 1) {
    return { ok: false, reason: `expected one USDC Transfer, found ${matches.length}` };
  }
  return { ok: true };
}

/**
 * Verify a client-signed goal-vault DEPOSIT the server never signed. Matches the
 * `GoalDeposited(owner, goalId, amount)` LOG emitted by the vault — bound to the
 * owning wallet, the goal's on-chain id, and the exact amount — and requires
 * EXACTLY ONE so a tx that also moves unrelated funds can't slip a wrong booking
 * through. Mirrors `verifyUsdcTransferReceipt`.
 */
export async function verifyGoalDepositReceipt(params: {
  hash: string;
  owner: string;
  goalId: string;
  amountCents: number;
}): Promise<{ ok: true } | { ok: false; reason: string }> {
  const vault = goalVaultContract();
  if (!vault) return { ok: false, reason: "onchain-not-configured" };
  const hash = params.hash;
  if (!isLikelyTxHash(hash)) return { ok: false, reason: "malformed-hash" };
  if (!isValidAddress(params.owner)) return { ok: false, reason: "malformed-address" };

  let receipt: import("viem").TransactionReceipt;
  try {
    receipt = await publicClient().waitForTransactionReceipt({ hash, timeout: 60_000 });
  } catch {
    return { ok: false, reason: "receipt-unavailable" };
  }
  if (receipt.status !== "success") return { ok: false, reason: "tx-reverted" };

  const want = centsToUnits(params.amountCents);
  const ownerAddr = getAddress(params.owner);
  const goalKey = goalIdToBytes32(params.goalId).toLowerCase();
  const events = parseEventLogs({ abi: GOAL_VAULT_ABI, eventName: "GoalDeposited", logs: receipt.logs });
  const matches = events.filter((log) => {
    try {
      const args = log.args as { owner: string; goalId: string; amount: bigint };
      return (
        getAddress(log.address) === vault &&
        getAddress(args.owner) === ownerAddr &&
        args.goalId.toLowerCase() === goalKey &&
        args.amount === want
      );
    } catch {
      return false;
    }
  });
  if (matches.length !== 1) {
    return { ok: false, reason: `expected one GoalDeposited, found ${matches.length}` };
  }
  return { ok: true };
}

/**
 * Verify a client-signed goal-vault WITHDRAWAL. Matches the
 * `GoalWithdrawn(owner, goalId, grossAmount, fee)` LOG bound to owner/goal/gross,
 * requires exactly one, and RETURNS the on-chain fee (in cents) so the caller
 * books net = gross − fee straight from the chain rather than re-deriving it.
 */
export async function verifyGoalWithdrawReceipt(params: {
  hash: string;
  owner: string;
  goalId: string;
  grossCents: number;
}): Promise<{ ok: true; feeCents: number } | { ok: false; reason: string }> {
  const vault = goalVaultContract();
  if (!vault) return { ok: false, reason: "onchain-not-configured" };
  const hash = params.hash;
  if (!isLikelyTxHash(hash)) return { ok: false, reason: "malformed-hash" };
  if (!isValidAddress(params.owner)) return { ok: false, reason: "malformed-address" };

  let receipt: import("viem").TransactionReceipt;
  try {
    receipt = await publicClient().waitForTransactionReceipt({ hash, timeout: 60_000 });
  } catch {
    return { ok: false, reason: "receipt-unavailable" };
  }
  if (receipt.status !== "success") return { ok: false, reason: "tx-reverted" };

  const want = centsToUnits(params.grossCents);
  const ownerAddr = getAddress(params.owner);
  const goalKey = goalIdToBytes32(params.goalId).toLowerCase();
  const events = parseEventLogs({ abi: GOAL_VAULT_ABI, eventName: "GoalWithdrawn", logs: receipt.logs });
  const matches = events.filter((log) => {
    try {
      const args = log.args as { owner: string; goalId: string; grossAmount: bigint; fee: bigint };
      return (
        getAddress(log.address) === vault &&
        getAddress(args.owner) === ownerAddr &&
        args.goalId.toLowerCase() === goalKey &&
        args.grossAmount === want
      );
    } catch {
      return false;
    }
  });
  if (matches.length !== 1) {
    return { ok: false, reason: `expected one GoalWithdrawn, found ${matches.length}` };
  }
  const feeUnits = ((matches[0].args as { fee?: bigint }).fee ?? 0n) as bigint;
  return { ok: true, feeCents: unitsToCents(feeUnits) };
}

/**
 * Verify a client-signed escrow CONTRIBUTION. Matches the escrow's
 * `Contributed(member, round, amount)` LOG (emitted at the full contribution
 * amount even when a reserve covers it — so this must match the event, never a
 * raw USDC Transfer) bound to member/round/amount, and also returns
 * `settledRound` when the same tx emitted `RoundSettled` (the escrow settled the
 * round atomically as this contribution filled it).
 */
export async function verifyEscrowContributeReceipt(params: {
  hash: string;
  escrow: string;
  member: string;
  round: number;
  amountCents: number;
}): Promise<{ ok: true; settledRound: number | null } | { ok: false; reason: string }> {
  const hash = params.hash;
  if (!isLikelyTxHash(hash)) return { ok: false, reason: "malformed-hash" };
  if (!isValidAddress(params.escrow) || !isValidAddress(params.member)) {
    return { ok: false, reason: "malformed-address" };
  }

  let receipt: import("viem").TransactionReceipt;
  try {
    receipt = await publicClient().waitForTransactionReceipt({ hash, timeout: 60_000 });
  } catch {
    return { ok: false, reason: "receipt-unavailable" };
  }
  if (receipt.status !== "success") return { ok: false, reason: "tx-reverted" };

  const want = centsToUnits(params.amountCents);
  const escrowAddr = getAddress(params.escrow);
  const memberAddr = getAddress(params.member);
  const events = parseEventLogs({ abi: ESCROW_ABI, eventName: "Contributed", logs: receipt.logs });
  const matches = events.filter((log) => {
    try {
      const args = log.args as { member: string; round: bigint; amount: bigint };
      return (
        getAddress(log.address) === escrowAddr &&
        getAddress(args.member) === memberAddr &&
        args.round === BigInt(params.round) &&
        args.amount === want
      );
    } catch {
      return false;
    }
  });
  if (matches.length !== 1) {
    return { ok: false, reason: `expected one Contributed, found ${matches.length}` };
  }
  let settledRound: number | null = null;
  try {
    const settled = parseEventLogs({ abi: ESCROW_ABI, eventName: "RoundSettled", logs: receipt.logs });
    const fromEscrow = settled.filter((l) => getAddress(l.address) === escrowAddr);
    if (fromEscrow.length > 0) settledRound = Number(fromEscrow[0].args.round);
  } catch {
    /* best-effort: settlement is also resolvable on-chain via findRoundSettledTx */
  }
  return { ok: true, settledRound };
}

/**
 * Resolve the tx hash of a circle round's `RoundSettled` event on-chain. The
 * escrow settles a round atomically as its last contribution lands, but
 * client-signed confirms can arrive at the backend OUT OF on-chain order — so
 * the confirm that fills the DB round is not necessarily the one whose receipt
 * carried `RoundSettled`. Rather than trust a per-confirm hint, the payout
 * booker queries the chain at DB-round-fill time (by then every contribution is
 * mined, so the event is present). Returns null when not yet settled on-chain
 * (mixed custody: a server member's contribution is still pending) so the caller
 * books the payout pending and the reconciler backfills it later.
 */
export async function findRoundSettledTx(
  escrow: string,
  round: number,
  lookbackBlocks = 5000n,
): Promise<string | null> {
  if (!isValidAddress(escrow)) return null;
  try {
    const pub = publicClient();
    const latest = await pub.getBlockNumber();
    const fromBlock = latest > lookbackBlocks ? latest - lookbackBlocks : 0n;
    const logs = await pub.getContractEvents({
      address: getAddress(escrow),
      abi: ESCROW_ABI,
      eventName: "RoundSettled",
      args: { round: BigInt(round) },
      fromBlock,
      toBlock: latest,
    });
    if (logs.length === 0) return null;
    return (logs[logs.length - 1].transactionHash as string | null) ?? null;
  } catch {
    return null;
  }
}

/** Read a USDC balance, in cents. Returns 0 when the RPC is unreachable. */
export async function usdcBalance(address: string): Promise<number> {
  const usdc = usdcContract();
  if (!usdc) return 0;
  try {
    const units = await publicClient().readContract({
      address: usdc,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [getAddress(address)],
    });
    return unitsToCents(units as bigint);
  } catch {
    return 0;
  }
}

/**
 * Read a USDC balance in cents, THROWING when the RPC is unreachable. Use this
 * for money-movement gating (withdrawals, contributions, allocations) where a
 * silent 0 could wrongly block a funded user, and where an unverifiable balance
 * must fail closed rather than be assumed. The catch-to-0 `usdcBalance` above is
 * only for best-effort display wrappers that surface `balanceUnavailable`.
 */
export async function usdcBalanceStrict(address: string): Promise<number> {
  const usdc = usdcContract();
  if (!usdc) throw new Error("USDC contract not configured");
  const units = await publicClient().readContract({
    address: usdc,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [getAddress(address)],
  });
  return unitsToCents(units as bigint);
}

/** Read an ETH (native gas) balance, in wei. Returns null when unreachable. */
export async function ethBalanceWei(address: string): Promise<bigint | null> {
  try {
    return await publicClient().getBalance({ address: getAddress(address) });
  } catch {
    return null;
  }
}

export type PlatformBalances = {
  /** The platform distributor address, or null when no platform key is set. */
  address: string | null;
  /** ETH balance in wei (as a string), or null when unreachable / no address. */
  ethWei: string | null;
  /** Human-readable ETH balance (e.g. "0.0123"), or null. */
  ethFormatted: string | null;
  /** USDC balance in integer cents, or null when unreachable / no address. */
  usdcCents: number | null;
  /** Whether the RPC could be reached to read live balances. */
  reachable: boolean;
};

/**
 * Read the platform distributor wallet's ETH (gas) and USDC balances so an
 * operator can confirm it is funded enough to settle queued transfers. Network-
 * dependent; `reachable` is false (and balances null) when the RPC is down or no
 * platform key is configured.
 */
export async function platformBalances(): Promise<PlatformBalances> {
  const address = platformAddress();
  if (!address) {
    return { address: null, ethWei: null, ethFormatted: null, usdcCents: null, reachable: false };
  }
  const wei = await ethBalanceWei(address);
  if (wei === null) {
    return { address, ethWei: null, ethFormatted: null, usdcCents: null, reachable: false };
  }
  const usdc = usdcContract();
  let usdcCents: number | null = null;
  if (usdc) {
    try {
      const units = await publicClient().readContract({
        address: usdc,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [getAddress(address)],
      });
      usdcCents = unitsToCents(units as bigint);
    } catch {
      usdcCents = null;
    }
  }
  return {
    address,
    ethWei: wei.toString(),
    ethFormatted: formatEther(wei),
    usdcCents,
    reachable: true,
  };
}

/**
 * Send USDC from `fromPrivateKey` to `to`. Tops up gas first. Returns a
 * confirmed result with the tx hash, or "skipped" when the network is
 * unreachable.
 */
export async function sendUsdc(params: {
  fromPrivateKey: string;
  to: string;
  amountCents: number;
  memo?: string;
  /**
   * A tx hash persisted by the caller from a PRIOR attempt on this same queue
   * row (see `reconcileKnownHash`). When on-chain state shows it already
   * confirmed, we return it directly instead of resending — no amount/address
   * heuristics involved. When it's still pending/unknown, we do NOT resend
   * (that would risk a double-send if it later lands); the caller should
   * retry again later. Only pass this on retries (attempts > 0); the first
   * attempt has no prior hash to check.
   */
  knownTxHash?: string | null;
  /** Invoked with the broadcast hash immediately after submission succeeds,
   * before waiting for the receipt, so the caller can persist it as the new
   * `knownTxHash` for any future retry. */
  onSubmitted?: (hash: Hex) => Promise<void> | void;
}): Promise<OnchainResult> {
  const usdc = usdcContract();
  if (!usdc) return { status: "skipped", reason: "USDC contract not configured" };
  if (!isValidAddress(params.to)) return { status: "skipped", reason: "invalid destination" };
  try {
    const pk = (params.fromPrivateKey.startsWith("0x")
      ? params.fromPrivateKey
      : `0x${params.fromPrivateKey}`) as Hex;
    const account = privateKeyToAccount(pk);
    const to = getAddress(params.to);

    if (isLikelyTxHash(params.knownTxHash)) {
      const outcome = await reconcileKnownHash(params.knownTxHash);
      if (outcome.kind === "confirmed") return { status: "confirmed", hash: params.knownTxHash };
      if (outcome.kind === "pending") {
        return { status: "skipped", reason: "previous transfer still pending on-chain" };
      }
      // "reverted" — the prior attempt definitively failed on-chain; fall
      // through and submit a fresh transfer.
    }

    await ensureGas(account.address);
    const wallet = walletClientFor(pk);
    const pub = publicClient();
    const hash = await submitTx(
      () =>
        wallet.writeContract({
          address: usdc,
          abi: ERC20_ABI,
          functionName: "transfer",
          args: [to, centsToUnits(params.amountCents)],
        }),
      { account: account.address, to: usdc },
    );
    await params.onSubmitted?.(hash);
    await pub.waitForTransactionReceipt({ hash });
    return { status: "confirmed", hash };
  } catch (e) {
    return { status: "skipped", reason: `rpc unreachable: ${errMsg(e)}` };
  }
}

// ---- Susu escrow (on-chain rotation circles) ----------------------------

/** The CircleFactory address, if configured & valid. */
export function factoryContract(): Address | null {
  return FACTORY_ADDRESS && isAddress(FACTORY_ADDRESS) ? getAddress(FACTORY_ADDRESS) : null;
}

/** Whether on-chain Susu escrows can be deployed (platform key + factory). */
export function escrowEnabled(): boolean {
  return Boolean(platformKey() && factoryContract() && usdcContract());
}

/**
 * Deterministic on-chain id for a circle. The factory uses it as the clone salt
 * (one escrow per id), so it must be stable and unique per circle — we derive it
 * from the circle's UUID.
 */
export function circleIdToBytes32(circleId: string): Hex {
  return keccak256(toHex(circleId));
}

export type DeployEscrowResult =
  | { status: "confirmed"; hash: string; escrow: string }
  | { status: "skipped"; reason: string };

/**
 * Deploy (or look up) the on-chain Susu escrow for a rotation circle. The
 * platform is the factory owner, so it signs `createCircle`. `members` MUST be
 * ordered by payout round (index 0 → round 1 recipient) to match the contract's
 * positional settlement. Idempotent: if an escrow already exists for this
 * circle id, returns it without redeploying.
 */
export async function deployCircleEscrow(params: {
  circleId: string;
  contributionCents: number;
  members: string[];
  roundDurationSecs: number;
  gracePeriodSecs: number;
}): Promise<DeployEscrowResult> {
  const factory = factoryContract();
  const pk = platformKey();
  if (!factory || !pk) return { status: "skipped", reason: "factory not configured" };
  if (params.members.length < 2) return { status: "skipped", reason: "need at least 2 members" };
  if (params.members.some((m) => !isValidAddress(m)))
    return { status: "skipped", reason: "a member has no valid wallet" };
  try {
    const pub = publicClient();
    const id = circleIdToBytes32(params.circleId);

    const existing = (await pub.readContract({
      address: factory,
      abi: FACTORY_ABI,
      functionName: "escrowOf",
      args: [id],
    })) as Address;
    if (existing && existing !== ZERO_ADDRESS) {
      return { status: "confirmed", hash: "", escrow: getAddress(existing) };
    }

    const account = privateKeyToAccount(pk);
    const wallet = walletClientFor(pk);
    const hash = await submitTx(
      () =>
        wallet.writeContract({
          address: factory,
          abi: FACTORY_ABI,
          functionName: "createCircle",
          args: [
            id,
            centsToUnits(params.contributionCents),
            params.members.map((m) => getAddress(m)),
            BigInt(Math.max(1, Math.floor(params.roundDurationSecs))),
            BigInt(Math.max(0, Math.floor(params.gracePeriodSecs))),
          ],
        }),
      { account: account.address, to: factory },
    );
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      return { status: "skipped", reason: `createCircle reverted (tx ${hash})` };
    }

    // The public RPC is load-balanced, so an `escrowOf` read immediately after
    // the receipt can hit a node that hasn't yet caught up to the deploy block
    // and return the zero address. The observed read-your-write lag runs ~12s,
    // so poll up to ~30s (matching awaitBalanceVisible) before giving up.
    let escrow = ZERO_ADDRESS as Address;
    for (let i = 0; i < 20; i++) {
      escrow = (await pub.readContract({
        address: factory,
        abi: FACTORY_ABI,
        functionName: "escrowOf",
        args: [id],
      })) as Address;
      if (escrow && escrow !== ZERO_ADDRESS) break;
      await new Promise((r) => setTimeout(r, 1500));
    }
    if (!escrow || escrow === ZERO_ADDRESS) {
      return { status: "skipped", reason: "escrow address not found after deploy" };
    }
    return { status: "confirmed", hash, escrow: getAddress(escrow) };
  } catch (e) {
    return { status: "skipped", reason: `rpc unreachable: ${errMsg(e)}` };
  }
}

/**
 * Faucet: mint test USDC straight to a wallet (MockUSDC.mint is permissionless;
 * the platform just pays gas). Returns the mint tx hash or "skipped".
 */
export async function mintUsdc(params: {
  to: string;
  amountCents: number;
  knownTxHash?: string | null;
  onSubmitted?: (hash: Hex) => Promise<void> | void;
}): Promise<OnchainResult> {
  const usdc = usdcContract();
  const pk = platformKey();
  if (!usdc || !pk) return { status: "skipped", reason: "USDC/platform not configured" };
  if (!isValidAddress(params.to)) return { status: "skipped", reason: "invalid destination" };
  try {
    const account = privateKeyToAccount(pk);
    const to = getAddress(params.to);

    if (isLikelyTxHash(params.knownTxHash)) {
      const outcome = await reconcileKnownHash(params.knownTxHash);
      if (outcome.kind === "confirmed") return { status: "confirmed", hash: params.knownTxHash };
      if (outcome.kind === "pending") {
        return { status: "skipped", reason: "previous mint still pending on-chain" };
      }
    }

    const wallet = walletClientFor(pk);
    const pub = publicClient();
    const hash = await submitTx(
      () =>
        wallet.writeContract({
          address: usdc,
          abi: MOCK_USDC_ABI,
          functionName: "mint",
          args: [to, centsToUnits(params.amountCents)],
        }),
      { account: account.address, to: usdc },
    );
    await params.onSubmitted?.(hash);
    await pub.waitForTransactionReceipt({ hash });
    return { status: "confirmed", hash };
  } catch (e) {
    return { status: "skipped", reason: `rpc unreachable: ${errMsg(e)}` };
  }
}

/**
 * A member's own reserve held inside the escrow (in cents) — collateral
 * withheld from an earlier payout that covers their still-unpaid future
 * rounds. Callers use this to avoid blocking a legitimate future contribution
 * on the member's real wallet balance when their reserve already covers it.
 * Returns 0 (rather than throwing) when unreadable, so a transient RPC issue
 * degrades to the stricter (wallet-balance-only) check instead of failing the
 * whole gate.
 */
export async function escrowHeldReserveCents(escrow: string, member: string): Promise<number> {
  if (!isValidAddress(escrow) || !isValidAddress(member)) return 0;
  try {
    const pub = publicClient();
    const reserve = (await pub.readContract({
      address: getAddress(escrow),
      abi: ESCROW_ABI,
      functionName: "heldReserve",
      args: [getAddress(member)],
    })) as bigint;
    return unitsToCents(reserve);
  } catch {
    return 0;
  }
}

export type EscrowContributeResult =
  | { status: "confirmed"; hash: string; settledRound: number | null }
  | { status: "skipped"; reason: string };

/**
 * Look up the tx hash of a member's `Contributed` event for a specific round,
 * plus any `RoundSettled` emitted in the same transaction (the escrow
 * auto-settles a round when the last member's contribution lands). Used to
 * reconcile an already-landed contribution instead of resending it.
 */
async function findContributedTx(
  escrow: Address,
  round: number,
  member: Address,
  lookbackBlocks = 5000n,
): Promise<{ hash: Hex; settledRound: number | null } | null> {
  try {
    const pub = publicClient();
    const latest = await pub.getBlockNumber();
    const fromBlock = latest > lookbackBlocks ? latest - lookbackBlocks : 0n;
    const logs = await pub.getContractEvents({
      address: escrow,
      abi: ESCROW_ABI,
      eventName: "Contributed",
      args: { member, round: BigInt(round) },
      fromBlock,
      toBlock: latest,
    });
    if (logs.length === 0) return null;
    const hash = logs[logs.length - 1].transactionHash as Hex | null;
    if (!hash) return null;
    let settledRound: number | null = null;
    try {
      const receipt = await pub.getTransactionReceipt({ hash });
      const settled = parseEventLogs({ abi: ESCROW_ABI, eventName: "RoundSettled", logs: receipt.logs });
      if (settled.length > 0) settledRound = Number(settled[0].args.round);
    } catch {
      /* best-effort */
    }
    return { hash, settledRound };
  } catch {
    return null;
  }
}

/**
 * A member contributes to the on-chain escrow: approve the escrow to pull the
 * contribution (if the allowance is short) then call `contribute()`. The escrow
 * auto-settles the round when the last member contributes — when that happens
 * the receipt carries a `RoundSettled` event, whose round we return so the
 * caller can confirm the matching ledger payout.
 *
 * Idempotency: two layers, since `contribute()` takes no round argument.
 * 1) `knownTxHash` — a hash persisted by the caller from a PRIOR attempt on
 *    this same queue row (see `reconcileKnownHash`). Checked FIRST: if that
 *    exact tx is confirmed, we return it without touching the chain further;
 *    if it's still pending/unknown, we do NOT resend (a false "not found" on
 *    a lagging RPC node is exactly the double-send risk this avoids) — the
 *    caller should retry later instead.
 * 2) `hasContributed(round, member)` — a secondary, coarser guard for the
 *    case where no known hash exists yet (first attempt after a crash before
 *    any hash was persisted, or a hash reconciled as reverted). `round`
 *    (parsed from the queue row's memo) is the only safe key for this check:
 *    a replay after the round has already advanced would otherwise silently
 *    apply to whatever round is current on-chain (charging the member for the
 *    next round instead of the one they intended, or crediting the wrong
 *    round's payout) — which is why a missing round fails closed below rather
 *    than falling back to a raw `contribute()` call.
 */
export async function escrowContribute(params: {
  fromPrivateKey: string;
  escrow: string;
  amountCents: number;
  round?: number;
  knownTxHash?: string | null;
  onSubmitted?: (hash: Hex) => Promise<void> | void;
}): Promise<EscrowContributeResult> {
  const usdc = usdcContract();
  if (!usdc) return { status: "skipped", reason: "USDC contract not configured" };
  if (!isValidAddress(params.escrow)) return { status: "skipped", reason: "invalid escrow address" };
  // `round` is the ONLY safe fallback idempotency key for `contribute()` (see
  // above) — without it we cannot tell whether this member already
  // contributed this round, so we fail closed instead of blindly calling
  // `contribute()` and risking it silently applying to whatever round is
  // current on-chain.
  if (params.round == null) {
    return { status: "skipped", reason: "missing round — cannot safely verify contribution idempotency" };
  }
  try {
    const pk = (params.fromPrivateKey.startsWith("0x")
      ? params.fromPrivateKey
      : `0x${params.fromPrivateKey}`) as Hex;
    const account = privateKeyToAccount(pk);
    const escrow = getAddress(params.escrow);
    const amount = centsToUnits(params.amountCents);
    const pub = publicClient();
    const round = params.round;

    if (isLikelyTxHash(params.knownTxHash)) {
      const outcome = await reconcileKnownHash(params.knownTxHash);
      if (outcome.kind === "confirmed") {
        let settledRound: number | null = null;
        try {
          const settled = parseEventLogs({
            abi: ESCROW_ABI,
            eventName: "RoundSettled",
            logs: outcome.receipt.logs,
          });
          if (settled.length > 0) settledRound = Number(settled[0].args.round);
        } catch {
          /* best-effort */
        }
        return { status: "confirmed", hash: params.knownTxHash, settledRound };
      }
      if (outcome.kind === "pending") {
        return { status: "skipped", reason: "previous contribution still pending on-chain" };
      }
      // "reverted" — fall through to the hasContributed check / fresh submit.
    }

    const already = (await pub.readContract({
      address: escrow,
      abi: ESCROW_ABI,
      functionName: "hasContributed",
      args: [BigInt(round), account.address],
    })) as boolean;
    if (already) {
      const found = await findContributedTx(escrow, round, account.address);
      return {
        status: "confirmed",
        hash: found?.hash ?? "",
        settledRound: found?.settledRound ?? null,
      };
    }

    await ensureGas(account.address);
    const wallet = walletClientFor(pk);

    const allowance = (await pub.readContract({
      address: usdc,
      abi: MOCK_USDC_ABI,
      functionName: "allowance",
      args: [account.address, escrow],
    })) as bigint;
    if (allowance < amount) {
      const approveHash = await submitTx(
        () =>
          wallet.writeContract({
            address: usdc,
            abi: MOCK_USDC_ABI,
            functionName: "approve",
            args: [escrow, amount],
          }),
        { account: account.address, to: usdc },
      );
      await pub.waitForTransactionReceipt({ hash: approveHash });
    }

    const hash = await submitTx(
      () =>
        wallet.writeContract({
          address: escrow,
          abi: ESCROW_ABI,
          functionName: "contribute",
        }),
      { account: account.address, to: escrow },
    );
    await params.onSubmitted?.(hash);
    const receipt = await pub.waitForTransactionReceipt({ hash });

    let settledRound: number | null = null;
    try {
      const settled = parseEventLogs({
        abi: ESCROW_ABI,
        eventName: "RoundSettled",
        logs: receipt.logs,
      });
      if (settled.length > 0) settledRound = Number(settled[0].args.round);
    } catch {
      /* event decode best-effort; settlement is also visible on-chain */
    }
    return { status: "confirmed", hash, settledRound };
  } catch (e) {
    return { status: "skipped", reason: `rpc unreachable: ${errMsg(e)}` };
  }
}

// ---- Goal vault (on-chain savings goals) --------------------------------

/** The singleton GoalVault address, if configured & valid. */
export function goalVaultContract(): Address | null {
  return GOAL_VAULT_ADDRESS && isAddress(GOAL_VAULT_ADDRESS)
    ? getAddress(GOAL_VAULT_ADDRESS)
    : null;
}

/**
 * Whether goals can settle on-chain. Every deposit/withdraw transaction is
 * sent from the user's own on-chain address (not a pooled platform account),
 * so we only need the vault + USDC configured and a platform key to fund the
 * user's gas top-ups. Note: the platform currently holds and uses that
 * user's private key server-side (see wallet.ts) — this is per-account
 * on-chain attribution, not a non-custodial security guarantee.
 */
export function goalVaultEnabled(): boolean {
  return Boolean(platformKey() && goalVaultContract() && usdcContract());
}

/**
 * Deterministic on-chain id for a goal. The vault keys balances by
 * (owner, goalId), so this must be stable and unique per goal — we derive it
 * from the goal's UUID, mirroring how circles derive their escrow id.
 */
export function goalIdToBytes32(goalId: string): Hex {
  return keccak256(toHex(goalId));
}

/** Read a user's on-chain goal balance, in cents. 0 when RPC unreachable. */
export async function goalVaultBalance(owner: string, goalId: string): Promise<number> {
  const vault = goalVaultContract();
  if (!vault || !isValidAddress(owner)) return 0;
  try {
    const units = await publicClient().readContract({
      address: vault,
      abi: GOAL_VAULT_ABI,
      functionName: "balanceOf",
      args: [getAddress(owner), goalIdToBytes32(goalId)],
    });
    return unitsToCents(units as bigint);
  } catch {
    return 0;
  }
}

/**
 * Read a user's on-chain goal balance in cents, THROWING when the RPC is
 * unreachable or the vault isn't configured. Gating (releases, deletes) must
 * fail closed rather than treat an unreadable balance as 0.
 */
export async function goalVaultBalanceStrict(owner: string, goalId: string): Promise<number> {
  const vault = goalVaultContract();
  if (!vault) throw new Error("goal vault not configured");
  if (!isValidAddress(owner)) throw new Error("invalid owner address");
  const units = await publicClient().readContract({
    address: vault,
    abi: GOAL_VAULT_ABI,
    functionName: "balanceOf",
    args: [getAddress(owner), goalIdToBytes32(goalId)],
  });
  return unitsToCents(units as bigint);
}

export type GoalWithdrawResult =
  | { status: "confirmed"; hash: string; feeCents: number; netCents: number }
  | { status: "skipped"; reason: string };

/**
 * Deposit USDC into a user's goal balance in the vault. Deposits are free. The
 * vault pulls funds via `transferFrom`, so we approve it first when the
 * allowance is short, then call `deposit`. Signed by the user's key.
 */
export async function goalDeposit(params: {
  fromPrivateKey: string;
  goalId: string;
  amountCents: number;
  knownTxHash?: string | null;
  onSubmitted?: (hash: Hex) => Promise<void> | void;
}): Promise<OnchainResult> {
  const vault = goalVaultContract();
  const usdc = usdcContract();
  if (!vault || !usdc) return { status: "skipped", reason: "goal vault not configured" };
  try {
    const pk = (params.fromPrivateKey.startsWith("0x")
      ? params.fromPrivateKey
      : `0x${params.fromPrivateKey}`) as Hex;
    const account = privateKeyToAccount(pk);
    const amount = centsToUnits(params.amountCents);
    const goalId = goalIdToBytes32(params.goalId);
    const pub = publicClient();

    if (isLikelyTxHash(params.knownTxHash)) {
      const outcome = await reconcileKnownHash(params.knownTxHash);
      if (outcome.kind === "confirmed") return { status: "confirmed", hash: params.knownTxHash };
      if (outcome.kind === "pending") {
        return { status: "skipped", reason: "previous deposit still pending on-chain" };
      }
    }

    await ensureGas(account.address);
    const wallet = walletClientFor(pk);

    const allowance = (await pub.readContract({
      address: usdc,
      abi: MOCK_USDC_ABI,
      functionName: "allowance",
      args: [account.address, vault],
    })) as bigint;
    if (allowance < amount) {
      const approveHash = await submitTx(
        () =>
          wallet.writeContract({
            address: usdc,
            abi: MOCK_USDC_ABI,
            functionName: "approve",
            args: [vault, amount],
          }),
        { account: account.address, to: usdc },
      );
      await pub.waitForTransactionReceipt({ hash: approveHash });
    }

    const hash = await submitTx(
      () =>
        wallet.writeContract({
          address: vault,
          abi: GOAL_VAULT_ABI,
          functionName: "deposit",
          args: [goalId, amount],
        }),
      { account: account.address, to: vault },
    );
    await params.onSubmitted?.(hash);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      return { status: "skipped", reason: `goal deposit reverted (tx ${hash})` };
    }
    return { status: "confirmed", hash };
  } catch (e) {
    return { status: "skipped", reason: `rpc unreachable: ${errMsg(e)}` };
  }
}

/**
 * Withdraw `grossCents` from a user's goal balance. The vault sends the caller
 * `gross - 2% fee` and routes the fee to the treasury, all in one tx. Returns
 * the fee/net (in cents) parsed from the `GoalWithdrawn` event. Signed by the
 * user's key — only the owning account can withdraw its own balance.
 */
export async function goalWithdraw(params: {
  fromPrivateKey: string;
  goalId: string;
  grossCents: number;
  knownTxHash?: string | null;
  onSubmitted?: (hash: Hex) => Promise<void> | void;
}): Promise<GoalWithdrawResult> {
  const vault = goalVaultContract();
  if (!vault) return { status: "skipped", reason: "goal vault not configured" };
  try {
    const pk = (params.fromPrivateKey.startsWith("0x")
      ? params.fromPrivateKey
      : `0x${params.fromPrivateKey}`) as Hex;
    const account = privateKeyToAccount(pk);
    const goalId = goalIdToBytes32(params.goalId);
    const requested = centsToUnits(params.grossCents);
    const pub = publicClient();

    if (isLikelyTxHash(params.knownTxHash)) {
      const outcome = await reconcileKnownHash(params.knownTxHash);
      if (outcome.kind === "confirmed") {
        let feeUnits = 0n;
        try {
          const events = parseEventLogs({
            abi: GOAL_VAULT_ABI,
            eventName: "GoalWithdrawn",
            logs: outcome.receipt.logs,
          });
          if (events.length > 0) feeUnits = (events[0].args.fee ?? 0n) as bigint;
        } catch {
          /* best-effort */
        }
        const feeCents = unitsToCents(feeUnits);
        return {
          status: "confirmed",
          hash: params.knownTxHash,
          feeCents,
          netCents: unitsToCents(requested) - feeCents,
        };
      }
      if (outcome.kind === "pending") {
        return { status: "skipped", reason: "previous withdrawal still pending on-chain" };
      }
    }

    // The ledger is the source of truth for the user's app balance, but the
    // vault can only return what was actually deposited on-chain for this
    // (owner, goal). A goal funded while the vault was disabled — or whose
    // deposit never settled — has a smaller (possibly zero) on-chain balance
    // than the ledger. Cap the withdraw to the live on-chain balance so we never
    // pull more than exists: an over-withdraw reverts with `Insufficient`, which
    // exhausts retries and dead-letters the row. When nothing is on-chain there
    // is nothing to settle — report confirmed with no tx so the already-booked
    // pending ledger postings still get stamped.
    const onchainUnits = (await pub.readContract({
      address: vault,
      abi: GOAL_VAULT_ABI,
      functionName: "balanceOf",
      args: [account.address, goalId],
    })) as bigint;
    const gross = requested < onchainUnits ? requested : onchainUnits;
    if (gross === 0n) {
      return { status: "confirmed", hash: "", feeCents: 0, netCents: 0 };
    }

    await ensureGas(account.address);
    const wallet = walletClientFor(pk);

    const hash = await submitTx(
      () =>
        wallet.writeContract({
          address: vault,
          abi: GOAL_VAULT_ABI,
          functionName: "withdraw",
          args: [goalId, gross],
        }),
      { account: account.address, to: vault },
    );
    await params.onSubmitted?.(hash);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      return { status: "skipped", reason: `goal withdraw reverted (tx ${hash})` };
    }

    let feeUnits = 0n;
    try {
      const events = parseEventLogs({
        abi: GOAL_VAULT_ABI,
        eventName: "GoalWithdrawn",
        logs: receipt.logs,
      });
      if (events.length > 0) feeUnits = (events[0].args.fee ?? 0n) as bigint;
    } catch {
      /* event decode best-effort; the withdraw still settled on-chain */
    }
    const feeCents = unitsToCents(feeUnits);
    // Net is derived from what was actually withdrawn on-chain (`gross`), which
    // may have been capped below the requested amount above.
    return {
      status: "confirmed",
      hash,
      feeCents,
      netCents: unitsToCents(gross) - feeCents,
    };
  } catch (e) {
    return { status: "skipped", reason: `rpc unreachable: ${errMsg(e)}` };
  }
}

/**
 * Fetch incoming USDC transfers to `address` from recent blocks. Network-
 * dependent; returns [] when the RPC is unreachable. Deduped upstream by opId.
 */
export async function getIncomingUsdc(address: string): Promise<IncomingPayment[]> {
  const usdc = usdcContract();
  if (!usdc) return [];
  try {
    const pub = publicClient();
    const latest = await pub.getBlockNumber();
    // Monad's ~400ms blocks make a fixed 9k lookback cover only ~1h of wall-clock
    // (vs ~5h on Base). Widen to restore parity; a persisted high-water cursor is
    // the robust follow-up for outages longer than this window (plan §2.5).
    const lookback = BigInt(process.env.SYNC_BLOCK_LOOKBACK ?? "50000");
    const fromBlock = latest > lookback ? latest - lookback : 0n;
    const logs = await pub.getLogs({
      address: usdc,
      event: ERC20_ABI[2],
      args: { to: getAddress(address) },
      fromBlock,
      toBlock: latest,
    });
    return logs.map((log) => ({
      opId: `${log.transactionHash}:${log.logIndex}`,
      hash: log.transactionHash ?? "",
      amountCents: unitsToCents((log.args.value ?? 0n) as bigint),
      from: (log.args.from ?? "") as string,
    }));
  } catch {
    return [];
  }
}
