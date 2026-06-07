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
