# MoolaHub iOS: design spec v1 (historical; superseded by the private DESIGN.md v2)

**Status:** v1 for the dev build · **Date:** 2026-10-23 · **Owner:** iOS design
**Applies to:** the native SwiftUI app in `apps/ios/` (iPhone, iOS 17.0+, built with the iOS 26 SDK).
**Inputs:** web brand tokens `artifacts/moolahub-app/src/index.css`, `docs/brand/BRAND_VOICE.md`, `docs/brand/UX_COPY_REVIEW.md`, `docs/base-build-spec-v2.md` §1 (invisible crypto), `docs/ios-app-plan.md` (D13, D14), web i18n `artifacts/moolahub-app/src/i18n/locales/en/*.json`, the API (`lib/api-spec/openapi.yaml` and `artifacts/api-server/src/routes/*`).

Engineers implement exactly what is written here. If something here can't be built as written, say so in your report rather than inventing a variant. All copy in this file is final English copy: use it verbatim (straight apostrophe `'`, real ellipsis `…` U+2026, middle dot `·` U+00B7, minus sign `−` U+2212 where noted).

---

## 0. Principles

1. **Dollars, not crypto.** Users see Balance, goals, groups, "Processing…" and "Done". No wallet, address, hash, chain, gas, "USDC", "Privy", "blockchain" or "transaction" outside the disclosure footer, About and legal, and Technical details (see §9.3).
2. **Never show a number we don't have.** Every amount, percent, pace and chart comes from an API field or a deterministic calculation on API fields (formulas in this file). Loading shows a skeleton, failure shows an error with retry. Never `$0.00` as a stand-in.
3. **One calm, dark hero.** Light mist canvas, white cards, one near-black balance card with four round quick actions. Space Grotesk numbers, Hanken Grotesk words, IBM Plex Mono eyebrows.
4. **Every money move is a sheet that ends on review, confirm, receipt.** Nothing moves on a single tap.
5. **System first.** System `TabView`, `NavigationStack`, sheets, `Toggle`, `DatePicker`, pull to refresh. Liquid Glass comes from the system on iOS 26; we don't fake it.

---

## 1. Color

### 1.1 Web tokens converted to exact hex

Converted from `index.css` HSL with standard HSL→sRGB, rounded to the nearest 8-bit value. These are the brand source values; §1.2 says which ones iOS uses.

| Token | Light HSL → hex | Dark HSL → hex |
|---|---|---|
| `--background` | 135 15% 97% → `#F6F8F7` | 162 25% 8% → `#0F1A16` |
| `--foreground` | 160 30% 6% → `#0B1411` | 0 0% 98% → `#FAFAFA` |
| `--card` | 0 0% 100% → `#FFFFFF` | 160 30% 6% → `#0B1411` |
| `--card-border` | 150 10% 92% → `#E9EDEB` | 160 20% 15% → `#1F2E29` |
| `--border` / `--input` | 150 10% 90% → `#E3E8E6` | 160 20% 15% → `#1F2E29` |
| `--primary` (jade) | 158 83% 34% → `#0F9F6A` | 158 83% 34% → `#0F9F6A` |
| `--primary-border` | 158 83% 30% → `#0D8C5D` | 158 83% 30% → `#0D8C5D` |
| `--secondary` | 135 15% 97% → `#F6F8F7` | 160 20% 12% → `#182521` |
| `--secondary-foreground` | 160 30% 20% → `#244238` | 0 0% 90% → `#E6E6E6` |
| `--secondary-border` | 135 15% 90% → `#E2E9E4` | 160 20% 18% → `#253731` |
| `--muted` | 150 10% 94% → `#EEF1F0` | 160 20% 12% → `#182521` |
| `--muted-foreground` | 160 10% 40% → `#5C7069` | 156 14% 72% → `#AEC2BA` |
| `--muted-border` | 150 10% 85% → `#D5DDD9` | 160 20% 15% → `#1F2E29` |
| `--accent` | 135 15% 95% → `#F0F4F1` | 160 20% 14% → `#1D2B26` |
| `--accent-foreground` | 160 30% 15% → `#1B322A` | 0 0% 95% → `#F2F2F2` |
| `--accent-border` | 135 15% 85% → `#D3DED6` | 160 20% 20% → `#293D36` |
| `--destructive` | 0 84% 60% → `#EF4343` | 0 62% 30% → `#7C1D1D` |
| `--destructive-border` | 0 84% 50% → `#EB1414` | 0 62% 25% → `#671818` |

Fixed hex brand scales (from `@theme`, used as-is): jade-50 `#ECFBF4`, jade-100 `#CFF5E3`, jade-200 `#A1EAC9`, jade-300 `#67DBAB`, jade-400 `#30C58A`, jade-500 `#0E9E6E`, jade-600 `#0B8A60`, jade-700 `#0A6E4E`, jade-800 `#0B563F`, jade-900 `#0A3F2F`; ink-950 `#070D0B`, ink-900 `#0C1512`, ink-850 `#0F1814`, ink-800 `#14201B`, ink-700 `#1B2A24`, ink-600 `#26392F`, ink-500 `#3A5046`, ink-400 `#5C7468`; mist `#F5F8F6`.

Notes on the conversion:
- The brief's `#0F9D6B` jade fill is `--primary`; the exact value is **`#0F9F6A`**. The logo mark uses jade-500 `#0E9E6E`; keep the logo artwork as-is.
- Web dark mode puts cards (`#0B1411`) *darker* than the page (`#0F1A16`). iOS dark mode lifts higher surfaces instead (§1.4), so iOS dark surfaces come from the ink scale.
- White text on `--primary` is 3.39:1 and on web `--destructive` 3.78:1. Both fail 4.5:1 for normal text, so iOS never puts body-size text on them (§1.2).

### 1.2 iOS semantic tokens

