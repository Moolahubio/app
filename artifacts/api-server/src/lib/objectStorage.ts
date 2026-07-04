import { Storage, File } from "@google-cloud/storage";
import { Readable, Transform } from "stream";
import { pipeline } from "stream/promises";
import { randomUUID } from "crypto";
import {
  ObjectAclPolicy,
  ObjectPermission,
  canAccessObject,
  getObjectAclPolicy,
  setObjectAclPolicy,
} from "./objectAcl";
import { hmacSign, hmacVerify } from "./crypto";

/** Upload capability tokens are only valid for this long after minting. */
const UPLOAD_TOKEN_TTL_MS = 15 * 60 * 1000;

function uploadTokenPayload(objectId: string, userId: string, expiresAt: number): string {
  return `${objectId}.${userId}.${expiresAt}`;
}

/**
 * Mint a capability token binding a specific upload objectId to the specific
 * user who requested it, with an expiry. This is what stops an unrelated
 * authenticated user from PUTing bytes to an objectId they merely guessed or
 * observed (e.g. from a public image URL) — resolveUploadTarget alone derives
 * the same bucket path for anyone who knows the id, so without this binding
 * `PUT /storage/uploads/:objectId` would let any logged-in user overwrite any
 * existing upload object.
 */
export function signUploadToken(objectId: string, userId: string): string {
  const expiresAt = Date.now() + UPLOAD_TOKEN_TTL_MS;
  const signature = hmacSign(uploadTokenPayload(objectId, userId, expiresAt));
  return `${expiresAt}.${signature}`;
}

/** Verify a token minted by signUploadToken for this exact objectId + userId pair. */
export function verifyUploadToken(objectId: string, userId: string, token: string): boolean {
  const [expiresAtRaw, signature] = token.split(".");
  if (!expiresAtRaw || !signature) return false;
  const expiresAt = Number(expiresAtRaw);
  if (!Number.isFinite(expiresAt) || Date.now() > expiresAt) return false;
  return hmacVerify(uploadTokenPayload(objectId, userId, expiresAt), signature);
}

const REPLIT_SIDECAR_ENDPOINT = "http://127.0.0.1:1106";

export const objectStorageClient = new Storage({
  credentials: {
    audience: "replit",
    subject_token_type: "access_token",
    token_url: `${REPLIT_SIDECAR_ENDPOINT}/token`,
    type: "external_account",
    credential_source: {
      url: `${REPLIT_SIDECAR_ENDPOINT}/credential`,
      format: {
        type: "json",
        subject_token_field_name: "access_token",
      },
    },
    universe_domain: "googleapis.com",
  },
  projectId: "",
});

export class ObjectNotFoundError extends Error {
  constructor() {
    super("Object not found");
    this.name = "ObjectNotFoundError";
    Object.setPrototypeOf(this, ObjectNotFoundError.prototype);
  }
}

/**
 * Thrown by receiveUpload() when the client streams more than maxBytes.
 * Distinct from a generic upload failure so the route can respond 413
 * instead of 500/502.
 */
export class UploadTooLargeError extends Error {
  constructor() {
    super("Upload exceeds the maximum allowed size");
    this.name = "UploadTooLargeError";
    Object.setPrototypeOf(this, UploadTooLargeError.prototype);
  }
}

/** Content types we accept as user-uploaded images and serve inline. SVG is
 * deliberately excluded — it can carry executable script. */
export const ALLOWED_IMAGE_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
]);

/**
 * Hard cap on uploads (avatars / circle images are small). Shared by the
 * request-url route (declared-metadata check) and isUsableImageObject /
 * sweepOrphanedUploads (real stored-object check) so the policy can't drift
 * between the two enforcement points.
 */
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

/**
 * How long a freshly-signed upload URL may sit unused/unclaimed before the GC
 * sweep considers it abandoned. Generous relative to the 900s PUT URL TTL so
 * legitimate clients have time to upload and then attach the object (as an
 * avatar / circle / goal image) before it's swept.
 */
