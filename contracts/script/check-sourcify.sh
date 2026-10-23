#!/usr/bin/env bash
# Spec §5 VerifyBase, last item: every deployed contract is the AUDITED build, and its Sourcify record is an exact
# match OF THAT BUILD. Read-only. Needs forge, cast, curl and jq; run from contracts/ after `forge clean && forge build`
# on the audited commit.
#
#   RPC_URL=<Base RPC> script/check-sourcify.sh deployments/base-mainnet/manifest.json
#
# Audit R2-04: an `exact_match` alone proves only that SOME published source compiles to whatever sits at an address,
# and anyone can publish the source of a substituted contract. So, for each of the seven contracts:
#   1. CheckManifest (offline) first proves the manifest's runtimeCodeHash values are the runtime the LOCAL build
#      produces (each initcode run in the local EVM), so they are the audited runtime;
#   2. the code at the address on chain (`cast codehash`) equals that runtimeCodeHash;
#   3. Sourcify reports `runtimeMatch == "exact_match"` (the metadata hash matches too, so the published sources are
#      exactly the ones the runtime commits to) and the on-chain bytecode Sourcify verified hashes to the same value.
# `creationMatch` is printed as well: for CREATE3 deployments Sourcify may not locate the creation transaction, so it
# is informational. Submit verification first (`forge verify-contract --verifier sourcify ...`, see README).
set -euo pipefail

manifest="${1:?usage: RPC_URL=<rpc> check-sourcify.sh <dir>/manifest.json}"
rpc="${RPC_URL:?set RPC_URL to a Base RPC endpoint}"
api="${SOURCIFY_API:-https://sourcify.dev/server}"
case "$manifest" in
  */manifest.json) dir="${manifest%manifest.json}" ;;
  *) echo "FAIL  the argument must be a path ending in /manifest.json"; exit 1 ;;
esac
chain=$(jq -r '.chainId' "$manifest")
fail=0

if ! forge script script/CheckManifest.s.sol --sig "run(string)" "$dir" >/dev/null 2>&1; then
  echo "FAIL  CheckManifest: the manifest is not the plan (and runtime) derived from its inputs and the local build"
  exit 1
fi
echo "OK    CheckManifest: runtime codehashes derived from the local build"

for key in rotatingImpl accumulationImpl timelock canceller registry reputation factory; do
  addr=$(jq -r ".contracts.${key}.address" "$manifest")
  name=$(jq -r ".contracts.${key}.contract" "$manifest")
  want=$(jq -r ".contracts.${key}.runtimeCodeHash" "$manifest")
  onchain=$(cast codehash "$addr" --rpc-url "$rpc" 2>/dev/null || echo "none")
  resp=$(curl -s "${api}/v2/contract/${chain}/${addr}?fields=runtimeBytecode" || true)
  runtime=$(jq -r '.runtimeMatch // "none"' <<<"$resp" 2>/dev/null || echo "none")
  creation=$(jq -r '.creationMatch // "none"' <<<"$resp" 2>/dev/null || echo "none")
  verified_code=$(jq -r '.runtimeBytecode.onchainBytecode // ""' <<<"$resp" 2>/dev/null || echo "")
  verified=$([ -n "$verified_code" ] && cast keccak "$verified_code" || echo "none")
  if [ "$onchain" = "$want" ] && [ "$runtime" = "exact_match" ] && [ "$verified" = "$want" ]; then
    printf 'OK    %-22s %s runtime=%s creation=%s codehash=%s\n' "$name" "$addr" "$runtime" "$creation" "$want"
  else
    printf 'FAIL  %-22s %s runtime=%s creation=%s\n' "$name" "$addr" "$runtime" "$creation"
    printf '        audited %s\n        on chain %s\n        Sourcify %s\n' "$want" "$onchain" "$verified"
    fail=1
  fi
done

exit "$fail"
