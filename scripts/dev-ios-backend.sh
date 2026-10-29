#!/usr/bin/env bash
# One-command LOCAL backend for the native iOS dev build.
#
#   scripts/dev-ios-backend.sh           # migrate + seed (no-op if seeded) + build + start
#   scripts/dev-ios-backend.sh --reset   # same, but wipe and reseed the demo users' data first
#
# What it does, in order:
#   1. checks the local Homebrew Postgres 16 (/opt/homebrew/opt/postgresql@16/bin)
#      and starts it with `brew services` if it isn't running;
#   2. creates the database moolahub_ios_dev if it is missing;
#   3. keeps a persistent, gitignored .dev/api.env holding APP_ENCRYPTION_KEY
#      (generated once with `openssl rand -hex 32`, mode 600, never printed);
#   4. runs the Drizzle migrations against the LOCAL database;
#   5. seeds demo data (artifacts/api-server/scripts/seed-ios-dev.ts);
#   6. builds the API and runs it on 0.0.0.0:8787 in the foreground (Ctrl-C stops it).
#
# Offline by construction: every chain, email, Privy and Sentry variable is unset,
# so nothing leaves this machine. Money is ledger-only test money (the faucet),
# and sign-up / reset codes are printed in this log as "[DEV ONLY] ... code".
#
# It refuses to run if the database URL it would use is not on localhost /
# 127.0.0.1. An inherited DATABASE_URL is ignored; to use a different LOCAL
# database set IOS_DEV_DATABASE_URL (in your shell or in .dev/api.env).
set -euo pipefail

PGBIN=/opt/homebrew/opt/postgresql@16/bin
DB_NAME=moolahub_ios_dev
PORT=8787

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="$ROOT/.dev"
ENV_FILE="$DEV_DIR/api.env"

RESET=""
for arg in "$@"; do
  case "$arg" in
    --reset) RESET="--reset" ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m[dev-ios-backend]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[dev-ios-backend] %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------ this Mac's name for the iPhone app
# The iPhone dev build reads this Mac's name from a gitignored xcconfig that
# apps/ios/Config/Debug.xcconfig includes. Written when it is missing, empty or
# only an older DEV_MAC_HOST line; a hand-edited file is left alone.
LAN_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
IOS_LOCAL_XCCONFIG="$ROOT/apps/ios/Config/Local.xcconfig"
IOS_HOST_LINE="DEV_MAC_HOST = $LAN_NAME.local"
if [ -d "$ROOT/apps/ios/Config" ]; then
  current="$(cat "$IOS_LOCAL_XCCONFIG" 2>/dev/null || true)"
  if [ -z "$current" ] || { [ "$current" != "$IOS_HOST_LINE" ] && [[ "$current" =~ ^DEV_MAC_HOST\ =\ [^[:space:]]*$ ]]; }; then
    printf '%s\n' "$IOS_HOST_LINE" >"$IOS_LOCAL_XCCONFIG"
    say "Wrote apps/ios/Config/Local.xcconfig ($LAN_NAME.local); rebuild the iPhone app to use it."
  fi
fi

# ---------------------------------------------------------------- tooling
command -v pnpm >/dev/null || die "pnpm is not installed (https://pnpm.io/installation)."
command -v node >/dev/null || die "node is not installed."
command -v openssl >/dev/null || die "openssl is not installed."
[ -x "$PGBIN/pg_isready" ] || die "PostgreSQL 16 not found at $PGBIN. Install it with: brew install postgresql@16"
[ -d "$ROOT/node_modules" ] || die "Dependencies are missing. Run: (cd \"$ROOT\" && pnpm install)"

# ------------------------------------------------- persistent local secrets
OLD_UMASK="$(umask)"
umask 077
mkdir -p "$DEV_DIR"
if [ ! -s "$ENV_FILE" ]; then
  printf '# Local iOS dev backend only (gitignored). Created by scripts/dev-ios-backend.sh.\n' >"$ENV_FILE"
  printf '# Encrypts the throwaway dev wallet keys and 2FA secrets in moolahub_ios_dev.\n' >>"$ENV_FILE"
  printf '# Keep it: changing it makes existing encrypted values in that database unreadable.\n' >>"$ENV_FILE"
  printf 'APP_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" >>"$ENV_FILE"
  say "Created $ENV_FILE with a new APP_ENCRYPTION_KEY (not shown)."
fi
chmod 700 "$DEV_DIR"
chmod 600 "$ENV_FILE"
umask "$OLD_UMASK"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
[ -n "${APP_ENCRYPTION_KEY:-}" ] || die "$ENV_FILE has no APP_ENCRYPTION_KEY. Delete the file to regenerate it."

# --------------------------------------------- database URL: local or nothing
DATABASE_URL="${IOS_DEV_DATABASE_URL:-postgres://$(id -un)@localhost:5432/$DB_NAME}"
DB_HOST="$(node -e 'try { process.stdout.write(new URL(process.argv[1]).hostname) } catch { process.exit(1) }' "$DATABASE_URL")" \
  || die "The database URL is not a valid postgres:// URL."
