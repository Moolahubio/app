import { getAddress, isAddress } from "viem";

/**
 * Format check for role addresses at boot (CLAUDE.md non-negotiable,
 * replit.md). A role that is set must be EIP-55 checksummed, non-zero, not
 * shared with another role and not an EOA used during deployment
 * (DEPLOY_EOAS). The server's own signer counts as a deployer here: a role
 * held by a key the server holds would be an admin path.
 *
 * This is not the role manifest check of docs/privy-account-layer.md §6 P0
 * (still open): it cannot tell whether a person confirmed an address, it
 * passes when no role is set, and the deployer rule needs DEPLOY_EOAS. The
 * deploy gate is contracts/script/VerifyBase.s.sol, which compares the roles
 * with the deployment manifest and refuses an empty DEPLOY_EOAS.
 *
 * A role is checked when the running config needs it (REQUIRED_ROLES) or when
 * it is set at all. Messages name the variable and the rule, never a value.
 */
export const ROLE_NAMES = ["OWNER_ADDRESS", "GUARDIAN_ADDRESS", "TREASURY_ADDRESS"] as const;
export type RoleName = (typeof ROLE_NAMES)[number];

/** Roles the API's running config reads. None today; code that starts reading one adds it here. */
export const REQUIRED_ROLES: readonly RoleName[] = [];

const ZERO = /^0x0{40}$/i;

export function roleAddressProblems(
  env: Record<string, string | undefined>,
  opts: { required?: readonly RoleName[]; signers?: ReadonlyArray<string | null | undefined> } = {},
): string[] {
  const required = opts.required ?? REQUIRED_ROLES;
  const problems: string[] = [];

  const deployers = new Set<string>();
  const eoas = (env.DEPLOY_EOAS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  for (const eoa of eoas) {
    if (isAddress(eoa, { strict: false })) deployers.add(eoa.toLowerCase());
    else problems.push("DEPLOY_EOAS has an entry that is not an address");
  }
  for (const signer of opts.signers ?? []) if (signer) deployers.add(signer.toLowerCase());

  const roles = new Map<RoleName, string>();
  for (const name of ROLE_NAMES) {
    const value = env[name]?.trim() ?? "";
    if (!value) {
      if (required.includes(name)) problems.push(`${name} is required by this deployment but not set`);
      continue;
    }
    if (!isAddress(value, { strict: false })) problems.push(`${name} is not an address`);
    else if (getAddress(value) !== value) problems.push(`${name} is not in EIP-55 checksummed form`);
    else if (ZERO.test(value)) problems.push(`${name} is the zero address`);
    else roles.set(name, value.toLowerCase());
  }

  const entries = [...roles];
  for (let i = 0; i < entries.length; i++) {
    for (let j = i + 1; j < entries.length; j++) {
      if (entries[i][1] === entries[j][1]) {
        problems.push(`${entries[i][0]} and ${entries[j][0]} are the same address; each role needs its own`);
      }
    }
  }
  for (const [name, address] of entries) {
    if (deployers.has(address)) problems.push(`${name} is a deployment EOA or the server's own signer`);
  }
  return problems;
}

/** Throws before the server takes a request when a role address breaks a format rule. */
export function assertRoleAddresses(
  env: Record<string, string | undefined> = process.env,
  signers: ReadonlyArray<string | null | undefined> = [],
): void {
  const problems = roleAddressProblems(env, { signers });
  if (problems.length) {
    throw new Error(
      `Refusing to start: a role address breaks a format rule. Each role is its own checksummed address ` +
        `and never a deployer (CLAUDE.md, replit.md).\n${problems.map((p) => `  - ${p}`).join("\n")}`,
    );
  }
}
