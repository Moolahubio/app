/**
 * Unit tests for the goal JSON helpers (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/goalJson.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { goalToJson, dashboardGoalJson, type GoalRow } from "./goalJson";

const row: GoalRow = {
  id: "g1",
  name: "Emergency fund",
  emoji: "🛟",
  color: "jade",
  imageUrl: null,
  targetCents: 300_000,
  savedCents: 0,
  deadline: new Date("2027-04-21T03:29:24.928Z"),
  frequency: "monthly",
  autoSaveCents: 25_000,
  createdAt: new Date("2026-06-05T03:29:24.928Z"),
};

test("a failed balance read is flagged and savedCents passes through unchanged", () => {
  const json = goalToJson({ ...row, savedCents: 0, balanceUnavailable: true });
  assert.equal(json.balanceUnavailable, true);
  assert.equal(json.savedCents, 0);
  assert.equal(goalToJson({ ...row, savedCents: 125_000, balanceUnavailable: true }).savedCents, 125_000);
  assert.equal(dashboardGoalJson({ ...row, balanceUnavailable: true }).balanceUnavailable, true);
});

test("an omitted flag is false", () => {
  assert.equal(goalToJson(row).balanceUnavailable, false);
  assert.equal(dashboardGoalJson(row).balanceUnavailable, false);
});

test("the flag sits directly after savedCents", () => {
  const keys = Object.keys(goalToJson(row));
  assert.equal(keys[keys.indexOf("savedCents") + 1], "balanceUnavailable");
});

test("the dashboard goal has exactly its 11 keys, in order", () => {
  assert.deepEqual(Object.keys(dashboardGoalJson({ ...row, onchain: true, feeBps: 200, history: [] })), [
    "id",
    "name",
    "emoji",
    "color",
    "targetCents",
    "savedCents",
    "balanceUnavailable",
    "deadline",
    "frequency",
    "autoSaveCents",
    "createdAt",
  ]);
});

test("dates are ISO strings", () => {
  for (const json of [goalToJson(row), dashboardGoalJson(row)]) {
    assert.equal(json.deadline, "2027-04-21T03:29:24.928Z");
    assert.equal(json.createdAt, "2026-06-05T03:29:24.928Z");
  }
});
