---
name: MoolaHub Account section
description: Durable decisions for the MoolaHub Account area — passkeys/WebAuthn, object-storage avatars, and the no-KYC stance.
---

# Auth model
- MoolaHub auth is **Privy-primary with passkeys** (real WebAuthn via `@simplewebauthn`) as a secondary path. Email/password login was **removed** (no `/auth/login`, `/auth/register`, no `passwordHash` column, no bcrypt). Coinbase/CDP onramp was also removed.
- **Why:** once Privy was integrated it became the primary auth; email/password and the CDP onramp (which required a Coinbase wallet) were dropped at the user's request. KYC was removed earlier and stays removed.
- **How to apply:** do not reintroduce email/password fields, bcrypt, or onramp UI when touching auth/wallet. Privy `/auth/privy` returns `PrivyAuthResponse`; passkey verify returns `LoginPasskeyVerifyResponse`.

# WebAuthn challenge single-use
- Challenge consumption must be a single atomic `DELETE ... RETURNING` (not SELECT-then-DELETE). Two concurrent verify requests must never both claim the same challenge.
- **Why:** SELECT+DELETE leaves a replay/concurrency race that defeats single-use semantics.
- **How to apply:** any new WebAuthn-style one-time-token flow in `webauthn_challenges` — delete-and-return in one statement, then check expiry/type on the returned row.
- rpID and expected origin are derived from the request `Origin` header at runtime (not hard-coded), so it works across dev domain + deployment without env changes.

# Object storage / avatars
- `GET /api/storage/objects/*` (PRIVATE_OBJECT_DIR) is guarded with `requireAuth` — the private namespace is NOT public-by-default. Avatars render fine because same-origin `<img>` requests carry the session cookie.
- **Why:** the scaffold ships this route unauthenticated (ACL checks commented out); leaving it open exposes every private object to anyone who knows a path.
- Any authenticated user can read any avatar (no per-owner ACL) — intentional, since avatars are shown to other members in circles.
- `/api/storage/public-objects/*` stays unconditionally public (that is its purpose).

# Authenticator (TOTP) 2FA
- Full TOTP 2FA via `otplib` (`lib/twofactor.ts`): secret stored **encrypted** (AES-GCM via APP_ENCRYPTION_KEY), backup codes stored as **SHA-256 hashes** (plaintext shown once), backup codes **single-use**.
- **Disable AND regenerate-backup-codes both require a current valid code** — not just an authenticated session.
- Login gating: when `twoFactorEnabled`, both `/auth/privy` and `/passkeys/login/verify` return `{twoFactorRequired, challengeId}` and create **no** session; `/auth/2fa/login` verifies the code then mints the session. No bypass path.
- **2FA login challenge single-use is enforced the same way as WebAuthn**: verify code with a non-consuming read (so a wrong code can be retried), then `consumeTwoFactorChallenge()` does an atomic `DELETE ... WHERE id=? AND expiresAt>now() RETURNING`; if it returns null another request already won → reject. Never SELECT-then-DELETE on success.
- **Why:** SELECT-then-DELETE lets two concurrent valid logins mint two sessions from one challenge.

# Account lifecycle (deactivate / delete)
- **Deactivate is reversible**: set `deactivatedAt` + drop sessions; any successful login (incl. `/auth/2fa/login`) clears `deactivatedAt`.
- **Delete is guarded**: blocked (409) unless ALL hold — zero balance (`userBalances().totalCents===0`), no `forming|active` circles, AND **no `goals.status='active'`**. The active-goals check is required, not just balance/circles. On pass: anonymize PII, null privyDid/2FA, set `deletedAt`, delete passkeys + sessions.
- **Why:** a freshly created active goal can hold zero funds yet still represents a live commitment; balance alone misses it.

# No KYC
- KYC was fully removed from schema, backend, openapi, codegen, and frontend. Do not reintroduce a `kycStatus` field or verification UI.
