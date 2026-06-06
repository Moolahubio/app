# MoolaHub Application Security Review

**Scope:** `Moolahubio/app` — API server (Express 5) + frontend (React/Vite). (Smart contracts are covered separately in `docs/blockchain/SECURITY_AUDIT.md`.)
**Date:** June 2026
**Method:** Manual code review of middleware, auth/session, every API route, error handling, secret handling, and frontend network/secret exposure; mapped to OWASP Top 10 (2021).

---

## 1. Posture summary

**Strong already (no change needed):**
- **Injection (A03):** all DB access goes through Drizzle ORM with parameterized queries — no string-built SQL, no SQL injection surface.
- **Secrets:** no `.env` or key files committed; `.gitignore` covers env files; **no hardcoded keys/secrets in code**; the frontend exposes only the **public** `VITE_PRIVY_APP_ID` and `VITE_BASE_NETWORK` (both safe to ship). No API keys reach the client or network calls.
- **AuthN (A07):** identity is derived strictly from a **server-verified Privy token (DID)** + profile fetched server-side; client-supplied email/name are not trusted for account linking. Login failures return a generic "Invalid Privy token."
- **Access control (A01):** every route is behind `requireAuth`; lib functions scope all reads/writes by the session `userId` (and circle membership), and there are dedicated authz e2e tests (`circles-http-authz`, `circles-invite-authz`). Operator routes use a constant-time token compare and fail closed (503) when unset.
- **Session/crypto (A02):** session cookies are `httpOnly` + `secure` (prod) + `sameSite=lax`; tokens are 32 random bytes; private keys at rest use AES-256-GCM.

---

## 2. Findings & fixes (all fixed in this change set)

| ID | Severity | OWASP | Issue | Fix |
|----|----------|-------|-------|-----|
| H-1 | High | A05 | **CORS reflected any origin with credentials** (`cors({ origin: true, credentials: true })`) — any website could make credentialed cross-origin calls. | Allowlist via `ALLOWED_ORIGINS`; no-Origin (same-origin/server) allowed; arbitrary origins get no CORS headers. |
| M-1 | Medium | A05 | **No security headers** (no `helmet`) — missing HSTS, X-Content-Type-Options, frameguard, CSP, etc.; `X-Powered-By` exposed. | Added `helmet()` and `app.disable('x-powered-by')`. |
| M-2 | Medium | A09/A05 | **Error-message leakage** — routes returned raw `e.message` and Zod `error.message` to clients, exposing internal/DB/validation detail. | Introduced `AppError` (user-safe) + `sendError` choke point: AppError → its message; everything else → logged server-side, generic message to client. Zod parse errors → generic "Invalid request". Applied across **all** routes (circles, goals, wallet, auth, passkeys, profile, learn, notifications). |
| M-3 | Medium | A05 | **No global error handler** — an unhandled error could surface a stack/500 body. | Added a terminal error middleware: logs full error, returns `{ error: "Internal server error" }`, never a stack. Plus a JSON 404 handler. |
| M-4 | Medium | A07 | **No rate limiting** — auth and API endpoints open to brute force / abuse. | `express-rate-limit`: 300/15 min per IP on `/api`, 20/15 min on `/api/auth`. |
| L-1 | Low | A05 | No request body size limit; proxy not trusted (breaks `secure` cookies / real client IP behind Replit). | `express.json/urlencoded({ limit: "1mb" })`; `app.set('trust proxy', 1)`. |

### The error-handling principle applied
- **Bad (removed):** returning `e.message` / `SELECT ... failed` / Zod schema text to the client.
- **Good (now):** full error logged server-side via `pino`; the client sees a safe `AppError` message (e.g., "Insufficient balance") or a generic fallback ("Could not create circle", "Invalid request", "Internal server error"). No stack traces, table/column names, or query logic ever leave the server.

---

## 3. Required configuration (set these in prod env)
- `ALLOWED_ORIGINS` — comma-separated list of your frontend origin(s), e.g. `https://moolahub.io,https://app.moolahub.io`. Without it, only same-origin requests work.
- `NODE_ENV=production` — required for `secure` cookies and to keep framework error verbosity off.
- Ensure TLS in front of the app (HSTS from helmet only applies over HTTPS).

---

## 4. Recommendations (not blocking; prioritized)
1. **Startup env validation** — fail fast if `DATABASE_URL`, `APP_ENCRYPTION_KEY`, `PRIVY_APP_ID/SECRET` are missing (today only `PORT` is checked).
2. **Dependency scanning in CI** — add `pnpm audit` / Dependabot / Socket to catch vulnerable packages (complements the existing `minimumReleaseAge` supply-chain guard).
3. **Session hardening** — 30-day sessions are long for a financial app; consider 7 days + rotation on privilege change, and server-side revoke-all on logout from all devices.
4. **Audit logging** — log sensitive actions (withdrawals, operator console reads, circle payouts) with actor + outcome for forensics.
5. **Account-abuse defenses** — consider a CAPTCHA or progressive backoff on repeated auth failures (rate limiting covers the basics).
6. **Mainnet key management** — move `PLATFORM_PRIVATE_KEY`/deployer to a KMS/HSM and owner roles to a multisig+timelock (also noted in the contract audit).
7. **CSP tuning** — if the API also serves the frontend, define an explicit `helmet.contentSecurityPolicy`; for an API-only origin the defaults are fine.

---

## 5. Files changed
- `artifacts/api-server/src/app.ts` — helmet, CORS allowlist, rate limiting, body limits, trust proxy, 404 + global error handler.
- `artifacts/api-server/src/lib/errors.ts` — **new**: `AppError` + `sendError`.
- `artifacts/api-server/src/lib/{goals,circles,deposits}.ts` — validation throws → `AppError`.
- `artifacts/api-server/src/routes/{circles,goals,wallet,auth,passkeys,profile,learn,notifications}.ts` — use `sendError` / generic validation responses.
- `artifacts/api-server/package.json` — add `helmet`, `express-rate-limit`.
