#!/usr/bin/env bash
# Offline check of a ceremony directory (spec §5 runbook step 5, "every signer rebuilds and matches the manifest";
# also run by CI on every committed manifest). No RPC, no keys. Run from contracts/.
#
#   forge clean && forge build
#   script/check-manifest-bytecode.sh deployments/base-mainnet/manifest.json                              # CI
#   script/check-manifest-bytecode.sh --signer <audited tag or full SHA> --inputs-hash <hash> \
#       deployments/base-mainnet/manifest.json                                                           # signers
#
# The audited commit is the tag or SHA printed in the AUDIT REPORT. Never take it from the manifest, the coordinator or
# the ceremony files (audit 2 R1-04): the manifest records whatever commit the coordinator built, so anchoring to it
# accepts any backdoored build. An argument that names an existing file or ends in `.json` is refused, and so is any
# revision that is neither a full 40-character SHA nor a tag (audit 2 R2-17: a branch or an abbreviated SHA can be
# made to point elsewhere). The inputs hash comes from the independent ceremony record (audit 2 R2-08: the roles,
# Safes, operator, wrapper, delay, fees, seed and nonce the Gov signers agreed on before the build); signer mode
# fails without it. In CI mode (no --signer) a manifest path that does not exist is skipped with exit 0 (audit 2
# R1-15: CI lists both networks before either ceremony is committed); with --signer it is an error.
#
# 1. `script/CheckManifest.s.sol` (audit R1-05, R2-03, R2-04): trusts only the manifest's INPUTS (chain, roles, Safes,
#    params, salt seed, nonce, commit) and the local build. It re-applies the ceremony policy (delay in [48h, 7 days],
#    fee caps, per-role Safe thresholds, distinct roles, no Safe owned by a role, Gov/Guardian keys disjoint, the
#    chain's pinned circle vault), re-derives the manifest, both batch files and the allowVault proposal files and
#    requires byte equality, derives every runtime codehash by running the initcodes in the local EVM, decodes every
#    transaction the Gov Safe signs and recomputes every CREATE3 address, constructor argument list and Safe
#    transaction hash (both batches and both allowVault proposal transactions) without the planner. It prints every
#    input, the inputs hash and every hash a signer compares.
# 2. For each of the seven contracts, keccak256(creation code) of the local forge artifact equals the manifest's
#    `creationCodeHash` (catches a stale or differently configured build; `forge clean` first, because forge's
#    cache does not always notice a remapping change).
# 3. With --signer <audited commit> (audit R1-24, R2-18). The audited commit or tag is an ARGUMENT taken from the
#    audit report, never from the manifest (a file cannot contain the hash of the commit that contains it, so the
#    manifest is always produced after the audited commit). The check passes both in the layout runbook step 5
#    describes (the audited commit checked out, the ceremony files copied into deployments/<network>/) and in a later
#    commit that only adds the ceremony files:
#    - the argument resolves to a commit and equals the manifest's `commit`;
#    - every tracked file under contracts/, except deployments/, is identical to that commit (`git diff --quiet`);
#    - no untracked file exists outside deployments/<network>/ (untracked sources would be compiled);
#    - the git-ignored build inputs match: lib/openzeppelin-contracts and lib/forge-std are clean checkouts of the
#      commits pinned in the audited commit's .github/workflows/contracts-ci.yml, and no FOUNDRY_*/DAPP_* override is
#      set in the environment or in contracts/.env (forge reads both and they change compilation).
set -euo pipefail

signer=0
audited=""
inputs_hash=""
if [ "${1:-}" = "--signer" ]; then
  signer=1
  audited="${2:?usage: check-manifest-bytecode.sh --signer <audited commit or tag from the audit report> [--inputs-hash <hash>] <dir>/manifest.json}"
  # Audit 2 R1-04: `--signer deployments/.../manifest.json` (the old README) or a path is a usage error, not a commit.
  case "$audited" in
    *.json)
      echo "FAIL  --signer takes the audited commit or tag from the audit report, not a file: ${audited}"
      exit 1 ;;
  esac
  if [ -e "$audited" ]; then
    echo "FAIL  --signer takes the audited commit or tag from the audit report, not a path: ${audited}"
    exit 1
  fi
  # Audit 2 R2-17: a full 40-character SHA, or a tag (refs/tags/ only: never a branch or an abbreviated SHA).
  if printf '%s' "$audited" | grep -qE '^[0-9a-f]{40}$'; then
    audited_ref="$audited"
  elif git rev-parse --verify --quiet "refs/tags/${audited}^{commit}" >/dev/null 2>&1; then
    audited_ref="refs/tags/${audited}"
  else
    echo "FAIL  --signer takes the audited tag or the full 40-character commit SHA from the audit report, not a branch or an abbreviated SHA: ${audited}"
    exit 1
  fi
  shift 2
  if [ "${1:-}" = "--inputs-hash" ]; then
    inputs_hash="${2:?usage: --inputs-hash <0x… inputs hash from the independent ceremony record>}"
    if ! printf '%s' "$inputs_hash" | grep -qE '^0x[0-9a-fA-F]{64}$'; then
      echo "FAIL  --inputs-hash takes a 32-byte hex hash (0x followed by 64 hex characters): ${inputs_hash}"
      exit 1
    fi
    shift 2
  fi
