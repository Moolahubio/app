# CLAUDE.md — MoolaHub conventions

Guidance for working in this repo. Read before making changes.

## What this is

The MoolaHub web app: a non-custodial savings product (marketing site + product
UI) built on **Next.js App Router + TypeScript + Tailwind CSS**. Tagline:
**"Save Now. Grow Together."**

## Brand system (single source of truth)

The brand is implemented in `tailwind.config.ts` (tokens) and
`src/components/brand/Logo.tsx` (mark + wordmark). Use those — don't hard-code
hex values in components.

### Palette

| Token | Hex | Use |
| --- | --- | --- |
| `jade-500` | `#0E9E6E` | Primary — CTAs, accents, the mark |
| `ink-900` / `ink-950` | `#0C1512` / `#070D0B` | Text, dark surfaces |
| `paper` | `#FFFFFF` | Cards |
| `mist` | `#F5F8F6` | App background |

Jade and ink ship as full 50–900 scales for hover/active/border states.

### Logo

The mark is an **open savings ring** + an **ascending "M" / rising chart** + a
**north-east goal star** ("start low, grow up"). It's pure SVG so it stays crisp
and themes cleanly:

- On **light** surfaces: jade ring + M, jade star (`tone="ink"`).
- On **dark** surfaces: white ring + M, jade star (`tone="light"`).

Wordmark: **Moola** in the foreground tone, **Hub** in jade. Always one word,
camel-cased: `MoolaHub`.

### Type

- **Poppins** — display / headings / wordmark (`font-display`)
- **Inter** — body (`font-sans`)
- **IBM Plex Mono** — uppercase, letter-spaced eyebrow labels (`font-mono` /
  the `.eyebrow` class). This mono label is a core brand signature — use it for
  section kickers and metadata.

### Voice & motifs

"Connecting people through savings." Supporting cues used across the UI:
**Built on Stellar**, currencies **GHS · NGN · USDC**, and the ascending-chart
visual (`components/marketing/AscendingChart.tsx`).

## Golden rules

1. **Non-custodial.** The user holds their keys. Never imply MoolaHub can move
   funds without the user's signature.
2. **Money is integers.** Store and pass amounts as integer **cents** (1/100
   USDC). Never use floats for money. Format only at the display edge via
   `formatMoney()` in `src/lib/utils.ts`.
3. **Chain is the source of truth.** On-chain references (`txHash`) are the
   record of what happened; the UI reflects the ledger, not the other way round.
4. **Audit gate.** Susu pooling runs on Soroban smart contracts that hold
   pooled funds — those ship to mainnet only after an independent security
   audit. Keep that framing in copy.
5. **Goals are allocations, not accounts.** A savings goal is metadata over the
   user's single wallet balance — not a separate on-chain account.
6. **KYC is per-user** (via the fiat rail), required for local-currency
   deposits; the crypto rail stays KYC-light. No KYB.

## Conventions

- Path alias `@/*` → `src/*`.
- Compose styles with the `cn()` helper (clsx + tailwind-merge).
- Reuse primitives from `src/components/ui.tsx` (Button, Card, Badge,
  ProgressBar, Avatar, Eyebrow, IconChip) before adding new ones.
- Dynamic route `params` are a Promise (Next 15) — `await` them.
- Keep `npm run build` and `npx tsc --noEmit` green before committing.
