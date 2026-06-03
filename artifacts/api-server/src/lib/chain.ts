import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  getAddress,
  parseAbi,
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
