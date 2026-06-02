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

The **official assets** live in `public/brand/`
(`moolahub_logo_horizontal.svg`, `…_horizontal_dark.svg`,
`moolahub_app_icon.png`). Use `src/components/brand/Logo.tsx`:

- `Logo` renders the official horizontal wordmark lockup — pass `tone="light"`
  on dark surfaces (white "Moola") and the default `tone="ink"` on light ones.
- `MoolaMark` is an inline SVG recreation of the mark (exact brand geometry:
  **open savings ring** + **ascending "M" / rising chart** + **north-east goal
  star**) for icon-only spots. It themes cleanly: jade on light surfaces;
  white ring + M with a jade star on dark (`tone="light"`), matching the app
  icon.

Wordmark: **Moola** in the foreground tone, **Hub** in jade. Always one word,
camel-cased: `MoolaHub`. Don't recreate the wordmark in HTML — use the asset.

### Type

- **Poppins** — display / headings / wordmark (`font-display`)
- **Inter** — body (`font-sans`)
- **IBM Plex Mono** — uppercase, letter-spaced eyebrow labels (`font-mono` /
  the `.eyebrow` class). This mono label is a core brand signature — use it for
  section kickers and metadata.

### Voice & motifs

"Connecting people through savings." Supporting cues used across the UI:
**Built on Base**, currencies **GHS · NGN · USDC**, and the ascending-chart
visual (`components/marketing/AscendingChart.tsx`).

## Golden rules

1. **Non-custodial.** The user holds their keys. Never imply MoolaHub can move
   funds without the user's signature.
2. **Money is integers.** Store and pass amounts as integer **cents** (1/100
   USDC). Never use floats for money. Format only at the display edge via
   `formatMoney()` in `src/lib/utils.ts`.
3. **Chain is the source of truth.** On-chain references (`txHash`) are the
   record of what happened; the UI reflects the ledger, not the other way round.
4. **Audit gate.** Susu pooling runs on audited smart contracts on Base that hold
   pooled funds — those ship to mainnet only after an independent security
   audit. Keep that framing in copy.
5. **Goals are allocations, not accounts.** A savings goal is metadata over the
   user's single wallet balance — not a separate on-chain account.
6. **Crypto-only rails (for now).** Deposits and withdrawals are **USDC on
   Base** — receive to your wallet address, withdraw to any Base address.
   No KYC on the crypto rail. Local-currency (GHS · NGN) on/off-ramp via a
   licensed partner — and the per-user KYC it requires — is planned for later.
   Test everything on **testnet** before mainnet contracts. No KYB.

## Conventions

- Path alias `@/*` → `src/*`.
- Compose styles with the `cn()` helper (clsx + tailwind-merge).
- Reuse primitives from `src/components/ui.tsx` (Button, Card, Badge,
  ProgressBar, Avatar, Eyebrow, IconChip) before adding new ones.
- Dynamic route `params` are a Promise (Next 15) — `await` them.
- Keep `npm run build` and `npx tsc --noEmit` green before committing.
