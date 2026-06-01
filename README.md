# MoolaHub — Web App (`app.moolahub.io`)

> **Save Now. Grow Together.**
> The MoolaHub product app: a non-custodial savings experience built on
> Stellar. Hit your goals, save with trusted Susu circles, learn as you go —
> and verify every contribution on-chain.

This repo is the **product app** that serves `app.moolahub.io`. The marketing
site lives separately at [moolahub.io](https://moolahub.io). Built with
**Next.js (App Router)**, **TypeScript**, and **Tailwind CSS**.

## Getting started

```bash
npm install
npm run dev       # http://localhost:3000
npm run build     # production build
npm run start     # serve the production build
```

## Routes

The product is served at the **root** so URLs map cleanly onto the app
subdomain (e.g. `app.moolahub.io/circles`).

| Route | Screen |
| --- | --- |
| `/` | Dashboard — balance, growth, reminders, goals, active circle, learning, activity |
| `/circles` · `/circles/[id]` | Susu circles list + detail (payout schedule, members, contribution history with on-chain proof) |
| `/goals` · `/goals/[id]` | Savings goals list + detail (progress ring, auto-save, projection) |
| `/learn` · `/learn/[slug]` | Financial-empowerment lessons |
| `/activity` | Transaction ledger + payment reminders |
| `/profile` | Account, KYC status, non-custodial wallet, settings |
| `/login` | Sign in / create account (app entry for logged-out users) |
| `/preview` | A proposed marketing landing — reference for the moolahub.io upgrade (see `LANDING_UPGRADE_PLAN.md`) |

## Project structure

```
public/
├── brand/               # official MoolaHub logo assets (horizontal light/dark, app icon)
└── partners/            # Privy · Yellowcard · Stellar marks
src/
├── app/
│   ├── (app)/           # authenticated product (AppShell layout) — served at /
│   │   ├── page.tsx     #   dashboard
│   │   ├── circles/ goals/ learn/ activity/ profile/
│   │   └── layout.tsx   #   AppShell (sidebar + topbar + mobile nav)
│   ├── login/           # sign in / create account
│   ├── preview/         # proposed marketing landing (reference)
│   ├── icon.png         # favicon (the MoolaHub app icon)
│   └── layout.tsx, globals.css, not-found.tsx
├── components/
│   ├── brand/Logo.tsx   # official wordmark lockup + inline SVG mark (themeable)
│   ├── marketing/       # landing sections (nav, footer, ascending-chart motif)
│   ├── app/             # app shell + shared app bits
│   └── ui.tsx           # design-system primitives (Button, Card, Badge, …)
└── lib/
    ├── data.ts          # demo domain data
    └── utils.ts         # money/format helpers
```

## Brand

The brand system (palette, logo, voice) is documented in
[`CLAUDE.md`](./CLAUDE.md). The **official logo assets** live in `public/brand/`
and the wordmark/mark are wired through `src/components/brand/Logo.tsx`.

- **Palette** — Jade `#0E9E6E` · Ink `#0C1512` · Paper `#FFFFFF`
- **Tagline** — *Save Now. Grow Together.*
- **Type** — Poppins (display) · Inter (body) · IBM Plex Mono (eyebrow labels)

## Notes

This build is the **UI layer**. The data in `src/lib/data.ts` is illustrative;
integrations (Privy wallets, Yellowcard fiat on/off-ramp, Blend yield, Soroban
Susu contracts) wire in behind these screens. Money is handled as **integer
cents** throughout — see `CLAUDE.md`.
