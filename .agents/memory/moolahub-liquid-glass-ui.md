---
name: MoolaHub liquid-glass UI system
description: How the moolahub-app frontend's liquid-glass design system is structured (tokens, utilities, primitives) and its non-obvious constraints.
---

# MoolaHub liquid-glass UI system

The web frontend (`artifacts/moolahub-app`) uses a theme-aware "liquid glass" design system layered on top of Tailwind v4.

## Token model
- `--mh-*` custom properties define the glass system: light values in `:root`, dark overrides in `.dark`.
- The immersive dark backdrop (radial glows / grid) is scoped to `.dark` / `.dark body` ONLY. Never make the backdrop global or light mode becomes unreadable.
- Tokens are consumed both via utilities and inline as `bg-[var(--mh-track)]`, `border-[var(--mh-border)]`, etc.

## Utilities & primitives
- Plain-CSS utilities appended in `src/index.css`: `mh-glass`/`-strong`/`-hover`, `mh-card-highlight`, `mh-btn-primary`/`-secondary`, `mh-input`, `mh-kicker`, `mh-page-title`, `mh-muted`, `mh-divider`, `mh-progress-track`/`-bar`, `mh-bg-grid`. All have reduced-motion / reduced-transparency / no-backdrop-filter fallbacks.
- Reusable primitives live in `src/components/ui/moola.tsx` (GlassPanel, GlassCard, MetricCard, PrimaryAction, SecondaryAction, StatusPill, ProgressLine, GlowLineChart), re-exported through the barrel `src/components/ui.tsx`.
- Base shared components were made glassy at the source: `Card` → `mh-glass`; primary `Button` → jade gradient (`from-jade-500 to-jade-600`) + glow.

**Why:** these are shared defaults, so a single edit restyles every consumer — but it also means base-component changes ripple app-wide; verify representative pages after touching `Card`/`Button`.

## Non-obvious constraints
- **`.mh-glass` uses `border:` shorthand.** The app shell (`app-layout.tsx`) sidebar/top/bottom bars still use the legacy `.glass` class plus side-specific border resets (`border-y-0`/`border-s-0`). If you ever migrate shell surfaces to `.mh-glass`, the border shorthand will clobber those side resets — guard them.
- **`ProgressLine` replaced the old `ProgressBar`.** Circles pages import `ProgressLine`; a stale `ProgressBar` reference is the usual culprit for a transient tsc/HMR error in `circles.tsx` / `circle-detail.tsx`.
- Vite build for this app REQUIRES `PORT` and `BASE_PATH` env vars at config load — a plain `pnpm build` fails at config resolution. Not a code error.
