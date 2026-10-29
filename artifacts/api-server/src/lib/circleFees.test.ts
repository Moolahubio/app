/**
 * Unit tests for the fee a group shows (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/circleFees.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { circleFeeBps } from "./circleFees";

const CONTRACT = "0x0000000000000000000000000000000000000001";
const fee = (
  c: { type: string; targetMembers: number | null; contractAddress: string | null },
  escrowOn: boolean,
) => circleFeeBps(c, { escrowOn, feeBps: 200 });

test("save-together groups never show a fee", () => {
  assert.equal(fee({ type: "accumulation", targetMembers: null, contractAddress: CONTRACT }, true), 0);
  // Impossible today (only take-turns groups get a target), kept as a guard.
  assert.equal(fee({ type: "accumulation", targetMembers: 3, contractAddress: null }, false), 0);
});

test("target-payout take-turns groups always show the fee", () => {
  assert.equal(fee({ type: "rotation", targetMembers: 4, contractAddress: null }, false), 200);
});

test("other take-turns groups show the fee only with escrow on and a contract", () => {
  assert.equal(fee({ type: "rotation", targetMembers: null, contractAddress: CONTRACT }, true), 200);
  assert.equal(fee({ type: "rotation", targetMembers: null, contractAddress: CONTRACT }, false), 0);
  assert.equal(fee({ type: "rotation", targetMembers: null, contractAddress: null }, true), 0);
});
