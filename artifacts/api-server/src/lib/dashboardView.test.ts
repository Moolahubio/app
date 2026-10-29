/**
 * Unit tests for the dashboard's pure choices (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/dashboardView.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  homeCircles,
  pickUpcomingPayIn,
  type PayInCandidate,
  type RoundContribution,
} from "./dashboardView";

// --- homeCircles -------------------------------------------------------------

const g = (id: string, status: string) => ({ id, status });
const ids = (list: { id: string }[]) => list.map((c) => c.id);

test("homeCircles: active first, then forming, never completed", () => {
  assert.deepEqual(ids(homeCircles([g("C3", "completed"), g("F2", "forming"), g("A1", "active")])), ["A1", "F2"]);
});

test("homeCircles: four active and one forming gives the first three active", () => {
  const list = [g("A1", "active"), g("F1", "forming"), g("A2", "active"), g("A3", "active"), g("A4", "active")];
  assert.deepEqual(ids(homeCircles(list)), ["A1", "A2", "A3"]);
});

test("homeCircles: an unknown status is kept after the active groups", () => {
  assert.deepEqual(ids(homeCircles([g("P1", "pending"), g("A1", "active")])), ["A1", "P1"]);
});

test("homeCircles: an empty input gives an empty list", () => {
  assert.deepEqual(homeCircles([]), []);
});

// --- pickUpcomingPayIn -------------------------------------------------------

const ME = "me";

function circle(id: string, over: Partial<PayInCandidate> = {}): PayInCandidate {
  return {
    id,
    name: `Group ${id}`,
    status: "active",
    contributionCents: 1000,
    currentRound: 1,
    totalRounds: 3,
    memberCount: 3,
    nextPayoutDate: "2026-10-01T00:00:00.000Z",
    ...over,
  };
}

/** `n` other members' rows for a group's round. */
function others(circleId: string, round: number, n: number): RoundContribution[] {
  return Array.from({ length: n }, (_, i) => ({ circleId, round, userId: `other-${i}` }));
}

test("no active groups gives null", () => {
  assert.equal(pickUpcomingPayIn(ME, [], []), null);
  assert.equal(pickUpcomingPayIn(ME, [circle("A", { status: "completed" })], []), null);
});

test("all paid gives null", () => {
  const rows = [
    { circleId: "A", round: 1, userId: ME },
    { circleId: "B", round: 2, userId: ME },
  ];
  assert.equal(pickUpcomingPayIn(ME, [circle("A"), circle("B", { currentRound: 2 })], rows), null);
});

test("forming groups and round 0 are ignored", () => {
  const list = [circle("F", { status: "forming", currentRound: 0 }), circle("Z", { currentRound: 0 })];
  assert.equal(pickUpcomingPayIn(ME, list, []), null);
});

test("a pay-in that is still settling (its row exists) counts as paid", () => {
  assert.equal(pickUpcomingPayIn(ME, [circle("A")], [{ circleId: "A", round: 1, userId: ME }]), null);
  // A row from an earlier round does not pay the current one.
  const due = pickUpcomingPayIn(ME, [circle("A", { currentRound: 2 })], [{ circleId: "A", round: 1, userId: ME }]);
  assert.equal(due?.circleId, "A");
});

test("last to pay wins over an older open round", () => {
  const list = [
    circle("NEW", { nextPayoutDate: "2026-10-20T00:00:00.000Z" }),
    circle("OLD", { nextPayoutDate: "2026-09-01T00:00:00.000Z" }),
  ];
  assert.equal(pickUpcomingPayIn(ME, list, others("NEW", 1, 2))?.circleId, "NEW");
});

test("between groups that are not last to pay, the earlier round start wins", () => {
  const list = [
    circle("OLDER_ROUND", { nextPayoutDate: "2026-09-01T00:00:00.000Z" }),
    circle("NEWER_ROUND", { nextPayoutDate: "2026-10-01T00:00:00.000Z" }),
  ];
  assert.equal(pickUpcomingPayIn(ME, list, others("NEWER_ROUND", 1, 1))?.circleId, "OLDER_ROUND");
  // A missing or unparsable start sorts last.
  const unknown = [circle("KNOWN"), circle("NONE", { nextPayoutDate: null }), circle("BAD", { nextPayoutDate: "soon" })];
  assert.equal(pickUpcomingPayIn(ME, unknown, [])?.circleId, "KNOWN");
});

