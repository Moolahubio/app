/**
 * Abuse controls for POST /storage/uploads/request-url.
 *
 * The signed PUT URL that route returns cannot bind content-type/size (the
 * Replit object-storage sidecar only accepts bucket/object/method/expiry), so
 * a single authenticated account could otherwise mint an unbounded number of
 * signed URLs and push arbitrary-sized/typed blobs into the private bucket.
 * Two independent controls close that gap without touching the upload flow
 * itself:
 *
 *  - uploadUrlLimiter: a per-user (not just per-IP) rate limit on how many
 *    signed URLs can be minted in a window, bounding how much unvetted
 *    storage one account can attempt to write.
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