const ORPHAN_GRACE_MS = 2 * 60 * 60 * 1000; // 2 hours

/**
 * Whether a value is a safe internal object-storage reference (e.g. an avatar
 * or circle image previously uploaded through this app). Used to reject
 * arbitrary absolute/external URLs from being stored as image fields, which
 * would otherwise be rendered in other users' browsers (tracking / SSRF / mixed
 * content). Only our own `/objects/<id>` paths are allowed.
 */
export function isStoredObjectPath(value: string): boolean {
  return /^\/objects\/[A-Za-z0-9._/-]+$/.test(value);
}

export class ObjectStorageService {
  constructor() {}

  /** See standalone verifyUploadToken() above for the security rationale. */
  verifyUploadToken(objectId: string, userId: string, token: string): boolean {
    return verifyUploadToken(objectId, userId, token);
  }

  getPublicObjectSearchPaths(): Array<string> {
    const pathsStr = process.env.PUBLIC_OBJECT_SEARCH_PATHS || "";
    const paths = Array.from(
      new Set(
        pathsStr
          .split(",")
          .map((path) => path.trim())
          .filter((path) => path.length > 0)
      )
    );
    if (paths.length === 0) {
      throw new Error(
        "PUBLIC_OBJECT_SEARCH_PATHS not set. Create a bucket in 'Object Storage' " +
          "tool and set PUBLIC_OBJECT_SEARCH_PATHS env var (comma-separated paths)."
      );
    }
    return paths;
  }

  getPrivateObjectDir(): string {
    const dir = process.env.PRIVATE_OBJECT_DIR || "";
    if (!dir) {
      throw new Error(
        "PRIVATE_OBJECT_DIR not set. Create a bucket in 'Object Storage' " +
          "tool and set PRIVATE_OBJECT_DIR env var."
      );
    }
    return dir;
  }

  async searchPublicObject(filePath: string): Promise<File | null> {
    for (const searchPath of this.getPublicObjectSearchPaths()) {
      const fullPath = `${searchPath}/${filePath}`;

      const { bucketName, objectName } = parseObjectPath(fullPath);
      const bucket = objectStorageClient.bucket(bucketName);
      const file = bucket.file(objectName);

      const [exists] = await file.exists();
      if (exists) {
        return file;
      }
    }

    return null;
  }

  async downloadObject(
    file: File,
    opts: { cacheTtlSec?: number; sanitize?: boolean } = {},
  ): Promise<Response> {
    const cacheTtlSec = opts.cacheTtlSec ?? 3600;
    const [metadata] = await file.getMetadata();
    const aclPolicy = await getObjectAclPolicy(file);
    const isPublic = aclPolicy?.visibility === "public";

    const nodeStream = file.createReadStream();
    const webStream = Readable.toWeb(nodeStream) as ReadableStream;

    let contentType = (metadata.contentType as string) || "application/octet-stream";

    const headers: Record<string, string> = {
      "Cache-Control": `${isPublic ? "public" : "private"}, max-age=${cacheTtlSec}`,
    };

    // For user-uploaded (untrusted) objects, never let the file be interpreted
    // as active content from our own origin. Stop MIME sniffing, and downgrade
    // anything that isn't a known-safe image to an octet-stream attachment so a
    // disguised HTML/JS upload can't execute when fetched.
    if (opts.sanitize) {
      headers["X-Content-Type-Options"] = "nosniff";
      if (!ALLOWED_IMAGE_TYPES.has(contentType.toLowerCase())) {
        contentType = "application/octet-stream";
        headers["Content-Disposition"] = "attachment";
      }
    }

    headers["Content-Type"] = contentType;
    if (metadata.size) {
      headers["Content-Length"] = String(metadata.size);
    }

    return new Response(webStream, { headers });
  }

