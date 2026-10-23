// Must stay the first import so errors during startup are reported.
import "./lib/sentry";
import * as Sentry from "@sentry/react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./index.css";

// Shown if rendering crashes. Kept outside the app's providers (they may be
// what failed), so it is plain markup with no translations or hooks.
function CrashScreen() {
  return (
    <div role="alert" className="flex min-h-screen flex-col items-center justify-center gap-4 p-6 text-center">
      <p>Something went wrong. Reload the page to try again.</p>
      <button
        type="button"
        className="rounded-md border px-4 py-2"
        onClick={() => window.location.reload()}
      >
        Reload
      </button>
    </div>
  );
}

// React 19 root hooks report uncaught and recoverable errors (caught ones are
// reported by the ErrorBoundary below). They replace React's own console
// logging, so the handler logs too, and they are only set when Sentry is on.
const reportError = Sentry.reactErrorHandler((error) => console.error(error));
const rootOptions = Sentry.getClient()
  ? { onUncaughtError: reportError, onRecoverableError: reportError }
  : undefined;

createRoot(document.getElementById("root")!, rootOptions).render(
  <Sentry.ErrorBoundary fallback={<CrashScreen />}>
    <App />
  </Sentry.ErrorBoundary>,
);
