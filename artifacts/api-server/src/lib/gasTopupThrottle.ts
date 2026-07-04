/**
 * Per-user daily cap on non-custodial gas top-ups.
 *
 * `POST /wallet/ensure-gas` hands out real (testnet) MON so a Privy embedded EOA
 * can pay for its own withdrawal. Left uncapped, a user could repeatedly drain
 * their embedded EOA and re-request top-ups to siphon platform gas. Capping to a
 * few requests per user per day bounds that extraction.
 *
 * In-memory (per process): adequate for the single settlement instance this app
 * runs as. If the API is ever scaled horizontally, move this to a shared store.
 */
const WINDOW_MS = 24 * 60 * 60 * 1000;
const MAX_PER_WINDOW = Number(process.env.GAS_TOPUP_DAILY_CAP) || 3;

const hits = new Map<string, number[]>();

/**
 * Record and authorize a gas top-up for `userId`. Returns false (and records
 * nothing new) once the user has hit the daily cap; otherwise records this
 * request and returns true.
 */
export function allowGasTopup(userId: string): boolean {
  const now = Date.now();
  const recent = (hits.get(userId) ?? []).filter((t) => now - t < WINDOW_MS);
  if (recent.length >= MAX_PER_WINDOW) {
    hits.set(userId, recent);
    return false;
  }
  recent.push(now);
  hits.set(userId, recent);
  return true;
}
