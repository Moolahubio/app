import type { Response } from "express";
import { logger } from "./logger";
import { isUniqueViolation } from "./dbErrors";
import { InsufficientFundsError } from "./ledger";
import { captureServerError } from "./observability";

/**
 * An error whose message is SAFE to show the end user — business/validation
 * errors like "Insufficient balance" or "Circle not found". Throw this in lib
 * code for anything the user should see. Everything else (DB errors, bugs,
 * config issues) is treated as internal and never surfaced verbatim.
 */
export class AppError extends Error {
  readonly statusCode: number;
  constructor(message: string, statusCode = 400) {
    super(message);
    this.name = "AppError";
    this.statusCode = statusCode;
  }
}

/**
 * Send a caught error to the client without leaking internals.
 * - `AppError` → its (safe) message + status.
 * - `InsufficientFundsError` (the ledger's in-transaction overdraft guard) →
 *   400 with its safe message: the user asked for more than they have.
 * - a unique violation (a concurrent duplicate lost the race to a DB-enforced
 *   guarantee) → 409 with the generic `fallback`.
 * - anything else is unexpected → logged in full server-side, captured to
 *   Sentry, and answered with `fallbackStatus` (5xx) and the generic `fallback`.
 *
 * This is the single choke point that prevents stack traces, SQL/Drizzle error
 * text, table/column names, and other internals from reaching users.
 */
export function sendError(res: Response, e: unknown, fallback: string, fallbackStatus = 500): void {
  if (res.headersSent) return;
  if (e instanceof AppError) {
    res.status(e.statusCode).json({ error: e.message });
    return;
  }
  if (e instanceof InsufficientFundsError) {
    res.status(400).json({ error: e.message });
    return;
  }
  if (isUniqueViolation(e)) {
    logger.warn({ err: e }, fallback);
    res.status(409).json({ error: fallback });
    return;
  }
  logger.error({ err: e }, fallback);
  if (fallbackStatus >= 500) captureServerError(e, { req: res.req });
  res.status(fallbackStatus).json({ error: fallback });
}