Define each as a named color with Any/Dark appearances (asset catalog or code, architect's call). "IC" = value when `colorSchemeContrast == .increased`; blank means unchanged.

**Surfaces**

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F6F8F7` | `#0B1411` | Page background behind everything. |
| `surface` | `#FFFFFF` | `#14201B` | Cards, list groups, the tab's content cards. |
| `surfaceRaised` | `#FFFFFF` | `#1B2A24` | Cards inside sheets, menus, pressed rows (dark). |
| `sheetCanvas` | `#F6F8F7` | `#14201B` | Sheet background (one level above `canvas`). |
| `fill` | `#EEF1F0` | `#1F2E29` | Text field fill, chips, icon wells, skeleton blocks, segmented track. |
| `cardBorder` | `#E9EDEB` | `#1F2E29` | 1pt hairline around cards (decorative). |
| `divider` | `#E3E8E6` | `#26392F` | Row separators inside cards (decorative). |
| `controlBorder` | `#768983` (IC `#5C7069`) | `#64796F` (IC `#8A9E96`) | 1pt border of text fields, secondary buttons, unselected radio rings. Meets 3:1. |
| `heroSurface` | `#0C1512` | `#26392F` | The balance card only. |
| `heroBorder` | none | `#FFFFFF` at 10% | 1pt border on the balance card in dark mode. |
| `heroDivider` | `#FFFFFF` at 12% | `#FFFFFF` at 12% | Rule between amount block and quick actions. |
| `heroAction` | `#FFFFFF` | `#FFFFFF` | Round quick-action buttons on the balance card. |
| `heroActionGlyph` | `#0C1512` | `#0C1512` | SF Symbol inside quick actions. |

**Text**

| Token | Light | Dark | Use |
|---|---|---|---|
| `textPrimary` | `#0B1411` | `#FAFAFA` | Titles, body, amounts. |
| `textSecondary` | `#5C7069` (IC `#44564F`) | `#AEC2BA` (IC `#C9D6D1`) | Supporting lines, captions, placeholders, eyebrows on cards. There is no lighter text token: anything readable meets 4.5:1. |
| `heroText` | `#FFFFFF` | `#FFFFFF` | Text on `heroSurface`. |
| `heroTextSecondary` | `#AEC2BA` | `#AEC2BA` | Eyebrow and sub-lines on `heroSurface`. |

**Buttons**

| Token | Light | Dark | Use |
|---|---|---|---|
| `ctaBackground` | `#0C1512` | `#FAFAFA` | PrimaryButton fill (black in light, inverted to near-white in dark). |
| `ctaForeground` | `#FFFFFF` | `#0B1411` | PrimaryButton label and spinner. |
| `ctaPressed` | `#1B2A24` | `#DCE3E0` | PrimaryButton pressed fill. |
| `ctaDisabledBackground` | `#EEF1F0` | `#26392F` | Disabled PrimaryButton. |
| `ctaDisabledForeground` | `#5C7069` | `#AEC2BA` | Disabled label (4.65:1 / 6.57:1). |
| `secondaryButtonBackground` | `#FFFFFF` | `#1B2A24` | SecondaryButton fill, with `controlBorder`. |
| `destructiveFill` | `#B91C1C` | `#7C1D1D` | Destructive button fill. Light deviates from web `#EF4343` (fails 4.5:1 with white); dark is the web token. |
| `destructiveForeground` | `#FFFFFF` | `#FAFAFA` | Destructive button label. |

**Accent and status**

| Token | Light | Dark | Use |
|---|---|---|---|
| `jadeText` | `#0A6E4E` (IC `#0B563F`) | `#30C58A` (IC `#67DBAB`) | Links, "See all", positive amounts, "On track", app `AccentColor` (tab selection, toggles' tint is `jadeFill`). |
| `jadeFill` | `#0F9F6A` | `#0F9F6A` | `Toggle` tint, brand accents, icons on light backgrounds. Never behind text. |
| `jadeTint` | `#ECFBF4` | `#18372B` | Background of jade pills and goal icon wells. Opaque. |
| `progressFill` | `#0B8A60` (IC `#0A6E4E`) | `#30C58A` | ProgressBar fill and chart bars. |
| `progressTrack` | `#EEF1F0` | `#26392F` | ProgressBar track. |
| `amberText` | `#92400E` | `#FBBF24` | "Processing…", "N weeks behind", "Past target date", test-money label. |
| `amberTint` | `#FFF7E6` | `#34361C` | Background of amber pills and banners. Opaque. |
| `redText` | `#B91C1C` | `#F87171` | Errors, "Didn't go through", field validation. |
| `redTint` | `#FEF2F2` | `#342B27` | Background of error banners and red pills. Opaque. |
| `neutralTint` | `#EEF1F0` | `#1F2E29` | Neutral pills ("Pending", "Forming"), with `textSecondary`. |

Tints are opaque hex, not opacity, so a pill keeps its contrast on any surface.

### 1.3 Contrast check (WCAG 2.2, computed)

Ratios computed with the WCAG relative-luminance formula on the exact hex values above. Text needs ≥4.5:1, UI parts and meaningful graphics ≥3:1. All pass.

| Pair | Light | Dark | Needs |
|---|---|---|---|
| textPrimary | `#0B1411` on canvas 17.54, surface 18.71, fill 16.46 | `#FAFAFA` on canvas 17.93, surface 16.07, surfaceRaised 14.34, fill 13.58 | ≥4.5 |
| textSecondary | `#5C7069` on canvas 4.95, surface 5.28, fill 4.65 | `#AEC2BA` on canvas 10.00, surface 8.96, surfaceRaised 8.00, fill 7.58 | ≥4.5 |
| textSecondary (IC) | `#44564F` on canvas 7.32, surface 7.81, fill 6.87 | `#C9D6D1` on surface 11.20, surfaceRaised 9.99 | ≥4.5 |
| jadeText | `#0A6E4E` on canvas 5.87, surface 6.26, fill 5.51, jadeTint 5.87 | `#30C58A` on canvas 8.45, surface 7.57, surfaceRaised 6.76, jadeTint 5.85 | ≥4.5 |
| jadeText (IC) | `#0B563F` on surface 8.69, jadeTint 8.14 | `#67DBAB` on surface 9.82, surfaceRaised 8.76 | ≥4.5 |
| amberText | `#92400E` on canvas 6.65, surface 7.09, amberTint 6.65 | `#FBBF24` on canvas 11.21, surface 10.05, surfaceRaised 8.96, amberTint 7.44 | ≥4.5 |
| redText | `#B91C1C` on canvas 6.07, surface 6.47, fill 5.69, redTint 5.91 | `#F87171` on canvas 6.76, surface 6.06, surfaceRaised 5.41, redTint 4.99 | ≥4.5 |
| heroText | `#FFFFFF` on hero 18.56 | `#FFFFFF` on hero 12.29 | ≥4.5 |
| heroTextSecondary | `#AEC2BA` on hero 9.92 | `#AEC2BA` on hero 6.57 | ≥4.5 |
| ctaForeground | `#FFFFFF` on cta 18.56 | `#0B1411` on cta 17.93 | ≥4.5 |
| ctaDisabledForeground | `#5C7069` on disabled 4.65 | `#AEC2BA` on disabled 6.57 | exempt, passes anyway |
| destructiveForeground | `#FFFFFF` on `#B91C1C` 6.47 | `#FAFAFA` on `#7C1D1D` 9.81 | ≥4.5 |
| heroAction glyph | `#0C1512` on white 18.56 | same | ≥3.0 |
| progressFill vs track | `#0B8A60` on track 3.83 | `#30C58A` on track 5.55 | ≥3.0 |
| progressFill / chart bar vs card | `#0B8A60` on surface 4.36, canvas 4.09 | `#30C58A` on surface 7.57, surfaceRaised 6.76 | ≥3.0 |
| jadeFill (toggle) | `#0F9F6A` on surface 3.39, canvas 3.18 | `#0F9F6A` on canvas 5.51, surface 4.94 | ≥3.0 |
| controlBorder | `#768983` on canvas 3.47, surface 3.70, fill 3.25 | `#64796F` on canvas 4.01, surface 3.60, surfaceRaised 3.21 | ≥3.0 |
| controlBorder (IC) | `#5C7069` on canvas 4.95, surface 5.28 | `#8A9E96` on surface 5.92, surfaceRaised 5.28 | ≥3.0 |
| PrimaryButton fill vs page | `#0C1512` on canvas 17.40 | `#FAFAFA` on canvas 17.93 | ≥3.0 |

Pairs that fail and are therefore **not allowed**: white or any text on `jadeFill` `#0F9F6A` (3.39); text on web `#EF4343` (3.78); `jadeFill` as a progress fill on `progressTrack` light (2.99, use `progressFill`); jade-700 text in dark mode (2.68).

Card borders, dividers and skeleton blocks are decorative (they don't identify a control), so they are exempt from 3:1. Text fields and secondary buttons use `controlBorder`, which meets 3:1.

### 1.4 Dark mode and elevation

Higher surfaces are lighter: `canvas` `#0B1411` (ink-900) → `surface` `#14201B` (ink-800) → `surfaceRaised` `#1B2A24` (ink-700) → `heroSurface` `#26392F` (ink-600). The balance card is the lightest surface in dark mode and gets a 1pt `heroBorder`, so it still reads as the one hero. No drop shadows in dark mode (§3.4). Sheets use `sheetCanvas` (`#14201B`) with `surfaceRaised` cards inside.

### 1.5 Color rules

- Status is never color alone: every pill has an SF Symbol and a word (§4.15).
- Use tokens only. No raw hex, no `.opacity()` on text colors (exception: `heroBorder`, `heroDivider`).
- `Reduce Transparency` on: any material (privacy cover, custom glass) becomes solid `canvas`.
- `AccentColor` = `jadeText` (light `#0A6E4E`, dark `#30C58A`).

---

## 2. Typography

### 2.1 Font files (verified)

All files are static instances (no `fvar` table), checked with `file`, a standard-library Python reader of the `name`/`OS/2`/`GSUB`/`cmap` tables, and macOS Core Text (`CTFontManagerCreateFontDescriptorsFromURL`). Location: `apps/ios/Moolahub/Resources/Fonts/`.

| File | PostScript name (use this in `Font.custom`) | Family / style | Weight (`usWeightClass`) | Version | SHA-256 |
|---|---|---|---|---|---|
| `SpaceGrotesk-Medium.ttf` | `SpaceGrotesk-Medium` | Space Grotesk / Medium | 500 | 2.000 | `d8135bce6603398f3d0cdb478a018d7fa869b0168d037a9408cad23e030bfa7a` |
| `SpaceGrotesk-SemiBold.ttf` | `SpaceGrotesk-SemiBold` | Space Grotesk / SemiBold | 600 | 2.000 | `279a5d22b8ab377f41706af566610667db3941b069b50187b98af09ca3b08f91` |
| `SpaceGrotesk-Bold.ttf` | `SpaceGrotesk-Bold` | Space Grotesk / Bold | 700 | 2.000 | `8fb63865c6afd083723dc1775548306b7751f20397bebcb79646032c598c81b9` |
| `HankenGrotesk-Regular.ttf` | `HankenGrotesk-Regular` | Hanken Grotesk / Regular | 400 | 3.014 | `0a5c86e907f6d6cba528c3bfb0516b3f46c9524fa22f32f292109f25dc149b32` |
| `HankenGrotesk-Medium.ttf` | `HankenGrotesk-Medium` | Hanken Grotesk / Medium | 500 | 3.014 | `d14c46b4c5e9e65d2ce5fbc01e0dd3b342c8cdac624ef1e5174ef11c40dfea6b` |
| `HankenGrotesk-SemiBold.ttf` | `HankenGrotesk-SemiBold` | Hanken Grotesk / SemiBold | 600 | 3.014 | `19ef1bdde3563a72e3a8387461f9e3eff33e6ae1ab3576e904db82fd99cf4f4a` |
| `HankenGrotesk-Bold.ttf` | `HankenGrotesk-Bold` | Hanken Grotesk / Bold | 700 | 3.014 | `db1917dede6e06e8b1cb307d5135f176a5846b24b4d59fbe59bab4741c30c146` |
| `IBMPlexMono-Regular.ttf` | **`IBMPlexMono`** (no `-Regular` suffix) | IBM Plex Mono / Regular | 400 | 2.005 | `7c6fbddca4b700be918f5f6183d9bd4464fa427fe435f0b480d77fe2bb8c5a43` |
| `IBMPlexMono-Medium.ttf` | **`IBMPlexMono-Medm`** (IBM's abbreviation) | IBM Plex Mono / Medium | 500 | 2.005 | `98fbd727aae340b236955879dabed4d991aac9e8e90b3b2a67ce4a59221cc97c` |

Licenses (SIL OFL 1.1, bundle them with the app): `SpaceGrotesk-OFL.txt`, `HankenGrotesk-OFL.txt`, `IBMPlexMono-OFL.txt`. None of the three declares a Reserved Font Name.

Sources:
- **Space Grotesk:** Google Fonts' official family download (manifest `https://fonts.google.com/download/list?family=Space%20Grotesk`, files `static/SpaceGrotesk-*.ttf` on `fonts.gstatic.com/s/spacegrotesk/v22/`). The upstream repo `floriankarsten/space-grotesk` (2.0.0) ships static Medium and Bold but **no static SemiBold**, so all three weights come from the same Google Fonts static build for a consistent set (same vertical metrics as upstream). License: `google/fonts` `ofl/spacegrotesk/OFL.txt` (same text as upstream).
- **Hanken Grotesk:** upstream `github.com/marcologous/hanken-grotesk`, `master/fonts/ttf/` and `OFL.txt`.
- **IBM Plex Mono:** upstream `github.com/IBM/plex`, `master/packages/plex-mono/fonts/complete/ttf/` and `packages/plex-mono/LICENSE.txt`.

Feature and glyph checks:
- Space Grotesk and Hanken Grotesk both have the OpenType `tnum` (tabular figures) and `pnum` features. Plex Mono is monospaced, so its digits are always equal width.
- All nine files have `$ , . 0-9 … · ’ − – — € £` and no-break space. **Hanken Grotesk lacks `↑ ↓` and `₵` (cedi)**: never type arrows in text (use SF Symbols); Ghana cedi amounts, when they come, must use Space Grotesk.
- Vertical metrics (units per em 1000): Space Grotesk ascender 984 / descender −292; Hanken Grotesk 1000 / −303; IBM Plex Mono 1025 / −275. Natural line heights are close to SF Pro's, so no line-height overrides are needed for single lines.

Registration: list every `.ttf` file name under `UIAppFonts` in the app's Info.plist (file names only, the fonts must be copied into the app bundle). In debug builds, assert at launch that `UIFont(name:size:)` returns non-nil for all nine PostScript names.

### 2.2 Type scale

Every style is `Font.custom(<PostScript name>, size: <size>, relativeTo: <text style>)`, so it scales with Dynamic Type along that style's curve. "AX5" is the approximate size at the largest accessibility setting (size × the text style's AX5/Large ratio). Tracking is in points at the base size (web uses −0.018em on display type, −0.006em on body, +0.22em on eyebrows).

| Token | PostScript name | Size | `relativeTo` | Tracking | ≈AX5 | Cap | Use |
|---|---|---|---|---|---|---|---|
| `displayHero` | `SpaceGrotesk-SemiBold` | 40 | `.largeTitle` | −0.7 | 71 | `.accessibility2` | Total balance on the balance card. |
| `displayEntry` | `SpaceGrotesk-SemiBold` | 52 | `.largeTitle` | −0.9 | 92 | `.accessibility1` | AmountEntry display. |
| `displayAmount` | `SpaceGrotesk-SemiBold` | 34 | `.largeTitle` | −0.6 | 60 | `.accessibility3` | Review and Receipt amount, goal detail saved amount, group pot. |
| `titleLarge` | `SpaceGrotesk-Bold` | 34 | `.largeTitle` | −0.6 | 60 | none | Navigation large titles (via appearance, §2.5), Welcome headline. |
| `title1` | `SpaceGrotesk-Bold` | 28 | `.title` | −0.5 | 58 | none | Auth screen titles, Home greeting. |
| `title2` | `SpaceGrotesk-SemiBold` | 22 | `.title2` | −0.4 | 56 | none | Sheet titles, EmptyState and ErrorState titles. |
| `title3` | `SpaceGrotesk-SemiBold` | 20 | `.title3` | −0.35 | 55 | none | SectionHeader, card amounts (GoalCard saved). |
| `titleInline` | `SpaceGrotesk-SemiBold` | 17 | `.headline` | −0.3 | 53 | none | Inline navigation titles (via appearance). |
| `amountRow` | `SpaceGrotesk-Medium` | 17 | `.body` | −0.2 | 53 | none | Amounts in rows (ActivityRow, review rows). |
| `amountSmall` | `SpaceGrotesk-Medium` | 15 | `.subheadline` | −0.15 | 49 | none | Secondary amounts ("of $5,000"). |
| `keypad` | `SpaceGrotesk-Medium` | 28 | `.title` | 0 | 58 | `.accessibility1` | Keypad digits. |
| `headline` | `HankenGrotesk-SemiBold` | 17 | `.headline` | −0.1 | 53 | none | Row titles, card titles, button labels. |
| `body` | `HankenGrotesk-Regular` | 17 | `.body` | −0.1 | 53 | none | Body copy. Paragraphs add `.lineSpacing(2)`. |
| `bodyEmphasis` | `HankenGrotesk-Medium` | 17 | `.body` | −0.1 | 53 | none | Emphasis inside body, field values. |
| `callout` | `HankenGrotesk-Regular` | 16 | `.callout` | −0.1 | 51 | none | Sheet intro text. |
| `subheadline` | `HankenGrotesk-Regular` | 15 | `.subheadline` | 0 | 49 | none | Secondary lines in rows and cards. |
| `subheadlineEmphasis` | `HankenGrotesk-SemiBold` | 15 | `.subheadline` | 0 | 49 | none | "See all", text buttons, chips. |
| `footnote` | `HankenGrotesk-Regular` | 13 | `.footnote` | 0 | 44 | none | Helper text, disclosure footer, field hints. |
| `footnoteEmphasis` | `HankenGrotesk-SemiBold` | 13 | `.footnote` | 0 | 44 | none | StatusPill, quick-action labels. |
| `eyebrow` | `IBMPlexMono-Medm` | 12 | `.caption` | +2.6 | 43 | `.accessibility3` | Uppercase labels ("TOTAL BALANCE"). Apply `.textCase(.uppercase)` to a sentence-case string so VoiceOver reads words, not letters. |
| `mono` | `IBMPlexMono` | 15 | `.subheadline` | 0 | 49 | none | Technical details values, Developer settings URL. |

Rules:
- **Weights:** Space Grotesk 500–700 only, Hanken 400–700, Plex Mono 400–500. Nothing above 700 exists in the bundle.
- **Money is always tabular:** every Space Grotesk style used for numbers gets `.monospacedDigit()`, which turns on `tnum`. A DesignSystem snapshot or unit test must prove `$111.11` and `$000.00` render at equal width in `displayHero` and `amountRow`.
- **Caps:** the "Cap" column is `.dynamicTypeSize(...cap)` on that text only, never on a whole screen. Display amounts also get `.lineLimit(1)`, `.minimumScaleFactor(0.5)`, `.allowsTightening(true)`. Digits of money are never truncated with "…": they scale down instead.
- **Bold Text** (`legibilityWeight == .bold`): step every custom font up one weight (Regular→Medium, Medium→SemiBold, SemiBold→Bold, Bold stays Bold; `IBMPlexMono`→`IBMPlexMono-Medm`).
- Tab bar labels, alerts, confirmation dialogs, context menus, `DatePicker` and keyboard use the system font. Don't restyle them.

### 2.3 Money formatting

- Amounts arrive as `Int` cents. Convert with `Decimal(cents) / 100`. Never `Double`, never `Float`.
- Format with `Decimal.FormatStyle.Currency(code: "USD")` and a **fixed `Locale(identifier: "en_US")`**, so it's always `$1,234.56` (never `US$1,234.56` from en-GH, never `1.234,56 $` from a European region). Dates and times use the user's locale.
- Two presentations, both in DesignSystem's MoneyText (§4.3):
  - `exact`: always 2 decimals. Default for balances, every money-move sheet, receipts, activity.
  - `wholeIfRound`: drops `.00` only when `cents % 100 == 0` (`$5,000`, but `$5,000.50`). Used for goal targets, group contribution summaries and preset chips.
- Direction: money in shows `+$50.00` in `jadeText`; money out shows `−$20.00` (U+2212 minus) in `textPrimary`. Build it as sign + formatted absolute value. Zero shows `$0.00` with no sign.
- Percent: `floor(saved × 100 / target)` as an integer, clamped 0…100. If `saved > 0` and the floor is 0, show `<1%`. Fee percents from basis points: `bps / 100` with up to 2 decimals and no trailing zeros (`200` → `2%`, `150` → `1.5%`).

### 2.4 Dates

- Activity times: `.dateTime.hour().minute()`. Day headers: "Today", "Yesterday", else `.dateTime.weekday(.wide).day().month(.abbreviated)` (adds `.year()` if not this year).
- Goal target date: the API stores the deadline as an ISO instant at UTC midnight. Format it **in the UTC time zone** with `.dateTime.day().month(.abbreviated).year()` (for example `1 Mar 2027`), otherwise users west of UTC see the day before. Send new deadlines as `yyyy-MM-dd`.

### 2.5 Navigation titles

Large titles use `titleLarge`, inline titles `titleInline`, set once at app start through `UINavigationBar.appearance().largeTitleTextAttributes` and `.titleTextAttributes` with the fonts scaled by `UIFontMetrics(forTextStyle: .largeTitle / .headline)` and colored `textPrimary`. Set only text attributes, never a bar background or `UINavigationBarAppearance` background, so iOS 26 keeps its Liquid Glass and scroll-edge behaviour. (Known limit: these don't rescale if Dynamic Type changes while the app runs; they pick it up on next launch.)

---

## 3. Layout

### 3.1 Spacing (4pt grid)

| Token | pt | Use |
|---|---|---|
| `space1` | 4 | Icon-to-text in pills, tight stacks. |
| `space2` | 8 | Label to value, quick-action circle to label. |
| `space3` | 12 | Between cards, section header to content, row vertical padding. |
| `space4` | 16 | Card inner padding, row horizontal padding. |
| `space5` | 20 | Screen side gutter, balance card padding. |
| `space6` | 24 | Sheet side padding, block spacing inside a sheet. |
| `space8` | 32 | Between sections on a screen. |
| `space10` | 40 | Top of auth screens below the nav bar. |
| `space12` | 48 | Above the main action on auth screens. |
| `space16` | 64 | EmptyState top inset. |

Screen gutter is 20pt on every tab screen. Bottom content inset clears the tab bar automatically (use the safe area; don't add fixed padding). Sheets pin their main button to the bottom safe area with 16pt above it.

### 3.2 Radii (all `RoundedRectangle(cornerRadius:style: .continuous)`)

| Token | pt | Use |
|---|---|---|
| `radiusSmall` | 8 | Keypad key pressed highlight, tiny chips. |
| `radiusMedium` | 12 | Text fields, icon wells, inline banners. (= web `--radius`) |
| `radiusLarge` | 16 | List-group cards in Account and sheets. |
| `radiusCard` | 20 | GoalCard, CircleCard, activity day cards, Home section cards. |
| `radiusHero` | 28 | BalanceCard. |
| capsule | full | Buttons, StatusPill, preset chips, ProgressBar. |

### 3.3 Sizes

| Element | Size |
|---|---|
| Minimum tap target | 44 × 44 (use `.contentShape` to extend small visuals). |
| PrimaryButton / SecondaryButton | Full width, min height 56, grows with Dynamic Type. |
| Small button (Accept, Decline, Copy) | Min height 36 visual, 44 tap target. |
| Quick-action circle | 56 diameter, SF Symbol 22pt semibold. |
| Goal icon well | 44 × 44 (`radiusMedium`), symbol 20pt. |
| Activity icon well | 40 × 40 circle, symbol 17pt. |
| Avatar (initials) | 40 (Account header 64, MemberRow 36). |
| ProgressBar | Height 8 (GoalCard), 10 (Goal detail). |
| Keypad key | Min 64 wide × 56 tall, 3 columns, 8pt gaps. |
| Text field | Min height 52, 16pt horizontal padding. |

### 3.4 Shadows and elevation

Light mode only. SwiftUI has no spread, so these approximate the web `--shadow-card` (`0 1 2 rgba(12,21,18,.04), 0 8 24 -12 rgba(12,21,18,.12)`):

| Token | Layers (color `#0C1512`) | Use |
|---|---|---|
| `shadowCard` | 5% opacity, radius 2, y 1 + 8% opacity, radius 16, y 8 | Cards on `canvas`. |
| `shadowHero` | 20% opacity, radius 24, y 12 | BalanceCard. |
| `shadowFloating` | 16% opacity, radius 20, y 10 | Toast/banner overlays. |

Dark mode: no shadows; use the surface ladder (§1.4) and `cardBorder`. Cards inside sheets get no shadow in either mode (border only).

---

## 4. Components

Every component lives in DesignSystem, takes plain values (no API types), and supports light, dark, Increase Contrast and every Dynamic Type size. "States" lists every state the component must render.

### 4.1 BalanceCard

The near-black hero on Home.

- **Container:** `heroSurface`, `radiusHero`, padding 20, `shadowHero` (light) or 1pt `heroBorder` (dark).
- **Content, top to bottom:**
  1. `eyebrow` "Total balance" in `heroTextSecondary`.
  2. Amount: MoneyText `exact`, `displayHero`, `heroText`, `.contentTransition(.numericText(value:))`.
  3. Sub-line, `subheadline`, `heroTextSecondary`: "Available {available} · In goals {inGoals}" (`amountSmall` for the two amounts). Wraps to two lines at large sizes.
  4. Only when `pendingCents > 0`: SF Symbol `clock` + "{pending} processing", `subheadline`, `heroTextSecondary`.
  5. `heroDivider` 1pt, 16pt above and below.
  6. Quick actions row (§4.2): Add money, Move to goal, Cash out, History. Evenly spaced `HStack`; at accessibility sizes a 2 × 2 grid.
- **States:**
  - Loading: same container; skeleton bars (`#FFFFFF` at 10%) for eyebrow, amount (60% width, 40pt tall) and sub-line; quick actions visible but disabled. VoiceOver: "Loading your balance…".
  - Loaded.
  - Stale (`balanceUnavailable == true`): amounts shown, plus a line with SF Symbol `exclamationmark.circle` "Showing your last known balance. We'll update it shortly." in `heroTextSecondary`.
  - Error (request failed, no data): no amount. Title "We couldn't load your balance" (`headline`, `heroText`), a small "Try again" button (white capsule, `heroActionGlyph` text). Quick actions stay enabled except Move to goal.
- **Accessibility:** the amount block is one element: label "Total balance", value "{total, full name}" (for example "1,240.50 US dollars"), then "Available {…}. In goals {…}." Quick actions are separate buttons.

### 4.2 QuickActionButton

- 56pt circle `heroAction` with a 22pt semibold SF Symbol in `heroActionGlyph`; label below in `footnoteEmphasis` `heroText`, 8pt gap, centered, up to 2 lines.
- **States:** enabled; pressed (circle scale 0.94, 0.12s); disabled (circle and label at 40% opacity, VoiceOver "dimmed"); hidden never (all four always present).
- Actions and symbols: Add money `plus`, Move to goal `target`, Cash out `arrow.up.right`, History `clock.arrow.circlepath`.
- VoiceOver label = the visible label; the button is the whole column.

### 4.3 MoneyText

- Input: cents (`Int`), presentation (`exact` / `wholeIfRound`), direction (`none` / `in` / `out`), style token, color token.
- Renders per §2.3 with `.monospacedDigit()`.
- **States:** value; unavailable (renders nothing; the parent shows an error, never `$0.00`).
- **Accessibility:** `accessibilityLabel` uses the same Decimal with `.presentation(.fullName)` ("1,240.50 US dollars"); direction adds a word before it: in → "plus", out → "minus".

### 4.4 GoalCard

Two layouts from the same data.

- **Tile** (Savings grid, Home preview): `surface`, `radiusCard`, padding 16, `shadowCard`/`cardBorder`.
  1. Icon well 44 (`jadeTint`, symbol in `jadeText`) and, top-right, PlanPill (§4.6).
  2. Name, `headline`, 2 lines max.
  3. Saved: MoneyText `exact`, `title3`.
  4. "of {target}", `amountSmall` `wholeIfRound`, `textSecondary`.
  5. ProgressBar (§4.5), height 8.
  6. "{percent}% · by {date}", `footnote`, `textSecondary`.
- **Row** (Move to goal picker, accessibility sizes): `HStack` icon well, name + "{saved} of {target}", trailing percent; ProgressBar full width underneath.
- **States:** loaded; "may be out of date" (`goal.balanceUnavailable`): footnote line in `amberText` with `exclamationmark.circle`: "May be out of date"; reached (PlanPill "Goal reached", ProgressBar full); pressed (scale 0.98, 0.12s; Reduce Motion: opacity 0.9 only); skeleton (§4.20).
- **Accessibility:** one element, label "{name}", value "{saved full} saved of {target full}. {percent} percent. {plan status}." Hint "Opens goal." Trait button.

### 4.5 ProgressBar

- Capsule track `progressTrack`, capsule fill `progressFill`, width = `min(saved / target, 1)`; if `saved > 0`, minimum visible fill is 4pt.
- **States:** empty (track only), partial, full, unknown (hidden while loading).
- Animates from 0 to value on first appearance (0.6s ease-out); no animation with Reduce Motion.
- **Accessibility:** wrapped in its parent element; standalone use: label "Progress", value "{percent} percent".

### 4.6 PlanPill (goal pace)

A StatusPill variant (§4.15) that says how a goal is doing against its plan. Computed on device from `targetCents`, `savedCents`, `createdAt`, `deadline`, `frequency`, using the **same progressive plan as the web** (`artifacts/moolahub-app/src/lib/contribution-plan.ts`; port `periodsBetween`, `progressivePlan`, `nextContribution` exactly, including `MAX_PERIODS = 520` and the remainder-to-the-end rule; port its tests too).

Let `plan = progressivePlan(target, periodsBetween(createdAt, deadline, frequency))`, `cumulative(k)` the sum of the first k steps, `stepsDone` = the largest k with `cumulative(k) ≤ saved`, and `elapsed` = whole periods since `createdAt` (daily: whole days; weekly: whole days ÷ 7, floored; monthly: whole calendar months), clamped to `plan.count`. Then, in order:

| Condition | Pill | Tone | Symbol |
|---|---|---|---|
| `saved ≥ target` | "Goal reached" | jade | `checkmark.seal.fill` |
| now is after the deadline | "Past target date" | amber | `calendar.badge.exclamationmark` |
| `elapsed − stepsDone ≤ 0` | "On track" | jade | `checkmark` |
| otherwise, `n = elapsed − stepsDone` | "{n} day/days behind", "{n} week/weeks behind", "{n} month/months behind" (by frequency; plural via String Catalog) | amber | `clock` |

Unknown `frequency` values are treated as weekly (same as the web's `asFrequency`).

### 4.7 CircleCard (group)

- `surface`, `radiusCard`, padding 16.
  1. Top row: icon well 44 (`fill`, `person.3.fill` in `textPrimary`), name `headline`, StatusPill for status: Forming (neutral, `hourglass`), Active (jade, `circle.fill` 8pt dot), Completed (neutral, `checkmark`).
  2. Type label `footnote` `textSecondary`: "Take turns" or "Save together", then " · Weekly" / " · Every 2 weeks" / " · Monthly".
  3. Two facts in an `HStack` (stack vertically at accessibility sizes), each an `eyebrow` over a `amountRow`:
     - "Each round" → `contributionCents` (`exact`).
     - Take turns: "Your payout" → `payoutCents`; Save together: "You get back" → `payoutCents`.
  4. Footer `footnote` `textSecondary`:
     - Active: "Round {current} of {total}" and, take turns only, " · Your turn: round {myPayoutRound}".
     - Forming with `targetMembers`: "{memberCount} of {targetMembers} joined. Starts when everyone joins."
     - Forming without: "{memberCount} joined. Not started yet."
     - Completed: "Finished".
- **States:** loaded, pressed, skeleton.
- **Accessibility:** one element: "{name}. {type}, {frequency}. {status}. Each round {amount}. {payout label} {amount}. {footer}." Hint "Opens group."

### 4.8 InviteCard

For pending invites (`GET /circles/invites`).

- `surface`, `radiusCard`, padding 16. `eyebrow` "Invitation", name `headline` (`circleName`), "{inviterName} invited you" `subheadline` `textSecondary`, "{contribution} {frequency word}" `amountRow` (`exact`; frequency word: "weekly", "every 2 weeks", "monthly").
- Buttons: small PrimaryButton "Accept", small SecondaryButton "Decline", side by side (stacked at accessibility sizes).
- **States:** idle; accepting/declining (that button shows a spinner, both disabled); error (inline red footnote with the server message, buttons re-enabled).

### 4.9 MemberRow

- Avatar 36 with initials from the username (first two letters, uppercase), name "@{name}" `headline`, and " (you)" in `textSecondary` for the current user (match `name` to the signed-in user's `username`, case-insensitive; if the user has no username, mark no one).
- The API's `name` is the member's username, or exactly `"Member"` when they have none (usernames are stored lowercase, so a capitalized `"Member"` is always the fallback). Show the fallback as "Member" with no "@" and the avatar symbol `person.fill` instead of initials.
- Secondary line `subheadline` `textSecondary`:
  - Take turns: state `paid` → "Received payout", `current` → "Receiving this round", `upcoming` → "Payout in round {payoutRound}".
  - Save together: "Saving".
- Trailing, only when the group is active: StatusPill "Paid in" (jade, `checkmark`) if `contributedThisRound`, else "Not yet" (neutral, `circle.dashed`).
- Row height ≥ 56. VoiceOver: one element, "{name}{, you}. {secondary}. {pill}."

### 4.10 RoundTimeline

**Take turns:** vertical list of members ordered by `payoutRound`, one node per round.
- Node 20pt on a 2pt vertical line (`divider`):
  - `paid`: filled `progressFill` circle with white `checkmark` (10pt bold).
  - `current`: `progressFill` ring 3pt with an inner dot.
  - `upcoming`: `controlBorder` ring 1.5pt.
- Text: "Round {n}" `eyebrow`, member "@{name}" `headline` (+ " (you)"), state `subheadline`: "Received", "Receiving now", "Up next" (the round right after current), "Upcoming".
- The current user's row has a `jadeTint` background (`radiusMedium`) and a jade pill "Your turn" when their round is current.
- VoiceOver: each row one element: "Round {n}, {name}, {state}{, your turn}."

**Save together:** no per-member order. Show a ProgressBar (height 10) of `currentRound / totalRounds`, label "Round {current} of {total}", and below it "Everyone gets their own savings back after round {total}." For a completed group: "Savings returned."

### 4.11 PrimaryButton and SecondaryButton

| | PrimaryButton | SecondaryButton | Destructive |
|---|---|---|---|
| Fill | `ctaBackground` | `secondaryButtonBackground` + 1pt `controlBorder` | `destructiveFill` |
| Label | `headline`, `ctaForeground` | `headline`, `textPrimary` | `headline`, `destructiveForeground` |
| Shape | capsule, full width, min height 56 | same | same |

- **Enabled.**
- **Pressed:** fill → `ctaPressed` (secondary: `fill`), scale 0.98, 0.12s.
- **Disabled:** `ctaDisabledBackground` + `ctaDisabledForeground` (secondary: border and label at 40% opacity). Not tappable. VoiceOver "dimmed". A disabled main button always has a visible reason nearby (helper or error text).
- **Loading:** label replaced by a `ProgressView` tinted with the label color plus the progressive verb ("Signing in…", "Confirming…"); same size; not tappable; VoiceOver label is the progressive verb.
- **Destructive:** only for delete and sign-out confirmations.
- Optional leading SF Symbol (for example `faceid` on "Confirm with Face ID").
- Labels are verb-first and sentence case (§9).

### 4.12 AmountEntry

USD only, 2 decimals, custom keypad (so the decimal separator is always ".", whatever the region).

- **Display:** `displayEntry`, centered. Empty shows "$0" in `textSecondary`. Typing shows "$" + grouped whole part + the typed fraction exactly as typed (`12.` → `$12.`, `1234.5` → `$1,234.5`). `.lineLimit(1)`, `.minimumScaleFactor(0.4)`.
- **Context line** under the display, `subheadline` `textSecondary`: for example "Available $1,240.50", "In this goal $300.00", "Up to $1,000.00 at a time".
- **Preset chips** (capsule, `fill`, `subheadlineEmphasis`, min height 36): tapping replaces the buffer. A chip whose amount exceeds the max is disabled. "All" sets the max exactly.
- **Keypad:** 3 × 4 grid `1 2 3 / 4 5 6 / 7 8 9 / . 0 ⌫` (`⌫` = SF Symbol `delete.left`), `keypad` font, no key background, pressed state `fill` in `radiusSmall`.
- **Buffer rules:**
  - Digits only, at most one ".", at most 2 digits after ".", at most 7 digits before it.
  - A leading "0" followed by a digit is replaced (`0` then `5` → `5`); "." on an empty buffer gives `0.`.
  - ⌫ removes the last character; long-press ⌫ clears.
  - A rejected key does nothing and plays the `.warning` haptic.
  - Cents = whole × 100 + fraction padded to 2 digits, in `Int`. No floating point at any step.
- **Validation** (shown under the context line in `redText` `footnote`, and the main button disabled):
  - Empty or 0: no message, button disabled.
  - Below the minimum: "Enter at least {min}."
  - Above the max, by context:
    - Available balance: "You don't have enough available for that. Add money or choose a smaller amount."
    - Goal saved: "That's more than this goal has."
    - Test money: "You can add up to $1,000.00 of test money at a time."
- **Accessibility:** the display is one element, label "Amount", value "{full name}" or "empty"; keys are buttons labelled "1"…"9", "0", "decimal point", "delete" (long-press action named "Clear"). Keys show the Large Content Viewer (`.accessibilityShowsLargeContentViewer()`). At accessibility sizes the keypad sits in a `ScrollView` with the main button pinned.

### 4.13 ReviewSheet (step)

The last step before a money move.

- Title "Review" (`title2`).
- Amount: MoneyText `exact`, `displayAmount`, centered.
- Details card (`surfaceRaised`, `radiusLarge`, rows separated by `divider`), each row label `subheadline` `textSecondary` left and value `bodyEmphasis` / `amountRow` right (stacked at accessibility sizes). Rows, in this order, as each flow defines (§7): From, To, Round, Fee, You receive.
- Fee row: "No fee" when the fee is 0, else MoneyText `exact`.
- Optional footnote under the card (`footnote` `textSecondary`), for example "Pay-ins can't be undone."
- Main button: "Confirm with Face ID" / "Confirm with Touch ID" / "Confirm with Optic ID" / "Confirm with passcode" (from `LAContext.biometryType` after `canEvaluatePolicy(.deviceOwnerAuthentication)`), or "Confirm" when the device has no passcode. Leading symbol `faceid` / `touchid` / `opticid` / `lock`.
- Secondary text button "Edit amount" (goes back one step).
- **Confirm sequence:**
  1. `LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Confirm this money move")`.
  2. On success, send the request. The button shows "Confirming…", the sheet is `interactiveDismissDisabled(true)` and the back control is hidden.
  3. User cancels Face ID: stay on Review, footnote in `textSecondary`: "Cancelled. Nothing was taken."
  4. Request fails: ErrorBanner (§4.22) above the button (copy in §9.4), button back to idle, amount kept.
  5. Success: go to Receipt.
- The Face ID step is a convenience gate; the server's session is the authority. Moves that need the server's step-up use §4.14 instead.

### 4.14 StepUpStep ("Confirm it's you")

Used where the server requires fresh proof: Move to balance, Delete goal, Change password.

- Title "Confirm it's you" (`title2`).
- Body (`callout` `textSecondary`), by what the account has:
  - Password only: "Enter your password to continue."
  - Password and authenticator: "Enter your password and the 6-digit code from your authenticator app."
- Fields: "Password" (secure, `.textContentType(.password)`, show/hide eye button labelled "Show password" / "Hide password"); "Authenticator code" only if 2FA is on (`.keyboardType(.numberPad)`, `.textContentType(.oneTimeCode)`, placeholder "6-digit code").
- Main button: the action verb ("Move to balance", "Delete goal", "Save password"); loading "Confirming…" / "Deleting…" / "Saving…".
- Errors: the server's 401 messages ("Your password is incorrect.", "That two-factor code didn't match.", "Please confirm your password to continue.") shown inline in `redText` under the fields. **A 401 here does not sign the user out** (§11).
- 2FA status comes from `GET /security/2fa` (`enabled`). Load it when the sheet opens; while loading, show the password field only and disable the button.

### 4.15 StatusPill

Capsule, horizontal padding 10, vertical 4, SF Symbol 11pt + `footnoteEmphasis` label, tint background + text color of the tone:

| Tone | Background | Text and symbol |
|---|---|---|
| jade | `jadeTint` | `jadeText` |
| amber | `amberTint` | `amberText` |
| red | `redTint` | `redText` |
| neutral | `neutralTint` | `textSecondary` |

Money-move statuses from `onchainStatus`:

| `onchainStatus` | Label | Tone | Symbol | VoiceOver |
|---|---|---|---|---|
| `none` or `confirmed` | "Done" | jade | `checkmark` | "Done" |
| `pending` | "Processing…" | amber | `clock` | "Processing" |
| `failed` | "Didn't go through" | red | `xmark` | "Didn't go through, nothing was taken" |
| anything else | "Processing…" | amber | `clock` | "Processing" |

(`none` means the move settled on the ledger with nothing left to do, so it is Done.) Unknown values never show "Done".

### 4.16 Receipt (step)

- Top: 64pt symbol. Done: `checkmark.circle.fill` in `jadeFill`. Processing: `clock.fill` in `amberText`. With `.symbolEffect(.bounce)` once on appear (not with Reduce Motion).
- Title `title2`, past tense, from the flow (§7).
- Amount `displayAmount`.
- Details card: same rows as Review, plus "Date" (date and time) and "Status" (StatusPill).
- If Processing: `footnote` `textSecondary` "This can take a few minutes. We'll show it in Activity when it's done."
- Buttons: PrimaryButton "Done" (dismisses the sheet). Optional SecondaryButton named per flow ("View goal", "View activity").
- **How the status is decided (no guessing):** the money endpoints return only `{ ok: true }` (release and delete add amounts). The receipt opens as "Processing…", then fetches `GET /activity?limit=10` at 0s, 1s and 3s and looks for the newest item with the expected `type` and signed `amountCents` whose `createdAt` is no earlier than 5 seconds before the request was sent. When found, it shows that item's status (§4.15). If none is found after the third try it stays "Processing…" with the footnote above.
- Success haptic `.success` when the receipt appears.

### 4.17 ActivityRow

- `HStack`: icon well 40 circle (`fill` + `textPrimary` symbol; money-in types use `jadeTint` + `jadeText`), title, trailing amount.
- Title (`headline`, 2 lines): the server's `description` (already plain language, for example "Moved to Vacation", "Test money added", "Family group · round 3").
- Subtitle (`subheadline` `textSecondary`): time (or date and time on goal history), then StatusPill inline when the status is not Done.
- Amount: MoneyText `exact`, `amountRow`, direction from the sign of `amountCents` (positive in, negative out). A `failed` row's amount is `textSecondary` with strikethrough. Null amount: no amount shown.
- Type → symbol (and the word VoiceOver uses):

| `type` | Symbol | Word |
|---|---|---|
| `deposit` | `plus` | Money added |
| `payout` | `arrow.down.left` | Your payout |
| `yield` | `chart.line.uptrend.xyaxis` | Earnings |
| `contribution` | `person.3.fill` | Paid in |
| `goal_allocate` | `target` | Moved to goal |
| `goal_release` | `arrow.uturn.backward` | Moved to balance |
| `withdrawal` | `arrow.up.right` | Cash out |
| `fee` | `percent` | Fee |
| `referral_earning`, `referral_withdrawal` | `gift` | Invite reward |
| anything else | `arrow.left.arrow.right` | Money moved |

- **Accessibility:** one element: "{word}. {description}. {plus/minus} {amount full name}. {status}. {time}."

### 4.18 EmptyState

- Centered stack, 64pt from the top of its area: SF Symbol 40pt in `textSecondary` inside an 80pt `fill` circle, title `title2`, body `callout` `textSecondary` (max 3 lines, centered), optional PrimaryButton (not full width: hugs label, min width 200).
- Copy per screen in §8. Pattern: what's here + the one action.

### 4.19 ErrorState

- Same layout as EmptyState with symbol `wifi.exclamationmark` (network) or `exclamationmark.triangle` (other).
- Title "We couldn't load this" (or screen-specific, §8), body from §9.4, SecondaryButton "Try again" (loading: "Trying again…").
- Never shows stale zeros: if a screen had data and a refresh fails, keep the data and show an ErrorBanner instead.

### 4.20 LoadingPlaceholder (skeleton)

- Shapes only, no placeholder text or numbers: rounded rectangles in `fill` that match the real layout (card outlines, a 60%-wide bar for amounts, two text bars for rows).
- Pulse opacity 1 → 0.55 → 1 over 3s (web `pulse-soft`); static with Reduce Motion.
- The whole skeleton is one accessibility element with the screen's loading label ("Loading your goals…") and the skeleton shapes are hidden from VoiceOver. Don't use `.redacted` on dummy data (VoiceOver can read dummy strings).

### 4.21 DisclosureFooter

- `footnote` `textSecondary`, centered under the BalanceCard: "Held as USDC · Not a bank deposit · Not insured" followed by SF Symbol `info.circle`.
- It is a button: opens a sheet titled "About your balance" with the full disclosure (§9.5) and a "Done" button.
- VoiceOver label: "Held as USDC. Not a bank deposit. Not insured." Hint: "Shows details."

### 4.22 ErrorBanner and Toast

- **ErrorBanner** (inline, inside a screen or sheet): `redTint`, `radiusMedium`, padding 12, SF Symbol `exclamationmark.triangle.fill` `redText`, message `subheadline` `textPrimary`, optional trailing text button "Try again" in `redText`. Announced with `AccessibilityNotification.Announcement`.
- **Toast** (non-blocking confirmation, for example "Password updated."): `surface` capsule with `shadowFloating`, SF Symbol `checkmark.circle.fill` `jadeFill`, `subheadlineEmphasis`, slides in from the top, stays 3s, tap to dismiss. Reduce Motion: fade. Announced to VoiceOver. Never used for money moves (those have receipts).

### 4.23 SectionHeader

- `HStack`: title `title3` `textPrimary` (optional `eyebrow` above it), trailing optional text button `subheadlineEmphasis` `jadeText` ("See all"). Marked `.accessibilityAddTraits(.isHeader)`. 12pt above content.

### 4.24 TechnicalDetailsRow

- Only rendered when the Technical details toggle is on.
- Label `eyebrow` `textSecondary`; value `mono` `textPrimary`, `.lineLimit(1)`, `.truncationMode(.middle)`, `.textSelection(.enabled)`; trailing small button "Copy" (SF Symbol `doc.on.doc`) that copies the full value and switches to "Copied" with `checkmark` for 2s (and announces "Copied").
- VoiceOver reads the full value (not the truncated one).

### 4.25 Form fields

- `fill` background, 1pt `controlBorder`, `radiusMedium`, min height 52, label above in `subheadlineEmphasis` `textPrimary`, optional hint below in `footnote` `textSecondary`, error below in `footnote` `redText` (and border `redText`).
- Focused: border 2pt `jadeText`. Disabled: 40% opacity.
- Placeholders in `textSecondary` start with "e.g." when they're examples.
- Labels say "· optional" when optional ("Nationality · optional").

---

## 5. Iconography

SF Symbols only, weight matched to the adjacent text (`.semibold` with headlines, `.regular` with body). All symbols listed exist on iOS 17.

| Where | Symbol |
|---|---|
| Tab: Home | `house` |
| Tab: Savings | `target` |
| Tab: Groups | `person.3` |
| Tab: Activity | `clock.arrow.circlepath` |
| Tab: Account | `person.crop.circle` |
| Add (toolbar) | `plus` |
| More (toolbar menu) | `ellipsis.circle` |
| Close (sheets) | `xmark` (system close button) |

**Goal icons.** The API stores a goal's icon in `emoji` (the web shows emoji). iOS shows SF Symbols and writes the paired emoji so the web keeps working. Exact strings, including variation selectors:

| SF Symbol | `emoji` sent / matched | Picker label |
|---|---|---|
| `target` | `🎯` (U+1F3AF) | Goal |
| `house.fill` | `🏠` (U+1F3E0) | Home |
| `car.fill` | `🚗` (U+1F697) | Car |
| `airplane` | `✈️` (U+2708 U+FE0F) | Travel |
| `graduationcap.fill` | `🎓` (U+1F393) | Education |
| `umbrella.fill` | `☂️` (U+2602 U+FE0F) | Emergency fund |
| `heart.fill` | `❤️` (U+2764 U+FE0F) | Wedding |
| `gift.fill` | `🎁` (U+1F381) | Gift |
| `briefcase.fill` | `💼` (U+1F4BC) | Business |
| `cross.case.fill` | `🏥` (U+1F3E5) | Health |
| `pawprint.fill` | `🐾` (U+1F43E) | Pets |
| `laptopcomputer` | `💻` (U+1F4BB) | Tech |

Match incoming `emoji` after removing U+FE0F from both sides. Anything unmatched (goals made on the web) shows `target`. Send `color: "jade"` on create. Goal images (`imageUrl`) are not shown in this build.

**Brand assets** (architect adds to the asset catalog): wordmark `artifacts/moolahub-app/public/brand/moolahub_logo_horizontal.svg` (light) and `moolahub_logo_horizontal_dark.svg` (dark), app icon `artifacts/moolahub-app/public/brand/moolahub_app_icon.png` (1024 × 1024). The mark alone is the first four paths of the wordmark SVG (viewBox `30 30 150 150`, see `src/components/brand/Logo.tsx`). User-facing name: **MoolaHub** (as on the web and in the logo).

---

## 6. App structure and navigation

- **Root:** signed out → Auth flow (`NavigationStack`: Welcome → Sign up / Sign in → …). Signed in → App lock (if on and locked) → `TabView`.
- **Tabs (system `TabView`, 5 tabs, this order):** Home · Savings · Groups · Activity · Account. One `NavigationStack` per tab, each with its own path, preserved when switching tabs. Re-tapping the selected tab pops that tab's stack to its root (drive it from the tab selection binding; don't rely on the system to do it).
- **Large titles** on tab roots (Savings, Groups, Activity, Account). Home has no navigation title; it starts with its greeting header. Pushed screens use inline titles.
- **Sheets** for every money move and every create flow: `.presentationDetents([.large])`, `.presentationDragIndicator(.visible)`, background `sheetCanvas` (`.presentationBackground`), close button `xmark` top-leading, multi-step flows use a `NavigationStack` inside the sheet with a back button. Dismissal is blocked (`interactiveDismissDisabled`) while a request is in flight, and after the first step a swipe-down asks "Discard this?" with "Discard" (destructive) and "Keep editing".
- **Confirmation dialogs** (`.confirmationDialog`) for destructive or committing actions: delete group, start group, accept invite, decline invite, sign out.
- **Privacy cover:** when `scenePhase` is not `.active`, cover the whole window with `canvas` and the centered mark (no blur, which can leak content).
- **Session expiry:** see §11.

---

## 7. Money-move flows

Every flow is a sheet. Steps in order; copy is final.

### 7.1 Add test money (dev build only)

Entry: Home quick action "Add money".
1. **Amount.**
   - Title "Add test money".
   - Banner (`amberTint`, `radiusMedium`, SF Symbol `testtube.2` `amberText`): eyebrow "Test money", text "This is a test version of MoolaHub. Test money isn't real and can't be cashed out."
   - AmountEntry: min $0.01, max $1,000.00, context line "Up to $1,000.00 at a time", presets $50 · $100 · $250 · $500.
   - Button "Add test money" (loading "Adding…").
   - No Review, no Face ID: nothing leaves the user's money.
2. **Receipt.**
   - Title "Test money added".
   - Rows: To "Balance".
   - Expected activity: `type == "deposit"`, `amountCents == +amount`.
   - Button "Done".
- API: `POST /wallet/deposit {amountCents}`. A 403 shows the server's message ("Test money isn't available right now.") in an ErrorBanner.

### 7.2 Move to goal

Entry: Home quick action "Move to goal" (starts at step 1), Goal detail "Move to goal" (starts at step 2).
1. **Choose a goal.** Title "Move to goal", subtitle "Choose a goal". List of GoalCard rows. If there are no goals: EmptyState "No goals yet" / "Create a goal first, then move money into it." / button "Create goal" (closes this sheet, opens Create goal).
2. **Amount.**
   - Title "Move to goal", subtitle "{goal name}".
   - Context "Available {availableCents}"; max = `availableCents` from `GET /wallet`, fetched when the sheet opens. While it loads the keypad is disabled. If it fails: ErrorState with "Try again"; never assume 0.
   - Presets: "Next step {amount}" (from `nextContribution`, only if it exists and ≤ available), $10 · $25 · $50 · "All".
   - Button "Review".
3. **Review.** Rows: From "Balance", To "{goal name}", Fee "No fee". Confirm with Face ID (§4.13).
4. **Receipt.**
   - Title "Moved to {goal name}".
   - Rows: From "Balance", To "{goal name}".
   - Secondary button "View goal" (only when started from Home).
   - Expected activity: `goal_allocate`, `−amount` (it's a wallet debit).
- API: `POST /goals/{id}/allocate {amountCents}`.

### 7.3 Move to balance

Entry: Goal detail "Move to balance".
1. **Amount.**
   - Title "Move to balance", subtitle "{goal name}".
   - Context "In this goal {savedCents}"; max = `savedCents`.
   - Presets $10 · $25 · $50 · "All".
   - Button "Review".
2. **Review.**
   - Rows: From "{goal name}", To "Balance", Fee, You receive.
   - Fee = `floor(amount × feeBps / 10000)` with `feeBps` from the goal (same rounding as the server); You receive = amount − fee.
   - Footnote only when `feeBps > 0`: "A {pct}% fee applies when you move money out of a goal."
   - Button "Continue" (no Face ID here; the next step is stronger).
3. **Confirm it's you.** StepUpStep (§4.14), main button "Move to balance".
4. **Receipt.**
   - Title "Moved to your balance".
   - Rows from the **server response**: Amount (`grossCents`), Fee (`feeCents`, "No fee" if 0), You received (`netCents`). If they differ from the preview, the server's numbers are what's shown.
   - Expected activity: `goal_release`, `+netCents`.
- API: `POST /goals/{id}/release {amountCents, currentPassword, twoFactorCode?}`.

### 7.4 Delete goal

Entry: Goal detail toolbar menu (`ellipsis.circle`) → "Delete goal" (destructive).
1. **Confirm.**
   - Title "Delete goal".
   - Body by case:
     - Saved is 0: "This permanently closes the goal."
     - Saved > 0 and `feeBps == 0`: "This moves the full {saved} back to your balance and closes the goal."
     - Saved > 0 and `feeBps > 0`: "This moves the full {saved} back to your balance, minus the {pct}% fee, and closes the goal."
   - Then the StepUpStep fields inline, and a destructive button "Delete goal" (loading "Deleting…"). The server requires step-up even for an empty goal.
2. **Receipt** (only when money moved, `withdrawnGrossCents > 0`): title "Goal deleted", rows Amount (`withdrawnGrossCents`), Fee (`feeCents`), You received (`withdrawnNetCents`). When nothing moved: dismiss, pop to Savings, Toast "Goal deleted."
- API: `POST /goals/{id}/delete {currentPassword, twoFactorCode?}`.

### 7.5 Pay in (group contribution)

Entry: Group detail button "Pay in {contribution}" (shown when `canContribute`).
1. **Review** (the amount is fixed, no keypad).
   - Title "Pay in", subtitle "{group name}".
   - Amount `contributionCents`.
   - Rows: From "Balance", To "{group name}", Round "{currentRound} of {totalRounds}", and when `feeBps > 0` a row Fee with value "Included ({pct}%)".
   - Footnote "Pay-ins can't be undone."
   - If available < contribution (from `GET /wallet`), the confirm button is disabled with `redText` "You need {contribution} available to pay in. Add money first." and a SecondaryButton "Add test money" that opens §7.1.
   - Confirm with Face ID.
2. **Receipt.**
   - Title "Paid in to {group name}".
   - Rows: Round, Status.
   - Expected activity: `contribution`, `−contributionCents`.
- API: `POST /circles/{id}/contribute` with body `{}`.

### 7.6 Cash out (not in this build)

Home quick action "Cash out" opens a small sheet (`.medium` detent):
- Title "Cash out".
- Body: "Cashing out isn't available yet. We'll let you know when it is."
- Button "Done".
- No API call.

---

## 8. Screens

Each screen lists data, layout top to bottom, actions, and states. Pull to refresh on every tab root and on Goal detail and Group detail. Loading = skeleton of that layout (§4.20), error = ErrorState (§4.19) unless noted.

### 8.1 Welcome

- **Layout:**
  - Mark (64pt) and wordmark at the top (40pt from the safe area).
  - Headline (`titleLarge`, two lines): "Save today." / "Reach it together."
  - Body (`callout` `textSecondary`): "Personal goals and group savings in one place. Every move has a receipt."
  - Three feature rows (SF Symbol in a 36pt `jadeTint` circle + `body`):
    - `target` "Goals with a plan you can keep"
    - `person.3.fill` "Save in groups with people you trust"
    - `checkmark.shield.fill` "You confirm every payment and move"
  - Bottom: PrimaryButton "Create account", SecondaryButton "Sign in".
  - Debug builds only, under the buttons, a `footnote` chip: SF Symbol `server.rack`, "Server: {host:port}" and the text button "Change" → Developer settings (§8.24) as a sheet. This is how you point a physical iPhone at the Mac before signing in.
- **States:** static. No data, no mock balances.

### 8.2 Sign up

API: `POST /auth/register {name, username, email, password, dateOfBirth, rememberMe: true}`; `GET /auth/username-available?username=`.

- **Header:** title "Create your account" (`title1`), subtitle "It takes about a minute." (`callout` `textSecondary`).
- **Fields:**
  - "Legal name · private". `.textContentType(.name)`, placeholder "e.g. Ama Mensah". Required.
  - "Username · public". Leading "@" adornment. `.textContentType(.username)`, autocapitalization off, autocorrection off. Hint "3–30 letters, numbers or underscores". Live check 400ms after typing stops: trailing "Checking…" / `checkmark` "Available" in `jadeText` / `xmark` "Taken" in `redText`.
  - "Email". `.textContentType(.emailAddress)`, email keyboard, autocapitalization off.
  - "Password". `.textContentType(.newPassword)`, show/hide. Hint "At least 8 characters".
  - "Date of birth · private". `DatePicker` (`.compact` style), date only, range up to yesterday, no default value: it shows "Choose a date" until set. The API requires it.
- **Main button:** "Create account" (loading "Creating account…"). Disabled until every field is valid; the first invalid field shows its error on submit.
- **Footer:** "Already have an account?" + text button "Sign in".
- **Field errors** (shown on submit or blur):
  - "Please enter your legal name."
  - "Username must be 3–30 characters: letters, numbers or underscores."
  - "Please enter a valid email address."
  - "Password must be at least 8 characters."
  - "Please enter your date of birth."
- **Server errors** (409 etc.) show verbatim in an ErrorBanner ("An account with this email already exists. Please sign in.", "That username is already taken.").
- **Success** → Verify email code with the email.

### 8.3 Verify email code

API: `POST /auth/verify-email {email, code, rememberMe: true}`; `POST /auth/resend-code {email}`.

- Title "Verify your email". Body "We sent a 6-digit code to **{email}**. It expires in 15 minutes."
- One code field: `.keyboardType(.numberPad)`, `.textContentType(.oneTimeCode)` (so the code can be filled from Mail), `mono` 28pt, letter-spaced, max 6 digits. Submits automatically when 6 digits are entered.
- Main button "Verify and continue" (loading "Verifying…").
- Text button "Resend code". After tapping, it's disabled for 30s, showing "Resend in {s}s" (the server's cooldown is 30s), then "A new code is on its way."
- Error "That code is invalid or has expired." (server message) inline; the field clears.
- Success: if `twoFactorRequired` → Two-factor code; else signed in → App lock offer (§8.7) → Home.

### 8.4 Sign in

API: `POST /auth/login {email, password, rememberMe: true}`.

- Title "Welcome back". Subtitle "Sign in to keep your savings on track."
- Fields: "Email" (`.textContentType(.username)` so Passwords autofill pairs it), "Password" (`.textContentType(.password)`, show/hide).
- Text button "Forgot password?" (right-aligned, under password).
- Main button "Sign in" (loading "Signing in…").
- Footer "New to MoolaHub?" + text button "Create an account".
- **Results:**
  - `twoFactorRequired` → Two-factor code with `challengeId`.
  - `emailVerificationRequired` → Verify email code.
  - Otherwise signed in → App lock offer (first sign-in on this device) → Home.
- **Errors:** 401 "Invalid email or password." and 429 "Too many failed attempts. Please try again later." in an ErrorBanner; the password field clears, the email stays.
- **Banners on arrival:** after a password reset, a jade banner "Your password has been reset. Sign in with your new password." After a session expiry, a neutral banner "You've been signed out. Please sign in again."

### 8.5 Two-factor code

API: `POST /auth/2fa/login {challengeId, code}`.

- Title "Two-factor authentication". Body "Enter the 6-digit code from your authenticator app, or a backup code."
- Field: number pad by default (`.oneTimeCode`). Text button "Use a backup code" switches to the default keyboard, autocapitalization off, placeholder "e.g. 1a2b-3c4d". Toggle back with "Use an authenticator code".
- Main button "Verify and sign in" (loading "Verifying…").
- **Errors:**
  - 401 "That code didn't match. Try a current code or a backup code." inline.
  - 400 "Your verification session expired. Please sign in again." → back to Sign in with that message.

### 8.6 Forgot password

API: `POST /auth/forgot-password {email}`, `POST /auth/reset-password {email, code, newPassword}`.

1. **Step 1.**
   - Title "Forgot your password?". Body "Enter your email and we'll send you a reset code."
   - Field "Email". Button "Send reset code" (loading "Sending…").
   - Errors verbatim (404 "We couldn't find an account with that email address.", 429).
2. **Step 2.**
   - Title "Reset your password". Body "A 6-digit code is on its way to **{email}**. Enter it with a new password."
   - Fields:
     - "Reset code" (`.oneTimeCode`).
     - "New password" (`.newPassword`, hint "At least 8 characters").
     - "Confirm new password". Mismatch error: "Passwords don't match."
   - Button "Reset password" (loading "Resetting…"). "Resend code" as in §8.3.
   - Success → Sign in with the reset banner.

### 8.7 App lock

- **Offer** (one time per device, after the first successful sign-in, as a sheet with `.medium` detent):
  - Title "Use Face ID to open MoolaHub". Body "Your money stays private if someone picks up your phone."
  - Buttons "Turn on Face ID" (evaluates once to confirm it works, then saves) and "Not now".
  - The biometry name adapts (Face ID / Touch ID / Optic ID / passcode).
  - If the device has no passcode, skip the offer.
- **Lock screen** (full screen, `canvas`):
  - Mark 64pt. Title "MoolaHub is locked". Button "Unlock with Face ID" (biometry-aware; leading symbol).
  - Text button "Sign out" (asks "Sign out of MoolaHub?" first).
  - Evaluation (`.deviceOwnerAuthentication`, reason "Unlock MoolaHub") starts automatically once when the screen appears; afterwards only on tap.
- **When it locks:** cold launch, and on return to the foreground after more than 60 seconds in the background. Setting in Security (§8.20). The lock is a device-side privacy gate; the server session is unaffected.

### 8.8 Home

API: `GET /dashboard/summary` (balance, `recentActivity`, `activeGoals`, `activeCircles`), `GET /auth/me` (name).

- **Layout:**
  1. Greeting header: `eyebrow` "Welcome back" (`textSecondary`), title "Good to see you, {first name}" (`title1`; first name = `name` up to the first space; no name → "Good to see you").
  2. BalanceCard (§4.1): Total `totalCents`, Available `availableCents`, In goals `goalTotalCents`, `pendingCents`, `balanceUnavailable`.
  3. DisclosureFooter (§4.21), 12pt under the card.
  4. SectionHeader "Your goals" + "See all" (→ Savings tab). Up to 4 GoalCard tiles in a 2-column grid (1 column at accessibility sizes). Empty: a compact card "No goals yet. Create your first one." + small PrimaryButton "Create goal".
  5. SectionHeader "Your groups" + "See all" (→ Groups tab), shown only when `activeCircles` is non-empty: up to 2 CircleCards.
  6. SectionHeader "Recent activity" + "See all" (→ Activity tab). A `surface` card with up to 5 ActivityRows. Empty: "No activity yet." in the card.
- **States:** loading (skeleton of all sections); error with no data (BalanceCard error state + ErrorState below "We couldn't load your home screen" + "Try again"); refresh failure with data (keep data, ErrorBanner at the top).

### 8.9 Activity

API: `GET /activity?limit=100`.

- Large title "Activity". Sections per day (§2.4 headers, `.isHeader`), each a `surface` card of ActivityRows. Rows are not tappable in this build.
- Footer when exactly 100 items came back: "Showing your latest 100 moves." (`footnote` `textSecondary`).
- **Empty:** symbol `clock.arrow.circlepath`, title "No activity yet", body "Money you add, move and pay in shows up here."
- **Error:** title "We couldn't load your activity".
- Loading label "Loading activity…".

### 8.10 Savings list

API: `GET /goals`.

- Large title "Savings". Toolbar `plus` (label "Create goal").
- **Summary card:** `eyebrow` "In goals", sum of `savedCents` (`displayAmount`), "Across {n} goal/goals" (`subheadline` `textSecondary`). If any goal has `balanceUnavailable`, add the `amberText` line "May be out of date" with `exclamationmark.circle`. Hidden when there are no goals.
- 2-column LazyVGrid of GoalCard tiles (1 column at accessibility sizes), 12pt gaps. Order: as returned.
- **Footer note** (`footnote` `textSecondary`): "Each goal is a pot inside your balance, not a separate account."
- **Empty:** symbol `target`, title "No goals yet", body "Set a target and a date. We'll track your progress.", button "Create goal".
- Loading "Loading your goals…". Error title "We couldn't load your goals".

### 8.11 Create goal (sheet)

API: `POST /goals {name, emoji, color: "jade", targetCents, deadline: "yyyy-MM-dd", frequency}`.

- Title "Create a goal".
- **Fields:**
  1. "Goal name". Placeholder "e.g. Emergency fund". Required, trimmed, max 40 characters (counter appears from 30).
  2. "Icon". Grid of the 12 symbols (§5), 4 per row (3 at accessibility sizes), each 56pt `fill` tile; selected = `jadeTint` with 2pt `jadeText` border and VoiceOver trait selected. Default `target`. VoiceOver labels are the picker labels in §5.
  3. "Target amount". Tappable field showing the amount; it opens AmountEntry in a pushed step (min $1.00, max $9,999,999.99, presets $500 · $1,000 · $5,000 · $10,000). Returns to the form.
  4. "Target date". `DatePicker` `.graphical`, range tomorrow to 10 years ahead, default 6 months ahead.
  5. "How often you'll save". Segmented: Daily · Weekly · Monthly (values `daily`, `weekly`, `monthly`); default Weekly.
- **Plan preview card** (`surfaceRaised`), from `buildGoalPlan(target, today, date, frequency)`:
  - `eyebrow` "Your plan".
  - Daily: "Start at {first} today and build up to {last} over {n} days."
  - Weekly: "Start at {first} this week and build up to {last} over {n} weeks."
  - Monthly: "Start at {first} this month and build up to {last} over {n} months."
  - Hidden until target and date are set.
- **Main button:** "Create goal" (loading "Creating…").
- **Success:** dismiss, push Goal detail for the new goal, Toast "Goal created."
- **Errors:** server message in an ErrorBanner; "Invalid request" maps to "Something went wrong. Please try again."

### 8.12 Goal detail

API: `GET /goals/{id}`; `GET /security/2fa` when a step-up sheet opens.

- Inline title = goal name. Toolbar menu `ellipsis.circle` with "Delete goal" (destructive).
- **Header card** (`surface`, `radiusCard`):
  - Icon well and PlanPill on one row.
  - Saved `displayAmount`; "of {target}" `amountSmall` `textSecondary`.
  - ProgressBar height 10.
  - Line `footnote` `textSecondary`: "{percent}% · Target date {date} · {n} days/weeks/months left" (left = whole periods from now to the deadline by the goal's frequency; omitted when past).
- **Actions:** PrimaryButton "Move to goal" and SecondaryButton "Move to balance", side by side (stacked at accessibility sizes). "Move to balance" is disabled when saved is 0, with the hint "Nothing to move yet." under it.
- **Plan card** (§4.6 data):
  - Title "Your plan".
  - Subtitle "{Daily / Weekly / Monthly} · grows gradually".
  - "Next step" row: amount (`amountRow`) and "this week" / "today" / "this month"; trailing "Step {i} of {n}".
  - Text: "About {k} weeks of saving left to reach your target." (days/months by frequency; k = n − i + 1). When the plan is complete: "You've completed every step of your plan."
- **Chart card**, title "Saved each month":
  - Swift Charts `BarMark` per calendar month for the last 6 months including this one.
  - y = sum of positive `history[].amountCents` in that month (status not `failed`), as `Int` cents (`Int` is plottable; no `Double` money).
  - Bars `progressFill`, corner radius 6. Y axis: 3 gridlines (`divider`) labelled `wholeIfRound` in `footnote` `textSecondary`. X axis: month abbreviations.
  - Height 160 (220 at accessibility sizes).
  - The API returns at most the latest 25 history items: when exactly 25 came back, plot only months from the oldest returned item's month onward and add the footnote "Based on your latest 25 moves."
  - Each bar: accessibility label "{Month year}", value "{amount full name} moved in".
  - Empty (no positive history): text "Your monthly saving shows up here after your first move." (no axes).
- **History card**, title "History": goal history items as ActivityRows (date and time subtitles).
  - Positive `goal_allocate` → title "Moved in", direction in. Negative `goal_release` → "Moved out", out. `fee` → "Fee", out.
  - Max 10 rows, then "Showing your latest {n} moves." Empty: "No moves yet."
- **Fee note** (`footnote` `textSecondary`), when `feeBps > 0`: "Moving money out of this goal has a {pct}% fee."
- **Technical details** (only when the toggle is on and `vaultAddress` is present): `eyebrow` "Technical details", TechnicalDetailsRows "Vault" (`vaultAddress`) and "Network" (`network`).
- **States:**
  - Loading: skeleton.
  - 404: ErrorState with symbol `questionmark.folder`, title "We couldn't find that goal.", button "Back to savings".
  - Other errors: standard.

### 8.13 Groups list

API: `GET /circles`, `GET /circles/invites`.

- Large title "Groups". Toolbar `plus` (label "Create group").
- **Section "Invitations ({n})"**, only if any: InviteCards.
  - Accept → dialog "Join {circleName}?" message "You'll pay in {contribution} {frequency word}." buttons "Join group" / "Cancel". On success the invite disappears and the group appears below; Toast "You joined {circleName}."
  - Decline → dialog "Decline this invitation?" buttons "Decline" (destructive) / "Cancel".
- **Section "Your groups":** CircleCards ordered Active, Forming, Completed (stable within each).
- **Explainer row** at the bottom: `info.circle` "How groups work" → sheet:
  - Title "How groups work".
  - Body: "A group is a savings circle, sometimes called a Susu. Everyone pays in a fixed amount each round. In a take-turns group, one person receives the pot each round until everyone has had a turn. In a save-together group, everyone saves into one pot and gets their own savings back at the end."
- **Empty** (no groups, no invites): symbol `person.3`, title "No groups yet", body "Save with people you trust. Everyone pays in each round.", button "Create group".
- Loading "Loading your groups…". Error title "We couldn't load your groups". If only invites fail, show the groups and an ErrorBanner "We couldn't load your invitations." with "Try again".

### 8.14 Create group (sheet)

API: `POST /circles`.

- Title "Create group".
- **Fields:**
  1. "Name". Placeholder "e.g. Family savings". Required, max 40.
  2. "How it works". Two selectable cards (radio, `surfaceRaised`, selected = 2pt `jadeText` border + `checkmark.circle.fill`):
     - "Take turns": "Everyone pays in each round. One person receives the pot each round until everyone has had a turn."
     - "Save together": "Everyone pays into one shared pot and gets their own savings back at the end."
  3. "Each person pays per round". AmountEntry step (min $1.00, max $10,000.00, presets $20 · $50 · $100 · $200).
  4. Take turns only: "Number of people (including you)". Stepper 2–20, default 5.
     Save together only: "Number of rounds". Stepper 2–52, default 10.
  5. "How often". Segmented: Weekly · Every 2 weeks · Monthly (values `weekly`, `biweekly`, `monthly`); default Monthly.
  6. "Invite by email · optional". Email field + "Add" button; added emails appear as removable chips (`xmark.circle.fill`, label "Remove {email}"). Max: take turns = people − 1; save together = 19. Over the max: "You can invite up to {n} people for this group."
- **Summary card:**
  - Take turns: "Each round, everyone pays in {c} plus a small fee. One person receives {c × people}. There are {people} rounds, so everyone gets one payout. The group starts automatically when everyone has joined."
  - Save together: "You pay in {c} {frequency word}. After {rounds} rounds you get back {c × rounds}. You start the group once people have joined."
  - The fee isn't known before the server creates the group, so no fee amount is shown here; the detail screen shows it.
- **Main button:** "Create group" (loading "Creating…").
- **Request:**
  - Take turns: `{name, type: "rotation", targetPayoutCents: c × people, groupSize: people, frequency, memberEmails}`.
  - Save together: `{name, type: "accumulation", contributionCents: c, numRounds: rounds, frequency, memberEmails}`.
- **Success:** dismiss, push Group detail, Toast "Group created."

### 8.15 Group detail

API: `GET /circles/{id}`, `POST /circles/{id}/start`, `POST /circles/{id}/delete`, `POST /circles/{id}/invite`.

- Inline title = group name. Toolbar menu (only when `canDelete`): "Delete group" (destructive).
- **Header card:**
  - StatusPill (Forming / Active / Completed), type and frequency line (as CircleCard).
  - Big number (`displayAmount`): take turns → `eyebrow` "Payout each round" + `payoutCents`; save together → `eyebrow` "You get back" + `payoutCents`. (Don't show `potCents`: it includes fees, so it's larger than what anyone receives.)
  - Facts row: "You pay in" `contributionCents` per round; take turns only, "Your turn" "Round {myPayoutRound}" (omit when null); "Round" "{currentRound} of {totalRounds}" (active only).
- **Main action:**
  - Active and `canContribute`: PrimaryButton "Pay in {contribution}" → §7.5.
  - Active and `myContributionStatus == "paid"`: StatusPill "Paid in this round" (jade) instead.
  - Forming, creator, `canStart`: PrimaryButton "Start group" → dialog "Start this group?" message "Rounds begin now and the payout order is set." buttons "Start group" / "Cancel".
  - Forming and not the creator: text "This group hasn't started yet." (`subheadline` `textSecondary`).
- **Forming card** (status forming):
  - Title "Build your group". Body:
    - Targeted: "{memberCount} of {targetMembers} have joined. The group starts automatically when the last person joins."
    - Take turns, untargeted: "Invite people by email. Everyone gets exactly one payout. Start the group once everyone's in."
    - Save together: "Invite people by email. Everyone saves into one pot for {totalRounds} rounds, then gets their savings back. Start the group once everyone's in."
  - When `canInvite`: SecondaryButton "Invite people" → Invite sheet. `pendingInvites` emails as rows with a neutral pill "Invited".
  - If the creator can't start yet (fewer than 2 members): "Invite at least one more person to start the group."
- **Take turns:** SectionHeader "Payout order" + RoundTimeline (§4.10). Body above it (`footnote` `textSecondary`): "The payout order is set when the group starts, so everyone knows who receives the pot, and when."
- **Save together:** SectionHeader "Progress" + the save-together RoundTimeline.
- **Members:** SectionHeader "Members ({n})" + MemberRows in a card.
- **Your pay-ins:** SectionHeader "Your pay-ins" + rows "Round {n}" with amount and StatusPill from `history[].status` (`confirmed` → Done, `pending` → Processing…, `failed` → Didn't go through). Empty: "No pay-ins yet."
- **Fee note**, when `feeBps > 0`: "Each pay-in includes a {pct}% fee."
- **Completed:** take turns "This group has finished. Everyone has received their payout."; save together "This group has finished. Savings returned."
- **Technical details** (toggle on and `contractAddress` present): TechnicalDetailsRow "Group contract".
- **Delete group:** dialog "Delete this group?" message "This removes the group and any pending invites." buttons "Delete group" (destructive) / "Cancel". Success → pop to Groups, Toast "Group deleted."
- **States:** loading; 404 "We couldn't find that group." + "Back to groups"; errors standard. After any action, refetch the detail.

### 8.16 Invite sheet

API: `POST /circles/{id}/invite {email}`.

- `.medium` and `.large` detents. Title "Invite people".
- Field "Email", placeholder "friend@example.com", `.emailAddress`. Button "Send invite" (loading "Sending…").
- On success: the field clears, jade footnote "Invite sent to {email}.", the email joins the list below.
- List "Invited": pending emails (from the refreshed detail).
- For targeted groups: "{n} spots left" where n = `targetMembers − memberCount − pendingInvites.count` (not below 0); at 0 the field is disabled with "This group is full."
- Server errors verbatim inline (for example "That person is already a member."). Some server messages say "circle" instead of "group"; show them as they are in this build (noted in §12).

### 8.17 Contribute sheet

The Pay in flow in §7.5.

### 8.18 Account

API: `GET /auth/me`.

- Large title "Account".
- **Header:** avatar 64 (initials of `name`), name `title3`, "@{username}" and email `subheadline` `textSecondary`.
- **Groups** (inset grouped list, `surface` rows, chevrons):
  - "Your account": Profile ("Name, username, date of birth"), Security ("Password, two-factor, app lock"), Notifications ("Choose what reaches you").
  - "App": Technical details ("Off" / "On" trailing value), About and legal.
  - "Developer" (Debug builds only): Developer settings.
- **Bottom:** destructive text row "Sign out" → dialog "Sign out of MoolaHub?" buttons "Sign out" (destructive) / "Cancel".
- **Sign-out sequence:**
  1. Call `POST /auth/logout`, best effort.
  2. Delete the session token from the Keychain.
  3. Clear in-memory user data.
  4. Go to Welcome.
  - Device settings (app lock, Technical details) stay.

### 8.19 Profile

API: `GET /profile`, `PATCH /profile {name, username}`, `GET /auth/username-available`.

- Inline title "Profile".
- **Fields:**
  - "Full name" (editable).
  - "Username" (editable, same check as Sign up).
  - "Email" (read-only, `textSecondary`, with a jade pill "Verified" when `emailVerified`).
  - "Date of birth" (read-only, formatted in UTC as §2.4).
- **Main button:** "Save changes" (loading "Saving…"), enabled only when something changed. Success Toast "Saved."
- **Errors:** "Name cannot be empty.", server messages verbatim.

### 8.20 Security

API: `GET /security/2fa`, `POST /auth/password`.

- Inline title "Security".
- **Rows:**
  - "Password" → Change password (pushed):
    - Fields "Current password", "Authenticator code" (only if 2FA is on), "New password" (hint "At least 8 characters"), "Confirm new password".
    - Button "Save password" (loading "Saving…"). Success: pop, Toast "Password updated."
    - Errors: "Password must be at least 8 characters.", "Passwords don't match.", server 401s inline (no sign-out).
  - "Authenticator app": trailing "On" (jade pill) / "Off" (neutral pill). When on, secondary line "Backup codes left: {backupCodesRemaining}". Footnote under the group: "You can turn two-factor on or off on the MoolaHub website."
  - "Lock with Face ID" `Toggle` (biometry-aware name). Footnote "MoolaHub asks for Face ID when you open it, and after a minute in the background." Disabled without a device passcode, with the footnote "Set a passcode on your iPhone to use app lock." Turning it on evaluates once first.

### 8.21 Notifications settings

API: `GET /notifications/preferences`, `PATCH /notifications/preferences {preference, categories?}`.

- Inline title "Notifications". Intro "Choose how much you want to hear from MoolaHub."
- **Radio list** (one selected, `checkmark` trailing):
  - "Everything" (jade pill "Recommended"): "All notifications: group activity, goal milestones, money added, reminders and tips."
  - "Essential": "Important updates only, like payouts, pay-in due dates and account activity."
  - "Minimal": "Only the most important account and money notifications."
  - "Custom": "Choose exactly which kinds you want to hear about."
- When Custom is selected, three toggles appear:
  - "Money" ("Money added and sent, payouts and payment reminders.")
  - "Groups" ("Invitations, member activity and group updates.")
  - "Tips" ("Streaks, learning nudges and product news.")
- Saves on every change. Optimistic, reverts on failure with ErrorBanner "We couldn't save that. Please try again."

### 8.22 Technical details

API: `GET /wallet` (only when the toggle is on).

- Inline title "Technical details".
- `Toggle` "Show technical details", off by default, stored on this device. Footnote "Shows network names, account addresses and contract details across the app. You never need this to use MoolaHub. This choice is saved on this device."
- **When on:**
  - Section "Your account": TechnicalDetailsRow "Network" (`network`), "Account address" (`address`, or "Not set up yet" when null).
  - Line (`footnote` `textSecondary`): "Your balance is held as USDC, a US-dollar digital currency."
- **States:** loading rows; ErrorBanner on failure.

### 8.23 About and legal

- Inline title "About and legal".
- **Section "About":** "Version" `{CFBundleShortVersionString} ({CFBundleVersion})`.
- **Section "Disclosures":**
  - "About your balance" → full disclosure (§9.5).
  - "Test money" → "This build of MoolaHub uses test money only. Nothing in it is real money and nothing can be cashed out."
- **Section "Open-source licenses":** rows "Space Grotesk", "Hanken Grotesk", "IBM Plex Mono", each pushing a scrollable `mono` text view of the bundled OFL file.
- No Terms or Privacy rows until real URLs exist (open question in §12).

### 8.24 Developer settings (Debug builds only)

Compiled only under `#if DEBUG`; impossible to reach in Release.

- Inline title "Developer settings".
- **Section "Server":**
  - Field "API base URL" (`mono`, URL keyboard, autocapitalization off), current value.
  - Preset rows: "Simulator" `http://localhost:8787/api`; "This Mac on the local network" `http://<this Mac>.local:8787/api`. Tap fills the field.
  - Buttons:
    - "Test connection": `GET {base}/healthz`. Shows "Connected" (jade) or the error (red).
    - "Save". If the URL changed while signed in, dialog "Change server? You'll be signed out." with "Change and sign out" / "Cancel".
    - "Reset to default".
- **Section "Build":** configuration name, bundle id.
- Validation: must start with `http://` or `https://` and end without a trailing slash; error "Enter a full URL, like http://localhost:8787/api."

---

## 9. Copy system

### 9.1 Voice (from `BRAND_VOICE.md`)

- Sentence case everywhere: titles, buttons, labels, pills, toasts.
- Verb-first buttons, one verb per action across the app: "Add money" (Home action) / "Add test money" (dev sheet), "Move to goal", "Move to balance", "Pay in", "Cash out", "Create goal", "Create group", "Start group", "Invite people", "Send invite", "Sign in", "Sign out", "Create account", "Try again", "Save changes", "Done".
- No emoji anywhere in the iOS app. No exclamation marks on money. At most one em dash per screen; this spec uses none.
- Real ellipsis `…` in progressive states ("Signing in…", "Processing…").
- Never "interest", "returns", "grow your money", "savings account", "deposit" (as a noun for our product), "yield", "APY".
- "Group" is the one word for circles in the iOS UI ("Susu" is defined once in How groups work).

### 9.2 Glossary (invisible crypto)

| Internal | User sees |
|---|---|
| USDC balance | Balance ($) |
| On-ramp / faucet | Add money / Add test money |
| Allocate / release | Move to goal / Move to balance |
| Contribute / payout | Pay in / Your payout |
| Off-ramp | Cash out |
| Pending | Processing… |
| Failed / reverted | Didn't go through, nothing was taken |
| Yield | Earnings (variable) |
| Sign | Confirm (Face ID) |
| Gas | nothing |

### 9.3 Where crypto words may appear

Only: the DisclosureFooter and its sheet ("USDC"), About and legal, Technical details (network name, addresses, "USDC"), Developer settings. A copy check (the iOS counterpart of `scripts/check-copy.mjs`) should fail the build if `USDC`, `0x`, `wallet`, `blockchain`, `Privy`, `gas`, `transaction`, `hash`, `Base`, `Monad` appear in any other user-facing string.

### 9.4 Errors and how to map them

The API returns `{ "error": "<message>" }`. Server `AppError` messages are written for users; show them verbatim except as below.

| Situation | Copy |
|---|---|
| No connection before sending (`URLError.notConnectedToInternet`, `.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed`) | "We couldn't reach MoolaHub. Check your connection and try again." |
| Money move: request may have been sent but no response (`.timedOut`, `.networkConnectionLost`, or any error after the request left) | "We couldn't confirm this move. Check Activity before you try again." + button "View activity". **Never auto-retry a money request.** |
| Money move: clear server refusal (4xx with message) | Title "Didn't go through. Nothing was taken." + the server message under it. |
| HTTP 5xx | "Something went wrong on our side. Your money hasn't moved. Please try again in a minute." (for non-money screens: "Something went wrong. Please try again.") |
| HTTP 429 | Server message if present, else "Too many tries. Please wait a moment and try again." |
| HTTP 400 "Invalid request" | "Something went wrong. Please try again." |
| HTTP 401 `{"error":"Unauthorized"}` on an authenticated request | Session expired: sign out locally, go to Sign in with "You've been signed out. Please sign in again." |
| Any other 401 (wrong password, step-up, 2FA) | Show the message inline. Do **not** sign out. |
| Screen failed to load | "We couldn't load this. Check your connection and try again." |
| Not enough available | "You don't have enough available for that. Add money or choose a smaller amount." |
| Face ID cancelled | "Cancelled. Nothing was taken." |

### 9.5 Disclosures (verbatim)

- **Balance footer:** "Held as USDC · Not a bank deposit · Not insured"
- **About your balance** (footer sheet and About and legal): "Your balance is held as USDC, a US-dollar digital currency issued by Circle. MoolaHub is not a bank. Your balance is not a bank deposit and is not FDIC-insured or government-backed."
- **Test money:** "This build of MoolaHub uses test money only. Nothing in it is real money and nothing can be cashed out."

### 9.6 Loading labels (VoiceOver and skeleton)

"Loading your balance…", "Loading your goals…", "Loading goal…", "Loading your groups…", "Loading group…", "Loading activity…", "Loading your profile…".

---

## 10. Accessibility, haptics and motion

### 10.1 Dynamic Type

- Every text style scales (§2.2). Test at Large, xxxLarge, AX3 and AX5.
- At accessibility sizes (`dynamicTypeSize.isAccessibilitySize`) switch layouts, don't shrink text:
  - Quick actions 4 across → 2 × 2.
  - Goal grid 2 columns → 1.
  - Side-by-side buttons → stacked.
  - Label/value rows → label above value.
  - Facts rows → vertical.
- Use `ViewThatFits` or `AnyLayout` for the switch.
- Only display amounts, the keypad and eyebrows are capped (table in §2.2). Body text is never capped. Nothing truncates money.
- Every screen scrolls vertically, so AX5 content is reachable; sheets keep the main button pinned above the keyboard and safe area.

### 10.2 VoiceOver

- Money: full-name currency ("1,240.50 US dollars") with "plus"/"minus" for direction (§4.3).
- Progress: "{percent} percent", combined into the card element (§4.4).
- Cards are single elements with a hint; buttons inside cards (InviteCard) stay separate.
- Headers carry `.isHeader`. Pills are read as part of their row. Decorative symbols are hidden.
- Charts: per-bar labels (§8.12); the chart container label "Saved each month, last 6 months".
- Announce: Toasts, ErrorBanners, Receipt titles (`AccessibilityNotification.Announcement`), and "Copied".
- Sheet steps move focus to the step title on appear.
- Secure fields' show/hide buttons are labelled "Show password" / "Hide password".
- Every interactive element has a 44 × 44 target.

### 10.3 Other settings

- **Reduce Motion:** no scale/spring/bounce, no numeric-text roll, no progress fill animation, no skeleton pulse; use 0.2s opacity crossfades.
- **Reduce Transparency:** solid `canvas` for the privacy cover and any material.
- **Increase Contrast:** use the IC values (§1.2); card hairlines switch to `controlBorder`.
- **Bold Text:** step custom fonts up one weight (§2.2).
- **Differentiate Without Color:** already met (symbols + words on every status).
- **Smart Invert:** mark the logo and charts `.accessibilityIgnoresInvertColors(true)`.

### 10.4 Haptics (`.sensoryFeedback`, iOS 17)

| Moment | Feedback |
|---|---|
| Receipt appears with a successful move | `.success` |
| Money move or sign-in fails | `.error` |
| AmountEntry rejects a key, validation blocks a submit | `.warning` |
| Preset chip, icon picker, segmented change, radio change | `.selection` |
| Pull to refresh | system |
| Keypad digits, navigation, toggles | none (system toggles have their own) |

### 10.5 Motion

| Token | Value | Use |
|---|---|---|
| `motionFast` | 0.12s ease-out | Press states. |
| `motionStandard` | 0.25s ease-in-out | Show/hide banners, chips, layout changes. |
| `motionEmphasis` | spring(response 0.35, dampingFraction 0.85) | Balance numeric transition, receipt symbol. |
| `motionProgress` | 0.6s ease-out | Progress bar fill on first appear. |

- Balance and amounts use `.contentTransition(.numericText(value:))` with `motionEmphasis` when they change after a refresh.
- Card press: scale 0.98 + `motionFast`.
- Toast: slide from top + fade, `motionStandard`.
- Sheets and navigation: system transitions only.
- Everything above respects Reduce Motion (§10.3).

---

## 11. Notes for the architect and engineers

1. **Fonts:** add all nine `.ttf` files to the app target and list them under `UIAppFonts`. Use the PostScript names in §2.1 exactly. Two are irregular: Plex Mono Regular is `IBMPlexMono`, Plex Mono Medium is `IBMPlexMono-Medm`. Bundle the three OFL files.
2. **Tabular figures:** `.monospacedDigit()` on Space Grotesk; add the equal-width test in §2.2.
3. **Money formatting:** fixed `en_US` locale for USD (§2.3); `Int` cents → `Decimal`; charts plot `Int` cents.
4. **Deadlines:** format in UTC; send `yyyy-MM-dd` (§2.4).
5. **401 handling:** only `401` with body `{"error":"Unauthorized"}` on an authenticated request means "session expired". Login, 2FA, step-up and password-change endpoints also return 401 for wrong credentials and must show the message inline.
6. **No automatic retries** of `POST` money requests (`/wallet/deposit`, `/goals/{id}/allocate`, `/goals/{id}/release`, `/goals/{id}/delete`, `/circles/{id}/contribute`). The API has no idempotency key yet.
7. **Step-up:** release and delete send `currentPassword` (and `twoFactorCode` when 2FA is on). Never store the password; clear the field after the request.
8. **Navigation titles** via `UINavigationBar.appearance()` text attributes only (§2.5).
9. **Info.plist:** `NSFaceIDUsageDescription` = "MoolaHub uses Face ID to unlock the app and confirm money moves." Display name "MoolaHub".
10. **Goal icons** ↔ `emoji` mapping in §5; send `color: "jade"`.
11. **Group "you" detection:** match member `name` (a username) to the signed-in user's `username`; member `id` is a membership id, not a user id.
12. **Activity amounts** are signed relative to the user's balance (positive = in). Goal history amounts are signed relative to the goal (positive = moved in).
13. **Plan math** must be a port of `contribution-plan.ts` with its test cases, so web and iOS show the same plan and pace.
14. **Copy check:** add the banned-terms check in §9.3 for iOS strings.

## 12. Open questions (do not block the dev build)

1. Terms of service and privacy policy URLs for About and legal.
2. Turning two-factor on/off and backup-code regeneration on iOS (this build only shows status).
3. App lock default: offered once (this spec) or on by default.
4. Brand casing: this spec uses "MoolaHub" (web copy and logo); some docs write "Moolahub".
5. Whether to show a group's fee before creation (needs the server's fee in a config endpoint).
6. Server error strings for groups still say "circle" (for example "Circle is not active", "This circle has already started."); the iOS UI says "group". Align the server copy, or add an iOS mapping, in a later pass.
