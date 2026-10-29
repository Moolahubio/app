/**
 * The `req` fields of a request log line (pino-http's `req` serializer), and
 * the secret scrub every log line goes through (lib/logger.ts). No imports, so
 * it is unit-tested without a database.
 *
 * Always the request id, method and path, with the query string cut off. Outside
 * production only, a request that an iOS UI test marked with `X-MH-Test-Run`
 * (Debug builds only) also logs that run id and its query string, so the test
 * can count its own requests on a dev backend every simulator shares. Secret
 * query parameters in it are redacted. Production output is unchanged, and
 * nothing else reads the header.
 */
const TEST_RUN_RE = /^[A-Za-z0-9-]{1,64}$/;

export type RequestLogFields = {
  id: unknown;
  method: string | undefined;
  url: string | undefined;
  testRun?: string;
  query?: string;
};

export function requestLogFields(
  req: { id?: unknown; method?: string; url?: string; headers?: Record<string, unknown> },
  isProduction: boolean,
): RequestLogFields {
  const fields: RequestLogFields = { id: req.id, method: req.method, url: req.url?.split("?")[0] };
  if (isProduction) return fields;
  const testRun = req.headers?.["x-mh-test-run"];
  if (typeof testRun !== "string" || !TEST_RUN_RE.test(testRun)) return fields;
  const url = req.url ?? "";
  const q = url.indexOf("?");
  fields.testRun = testRun;
  fields.query = q === -1 ? "" : redactQuery(url.slice(q + 1));
  return fields;
}

// ---------------------------------------------------------------------------
// Secret scrub (docs/privy-account-layer.md §3.14, invariant 5)
// ---------------------------------------------------------------------------

export const REDACTED = "[Redacted]";

/**
 * Field, header and query names whose values never reach a log line: auth
 * headers and cookies, any privy-* header, anything named authorization*
 * (authorizationKey), tokens (our session and refresh tokens, Privy access and
 * identity tokens, JWTs), signatures, API keys, one-time codes and PINs, also
 * under a compound name (emailCode, verification_code, smsOtp, user_pin),
 * nonces and challenges, passwords and secrets. statusCode, countryCode and
 * sessionId stay.
 */
export const SECRET_LOG_KEY = new RegExp(
  [
    "^(?:proxy-authorization|privy-.+|code|otp|totp|pin|nonce|challenge|session)$",
    "^authorization",
    "token|secret|passw|signature|credential|private_?key|api[-_]?key|mnemonic|cookie|jwt",
    "(?:email|verif\\w*|auth|login|signin|reset|recovery|backup|mfa|sms|magic|one_?time|otp)[-_]?code$",
    "otp$",
    "[-_]pin$",
  ].join("|"),
  "i",
);

/** Redact paths for pino (fast-redact syntax), on top of the scrub below. */
export const LOG_REDACT_PATHS = [
  "req.headers.authorization",
  "req.headers.cookie",
  'req.headers["x-session-token"]',
  'req.headers["x-operator-token"]',
  'req.headers["privy-token"]',
  'req.headers["privy-id-token"]',
  'req.headers["privy-authorization-signature"]',
  'res.headers["set-cookie"]',
  "err.config",
  "err.request",
  "err.response",
  "err.headers",
  "*.authorization",
  '*["privy-authorization-signature"]',
];

