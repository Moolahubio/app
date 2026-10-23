// Sentry for the API (spec §8). Imported first by src/index.ts so the SDK is
// set up before Express, pg and the rest load. With no SENTRY_DSN nothing is
// initialised: no client, no instrumentation overhead, no traffic.
import * as Sentry from "@sentry/node";
import { scrubBreadcrumb, scrubEvent, scrubSpan } from "./lib/sentryScrub";

type NodeOptions = NonNullable<Parameters<typeof Sentry.init>[0]>;

// SDK v11 collects user info, cookies, headers, bodies, query params and DB
// query data by default. A money app sends none of it: every category is off,
// and lib/sentryScrub.ts allowlists whatever is left.
export const DATA_COLLECTION = {
  userInfo: false,
  cookies: false,
  httpHeaders: false,
  httpBodies: [],
  urlQueryParams: false,
  databaseQueryData: false,
  queues: false,
  stackFrameVariables: false,
  frameContextLines: 0,
  genAI: { inputs: false, outputs: false },
  graphQL: { document: false, variables: false },
} satisfies NodeOptions["dataCollection"];

function sampleRate(raw: string | undefined): number {
  const n = Number(raw ?? "0");
  return Number.isFinite(n) && n >= 0 && n <= 1 ? n : 0;
}

/** The API's Sentry options. Shared with the scrub test so it checks the real config. */
export function sentryOptions(dsn: string, env: NodeJS.ProcessEnv = process.env): NodeOptions {
  return {
    dsn,
    environment: env.SENTRY_ENVIRONMENT ?? "development",
    release: env.SENTRY_RELEASE || undefined,
    tracesSampleRate: sampleRate(env.SENTRY_TRACES_SAMPLE_RATE),
    dataCollection: DATA_COLLECTION,
    integrations: [
      // We capture explicitly (global handler + sendError), 5xx only, so
      // expected 4xx never page anyone and nothing is captured twice.
      Sentry.expressIntegration({ shouldHandleError: false }),
      // Keep Node's default: an unhandled rejection still crashes the process,
      // whether or not a DSN is set (the SDK default would only warn).
      Sentry.onUnhandledRejectionIntegration({ mode: "strict" }),
    ],
    beforeSend: scrubEvent,
    beforeBreadcrumb: scrubBreadcrumb,
    beforeSendSpan: scrubSpan,
  };
}

const dsn = process.env.SENTRY_DSN;
if (dsn) Sentry.init(sentryOptions(dsn));
