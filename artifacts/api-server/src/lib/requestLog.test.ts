/**
 * Unit tests for the request log fields (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/requestLog.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { requestLogFields } from "./requestLog";

const run = (header: unknown, url = "/api/activity?limit=100") => ({
  id: 7,
  method: "GET",
  url,
  headers: { "x-mh-test-run": header },
});

/** The serializer app.ts used before D1, kept to prove production output is unchanged. */
const before = (req: { id?: unknown; method?: string; url?: string }) => ({
  id: req.id,
  method: req.method,
  url: req.url?.split("?")[0],
});

test("production logs only id, method and the path, even with a valid header", () => {
  const fields = requestLogFields(run("run-1"), true);
  assert.deepEqual(fields, { id: 7, method: "GET", url: "/api/activity" });
  assert.deepEqual(Object.keys(fields), ["id", "method", "url"]);
  for (const req of [run("run-1"), run("run-1", "/api/goals"), { id: 1, method: "GET" }, {}]) {
    assert.equal(JSON.stringify(requestLogFields(req, true)), JSON.stringify(before(req)));
  }
});

test("development without the header logs only id, method and the path", () => {
  const req = { id: 7, method: "GET", url: "/api/activity?limit=100", headers: {} };
  assert.deepEqual(Object.keys(requestLogFields(req, false)), ["id", "method", "url"]);
  assert.equal(JSON.stringify(requestLogFields(req, false)), JSON.stringify(before(req)));
});

test("development with a valid header adds the run id and the query string", () => {
  assert.deepEqual(requestLogFields(run("run-1"), false), {
    id: 7,
    method: "GET",
    url: "/api/activity",
    testRun: "run-1",
    query: "limit=100",
  });
});

test("a marked request with no query string logs an empty query", () => {
  const fields = requestLogFields(run("run-1", "/api/dashboard/summary"), false);
  assert.equal(fields.url, "/api/dashboard/summary");
  assert.equal(fields.testRun, "run-1");
  assert.equal(fields.query, "");
});

test("invalid headers add nothing", () => {
  for (const bad of ["a b", "x".repeat(65), "", ["run-1"], 5]) {
    const fields = requestLogFields(run(bad), false);
    assert.deepEqual(Object.keys(fields), ["id", "method", "url"], `header ${JSON.stringify(bad)} adds nothing`);
  }
});

// ---------------------------------------------------------------------------
// Secret scrub (docs/privy-account-layer.md §3.14): the logger's real options,
// written to a capture stream. Every value below is a fake planted for the test.
// ---------------------------------------------------------------------------

// Built at runtime, so these fakes never sit in this public source as
// credential-shaped literals.
const b64url = (s: string) => Buffer.from(s).toString("base64url");
const fakeJwt = (sub: string, sig: string) =>
  [JSON.stringify({ alg: "ES256" }), JSON.stringify({ sub }), sig].map(b64url).join(".");

const SESSION_TOKEN = createHash("sha256").update("password").digest("hex");
const REFRESH_TOKEN = "rt_" + b64url("ClaudeTestRefreshToken0000001");
const PRIVY_ACCESS_TOKEN = fakeJwt("did:privy:access", "access-signature");
const PRIVY_ID_TOKEN = fakeJwt("did:privy:identity", "identity-signature");
const PRIVY_APP_SECRET = "privy_app_secret_" + "FakeTestValue" + "0".repeat(16);
const PRIVY_AUTH_KEY = "wallet-auth:" + b64url("FakeTestAuthorizationKey000");
// The fakes must keep the real formats, or the test stops exercising the real masks.
assert.match(SESSION_TOKEN, /^[0-9a-f]{64}$/);
for (const t of [PRIVY_ACCESS_TOKEN, PRIVY_ID_TOKEN]) assert.match(t, /^eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+$/);
assert.match(PRIVY_APP_SECRET, /^privy_app_secret_[A-Za-z0-9]{16,}$/);
assert.match(PRIVY_AUTH_KEY, /^wallet-auth:[A-Za-z0-9+/]{16,}={0,2}$/);

const PRIVY_SIGNATURE = "MEUCIQCfakeSignatureForTheLogTest000000000000000000AiB0";
const OPERATOR_TOKEN = "op_fake_operator_token_for_the_log_test_0000";
const EMAIL_CODE = "481516";
const NONCE = "n0nceFakeForTheLogTest";
const PASSWORD = "Fake-Log-Test-Passw0rd";
const RPC_PASSWORD = "fakeRpcPassw0rd";
const UNPREFIXED_APP_SECRET = "FakeUnprefixedAppSecretForTheLogTest0000";
const API_KEY = "fake_api_key_for_the_log_test_000000";
const VERIFICATION_CODE = "927314";
const RAW_KEY = `0x${"5f3c".repeat(16)}`;

