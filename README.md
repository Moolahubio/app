# MoolaHub — Web App

> **Save Now. Grow Together.**
> A non-custodial savings web app built on Stellar. Hit your goals, save with
> trusted Susu circles, learn as you go — and verify every contribution on-chain.

This is the marketing site + product UI for MoolaHub, built with **Next.js (App
Router)**, **TypeScript**, and **Tailwind CSS**.

## Getting started

```bash
npm install
npm run dev       # http://localhost:3000
npm run build     # production build
npm run start     # serve the production build
```

## What's inside

| Route | Screen |
| --- | --- |
| `/` | Marketing landing — hero, Susu circles, goals, education, on-chain verification, trust features |
| `/get-started` | Onboarding / sign-in (Privy-style email + social) |
| `/app` | Dashboard — balance, growth, reminders, goals, active circle, learning, activity |
| `/app/circles` · `/app/circles/[id]` | Susu circles list + detail (payout schedule, members, contribution history with on-chain proof) |
| `/app/goals` · `/app/goals/[id]` | Savings goals list + detail (progress ring, auto-save, projection) |
| `/app/learn` · `/app/learn/[slug]` | Financial-empowerment lessons |
| `/app/activity` | Transaction ledger + payment reminders |
| `/app/profile` | Account, KYC status, non-custodial wallet, settings |

## Project structure

```
src/
├── app/                 # routes (App Router)
│   ├── page.tsx         # marketing landing
│   ├── get-started/     # onboarding
│   ├── app/             # authenticated product shell + screens
│   ├── icon.svg         # favicon / app icon (the MoolaHub mark)
│   └── globals.css
├── components/
│   ├── brand/Logo.tsx   # SVG logo + mark (themeable)
│   ├── marketing/       # landing sections (nav, footer, ascending-chart motif)
│   ├── app/             # app shell + shared app bits
│   └── ui.tsx           # design-system primitives (Button, Card, Badge, …)
└── lib/
    ├── data.ts          # demo domain data
    └── utils.ts         # money/format helpers
```

## Brand

The MoolaHub brand system (palette, logo, voice) is documented in
[`CLAUDE.md`](./CLAUDE.md) and implemented as the single source of truth in
`tailwind.config.ts` and `src/components/brand/Logo.tsx`.

- **Palette** — Jade `#0E9E6E` · Ink `#0C1512` · Paper `#FFFFFF`
- **Tagline** — *Save Now. Grow Together.*
- **Type** — Poppins (display) · Inter (body) · IBM Plex Mono (eyebrow labels)

## Notes

This build is the **UI layer**. The data in `src/lib/data.ts` is illustrative;
integrations (Privy wallets, Yellowcard fiat on/off-ramp, Blend yield, Soroban
Susu contracts) are out of scope here and wire in behind these screens. Money is
handled as **integer cents** throughout — see `CLAUDE.md`.
