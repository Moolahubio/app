---
name: MoolaHub Account section
description: Durable decisions for the MoolaHub Account area — passkeys/WebAuthn, object-storage avatars, and the no-KYC stance.
---

# Auth model
- MoolaHub keeps THREE login paths simultaneously: email/password, Privy, and passkeys (real WebAuthn via `@simplewebauthn`). Do not remove any when touching auth.
- **Why:** product requirement; KYC was explicitly removed but these three must stay.

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

# No KYC
- KYC was fully removed from schema, backend, openapi, codegen, and frontend. Do not reintroduce a `kycStatus` field or verification UI.
