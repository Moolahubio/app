---
name: MoolaHub stack decisions
description: Key non-obvious decisions and quirks for the MoolaHub social savings app on Base blockchain
---

## Auth
- Password hashing: uses `bcryptjs` npm package in api-server. bcryptjs is CJS-only in this monorepo; cannot `await import('bcryptjs')` from the code_execution sandbox (ESM). To generate hashes for seeds, use: `node -e "const b = require('/home/runner/workspace/artifacts/api-server/node_modules/bcryptjs'); b.hash('pass', 10, (e,h)=>console.log(h))"`
- Seed user: ama@moolahub.io / moolahub (bcrypt cost 10)
- Sessions: HTTP-only cookie `moolahub_session` (30d expiry). Cookie must be included in all authenticated requests.

**Why:** bcryptjs has no ESM export in v3; code_execution sandbox uses ESM import. Must use CJS require path.

## DB Schema
- All money stored as integer cents. No decimals anywhere.
- Tables: users, sessions, wallets, goals, circles, circle_members, circle_invites, transactions, notifications, lesson_progress
- Wallet balances: `available_cents` + `goal_allocated_cents`. Total = sum of both.

## Lessons
- Lessons are static data in `artifacts/api-server/src/lib/lessons-data.ts` (not DB-driven). Progress tracked in `lesson_progress` table.
- 6 lessons seeded in that file.

## API
- Base URL: `/api`. API server port 8080. Frontend port 23183.
- CORS configured with `credentials: true` for cookie-based auth.
