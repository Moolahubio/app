/**
 * Unit tests for the request log fields (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/requestLog.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
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
