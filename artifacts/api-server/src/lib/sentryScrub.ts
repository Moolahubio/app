/**
 * Allowlist scrubber for everything the Sentry SDKs send (spec §8). The API's
 * beforeSend / beforeSendSpan / beforeBreadcrumb all run through here, and the
 * web app imports this same file, so it has no imports of its own.
 *
 * Sentry gets enough to find a bug (the error, its stack, the route, our own
 * tags, the user's UUID) and nothing a user typed or owns:
 *  - events keep only allowlisted fields, tags and contexts; `extra` is dropped;
 *  - a request keeps its method and a query-less URL. Headers (outgoing Privy
 *    `Authorization` and `privy-authorization-signature` included), cookies,
 *    bodies and query strings never leave the process;
 *  - breadcrumbs and spans keep allowlisted data keys, so `db.statement`,
 *    query params and header attributes are dropped;
 *  - every string that survives is masked: 0x… hex (addresses, hashes, keys),
 *    emails, credentials, long token-like strings (session tokens, RPC keys in
 *    URL paths), money amounts and the `params:` dump drizzle appends to a
 *    failed query.
 */

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HAS_UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
const UUID_ANY = new RegExp(HAS_UUID.source, "gi");

const SECRET_MASKS: Array<[RegExp, string]> = [
  // drizzle: "Failed query: <sql>\nparams: <every bound value>"
  [/\bparams:[\s\S]*$/, "params: [Filtered]"],
  // Postgres key details: Key (email)=(a@b.c) already exists.
  [/\(([\w", ]+)\)=\([^)]*\)/g, "($1)=([Filtered])"],
  // URL credentials and query strings.
  [/\/\/[^/\s:@]+:[^/\s@]+@/g, "//[Filtered]@"],
  [/(https?:\/\/[^\s?#"']*)\?[^\s#"']*/gi, "$1"],
  [/0x[0-9a-f]{4,}/gi, "[hex]"],
  [/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[email]"],
  [/\b(bearer|basic)\s+[\w.~+/=-]+/gi, "$1 [token]"],
  // key=value / key: value pairs whose value is a credential.
  [/\b(pass(?:word)?|passwd|otp|totp|pin|token|secret|session|api_?key|signature|authorization|cookie)(\s*[=:]\s*)[^\s,;&"')]+/gi, "$1$2[Filtered]"],
  [/\beyJ[\w-]+\.[\w-]+\.[\w-]*/g, "[token]"],
];

// Long opaque runs with a digit: hex session tokens, API keys in RPC URL paths.
// A run holding a UUID (our row and user ids) is kept. A callback instead of a
// lookbehind, so older Safari can still parse the web bundle.
const LONG_RUN = /[\w-]{24,}/g;
const maskLongRun = (run: string) => (/\d/.test(run) && !HAS_UUID.test(run) ? "[token]" : run);

const MONEY_MASKS: Array<[RegExp, string]> = [
  // "$12.50", "$1,200" ("$1" alone is left: it is far more often a SQL placeholder).
  [/[$€£₵]\s?(?:\d[\d,]*\.\d+|\d{1,3}(?:,\d{3})+)/g, "[amount]"],
  // "1,234.56 USDC", "−5.00 USDC" (formatMoney), "500 cents".
  [/[−-]?\d[\d,]*(?:\.\d+)?\s?(?:USDC|USD|GHS|EUR|GBP|cents?)\b/gi, "[amount]"],
  // "amountCents=1250", "balance: 10".
  [/\b(\w*(?:amount|balance|cents)\w*)(\s*[=:]\s*)-?\d[\d,.]*/gi, "$1$2[amount]"],
];

export function scrubString(s: string): string {
  let out = s;
  for (const [re, replacement] of SECRET_MASKS) out = out.replace(re, replacement);
  out = out.replace(LONG_RUN, maskLongRun);
  for (const [re, replacement] of MONEY_MASKS) out = out.replace(re, replacement);
  return out;
}

/** Path only: drops the query string and fragment of an absolute or relative URL. */
export function scrubUrl(url: string): string {
  return scrubString(url.split(/[?#]/)[0] ?? "");
}

/** Route-style names: "/api/goals/<uuid>/release" -> "/api/goals/:id/release". */
function scrubName(name: string): string {
  return scrubString(name.replace(UUID_ANY, ":id")).replace(/\/\d+(?=\/|$)/g, "/:n");
}

// Errs toward dropping: a false positive only loses a debugging detail.
const SENSITIVE_KEY = /pass|secret|token|auth|cookie|session|signature|key|otp|code|email|phone|mnemonic|seed|private|address|amount|balance|cents|body|header|query|param|user|^ip$|[._]ip$/i;

/**
 * Values under keys we chose to keep: strings masked, nested objects kept only
 * for keys that don't look sensitive, depth-limited.
 */
function scrubValue(v: unknown, depth = 0): unknown {
  if (typeof v === "string") return scrubString(v);
  if (typeof v !== "object" || v === null) return v;
  if (depth > 4) return "[Filtered]";
  if (Array.isArray(v)) return v.slice(0, 50).map((x) => scrubValue(x, depth + 1));
  const out: Obj = {};
  for (const [k, x] of Object.entries(v)) {
    if (!SENSITIVE_KEY.test(k)) out[k] = scrubValue(x, depth + 1);
  }
  return out;
}

// SDK-generated ids, kept verbatim (a 32-hex trace id would otherwise read as a token).
const ID_KEYS = new Set(["trace_id", "span_id", "parent_span_id", "event_id", "exception_id", "parent_id"]);

function pick(src: unknown, keys: readonly string[]): Obj | undefined {
  if (!isObj(src)) return undefined;
  const out: Obj = {};
  for (const k of keys) if (src[k] !== undefined) out[k] = ID_KEYS.has(k) ? src[k] : scrubValue(src[k]);
  return Object.keys(out).length ? out : undefined;
}

// ---------------------------------------------------------------------------
// Allowlists
// ---------------------------------------------------------------------------

const EVENT_KEYS = [
  "event_id", "timestamp", "start_timestamp", "level", "platform", "logger",
  "release", "dist", "environment", "type", "fingerprint", "sdk", "debug_meta",
] as const;

const TAG_KEYS = new Set(["area", "route", "job", "transfer_kind", "monitor.slug", "handled", "mechanism", "level"]);

/** Context name -> fields kept. */
const CONTEXT_FIELDS: Record<string, readonly string[]> = {
  trace: ["trace_id", "span_id", "parent_span_id", "op", "status", "origin"],
  runtime: ["name", "version"],
  os: ["name", "version", "kernel_version"],
  device: ["arch", "boot_time", "processor_count", "cpu_description", "memory_size", "free_memory", "family", "model", "screen_resolution"],
  app: ["app_start_time", "app_memory"],
  browser: ["name", "version"],
  culture: ["locale", "timezone"],
  cloud_resource: ["cloud.provider", "cloud.region", "cloud.platform"],
  response: ["status_code"],
  transfer: ["rowId", "attempts", "reason"],
};

const BREADCRUMB_DATA_KEYS = new Set([
  "method", "status_code", "url", "from", "to", "http.method", "http.request.method",
  "http.response.status_code", "logger", "category", "level",
]);

/** Span attributes kept: exact keys, plus anything under these prefixes. */
const SPAN_ATTR_KEYS = new Set([
  "http.request.method", "http.response.status_code", "http.route", "http.method", "http.status_code",
  "url.path", "url.full", "url.scheme", "server.address", "server.port", "db.system", "db.system.name",
  "db.operation", "db.operation.name", "db.collection.name", "db.namespace", "express.name", "express.type",
  "process.runtime.name", "process.runtime.version",
]);
const SPAN_ATTR_PREFIXES = ["sentry.", "otel.", "network.", "thread.", "code.", "app.", "os.", "device.", "browser.", "ui."];
const URL_ATTRS = new Set(["url.full", "url.path", "http.url", "http.target", "url"]);

function keepSpanAttr(key: string): boolean {
  return SPAN_ATTR_KEYS.has(key) || SPAN_ATTR_PREFIXES.some((p) => key.startsWith(p));
}

function scrubAttributes(attrs: unknown): Obj {
  const out: Obj = {};
  if (!isObj(attrs)) return out;
  for (const [k, v] of Object.entries(attrs)) {
    if (!keepSpanAttr(k)) continue;
    // Streamed spans may wrap values as { value, type, unit }.
    const raw = isObj(v) && "value" in v ? v.value : v;
    let clean: unknown = typeof raw === "string" && URL_ATTRS.has(k) ? scrubUrl(raw) : scrubValue(raw);
    if (typeof clean === "string" && /name$/.test(k)) clean = scrubName(clean);
    out[k] = isObj(v) && "value" in v ? { ...v, value: clean } : clean;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

type BreadcrumbLike = { type?: string; level?: string; category?: string; message?: string; data?: Obj; timestamp?: number; event_id?: string };

export function scrubBreadcrumb<B extends BreadcrumbLike>(b: B): B | null {
  const out: BreadcrumbLike = {};
  for (const k of ["type", "level", "category", "timestamp", "event_id"] as const) {
    if (b[k] !== undefined) (out as Obj)[k] = b[k];
  }
  if (typeof b.message === "string") out.message = scrubString(b.message);
  if (isObj(b.data)) {
    const data: Obj = {};
    for (const [k, v] of Object.entries(b.data)) {
      if (!BREADCRUMB_DATA_KEYS.has(k)) continue;
      data[k] = typeof v === "string" && (k === "url" || k === "from" || k === "to") ? scrubUrl(v) : scrubValue(v);
    }
    if (Object.keys(data).length) out.data = data;
  }
  return out as B;
}

function scrubException(values: unknown): unknown {
  if (!Array.isArray(values)) return undefined;
  return values.map((x) => {
    if (!isObj(x)) return x;
    const st = isObj(x.stacktrace) && Array.isArray(x.stacktrace.frames)
      ? {
          ...x.stacktrace,
          // Local variable values never leave the process.
          frames: x.stacktrace.frames.map((f) => (isObj(f) ? { ...f, vars: undefined } : f)),
        }
      : undefined;
    const mech = isObj(x.mechanism)
      ? pick(x.mechanism, ["type", "handled", "synthetic", "exception_id", "parent_id", "source", "is_exception_group"])
      : undefined;
    return {
      type: typeof x.type === "string" ? x.type : undefined,
      value: typeof x.value === "string" ? scrubString(x.value) : undefined,
      module: x.module,
      thread_id: x.thread_id,
      mechanism: mech,
      stacktrace: st,
    };
  });
}

/** beforeSend: rebuild the event from allowlisted parts only. */
export function scrubEvent<E extends object>(event: E): E {
  const e = event as Obj;
  const out: Obj = {};
  for (const k of EVENT_KEYS) if (e[k] !== undefined) out[k] = e[k];

  if (typeof e.message === "string") out.message = scrubString(e.message);
  if (isObj(e.logentry) && typeof e.logentry.message === "string") {
    out.logentry = { message: scrubString(e.logentry.message) };
  }
  if (typeof e.transaction === "string") out.transaction = scrubName(e.transaction);
  if (isObj(e.exception)) out.exception = { values: scrubException(e.exception.values) };

  const user = isObj(e.user) ? e.user.id : undefined;
  if (typeof user === "string" && UUID.test(user)) out.user = { id: user };

  if (isObj(e.request)) {
    const req: Obj = {};
    if (typeof e.request.method === "string") req.method = e.request.method;
    if (typeof e.request.url === "string") req.url = scrubUrl(e.request.url);
    out.request = req;
  }

  if (isObj(e.tags)) {
    const tags: Obj = {};
    for (const [k, v] of Object.entries(e.tags)) {
      if (TAG_KEYS.has(k)) tags[k] = typeof v === "string" ? scrubName(v) : v;
    }
    out.tags = tags;
  }

  if (isObj(e.contexts)) {
    const contexts: Obj = {};
    for (const [name, fields] of Object.entries(CONTEXT_FIELDS)) {
      const c = pick(e.contexts[name], fields);
      if (c) contexts[name] = c;
    }
    out.contexts = contexts;
  }

  if (Array.isArray(e.breadcrumbs)) {
    out.breadcrumbs = e.breadcrumbs
      .filter(isObj)
      .map((b) => scrubBreadcrumb(b as BreadcrumbLike))
      .filter(Boolean);
  }
  return out as E;
}

type SpanLike = { name?: string; description?: string; attributes?: unknown; data?: unknown };

/** beforeSendSpan: names lose ids and secrets; attributes are allowlisted. */
export function scrubSpan<S extends SpanLike>(span: S): S {
  const out = { ...span } as SpanLike;
  if (typeof out.name === "string") out.name = scrubName(out.name);
  if (typeof out.description === "string") out.description = scrubName(out.description);
  if (out.attributes !== undefined) out.attributes = scrubAttributes(out.attributes);
  if (out.data !== undefined) out.data = scrubAttributes(out.data);
  return out as S;
}
