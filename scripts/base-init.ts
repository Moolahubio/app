/**
 * One-time Base setup: generate the platform account (faucet / escrow / payouts)
 * and print the env vars to add. Unlike Stellar's friendbot, EVM testnet funds
 * come from public faucets — follow the printed instructions to fund the address
 * with Base Sepolia ETH (gas) and test USDC.
 *
 *   npm run base:init
 */
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const USDC_SEPOLIA = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";

function main() {
  const privateKey = generatePrivateKey();
  const account = privateKeyToAccount(privateKey);

  console.log("\n✔ Generated the MoolaHub platform account (Base).\n");
  console.log("Add these to your .env:\n");
  console.log(`BASE_NETWORK="sepolia"`);
  console.log(`BASE_RPC_URL="https://sepolia.base.org"`);
  console.log(`USDC_CONTRACT_ADDRESS="${USDC_SEPOLIA}"`);
  console.log(`PLATFORM_PRIVATE_KEY="${privateKey}"`);
  console.log(`BASE_EXPLORER_URL="https://sepolia.basescan.org"`);
  console.log(`\nPlatform address: ${account.address}\n`);
  console.log("Next, fund that address on Base Sepolia:");
  console.log("  • ETH (gas):  https://docs.base.org/base-chain/tools/network-faucets");
  console.log("                or the Coinbase Developer Platform faucet");
  console.log(`  • test USDC:  Circle faucet → https://faucet.circle.com (select Base Sepolia)`);
  console.log("\nKeep PLATFORM_PRIVATE_KEY secret — set it as a deployment secret, never commit it.\n");
}

main();
