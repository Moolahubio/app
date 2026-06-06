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
import { base, baseSepolia } from "viem/chains";

/**
 * Base (EVM) chain integration via viem. USDC is an ERC-20 (6 decimals) on Base.
 *
 * Account generation and signing are local; reads, log queries, and submission
 * need network egress to the Base RPC. Where that's unavailable, calls fail
 * gracefully so the ledger-backed app keeps working; real on-chain settlement
 * happens wherever the app runs with RPC access (Base Sepolia).
 */

const IS_MAINNET = process.env.BASE_NETWORK === "mainnet";
const CHAIN = IS_MAINNET ? base : baseSepolia;
const RPC_URL =
  process.env.BASE_RPC_URL || (IS_MAINNET ? "https://mainnet.base.org" : "https://sepolia.base.org");
const USDC_ADDRESS = (process.env.USDC_CONTRACT_ADDRESS || "") as string;
const FACTORY_ADDRESS = (process.env.CIRCLE_FACTORY_ADDRESS || "") as string;
const GOAL_VAULT_ADDRESS = (process.env.GOAL_VAULT_ADDRESS || "") as string;

function platformKey(): Hex | undefined {
  const raw = process.env.PLATFORM_PRIVATE_KEY;
  if (!raw) return undefined;
  return (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
}

const USDC_DECIMALS = 6;
const GAS_TOPUP_WEI = 200_000_000_000_000n; // 0.0002 ETH — enough for a few testnet transfers
const GAS_MIN_WEI = 50_000_000_000_000n; // top up when below 0.00005 ETH

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
  "event Contributed(address indexed member, uint256 indexed round, uint256 amount)",
  "event RoundSettled(uint256 indexed round, address indexed recipient, uint256 payout, uint256 fee)",
]);

