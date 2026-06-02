# Coinbase Onramp (fiat → USDC)

Lets users **buy USDC with a card/bank**; the funds land directly in their Base
wallet and are credited to the MoolaHub ledger by our on-chain deposit sync.
Flag-gated behind `NEXT_PUBLIC_ONRAMP`; off by default.

## Security model (follows Coinbase's requirements)

- **Server-side session token.** The CDP API key/secret never reach the client.
  `POST /api/onramp` mints a short-lived session token via the official CDP JWT
  (`@coinbase/cdp-sdk/auth`) and calls `…/onramp/v1/token`. (`src/lib/server/onramp.ts`)
- **Address can't be tampered.** The destination is set **server-side to the
  authenticated user's own wallet** — never taken from client input. The address
  + asset/network are baked into the session token, so the hosted URL only
  carries `sessionToken` (no `addresses`/`assets`/`projectId`).
- **Auth-gated + rate-limited.** The route requires a MoolaHub session and caps
  requests (10/min/user); body is Zod-validated; client IP is forwarded (CDP
  rejects private IPs).
- **Secret hygiene.** `CDP_API_KEY_SECRET` is server-only; `@coinbase/cdp-sdk` is
  in `serverExternalPackages` so it never ships to the browser.

## Flow

1. `/wallet` → "Buy USDC with card" → `POST /api/onramp` → `{ url }`.
2. Client opens the hosted Coinbase Onramp (`pay.coinbase.com`) in a popup.
3. User completes the purchase; USDC is delivered to their Base wallet on-chain.
4. "Check for deposits" (`syncDeposits`) scans Transfer logs and credits the
   ledger — onramp reuses the deposit rail we already built. (A CDP transaction
   webhook can be added later for instant status.)

## Enable

Provide (from portal.cdp.coinbase.com):

| Env var | What |
| --- | --- |
| `NEXT_PUBLIC_ONRAMP` | `"true"` to show the buy button |
| `CDP_API_KEY_ID` | CDP API key id (server) |
| `CDP_API_KEY_SECRET` | CDP API key secret (server, keep secret) |

In the CDP dashboard, enable Onramp for the project and allow-list your app
domain(s). **Onramp delivers real funds, so it operates on Base mainnet** — wire
it for the mainnet launch; on Base Sepolia use the testnet faucet instead. No
app-code change is needed to switch (the destination is the user's wallet).
