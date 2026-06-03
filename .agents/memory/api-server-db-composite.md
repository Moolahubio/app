---
name: api-server consumes @workspace/db via composite project references
description: Why api-server typecheck breaks after a db schema change and how to fix it
---

The `@workspace/api-server` package consumes `@workspace/db` through TypeScript
**composite project references** (`references: [{ path: "../../lib/db" }]`),
resolving types from `lib/db/dist/*.d.ts` — NOT directly from `lib/db/src`.

**Rule:** after ANY change to the Drizzle schema in `lib/db/src/schema/*`, you
MUST regenerate the db declaration output before the api-server (or anything else
referencing `@workspace/db`) will typecheck against the new shape:

```
pnpm --filter @workspace/db exec tsc -p tsconfig.json
```

**Why:** the consumer reads stale `.d.ts` from `dist/` until rebuilt. Symptoms of
a stale build: "no exported member 'usersTable'" on every table import, plus
drizzle's "DrizzleTypeError: Seems like the schema generic is missing" on
`db.query.*` (the whole `db` type degrades to any when the schema barrel's
declarations are out of date).

**How to apply:** schema change → rebuild db decls → then typecheck consumers.
