/**
 * Sentry scrubbing test (spec §8, A5). Runs the API's real Sentry config
 * (src/instrument.ts) against a capture transport and asserts that no secret,
 * token, email, address or amount reaches the wire, whatever path it took:
 * error messages, drizzle query dumps, request data, extras, contexts, tags,
 * user fields, breadcrumbs, span names and span attributes. Also proves the
 * no-DSN case: without SENTRY_DSN there is no client and nothing to send.
 *
 * Offline, no database. Run: pnpm --filter @workspace/api-server test:sentry-scrub
 */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import type { Request } from "express";

delete process.env.SENTRY_DSN;
process.env.SENTRY_TRACES_SAMPLE_RATE = "1";

const Sentry = await import("@sentry/node");
const { sentryOptions } = await import("../instrument");
const { captureServerError, captureDeadLetter, heartbeat } = await import("./observability");
const { scrubString } = await import("./sentryScrub");

// ---- no DSN: instrument.ts must not create a client ----
assert.equal(Sentry.getClient(), undefined, "no SENTRY_DSN means no Sentry client");
captureServerError(new Error("ignored")); // a no-op, must not throw

// ---- the secrets ----
// The token, JWT and Privy key fakes are built at runtime, so they never sit
// in this public source as credential-shaped literals.
const b64url = (s: string) => Buffer.from(s).toString("base64url");
const fakeJwt = (sub: string, sig: string) =>
  [JSON.stringify({ alg: "ES256" }), JSON.stringify({ sub }), sig].map(b64url).join(".");

const USER_ID = "3b241101-e2bb-4255-8caf-4136c566a962";
const SESSION_TOKEN = createHash("sha256").update("test").digest("hex");
const RPC_KEY = "Zx81kQp0LmN2bV7cX4sR9tY6uW3eA5dF";
const PRIVY_JWT = fakeJwt("did:privy:abc", "signature-value");
const PRIVY_SIGNATURE = "MEUCIQDx3bZpLr0H5a2f8W1kJ9yQp7nVt4sR6oG2mXc8eYdAiB3";
const EMAIL = "ama.mensah@example.com";
const ADDRESS = "0x742d35Cc6634C0532925a3b844Bc454e4438f44e";
const TX_HASH = "0x5c504ed432cb51138bcf09aa5e8a410dd4a1e204ef84bfed1be16dfba1b22060";
const PASSWORD = "hunter2-Correct-Horse";
const AMOUNT_DISPLAY = "9,876,543.21";
const AMOUNT_DOLLARS = "4,321.09";
const AMOUNT_CENTS = "987654321";
const OTP = "481516";
const REFRESH_TOKEN = "rt_" + b64url("SentryFakeRefreshToken0000001");
const PRIVY_ID_TOKEN = fakeJwt("did:privy:identity", "id-token-signature");
const PRIVY_APP_SECRET = "privy_app_secret_" + "FakeSentryTestValue" + "0".repeat(9);
const PRIVY_AUTH_KEY = "wallet-auth:" + b64url("FakeSentryAuthorizationKey00");
const NONCE = "SentryFakeNonce42";
const EMAIL_CODE = "735911";
const BASIC_CREDENTIAL = Buffer.from(`cmfakeappid:${PRIVY_APP_SECRET}`).toString("base64");

// The fakes must keep the real formats, or the test stops exercising the real masks.
assert.match(SESSION_TOKEN, /^[0-9a-f]{64}$/);
for (const t of [PRIVY_JWT, PRIVY_ID_TOKEN]) assert.match(t, /^eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+$/);
assert.match(PRIVY_APP_SECRET, /^privy_app_secret_[A-Za-z0-9]{16,}$/);
assert.match(PRIVY_AUTH_KEY, /^wallet-auth:[A-Za-z0-9+/]{16,}={0,2}$/);

const SECRETS: Record<string, string> = {
  SESSION_TOKEN, RPC_KEY, PRIVY_JWT, PRIVY_SIGNATURE, EMAIL, ADDRESS, TX_HASH, PASSWORD,
  AMOUNT_DISPLAY, AMOUNT_DOLLARS, AMOUNT_CENTS, OTP,
  REFRESH_TOKEN, PRIVY_ID_TOKEN, PRIVY_APP_SECRET, PRIVY_AUTH_KEY, NONCE, EMAIL_CODE, BASIC_CREDENTIAL,
  ADDRESS_BODY: ADDRESS.slice(2), TX_HASH_BODY: TX_HASH.slice(2),
};

