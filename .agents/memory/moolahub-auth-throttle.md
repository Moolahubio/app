---
name: MoolaHub auth throttle layering
description: How per-IP/email auth throttles layer under the global express limiter, and the e2e testing gotcha that follows.
---

# Auth throttle layering

Auth endpoints have TWO throttle layers:

1. A coarse global `express-rate-limit` on `/api/auth` (in `app.ts`): ~20 requests
   per IP per 15 min, shared across ALL auth endpoints. Its 429 body is
   express-rate-limit's **plain text** ("Too many requests…"), NOT JSON `{error}`.
2. Targeted in-process throttles per endpoint (`loginThrottle.ts`,
   `resetThrottle.ts`) keyed by IP and/or email, with their own JSON `{error}` 429.

**Why it matters:** targeted budgets must sit BELOW the global 20/IP cap or the
global limiter trips first and you never reach the targeted logic. forgot-password
caps (per-IP 6, per-email 4) and reset-password (per-IP 10) are all under 20.

**E2e testing gotcha (cost >2 attempts):** an in-process HTTP e2e test makes all
its requests from one IP (127.0.0.1) and shares the global 20-request budget
across every auth call in that process. So a later step can receive the global
limiter's **plain-text** 429 instead of the targeted throttle's JSON 429. A
throttle test that asserts `body.error` is a string will spuriously fail. Assert
on the 429 status + a generic non-empty message that accepts either body shape,
and rely on earlier steps (which run before the global budget is exhausted) to
prove the targeted JSON throttle specifically.

**How to apply:** when adding a new per-IP/email auth throttle, keep its budget
under the global cap, and write throttle e2e tests tolerant of the global
limiter possibly firing first.
