import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  randomBytes,
  scryptSync,
  timingSafeEqual,
} from "node:crypto";

/**
 * AES-256-GCM encryption for secrets at rest (EVM private keys, 2FA seeds).
 *
 * On testnet we custody an encrypted key per user as a stand-in for a
 * non-custodial signer — encrypted with a key derived from APP_ENCRYPTION_KEY.
 *
 * Key derivation:
 *  - The recommended (and fastest-path) format is a 64-char hex string,
 *    i.e. 32 bytes of real random entropy generated with e.g.
 *    `openssl rand -hex 32`. That is used directly as the AES-256 key.
 *  - Any other value is treated as a human-chosen passphrase and is
 *    stretched through scrypt (a memory-hard KDF) with a high work factor
 *    before use. This does not turn a weak passphrase into a strong key,
 *    but it makes offline brute-forcing of a leaked-database scenario far
 *    more expensive than the previous single-pass sha256, which could be
 *    tested at billions of guesses/sec on commodity hardware.
 *  - A minimum length is enforced so trivially short secrets are rejected
 *    outright at startup instead of silently producing a weak key.
 */
const KDF_SALT = "moolahub.app-encryption-key.kdf.v1";
const MIN_PASSPHRASE_LENGTH = 20;
// N=2^17, r=8, p=1 is an OWASP-recommended interactive scrypt work factor;
// ~128MB memory and a few hundred ms per derivation. We cache the derived
// key below so this cost is only paid once per process lifetime.
const SCRYPT_OPTS = { N: 2 ** 17, r: 8, p: 1, maxmem: 256 * 1024 * 1024 };

let cachedKey: Buffer | null = null;

function key(): Buffer {
  if (cachedKey) return cachedKey;
  const raw = process.env.APP_ENCRYPTION_KEY;
  if (!raw) throw new Error("APP_ENCRYPTION_KEY is not set");

  // Preferred: 64 hex chars = 32 bytes of real random entropy, used as-is.
  if (/^[0-9a-fA-F]{64}$/.test(raw)) {
    cachedKey = Buffer.from(raw, "hex");
    return cachedKey;
  }

  if (raw.length < MIN_PASSPHRASE_LENGTH) {
    throw new Error(
      `APP_ENCRYPTION_KEY is too weak (${raw.length} chars). Use a 64-character ` +
        `hex string generated with \`openssl rand -hex 32\`, or a passphrase of ` +
        `at least ${MIN_PASSPHRASE_LENGTH} characters with real entropy.`,
    );
  }

  cachedKey = scryptSync(raw, KDF_SALT, 32, SCRYPT_OPTS);
  return cachedKey;
}

export function encryptSecret(plain: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key(), iv);
  const enc = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  // iv.tag.ciphertext, base64
  return `${iv.toString("base64")}.${tag.toString("base64")}.${enc.toString("base64")}`;
}

export function decryptSecret(payload: string): string {
  const [ivB64, tagB64, dataB64] = payload.split(".");
  if (!ivB64 || !tagB64 || !dataB64) throw new Error("Malformed ciphertext");
  const decipher = createDecipheriv("aes-256-gcm", key(), Buffer.from(ivB64, "base64"));
  decipher.setAuthTag(Buffer.from(tagB64, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(dataB64, "base64")),
    decipher.final(),
  ]).toString("utf8");
}

/**
 * Sign an opaque payload string with an HMAC over APP_ENCRYPTION_KEY. Used to
 * mint short-lived, single-purpose capability tokens (e.g. "this specific
 * user may PUT this specific upload object id until this expiry") without
 * needing any server-side state to verify them later.
 */
export function hmacSign(payload: string): string {
  return createHmac("sha256", key()).update(payload).digest("hex");
}

/** Constant-time comparison of two HMAC hex digests. */
export function hmacVerify(payload: string, signature: string): boolean {
  const expected = hmacSign(payload);
  const expectedBuf = Buffer.from(expected, "hex");
  const gotBuf = Buffer.from(signature, "hex");
  if (expectedBuf.length !== gotBuf.length) return false;
  return timingSafeEqual(expectedBuf, gotBuf);
}
