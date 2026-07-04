---
name: MoolaHub image upload hardening
description: Why uploaded-image fields must verify stored object metadata, and which write paths share the gate.
---

# Image upload acceptance must verify stored object metadata

User-uploaded images go to object storage via a **signed PUT URL** that does NOT
bind content-type or size. So any request-time allowlist/size check on the upload
endpoint is only *advisory* — an authed client can PUT arbitrary/oversized bytes
straight to the signed URL.

**Rule:** the real enforcement point is when an object path is *accepted* as an
entity image. `ObjectStorageService.isUsableImageObject(objectPath, maxBytes)`
fetches the stored object's real GCS metadata and returns false unless the
contentType is in `ALLOWED_IMAGE_TYPES` and size is finite, >0, and ≤ cap
(fails closed on missing/NaN size).

**Why:** review rejected the feature twice — first because the allowlist was
advisory, then because a missed call path (goals) persisted images unverified.

**How to apply:** every write path that persists an image/avatar field MUST
`await isUsableImageObject(...)` before insert/update and reject on false. Current
gated paths: `createCircle` (lib/circles.ts), `PATCH /profile` (routes/profile.ts),
`createGoal` (lib/goals.ts). If you add any goal/circle/profile *edit* endpoint
that accepts an image path, add the same gate. Serve-side `downloadObject({sanitize:true})`
(nosniff + non-image → octet-stream attachment) remains the defense against
spoofed content-type bytes; the metadata gate and the sanitized serve are
complementary, keep both.

**Orphaned uploads (never attached to any entity) bypass the gate entirely** —
`isUsableImageObject` only runs at attach time, so an object minted a signed URL
but never claimed (no ACL owner via `claimObjectEntityForOwner`) sat in storage
forever with no size/type check and no deletion path. Fixed with
`ObjectStorageService.sweepOrphanedUploads()`: deletes unclaimed objects whose
real metadata violates the image/size policy immediately, and unclaimed objects
older than a grace window (~2h) regardless of validity. Triggered opportunistically
(self-throttled, fire-and-forget) from the request-url route rather than a cron
job. Paired with a per-user `express-rate-limit` (keyed by user id, not just IP)
on `POST /storage/uploads/request-url` to bound how many signed URLs one account
can mint per window — since the signed PUT URL can't bind content-type/size
itself, both the sweep and the per-user mint limit are necessary, not optional,
hardening for any endpoint that returns a signed upload URL.