fi
manifest="${1:?usage: check-manifest-bytecode.sh [--signer <audited commit from the audit report>] <dir>/manifest.json}"
case "$manifest" in
  */manifest.json) dir="${manifest%manifest.json}" ;;
  *) echo "FAIL  the argument must be a path ending in /manifest.json"; exit 1 ;;
esac
if [ ! -f "$manifest" ]; then
  # Audit 2 R1-15: CI checks every network's committed manifest; one that is not committed yet is not a failure.
  if [ "$signer" = 1 ]; then echo "FAIL  ${manifest} not found"; exit 1; fi
  echo "SKIP  ${manifest} not found (no ceremony committed for this network)"
  exit 0
fi
out="${FOUNDRY_OUT:-out}"
fail=0

if [ "$signer" = 1 ]; then
  # Build-affecting overrides first: they would change what CheckManifest compiles.
  if env | grep -qE '^(FOUNDRY|DAPP)_'; then
    echo "FAIL  FOUNDRY_*/DAPP_* variables are set in the environment (they override foundry.toml):"
    env | grep -E '^(FOUNDRY|DAPP)_' | sed 's/=.*//' | sed 's/^/        /'
    fail=1
  fi
  if [ -f .env ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?(FOUNDRY|DAPP)_' .env; then
    echo "FAIL  contracts/.env sets FOUNDRY_*/DAPP_* variables (forge loads it and they override foundry.toml)"
    fail=1
  fi
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT
if [ -n "$inputs_hash" ]; then
  check_args=(--sig "run(string,bytes32)" "$dir" "$inputs_hash")
else
  check_args=(--sig "run(string)" "$dir")
fi
if ! forge script script/CheckManifest.s.sol "${check_args[@]}" >"$log" 2>&1; then
  cat "$log"
  echo "FAIL  CheckManifest: the files differ from the plan re-derived from the manifest inputs, break policy, or"
  echo "      (with --inputs-hash) the inputs differ from the independent ceremony record"
  exit 1
fi
if [ "$signer" = 1 ] && [ -z "$inputs_hash" ]; then
  echo "FAIL  --inputs-hash <hash from the independent ceremony record> is required in signer mode (audit 2 R2-08)"
  fail=1
fi
sed -n '/CheckManifest: OK/,$p' "$log" | grep -vE '^(Script ran|Gas used|== Logs ==|$)' || true

for key in rotatingImpl accumulationImpl timelock canceller registry reputation factory; do
  name=$(jq -r ".contracts.${key}.contract" "$manifest")
  artifact="${out}/${name}.sol/${name}.json"
  if [ ! -f "$artifact" ]; then
    echo "FAIL  ${name}: artifact ${artifact} not found (run forge build)"
    fail=1
    continue
  fi
  code=$(jq -r '.bytecode.object' "$artifact")
  want_creation=$(jq -r ".contracts.${key}.creationCodeHash" "$manifest")
  got_creation=$(cast keccak "$code")
  if [ "$got_creation" = "$want_creation" ]; then
    printf 'OK    %-22s creation %s\n' "$name" "$got_creation"
  else
    printf 'FAIL  %-22s creation %s (manifest %s)\n' "$name" "$got_creation" "$want_creation"
    fail=1
  fi
done

if [ "$signer" = 1 ]; then
  if ! want=$(git rev-parse --verify --quiet "${audited_ref}^{commit}"); then
    echo "FAIL  ${audited} is not a commit in this repository (fetch the audited tag first)"
    exit 1
  fi
  manifest_commit=$(jq -r '.commit' "$manifest")
  if [ "$manifest_commit" = "$want" ]; then
    echo "OK    the manifest records the audited commit ${want}"
  else
    echo "FAIL  the manifest records ${manifest_commit}, the audited commit is ${want}"
    fail=1
  fi
  if git diff --quiet "$want" -- . ':(exclude)deployments'; then
    echo "OK    every tracked file under contracts/ (deployments/ excepted) equals the audited commit"
  else
    echo "FAIL  tracked files differ from the audited commit:"
    git diff --name-only "$want" -- . ':(exclude)deployments' | sed 's/^/        /'
    fail=1
  fi
  network=$(jq -r '.network' "$manifest")
  untracked=$(git ls-files --others --exclude-standard -- . ":(exclude)deployments/${network}")
  if [ -z "$untracked" ]; then
    echo "OK    no untracked file outside deployments/${network}/"
  else
    echo "FAIL  untracked files outside deployments/${network}/ (they would be compiled or read):"
    echo "$untracked" | sed 's/^/        /'
    fail=1
  fi
  ci=$(git show "${want}:.github/workflows/contracts-ci.yml" 2>/dev/null || true)
  for dep in "OZ_SHA lib/openzeppelin-contracts" "FORGE_STD_SHA lib/forge-std"; do
    set -- $dep
    pin=$(printf '%s\n' "$ci" | sed -nE "s/^[[:space:]]*$1:[[:space:]]*([0-9a-f]{40}).*/\1/p" | head -1)
    got=$(git -C "$2" rev-parse HEAD 2>/dev/null || echo "missing")
    dirty=$(git -C "$2" status --porcelain 2>/dev/null || echo "missing")
    if [ -n "$pin" ] && [ "$got" = "$pin" ] && [ -z "$dirty" ]; then
      echo "OK    $2 is a clean checkout of the pinned ${pin}"
    else
      echo "FAIL  $2 is ${got} (pinned ${pin:-unknown}${dirty:+, local changes})"
      fail=1
    fi
  done
fi

exit "$fail"
