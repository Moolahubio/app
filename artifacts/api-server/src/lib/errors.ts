import type { Response } from "express";
import { logger } from "./logger";

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
 * - anything else → logged in full server-side, generic `fallback` to the client.
 *
 * This is the single choke point that prevents stack traces, SQL/Drizzle error
 * text, table/column names, and other internals from reaching users.
 */
export function sendError(res: Response, e: unknown, fallback: string, fallbackStatus = 400): void {
  if (res.headersSent) return;
  if (e instanceof AppError) {
    res.status(e.statusCode).json({ error: e.message });
    return;
  }
  logger.error({ err: e }, fallback);
  res.status(fallbackStatus).json({ error: fallback });
}