// ---- a real client with the production options and a capture transport ----
const envelopes: unknown[] = [];
Sentry.init({
  ...sentryOptions("https://publickey@o0.ingest.sentry.io/1", { SENTRY_TRACES_SAMPLE_RATE: "1" }),
  transport: () => ({
    send: async (envelope: unknown) => {
      envelopes.push(envelope);
      return { statusCode: 200 };
    },
    flush: async () => true,
  }),
});
assert.ok(Sentry.getClient(), "client created for the test");

// Simulate everything a misconfigured integration or careless caller could
// attach. These run before beforeSend, so the scrubber has to remove them.
Sentry.addEventProcessor((event) => {
  event.request = {
    method: "POST",
    url: `https://app.moolahub.test/api/wallet/withdraw?token=${SESSION_TOKEN}&email=${EMAIL}`,
    headers: {
      authorization: `Bearer ${PRIVY_JWT}`,
      "privy-authorization-signature": PRIVY_SIGNATURE,
      cookie: `moolahub_session=${SESSION_TOKEN}`,
      "set-cookie": `moolahub_session=${SESSION_TOKEN}`,
      "x-session-token": SESSION_TOKEN,
      "privy-token": PRIVY_JWT,
      "privy-id-token": PRIVY_ID_TOKEN,
    },
    cookies: { moolahub_session: SESSION_TOKEN },
    data: {
      password: PASSWORD, amountCents: Number(AMOUNT_CENTS), destination: ADDRESS, otp: OTP,
      code: EMAIL_CODE, refreshToken: REFRESH_TOKEN, nonce: NONCE,
    },
    query_string: `token=${SESSION_TOKEN}`,
  };
  event.user = { ...(event.user ?? {}), email: EMAIL, ip_address: "203.0.113.7", username: "ama" };
  event.extra = { password: PASSWORD, body: { amountCents: AMOUNT_CENTS } };
  event.contexts = {
    ...event.contexts,
    privyRequest: {
      headers: { authorization: `Basic ${BASIC_CREDENTIAL}`, "privy-id-token": PRIVY_ID_TOKEN },
      url: `https://api.privy.io/v1/wallets?x=${RPC_KEY}`,
    },
  };
  event.tags = { ...event.tags, email: EMAIL, session: SESSION_TOKEN };
  return event;
});

// 1. An unexpected error on a money route, through the API's capture path.
const fakeReq = {
  method: "POST",
  baseUrl: "/api/wallet",
  route: { path: "/withdraw" },
  originalUrl: `/api/wallet/withdraw?token=${SESSION_TOKEN}`,
  url: "/withdraw",
  user: { id: USER_ID, email: EMAIL },
} as unknown as Request;
Sentry.addBreadcrumb({
  category: "http",
  type: "http",
  message: `POST https://base-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
  data: {
    method: "POST",
    url: `https://base-mainnet.g.alchemy.com/v2/${RPC_KEY}?apikey=${RPC_KEY}`,
    status_code: 500,
    "http.query": `apikey=${RPC_KEY}`,
    request_body: { to: ADDRESS, value: AMOUNT_CENTS },
    headers: { authorization: `Bearer ${PRIVY_JWT}`, "x-session-token": SESSION_TOKEN },
  },
});
Sentry.addBreadcrumb({ category: "console", level: "error", message: `withdraw ${AMOUNT_DISPLAY} USDC to ${ADDRESS} for ${EMAIL}` });
captureServerError(
  new Error(
    `Failed query: insert into "transactions" ("user_id","tx_hash") values ($1, $2)\nparams: ${USER_ID},${TX_HASH},${EMAIL},${AMOUNT_CENTS}`,
  ),
  { req: fakeReq },
);

// 2. A message with money and identity in it.
Sentry.captureMessage(`refund of $${AMOUNT_DOLLARS} and ${AMOUNT_DISPLAY} USDC to ${ADDRESS} (${EMAIL}), session ${SESSION_TOKEN}, otp=${OTP}`);

// 2b. A failed sign-in: the challenge message, a refresh token, an email code
// and a Privy client error that quotes our app secret and an authorization key.
Sentry.captureMessage(
  `sign-in failed for "Moolahub sign-in · purpose:signin · nonce:${NONCE} · device:dev-1 · chain:8453", ` +
    `refreshToken=${REFRESH_TOKEN} code: ${EMAIL_CODE} idToken=${PRIVY_ID_TOKEN}`,
);
captureServerError(new Error(`privy request failed: Basic ${BASIC_CREDENTIAL} ${PRIVY_APP_SECRET} ${PRIVY_AUTH_KEY}`), {
  req: fakeReq,
});

