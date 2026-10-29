// Must stay the first import: Sentry has to initialise before Express, pg and
// the rest of the app load (no-op without SENTRY_DSN).
import "./instrument";
import * as Sentry from "@sentry/node";
import { endPool } from "@workspace/db";
import app from "./app";
import { logger } from "./lib/logger";
import { devEmailCodeLoggingEnabled } from "./lib/email";
import { startSettlementLoop } from "./lib/settlement";
import { startStreakLoop } from "./lib/streaks";
import { startReferralAccrualLoop } from "./lib/referrals";

const rawPort = process.env["PORT"];

if (!rawPort) {
  throw new Error(
    "PORT environment variable is required but was not provided.",
  );
}

const port = Number(rawPort);

if (Number.isNaN(port) || port <= 0) {
  throw new Error(`Invalid PORT value: "${rawPort}"`);
}

// Optional bind address (e.g. LISTEN_HOST=0.0.0.0 so a phone on the LAN can
// reach a local dev server). Unset keeps Node's default: every interface. Not
// named HOST, which shells commonly set to the machine name.
const host = process.env["LISTEN_HOST"] || undefined;

const onListening = (err?: Error) => {
  if (err) {
    logger.error({ err }, "Error listening on port");
    process.exit(1);
  }

  logger.info({ port, host: host ?? "default" }, "Server listening");
  // Surfaces the production warning for a stray DEV_LOG_EMAIL_CODES at boot,
  // and tells a local developer where their sign-up codes will appear.
  if (devEmailCodeLoggingEnabled()) {
    logger.warn("[DEV ONLY] DEV_LOG_EMAIL_CODES=true: emailed codes are written to this log (no email provider)");
  }
  void startSettlementLoop();
  void startStreakLoop();
  startReferralAccrualLoop();
};

const server = host ? app.listen(port, host, onListening) : app.listen(port, onListening);

const SHUTDOWN_GRACE_MS = 10_000;

// Deploys and scale-downs send SIGTERM. Stop taking requests, let in-flight
// ones finish, then close the database pool and flush Sentry. A hard exit after
// the grace period covers a request that never finishes.
function shutdown(signal: string): void {
  logger.info({ signal }, "shutting down");
  setTimeout(() => process.exit(1), SHUTDOWN_GRACE_MS).unref();
  server.close(() => {
    void endPool()
      .then(() => Sentry.close(2_000))
      .finally(() => process.exit(0));
  });
  server.closeIdleConnections();
}

process.once("SIGTERM", () => shutdown("SIGTERM"));
process.once("SIGINT", () => shutdown("SIGINT"));
