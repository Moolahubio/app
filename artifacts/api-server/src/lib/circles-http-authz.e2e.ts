/**
 * End-to-end test: circle authorization & access control over the ACTUAL HTTP API.
 *
 * The sibling `circles-http.e2e.ts` proves the happy path (create → invite →
 * start → contribute → payout) through the real Express routes. It does NOT
 * assert the negative/security paths the live app leans on:
 *
 *   1. Unauthenticated requests (no token / invalid token) must be rejected by
 *      the `requireAuth` guard with 401 on EVERY circle route.
 *   2. An authenticated user who is NOT a member of a circle must not be able to
 *      view it, start it, invite to it, or contribute to it — even though their
 *      session is perfectly valid.
 *
 * A regression in `requireAuth` or in the per-route membership/creator checks in
 * `lib/circles` could expose other users' circles or let an outsider move money,
 * all while the happy-path test stays green. This test boots the real Express
 * `app` on an ephemeral port and drives those negative paths over `fetch` for
 * BOTH circle types (rotation and accumulation), in both `forming` and `active`
 * states, where the distinction matters.
 *
 * Expected contract (asserted below):
 *   - No / invalid session token  → 401 on every circle route (requireAuth).
 *   - Non-member GET /circles/:id            → 404 (detail returns null).
 *   - Non-member POST /circles/:id/start     → 400 (creator-only).
 *   - Non-member POST /circles/:id/invite    → 400 (creator-only).
 *   - Non-member POST /circles/:id/contribute→ 400 (membership-gated).
 *   - A non-member never sees the circle in GET /circles (their own list).
 *   - Positive controls confirm the rejections are authorization-driven, not a
 *     broken route: the real member/creator CAN view and contribute (200).
 *
 * Scope: on-chain USDC settlement and email are intentionally OUT of scope and
 * disabled BEFORE any import, so this test is deterministic and fully offline.
 *
 * Run: pnpm --filter @workspace/api-server test:susu-http-authz
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

// Disable on-chain settlement and email at the source. `chain.ts` snapshots the
// USDC contract address at import time and `email.ts` snapshots the Resend key,
// so these must be cleared before the dynamic imports below.
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;
// Explicitly enable the test faucet so this e2e test can fund wallets via
// POST /api/wallet/deposit. The faucet now defaults to off on non-mainnet to
// prevent synthetic balance creation in production-like deployments.
process.env.ENABLE_TEST_FAUCET = "true";

const { db, pool, usersTable, circlesTable, ledgerAccountsTable, postingsTable, transactionsTable } =
  await import("@workspace/db");
const { inArray } = await import("drizzle-orm");
const { createWalletForUser } = await import("./wallet");
const { acct } = await import("./ledger");
const { createSession } = await import("./auth");
const { onchainEnabled } = await import("./chain");
const { emailEnabled } = await import("./email");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
const CONTRIBUTION_CENTS = 1000; // $10.00 per round
const DEPOSIT_CENTS = 6000; // funds every member generously
const ACC_ROUNDS = 4; // accumulation rounds, fixed at creation

type TestUser = { id: string; email: string; name: string; token: string };

const allUsers: TestUser[] = [];
const allCircleIds: string[] = [];

// --- In-process HTTP harness -------------------------------------------------
let baseUrl = "";
const server = app.listen(0);
await new Promise<void>((resolve) => server.once("listening", () => resolve()));
baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

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

async function makeUser(prefix: string, label: string): Promise<TestUser> {
  const email = `${prefix}+${label}+${runId}@moolahub.test`;
  const [u] = await db.insert(usersTable).values({ name: `${prefix} ${label} ${runId}`, email }).returning();
  await createWalletForUser(u.id);
  const token = await createSession(u.id);
  const tu = { id: u.id, email: u.email, name: u.name, token };
  allUsers.push(tu);
  return tu;
}

async function fund(user: TestUser, amountCents: number): Promise<void> {
  const r = await api<{ ok: boolean }>("POST", "/api/wallet/deposit", {
    token: user.token,
    body: { amountCents },
  });
  assert.equal(r.status, 200, `faucet deposit should succeed (got ${r.status})`);
  assert.equal(r.body.ok, true, "faucet deposit response should be { ok: true }");
}

async function inviteAndAccept(creator: TestUser, circleId: string, circleName: string, invitee: TestUser) {
  const inv = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/invite`, {
    token: creator.token,
    body: { email: invitee.email },
  });
  assert.equal(inv.status, 200, `invite should succeed (got ${inv.status})`);

  const list = await api<Array<{ id: string; circleName: string }>>("GET", "/api/circles/invites", {
    token: invitee.token,
  });
  assert.equal(list.status, 200, "listing invites should return 200");
  const invite = list.body.find((i) => i.circleName === circleName);
  assert.ok(invite, `invitee ${invitee.email} should see a pending invite over HTTP`);

  const acc = await api<{ ok: boolean }>("POST", `/api/circles/invites/${invite.id}/accept`, {
    token: invitee.token,
  });
  assert.equal(acc.status, 200, `accepting invite should succeed (got ${acc.status})`);
}

type CircleBody = {
  name: string;
  type?: "rotation" | "accumulation";
  contributionCents: number;
  numRounds?: number;
  frequency: string;
  memberEmails: string[];
};

async function createCircleApi(creator: TestUser, body: CircleBody): Promise<{ id: string; name: string }> {
  const create = await api<{ id: string; name: string }>("POST", "/api/circles", { token: creator.token, body });
  assert.equal(create.status, 201, `create circle should return 201 (got ${create.status})`);
  allCircleIds.push(create.body.id);
  return { id: create.body.id, name: create.body.name };
}

function bodyFor(type: "rotation" | "accumulation", label: string): CircleBody {
  if (type === "accumulation") {
    return {
      name: `Authz ${type} ${label} ${runId}`,
      type: "accumulation",
      contributionCents: CONTRIBUTION_CENTS,
      numRounds: ACC_ROUNDS,
      frequency: "monthly",
      memberEmails: [],
    };
  }
  return {
    name: `Authz ${type} ${label} ${runId}`,
    type: "rotation",
    contributionCents: CONTRIBUTION_CENTS,
    frequency: "monthly",
    memberEmails: [],
  };
}

/**
 * Build a circle of the given type with a creator + one accepted member.
 * If `start` is true, fund both members and start the circle (status: active).
 */
