/**
 * Unit tests for the role address boot check (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/roleAddresses.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { getAddress } from "viem";
import { assertRoleAddresses, roleAddressProblems } from "./roleAddresses";

// EIP-55 test vectors, in checksummed form.
const OWNER = getAddress("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
const GUARDIAN = getAddress("0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359");
const TREASURY = getAddress("0xdbf03b407c01e7cd3cbea99509d93f8dddc8c6fb");
const DEPLOYER = getAddress("0xd1220a0cf47c7b9be7a2e6ba89f429762e7b9adb");

const valid = { OWNER_ADDRESS: OWNER, GUARDIAN_ADDRESS: GUARDIAN, TREASURY_ADDRESS: TREASURY };

// A format check only: it passes when no role is set. The role manifest check
// (docs/privy-account-layer.md §6 P0) is still open.
test("no role set and none required: nothing to check", () => {
  assert.deepEqual(roleAddressProblems({}), []);
  assert.deepEqual(roleAddressProblems({ OWNER_ADDRESS: "", TREASURY_ADDRESS: "  " }), []);
  assert.doesNotThrow(() => assertRoleAddresses({}));
});

test("three distinct checksummed roles, none a deployer, pass", () => {
  assert.deepEqual(roleAddressProblems({ ...valid, DEPLOY_EOAS: DEPLOYER }, { signers: [null] }), []);
});

test("a required role must be set", () => {
  assert.deepEqual(roleAddressProblems({}, { required: ["TREASURY_ADDRESS"] }), [
    "TREASURY_ADDRESS is required by this deployment but not set",
  ]);
});

test("a role must be an EIP-55 checksummed, non-zero address", () => {
  assert.deepEqual(roleAddressProblems({ OWNER_ADDRESS: "treasury-safe" }), ["OWNER_ADDRESS is not an address"]);
  assert.deepEqual(roleAddressProblems({ OWNER_ADDRESS: OWNER.toLowerCase() }), [
    "OWNER_ADDRESS is not in EIP-55 checksummed form",
  ]);
  const typo = OWNER.slice(0, 2) + OWNER.slice(2, 3).toLowerCase() + OWNER.slice(3, 4).toUpperCase() + OWNER.slice(4);
  assert.notEqual(typo, OWNER);
  assert.deepEqual(roleAddressProblems({ OWNER_ADDRESS: typo }), ["OWNER_ADDRESS is not in EIP-55 checksummed form"]);
  assert.deepEqual(roleAddressProblems({ GUARDIAN_ADDRESS: `0x${"0".repeat(40)}` }), ["GUARDIAN_ADDRESS is the zero address"]);
});

test("two roles may not share an address", () => {
  assert.deepEqual(roleAddressProblems({ ...valid, TREASURY_ADDRESS: OWNER }), [
    "OWNER_ADDRESS and TREASURY_ADDRESS are the same address; each role needs its own",
  ]);
});

test("no role may be a deployment EOA or the server's own signer", () => {
  assert.deepEqual(roleAddressProblems({ ...valid, DEPLOY_EOAS: `${DEPLOYER}, ${GUARDIAN.toLowerCase()}` }), [
    "GUARDIAN_ADDRESS is a deployment EOA or the server's own signer",
  ]);
  assert.deepEqual(roleAddressProblems(valid, { signers: [TREASURY] }), [
    "TREASURY_ADDRESS is a deployment EOA or the server's own signer",
  ]);
  assert.deepEqual(roleAddressProblems({ DEPLOY_EOAS: "0x123" }), ["DEPLOY_EOAS has an entry that is not an address"]);
});

test("boot fails fast with every problem and never prints an address", () => {
  const env = { OWNER_ADDRESS: OWNER.toLowerCase(), GUARDIAN_ADDRESS: DEPLOYER, TREASURY_ADDRESS: DEPLOYER, DEPLOY_EOAS: DEPLOYER };
  assert.throws(
    () => assertRoleAddresses(env),
    (err: Error) => {
      assert.match(err.message, /^Refusing to start: a role address breaks a format rule/);
      assert.match(err.message, /OWNER_ADDRESS is not in EIP-55 checksummed form/);
      assert.match(err.message, /GUARDIAN_ADDRESS and TREASURY_ADDRESS are the same address/);
      assert.match(err.message, /GUARDIAN_ADDRESS is a deployment EOA/);
      for (const address of [OWNER, DEPLOYER]) {
        assert.ok(!err.message.toLowerCase().includes(address.slice(2).toLowerCase()), "no address in the message");
      }
      return true;
    },
  );
});
