/**
 * End-to-end test: the time zone round trip through the real HTTP API (C3), plus
 * an HTTP smoke for settling a closed streak period on read (C29).
 *
 *   PATCH /profile {"timezone"}  validates the IANA name (400 "That time zone
 *     isn't supported." for an unknown one, with nothing written), accepts a
 *     time-zone-only body and `{}` (200, not 500), and is a no-op for the same
 *     zone again;
 *   GET /profile and GET /streaks echo the stored zone, and the open streak
 *     period then ends at local midnight in it.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import, so this
 * is deterministic and fully offline.
 *
 * Run: pnpm --filter @workspace/api-server run test:profile-timezone-http
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, streaksTable } = await import("@workspace/db");
const { purgeTestData } = await import("@workspace/db/testing");
const { eq } = await import("drizzle-orm");
const { createWalletForUser } = await import("./wallet");
const { createSession } = await import("./auth");
const { recordSave } = await import("./streaks");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
type TestUser = { id: string; token: string };
const allUsers: TestUser[] = [];
let userSeq = 0;

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
  const [u] = await db
    .insert(usersTable)
    .values({
      name: `Zone ${label} ${runId}`,
      username: `z${++userSeq}${runId}`.toLowerCase(),
      email: `e2e+zone+${label}+${runId}@moolahub.test`,
    })
    .returning();
  await createWalletForUser(u.id);
  const tu = { id: u.id, token: await createSession(u.id) };
  allUsers.push(tu);
  return tu;
}

type Profile = { name: string; timezone?: string };
type Overview = { currentPeriodEnd: string | null; currentPeriodSatisfied: boolean; timezone?: string };

const patch = (u: TestUser, body: unknown) => api<Profile & { error?: string }>("PATCH", "/api/profile", { token: u.token, body });
const storedRow = async (u: TestUser) => (await db.select().from(usersTable).where(eq(usersTable.id, u.id)))[0];

/** The first Monday 00:00 in Los Angeles strictly after the local day of `at`. */
function nextLosAngelesMonday(at: Date): string {
  const parts = (d: Date) => {
    const map: Record<string, string> = {};
    const fmt = new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Los_Angeles",
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      weekday: "short",
    });
    for (const p of fmt.formatToParts(d)) map[p.type] = p.value;
    return map;
  };
  const local = parts(at);
  const weekday = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(local.weekday);
  const day = Number(local.day) + (7 - weekday);
  // Los Angeles is UTC-7 or UTC-8: pick the candidate that is local midnight.
  for (const offsetHours of [7, 8]) {
    const candidate = new Date(Date.UTC(Number(local.year), Number(local.month) - 1, day, offsetHours));
    const p = parts(candidate);
    if (p.hour === "00" && p.weekday === "Mon") return candidate.toISOString();
  }
  throw new Error("no Los Angeles midnight found");
}

