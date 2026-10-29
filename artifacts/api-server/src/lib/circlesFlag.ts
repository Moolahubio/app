import type { NextFunction, Request, Response } from "express";

/**
 * Circles stay behind CIRCLES_ENABLED until the contract audit is signed off
 * (CLAUDE.md; docs/privy-account-layer.md §4). Only the exact value "true"
 * turns them on. Read on every call, so no restart can leave a stale value.
 */
export function circlesEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.CIRCLES_ENABLED === "true";
}

// Confirming a contribution the member's own device already sent on chain. It
// stays open with circles off, so money that already moved still reaches the
// ledger; it starts nothing new.
const CONFIRM_SENT_CONTRIBUTION = /^\/[^/]+\/contribute\/submitted\/?$/;

/**
 * Mounted on /circles. With circles off, every circle route that starts
 * something answers 404: create, invite, start, delete, contribute (which also
 * books payouts), accept or decline an invite. Reads stay, so a member still
 * sees an existing circle, and so does the confirmation of a contribution
 * already sent on chain (docs/privy-account-layer.md §4 records both).
 */
export function requireCirclesEnabled(req: Request, res: Response, next: NextFunction): void {
  if (
    circlesEnabled() ||
    req.method === "GET" ||
    req.method === "HEAD" ||
    (req.method === "POST" && CONFIRM_SENT_CONTRIBUTION.test(req.path))
  ) {
    next();
    return;
  }
  res.status(404).json({ error: "Not found" });
}