const PLANTED: Record<string, string> = {
  SESSION_TOKEN, REFRESH_TOKEN, PRIVY_ACCESS_TOKEN, PRIVY_ID_TOKEN, PRIVY_APP_SECRET, PRIVY_AUTH_KEY,
  PRIVY_SIGNATURE, OPERATOR_TOKEN, EMAIL_CODE, NONCE, PASSWORD, RPC_PASSWORD,
  UNPREFIXED_APP_SECRET, API_KEY, VERIFICATION_CODE, RAW_KEY,
  RAW_KEY_BARE: RAW_KEY.slice(2),
  BASIC_CREDENTIAL: Buffer.from(`cmfakeappid:${PRIVY_APP_SECRET}`).toString("base64"),
};

function assertNoPlanted(output: string, where: string) {
  for (const [name, value] of Object.entries(PLANTED)) {
    assert.ok(!output.includes(value), `${name} leaked into ${where}`);
  }
}

/** A Privy-shaped HTTP client error: our request (with its Authorization header) and the response hang off it. */
function privyError(): Error {
  const err = new Error(`Request failed with status code 401 (token ${PRIVY_ACCESS_TOKEN})`) as Error & Record<string, unknown>;
  err.code = "ERR_BAD_REQUEST";
  err.status = 401;
  err.config = {
    url: "https://auth.privy.io/api/v1/users",
    headers: {
      Authorization: `Basic ${PLANTED.BASIC_CREDENTIAL}`,
      "privy-app-id": "cmfakeappid",
      "privy-authorization-signature": PRIVY_SIGNATURE,
    },
    data: JSON.stringify({ secret: PRIVY_APP_SECRET }),
  };
  err.request = { _header: `POST /api/v1/users HTTP/1.1\r\nAuthorization: Basic ${PLANTED.BASIC_CREDENTIAL}` };
  err.response = { status: 401, headers: { "set-cookie": `privy-token=${PRIVY_ACCESS_TOKEN}` }, data: { error: "invalid" } };
  err.headers = { "privy-id-token": PRIVY_ID_TOKEN };
  err.body = { refreshToken: REFRESH_TOKEN, authorizationKey: PRIVY_AUTH_KEY };
  return err;
}

process.env.NODE_ENV = "production"; // the logger module then skips pino-pretty
const { default: pino } = await import("pino");
const { default: pinoHttp } = await import("pino-http");
const { loggerOptions, httpLogSerializers, withScrubbedChildBindings } = await import("./logger");

function captureLogger() {
  const lines: string[] = [];
  const log = withScrubbedChildBindings(pino(loggerOptions, { write: (s: string) => void lines.push(s) }));
  return { log, lines };
}

test("an error carrying a Privy request and response logs without any of its secrets", () => {
  const { log, lines } = captureLogger();
  log.error({ err: privyError(), userId: "u-1" }, "privy call failed");
  log.warn({ cause: privyError() }, "an error under another key");
  log.error(privyError());
  const out = lines.join("");
  assertNoPlanted(out, "the error log lines");
  for (const gone of ["auth.privy.io", "privy-authorization-signature", "set-cookie", "_header"]) {
    assert.ok(!out.includes(gone), `${gone} is dropped with the request and response`);
  }
  const first = JSON.parse(lines[0]);
  assert.equal(first.err.code, "ERR_BAD_REQUEST", "the error code is kept");
  assert.equal(first.err.status, 401);
  assert.match(first.err.message, /^Request failed with status code 401/);
  assert.equal(first.userId, "u-1");
});

test("secret fields, headers and strings in any log object are redacted", () => {
  const { log, lines } = captureLogger();
  log.warn(
    {
      headers: {
        authorization: `Bearer ${PRIVY_ACCESS_TOKEN}`,
        cookie: `moolahub_session=${SESSION_TOKEN}`,
        "set-cookie": [`moolahub_session=${SESSION_TOKEN}`],
        "x-session-token": SESSION_TOKEN,
        "x-operator-token": OPERATOR_TOKEN,
        "privy-token": PRIVY_ACCESS_TOKEN,
        "privy-id-token": PRIVY_ID_TOKEN,
        "privy-app-id": "cmfakeappid",
      },
      body: { email: "ama@example.test", code: EMAIL_CODE, password: PASSWORD, nonce: NONCE, signature: PRIVY_SIGNATURE },
      tokens: [{ refreshToken: REFRESH_TOKEN, idToken: PRIVY_ID_TOKEN }],
      rpc: `https://user:${RPC_PASSWORD}@rpc.example.test/v1`,
      note: `privy said ${PRIVY_APP_SECRET} and ${PRIVY_AUTH_KEY}`,
      rowId: "row-7",
    },
    "request details",
  );
  const out = lines.join("");
  assertNoPlanted(out, "the log line");
  const line = JSON.parse(out);
  assert.equal(line.rowId, "row-7", "ordinary fields are kept");
  assert.equal(line.headers["privy-app-id"], "[Redacted]", "any privy-* header is redacted");
  assert.equal(line.body.email, "ama@example.test");
  assert.equal(line.msg, "request details");
});

