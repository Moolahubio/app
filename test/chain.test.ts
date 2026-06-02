import { describe, expect, it } from "vitest";
import {
  generateAccount,
  isValidAddress,
  centsToUnits,
  unitsToCents,
  onchainEnabled,
} from "@/lib/server/chain";

describe("chain (Base / viem)", () => {
  it("generates distinct EVM accounts", () => {
    const a = generateAccount();
    const b = generateAccount();
    expect(a.address).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(a.privateKey).toMatch(/^0x[0-9a-fA-F]{64}$/);
    expect(a.address).not.toBe(b.address);
  });

  it("validates EVM addresses and rejects non-EVM ones", () => {
    const { address } = generateAccount();
    expect(isValidAddress(address)).toBe(true);
    expect(isValidAddress("0x0000000000000000000000000000000000000000")).toBe(true);
    expect(isValidAddress("not-an-address")).toBe(false);
    expect(isValidAddress("")).toBe(false);
    // a Stellar-style key is not a valid EVM address
    expect(isValidAddress("GBHK4QZ7M3UYV2XK6F9N4ELZ5RJ8WQ7D2C5T1AP3SVB9MOOLAHUBXYZ")).toBe(false);
  });

  it("converts cents <-> USDC base units at 6 decimals", () => {
    expect(centsToUnits(100)).toBe(1_000_000n); // 1.00 USDC = 1e6 units
    expect(centsToUnits(1)).toBe(10_000n); // 1 cent = 1e4 units
    expect(unitsToCents(1_000_000n)).toBe(100);
    expect(unitsToCents(centsToUnits(12_345))).toBe(12_345);
  });

  it("reports on-chain disabled when platform key / USDC contract are unset", () => {
    // The test env leaves PLATFORM_PRIVATE_KEY and USDC_CONTRACT_ADDRESS empty.
    expect(onchainEnabled()).toBe(false);
  });
});
