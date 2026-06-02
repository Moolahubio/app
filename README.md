# MoolaHub — Web App (`app.moolahub.io`)

> **Save Now. Grow Together.**
> The MoolaHub product app: a non-custodial savings experience built on
> Stellar. Hit your goals, save with trusted Susu circles, learn as you go —
> and verify every contribution on-chain.

A real full-stack app — **Next.js (App Router) · TypeScript · Tailwind ·
Prisma · Stellar SDK**. Session auth, a double-entry money ledger, and real
on-chain (testnet) settlement.

## Quick start

The app uses **PostgreSQL**. Easiest path is Docker:

```bash
# 1) secrets
export APP_ENCRYPTION_KEY=$(openssl rand -hex 32)
export SESSION_SECRET=$(openssl rand -hex 32)

# 2) bring up Postgres + the app, then seed demo data
docker compose up --build -d
docker compose exec app npm run db:seed

# → http://localhost:3000
```

Or run it locally against your own Postgres:

```bash
npm install                 # also runs `prisma generate`
cp .env.example .env        # set DATABASE_URL + APP_ENCRYPTION_KEY + SESSION_SECRET
npm run db:migrate          # apply migrations (prod) — or `npm run db:push` for quick dev
npm run db:seed             # seed demo data
npm run dev                 # http://localhost:3000
```

**Demo login:** `ama@moolahub.io` / `moolahub`

## Scripts

| Script | What it does |
| --- | --- |
| `npm run dev` / `build` / `start` | Next.js dev / production build / serve |
| `npm run db:push` | Sync the Prisma schema to the database |
| `npm run db:seed` | Seed a realistic, ledger-consistent dataset |
| `npm run db:reset` | Force-reset + reseed |
| `npm run stellar:init` | Bootstrap the testnet USDC issuer/distributor (needs network) |

## Architecture

```
src/
├── app/
│   ├── (app)/              # authenticated product — served at the root (AppShell layout)
│   │   ├── page.tsx        #   dashboard
│   │   ├── wallet/         #   deposit / withdraw
│   │   ├── circles/ goals/ learn/ activity/ profile/
│   │   └── actions.ts      #   server actions (deposit, contribute, allocate, …)
│   ├── login/              # sign in / create account (+ auth server actions)
│   └── preview/            # proposed marketing landing (reference for moolahub.io)
├── components/             # brand, ui primitives, app shell, client forms
└── lib/
    ├── db.ts               # Prisma client
    ├── content/lessons.ts  # static lesson curriculum
    └── server/             # server-only domain layer
        ├── auth.ts         #   bcrypt + DB-backed sessions (Privy-ready seam)
        ├── crypto.ts       #   AES-256-GCM for secrets at rest
        ├── ledger.ts       #   double-entry ledger (balances are derived)
        ├── stellar.ts      #   real Stellar SDK integration (testnet)
        ├── wallet.ts       #   per-user Stellar wallet provisioning
        ├── deposits.ts circles.ts goals.ts reminders.ts learn.ts
prisma/schema.prisma        # data model (PostgreSQL) + prisma/migrations/
```

**Money** is always integer **cents** (1/100 USDC). Balances are never stored —
they're derived from a double-entry ledger (`LedgerAccount` + `Transaction` +
`Posting`), mirroring the on-chain record.

**Auth** is session-based (bcrypt + httpOnly cookies) behind a thin seam, so
swapping in **Privy** later only touches `lib/server/auth.ts`.

## On-chain (Stellar)

Keypair generation and transaction signing are real and run offline. **Funding
(friendbot) and submission (Horizon) require network egress** — where it's
unavailable the signed transaction is recorded with its real hash and queued
for broadcast (`onchainStatus: "queued"`). To go live on testnet:

```bash
npm run stellar:init        # prints issuer/distributor env vars
# paste them into .env, then deposits/contributions settle on-chain
```

Mainnet with pooled Susu funds stays **audit-gated** and is intentionally not
wired.

## Integrations (auth + email)

Both are **config-driven**: they activate when their secrets are present and
fall back safely otherwise, so dev works without them.

- **Privy** (auth/wallets) — set `PRIVY_APP_ID`, `PRIVY_APP_SECRET`, and
  `NEXT_PUBLIC_PRIVY_APP_ID`. The login page then offers "Continue with Privy";
  the client posts its access token to `POST /api/auth/privy`, which verifies it
  server-side and issues a MoolaHub session. With no keys, the email/password
  flow is used. (The Privy React SDK pulls a web3 dep tree, so the repo pins
  `legacy-peer-deps=true` in `.npmrc` — `npm ci` respects it.)
- **Resend** (email) — set `RESEND_API_KEY`, `EMAIL_FROM`, and `APP_URL`.
  Circle invitations are then emailed; without a key they log to the server
  console. See `src/lib/server/email.ts`.

## Deploying

The app ships with a **Dockerfile** and **docker-compose.yml** (app + Postgres).
The container runs `prisma migrate deploy` on boot, then serves on `:3000`.

```bash
APP_ENCRYPTION_KEY=… SESSION_SECRET=… docker compose up --build
docker compose exec app npm run db:seed   # one-time, optional demo data
```

For a managed host (Render / Fly / Railway / self-host): build the image, point
`DATABASE_URL` at your Postgres, and set `APP_ENCRYPTION_KEY`, `SESSION_SECRET`,
and the `STELLAR_*` vars as secrets. Migrations live in `prisma/migrations/`.
Run `npm run stellar:init` once to populate the testnet Stellar vars.

## Brand

Palette Jade `#0E9E6E` · Ink `#0C1512` · Paper `#FFFFFF`. Official logo assets
in `public/brand/`. Full conventions in [`CLAUDE.md`](./CLAUDE.md).
