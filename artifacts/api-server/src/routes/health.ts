import { Router, type IRouter } from "express";
import { HealthCheckResponse } from "@workspace/api-zod";
import { pool } from "@workspace/db";
import { logger } from "../lib/logger";

const router: IRouter = Router();

const DB_TIMEOUT_MS = 2_000;

/** SELECT 1 through the app pool, failing fast if the pool or database hangs. */
async function databaseReachable(): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`database check timed out after ${DB_TIMEOUT_MS}ms`)), DB_TIMEOUT_MS);
  });
  try {
    await Promise.race([pool.query("select 1"), timeout]);
    return true;
  } catch (err) {
    logger.warn({ err }, "healthz: database check failed");
    return false;
  } finally {
    clearTimeout(timer);
  }
}

// Uptime monitors and the deploy health check hit this. It reports unhealthy
// (503) when the database can't answer, since no request path works without it.
router.get("/healthz", async (_req, res) => {
  const dbOk = await databaseReachable();
  res.setHeader("Cache-Control", "no-store");
  res.status(dbOk ? 200 : 503).json(HealthCheckResponse.parse({ status: dbOk ? "ok" : "unavailable" }));
});

export default router;
