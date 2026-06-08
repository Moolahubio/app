/**
 * In-process login throttle / lockout to blunt online password guessing on
 * /auth/login. This is a per-identifier (email + client IP) counter on top of
 * the coarse per-IP express-rate-limit in app.ts.
 *
 * After MAX_FAILURES failed attempts within the window, the identifier is locked
 * for LOCKOUT_MS. A successful login clears the counter. State is kept in memory
 * (the API runs as a single process); it intentionally resets on restart, which
 * is acceptable for a basic lockout and avoids leaking attempt history.
 *
 * Responses must stay non-enumerating: callers surface a generic "too many
 * attempts" message without revealing whether the account exists.
 */
const MAX_FAILURES = 8;
const WINDOW_MS = 15 * 60 * 1000;
const LOCKOUT_MS = 15 * 60 * 1000;

type Entry = { failures: number; firstAt: number; lockedUntil: number | null };

const attempts = new Map<string, Entry>();

function keyFor(email: string, ip: string): string {
  return `${email.trim().toLowerCase()}|${ip}`;
}

function prune(now: number): void {
  // Bound memory: drop entries whose window has elapsed and that aren't locked.
  for (const [k, e] of attempts) {
    const expired = now - e.firstAt > WINDOW_MS && (!e.lockedUntil || e.lockedUntil <= now);
    if (expired) attempts.delete(k);
  }
}

/** Returns the seconds remaining if currently locked, otherwise null. */
export function loginLockoutRemaining(email: string, ip: string): number | null {
  const e = attempts.get(keyFor(email, ip));
  if (!e || !e.lockedUntil) return null;
  const now = Date.now();
  if (e.lockedUntil <= now) return null;
  return Math.ceil((e.lockedUntil - now) / 1000);
}

/** Record a failed login attempt; locks the identifier once the budget is spent. */
export function recordFailedLogin(email: string, ip: string): void {
  const now = Date.now();
  prune(now);
  const k = keyFor(email, ip);
  const e = attempts.get(k);
  if (!e || now - e.firstAt > WINDOW_MS) {
    attempts.set(k, { failures: 1, firstAt: now, lockedUntil: null });
    return;
  }
  e.failures += 1;
  if (e.failures >= MAX_FAILURES) {
    e.lockedUntil = now + LOCKOUT_MS;
  }
}

/** Clear the counter for an identifier after a successful login. */
export function clearLoginAttempts(email: string, ip: string): void {
  attempts.delete(keyFor(email, ip));
}