// Credentials that can sit inside a string: an error message, a URL, a stack.
// Any 64-hex value is masked: a raw private key or one of our session tokens
// looks the same as a transaction hash, so hashes are masked too.
const SECRET_STRINGS: Array<[RegExp, string]> = [
  [/\b(bearer|basic)\s+[\w.~+/=-]+/gi, `$1 ${REDACTED}`],
  [/\beyJ[\w-]+\.[\w-]+\.[\w-]*/g, REDACTED],
  [/privy_app_secret_\w+/g, REDACTED],
  [/wallet-(?:auth|api):[\w+/=]+/g, REDACTED],
  [/\/\/[^/\s:@]+:[^/\s@]+@/g, `//${REDACTED}@`],
  // Secret query parameters in a URL inside any string: ?token=…, &code=….
  [/([?&][\w.-]*?(?:token|secret|passw\w*|signature|sig|code|otp|nonce|state|jwt|session|key)=)[^&#\s"'<>]+/gi, `$1${REDACTED}`],
  [/\b(?:0x)?[0-9a-f]{64}\b/gi, REDACTED],
];

export function scrubLogString(s: string): string {
  let out = s;
  for (const [re, replacement] of SECRET_STRINGS) out = out.replace(re, replacement);
  return out;
}

/** "a=1&token=x" -> "a=1&token=[Redacted]". An OAuth `state` is redacted too. */
export function redactQuery(query: string): string {
  return query
    .split("&")
    .map((pair) => {
      const eq = pair.indexOf("=");
      if (eq === -1) return pair;
      let key = pair.slice(0, eq);
      try {
        key = decodeURIComponent(key);
      } catch {
        // keep the raw key
      }
      return SECRET_LOG_KEY.test(key) || key === "state" ? `${pair.slice(0, eq)}=${REDACTED}` : scrubLogString(pair);
    })
    .join("&");
}

// Request and response objects a client library hangs on its errors (axios
// `config`, `request`, `response`; fetch-style `headers`). They carry our own
// Authorization header and the upstream's cookies, so they are dropped whole.
const HTTP_BAGGAGE = new Set(["config", "request", "response", "headers", "req", "res"]);

const isPlainObject = (v: object) => {
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
};

// pino's serialized errors (nested `aggregateErrors`) are not plain objects.
const isSerializedError = (v: object) => "message" in v && "stack" in v;

type SerializeError = (err: unknown) => unknown;

function scrubValue(v: unknown, serializeError: SerializeError, depth: number): unknown {
  if (typeof v === "string") return scrubLogString(v);
  if (typeof v !== "object" || v === null) return v;
  if (v instanceof Error) return serializeError(v);
  if (depth > 8) return "[Truncated]";
  if (Array.isArray(v)) return v.map((x) => scrubValue(x, serializeError, depth + 1));
  if (!isPlainObject(v)) {
    if (isSerializedError(v)) return scrubSerializedError(v, serializeError);
    // What JSON.stringify would write: toJSON (a Date, a URL), else a class
    // instance's own fields (a client holding its app secret), scrubbed.
    const toJSON = (v as { toJSON?: unknown }).toJSON;
    if (typeof toJSON === "function") return scrubValue(toJSON.call(v), serializeError, depth + 1);
    if (v instanceof Map || v instanceof Set) return v;
  }
  const out: Record<string, unknown> = {};
  for (const [k, x] of Object.entries(v)) {
    out[k] = SECRET_LOG_KEY.test(k) ? REDACTED : scrubValue(x, serializeError, depth + 1);
  }
  return out;
}

/** Any value bound for a log line (a %o or %j argument, say): secret fields replaced, strings masked. */
export function scrubLogValue(v: unknown, serializeError: SerializeError): unknown {
  return scrubValue(v, serializeError, 1);
}

/**
 * pino `formatters.log` and `formatters.bindings`: the merge object of a log
 * call, or a child logger's bindings, with secret fields replaced and secret
 * strings masked. `req`, `res` and `err` keep their own serializers (lib/logger.ts);
 * an Error under any other key is serialized and scrubbed here.
 */
export function scrubLogFields(obj: Record<string, unknown>, serializeError: SerializeError): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (k === "req" || k === "res" || k === "err") out[k] = v;
    else out[k] = SECRET_LOG_KEY.test(k) ? REDACTED : scrubValue(v, serializeError, 1);
  }
  return out;
}

/**
 * An error already serialized by pino (type, message, stack and its own
 * fields): HTTP baggage dropped, secret fields replaced, strings masked. The
 * error's own `code` (ECONNREFUSED, 23505) is kept.
 */
export function scrubSerializedError(e: unknown, serializeError: SerializeError): unknown {
  if (typeof e === "string") return scrubLogString(e);
  if (typeof e !== "object" || e === null) return e;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(e)) {
    if (HTTP_BAGGAGE.has(k)) continue;
    if (k === "code" && (typeof v === "string" || typeof v === "number")) out[k] = v;
    else out[k] = SECRET_LOG_KEY.test(k) ? REDACTED : scrubValue(v, serializeError, 1);
  }
  return out;
}
