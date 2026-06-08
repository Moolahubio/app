/**
 * In-process throttle for password-reset *requests* — /auth/forgot-password and
 * /auth/reset-password. This blunts "email bombing": an attacker hammering
 * forgot-password with many different email addresses to flood reset emails (or
 * rotating just under the 30s per-user resend cooldown in issuePasswordResetCode).
 *
 * Each request is counted against independent per-IP and (optionally) per-email
 * budgets within a rolling window. Exceeding either budget locks that key for
 * LOCKOUT_MS and the caller returns a generic 429. Counters increment on EVERY
 * request regardless of whether the account exists, so the throttle never
 * reveals account existence (no enumeration).
 *
 * Scopes are independent so the two endpoints can't starve each other's budget:
 *   - "forgot" is the email-sending endpoint and gets the tightest caps: a
 *     per-IP cap (the main lever against bombing many victims from one source)
 *     plus a per-email cap (caps flooding a single inbox, on top of the cooldown).
 *   - "reset" sends no email; code brute-forcing is already handled by the
 *     5-attempt code burn, so it only needs a looser per-IP cap to slow probing
 *     — generous enough for a legitimate burn-and-retry flow.
 *
 * State is kept in memory (the API runs as a single process); it intentionally
 * resets on restart, which is acceptable here and avoids leaking attempt history.
 * Mirrors the design of loginThrottle.ts.
 */
const WINDOW_MS = 15 * 60 * 1000;
const LOCKOUT_MS = 15 * 60 * 1000;

export type ResetScope = "forgot" | "reset";

type Budget = { ip: number; email: number | null };

const BUDGETS: Record<ResetScope, Budget> = {
  forgot: { ip: 6, email: 4 },
  reset: { ip: 10, email: null },
};

type Entry = { count: number; firstAt: number; lockedUntil: number | null };

const buckets = new Map<string, Entry>();

function keyFor(scope: ResetScope, kind: "ip" | "email", value: string): string {
  return `${scope}|${kind}|${value.trim().toLowerCase()}`;
}

function prune(now: number): void {
  // Bound memory: drop entries whose window has elapsed and that aren't locked.
  for (const [k, e] of buckets) {
    const expired = now - e.firstAt > WINDOW_MS && (!e.lockedUntil || e.lockedUntil <= now);
    if (expired) buckets.delete(k);
  }
}

/** Seconds remaining on a locked key, or null if the key is not currently locked. */
function lockedRemaining(key: string, now: number): number | null {
  const e = buckets.get(key);
  if (!e || !e.lockedUntil) return null;
  if (e.lockedUntil <= now) return null;
  return Math.ceil((e.lockedUntil - now) / 1000);
}

/** Count one request against a key; lock it once the budget is spent. */
function bump(key: string, max: number, now: number): void {
  const e = buckets.get(key);
  if (!e || now - e.firstAt > WINDOW_MS) {
    buckets.set(key, { count: 1, firstAt: now, lockedUntil: null });
    return;
  }
  e.count += 1;
  if (e.count >= max) {
    e.lockedUntil = now + LOCKOUT_MS;
  }
}

/**
 * Returns the seconds remaining if the IP or email is currently locked for this
 * scope, otherwise null. Check this BEFORE doing any work in the handler.
 */
export function resetThrottleRemaining(scope: ResetScope, ip: string, email: string): number | null {
  const now = Date.now();
  const budget = BUDGETS[scope];
  const ipLock = lockedRemaining(keyFor(scope, "ip", ip), now);
  if (ipLock !== null) return ipLock;
  if (budget.email !== null) {
    const emailLock = lockedRemaining(keyFor(scope, "email", email), now);
    if (emailLock !== null) return emailLock;
  }
  return null;
}

/**
 * Record a password-reset request against its per-IP and per-email budgets.
 * Call once per accepted request (after the throttle check passes).
 */
export function recordResetRequest(scope: ResetScope, ip: string, email: string): void {
  const now = Date.now();
  prune(now);
  const budget = BUDGETS[scope];
  bump(keyFor(scope, "ip", ip), budget.ip, now);
  if (budget.email !== null) {
    bump(keyFor(scope, "email", email), budget.email, now);
  }
}
