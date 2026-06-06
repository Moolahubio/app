import { keccak256, stringToHex } from "viem";

/**
 * Deterministic bytes32 id from a DB uuid. MUST match the backend
 * (`circleChain.circleIdToBytes32`) and the on-chain CREATE2 salt / goalId.
 */
export function idToBytes32(uuid: string): `0x${string}` {
  return keccak256(stringToHex(uuid));
}

/** Integer cents (1/100 USDC) -> USDC base units (6 dp). */
export function centsToUnits(cents: number): bigint {
  return BigInt(Math.round(cents)) * 10_000n;
}
