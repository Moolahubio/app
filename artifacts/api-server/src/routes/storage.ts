import { Router, type IRouter, type Request, type Response } from "express";
import { Readable } from "stream";
import {
  RequestUploadUrlBody,
  RequestUploadUrlResponse,
} from "@workspace/api-zod";
import {
  ObjectStorageService,
  ObjectNotFoundError,
  UploadTooLargeError,
  ALLOWED_IMAGE_TYPES,
  MAX_UPLOAD_BYTES,
} from "../lib/objectStorage";
import { ObjectPermission } from "../lib/objectAcl";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireJsonAndAllowedOrigin, requireAllowedOrigin } from "../lib/origins";
import {
  uploadUrlLimiter,
  uploadBytesLimiter,
  maybeTriggerUploadSweep,
} from "../lib/uploadThrottle";

const router: IRouter = Router();
const objectStorageService = new ObjectStorageService();

/** Matches the v4 UUIDs minted by ObjectStorageService.allocateUploadObject. */
const UPLOAD_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * POST /storage/uploads/request-url
 *
 * Allocate an upload id for a new object in the private namespace.
 * The client sends JSON metadata (name, size, contentType) — NOT the file —
 * then PUTs the file bytes to the returned `uploadURL`, which points back at
 * this same server (see `PUT /storage/uploads/:objectId` below), not
 * directly at the storage bucket.
 *
 * This endpoint's declared-metadata checks (contentType/size) are only a
 * fast client-facing rejection; they are NOT the enforcement boundary, since
 * a client can freely lie about them. The real size/type cap is enforced
 * server-side while the bytes are streamed to storage (see
 * objectStorage.receiveUpload). uploadUrlLimiter also bounds how many upload
 * ids a single account can mint per window.
 */
router.post(
  "/storage/uploads/request-url",
  requireJsonAndAllowedOrigin,
  requireAuth,
  uploadUrlLimiter,
  async (req: Request, res: Response) => {
    const parsed = RequestUploadUrlBody.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "Missing or invalid required fields" });
      return;
    }

    const { name, size, contentType } = parsed.data;

    if (!contentType || !ALLOWED_IMAGE_TYPES.has(contentType.toLowerCase())) {
      res.status(400).json({ error: "Only PNG, JPEG, WebP, or GIF images can be uploaded." });
      return;
    }
    if (typeof size === "number" && size > MAX_UPLOAD_BYTES) {
      res.status(400).json({ error: "Image is too large (max 10MB)." });
      return;
    }

    try {
      const requester = (req as AuthRequest).user;
      const { objectId, objectPath, uploadToken } =
        objectStorageService.allocateUploadObject(requester.id);

      // Opportunistically GC abandoned/invalid uploads on this hot path
      // (fire-and-forget) so unclaimed storage doesn't grow unbounded even
      // without a separate scheduler process.
      maybeTriggerUploadSweep(objectStorageService);

      res.json(
        RequestUploadUrlResponse.parse({
          uploadURL: `/api/storage/uploads/${objectId}?token=${encodeURIComponent(uploadToken)}`,
          objectPath,
          metadata: { name, size, contentType },
        }),
      );
    } catch (error) {
      req.log.error({ err: error }, "Error generating upload URL");
      res.status(500).json({ error: "Failed to generate upload URL" });
    }
  },
);

/**
 * PUT /storage/uploads/:objectId
 *
 * Receive the actual file bytes for an id allocated by request-url above.
 * Uploads are proxied through this server (rather than a direct-to-bucket
 * signed URL) specifically so the byte cap can be enforced in real time as
 * the body streams in — see objectStorage.receiveUpload for why a signed URL
 * can't bind content-length itself. uploadBytesLimiter additionally bounds
 * how many upload attempts (successful or not) a single account can make per
 * window, on top of the per-mint uploadUrlLimiter above.
 */