async function run() {
  // §7.9, row by row.
  const a = await makeUser("a");
  let r = await patch(a, { timezone: "Africa/Accra" });
  assert.equal(r.status, 200, `a valid zone is stored (got ${r.status})`);
  assert.equal(r.body.timezone, "Africa/Accra", "PATCH echoes the zone");

  for (const bad of ["Mars/Base", "+05:00"]) {
    r = await patch(a, { timezone: bad });
    assert.equal(r.status, 400, `${bad} is refused`);
    assert.deepEqual(r.body, { error: "That time zone isn't supported." });
  }
  assert.equal((await storedRow(a)).timezone, "Africa/Accra", "a 400 leaves the stored zone unchanged");

  const nameBefore = (await storedRow(a)).name;
  r = await patch(a, { timezone: "Mars/Base", name: "New name" });
  assert.equal(r.status, 400, "an unknown zone fails the whole request");
  assert.deepEqual(r.body, { error: "That time zone isn't supported." });
  assert.equal((await storedRow(a)).name, nameBefore, "the name is unchanged");

  for (const bad of ["", 5, "x".repeat(65)]) {
    r = await patch(a, { timezone: bad });
    assert.equal(r.status, 400, `${JSON.stringify(bad)} fails the schema`);
    assert.deepEqual(r.body, { error: "Invalid request" });
  }
  assert.equal((await storedRow(a)).timezone, "Africa/Accra", "schema failures write nothing");

  const profile = await api<Profile>("GET", "/api/profile", { token: a.token });
  r = await patch(a, {});
  assert.equal(r.status, 200, `an empty body returns 200 (got ${r.status})`);
  assert.deepEqual(r.body, profile.body, "an empty body returns the unchanged profile");

  const updatedBefore = (await storedRow(a)).updatedAt;
  r = await patch(a, { timezone: "Africa/Accra" });
  assert.equal(r.status, 200, "the same zone again returns 200");
  assert.equal((await storedRow(a)).updatedAt.toISOString(), updatedBefore.toISOString(), "the same zone again writes nothing");

  // The value is stored: GET /profile and GET /streaks echo it.
  const got = await api<Profile>("GET", "/api/profile", { token: a.token });
  assert.equal(got.body.timezone, "Africa/Accra", "GET /profile echoes the zone");
  const streaks = await api<Overview>("GET", "/api/streaks", { token: a.token });
  assert.equal(streaks.status, 200);
  assert.equal(streaks.body.timezone, "Africa/Accra", "GET /streaks echoes the zone");

  // A refused name leaves the zone unchanged too.
  const b = await makeUser("b");
  r = await patch(b, { timezone: "Africa/Accra", name: "" });
  assert.equal(r.status, 400);
  assert.deepEqual(r.body, { error: "Name can't be empty." });
  assert.equal((await storedRow(b)).timezone, "UTC", "the zone is not written when another field is refused");
  r = await patch(b, {});
  assert.equal(r.body.timezone, "UTC", "a profile reports UTC until a client sets a zone");

  // With a saved streak, the open period then ends at the Los Angeles boundary
  // nearest its old end (lead ruling B-SAFE-1, revised): the Monday 00:00 there
  // 7 or 8 hours after the UTC week ends. It stays saved, so a save in the next
  // Los Angeles week counts.
  const c = await makeUser("c");
  await recordSave(c.id, `save-${randomUUID()}`);
  const [before] = await db.select().from(streaksTable).where(eq(streaksTable.userId, c.id));
  r = await patch(c, { timezone: "America/Los_Angeles" });
  assert.equal(r.status, 200);
  const ov = await api<Overview>("GET", "/api/streaks", { token: c.token });
  assert.equal(ov.body.timezone, "America/Los_Angeles");
  assert.equal(
    ov.body.currentPeriodEnd,
    nextLosAngelesMonday(before.currentPeriodEnd),
    "the period ends on the Los Angeles Monday 00:00 nearest its old end",
  );
  assert.equal(ov.body.currentPeriodSatisfied, true, "the save already made is kept");

  // C29 over HTTP: a period that ended last week is settled before the answer.
  const d = await makeUser("d");
  const now = Date.now();
  const thisMonday = new Date(now);
  thisMonday.setUTCHours(0, 0, 0, 0);
  thisMonday.setUTCDate(thisMonday.getUTCDate() - ((thisMonday.getUTCDay() + 6) % 7));
  const week = 7 * 86_400_000;
  await db.insert(streaksTable).values({
    userId: d.id,
    commitmentType: "account",
    commitmentId: d.id,
    frequency: "weekly",
    startedAt: new Date(thisMonday.getTime() - 2 * week),
    status: "active",
    currentCount: 1,
    bestCount: 1,
    currentPeriodStart: new Date(thisMonday.getTime() - 2 * week),
    currentPeriodEnd: new Date(thisMonday.getTime() - week),
    currentPeriodSatisfied: true,
  });
  const settled = await api<Overview>("GET", "/api/streaks", { token: d.token });
  assert.equal(settled.status, 200);
  assert.equal(settled.body.currentPeriodSatisfied, false, "the closed period no longer reads as saved");
  assert.ok(settled.body.currentPeriodEnd && Date.parse(settled.body.currentPeriodEnd) > now, "the period is current");
}

let failed = false;
try {
  await run();
  console.log(`\n✓ Profile time zone HTTP e2e passed (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Profile time zone HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  try {
    await purgeTestData({ userIds: allUsers.map((u) => u.id) });
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
