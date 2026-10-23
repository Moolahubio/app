// Sentry for the web app (spec §8). Imported first by main.tsx. With no
// VITE_SENTRY_DSN at build time nothing is initialised and nothing is sent.
// Session Replay is deliberately not included: it records the screen, and on a
// money app that means balances and personal details.
import * as Sentry from "@sentry/react";
// The API's allowlist scrubber, shared so both apps send exactly the same shape.
import { scrubBreadcrumb, scrubEvent, scrubSpan } from "../../../api-server/src/lib/sentryScrub";

function sampleRate(raw: unknown): number {
  const n = Number(raw ?? "0");
  return Number.isFinite(n) && n >= 0 && n <= 1 ? n : 0;
}

const dsn = import.meta.env.VITE_SENTRY_DSN as string | undefined;
const tracesSampleRate = sampleRate(import.meta.env.VITE_SENTRY_TRACES_SAMPLE_RATE);

if (dsn) {
  Sentry.init({
    dsn,
    environment: (import.meta.env.VITE_SENTRY_ENVIRONMENT as string | undefined) ?? "development",
    // The build plugin injects the release when source maps are uploaded.
    integrations: tracesSampleRate > 0 ? [Sentry.browserTracingIntegration()] : [],
    tracesSampleRate,
    // SDK v11 collects user info, cookies, headers, bodies and query params by
    // default. None of it leaves the browser.
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: false,
      stackFrameVariables: false,
      genAI: { inputs: false, outputs: false },
      graphQL: { document: false, variables: false },
    },
    denyUrls: [/^(chrome|moz|safari-web)-extension:\/\//],
    beforeSend: scrubEvent,
    beforeBreadcrumb: scrubBreadcrumb,
    beforeSendSpan: scrubSpan,
  });
}
