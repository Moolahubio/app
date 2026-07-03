# Threat Model

## Project Overview

MoolaHub is a pnpm-monorepo financial application with an Express 5 API (`artifacts/api-server`), a React/Vite web client (`artifacts/moolahub-app`), shared OpenAPI/Zod/DB packages under `lib/`, and production Solidity contracts under `contracts/src`. Users authenticate primarily with email/password, with optional passkeys and TOTP 2FA; Privy is still present for legacy passwordless accounts and optional post-login linkage. Users can provision an in-app wallet, save into personal goals, participate in social savings circles, and settle some flows through live Monad/testnet-oriented on-chain integrations. PostgreSQL via Drizzle is the application source of truth for users, sessions, balances, and product state. For provisioned in-app wallets, the current production model is server-custodial in practice: the backend generates, stores, decrypts, and uses encrypted user signing keys for on-chain settlement.

This scan is production-scoped. `artifacts/mockup-sandbox`, e2e test files, contract build artifacts, and local-only tooling are dev-only unless a production code path explicitly reaches them. Assume `NODE_ENV=production` in production. Replit deployment TLS is platform-managed. The application is publicly reachable at `https://app.moolahub.io` and `https://moolahubapp.replit.app`, so internet-facing browser attacks are in scope. Because public Replit apps share the `replit.app` site, sibling-origin requests from another attacker-controlled `*.replit.app` deployment must be treated as same-site for cookie/CSRF analysis. Current Monad testnet and other non-mainnet on-chain configurations remain in scope when production code treats them as real user flows; a testnet asset is still security-relevant if the live application trusts it for ledger-backed balances. Base/Base Sepolia manifests are retained in-repo but are not the primary live production path for this scan unless a production code path still consumes them.

## Assets

- **User accounts and sessions** — session cookies, Privy identity links, passkeys, WebAuthn/TOTP challenges, and backup codes. Compromise allows impersonation and control over savings actions.
- **Wallet balances and ledger integrity** — ledger transactions, postings, on-chain settlement queue state, wallet addresses, and deposit/withdraw records. Integrity failures can mint spendable balance or misroute funds.
- **Goal and circle state** — membership, contributions, payout sequencing, invite state, and goal allocations. Unauthorized tampering impacts real user funds and obligations.
- **Custodied or encrypted signing material** — encrypted user private keys (where used), platform private key configuration, and TOTP secrets. Exposure would enable unauthorized blockchain actions or account takeover.
- **User PII and profile data** — names, email addresses, nationality, date of birth, avatars, notifications, and activity history.
- **Object storage content** — uploaded avatars, goal images, and circle images. Unsafe handling can become stored XSS, cross-user data exposure, or browser-side SSRF/tracking.
- **Operator-only observability data** — settlement overview and platform funding visibility behind the operator token.

## Trust Boundaries

- **Browser ↔ API** — the React client is untrusted; every API route must authenticate, authorize, and validate request data server-side.
- **Cross-site browser ↔ session-establishing auth routes** — public login/bootstrap endpoints still mutate authentication state and must be treated as CSRF-sensitive even when they do not require an existing session cookie.
- **API ↔ PostgreSQL** — the API can mutate authoritative balances, sessions, challenge state, and user data. Query correctness and transaction boundaries are critical.
- **API ↔ Object storage** — signed upload URLs and object serving cross into untrusted user-controlled file content.
- **API ↔ Blockchain / RPC** — on-chain reads and writes depend on external RPC and contract state. Ledger state must not become unsafe when chain operations fail or race.
- **Public ↔ Authenticated** — health and login bootstrapping are public; wallet, goals, circles, security, profile, storage, and on-chain config are authenticated.
- **Authenticated ↔ Operator** — `/api/operations/*` is a stronger boundary than normal user auth and must remain inaccessible to ordinary users.
- **Dev-only ↔ Production** — `artifacts/mockup-sandbox`, e2e tests, and contract build output are normally out of scope unless proven reachable from production entry points.

## Scan Anchors

