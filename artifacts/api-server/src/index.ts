// Must stay the first import: Sentry has to initialise before Express, pg and
// the rest of the app load (no-op without SENTRY_DSN).
import "./instrument";
import * as Sentry from "@sentry/node";
import { endPool } from "@workspace/db";
import app from "./app";
import { logger } from "./lib/logger";
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

const server = app.listen(port, (err) => {
  if (err) {
    logger.error({ err }, "Error listening on port");
    process.exit(1);
  }

  logger.info({ port }, "Server listening");
  void startSettlementLoop();
  void startStreakLoop();
  startReferralAccrualLoop();
});

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
