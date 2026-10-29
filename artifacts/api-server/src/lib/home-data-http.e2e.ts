/**
 * End-to-end test: the Home data the iOS app reads, through the real HTTP API.
 *
 * Every route passes its JSON through a generated zod schema, which drops any key
 * `openapi.yaml` does not declare, so these fields are only real once a client
 * receives them over HTTP:
 *   C14  `balanceUnavailable` on every goal object (POST /goals, GET /goals,
 *        GET /goals/:id, dashboard `activeGoals[]`);
 *   C30  `feeBps` 0 for save-together groups on GET /circles and GET /circles/:id;
 *   C35  dashboard `activeCircles`: active first, then forming, never completed,
 *        each with `targetMembers`; `circlePotCents` still counts every group;
 *   B4   dashboard `upcomingPayIn`: the caller's next unpaid round, last to pay
 *        first, with no date; `upcomingReminder` unchanged.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import, the fee
 * variables are cleared so the default 200 bps applies, and the test faucet
 * funds wallets, so this is deterministic and fully offline.
 *
 * Run: pnpm --filter @workspace/api-server run test:home-data-http
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;
delete process.env.CIRCLE_FEE_BPS;
delete process.env.FEE_BPS;
process.env.ENABLE_TEST_FAUCET = "true";

const { db, pool, usersTable, circlesTable } = await import("@workspace/db");
const { purgeTestData } = await import("@workspace/db/testing");
const { eq } = await import("drizzle-orm");
const { createWalletForUser } = await import("./wallet");
const { createSession } = await import("./auth");
const { onchainEnabled } = await import("./chain");
const { emailEnabled } = await import("./email");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
type TestUser = { id: string; email: string; token: string };
let userSeq = 0;
const allUsers: TestUser[] = [];
const allCircleIds: string[] = [];

const server = app.listen(0);
await new Promise<void>((resolve) => server.once("listening", () => resolve()));
const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

type ApiResult<T = unknown> = { status: number; body: T };

async function api<T = unknown>(
  method: string,
  path: string,
  opts: { token?: string; body?: unknown } = {},
): Promise<ApiResult<T>> {
  const headers: Record<string, string> = {};
  if (opts.token) headers["x-session-token"] = opts.token;
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  let body: unknown = null;
  const text = await res.text();
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }
  return { status: res.status, body: body as T };
}

async function makeUser(label: string): Promise<TestUser> {
  const email = `e2e+home+${label}+${runId}@moolahub.test`;
  const [u] = await db
    .insert(usersTable)
    .values({ name: `Home ${label} ${runId}`, username: `h${++userSeq}${runId}`.toLowerCase(), email })
    .returning();
  await createWalletForUser(u.id);
  const token = await createSession(u.id);
  const tu = { id: u.id, email: u.email, token };
  allUsers.push(tu);
  return tu;
}

async function fund(user: TestUser, amountCents: number): Promise<void> {
  const r = await api<{ ok: boolean }>("POST", "/api/wallet/deposit", { token: user.token, body: { amountCents } });
  assert.equal(r.status, 200, `faucet deposit should succeed (got ${r.status})`);
}

async function createCircle(creator: TestUser, body: Record<string, unknown>): Promise<string> {
  const r = await api<{ id: string }>("POST", "/api/circles", {
    token: creator.token,
    body: { frequency: "monthly", memberEmails: [], ...body },
  });
  assert.equal(r.status, 201, `create circle should return 201 (got ${r.status})`);
  allCircleIds.push(r.body.id);
  return r.body.id;
}

async function inviteAndAccept(creator: TestUser, circleId: string, circleName: string, invitee: TestUser): Promise<void> {
  const inv = await api("POST", `/api/circles/${circleId}/invite`, { token: creator.token, body: { email: invitee.email } });
  assert.equal(inv.status, 200, `invite should succeed (got ${inv.status})`);
  const list = await api<Array<{ id: string; circleName: string }>>("GET", "/api/circles/invites", { token: invitee.token });
  assert.equal(list.status, 200, "listing invites should return 200");
  const invite = list.body.find((i) => i.circleName === circleName);
  assert.ok(invite, "the invitee should see the pending invite");
  const acc = await api("POST", `/api/circles/invites/${invite.id}/accept`, { token: invitee.token });
  assert.equal(acc.status, 200, `accepting the invite should succeed (got ${acc.status})`);
}

async function start(creator: TestUser, circleId: string): Promise<void> {
  const r = await api("POST", `/api/circles/${circleId}/start`, { token: creator.token });
  assert.equal(r.status, 200, `start should succeed (got ${r.status})`);
}

async function contribute(user: TestUser, circleId: string): Promise<void> {
  const r = await api("POST", `/api/circles/${circleId}/contribute`, { token: user.token });
  assert.equal(r.status, 200, `contribute should succeed (got ${r.status})`);
}

type DashboardDto = {
  activeGoals: Array<Record<string, unknown>>;
  activeCircles: Array<{ id: string; status: string; targetMembers?: number | null }>;
  circlePotCents: number;
  upcomingReminder?: { title: string; amountCents: number; dueDate: string };
  upcomingPayIn?: { circleId: string; circleName: string; amountCents: number; round: number; totalRounds: number } | null;
};

async function dashboard(user: TestUser): Promise<DashboardDto & Record<string, unknown>> {
  const r = await api<DashboardDto & Record<string, unknown>>("GET", "/api/dashboard/summary", { token: user.token });
  assert.equal(r.status, 200, `dashboard should return 200 (got ${r.status})`);
  return r.body;
}

type CircleDto = { id: string; name: string; status: string; feeBps: number; potCents: number; currentRound: number; contributionCents: number; nextPayoutDate: string | null };

async function circlesOf(user: TestUser): Promise<CircleDto[]> {
  const r = await api<CircleDto[]>("GET", "/api/circles", { token: user.token });
  assert.equal(r.status, 200, "GET /circles should return 200");
  return r.body;
}

async function circleDetail(user: TestUser, id: string): Promise<CircleDto> {
  const r = await api<CircleDto>("GET", `/api/circles/${id}`, { token: user.token });
  assert.equal(r.status, 200, "GET /circles/:id should return 200");
  return r.body;
}

// --- C14: balanceUnavailable on every goal object -------------------------------
async function runC14() {
  const u = await makeUser("c14");
  const created = await api<Record<string, unknown> & { id: string }>("POST", "/api/goals", {
    token: u.token,
    body: { name: "Laptop", targetCents: 100_000, deadline: "2027-06-30T00:00:00.000Z", frequency: "monthly" },
  });
  assert.equal(created.status, 201, `create goal should return 201 (got ${created.status})`);
  assert.equal(created.body.balanceUnavailable, false, "POST /goals: balanceUnavailable is false");

  const list = await api<Array<Record<string, unknown>>>("GET", "/api/goals", { token: u.token });
  assert.equal(list.status, 200);
  assert.ok(list.body.length > 0, "GET /goals lists the goal");
  for (const goal of list.body) {
    assert.equal(typeof goal.balanceUnavailable, "boolean", "GET /goals: every item carries balanceUnavailable");
    const keys = Object.keys(goal);
    assert.equal(keys[keys.indexOf("savedCents") + 1], "balanceUnavailable", "the flag sits after savedCents");
  }

  const one = await api<Record<string, unknown>>("GET", `/api/goals/${created.body.id}`, { token: u.token });
  assert.equal(one.status, 200);
  assert.equal(typeof one.body.balanceUnavailable, "boolean", "GET /goals/:id carries balanceUnavailable");

  const d = await dashboard(u);
  assert.ok(d.activeGoals.length > 0, "the dashboard lists the goal");
  for (const goal of d.activeGoals) {
    assert.equal(typeof goal.balanceUnavailable, "boolean", "dashboard activeGoals[] carries balanceUnavailable");
  }
  assert.ok("upcomingPayIn" in d, "upcomingPayIn is always present");
  assert.equal(d.upcomingPayIn, null, "no group, nothing owed");
}

// --- C30: feeBps 0 for save-together groups --------------------------------------
async function runC30() {
  const u = await makeUser("c30");
  const together = await createCircle(u, { name: `Home together ${runId}`, type: "accumulation", numRounds: 2, contributionCents: 1000 });
  const turns = await createCircle(u, { name: `Home turns ${runId}`, targetPayoutCents: 2000, groupSize: 2 });

  const list = await circlesOf(u);
  assert.equal(list.find((c) => c.id === together)?.feeBps, 0, "GET /circles: save together shows no fee");
  assert.equal(list.find((c) => c.id === turns)?.feeBps, 200, "GET /circles: target-payout take turns shows 200");
  assert.equal((await circleDetail(u, together)).feeBps, 0, "GET /circles/:id: save together shows no fee");
  assert.equal((await circleDetail(u, turns)).feeBps, 200, "GET /circles/:id: target-payout take turns shows 200");
}

// --- C35: Home groups, active first, with targetMembers ---------------------------
async function runC35() {
  const u = await makeUser("c35");
  const v = await makeUser("c35-member");
  const aName = `Home active ${runId}`;
  const a = await createCircle(u, { name: aName, type: "accumulation", numRounds: 2, contributionCents: 1000 });
  await inviteAndAccept(u, a, aName, v);
  await start(u, a);
  const f = await createCircle(u, { name: `Home forming ${runId}`, targetPayoutCents: 3000, groupSize: 3 });
  const c = await createCircle(u, { name: `Home completed ${runId}`, contributionCents: 1000 });
  await db.update(circlesTable).set({ status: "completed" }).where(eq(circlesTable.id, c));

  const d = await dashboard(u);
  assert.deepEqual(d.activeCircles.map((x) => x.id), [a, f], "active first, then forming, never completed");
  assert.equal(d.activeCircles[0].targetMembers, null, "the save-together group has no target");
  assert.equal(d.activeCircles[1].targetMembers, 3, "the forming take-turns group carries its target");
  for (const x of d.activeCircles) assert.ok("targetMembers" in x, "every item carries targetMembers");

  const all = await circlesOf(u);
  assert.equal(all.length, 3);
  assert.equal(d.circlePotCents, all.reduce((sum, x) => sum + x.potCents, 0), "circlePotCents still counts every group");
}

// --- B4: upcomingPayIn -------------------------------------------------------------
async function runB4() {
  const x = await makeUser("b4-x");
  const y = await makeUser("b4-y");
  const z = await makeUser("b4-z");
  for (const user of [x, y, z]) await fund(user, 6000);

  const g2Name = `Home G2 ${runId}`;
  const g2 = await createCircle(x, { name: g2Name, contributionCents: 1000 });
  for (const m of [y, z]) await inviteAndAccept(x, g2, g2Name, m);
  await start(x, g2);
  await contribute(y, g2);
  await contribute(z, g2);

  const g1Name = `Home G1 ${runId}`;
  const g1 = await createCircle(x, { name: g1Name, contributionCents: 1000 });
  for (const m of [y, z]) await inviteAndAccept(x, g1, g1Name, m);
  await start(x, g1);

  // Z paid G2, so G1 is the only round owed.
  const dz = await dashboard(z);
  assert.equal(dz.upcomingPayIn?.circleId, g1, "Z owes G1 only");
  assert.equal(dz.upcomingPayIn?.round, 1);

  // X is last to pay in G2, which wins over the newer G1.
  const dx = await dashboard(x);
  assert.ok(dx.upcomingPayIn, "X owes a pay-in");
  assert.deepEqual(Object.keys(dx.upcomingPayIn), ["circleId", "circleName", "amountCents", "round", "totalRounds"], "no date is sent");
  assert.equal(dx.upcomingPayIn.circleId, g2, "X is last to pay in G2");
  assert.equal(dx.upcomingPayIn.round, 1);
  const g2Detail = await circleDetail(x, g2);
  assert.equal(dx.upcomingPayIn.amountCents, g2Detail.contributionCents, "amountCents is the contribution");
  assert.equal(dx.upcomingPayIn.circleName, g2Name);
  assert.equal(dx.upcomingPayIn.totalRounds, 3);

  // upcomingReminder is unchanged: the newest-created active group, with its round start.
  const g1Summary = (await circlesOf(x)).find((c) => c.id === g1);
  assert.deepEqual(dx.upcomingReminder, {
    title: `${g1Name} contribution due`,
    amountCents: 1000,
    dueDate: g1Summary?.nextPayoutDate,
  });
  assert.ok(dx.upcomingReminder?.title.endsWith(" contribution due"));
  assert.deepEqual(
    Object.keys(dx),
    [
      "availableCents",
      "totalCents",
      "goalTotalCents",
      "pendingCents",
      "balanceUnavailable",
      "circlePotCents",
      "recentActivity",
      "activeGoals",
      "activeCircles",
      "lessonsCompleted",
      "totalLessons",
      "upcomingReminder",
      "upcomingPayIn",
    ],
    "the payload's other keys are unchanged",
  );

  // X pays G2: the round fills and pays out, and G2 moves to round 2. X now owes
  // G2 round 2 and G1 round 1, last to pay in neither; G1's round opened first.
  await contribute(x, g2);
  assert.equal((await circleDetail(x, g2)).currentRound, 2, "G2 moved to round 2");
  const dx2 = await dashboard(x);
  assert.equal(dx2.upcomingPayIn?.circleId, g1, "the round open longest wins");
  assert.equal(dx2.upcomingPayIn?.round, 1);

  // A user whose only group is forming owes nothing.
  const w = await makeUser("b4-w");
  await createCircle(w, { name: `Home W ${runId}`, contributionCents: 1000 });
  const dw = await dashboard(w);
  assert.ok("upcomingPayIn" in dw, "upcomingPayIn is always present");
  assert.equal(dw.upcomingPayIn, null, "a forming group is never owed");
}

let failed = false;
try {
  assert.equal(onchainEnabled(), false, "on-chain settlement must be disabled for this test");
  assert.equal(emailEnabled(), false, "email must be disabled for this test");
  await runC14();
  await runC30();
  await runC35();
  await runB4();
  console.log(`\n✓ Home data HTTP e2e passed (C14, C30, C35, B4) (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Home data HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  try {
    await purgeTestData({ userIds: allUsers.map((u) => u.id), circleIds: allCircleIds });
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
