import { Router, type IRouter, type Request, type Response } from "express";
import { Readable } from "stream";
import {
  RequestUploadUrlBody,
  RequestUploadUrlResponse,
} from "@workspace/api-zod";
import {
  ObjectStorageService,
  ObjectNotFoundError,
  ALLOWED_IMAGE_TYPES,
} from "../lib/objectStorage";
import { ObjectPermission } from "../lib/objectAcl";
import { requireAuth, type AuthRequest } from "../lib/auth";

const router: IRouter = Router();
const objectStorageService = new ObjectStorageService();

/** Hard cap on uploads (avatars / circle images are small). */
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

/**
 * POST /storage/uploads/request-url
 *
 * Request a presigned URL for file upload.
 * The client sends JSON metadata (name, size, contentType) — NOT the file.
 * Then uploads the file directly to the returned presigned URL.
 */
router.post("/storage/uploads/request-url", requireAuth, async (req: Request, res: Response) => {
  const parsed = RequestUploadUrlBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Missing or invalid required fields" });
    return;
  }

  const { name, size, contentType } = parsed.data;

  // Only images may be uploaded into the private namespace, and only up to a
  // sane size. This (together with sanitized serving below) prevents the bucket
  // from being used to host arbitrary HTML/JS that would execute from our
  // origin.
  if (!contentType || !ALLOWED_IMAGE_TYPES.has(contentType.toLowerCase())) {
    res.status(400).json({ error: "Only PNG, JPEG, WebP, or GIF images can be uploaded." });
    return;
  }
  if (typeof size === "number" && size > MAX_UPLOAD_BYTES) {
    res.status(400).json({ error: "Image is too large (max 10MB)." });
    return;
  }

  try {
    const uploadURL = await objectStorageService.getObjectEntityUploadURL();
    const objectPath = objectStorageService.normalizeObjectEntityPath(uploadURL);

    res.json(
      RequestUploadUrlResponse.parse({
        uploadURL,
        objectPath,
        metadata: { name, size, contentType },
      }),
    );
  } catch (error) {
    req.log.error({ err: error }, "Error generating upload URL");
    res.status(500).json({ error: "Failed to generate upload URL" });
  }
});

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
