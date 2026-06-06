# Session hardening — 7-day default, 30 days with "keep me logged in"

## What changed (backend — implemented)
- `lib/auth.ts`: `createSession(userId, rememberMe=false)` now expires in **7 days** by default, **30 days** when `rememberMe` is true. Exposes `sessionTtlMs(rememberMe)` and the `SESSION_TTL_MS` / `SESSION_TTL_REMEMBER_MS` constants.
- `routes/auth.ts` (`/auth/privy`) and `routes/passkeys.ts` (`/passkeys/login/verify`): read `rememberMe` from the request body, pass it to `createSession`, and set the cookie `maxAge` to match the session TTL (`sessionTtlMs(rememberMe)`). The base `cookieOpts` no longer hard-codes a 30-day `maxAge`.

`rememberMe` is read defensively from the raw body, so the backend honors it whether or not the generated client/schema has been regenerated yet. Default is **false → 7 days**.

## API contract (implemented in openapi.yaml)
`PrivyAuthInput` gains an optional `rememberMe: boolean`. Regenerate the typed client so the frontend can send it:

```bash
pnpm --filter @workspace/api-spec run codegen
```

## Frontend — add the checkbox (apply this edit)
In `artifacts/moolahub-app/src/components/auth/PrivyAuth.tsx`, add a "Keep me logged in" checkbox and pass it through the mutation:

```tsx
// inside PrivyLoginButton()
const [rememberMe, setRememberMe] = useState(false);

// in authenticateWithServer(), change the mutate call:
privyAuthMutation.mutate(
  { data: { token, rememberMe } },   // <-- add rememberMe
  { onSuccess: () => { /* … */ }, onSettled: () => setBusy(false) },
);

// in the returned JSX, above the button:
<label className="flex items-center gap-2 text-sm text-ink-500">
  <input
    type="checkbox"
    checked={rememberMe}
    onChange={(e) => setRememberMe(e.target.checked)}
    className="h-4 w-4 rounded border-ink-300"
  />
  Keep me logged in for 30 days
</label>
```

(For passkey login, pass `rememberMe` in the body of the `/passkeys/login/verify` request the same way once you add a checkbox to that form.)

## Result
- Default login → 7-day session + 7-day cookie.
- "Keep me logged in" → 30-day session + 30-day cookie.
- Cookie lifetime always matches the server-side session expiry (no zombie cookies pointing at expired sessions).
