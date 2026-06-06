import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  isAddress,
  parseAbi,
  keccak256,
  stringToHex,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia } from "viem/chains";
import { centsToUnits } from "./chain";
import { logger } from "./logger";

/**
 * On-chain integration for Susu *accumulation* circles.
 *
 * Each accumulation circle gets its own contract: when the organiser starts the
 * circle, the backend asks `MoolaHubAccumulationFactory` to deploy a deterministic
 * EIP-1167 clone (its own parameters: members, contribution, rounds, fee) and
 * stores the address on the circle row. Members then contribute / withdraw
 * directly against that clone (user-signed in the non-custodial model).
 *
 * The double-entry ledger remains the source of truth; this layer is best-effort
 * and never throws into the request path — if the RPC is down or the platform key
 * is not the factory owner, the circle still starts and the address is backfilled
 * on a later attempt.
 */

const IS_MAINNET = process.env.BASE_NETWORK === "mainnet";
const CHAIN = IS_MAINNET ? base : baseSepolia;
const RPC_URL =
  process.env.BASE_RPC_URL || (IS_MAINNET ? "https://mainnet.base.org" : "https://sepolia.base.org");
const FACTORY = (process.env.ACCUMULATION_FACTORY_ADDRESS || "") as string;
// Grace after each round's window before a member can be flagged delinquent.
const GRACE_PERIOD_SECS = Number(process.env.CIRCLE_GRACE_PERIOD_SECS) || 3 * 24 * 60 * 60;

function platformKey(): Hex | undefined {
  const raw = process.env.PLATFORM_PRIVATE_KEY;
  if (!raw) return undefined;
  return (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
}

const FACTORY_ABI = parseAbi([
  "function createAccumulationCircle(bytes32 circleId, uint256 contributionAmount, address[] members, uint64 roundDuration, uint64 gracePeriod, uint256 totalRounds, bool lockUntilMaturity) returns (address)",
  "function predictAddress(bytes32 circleId) view returns (address)",
  "function circleOf(bytes32 circleId) view returns (address)",
]);

const INTERVAL_SECONDS: Record<string, number> = {
  weekly: 7 * 86_400,
  biweekly: 14 * 86_400,
  monthly: 30 * 86_400,
};

function publicClient() {
  return createPublicClient({ chain: CHAIN, transport: http(RPC_URL) });
}

function walletClientFor(pk: Hex) {
  return createWalletClient({ account: privateKeyToAccount(pk), chain: CHAIN, transport: http(RPC_URL) });
}

/** Whether accumulation circles can be deployed on-chain (platform key + factory). */
export function accumulationOnchainEnabled(): boolean {
  return Boolean(platformKey() && FACTORY && isAddress(FACTORY));
}

export function accumulationFactoryAddress(): Address | null {
  return FACTORY && isAddress(FACTORY) ? getAddress(FACTORY) : null;
}

/** Deterministic bytes32 circle id from the DB uuid (the CREATE2 salt). */
export function circleIdToBytes32(uuid: string): Hex {
  return keccak256(stringToHex(uuid));
}

export type AccumulationDeployParams = {
  circleUuid: string;
  contributionCents: number;
  memberAddresses: string[];
  frequency: string;
  totalRounds: number;
  lockUntilMaturity?: boolean;
};

/**
 * Deploy a per-circle accumulation clone via the factory (platform/owner signed).
 * Returns the new contract address + tx hash, or null when on-chain is
 * unavailable, a member lacks a wallet, or the platform key is not the factory
 * owner. Best-effort: never throws.
 */
export async function deployAccumulationCircle(
  p: AccumulationDeployParams,
): Promise<{ address: string; txHash: string } | null> {
  const factory = accumulationFactoryAddress();
  const pk = platformKey();
  if (!factory || !pk) return null;

  const members = p.memberAddresses.filter((a) => isAddress(a)).map((a) => getAddress(a));
  // Every member must have a valid on-chain address, or the on-chain roster is incomplete.
  if (members.length < 2 || members.length !== p.memberAddresses.length) return null;

  const circleId = circleIdToBytes32(p.circleUuid);
  const roundDuration = BigInt(INTERVAL_SECONDS[p.frequency] ?? INTERVAL_SECONDS.monthly);

  try {
    const pub = publicClient();
    const predicted = (await pub.readContract({
      address: factory,
      abi: FACTORY_ABI,
      functionName: "predictAddress",
      args: [circleId],
    })) as Address;

    const hash = await walletClientFor(pk).writeContract({
      address: factory,
      abi: FACTORY_ABI,
      functionName: "createAccumulationCircle",
      args: [
        circleId,
        centsToUnits(p.contributionCents),
        members,
        roundDuration,
        BigInt(GRACE_PERIOD_SECS),
        BigInt(p.totalRounds),
        p.lockUntilMaturity ?? true,
      ],
    });
    await pub.waitForTransactionReceipt({ hash });
    return { address: predicted, txHash: hash };
  } catch (e) {
    logger.warn(
      { err: e instanceof Error ? e.message : String(e), circle: p.circleUuid },
      "accumulation clone deploy failed; will retry",
    );
    return null;
  }
}