- **Production entry points**: `artifacts/api-server/src/app.ts`, `artifacts/api-server/src/routes/*`, `artifacts/moolahub-app/src/main.tsx`, `contracts/src/*`.
- **Highest-risk code areas**: `artifacts/api-server/src/lib/auth.ts`, `routes/auth.ts`, `routes/passkeys.ts`, `routes/security.ts`, `lib/deposits.ts`, `lib/ledger.ts`, `lib/settlement.ts`, `lib/wallet.ts`, `routes/storage.ts`, `lib/objectStorage.ts`, `lib/circles.ts`, `lib/goals.ts`, `lib/email.ts`, `lib/crypto.ts`, `contracts/src/*`.
- **Public surfaces**: health, Privy login bootstrap, passkey login bootstrap.
- **Authenticated surfaces**: wallet, goals, circles, profile, notifications, storage objects, on-chain config, account management.
- **Operator-only surfaces**: `routes/operations.ts` guarded by `OPERATOR_TOKEN`.
- **Production-relevant testnet posture**: `artifacts/api-server/src/lib/chain.ts`, `routes/wallet.ts`, `routes/onchain.ts`, `contracts/deployments/monad-testnet.json`, `contracts/deployments/latest.json`, `contracts/deployments/base-sepolia.json`, and contract paths whose safety depends on payout sequencing, privileged roles, or test-token behavior.
- **Usually dev-only**: `artifacts/mockup-sandbox/**`, `artifacts/api-server/src/**/*.e2e.ts`, `contracts/out/**`, `contracts/cache/**`, `attached_assets/**`.

## Threat Categories

### Spoofing

The application relies on password verification, server-issued session cookies, WebAuthn ceremonies, optional TOTP challenges, and legacy/linked Privy identities. The API must derive identity only from verified auth artifacts, ensure session tokens are unpredictable and revocable, keep WebAuthn / 2FA challenges single-use with bounded lifetime, and require fresh proof of possession of an existing factor before enrolling or replacing any durable login factor (passkey, first password on a passwordless account, new 2FA, or linked Privy identity). Sensitive account-lifecycle actions such as deactivation and deletion should also require step-up proof rather than a session alone. Account lifecycle controls are part of this boundary: `deletedAt` must actually revoke future authentication rather than merely anonymize profile fields. Operator endpoints must require a separate secret and never inherit trust from ordinary user authentication.

### Tampering

Users can submit goal, circle, wallet, profile, and upload metadata from an untrusted client. The system must enforce all business rules server-side: only authorized users may mutate their own resources, circle/goals actions must respect membership and ownership, and uploads must be bound to vetted internal object paths before they become displayable. Authenticated state-changing routes that depend on the session cookie MUST also enforce same-origin / allowlisted-origin or JSON-only CSRF protections consistently, because the live `*.replit.app` alias creates same-site sibling-origin risk even when `SameSite=Lax` is set. Ledger-affecting operations must compose validation, reservations, and postings atomically so concurrency cannot create or destroy value, and goal/circle lifecycle transitions must revalidate mutable state inside the transaction that moves funds. On-chain settlement MUST remain idempotent across ambiguous RPC retries, lost responses, and crash recovery; local `pending` state alone is not enough evidence that a prior signed transfer never reached the chain.

### Information Disclosure

The API exposes account details, wallet balances, circle membership, notifications, activity, and uploaded media. Responses and object-serving routes must stay scoped to the requesting user or intended audience; raw uploads must not become a cross-user content-hosting channel; secrets, cookies, and tokens must not leak via logs, responses, or generated client code. Operator observability must not expose platform balance data to standard users. The product currently accepts limited account-state disclosure on `/auth/forgot-password` (404 vs 409 vs 200) as a deliberate UX tradeoff under throttling; future scans should only re-propose it if a code change materially amplifies that disclosure or removes the rate-limit assumptions.

### Denial of Service

Public auth bootstrapping and authenticated money-moving endpoints are attractive abuse targets. The system must rate-limit login-related routes, reject oversized uploads and request bodies, and avoid attacker-triggerable unbounded work such as repeated expensive chain sync or storage fetches that could starve service capacity.

### Elevation of Privilege

A compromised or malicious user must not be able to read or mutate another user’s private objects, goals, circle state, or ledger-backed funds. Missing ownership checks, weak operator controls, unsafe dynamic fetches of user-controlled resources, or race conditions in financial flows can all translate into privilege escalation. Contract and on-chain integration code must not introduce hidden admin paths that let the platform or another user redirect funds. Because the backend currently custodies encrypted per-user signing keys, compromise of app-server secrets or operator access is equivalent to compromise of every provisioned wallet; future scans should treat `lib/wallet.ts`, `lib/crypto.ts`, and `lib/settlement.ts` as one privileged signing boundary rather than assuming contracts alone enforce per-user ownership.
