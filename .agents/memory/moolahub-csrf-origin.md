---
name: MoolaHub CSRF/CORS origin allowlisting
description: Why production POST auth endpoints 403'd and how the origin allowlist must be derived (REPLIT_DOMAINS + same-origin, not just ALLOWED_ORIGINS).
---

# CSRF/CORS origin allowlisting

The CSRF guard on session-establishing POST endpoints and the CORS middleware
must derive allowed origins from `lib/origins.ts` (`getAllowedOrigins` =
`ALLOWED_ORIGINS` ∪ `REPLIT_DOMAINS`, bare hosts normalized to `https://`).
The guard 403s only when an `Origin` header is present AND the request is not
same-origin AND the origin is not allowlisted. Same-origin is checked against
`x-forwarded-host` + `x-forwarded-proto` (Replit proxy), comparing scheme+host.

**Why:** `ALLOWED_ORIGINS` is UNSET in production. Browsers always send `Origin`
on POSTs (even same-origin), so an allowlist that only reads `ALLOWED_ORIGINS`
403s every POST auth endpoint (register/login/verify/...) in prod while GETs
(no Origin) still work. In prod the API serves the frontend at the same origin,
so a same-origin check + `REPLIT_DOMAINS` makes the guard zero-config-correct.

**How to apply:** Never gate prod browser POSTs on `ALLOWED_ORIGINS` alone. Keep
the CSRF guard and CORS reading the same `lib/origins.ts` so they can't drift.
The 415 JSON content-type check is the primary anti-form-CSRF control and stays.
