/**
 * Unit tests for the Base boot check on today's testnet settings (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/legacyChainEnv.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { LEGACY_CHAIN_ENV, assertNoLegacyChainEnv, legacyChainEnvProblems } from "./legacyChainEnv";

// A fake value: the test only proves it never reaches the message.
const PLANTED = "planted-legacy-value-0000";

test("today's testnet API sets no CHAIN_ID and is not affected", () => {
  const env = Object.fromEntries(LEGACY_CHAIN_ENV.map((name) => [name, PLANTED]));
  assert.deepEqual(legacyChainEnvProblems(env), []);
  assert.deepEqual(legacyChainEnvProblems({ ...env, CHAIN_ID: "10143" }), [], "Monad testnet's chain ID is not a Base chain");
  assert.doesNotThrow(() => assertNoLegacyChainEnv(env));
});

test("a Base environment with no testnet setting starts", () => {
  for (const chainId of ["8453", "84532", " 8453 "]) {
    assert.deepEqual(legacyChainEnvProblems({ CHAIN_ID: chainId, TREASURY_ADDRESS: PLANTED, BASE_RPC_URL: PLANTED }), []);
  }
  assert.deepEqual(legacyChainEnvProblems({ CHAIN_ID: "8453", CHAIN_RPC_URL: "", ENABLE_TEST_FAUCET: "  " }), [], "empty values are unset");
});

test("a Base environment refuses to start with any testnet setting, naming it and never its value", () => {
  for (const chainId of ["8453", "84532"]) {
    for (const name of LEGACY_CHAIN_ENV) {
      assert.deepEqual(legacyChainEnvProblems({ CHAIN_ID: chainId, [name]: PLANTED }), [
        `${name} is a Monad testnet or server-custody setting`,
      ]);
    }
  }
  assert.throws(
    () => assertNoLegacyChainEnv({ CHAIN_ID: "8453", CHAIN_RPC_URL: PLANTED, PLATFORM_PRIVATE_KEY: PLANTED }),
    (err: Error) =>
      /^Refusing to start: CHAIN_ID is a Base chain/.test(err.message) &&
      err.message.includes("CHAIN_RPC_URL") &&
      err.message.includes("PLATFORM_PRIVATE_KEY") &&
      !err.message.includes(PLANTED),
  );
});
