#!/bin/bash
set -e
pnpm install --frozen-lockfile
# Schema changes ship as reviewed SQL in lib/db/migrations and are applied with
# drizzle-kit migrate by the owner role. Never `drizzle-kit push`: it diffs the
# live database and can drop data. The app role in DATABASE_URL has no DDL
# rights, so migrations only run where MIGRATIONS_DATABASE_URL is set.
if [ -n "$MIGRATIONS_DATABASE_URL" ]; then
  pnpm --filter @workspace/db run migrate
else
  echo "post-merge: MIGRATIONS_DATABASE_URL not set, skipping migrations"
fi
