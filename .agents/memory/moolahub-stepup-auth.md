---
name: MoolaHub step-up reauthentication for factor enrollment
description: how new durable login methods (passkey, Privy link, first password) are gated against stolen-session enrollment
---

Any route that enrolls or overwrites a durable login method (register a passkey,
link/relink Privy, set a first password) must call `verifyStepUp(user, proof)`
before making the change. A session cookie alone is not proof of continued
account ownership — it must not be enough to mint a new persistent credential.

`verifyStepUp` checks, in priority order: current password (if the account has
one) -> live TOTP/backup code (if 2FA enabled) -> emailed one-time reauth code
(fallback for accounts with neither, e.g. Privy-only legacy accounts). The
reauth-code fallback has its own request endpoint and its own DB table,
separate from password-reset/email-verification codes, so in-flight flows
never collide.

**Why:** a leaked/replayed session token previously let an attacker silently
add a passkey, relink Privy to their own identity, or set the first password
on a passwordless account — converting a transient compromise into permanent
takeover.

**How to apply:** when adding any new "add a way to log in" endpoint, gate it
with `verifyStepUp` before persisting the change. On the frontend, collect the
proof via the shared step-up dialog/hook rather than inventing a new prompt —
it already knows which of the three methods applies to the current user.

**Gotcha:** the request-code endpoint (issuing the emailed fallback code) has
no request body, so it must use an origin-only CSRF guard (`requireAllowedOrigin`
in `lib/origins.ts`), not the stricter `requireJsonAndAllowedOrigin` that 415s
any request without a JSON content-type — the generated client for a bodyless
mutation sends no body/content-type at all. Cover this with an HTTP-level e2e
call (not just a DB-seeded code) so a content-type mismatch fails loudly.
