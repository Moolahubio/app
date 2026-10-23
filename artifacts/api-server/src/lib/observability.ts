import * as Sentry from "@sentry/node";
import type { Request } from "express";

/**
 * Explicit Sentry capture (spec §8). Every helper is a no-op when SENTRY_DSN is
 * unset (no client). Tags and the user are set on a scope at capture time, so
 * they never depend on per-request isolation and can't leak between requests.
 */

const enabled = () => Sentry.getClient() !== undefined;

// Routes that move or account for money. Errors here alert on-call (spec §8:
// more than 3 `area:money` errors in 5 minutes pages).
const MONEY_ROUTES = /^\/api\/(wallet|goals|circles|onchain|referral)(\/|$)/;

export function areaOf(path: string): string {
  if (MONEY_ROUTES.test(path)) return "money";
  return path.split("/")[2] || "root";
}

/**
 * Low-cardinality route from the request path: "POST /api/goals/:id/release".
 * Built from the path rather than req.route, which Express has already reset
 * by the time the global error handler runs.
 */
function routeOf(method: string, path: string): string {
  const pattern = path
    .split("/")
    .map((seg) => (/^[0-9a-f-]{36}$/i.test(seg) ? ":id" : /^\d+$/.test(seg) ? ":n" : /^0x/i.test(seg) ? ":hex" : seg))
    .join("/");
  return `${method} ${pattern}`;
}

/** Capture an unexpected (5xx) failure. User = internal UUID only. */
export function captureServerError(err: unknown, ctx: { req?: Request; job?: string } = {}): void {
  if (!enabled()) return;
  Sentry.withScope((scope) => {
    if (ctx.req) {
      const path = (ctx.req.originalUrl ?? ctx.req.url ?? "").split("?")[0] ?? "";
      scope.setTag("area", areaOf(path));
      scope.setTag("route", routeOf(ctx.req.method, path));
      const userId = (ctx.req as Request & { user?: { id?: unknown } }).user?.id;
      if (typeof userId === "string") scope.setUser({ id: userId });
    }
    if (ctx.job) scope.setTag("job", ctx.job);
    Sentry.captureException(err);
  });
}

/**
 * One event per dead-lettered transfer, fingerprinted by kind, for the
 * `settlement.dead_letter` page. Call it once per reversal, after the reversal
 * commits (settlement.ts markFailed). Row ids only; never amounts or addresses.
 */
export function captureDeadLetter(row: { id: unknown; kind: string; attempts: number }, reason: string): void {
  if (!enabled()) return;
  Sentry.withScope((scope) => {
    scope.setLevel("error");
    scope.setTags({ job: "settlement", area: "money", transfer_kind: row.kind });
    scope.setFingerprint(["settlement-dead-letter", row.kind]);
    scope.setContext("transfer", { rowId: String(row.id), attempts: row.attempts, reason });
    Sentry.captureMessage(`settlement.dead_letter ${row.kind}`);
  });
}

const beats = new Map<string, { last: number; failed: boolean }>();

/**
 * Cron-monitor heartbeat for a background loop; call it after every tick with
 * whether the tick succeeded. Check-ins are throttled to roughly one per
 * monitor interval (Sentry allows 6 per minute per monitor), and a window
 * reports "error" if any tick in it failed. The monitor is created by its first
 * check-in, with the schedule given here.
 */
export function heartbeat(slug: string, everyMinutes: number, ok: boolean): void {
  if (!enabled()) return;
  const beat = beats.get(slug) ?? { last: 0, failed: false };
  beat.failed ||= !ok;
  // 0.8 of the interval absorbs timer drift without double check-ins.
  if (Date.now() - beat.last >= everyMinutes * 48_000) {
    Sentry.captureCheckIn(
      { monitorSlug: slug, status: beat.failed ? "error" : "ok" },
      {
        schedule: { type: "interval", value: everyMinutes, unit: "minute" },
        checkinMargin: Math.min(everyMinutes, 30),
        maxRuntime: 10,
        failureIssueThreshold: 2,
        recoveryThreshold: 1,
      },
    );
    beat.last = Date.now();
    beat.failed = false;
  }
  beats.set(slug, beat);
}
