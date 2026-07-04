import { parseAbi } from "viem";

/**
 * Minimal ABIs for user-signed on-chain actions. The `contribute()` and
 * `claimRefund()` selectors are identical across the rotation escrow and the
 * accumulation circle, so one fragment serves both modes.
 */
export const ERC20_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
]);

/** Rotation escrow + accumulation circle (shared selectors). */
export const CIRCLE_ABI = parseAbi([
  "function contribute()",
  "function claimRefund()",
]);

/** Accumulation circle — member withdraws their own savings. */
export const ACCUMULATION_ABI = parseAbi([
  "function withdraw()",
]);

/** Goal vault (singleton) — per (owner, goalId) savings. */
export const GOAL_VAULT_ABI = parseAbi([
  "function deposit(bytes32 goalId, uint256 amount)",
  "function withdraw(bytes32 goalId, uint256 grossAmount)",
]);
