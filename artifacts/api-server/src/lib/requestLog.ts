/**
 * The `req` fields of a request log line (pino-http's `req` serializer). No
 * imports, so it is unit-tested without a database.
 *
 * Always the request id, method and path, with the query string cut off. Outside
 * production only, a request that an iOS UI test marked with `X-MH-Test-Run`
 * (Debug builds only) also logs that run id and its query string, so the test
 * can count its own requests on a dev backend every simulator shares. Production
 * output is unchanged, and nothing else reads the header.
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
  fields.query = q === -1 ? "" : url.slice(q + 1);
  return fields;
}