case "$DB_HOST" in
  localhost|127.0.0.1) ;;
  *) die "Refusing to run: the database URL points at '$DB_HOST', not localhost / 127.0.0.1." ;;
esac
DB_NAME_IN_URL="$(node -e 'process.stdout.write(decodeURIComponent(new URL(process.argv[1]).pathname.slice(1)))' "$DATABASE_URL")"
[ -n "$DB_NAME_IN_URL" ] || die "The database URL has no database name."

# ----------------------------------------- offline, local-only environment
# Nothing may reach a chain, an email provider, Privy, Sentry or a remote DB.
unset MIGRATIONS_DATABASE_URL PG_CA_CERT \
  PLATFORM_PRIVATE_KEY USDC_CONTRACT_ADDRESS GOAL_VAULT_ADDRESS CIRCLE_FACTORY_ADDRESS \
  ACCUMULATION_FACTORY_ADDRESS CHAIN_RPC_URL BASE_RPC_URL ENABLE_DEPOSIT_SYNC \
  ENABLE_PRIVY_CUSTODY PRIVY_APP_ID PRIVY_APP_SECRET RESEND_API_KEY EMAIL_FROM \
  SENTRY_DSN SENTRY_AUTH_TOKEN REPLIT_DOMAINS REPLIT_DEV_DOMAIN REFERRAL_REWARDS_ENABLED
export DATABASE_URL APP_ENCRYPTION_KEY
export NODE_ENV=development
export PORT
export LISTEN_HOST=0.0.0.0
export ENABLE_TEST_FAUCET=true
export DEV_LOG_EMAIL_CODES=true
# A QA session on a phone easily exceeds the production budgets (20 auth / 300
# API calls per 15 minutes per IP). Dev-only overrides; ignored in production.
export DEV_AUTH_RATE_LIMIT_MAX="${DEV_AUTH_RATE_LIMIT_MAX:-500}"
export DEV_API_RATE_LIMIT_MAX="${DEV_API_RATE_LIMIT_MAX:-5000}"

# ------------------------------------------------------------- Postgres up
if ! "$PGBIN/pg_isready" -q -h "$DB_HOST" -p 5432; then
  command -v brew >/dev/null || die "Postgres is not running on $DB_HOST:5432. Start it, then re-run."
  say "Postgres is not running; starting it: brew services start postgresql@16"
  brew services start postgresql@16 >/dev/null
  for _ in $(seq 1 20); do
    "$PGBIN/pg_isready" -q -h "$DB_HOST" -p 5432 && break
    sleep 0.5
  done
  "$PGBIN/pg_isready" -q -h "$DB_HOST" -p 5432 || die "Postgres did not come up on $DB_HOST:5432."
fi
say "Postgres is accepting connections on $DB_HOST:5432."

if ! "$PGBIN/psql" "$DATABASE_URL" -Atc 'select 1' >/dev/null 2>&1; then
  ADMIN_URL="$(node -e 'const u = new URL(process.argv[1]); u.pathname = "/postgres"; process.stdout.write(u.toString())' "$DATABASE_URL")"
  say "Creating database $DB_NAME_IN_URL."
  "$PGBIN/psql" "$ADMIN_URL" -v ON_ERROR_STOP=1 -qc "CREATE DATABASE \"$DB_NAME_IN_URL\"" \
    || die "Could not create database $DB_NAME_IN_URL."
fi

# ---------------------------------------------------------- port is free
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "Port $PORT is already in use (an earlier backend still running?). Stop it, then re-run."
fi

cd "$ROOT"

# ----------------------------------------------------------- migrate + seed
say "Applying database migrations to $DB_NAME_IN_URL."
pnpm --silent --filter @workspace/db run migrate
echo # drizzle-kit's progress line ends without a newline

say "Seeding demo data${RESET:+ (reset)}."
pnpm --silent --filter @workspace/api-server run seed:ios-dev ${RESET:+"$RESET"}

# ------------------------------------------------------------- build + run
say "Building the API."
pnpm --silent --filter @workspace/api-server run build

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
cat <<EOF

  Moolahub local backend (offline: test money only, no chain, no email)
  -------------------------------------------------------------------
  Simulator:   http://localhost:$PORT/api
  iPhone:      http://$LAN_NAME.local:$PORT/api   (same Wi-Fi as this Mac)
${LAN_IP:+  iPhone (IP): http://$LAN_IP:$PORT/api}
  Health:      http://localhost:$PORT/api/healthz
  Demo login:  demo@moolahub.test, password = DEMO_PASSWORD in
               artifacts/api-server/scripts/seed-ios-dev.ts
  Codes:       sign-up / reset codes appear below as "[DEV ONLY] ... code".
  If the phone can't connect, allow incoming connections for "node" in
  System Settings > Network > Firewall.  Ctrl-C stops the server.

EOF

cd "$ROOT/artifacts/api-server"
exec node --enable-source-maps ./dist/index.mjs
