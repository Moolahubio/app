---
name: MoolaHub Privy + Vite + Monad frontend wiring
description: How the Privy smart-wallet providers are wired for Monad in the Vite web app, and which recurring console errors are just noise.
---

# Privy smart-wallet providers (Monad) in the Vite web app

The Privy stack is wired once at the app root, never per-component.

- A single `Web3Provider` (src/components/app/Web3Provider.tsx) renders
  `PrivyProvider` (defaultChain + supportedChains = viem `monadTestnet`, 10143)
  wrapping `SmartWalletsProvider`. It is hoisted in App.tsx **inside** ThemeProvider
  (needs `resolvedTheme` for appearance.theme) and **above** AuthProvider/Router so
  `usePrivy` / `useLogin` / `useSmartWallets` anywhere resolve to one root context.
- `Web3Provider` exports `isWeb3Enabled` (build-time guard on VITE_PRIVY_APP_ID).
  When false it renders children plain; consumers (e.g. WalletSetupCard) gate on the
  **same** flag. Never re-introduce a second per-component PrivyProvider — duplicate
  providers were the real dual-context / dual-React risk.

**Why:** `@privy-io/react-auth/smart-wallets` is a subpath with an *optional* peer
`permissionless` (ERC-4337). If `permissionless` isn't installed, Vite pre-bundles a
throwing `__vite-optional-peer-dep:permissionless` stub → runtime "Could not resolve
permissionless". A mid-session Vite re-optimization (lockfile change) can also pull in
a second React copy → "Invalid hook call / more than one copy of React".

**How to apply:**
- Keep `permissionless` (^0.2.47, resolved 0.2.57) in moolahub-app deps, and keep
  BOTH `@privy-io/react-auth` and `@privy-io/react-auth/smart-wallets` in
  vite.config.ts `optimizeDeps.include` (plus the existing resolve.dedupe react /
  react-dom). After adding the peer, do a full page reload — the old optimized-bundle
  hash keeps throwing until Vite re-optimizes AND the page reloads.
- Recurring console errors are usually NOT app bugs: "Invalid hook call", "wallet not
  connected", and injected-provider logs come from browser wallet extensions
  (Binance / Backpack / Rabby). Verify in an **extension-free** context (the
  app-preview screenshot tool), not the dev browser.
- Benign, left as-is: "The configured chains are not supported by Coinbase Smart
  Wallet: 10143" — MoolaHub uses Privy embedded smart accounts, not Coinbase SW. The
  documented silencer `externalWallets.coinbaseWallet.connectionOptions: "eoaOnly"`
  does NOT typecheck against @privy-io/react-auth@3.28 config types — do not re-add it.
- `useSmartWallets().client` stays null until the user is Privy-authed with an embedded
  signer AND Monad 10143 bundler/paymaster is enabled in the Privy dashboard (user
  action). hooks/useOnchain.ts is currently dead code (imported nowhere).
- Privy's auth/embedded-wallet iframe (auth.privy.io) is REFUSED inside the Replit
  preview pane and the app-preview screenshot tool. Cause: those load the app nested
  (screenshot at http://localhost:80; preview under Replit's origin), and Privy's
  `frame-ancestors` CSP checks the FULL ancestor chain — the wrapper origin isn't (and
  can't reliably be) allow-listed. Console shows either "Privy iframe failed to load"
  (domain not yet in dashboard) or, once the dev domain IS added, "Refused to frame
  'https://auth.privy.io/' because an ancestor violates ... frame-ancestors 'self'
  <your allow-listed domains>". The SECOND form means dashboard config is CORRECT — the
  only blocker left is nesting. **Test any Privy embedded flow TOP-LEVEL** (open the dev
  domain in its own tab), never in the preview pane. Production is unaffected: real users
  hit the allow-listed prod domain top-level. Dev-only `/privy-check` route (gated on
  `import.meta.env.DEV`) exists as the top-level signing spike.
