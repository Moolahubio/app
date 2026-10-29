/**
 * Unit tests for the circles flag (no DB). circles-http.e2e.ts proves the same
 * over HTTP against a real database.
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/circlesFlag.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import type { NextFunction, Request, Response } from "express";
import { circlesEnabled, requireCirclesEnabled } from "./circlesFlag";

function run(method: string, flag: string | undefined, path = "/") {
  const saved = process.env.CIRCLES_ENABLED;
  if (flag === undefined) delete process.env.CIRCLES_ENABLED;
  else process.env.CIRCLES_ENABLED = flag;
  const out: { next: boolean; status?: number; body?: unknown } = { next: false };
  const res = {
    status(code: number) {
      out.status = code;
      return this;
    },
    json(body: unknown) {
      out.body = body;
      return this;
    },
  } as unknown as Response;
  try {
    requireCirclesEnabled({ method, path } as Request, res, (() => void (out.next = true)) as NextFunction);
  } finally {
    if (saved === undefined) delete process.env.CIRCLES_ENABLED;
    else process.env.CIRCLES_ENABLED = saved;
  }
  return out;
}

test("only the exact value true turns circles on", () => {
  assert.equal(circlesEnabled({}), false, "unset is off");
  for (const off of ["false", "", "0", "1", "TRUE", "True", "yes", " true"]) {
    assert.equal(circlesEnabled({ CIRCLES_ENABLED: off }), false, `${JSON.stringify(off)} is off`);
  }
  assert.equal(circlesEnabled({ CIRCLES_ENABLED: "true" }), true);
});

// Paths as Express gives them to a middleware mounted on /circles.
const CHANGES = ["/", "/c-1/invite", "/c-1/start", "/c-1/delete", "/c-1/contribute", "/invites/i-1/accept", "/invites/i-1/decline"];

test("with circles off, every change is refused with 404", () => {
  for (const flag of [undefined, "false"]) {
    for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
      for (const path of CHANGES) {
        const r = run(method, flag, path);
        assert.equal(r.next, false, `${method} ${path} with CIRCLES_ENABLED=${flag} must not reach the route`);
        assert.equal(r.status, 404);
        assert.deepEqual(r.body, { error: "Not found" });
      }
    }
  }
});

test("with circles off, reads still reach the route", () => {
  for (const method of ["GET", "HEAD"]) {
    assert.equal(run(method, undefined).next, true, `${method} is allowed`);
  }
});

test("with circles off, confirming a contribution already sent on chain still reaches the route", () => {
  for (const path of ["/c-1/contribute/submitted", "/c-1/contribute/submitted/"]) {
    assert.equal(run("POST", undefined, path).next, true, `POST ${path} is allowed`);
  }
  for (const [method, path] of [["PUT", "/c-1/contribute/submitted"], ["POST", "/c-1/contribute/submitted/x"], ["POST", "/a/b/contribute/submitted"]]) {
    assert.equal(run(method, undefined, path).status, 404, `${method} ${path} is refused`);
  }
});

test("with circles on, every route is reached", () => {
  for (const method of ["GET", "POST", "PUT", "PATCH", "DELETE"]) {
    const r = run(method, "true");
    assert.equal(r.next, true, `${method} is allowed`);
    assert.equal(r.status, undefined);
  }
});
