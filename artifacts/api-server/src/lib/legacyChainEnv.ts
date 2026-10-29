/**
 * Boot check for a Base environment (docs/privy-account-layer.md §4, "Boot
 * checks on 8453", and F7): today's Monad testnet and server-custody settings
 * never reach a Base environment. With CHAIN_ID set to Base (8453) or Base
 * Sepolia (84532), the API refuses to start while any of them is set. Today's
 * testnet API sets no CHAIN_ID, so it is not affected. Messages name the
 * variable, never its value.
 *
 * Names the Base build reuses (TREASURY_ADDRESS, CIRCLE_FACTORY_ADDRESS,
 * REPUTATION_ADDRESS) are not listed: the role manifest check covers them.
 */
export const BASE_CHAIN_IDS: readonly string[] = ["8453", "84532"];

export const LEGACY_CHAIN_ENV = [
  "CHAIN_RPC_URL",
  "CHAIN_NETWORK",
  "CHAIN_EXPLORER_URL",
  "MONAD_TESTNET_RPC_URL",
  "MONAD_EXPLORER_URL",
  "MONADSCAN_API_KEY",
  "USDC_CONTRACT_ADDRESS",
  "GOAL_VAULT_ADDRESS",
  "ESCROW_IMPL_ADDRESS",
  "ACCUMULATION_FACTORY_ADDRESS",
  "FEE_RECIPIENT_ADDRESS",
  "ENABLE_TEST_FAUCET",
  "ENABLE_DEPOSIT_SYNC",
  "ENABLE_PRIVY_CUSTODY",
  "PLATFORM_PRIVATE_KEY",
  "DEPLOYER_PRIVATE_KEY",
] as const;

export function legacyChainEnvProblems(env: Record<string, string | undefined>): string[] {
  if (!BASE_CHAIN_IDS.includes(env.CHAIN_ID?.trim() ?? "")) return [];
  return LEGACY_CHAIN_ENV.filter((name) => (env[name]?.trim() ?? "") !== "").map(
    (name) => `${name} is a Monad testnet or server-custody setting`,
  );
}

/** Throws before the server takes a request when a Base environment still carries a testnet setting. */
export function assertNoLegacyChainEnv(env: Record<string, string | undefined> = process.env): void {
  const problems = legacyChainEnvProblems(env);
  if (problems.length) {
    throw new Error(
      `Refusing to start: CHAIN_ID is a Base chain, but today's testnet settings are still set. ` +
        `Remove them from this environment (docs/privy-account-layer.md §4).\n${problems.map((p) => `  - ${p}`).join("\n")}`,
    );
  }
}