// Singleton GoalVault: holds USDC per (owner, goalId). Deposits are free;
// withdrawals charge a 2% fee to the treasury, collected on-chain. Strictly
// non-custodial — only the owning account can withdraw, so every goal action is
// signed by the user's key (the platform only pays gas).
const GOAL_VAULT_ABI = parseAbi([
  "function deposit(bytes32 goalId, uint256 amount)",
  "function withdraw(bytes32 goalId, uint256 grossAmount)",
  "function balanceOf(address owner, bytes32 goalId) view returns (uint256)",
  "function quoteWithdraw(uint256 grossAmount) view returns (uint256 net, uint256 fee)",
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
  return IS_MAINNET ? "base" : "base-sepolia";
}

export function explorerUrl(): string {
  return process.env.BASE_EXPLORER_URL || "https://sepolia.basescan.org";
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
 * Ensure a wallet holds enough ETH for gas (testnet, platform-funded). Best
 * effort: silently no-ops if the platform key/RPC is unavailable.
 */
export async function ensureGas(address: string): Promise<void> {
  const pk = platformKey();
  if (!pk) return;
  try {
    const pub = publicClient();
    const balance = await pub.getBalance({ address: getAddress(address) });
    if (balance >= GAS_MIN_WEI) return;
    const wallet = walletClientFor(pk);
    const hash = await wallet.sendTransaction({ to: getAddress(address), value: GAS_TOPUP_WEI });
    await pub.waitForTransactionReceipt({ hash });
  } catch {
    /* gas top-up is best-effort on testnet */
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
}): Promise<OnchainResult> {
  const usdc = usdcContract();
  if (!usdc) return { status: "skipped", reason: "USDC contract not configured" };
  if (!isValidAddress(params.to)) return { status: "skipped", reason: "invalid destination" };
  try {
    const pk = (params.fromPrivateKey.startsWith("0x")
      ? params.fromPrivateKey
      : `0x${params.fromPrivateKey}`) as Hex;
    const account = privateKeyToAccount(pk);
    await ensureGas(account.address);
    const wallet = walletClientFor(pk);
    const pub = publicClient();
    const hash = await wallet.writeContract({
      address: usdc,
      abi: ERC20_ABI,
      functionName: "transfer",
      args: [getAddress(params.to), centsToUnits(params.amountCents)],
    });
    await pub.waitForTransactionReceipt({ hash });
    return { status: "confirmed", hash };
  } catch (e) {
    return { status: "skipped", reason: `base rpc unreachable: ${errMsg(e)}` };
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

    const wallet = walletClientFor(pk);
    const hash = await wallet.writeContract({
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
    });
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      return { status: "skipped", reason: `createCircle reverted (tx ${hash})` };
    }

    // The public RPC is load-balanced, so an `escrowOf` read immediately after
    // the receipt can hit a node that hasn't yet caught up to the deploy block
    // and return the zero address. Poll a few times before giving up.
    let escrow = ZERO_ADDRESS as Address;
    for (let i = 0; i < 6; i++) {
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
    return { status: "skipped", reason: `base rpc unreachable: ${errMsg(e)}` };
  }
}

/**
 * Faucet: mint test USDC straight to a wallet (MockUSDC.mint is permissionless;
 * the platform just pays gas). Returns the mint tx hash or "skipped".
 */
export async function mintUsdc(params: { to: string; amountCents: number }): Promise<OnchainResult> {
  const usdc = usdcContract();
  const pk = platformKey();
  if (!usdc || !pk) return { status: "skipped", reason: "USDC/platform not configured" };
  if (!isValidAddress(params.to)) return { status: "skipped", reason: "invalid destination" };
  try {
    const wallet = walletClientFor(pk);
    const pub = publicClient();
    const hash = await wallet.writeContract({
      address: usdc,
      abi: MOCK_USDC_ABI,
      functionName: "mint",
      args: [getAddress(params.to), centsToUnits(params.amountCents)],
    });
    await pub.waitForTransactionReceipt({ hash });
    return { status: "confirmed", hash };
  } catch (e) {
    return { status: "skipped", reason: `base rpc unreachable: ${errMsg(e)}` };
  }
}

export type EscrowContributeResult =
  | { status: "confirmed"; hash: string; settledRound: number | null }
  | { status: "skipped"; reason: string };

/**
 * A member contributes to the on-chain escrow: approve the escrow to pull the
 * contribution (if the allowance is short) then call `contribute()`. The escrow
 * auto-settles the round when the last member contributes — when that happens
 * the receipt carries a `RoundSettled` event, whose round we return so the
 * caller can confirm the matching ledger payout.
 */
export async function escrowContribute(params: {
  fromPrivateKey: string;
  escrow: string;
  amountCents: number;
}): Promise<EscrowContributeResult> {
  const usdc = usdcContract();
  if (!usdc) return { status: "skipped", reason: "USDC contract not configured" };
  if (!isValidAddress(params.escrow)) return { status: "skipped", reason: "invalid escrow address" };
  try {
    const pk = (params.fromPrivateKey.startsWith("0x")
      ? params.fromPrivateKey
      : `0x${params.fromPrivateKey}`) as Hex;
    const account = privateKeyToAccount(pk);
    const escrow = getAddress(params.escrow);
    const amount = centsToUnits(params.amountCents);
    await ensureGas(account.address);
    const wallet = walletClientFor(pk);
    const pub = publicClient();

    const allowance = (await pub.readContract({
      address: usdc,
      abi: MOCK_USDC_ABI,
      functionName: "allowance",
      args: [account.address, escrow],
    })) as bigint;
    if (allowance < amount) {
      const approveHash = await wallet.writeContract({
        address: usdc,
        abi: MOCK_USDC_ABI,
        functionName: "approve",
        args: [escrow, amount],
      });
      await pub.waitForTransactionReceipt({ hash: approveHash });
    }

    const hash = await wallet.writeContract({
      address: escrow,
      abi: ESCROW_ABI,
      functionName: "contribute",
    });
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
    return { status: "skipped", reason: `base rpc unreachable: ${errMsg(e)}` };
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
 * Whether goals can settle on-chain. The vault is non-custodial (the user signs
 * their own deposit/withdraw), so we only need the vault + USDC configured and a
 * platform key to fund the user's gas top-ups.
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
    await ensureGas(account.address);
    const wallet = walletClientFor(pk);
    const pub = publicClient();

    const allowance = (await pub.readContract({
      address: usdc,
      abi: MOCK_USDC_ABI,
      functionName: "allowance",
      args: [account.address, vault],
    })) as bigint;
    if (allowance < amount) {
      const approveHash = await wallet.writeContract({
        address: usdc,
        abi: MOCK_USDC_ABI,
        functionName: "approve",
        args: [vault, amount],
      });
      await pub.waitForTransactionReceipt({ hash: approveHash });
    }

    const hash = await wallet.writeContract({
      address: vault,
      abi: GOAL_VAULT_ABI,
      functionName: "deposit",
      args: [goalId, amount],
    });
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      return { status: "skipped", reason: `goal deposit reverted (tx ${hash})` };
    }
    return { status: "confirmed", hash };
  } catch (e) {
    return { status: "skipped", reason: `base rpc unreachable: ${errMsg(e)}` };
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
}): Promise<GoalWithdrawResult> {
  const vault = goalVaultContract();
  if (!vault) return { status: "skipped", reason: "goal vault not configured" };
  try {
    const pk = (params.fromPrivateKey.startsWith("0x")
      ? params.fromPrivateKey
      : `0x${params.fromPrivateKey}`) as Hex;
    const account = privateKeyToAccount(pk);
    const gross = centsToUnits(params.grossCents);
    const goalId = goalIdToBytes32(params.goalId);
    await ensureGas(account.address);
    const wallet = walletClientFor(pk);
    const pub = publicClient();

    const hash = await wallet.writeContract({
      address: vault,
      abi: GOAL_VAULT_ABI,
      functionName: "withdraw",
      args: [goalId, gross],
    });
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
    return {
      status: "confirmed",
      hash,
      feeCents,
      netCents: params.grossCents - feeCents,
    };
  } catch (e) {
    return { status: "skipped", reason: `base rpc unreachable: ${errMsg(e)}` };
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
    const fromBlock = latest > 9_000n ? latest - 9_000n : 0n;
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