test("equal on the first two keys: the older group (later in the input) wins", () => {
  const list = [circle("NEWER"), circle("OLDER")];
  assert.equal(pickUpcomingPayIn(ME, list, [])?.circleId, "OLDER");
});

test("the pick carries the contribution and the current round, and no date", () => {
  const pick = pickUpcomingPayIn(ME, [circle("A", { contributionCents: 2040, currentRound: 2, totalRounds: 4 })], []);
  assert.deepEqual(pick, { circleId: "A", circleName: "Group A", amountCents: 2040, round: 2, totalRounds: 4 });
});

test("the live demo account (2026-10-25): Family susu, round 3 of 4", () => {
  // Ama's 18 active groups, newest first: [name, round, totalRounds, members, Ama paid, others paid, cents, round start].
  const table: [string, number, number, number, boolean, number, number, string][] = [
    ["QA Together 837206", 1, 2, 2, false, 0, 1000000, "2026-10-24T10:26:44.335Z"],
    ["QA Turns 837206", 1, 2, 2, true, 0, 2040, "2026-10-24T10:24:09.242Z"],
    ["QA Together 833098", 1, 2, 2, false, 0, 1000000, "2026-10-24T09:20:20.145Z"],
    ["QA Turns 833098", 1, 2, 2, true, 0, 2040, "2026-10-24T09:16:54.253Z"],
    ["QA Together 828171", 1, 2, 2, false, 0, 1000000, "2026-10-24T07:55:34.624Z"],
    ["QA Turns 828171", 1, 2, 2, true, 0, 2040, "2026-10-24T07:53:08.849Z"],
    ["QA Together 823706", 1, 2, 2, false, 0, 1000000, "2026-10-24T06:40:09.047Z"],
    ["QA Turns 823706", 1, 2, 2, true, 0, 2040, "2026-10-24T06:38:06.875Z"],
    ["QA Together 794872", 1, 2, 2, false, 0, 1000000, "2026-10-23T22:40:19.817Z"],
    ["QA Turns 794872", 1, 2, 2, true, 0, 2040, "2026-10-23T22:38:07.703Z"],
    ["QA Together 790703", 1, 2, 2, false, 0, 1000000, "2026-10-23T21:29:41.378Z"],
    ["QA Turns 790703", 1, 2, 2, true, 0, 2040, "2026-10-23T21:28:05.955Z"],
    ["QA Together 789123", 1, 2, 2, false, 0, 1000000, "2026-10-23T21:02:56.889Z"],
    ["QA Turns 789123", 1, 2, 2, true, 0, 2040, "2026-10-23T21:01:29.488Z"],
    ["QA Turns 787384", 1, 2, 2, false, 0, 2040, "2026-10-23T20:32:22.748Z"],
    ["QA Turns 785229", 1, 2, 2, false, 0, 2040, "2026-10-23T19:56:38.277Z"],
    ["Family susu", 3, 4, 4, false, 3, 10000, "2026-11-02T03:29:24.928Z"],
    ["Holiday pot", 4, 6, 3, true, 1, 5000, "2026-11-02T03:29:24.928Z"],
  ];
  const circles: PayInCandidate[] = table.map(([name, round, totalRounds, members, , , cents, start]) => ({
    id: name,
    name,
    status: "active",
    contributionCents: cents,
    currentRound: round,
    totalRounds,
    memberCount: members,
    nextPayoutDate: start,
  }));
  const mine: RoundContribution[] = table
    .filter(([, , , , paid]) => paid)
    .map(([name, round]) => ({ circleId: name, round, userId: ME }));
  const theirs: RoundContribution[] = table.flatMap(([name, round, , , , n]) => others(name, round, n));

  assert.deepEqual(pickUpcomingPayIn(ME, circles, [...mine, ...theirs]), {
    circleId: "Family susu",
    circleName: "Family susu",
    amountCents: 10000,
    round: 3,
    totalRounds: 4,
  });
  // The two weaker rules this one replaces: the round open longest alone (no last-to-pay
  // key, so nobody else's row counts) and "newest created".
  assert.equal(pickUpcomingPayIn(ME, circles, mine)?.circleName, "QA Turns 785229");
  const paid = new Set(mine.map((r) => r.circleId));
  assert.equal(circles.find((c) => !paid.has(c.id))?.name, "QA Together 837206");
});
