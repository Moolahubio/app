/**
 * End-to-end test: circle INVITATION authorization over the ACTUAL HTTP API.
 *
 * The sibling `circles-http-authz.e2e.ts` covers unauthenticated requests and
 * non-member access to view/start/invite/contribute. It does NOT cover the
 * invitation flow's own access rule: an invite is addressed to a specific email,
 * and only that recipient may accept or decline it.
 *
 * `acceptInvite` throws "This invitation isn't for you." and `declineInvite`
 * throws "Invitation not found." when the caller's email doesn't match the
 * invite's `email`. A regression here would let an attacker with a perfectly
 * valid session JOIN a circle they were never invited to (accept), or silently
 * KILL someone else's pending invite (decline). This test drives those paths
 * over the real Express routes for BOTH circle types (rotation, accumulation).
 *
 * Expected contract (asserted below):
 *   - A logged-in user who is NOT the invitee gets 400 on
 *       POST /api/circles/invites/:id/accept  (wrong recipient)
 *       POST /api/circles/invites/:id/decline (wrong recipient)
 *     for an invite addressed to a different email.
 *   - The attacker's rejected attempts do not mutate state: both invites stay
 *     pending and visible to their real recipients, and the attacker never
 *     appears as a member of the circle.
 *   - Positive controls confirm the rejections are authorization-driven, not a
 *     broken route: the real invitee CAN accept (200, becomes a member) and the
 *     real recipient of a second invite CAN decline (200, does not join).
 *
 * Scope: on-chain USDC settlement and email are intentionally OUT of scope and
 * disabled BEFORE any import, so this test is deterministic and fully offline.
 *
 * Run: pnpm --filter @workspace/api-server test:susu-invite-authz
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
      name: `InviteAuthz ${type} ${label} ${runId}`,
      type: "accumulation",
      contributionCents: CONTRIBUTION_CENTS,
      numRounds: ACC_ROUNDS,
      frequency: "monthly",
      memberEmails: [],
    };
  }
  return {
    name: `InviteAuthz ${type} ${label} ${runId}`,
    type: "rotation",
    contributionCents: CONTRIBUTION_CENTS,
    frequency: "monthly",
    memberEmails: [],
  };
}

type InviteRow = { id: string; circleName: string };

/** Resolve the pending invite a recipient sees for a given circle name. */
async function pendingInviteId(recipient: TestUser, circleName: string): Promise<string | undefined> {
  const list = await api<InviteRow[]>("GET", "/api/circles/invites", { token: recipient.token });
  assert.equal(list.status, 200, "listing invites should return 200");
  return list.body.find((i) => i.circleName === circleName)?.id;
}

// --- Flow: only the addressed recipient can accept / decline an invite -------
async function runInviteHijack(type: "rotation" | "accumulation") {
  const creator = await makeUser(`InviteAuthz ${type}`, "creator");
  const invitee = await makeUser(`InviteAuthz ${type}`, "invitee"); // accept positive control
  const decliner = await makeUser(`InviteAuthz ${type}`, "decliner"); // decline positive control
  const attacker = await makeUser(`InviteAuthz ${type}`, "attacker"); // valid session, wrong email

  const { id: circleId, name: circleName } = await createCircleApi(creator, bodyFor(type, "hijack"));

  // The creator invites the two real recipients by their own emails.
  for (const u of [invitee, decliner]) {
    const inv = await api<{ ok: boolean }>("POST", `/api/circles/${circleId}/invite`, {
      token: creator.token,
      body: { email: u.email },
    });
    assert.equal(inv.status, 200, `${type}: inviting ${u.email} should succeed (got ${inv.status})`);
  }

  const acceptInviteId = await pendingInviteId(invitee, circleName);
  const declineInviteId = await pendingInviteId(decliner, circleName);
  assert.ok(acceptInviteId, `${type}: invitee should see a pending invite over HTTP`);
  assert.ok(declineInviteId, `${type}: decliner should see a pending invite over HTTP`);

  // The attacker has a valid session but is NOT the addressed recipient of
  // either invite. They must be rejected on both accept and decline — and they
  // never see these invites in their own list (a stronger statement than just
  // "can't act": the invite simply isn't theirs).
  const attackerInvites = await api<InviteRow[]>("GET", "/api/circles/invites", { token: attacker.token });
  assert.equal(attackerInvites.status, 200, `${type}: attacker can read their own (empty) invite list`);
  assert.ok(
    !attackerInvites.body.some((i) => i.id === acceptInviteId || i.id === declineInviteId),
    `${type}: attacker must NOT see invites addressed to someone else`,
  );

  for (const inviteId of [acceptInviteId, declineInviteId]) {
    const acc = await api("POST", `/api/circles/invites/${inviteId}/accept`, { token: attacker.token });
    assert.equal(
      acc.status,
      400,
      `${type}: wrong recipient accepting invite must be 400 (got ${acc.status})`,
    );

    const dec = await api("POST", `/api/circles/invites/${inviteId}/decline`, { token: attacker.token });
    assert.equal(
      dec.status,
      400,
      `${type}: wrong recipient declining invite must be 400 (got ${dec.status})`,
    );
  }

  // The attacker's rejected attempts must not have mutated state: both invites
  // are still pending and still visible to their real recipients.
  assert.equal(
    await pendingInviteId(invitee, circleName),
    acceptInviteId,
    `${type}: invitee's invite must still be pending after the attacker's failed attempts`,
  );
  assert.equal(
    await pendingInviteId(decliner, circleName),
    declineInviteId,
    `${type}: decliner's invite must still be pending after the attacker's failed attempts`,
  );

  // And the attacker did not sneak into the circle as a member.
  const attackerCircles = await api<Array<{ id: string }>>("GET", "/api/circles", { token: attacker.token });
  assert.equal(attackerCircles.status, 200, `${type}: attacker can read their own (empty) circle list`);
  assert.ok(
    !attackerCircles.body.some((c) => c.id === circleId),
    `${type}: attacker must NOT have joined the circle via a hijacked invite`,
  );

  // Positive controls — prove the rejections are authorization-driven, not a
  // broken route. The real invitee CAN accept; the real recipient CAN decline.
  const accept = await api<{ ok: boolean }>("POST", `/api/circles/invites/${acceptInviteId}/accept`, {
    token: invitee.token,
  });
  assert.equal(accept.status, 200, `${type}: the real invitee CAN accept their invite (got ${accept.status})`);
  assert.equal(accept.body.ok, true, "accept response should be { ok: true }");

  const decline = await api<{ ok: boolean }>("POST", `/api/circles/invites/${declineInviteId}/decline`, {
    token: decliner.token,
  });
  assert.equal(decline.status, 200, `${type}: the real recipient CAN decline their invite (got ${decline.status})`);
  assert.equal(decline.body.ok, true, "decline response should be { ok: true }");

  // After acting: the accepter is now a member; the decliner is not.
  const inviteeCircles = await api<Array<{ id: string }>>("GET", "/api/circles", { token: invitee.token });
  assert.ok(
    inviteeCircles.body.some((c) => c.id === circleId),
    `${type}: the invitee who accepted must now appear as a member`,
  );
  const declinerCircles = await api<Array<{ id: string }>>("GET", "/api/circles", { token: decliner.token });
  assert.ok(
    !declinerCircles.body.some((c) => c.id === circleId),
    `${type}: the recipient who declined must NOT be a member`,
  );
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
  await runInviteHijack("rotation");
  await runInviteHijack("accumulation");
  console.log(`\n✓ Susu circle invite authz e2e passed (wrong-recipient accept/decline, rotation + accumulation) (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Susu circle invite authz e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