router.put(
  "/storage/uploads/:objectId",
  requireAllowedOrigin,
  requireAuth,
  uploadBytesLimiter,
  async (req: Request, res: Response) => {
    const rawObjectId = req.params.objectId;
    const objectId = Array.isArray(rawObjectId) ? rawObjectId[0] : rawObjectId;
    if (!objectId || !UPLOAD_ID_RE.test(objectId)) {
      res.status(400).json({ error: "Invalid upload id" });
      return;
    }

    // resolveUploadTarget derives the same bucket path for anyone who knows
    // the objectId, so without this check any authenticated user could PUT
    // bytes over an unrelated existing upload object just by guessing or
    // observing its id (e.g. from a public image URL). The token proves the
    // caller is the same user who minted THIS objectId via request-url above,
    // and hasn't expired.
    const rawToken = req.query.token;
    const token = Array.isArray(rawToken) ? rawToken[0] : rawToken;
    const requester = (req as AuthRequest).user;
    if (
      typeof token !== "string" ||
      !objectStorageService.verifyUploadToken(objectId, requester.id, token)
    ) {
      res.status(403).json({ error: "Invalid or expired upload token" });
      return;
    }

    const rawContentType = req.headers["content-type"];
    const contentType = Array.isArray(rawContentType) ? rawContentType[0] : rawContentType;
    if (!contentType || !ALLOWED_IMAGE_TYPES.has(contentType.toLowerCase())) {
      res.status(400).json({ error: "Only PNG, JPEG, WebP, or GIF images can be uploaded." });
      return;
    }

    // Content-Length is client-declared and not trustworthy on its own (it
    // can be omitted or lied about), but reject the obviously-oversized case
    // up front without even starting the GCS write. The authoritative check
    // is the live byte count enforced inside receiveUpload.
    const rawContentLength = req.headers["content-length"];
    const declaredLength = Number(Array.isArray(rawContentLength) ? rawContentLength[0] : rawContentLength);
    if (Number.isFinite(declaredLength) && declaredLength > MAX_UPLOAD_BYTES) {
      res.status(413).json({ error: "Image is too large (max 10MB)." });
      return;
    }

    try {
      const { bucketName, objectName, objectPath } =
        objectStorageService.resolveUploadTarget(objectId);
      await objectStorageService.receiveUpload({
        bucketName,
        objectName,
        contentType: contentType.toLowerCase(),
        body: req,
        maxBytes: MAX_UPLOAD_BYTES,
      });
      res.json({ objectPath });
    } catch (error) {
      if (error instanceof UploadTooLargeError) {
        res.status(413).json({ error: "Image is too large (max 10MB)." });
        return;
      }
      req.log.error({ err: error }, "Error receiving upload");
      res.status(500).json({ error: "Failed to upload file" });
    }
  },
);

/**
 * GET /storage/public-objects/*
 *
 * Serve public assets from PUBLIC_OBJECT_SEARCH_PATHS.
 * These are unconditionally public — no authentication or ACL checks.
 * IMPORTANT: Always provide this endpoint when object storage is set up.
 */
router.get("/storage/public-objects/*filePath", async (req: Request, res: Response) => {
  try {
    const raw = req.params.filePath;
    const filePath = Array.isArray(raw) ? raw.join("/") : raw;
    const file = await objectStorageService.searchPublicObject(filePath);
    if (!file) {
      res.status(404).json({ error: "File not found" });
      return;
    }

    const response = await objectStorageService.downloadObject(file);

    res.status(response.status);
    response.headers.forEach((value, key) => res.setHeader(key, value));

    if (response.body) {
      const nodeStream = Readable.fromWeb(response.body as ReadableStream<Uint8Array>);
      nodeStream.pipe(res);
    } else {
      res.end();
    }
  } catch (error) {
    req.log.error({ err: error }, "Error serving public object");
    res.status(500).json({ error: "Failed to serve public object" });
  }
});

/**
 * GET /storage/objects/*
 *
 * Serve object entities from PRIVATE_OBJECT_DIR. Secured with requireAuth so the
 * private namespace is not publicly readable: only authenticated users can fetch
 * objects (e.g. avatars, which are shown to the user and to other members in
 * their circles). Same-origin <img> requests include the session cookie, so
 * avatars render without extra handling.
 */
router.get("/storage/objects/*path", requireAuth, async (req: Request, res: Response) => {
  try {
    const raw = req.params.path;
    const wildcardPath = Array.isArray(raw) ? raw.join("/") : raw;
    const objectPath = `/objects/${wildcardPath}`;
    const objectFile = await objectStorageService.getObjectEntityFile(objectPath);

    // Object-level authorization: never stream a private object to a user who
    // isn't allowed to read it. Objects carry an ACL policy set when they are
    // bound to an avatar / circle / goal; anything without a policy (e.g. a raw
    // upload that was never attached) is denied. This stops one logged-in user
    // from fetching another user's object just by knowing its path.
    const requester = (req as AuthRequest).user;
    const canRead = await objectStorageService.canAccessObjectEntity({
      userId: requester.id,
      objectFile,
      requestedPermission: ObjectPermission.READ,
    });
    if (!canRead) {
      res.status(403).json({ error: "Forbidden" });
      return;
    }

    // These are user-uploaded, untrusted files. Serve them with content-type
    // sanitization (nosniff + non-image → octet-stream attachment) so a
    // disguised HTML/JS upload can never execute from our origin.
    const response = await objectStorageService.downloadObject(objectFile, { sanitize: true });

    res.status(response.status);
    response.headers.forEach((value, key) => res.setHeader(key, value));

    if (response.body) {
      const nodeStream = Readable.fromWeb(response.body as ReadableStream<Uint8Array>);
      nodeStream.pipe(res);
    } else {
      res.end();
    }
  } catch (error) {
    if (error instanceof ObjectNotFoundError) {
      req.log.warn({ err: error }, "Object not found");
      res.status(404).json({ error: "Object not found" });
      return;
    }
    req.log.error({ err: error }, "Error serving object");
    res.status(500).json({ error: "Failed to serve object" });
  }
});

export default router;
