---
name: MoolaHub client auth/logout
description: How client-side auth state must be cleared on logout, and why invalidate/remove patterns fail
---

# Client logout & auth-state clearing

The web app's `AuthProvider` (`use-auth.tsx`) derives auth from `useGetMe` with
`staleTime: Infinity` + `retry: false`, keyed by `getGetMeQueryKey()` (`["/api/auth/me"]`).
`isAuthenticated = !!user`. `AppLayout` redirects to `/login` when unauthenticated.

## Rule
On logout success, do exactly:
1. `queryClient.setQueryData(getGetMeQueryKey(), null)` — flips `isAuthenticated` false
   immediately, with no refetch (data present + staleTime Infinity).
2. `queryClient.removeQueries({ predicate: q => q.queryKey[0] !== getGetMeQueryKey()[0] })`
   — clears every other user-scoped cache (dashboard, notifications, profile, passkeys)
   while leaving the just-set `getMe: null` intact.
3. `setLocation("/login")`.

**Why:** Earlier attempts failed two ways, both observed via e2e:
- `invalidateQueries(getMe)` → refetch 401s, but React Query *keeps the last successful
  data on error*, so `user` stays set, `isAuthenticated` stays true → zombie logged-in UI.
- `queryClient.removeQueries()` (no predicate) → re-triggers a refetch of the still-mounted
  `getMe` observer, racing with `setQueryData(null)` → app left half-authenticated, and
  `login.tsx` bounced back to `/`. Excluding `getMe` from the removal avoids that race.

**How to apply:** Any new sign-out entry point must follow this exact order. Clearing only
`getMe` leaves a cross-user data-leak path on account-switch in one browser; clearing
everything (including `getMe`) reintroduces the refetch race.

## Related: login redirect
`login.tsx` must redirect already-authenticated users via a `useEffect`, never a
render-phase `setLocation` — the latter throws React's "Cannot update a component while
rendering" and can cause a redirect bounce loop right after logout.

## Privy re-login after sign-out (important)
Server `/auth/logout` clears the cookie + DB session, but it does NOT clear Privy's
own persisted (localStorage) session — the profile/sign-out button is outside the
`PrivyProvider`. Privy's `useLogin().onComplete` fires BOTH on an explicit login AND
when Privy silently restores its session on mount. So after sign-out the redirect to
`/login` mounts `PrivyProvider`, Privy restores, `onComplete` fires, and the app
re-calls `/auth/privy` → instant re-login loop.
- **Fix:** in `PrivyAuth.tsx` guard `onComplete` with an `intentionalRef` flag set only
  on an actual button click; ignore passive restores. When `usePrivy().authenticated`
  is already true on click, call the server exchange directly (login() won't re-fire).
- **How to apply:** never run the server `/auth/privy` exchange straight from
  `onComplete` unconditionally; it will auto-undo a sign-out.

## Note on console noise
The "Invalid hook call / more than one copy of React" console error is NOT an app bug:
vite config already `dedupe`s react/react-dom and only one react@19.1.0 resolves. It comes
from injected browser wallet extensions (e.g. Rabby) interacting with the Privy stack.
