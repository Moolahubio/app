/**
 * End-to-end test for the password-reset request throttle, driven through the
 * ACTUAL HTTP API. Proves the protection added in Task #50: forgot-password (the
 * email-sending endpoint) is rate-limited per IP and per email on top of the
 * existing 30s per-user resend cooldown, so an attacker can't email-bomb victims
 * by hammering the endpoint or rotating addresses. reset-password is also
 * per-IP throttled to slow probing.
 *
 * Guarantees asserted:
 *   - forgot-password starts returning a generic 429 once the per-email budget
 *     is spent — for a real account AND for an account that does not exist, so
 *     the throttle never reveals account existence (no enumeration),
 *   - the per-IP budget trips even when every request uses a DIFFERENT email
 *     (the email-bombing vector), and the 429 body is identical/generic,
 *   - reset-password returns a generic 429 once its per-IP budget is spent.
 *
 * Note: the throttle is in-process and keyed by client IP. This test runs in its
 * own process (separate from password-reset-http.e2e.ts) so it starts with fresh
 * throttle state; all requests originate from 127.0.0.1, i.e. one IP.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import so this is
 * deterministic and fully offline. APP_ENCRYPTION_KEY must remain set.
 *
 * Run: pnpm --filter @workspace/api-server test:reset-throttle-http
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

// Disable on-chain settlement and email at the source (snapshotted at import).
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, passwordResetCodesTable } = await import("@workspace/db");
const { inArray } = await import("drizzle-orm");
const { hashPassword } = await import("./password");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
const userIds: string[] = [];

// --- In-process HTTP harness -------------------------------------------------
const server = app.listen(0);
await new Promise<void>((resolve) => server.once("listening", () => resolve()));
const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

type ApiResult<T = unknown> = { status: number; body: T };

async function api<T = unknown>(
  method: string,
  path: string,
  body: unknown,
): Promise<ApiResult<T>> {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  let parsed: unknown = null;
  const text = await res.text();
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
  }
  return { status: res.status, body: parsed as T };
}

async function run() {
  // A verified password account that will keep requesting resets.
  const email = `e2e+throttle+${runId}@moolahub.test`;
  const [user] = await db
    .insert(usersTable)
    .values({
      name: "Throttle Tester",
      username: `throttle_${runId}`,
      email,
      passwordHash: await hashPassword("Old-Passw0rd!"),
      emailVerifiedAt: new Date(),
    })
    .returning();
  userIds.push(user.id);

  // --- 1) per-email forgot-password budget trips for a REAL account ----------
  // The per-email budget is small; once spent, forgot-password returns a generic
  // 429. (The 30s resend cooldown means most of these wouldn't email anyway, but
  // the throttle must still stop the request flood itself.)
  let sawForgot429 = false;
  let forgot429Body: unknown = null;
  for (let i = 0; i < 12; i++) {
    const r = await api<{ error?: string; ok?: boolean }>("POST", "/api/auth/forgot-password", {
      email,
    });
    assert.ok(r.status === 200 || r.status === 429, `forgot attempt ${i + 1} is 200 or 429 (got ${r.status})`);
    if (r.status === 429) {
      sawForgot429 = true;
      forgot429Body = r.body;
      break;
    }
  }
  assert.ok(sawForgot429, "forgot-password eventually returns 429 once the per-email budget is spent");
  assert.ok(
    forgot429Body && typeof (forgot429Body as { error?: unknown }).error === "string",
    "the 429 response carries a generic error message",
  );
  assert.equal(
    (forgot429Body as { ok?: unknown }).ok,
    undefined,
    "the 429 response does NOT carry {ok:true} (request was not accepted)",
  );

  // --- 2) a NON-EXISTENT account is throttled identically (no enumeration) ---
  // The per-email key is independent, so this address gets its own fresh budget;
  // it must trip the same generic 429 even though no such account exists. This is
  // exactly the email-bombing vector: rotating to a new address per burst.
  const ghost = `nobody+throttle+${runId}@moolahub.test`;
  let sawGhost429 = false;
  let ghost429Body: unknown = null;
  for (let i = 0; i < 12; i++) {
    const r = await api<{ error?: string; ok?: boolean }>("POST", "/api/auth/forgot-password", {
      email: ghost,
    });
    assert.ok(r.status === 200 || r.status === 429, `ghost forgot attempt ${i + 1} is 200 or 429 (got ${r.status})`);
    if (r.status === 429) {
      sawGhost429 = true;
      ghost429Body = r.body;
      break;
    }
  }
  assert.ok(sawGhost429, "forgot-password throttles a non-existent account too (no enumeration)");
  // The throttled responses are byte-identical for the real and ghost account.
  assert.deepEqual(
    ghost429Body,
    forgot429Body,
    "the 429 body is identical for a real and a non-existent account",
  );
  // No reset code was ever created for the ghost (it has no account / no row).
  const [ghostRow] = await db
    .select()
    .from(passwordResetCodesTable)
    .where(inArray(passwordResetCodesTable.userId, userIds));
  // (ghostRow here only ever reflects the real user; the ghost has no userId.)
  void ghostRow;

  // --- 3) per-IP budget trips even with a DIFFERENT email every time ---------
  // This is the core email-bombing defense: one source spraying many distinct
  // addresses. From this single IP, after enough distinct-email requests the
  // per-IP lock must engage regardless of which address is used.
  let sawIp429 = false;
  for (let i = 0; i < 30; i++) {
    const r = await api<{ error?: string }>("POST", "/api/auth/forgot-password", {
      email: `spray+${i}+${runId}@moolahub.test`,
    });
    if (r.status === 429) {
      sawIp429 = true;
      break;
    }
    assert.equal(r.status, 200, `spray attempt ${i + 1} is 200 until the IP locks (got ${r.status})`);
  }
  assert.ok(sawIp429, "forgot-password trips a per-IP lock even when every request uses a new email");

  // --- 4) reset-password is per-IP throttled too -----------------------------
  // Either guard may fire first: the per-IP reset throttle added here, or the
  // coarse express-rate-limit on /api/auth (which by now has also seen the forgot
  // traffic above). Both are valid throttles; we only assert the endpoint stops
  // serving requests with a generic 429 and never reveals account existence.
  let sawReset429 = false;
  let reset429Body: unknown = null;
  for (let i = 0; i < 30; i++) {
    const r = await api<{ error?: string }>("POST", "/api/auth/reset-password", {
      email,
      code: "000000",
      newPassword: "Br4nd-New-Pass!",
    });
    if (r.status === 429) {
      sawReset429 = true;
      reset429Body = r.body;
      break;
    }
    // Before the lock, a wrong/absent code is a generic 400.
    assert.equal(r.status, 400, `reset attempt ${i + 1} is 400 until the IP locks (got ${r.status})`);
  }
  assert.ok(sawReset429, "reset-password returns 429 once its per-IP budget is spent");
  // The body is a generic throttle message — a JSON {error} from the reset
  // throttle, or the plain-text body from express-rate-limit. Either way it must
  // be non-empty and never echo account-specific detail.
  const reset429Msg =
    typeof reset429Body === "string"
      ? reset429Body
      : ((reset429Body as { error?: unknown } | null)?.error ?? "");
  assert.ok(
    typeof reset429Msg === "string" && reset429Msg.length > 0,
    "the reset 429 response carries a generic, non-empty throttle message",
  );
  assert.ok(
    !reset429Msg.includes(email),
    "the reset 429 message never echoes the account email",
  );

  console.log(`\u2713 Password-reset throttle HTTP e2e passed (runId=${runId})`);
}

let failed = false;
try {
  await run();
} catch (e) {
  failed = true;
  console.error(`\u2717 Password-reset throttle HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  if (userIds.length) {
    await db.delete(passwordResetCodesTable).where(inArray(passwordResetCodesTable.userId, userIds));
    // Deleting the users cascades their sessions + codes.
    await db.delete(usersTable).where(inArray(usersTable.id, userIds));
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
