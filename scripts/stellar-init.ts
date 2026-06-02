/**
 * One-time Stellar testnet bootstrap for the USDC stand-in asset.
 *
 * Generates an issuer + distributor account, funds them via friendbot,
 * establishes the distributor's trustline, and mints an initial USDC supply
 * to the distributor. Prints the env vars to paste into `.env`.
 *
 * Requires outbound network access to Horizon + friendbot. Run from any
 * networked environment:  npm run stellar:init
 */
import { readFileSync } from "node:fs";
import {
  Keypair,
  Networks,
  Horizon,
  TransactionBuilder,
  Operation,
  Asset,
  BASE_FEE,
} from "@stellar/stellar-sdk";

try {
  for (const line of readFileSync(".env", "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
} catch {
  /* ignore */
}

const HORIZON = process.env.STELLAR_HORIZON_URL || "https://horizon-testnet.stellar.org";
const server = new Horizon.Server(HORIZON);

async function fund(pub: string) {
  const res = await fetch(`https://friendbot.stellar.org/?addr=${pub}`);
  if (!res.ok) throw new Error(`friendbot failed: ${res.status}`);
}

async function main() {
  console.log("Generating issuer + distributor keypairs…");
  const issuer = Keypair.random();
  const distributor = Keypair.random();

  console.log("Funding via friendbot…");
  await fund(issuer.publicKey());
  await fund(distributor.publicKey());

  const usdc = new Asset("USDC", issuer.publicKey());

  console.log("Establishing distributor trustline…");
  const distAccount = await server.loadAccount(distributor.publicKey());
  const trustTx = new TransactionBuilder(distAccount, {
    fee: BASE_FEE,
    networkPassphrase: Networks.TESTNET,
  })
    .addOperation(Operation.changeTrust({ asset: usdc, limit: "1000000000" }))
    .setTimeout(60)
    .build();
  trustTx.sign(distributor);
  await server.submitTransaction(trustTx);

  console.log("Minting initial USDC supply to distributor…");
  const issuerAccount = await server.loadAccount(issuer.publicKey());
  const mintTx = new TransactionBuilder(issuerAccount, {
    fee: BASE_FEE,
    networkPassphrase: Networks.TESTNET,
  })
    .addOperation(
      Operation.payment({ destination: distributor.publicKey(), asset: usdc, amount: "1000000" }),
    )
    .setTimeout(60)
    .build();
  mintTx.sign(issuer);
  await server.submitTransaction(mintTx);

  console.log("\n✔ Done. Add these to your .env:\n");
  console.log(`STELLAR_USDC_ISSUER_PUBLIC="${issuer.publicKey()}"`);
  console.log(`STELLAR_USDC_ISSUER_SECRET="${issuer.secret()}"`);
  console.log(`STELLAR_DISTRIBUTOR_PUBLIC="${distributor.publicKey()}"`);
  console.log(`STELLAR_DISTRIBUTOR_SECRET="${distributor.secret()}"`);
}

main().catch((e) => {
  console.error("\n✖ stellar:init failed:", e.message);
  console.error("  (Needs outbound access to Horizon + friendbot.)");
  process.exit(1);
});