async function buildCircle(
  type: "rotation" | "accumulation",
  label: string,
  start: boolean,
): Promise<{ creator: TestUser; member: TestUser; circleId: string; circleName: string }> {
  const creator = await makeUser(`Authz ${type} ${label}`, "creator");
  const member = await makeUser(`Authz ${type} ${label}`, "member");
  const { id: circleId, name: circleName } = await createCircleApi(creator, bodyFor(type, label));
  await inviteAndAccept(creator, circleId, circleName, member);
  if (start) {
    await fund(creator, DEPOSIT_CENTS);
    await fund(member, DEPOSIT_CENTS);
    const s = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/start`, { token: creator.token });
    assert.equal(s.status, 200, `start should succeed (got ${s.status})`);
  }
  return { creator, member, circleId, circleName };
}

// --- Flow 1: unauthenticated & invalid-token requests are all 401 ------------
async function runUnauthenticated() {
  // A real, active circle whose id is valid — so a 401 can only come from the
  // auth guard, never from a missing/unknown circle.
  const { circleId } = await buildCircle("rotation", "unauth", true);
  const INVALID = "deadbeef".repeat(8); // well-formed but not a real session token

  const routes: Array<{ method: string; path: string; body?: unknown }> = [
    { method: "GET", path: "/api/circles" },
    { method: "GET", path: "/api/circles/invites" },
    { method: "POST", path: "/api/circles", body: bodyFor("rotation", "x") },
    { method: "GET", path: `/api/circles/${circleId}` },
    { method: "POST", path: `/api/circles/${circleId}/invite`, body: { email: `x+${runId}@moolahub.test` } },
    { method: "POST", path: `/api/circles/${circleId}/start` },
    { method: "POST", path: `/api/circles/${circleId}/contribute` },
    { method: "POST", path: `/api/circles/invites/${randomUUID()}/accept` },
    { method: "POST", path: `/api/circles/invites/${randomUUID()}/decline` },
  ];

  for (const r of routes) {
    const noToken = await api(r.method, r.path, { body: r.body });
    assert.equal(noToken.status, 401, `no token: ${r.method} ${r.path} must be 401 (got ${noToken.status})`);

    const badToken = await api(r.method, r.path, { token: INVALID, body: r.body });
    assert.equal(
      badToken.status,
      401,
      `invalid token: ${r.method} ${r.path} must be 401 (got ${badToken.status})`,
    );
  }
}

// --- Flow 2: a valid, authenticated NON-member is rejected everywhere --------
async function runNonMember(type: "rotation" | "accumulation") {
  // An outsider with a perfectly valid session, but no membership in either
  // circle. They are funded so a contribution rejection can't be blamed on a
  // low balance — it must be the membership guard doing its job.
  const outsider = await makeUser(`Authz ${type} outsider`, "outsider");
  await fund(outsider, DEPOSIT_CENTS);

  const forming = await buildCircle(type, "forming", false);
  const active = await buildCircle(type, "active", true);

  for (const circle of [forming, active]) {
    const stateLabel = circle === forming ? "forming" : "active";
    const cid = circle.circleId;

    // View someone else's circle → 404 (detail returns null for non-members).
    const detail = await api("GET", `/api/circles/${cid}`, { token: outsider.token });
    assert.equal(
      detail.status,
      404,
      `non-member GET ${type}/${stateLabel} detail must be 404 (got ${detail.status})`,
    );

    // Invite to someone else's circle → 400 (creator-only).
    const invite = await api("POST", `/api/circles/${cid}/invite`, {
      token: outsider.token,
      body: { email: `intruder+${runId}@moolahub.test` },
    });
    assert.equal(
      invite.status,
      400,
      `non-member POST ${type}/${stateLabel} invite must be 400 (got ${invite.status})`,
    );

    // Start someone else's circle → 400 (creator-only).
    const start = await api("POST", `/api/circles/${cid}/start`, { token: outsider.token });
    assert.equal(
      start.status,
      400,
      `non-member POST ${type}/${stateLabel} start must be 400 (got ${start.status})`,
    );

    // Contribute to someone else's circle → 400 (membership-gated, before any
    // money can move). Checked for both states; the membership guard runs ahead
    // of the active-status check, so even an active circle rejects the outsider.
    const contribute = await api("POST", `/api/circles/${cid}/contribute`, { token: outsider.token });
    assert.equal(
      contribute.status,
      400,
      `non-member POST ${type}/${stateLabel} contribute must be 400 (got ${contribute.status})`,
    );

    // The outsider never sees the circle in their own list.
    const myCircles = await api<Array<{ id: string }>>("GET", "/api/circles", { token: outsider.token });
    assert.equal(myCircles.status, 200, "non-member can read their own (empty) circle list");
    assert.ok(
      !myCircles.body.some((c) => c.id === cid),
      `non-member must NOT see ${type}/${stateLabel} circle in their own list`,
    );
  }

  // Positive controls — prove the rejections above are authorization-driven and
  // not a broken route: the real creator and member CAN access their circle.
  const memberDetail = await api("GET", `/api/circles/${active.circleId}`, { token: active.member.token });
  assert.equal(memberDetail.status, 200, `${type}: a real member CAN view the circle (200)`);

  const creatorContribute = await api<{ ok: boolean }>("POST", `/api/circles/${active.circleId}/contribute`, {
    token: active.creator.token,
  });
  assert.equal(creatorContribute.status, 200, `${type}: a real member CAN contribute (200)`);
  assert.equal(creatorContribute.body.ok, true, "contribute response should be { ok: true }");
}

async function cleanup() {
  try {
    const keys = [
      ...allUsers.map((u) => acct.wallet(u.id)),
      ...allCircleIds.map((id) => acct.pool(id)),
    ];
    if (keys.length) {
      const accts = await db
        .select({ id: ledgerAccountsTable.id })
        .from(ledgerAccountsTable)
        .where(inArray(ledgerAccountsTable.key, keys));
      const acctIds = accts.map((a) => a.id);
      if (acctIds.length) {
        const txnRows = await db
          .selectDistinct({ id: postingsTable.transactionId })
          .from(postingsTable)
          .where(inArray(postingsTable.accountId, acctIds));
        const txnIds = txnRows.map((r) => r.id);
        if (txnIds.length) {
          await db.delete(transactionsTable).where(inArray(transactionsTable.id, txnIds));
        }
      }
    }
    if (allCircleIds.length) {
      await db.delete(circlesTable).where(inArray(circlesTable.id, allCircleIds));
    }
    if (allUsers.length) {
      await db.delete(usersTable).where(inArray(usersTable.id, allUsers.map((u) => u.id)));
    }
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
}

let failed = false;
try {
  assert.equal(onchainEnabled(), false, "on-chain settlement must be disabled for this test");
  assert.equal(emailEnabled(), false, "email must be disabled for this test");
  await runUnauthenticated();
  await runNonMember("rotation");
  await runNonMember("accumulation");
  console.log(`\n✓ Susu circle HTTP authz e2e passed (unauth + non-member, rotation + accumulation) (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Susu circle HTTP authz e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
