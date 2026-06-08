---
name: MoolaHub email + password auth
description: How primary email/password auth, Privy reconciliation, and username/legal-name privacy work in MoolaHub.
---

# MoolaHub email + password auth

Email + password is the PRIMARY auth method. Privy is optional, post-login wallet
linkage only.

## Core invariants
- **Email compromise alone must never grant access.** `/auth/privy` returns 403
  whenever the matched account has a `passwordHash` — both the DID-match path and
  the verified-email-match path. Only legacy passwordless accounts may be linked /
  logged in via Privy. Linking for password accounts goes through the auth'd
  `/auth/privy/link`.
- **Verification codes are not brute-forceable.** `email_verification_codes` has an
  `attempts` column; `consumeVerificationCode` increments it on each wrong guess and
  deletes (burns) the row once it hits the max, forcing a fresh code. A 6-digit code
  without this cap is online-guessable.
  **Why:** architect flagged the missing attempt limit as a blocking security gap.
- **Setting a first password also verifies email.** `/auth/password` lets a
  passwordless (legacy Privy) account set a password without the current one, and
  stamps `emailVerifiedAt` at the same time.

## Username vs legal name (privacy)
- `username` is PUBLIC, `name` (legal name) is PRIVATE. All public surfaces (circle
  members, inviter, createdBy, accepter) must expose `username`, never `name`.
- Username is canonicalized to lowercase and unique case-insensitively via
  `lower(username)` collision checks. This must be applied at **every** write site:
  `/auth/register` AND `PATCH /profile` (a CI check on one but not the other lets
  case-variant handles slip in).
  **How to apply:** `USERNAME_RE = /^[a-zA-Z0-9_]{3,30}$/`, `.trim().toLowerCase()`
  before validate/store, and `sql\`lower(${usersTable.username}) = ${username}\``.

## Completion gate for legacy accounts
- A legacy Privy-only account has `username == null` and/or `hasPassword == false`.
  `AppLayout` redirects such users to `/complete-profile` (a standalone route
  outside the layout to avoid a redirect loop) to collect the missing username
  and/or password. `/auth/me` exposes `username`, `hasPassword`, `emailVerified`
  for the gate to read.

## Test notes
- Offline auth e2e: `auth-http.e2e.ts` (in `test:auth`). Email no-ops without
  `RESEND_API_KEY`, so verification codes can't be read from email — seed the code
  row directly with `sha256(code)` (matches the lib's `hashCode`) to drive
  verify-email + brute-force assertions. Privy PRIMARY login is out of scope offline
  (needs a live token), same as `twofactor-http.e2e.ts`.
- Circle HTTP e2e maps recipients by `username` now (member.name field carries the
  username), so test users must be created WITH a username.