test("hand-logged requests and responses, compound key names, child bindings, class instances and %o arguments are redacted", () => {
  const { log, lines } = captureLogger();
  log.warn({ req: { body: { password: PASSWORD, emailCode: EMAIL_CODE } } }, "a request body logged by hand");
  log.warn({ res: { data: { refreshToken: REFRESH_TOKEN } } }, "a response logged by hand");
  log.warn(
    {
      body: {
        emailCode: EMAIL_CODE,
        verification_code: VERIFICATION_CODE,
        authorizationKey: PRIVY_AUTH_KEY,
        "x-api-key": API_KEY,
        jwt: PRIVY_ID_TOKEN,
        session: SESSION_TOKEN,
        smsOtp: VERIFICATION_CODE,
        user_pin: VERIFICATION_CODE,
      },
      statusCode: 502,
      countryCode: "GH",
      sessionId: "s-1",
      referralCode: "AMA2026",
    },
    "compound names",
  );
  log.child({ token: SESSION_TOKEN, requestId: "r-1" }).info("a child logger");
  class FakePrivyClient {
    appId = "cmfakeappid";
    appSecret = UNPREFIXED_APP_SECRET;
  }
  log.info({ client: new FakePrivyClient() }, "a class instance");
  log.info("details %o", { password: PASSWORD, nested: { apiKey: API_KEY } });
  log.info("details %j", { token: SESSION_TOKEN });
  log.info(
    {
      note: `callback https://app.example.test/cb?state=${NONCE}&code=${EMAIL_CODE}&token=${SESSION_TOKEN}`,
      leaked: `key ${RAW_KEY} and ${RAW_KEY.slice(2)}`,
    },
    "secret strings",
  );
  const out = lines.join("");
  assertNoPlanted(out, "the log lines");
  const [reqLine, resLine, compound, child, instance] = lines.map((l) => JSON.parse(l));
  assert.deepEqual(reqLine.req, {}, "a hand-logged req keeps only the request line fields, none of which it has");
  assert.deepEqual(resLine.res, {}, "a hand-logged res keeps only its status code, which it has not");
  assert.equal(compound.statusCode, 502);
  assert.equal(compound.countryCode, "GH");
  assert.equal(compound.sessionId, "s-1");
  assert.equal(compound.referralCode, "AMA2026");
  assert.equal(child.requestId, "r-1", "ordinary child fields are kept");
  assert.equal(instance.client.appId, "cmfakeappid");
});

test("request log lines never carry headers, and dev query strings lose secret parameters", async () => {
  const { log, lines } = captureLogger();
  const httpLog = pinoHttp({ logger: log, serializers: httpLogSerializers });
  const { createServer } = await import("node:http");
  const server = createServer((req, res) => {
    httpLog(req, res);
    (res as typeof res & { err?: Error }).err = privyError();
    res.statusCode = 500;
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as { port: number };
  process.env.NODE_ENV = "development";
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/auth/session?code=${EMAIL_CODE}&token=${SESSION_TOKEN}&state=${NONCE}&limit=5`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${PRIVY_ACCESS_TOKEN}`,
        cookie: `moolahub_session=${SESSION_TOKEN}`,
        "x-session-token": SESSION_TOKEN,
        "privy-id-token": PRIVY_ID_TOKEN,
        "x-mh-test-run": "run-9",
      },
    });
    assert.equal(res.status, 500);
    await res.arrayBuffer();
    for (let i = 0; i < 50 && lines.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
  } finally {
    process.env.NODE_ENV = "production";
    server.close();
  }
  const out = lines.join("");
  assert.ok(out.length > 0, "the request was logged");
  assertNoPlanted(out, "the request log line");
  const line = JSON.parse(lines[0]);
  assert.deepEqual(Object.keys(line.req), ["id", "method", "url", "testRun", "query"]);
  assert.equal(line.req.url, "/api/auth/session");
  assert.equal(line.req.query, "code=[Redacted]&token=[Redacted]&state=[Redacted]&limit=5");
  assert.equal(line.err.code, "ERR_BAD_REQUEST");
});