// 3. The dead-letter event, with an address and a tx hash in its reason.
captureDeadLetter({ id: USER_ID, kind: "withdrawal", attempts: 5 }, `transfer ${TX_HASH} to ${ADDRESS} reverted; amountCents=${AMOUNT_CENTS}`);

// 4. A span carrying a statement, headers and a query string.
Sentry.startSpan(
  {
    name: `GET /api/goals/${USER_ID}/release`,
    op: "http.server",
    attributes: {
      "db.statement": `select * from users where email = '${EMAIL}'`,
      "db.query.text": `update users set password_hash = '${PASSWORD}'`,
      "http.request.header.authorization": `Bearer ${PRIVY_JWT}`,
      "url.full": `https://app.moolahub.test/api/goals?token=${SESSION_TOKEN}`,
      "url.query": `token=${SESSION_TOKEN}`,
      "user.email": EMAIL,
      "http.response.status_code": 500,
      "http.request.method": "GET",
    },
  },
  () => {
    Sentry.startSpan({ name: `POST https://base-mainnet.g.alchemy.com/v2/${RPC_KEY}`, op: "http.client" }, () => {});
  },
);

// 5. A cron heartbeat from a background loop.
heartbeat("scrub-test-loop", 5, true);

await Sentry.flush(2_000);
await Sentry.close(2_000);

// ---- assertions ----
const wire = JSON.stringify(envelopes);
assert.ok(envelopes.length >= 3, `expected error, message and span envelopes, got ${envelopes.length}`);
for (const [name, secret] of Object.entries(SECRETS)) {
  assert.ok(!wire.includes(secret), `${name} leaked into a Sentry envelope`);
  assert.ok(!wire.toLowerCase().includes(secret.toLowerCase()), `${name} leaked (case-folded)`);
}
for (const banned of [
  "203.0.113.7", "moolahub_session", "privy-authorization-signature", "x-session-token", "privy-token",
  "privy-id-token", "set-cookie", "db.statement", "db.query.text", "password", "\"cookies\"", "\"headers\"",
  "\"query_string\"", "\"extra\"",
]) {
  assert.ok(!wire.includes(banned), `"${banned}" should never reach Sentry`);
}

// What must survive, so the events are still useful.
assert.ok(wire.includes(USER_ID), "the user's internal UUID is kept");
assert.ok(wire.includes("\"area\":\"money\""), "money routes are tagged area:money");
assert.ok(wire.includes("POST /api/wallet/withdraw"), "the route pattern tag is kept");
assert.ok(wire.includes("settlement.dead_letter withdrawal"), "the dead-letter event is sent");
assert.ok(wire.includes("GET /api/goals/:id/release"), "span names keep the route, lose the id");
assert.ok(wire.includes("Failed query: insert into"), "the failing statement shape is kept");
assert.ok(wire.includes("/api/wallet/withdraw"), "request path is kept without its query");
assert.ok(wire.includes("\"check_in\"") && wire.includes("scrub-test-loop"), "heartbeats send a cron check-in");

// Unit checks on the string masks.
assert.equal(scrubString(`to ${ADDRESS}`), "to [hex]");
assert.equal(scrubString(`user ${USER_ID}`), `user ${USER_ID}`, "UUIDs are not tokens");
assert.equal(scrubString("idle_in_transaction_session_timeout"), "idle_in_transaction_session_timeout", "long words without digits survive");
assert.equal(scrubString(`${AMOUNT_DISPLAY} USDC`), "[amount]");
assert.equal(scrubString(`refreshToken=${REFRESH_TOKEN}`), "refreshToken=[Filtered]");
assert.equal(scrubString(`x-session-token: ${SESSION_TOKEN}`), "x-session-token: [Filtered]");
assert.equal(scrubString(`nonce:${NONCE} · chain:8453`), "nonce:[Filtered] · chain:8453");
assert.equal(scrubString(`code: ${EMAIL_CODE}`), "code: [Filtered]");
assert.equal(scrubString(`secret ${PRIVY_APP_SECRET} key ${PRIVY_AUTH_KEY}`), "secret [Filtered] key [Filtered]");

console.log(`✅ sentryScrub.test passed: ${envelopes.length} envelopes, no secret, token, email, address or amount on the wire`);
process.exit(0);
