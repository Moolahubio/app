---
name: MoolaHub object storage upload proxy
description: Why uploads go through the API server instead of a direct-to-bucket signed PUT URL, and where the real size/type enforcement lives.
---

Replit sidecar-signed PUT URLs (the "get a signed URL, client PUTs directly to
GCS" pattern) cannot bind content-type or content-length into the signature.
A signed URL only authorizes *that a PUT to that object may happen* — the
client can still stream arbitrarily large bytes of any type straight into the
bucket, producing unbounded orphan blobs with only client-declared JSON
metadata as a paper-thin gate.

**Fix (architecture change, not a patch):** uploads are proxied through the
API server itself. `POST /storage/uploads/request-url` only allocates a
stateless objectId (bucket/object path is deterministically derived from it,
no DB row needed) and returns a same-origin relative path
(`/api/storage/uploads/:objectId`) as `uploadURL` — not a bucket URL.
`PUT /storage/uploads/:objectId` streams the body through a byte-counting
Transform + `pipeline` into GCS, aborting and deleting the partial object the
moment real bytes exceed the cap. Declared Content-Length/size are only a fast
pre-flight rejection; the authoritative check is the live byte count during
streaming.

**Why:** it's the only way to enforce a hard byte cap against actual bytes
sent, since the storage provider's URL signing has no hook for that. Declared
metadata (size/contentType in the JSON mint request) is trust-only and must
never be treated as enforcement.

**How to apply:** any new binary/file upload surface in this project should
reuse this proxy-through-server pattern (allocate id → stream-limited PUT
back through the API), not a fresh direct-to-bucket signed URL. Also apply the
existing per-user rate limits (mint-time AND byte-PUT-time) since minting is
now cheap/stateless and could otherwise be abused to spray objectIds.

**IDOR gotcha (caught in review, since fixed):** a stateless objectId->bucket
mapping alone is not enough — `resolveUploadTarget` derives the same path for
anyone who knows the id, so without an ownership check any authenticated user
could overwrite any other user's existing upload object just by guessing/
observing its id. Fixed with a short-lived HMAC capability token
(objectId+userId+expiry, `signUploadToken`/`verifyUploadToken` in
objectStorage.ts, signed via `hmacSign` in crypto.ts over APP_ENCRYPTION_KEY)
minted at request-url time and required as a query param on the PUT. Any
future stateless-id-based write endpoint needs the same binding, not just a
"the id is a random UUID so it's unguessable" assumption.
