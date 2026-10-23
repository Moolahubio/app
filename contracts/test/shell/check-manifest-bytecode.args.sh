#!/usr/bin/env bash
# Regression for audit 2 R1-04, R1-15, R2-08 and R2-17 (verifier PoCs `poc/verify_signer_anchor.sh` and
# `poc/ci_manifest_step_poc.sh`): argument handling of script/check-manifest-bytecode.sh. Needs no RPC and no build.
# Run from contracts/: bash test/shell/check-manifest-bytecode.args.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
S=script/check-manifest-bytecode.sh
fail=0
expect() { # expect <label> <exit code> <grep pattern> <args...>
  local label="$1" want="$2" pat="$3"; shift 3
  out=$(env -u FOUNDRY_OUT -u FOUNDRY_CACHE_PATH bash "$S" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qE "$pat"; then
    echo "PASS  $label"
  else
    echo "FAIL  $label (exit $rc, want $want; output: $out)"; fail=1
  fi
}
# R1-04: the old README command (`--signer <manifest path>`) and any path or JSON file are usage errors.
expect "R1-04 README-verbatim --signer <manifest> is refused" 1 "not a file" \
  --signer deployments/base-mainnet/manifest.json
expect "R1-04 --signer <manifest> <manifest> is refused" 1 "not a file" \
  --signer deployments/base-mainnet/manifest.json deployments/base-mainnet/manifest.json
expect "R1-04 --signer <existing path> is refused" 1 "not a path" --signer foundry.toml deployments/x/manifest.json
expect "R1-04 --signer <directory> is refused" 1 "not a path" --signer deployments deployments/x/manifest.json
# R1-15: CI mode skips a network without a committed ceremony; signer mode does not.
expect "R1-15 CI mode skips a missing manifest" 0 "^SKIP" deployments/base-sepolia-not-committed/manifest.json
expect "R1-15 signer mode fails on a missing manifest" 1 "not found" \
  --signer 0123456789abcdef0123456789abcdef01234567 deployments/base-sepolia-not-committed/manifest.json
expect "a non-manifest path is refused" 1 "must be a path ending in /manifest.json" deployments/base-mainnet
# Audit 2 R2-17: only a full 40-character SHA or a tag; never a branch or an abbreviated SHA.
expect "R2-17 --signer <branch> is refused" 1 "not a branch or an abbreviated SHA" \
  --signer main deployments/x/manifest.json
expect "R2-17 --signer <abbreviated SHA> is refused" 1 "not a branch or an abbreviated SHA" \
  --signer 0123456 deployments/x/manifest.json
expect "R2-17 --signer <uppercase SHA> is refused" 1 "not a branch or an abbreviated SHA" \
  --signer 0123456789ABCDEF0123456789ABCDEF01234567 deployments/x/manifest.json
# Audit 2 R2-08: the inputs hash from the independent ceremony record must be a 32-byte hash.
expect "R2-08 --inputs-hash <short> is refused" 1 "32-byte hex hash" \
  --signer 0123456789abcdef0123456789abcdef01234567 --inputs-hash 0x1234 deployments/x/manifest.json
# The CI step, as written in .github/workflows/contracts-ci.yml (literal paths + nullglob), now passes with
# neither ceremony committed.
if [ ! -f deployments/base-mainnet/manifest.json ] && [ ! -f deployments/base-sepolia/manifest.json ]; then
  if (shopt -s nullglob; for m in deployments/base-mainnet/manifest.json deployments/base-sepolia/manifest.json; do
        bash "$S" "$m" >/dev/null || exit 1; done); then
    echo "PASS  R1-15 CI step with no committed manifest exits 0"
  else
    echo "FAIL  R1-15 CI step with no committed manifest"; fail=1
  fi
fi
exit "$fail"
