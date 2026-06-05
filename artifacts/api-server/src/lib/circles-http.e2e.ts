/**
 * End-to-end test: full circle lifecycles driven through the ACTUAL HTTP API.
 *
 * The sibling tests (`circles.e2e.ts`, `circles-accumulation.e2e.ts`) call the
 * `lib/circles` functions directly. They prove the engine is correct but they
 * skip everything the real app sits behind: the Express router, the `requireAuth`
 * guard (session token -> user), request-body validation, and — most importantly
 * — the OpenAPI response filtering (`GetCircleResponse.parse(...)`), which
 * silently strips any field not declared in `openapi.yaml`. A regression in that
 * wiring could break payouts for real users while the lib-level tests stay green.
 *
 * This test boots the real Express `app` on an ephemeral port and drives a full
 * lifecycle over `fetch` with authenticated requests, for BOTH circle types:
 *
 *   POST /api/circles            (create)
 *   POST /api/circles/:id/invite (invite each member)
 *   GET  /api/circles/invites    (invitee reads their pending invite)
 *   POST /api/circles/invites/:id/accept
 *   POST /api/circles/:id/start
 *   POST /api/circles/:id/contribute  (every member, every round)
 *   GET  /api/circles/:id        (read payout/status as the client sees it)
 *   GET  /api/wallet             (confirm the payout actually reached the wallet)
 *
 * It asserts that the PAYOUT AMOUNTS and CIRCLE STATUS reach the client through
 * the parsed response (guarding the known response-filtering footgun):
 *   - `payoutCents` / `potCents` survive the response schema and are correct,
 *   - `status` transitions forming -> active -> completed are visible to clients,
 *   - the recipient's `paidOut` flips true in the members array,
 *   - the recipient's wallet balance (read over HTTP) reflects the payout,
 *   - every member is net-zero through the wallet endpoint after completion.
 *
 * Scope: on-chain USDC settlement and email are intentionally OUT of scope and
 * disabled BEFORE any import (the ledger postings that drive payouts/balances
 * are identical either way), so this test is deterministic and fully offline.
 *
 * Run: pnpm --filter @workspace/api-server test:susu-http
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

const { db, pool, usersTable, circlesTable, ledgerAccountsTable, postingsTable, transactionsTable } =
  await import("@workspace/db");
const { eq, inArray } = await import("drizzle-orm");
const { createWalletForUser } = await import("./wallet");
const { acct } = await import("./ledger");
const { createSession } = await import("./auth");
const { onchainEnabled } = await import("./chain");
const { emailEnabled } = await import("./email");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
const CONTRIBUTION_CENTS = 1000; // $10.00 per round
const DEPOSIT_CENTS = 6000; // covers every round for either circle type

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

async function walletTotalCents(token: string): Promise<number> {
  const r = await api<{ totalCents: number }>("GET", "/api/wallet", { token });
  assert.equal(r.status, 200, "wallet endpoint should return 200");
  assert.equal(typeof r.body.totalCents, "number", "wallet totalCents must reach the client");
  return r.body.totalCents;
}

async function fund(user: TestUser, amountCents: number): Promise<void> {
  const r = await api<{ ok: boolean }>("POST", "/api/wallet/deposit", {
    token: user.token,
    body: { amountCents },
  });
  assert.equal(r.status, 200, `faucet deposit should succeed (got ${r.status})`);
  assert.equal(r.body.ok, true, "faucet deposit response should be { ok: true }");
}

// --- The full circle response shape the client receives ----------------------
type CircleMemberDto = { id: string; name: string; payoutRound: number; state: string; paidOut: boolean };
type CircleDetailDto = {
  id: string;
  name: string;
  status: string;
  type: string;
  contributionCents: number;
  payoutCents: number;
  potCents: number;
  currentRound: number;
  totalRounds: number;
  members: CircleMemberDto[];
};

async function getDetail(token: string, circleId: string): Promise<CircleDetailDto> {
  const r = await api<CircleDetailDto>("GET", `/api/circles/${circleId}`, { token });
  assert.equal(r.status, 200, `GET circle detail should return 200 (got ${r.status})`);
  // Guard against the response schema silently dropping the money/status fields.
  for (const field of ["payoutCents", "potCents", "contributionCents", "currentRound", "totalRounds"] as const) {
    assert.equal(typeof r.body[field], "number", `detail.${field} must reach the client as a number`);
  }
  assert.equal(typeof r.body.status, "string", "detail.status must reach the client");
  assert.ok(Array.isArray(r.body.members), "detail.members must reach the client");
  return r.body;
}

async function setupCircleMembers(prefix: string): Promise<{ creator: TestUser; members: TestUser[] }> {
  const creator = await makeUser(prefix, "creator");
  const m2 = await makeUser(prefix, "m2");
  const m3 = await makeUser(prefix, "m3");
  const members = [creator, m2, m3];
  for (const u of members) await fund(u, DEPOSIT_CENTS);
  for (const u of members) {
    assert.equal(await walletTotalCents(u.token), DEPOSIT_CENTS, "faucet should fund each member via HTTP");
  }
  return { creator, members };
}

async function inviteAndAccept(creator: TestUser, circleId: string, circleName: string, invitee: TestUser) {
  const inv = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/invite`, {
    token: creator.token,
    body: { email: invitee.email },
  });
  assert.equal(inv.status, 200, `invite should succeed (got ${inv.status})`);
  assert.equal(inv.body.ok, true, "invite response should be { ok: true }");

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
  assert.equal(acc.body.ok, true, "accept response should be { ok: true }");
}

function recipientForRound(detail: CircleDetailDto, round: number, members: TestUser[]): TestUser {
  const member = detail.members.find((m) => m.payoutRound === round);
  assert.ok(member, `round ${round} should have a recipient member in the HTTP detail`);
  const user = members.find((u) => u.name === member.name);
  assert.ok(user, `recipient member ${member.name} should map to a known test user`);
  return user;
}

// --- Flow 1: rotation circle, driven entirely over HTTP ----------------------
async function runRotation() {
  const { creator, members } = await setupCircleMembers("E2E HTTP ROT");
  const n = members.length;
  const pot = CONTRIBUTION_CENTS * n;

  const create = await api<CircleDetailDto>("POST", "/api/circles", {
    token: creator.token,
    body: {
      name: `E2E HTTP Rotation ${runId}`,
      contributionCents: CONTRIBUTION_CENTS,
      frequency: "monthly",
      memberEmails: [],
    },
  });
  assert.equal(create.status, 201, `create circle should return 201 (got ${create.status})`);
  const circleId = create.body.id;
  allCircleIds.push(circleId);
  const circleName = create.body.name;
  assert.equal(create.body.status, "forming", "new circle is forming");
  assert.equal(create.body.type, "rotation", "type should reach client as rotation");

  for (const u of [members[1], members[2]]) {
    await inviteAndAccept(creator, circleId, circleName, u);
  }

  const start = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/start`, { token: creator.token });
  assert.equal(start.status, 200, `start should succeed (got ${start.status})`);
  assert.equal(start.body.ok, true, "start response should be { ok: true }");

  const started = await getDetail(creator.token, circleId);
  assert.equal(started.status, "active", "circle is active after start (status reaches client)");
  assert.equal(started.currentRound, 1, "first round is 1");
  assert.equal(started.totalRounds, n, "rotation rounds equal member count");
  assert.equal(started.members.length, n, "all members present in HTTP detail");
  assert.equal(started.payoutCents, pot, "rotation payout (full pot) reaches the client correctly");
  assert.equal(started.potCents, pot, "pot amount reaches the client correctly");

  for (let round = 1; round <= n; round++) {
    const before = await getDetail(creator.token, circleId);
    assert.equal(before.currentRound, round, `should be on round ${round}`);
    const recipient = recipientForRound(before, round, members);
    const recipientBefore = await walletTotalCents(recipient.token);

    for (let i = 0; i < members.length; i++) {
      const u = members[i];
      const c = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/contribute`, { token: u.token });
      assert.equal(c.status, 200, `round ${round} contribution should succeed (got ${c.status})`);
      assert.equal(c.body.ok, true, "contribute response should be { ok: true }");

      // Double-contribution guard over HTTP (checked once): a repeat must 400.
      if (round === 1 && i === 0) {
        const dup = await api<{ error: string }>("POST", `/api/circles/${circleId}/contribute`, { token: u.token });
        assert.equal(dup.status, 400, "a second contribution in the same round must be rejected (400)");
      }
    }

    // The payout amount reached the recipient's wallet (read over HTTP).
    const recipientAfter = await walletTotalCents(recipient.token);
    assert.equal(
      recipientAfter - recipientBefore,
      pot - CONTRIBUTION_CENTS,
      `round ${round}: recipient nets the pot minus their own contribution (seen via /api/wallet)`,
    );

    const after = await getDetail(creator.token, circleId);
    const recipientMember = after.members.find((m) => m.name === recipient.name);
    assert.ok(recipientMember?.paidOut, `round ${round}: recipient.paidOut reaches the client as true`);

    if (round < n) {
      assert.equal(after.currentRound, round + 1, "round advances by exactly one");
      assert.equal(after.status, "active", "circle stays active mid-rotation");
    } else {
      assert.equal(after.status, "completed", "circle status reaches client as completed");
      assert.equal(after.currentRound, n, "completed circle rests on the final round");
    }
  }

  // Every member is net-zero, confirmed through the wallet endpoint.
  for (const u of members) {
    assert.equal(
      await walletTotalCents(u.token),
      DEPOSIT_CENTS,
      "rotation: every member is net-zero after a full rotation (via /api/wallet)",
    );
  }
}

// --- Flow 2: accumulation circle, driven entirely over HTTP ------------------
async function runAccumulation() {
  const NUM_ROUNDS = 4; // fixed at creation, deliberately != member count
  const SHARE_CENTS = CONTRIBUTION_CENTS * NUM_ROUNDS;
  const { creator, members } = await setupCircleMembers("E2E HTTP ACC");
  const n = members.length;

  const create = await api<CircleDetailDto>("POST", "/api/circles", {
    token: creator.token,
    body: {
      name: `E2E HTTP Accumulation ${runId}`,
      type: "accumulation",
      contributionCents: CONTRIBUTION_CENTS,
      numRounds: NUM_ROUNDS,
      frequency: "monthly",
      memberEmails: [],
    },
  });
  assert.equal(create.status, 201, `create accumulation circle should return 201 (got ${create.status})`);
  const circleId = create.body.id;
  allCircleIds.push(circleId);
  const circleName = create.body.name;
  assert.equal(create.body.type, "accumulation", "type reaches client as accumulation");
  assert.equal(create.body.totalRounds, NUM_ROUNDS, "accumulation rounds fixed at creation reach the client");
  assert.equal(create.body.payoutCents, SHARE_CENTS, "accumulation payout (contribution × rounds) reaches client");

  for (const u of [members[1], members[2]]) {
    await inviteAndAccept(creator, circleId, circleName, u);
  }

  const start = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/start`, { token: creator.token });
  assert.equal(start.status, 200, `start should succeed (got ${start.status})`);

  const started = await getDetail(creator.token, circleId);
  assert.equal(started.status, "active", "accumulation circle is active after start");
  assert.equal(started.currentRound, 1, "first round is 1");
  assert.equal(started.totalRounds, NUM_ROUNDS, "accumulation rounds do not track member count");
  assert.notEqual(started.totalRounds, n, "round count differs from member count by design");
  assert.equal(started.payoutCents, SHARE_CENTS, "accumulation payout reaches client after start");

  for (let round = 1; round <= NUM_ROUNDS; round++) {
    const before = await getDetail(creator.token, circleId);
    assert.equal(before.currentRound, round, `should be on round ${round}`);

    const balancesBefore = new Map<string, number>();
    for (const u of members) balancesBefore.set(u.id, await walletTotalCents(u.token));

    const isFinal = round === NUM_ROUNDS;

    for (const u of members) {
      const c = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/contribute`, { token: u.token });
      assert.equal(c.status, 200, `round ${round} contribution should succeed (got ${c.status})`);
    }

    const after = await getDetail(creator.token, circleId);

    if (!isFinal) {
      // No per-round recipient: each member only loses their contribution.
      for (const u of members) {
        assert.equal(
          (balancesBefore.get(u.id) ?? 0) - (await walletTotalCents(u.token)),
          CONTRIBUTION_CENTS,
          `round ${round}: member only loses their contribution, no early payout (via /api/wallet)`,
        );
      }
      assert.equal(after.currentRound, round + 1, "round advances by exactly one");
      assert.equal(after.status, "active", "circle stays active mid-accumulation");
    } else {
      // Final round: each member gets their full savings back.
      for (const u of members) {
        assert.equal(
          (await walletTotalCents(u.token)) - (balancesBefore.get(u.id) ?? 0),
          SHARE_CENTS - CONTRIBUTION_CENTS,
          "final round: member gets savings back minus this round's contribution (via /api/wallet)",
        );
      }
      assert.equal(after.status, "completed", "accumulation status reaches client as completed");
      assert.equal(after.currentRound, NUM_ROUNDS, "completed circle rests on the final round");
    }
  }

  // Every member is net-zero: they get back exactly what they saved.
  for (const u of members) {
    assert.equal(
      await walletTotalCents(u.token),
      DEPOSIT_CENTS,
      "accumulation: every member is net-zero after completion (via /api/wallet)",
    );
  }
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
      // Cascades wallets, sessions, notifications and per-user ledger accounts.
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
  await runRotation();
  await runAccumulation();
  console.log(`\n✓ Susu circle HTTP e2e passed (rotation + accumulation) (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Susu circle HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