  /**
   * Deterministically resolve the bucket/object location for an upload id in
   * the private `uploads/` namespace. Kept stateless (no DB/memory mapping)
   * so the request-url route and the actual upload-receiving route can each
   * independently derive the same location from the id alone.
   */
  resolveUploadTarget(objectId: string): {
    objectPath: string;
    bucketName: string;
    objectName: string;
  } {
    let privateObjectDir = this.getPrivateObjectDir();
    if (!privateObjectDir.endsWith("/")) {
      privateObjectDir = `${privateObjectDir}/`;
    }
    const fullPath = `${privateObjectDir}uploads/${objectId}`;
    const { bucketName, objectName } = parseObjectPath(fullPath);
    return { objectPath: `/objects/uploads/${objectId}`, bucketName, objectName };
  }

  /**
   * Allocate a new upload id in the private `uploads/` namespace.
   *
   * Deliberately does NOT mint a signed GCS URL: the Replit sidecar can only
   * sign a bucket/object/method/expiry tuple, it cannot bind content-type or
   * content-length (see receiveUpload below), so a signed PUT URL handed
   * straight to the client would let it write an arbitrarily large body
   * directly to the bucket. Instead, the caller uploads through this server
   * (see routes/storage.ts `PUT /storage/uploads/:objectId`), which streams
   * the body to GCS itself and can enforce the byte cap in real time.
   */
  allocateUploadObject(userId: string): {
    objectId: string;
    objectPath: string;
    bucketName: string;
    objectName: string;
    uploadToken: string;
  } {
    const objectId = randomUUID();
    return {
      objectId,
      ...this.resolveUploadTarget(objectId),
      uploadToken: signUploadToken(objectId, userId),
    };
  }

  /**
   * Stream an incoming upload body into GCS, enforcing `maxBytes` in real
   * time as bytes arrive from the client — this is the actual size
   * enforcement for uploads (see allocateUploadObject for why a signed URL
   * can't do this). As soon as more than `maxBytes` have been read, the
   * pipeline is torn down: the in-flight GCS write is aborted (a GCS "simple"
   * upload is atomic, so an aborted request never creates a partial object)
   * and any object that did land is deleted defensively.
   */
  async receiveUpload({
    bucketName,
    objectName,
    contentType,
    body,
    maxBytes = MAX_UPLOAD_BYTES,
  }: {
    bucketName: string;
    objectName: string;
    contentType: string;
    body: Readable;
    maxBytes?: number;
  }): Promise<{ size: number }> {
    const bucket = objectStorageClient.bucket(bucketName);
    const file = bucket.file(objectName);
    const writeStream = file.createWriteStream({
      resumable: false,
      metadata: { contentType },
    });

    let received = 0;
    let tooLarge = false;

    const limiter = new Transform({
      transform(chunk: Buffer, _enc, callback) {
        received += chunk.length;
        if (received > maxBytes) {
          tooLarge = true;
          callback(new Error("upload_too_large"));
          return;
        }
        callback(null, chunk);
      },
    });

    try {
      await pipeline(body, limiter, writeStream);
    } catch (err) {
      // Defensive cleanup: a simple (non-resumable) GCS upload only creates
      // the object once the whole request completes, so aborting mid-stream
      // should leave nothing behind — but delete unconditionally in case.
      await file.delete({ ignoreNotFound: true }).catch(() => {});
      if (tooLarge) {
        throw new UploadTooLargeError();
      }
      throw err;
    }

    return { size: received };
  }

