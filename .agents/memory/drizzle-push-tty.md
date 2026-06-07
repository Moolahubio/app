---
name: drizzle-kit push interactive TTY block
description: Why `drizzle-kit push` can hang/error in this env and how to apply additive schema changes instead.
---

# drizzle-kit push hits an interactive prompt and fails here
- `pnpm --filter @workspace/db run push` runs `drizzle-kit push`, which prompts interactively for certain changes — notably **adding a UNIQUE constraint to a table that already has rows** ("Do you want to truncate ...?"). The Replit shell has no TTY, so it errors: `Interactive prompts require a TTY terminal`. Nothing is applied (it prompts before executing).
- **Why:** drizzle guards potentially-destructive ops behind a confirm; non-interactive shells can't answer.

# How to apply additive changes instead
- Apply DDL directly via SQL (executeSql in code_execution, or `psql "$DATABASE_URL"`), idempotently: `ADD COLUMN IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`, and add constraints in a `DO $$ ... IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='...') ...` block.
- **Name the constraint exactly what drizzle expects** (e.g. `users_username_unique` for `.unique()` on `username`) so a later `push`/introspect sees the schema as in-sync rather than trying to re-add it.
- A UNIQUE constraint on a **nullable** column with all-NULL existing rows is safe — NULLs don't collide; the prompt is just drizzle being cautious.
- `executeSql` in the code_execution sandbox targets the same `DATABASE_URL` the workflows use — verify with `psql "$DATABASE_URL"` if in doubt.

# Watch for stale workflow logs after a schema fix
- After applying schema, a test workflow (e.g. `circles`) may still show an old FAILED run because its log file isn't always rotated by a restart. Re-run the test **directly** (`pnpm --filter @workspace/api-server run test:susu`) or `refresh_all_logs` to get the true current state before concluding it's still broken.
