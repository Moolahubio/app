/**
 * Abuse controls for the upload flow (POST /storage/uploads/request-url and
 * PUT /storage/uploads/:objectId).
 *
 * Uploads are proxied through this server rather than a direct-to-bucket
 * signed URL specifically so the byte cap can be enforced in real time (see
 * objectStorage.receiveUpload) — the Replit object-storage sidecar can only
 * sign a bucket/object/method/expiry tuple, it cannot bind content-type or
 * content-length itself. On top of that real enforcement, rate limits bound
 * how much a single account can even attempt:
 *
 *  - uploadUrlLimiter: how many upload ids can be minted in a window.
 *  - uploadBytesLimiter: how many actual upload attempts (successful or not,
 *    since a rejected/oversized attempt still costs bandwidth/CPU to stream
 *    and reject) a single account can make in a window.
 *  - maybeTriggerUploadSweep: opportunistically (and rate-limited itself, so
 *    it can't be used to hammer GCS) runs sweepOrphanedUploads in the
 *    background so objects that were minted but never validly claimed don't
 *    accumulate indefinitely.
 */
import rateLimit from "express-rate-limit";
import type { Request } from "express";
import type { AuthRequest } from "./auth";
import type { ObjectStorageService } from "./objectStorage";
import { logger } from "./logger";

/** Generous enough for legitimate rapid re-uploads (e.g. retrying after a
 * failed PUT) but well below what's needed to meaningfully fill a bucket. */
export const uploadUrlLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req: Request) => {
    const userId = (req as AuthRequest).user?.id;
    return userId ? `user:${userId}` : (req.ip ?? "unknown");
  },
  message: { error: "Too many upload requests. Please try again later." },
});

/**
 * Bounds how many times a single account can PUT bytes to the upload-receive
 * endpoint per window. Each attempt now streams through this server (rather
 * than straight to GCS), so this also protects our own bandwidth/CPU, not
 * just bucket storage. Kept equal to uploadUrlLimiter's budget since a
 * legitimate client makes exactly one PUT per minted id.
 */
export const uploadBytesLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req: Request) => {
    const userId = (req as AuthRequest).user?.id;
    return userId ? `user:${userId}` : (req.ip ?? "unknown");
  },
  message: { error: "Too many upload requests. Please try again later." },
});

const SWEEP_MIN_INTERVAL_MS = 10 * 60 * 1000; // at most once per 10 minutes
let lastSweepAt = 0;
let sweepInFlight = false;

/**
 * Fire-and-forget GC trigger, safe to call on every request-url call: it
 * no-ops unless enough time has passed since the last sweep and no sweep is
 * currently running, so it never adds latency or extra GCS load to the
 * request path.
 */
export function maybeTriggerUploadSweep(service: ObjectStorageService): void {
  const now = Date.now();
  if (sweepInFlight || now - lastSweepAt < SWEEP_MIN_INTERVAL_MS) return;

  sweepInFlight = true;
  lastSweepAt = now;
  service
    .sweepOrphanedUploads()
    .then(({ scanned, deleted }) => {
      if (deleted > 0) {
        logger.info({ scanned, deleted }, "Swept orphaned/invalid object storage uploads");
      }
    })
    .catch((err) => {
      logger.error({ err }, "Error sweeping orphaned object storage uploads");
    })
    .finally(() => {
      sweepInFlight = false;
    });
}