  /**
   * Verify an uploaded object path points to a real, allowlisted image within
   * the size cap. The signed PUT URL itself is not constrained, so the upload
   * content-type/size policy is actually *enforced here* — at the moment an
   * object is accepted as an avatar / circle image — by inspecting the stored
   * object's real metadata. Returns false (rather than throwing) so callers can
   * reject with a friendly message.
   */
  async isUsableImageObject(
    objectPath: string,
    maxBytes: number = MAX_UPLOAD_BYTES,
  ): Promise<boolean> {
    if (!isStoredObjectPath(objectPath)) return false;
    try {
      const file = await this.getObjectEntityFile(objectPath);
      const [metadata] = await file.getMetadata();
      const contentType = (metadata.contentType as string | undefined)?.toLowerCase();
      if (!contentType || !ALLOWED_IMAGE_TYPES.has(contentType)) return false;
      // Fail closed: missing or non-finite size metadata is treated as invalid
      // rather than passing the cap check.
      const size = Number(metadata.size);
      if (!Number.isFinite(size) || size <= 0 || size > maxBytes) return false;
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Garbage-collect uploads sitting in the private `uploads/` namespace that
   * were minted a signed PUT URL but never validly claimed. The signed URL
   * itself can't bind content-type/size (see getObjectEntityUploadURL), so
   * this is where that policy is actually enforced against every object that
   * lands there, not just ones a user chooses to attach:
   *
   *  - Any unclaimed (no ACL policy set) object whose real stored metadata
   *    violates the image/size policy is deleted immediately — it could never
   *    legitimately pass isUsableImageObject anyway.
   *  - Any unclaimed object older than ORPHAN_GRACE_MS is deleted regardless
   *    of validity, so abandoned-but-otherwise-valid uploads don't accumulate
   *    storage cost forever.
   *  - Claimed objects (owner set via claimObjectEntityForOwner) are never
   *    touched here; their lifecycle is owned by the feature that attached
   *    them (profile/circle/goal).
   *
   * Best-effort: failures on an individual file are logged-by-omission (the
   * file is simply left for the next sweep) so one bad object can't abort the
   * whole pass.
   */
  async sweepOrphanedUploads(): Promise<{ scanned: number; deleted: number }> {
    let privateObjectDir: string;
    try {
      privateObjectDir = this.getPrivateObjectDir();
    } catch {
      return { scanned: 0, deleted: 0 };
    }

    const uploadsDirPath = `${privateObjectDir.replace(/\/+$/, "")}/uploads/`;
    const { bucketName, objectName: prefix } = parseObjectPath(uploadsDirPath);
    const bucket = objectStorageClient.bucket(bucketName);

    const [files] = await bucket.getFiles({ prefix });
    let deleted = 0;
    const now = Date.now();

    for (const file of files) {
      try {
        const [metadata] = await file.getMetadata();
        const policy = await getObjectAclPolicy(file);
        if (policy) continue; // claimed — owned by profile/circle/goal lifecycle

        const contentType = (metadata.contentType as string | undefined)?.toLowerCase();
        const size = Number(metadata.size);
        const isValidImage =
          !!contentType &&
          ALLOWED_IMAGE_TYPES.has(contentType) &&
          Number.isFinite(size) &&
          size > 0 &&
          size <= MAX_UPLOAD_BYTES;

        const createdMs = metadata.timeCreated ? new Date(metadata.timeCreated as string).getTime() : NaN;
        const isExpired = !Number.isFinite(createdMs) || now - createdMs > ORPHAN_GRACE_MS;

        if (!isValidImage || isExpired) {
          await file.delete({ ignoreNotFound: true });
          deleted++;
        }
      } catch {
        // Leave this object for the next sweep rather than aborting the pass.
      }
    }

    return { scanned: files.length, deleted };
  }

  async getObjectEntityFile(objectPath: string): Promise<File> {
    if (!objectPath.startsWith("/objects/")) {
      throw new ObjectNotFoundError();
    }

    const parts = objectPath.slice(1).split("/");
    if (parts.length < 2) {
      throw new ObjectNotFoundError();
    }

    const entityId = parts.slice(1).join("/");
    let entityDir = this.getPrivateObjectDir();
    if (!entityDir.endsWith("/")) {
      entityDir = `${entityDir}/`;
    }
    const objectEntityPath = `${entityDir}${entityId}`;
    const { bucketName, objectName } = parseObjectPath(objectEntityPath);
    const bucket = objectStorageClient.bucket(bucketName);
    const objectFile = bucket.file(objectName);
    const [exists] = await objectFile.exists();
    if (!exists) {
      throw new ObjectNotFoundError();
    }
    return objectFile;
  }

  normalizeObjectEntityPath(rawPath: string): string {
    if (!rawPath.startsWith("https://storage.googleapis.com/")) {
      return rawPath;
    }

    const url = new URL(rawPath);
    const rawObjectPath = url.pathname;

    let objectEntityDir = this.getPrivateObjectDir();
    if (!objectEntityDir.endsWith("/")) {
      objectEntityDir = `${objectEntityDir}/`;
    }

    if (!rawObjectPath.startsWith(objectEntityDir)) {
      return rawObjectPath;
    }

    const entityId = rawObjectPath.slice(objectEntityDir.length);
    return `/objects/${entityId}`;
  }

  async trySetObjectEntityAclPolicy(
    rawPath: string,
    aclPolicy: ObjectAclPolicy
  ): Promise<string> {
    const normalizedPath = this.normalizeObjectEntityPath(rawPath);
    if (!normalizedPath.startsWith("/")) {
      return normalizedPath;
    }

    const objectFile = await this.getObjectEntityFile(normalizedPath);
    await setObjectAclPolicy(objectFile, aclPolicy);
    return normalizedPath;
  }

  /**
   * Claim ownership of an uploaded object and set its ACL policy, but ONLY if it
   * is not already owned by someone else. This prevents one authenticated user
   * from rebinding (and thereby hijacking, exposing, or denying) another user's
   * object just by knowing its path — see canAccessObjectEntity on the read path.
   * Returns false if the object is already owned by a different user.
   */
  async claimObjectEntityForOwner(
    rawPath: string,
    ownerId: string,
    visibility: "public" | "private"
  ): Promise<boolean> {
    const normalizedPath = this.normalizeObjectEntityPath(rawPath);
    if (!normalizedPath.startsWith("/")) {
      return false;
    }

    const objectFile = await this.getObjectEntityFile(normalizedPath);
    const existing = await getObjectAclPolicy(objectFile);
    if (existing && existing.owner !== ownerId) {
      return false;
    }

    await setObjectAclPolicy(objectFile, { owner: ownerId, visibility });
    return true;
  }

  async canAccessObjectEntity({
    userId,
    objectFile,
    requestedPermission,
  }: {
    userId?: string;
    objectFile: File;
    requestedPermission?: ObjectPermission;
  }): Promise<boolean> {
    return canAccessObject({
      userId,
      objectFile,
      requestedPermission: requestedPermission ?? ObjectPermission.READ,
    });
  }
}

function parseObjectPath(path: string): {
  bucketName: string;
  objectName: string;
} {
  if (!path.startsWith("/")) {
    path = `/${path}`;
  }
  const pathParts = path.split("/");
  if (pathParts.length < 3) {
    throw new Error("Invalid path: must contain at least a bucket name");
  }

  const bucketName = pathParts[1];
  const objectName = pathParts.slice(2).join("/");

  return {
    bucketName,
    objectName,
  };
}

async function signObjectURL({
  bucketName,
  objectName,
  method,
  ttlSec,
}: {
  bucketName: string;
  objectName: string;
  method: "GET" | "PUT" | "DELETE" | "HEAD";
  ttlSec: number;
}): Promise<string> {
  const request = {
    bucket_name: bucketName,
    object_name: objectName,
    method,
    expires_at: new Date(Date.now() + ttlSec * 1000).toISOString(),
  };
  const response = await fetch(
    `${REPLIT_SIDECAR_ENDPOINT}/object-storage/signed-object-url`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(request),
      signal: AbortSignal.timeout(30_000),
    }
  );
  if (!response.ok) {
    throw new Error(
      `Failed to sign object URL, errorcode: ${response.status}, ` +
        `make sure you're running on Replit`
    );
  }

  const { signed_url: signedURL } = (await response.json()) as { signed_url: string };
  return signedURL;
}
