---
name: MoolaHub step-up reauthentication for factor enrollment
description: how new durable login methods (passkey, Privy link, first password) are gated against stolen-session enrollment
---

Any route that enrolls or overwrites a durable login method (register a passkey,
link/relink Privy, set a first password) must call `verifyStepUp(user, proof)`
before making the change. A session cookie alone is not proof of continued
account ownership — it must not be enough to mint a new persistent credential.

`verifyStepUp` requires proof of EVERY factor the account has configured, not
just the first one found: if a password is set it must be correct, AND if
TOTP 2FA is enabled its code must ALSO be correct — both independently, not
either/or. Only when an account has NEITHER a password nor 2FA does it fall
back to an emailed one-time reauth code (for passwordless legacy accounts).
The reauth-code fallback has its own request endpoint and its own DB table,
separate from password-reset/email-verification codes, so in-flight flows
never collide.

**Why:** a leaked/replayed session token previously let an attacker silently
add a passkey, relink Privy to their own identity, set the first password on
a passwordless account, or (worse) deactivate/delete the account or rotate
the password on an account that already has both a password and 2FA — because
the original implementation short-circuited on the password alone and never
reached the 2FA check. Enabling 2FA must actually raise the bar for every
step-up-gated route, not just login.

**How to apply:** when adding any new "add a way to log in" or other
high-risk account-action endpoint, gate it with `verifyStepUp(user,
parsed.data)` — pass the WHOLE parsed proof object through, don't hand-roll a
password-only check "because this account has one." On the frontend, collect
proof via the shared step-up dialog/hook (`useStepUpGate`), which asks for
password AND 2FA code together when both are configured, not just one.
Any OTHER form that submits directly to a step-up-gated route (e.g. an
inline "change password" card, not the shared dialog) must independently
collect and submit every configured factor too — check `useGetTwoFactorStatus`
and add the 2FA field, or tightening the backend silently 401s that form for
every 2FA-enabled user.

**Gotcha:** the request-code endpoint (issuing the emailed fallback code) has
no request body, so it must use an origin-only CSRF guard (`requireAllowedOrigin`
in `lib/origins.ts`), not the stricter `requireJsonAndAllowedOrigin` that 415s
any request without a JSON content-type — the generated client for a bodyless
mutation sends no body/content-type at all. Cover this with an HTTP-level e2e
call (not just a DB-seeded code) so a content-type mismatch fails loudly.
