#!/usr/bin/env bash
# Closeout A-R2-18: the signer check passes in the layout runbook step 5 describes (the audited commit checked out in a
# clean tree, the ceremony files copied into deployments/<network>/ as untracked files), and fails on a tracked change,
# an untracked source or another inputs hash. Builds a throwaway git repository under $TMPDIR (contracts/ copied from
# this checkout without build output, lib/ linked to its pinned dependency checkouts, the CI workflow copied for the
# pins). No RPC, no keys; nothing outside the temporary directory is written. Two `forge build`s: a few minutes.
# Run from contracts/: bash test/shell/check-manifest-bytecode.signer-layout.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
src=$(pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.github/workflows"
cp ../.github/workflows/contracts-ci.yml "$tmp/.github/workflows/"
# git ls-files would miss the uncommitted sources of a working checkout: copy everything git does not ignore.
rsync -a --exclude out --exclude cache --exclude lib --exclude broadcast --exclude deployments/rehearsal \
  --exclude 'deployments/base-mainnet' "$src/" "$tmp/contracts/"
ln -s "$src/lib" "$tmp/contracts/lib"
cd "$tmp"
git init -q && git add -A && git -c user.email=closeout@test -c user.name=closeout commit -qm audited
sha=$(git rev-parse HEAD)
cd contracts
env -u FOUNDRY_OUT -u FOUNDRY_CACHE_PATH forge build >/dev/null 2>&1 || { echo "FAIL  forge build"; exit 1; }
gen=$(env -u FOUNDRY_OUT -u FOUNDRY_CACHE_PATH forge script test/shell/GenSignerCeremony.s.sol \
  --sig "run(string,string)" deployments/base-mainnet/ "$sha" 2>&1)
hash=$(printf '%s\n' "$gen" | sed -nE 's/.*INPUTS_HASH=(0x[0-9a-f]{64}).*/\1/p' | head -1)
[ -n "$hash" ] || { echo "FAIL  ceremony generation"; printf '%s\n' "$gen" | tail -5; exit 1; }
fail=0
check() { env -u FOUNDRY_OUT -u FOUNDRY_CACHE_PATH bash script/check-manifest-bytecode.sh "$@" 2>&1; }
o=$(check --signer "$sha" --inputs-hash "$hash" deployments/base-mainnet/manifest.json); rc=$?
if [ "$rc" = 0 ] && ! printf '%s\n' "$o" | grep -q FAIL; then
  echo "PASS  A-R2-18 runbook layout (audited commit, ceremony files untracked in deployments/) passes"
else
  echo "FAIL  A-R2-18 runbook layout (exit $rc):"; printf '%s\n' "$o" | grep FAIL; fail=1
fi
zero=0x0000000000000000000000000000000000000000000000000000000000000000
o=$(check --signer "$sha" --inputs-hash "$zero" deployments/base-mainnet/manifest.json); rc=$?
if [ "$rc" != 0 ] && printf '%s\n' "$o" | grep -q "independent ceremony record"; then
  echo "PASS  R2-08 another inputs hash is refused"
else
  echo "FAIL  R2-08 inputs hash anchor (exit $rc)"; fail=1
fi
echo "// stray" > src/circles/Stray.sol
o=$(check --signer "$sha" --inputs-hash "$hash" deployments/base-mainnet/manifest.json); rc=$?
if [ "$rc" != 0 ] && printf '%s\n' "$o" | grep -q "untracked files outside deployments"; then
  echo "PASS  an untracked source is refused"
else
  echo "FAIL  untracked source (exit $rc)"; fail=1
fi
rm src/circles/Stray.sol
echo "" >> README.md
o=$(check --signer "$sha" --inputs-hash "$hash" deployments/base-mainnet/manifest.json); rc=$?
if [ "$rc" != 0 ] && printf '%s\n' "$o" | grep -q "tracked files differ from the audited commit"; then
  echo "PASS  a tracked change is refused"
else
  echo "FAIL  tracked change (exit $rc)"; fail=1
fi
exit "$fail"
