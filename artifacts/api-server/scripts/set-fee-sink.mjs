// Admin (owner-only) script: repoint the on-chain platform fee sink to
// FEE_RECIPIENT_ADDRESS on every fee-collecting contract, so the 2% fee is
// transferred directly to the recipient wallet at disbursement time. No
// pooling, no backend withdrawal endpoint. Idempotent: skips contracts whose
// treasury() already equals the recipient.
//
// Requires shared env: PLATFORM_PRIVATE_KEY (owner), FEE_RECIPIENT_ADDRESS,
// CIRCLE_FACTORY_ADDRESS, GOAL_VAULT_ADDRESS, ACCUMULATION_FACTORY_ADDRESS.
// Never prints the private key.
import { createWalletClient, createPublicClient, http, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { monadTestnet } from "viem/chains";

const IS_MAINNET = (process.env.CHAIN_NETWORK ?? process.env.BASE_NETWORK) === "mainnet";
if (IS_MAINNET) throw new Error("Refusing to run against mainnet");
const CHAIN = monadTestnet;
const RPC = process.env.CHAIN_RPC_URL || process.env.BASE_RPC_URL || "https://testnet-rpc.monad.xyz";

let pk = process.env.PLATFORM_PRIVATE_KEY;
if (!pk) throw new Error("PLATFORM_PRIVATE_KEY missing");
if (!pk.startsWith("0x")) pk = "0x" + pk;
const account = privateKeyToAccount(pk);

const recipientRaw = process.env.FEE_RECIPIENT_ADDRESS;
if (!recipientRaw) throw new Error("FEE_RECIPIENT_ADDRESS missing");
const recipient = getAddress(recipientRaw);

const targets = {
  CircleFactory: process.env.CIRCLE_FACTORY_ADDRESS,
  GoalVault: process.env.GOAL_VAULT_ADDRESS,
  AccumulationFactory: process.env.ACCUMULATION_FACTORY_ADDRESS,
};

const abi = [
  { type: "function", name: "setTreasury", stateMutability: "nonpayable", inputs: [{ name: "treasury_", type: "address" }], outputs: [] },
  { type: "function", name: "treasury", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
];

const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: CHAIN, transport: http(RPC) });

console.log("sender (must be owner):", account.address);
console.log("new fee sink (recipient):", recipient);

for (const [name, addrRaw] of Object.entries(targets)) {
  if (!addrRaw) { console.log(`${name}: address env missing, SKIP`); continue; }
  const address = getAddress(addrRaw);
  const [before, owner] = await Promise.all([
    pub.readContract({ address, abi, functionName: "treasury" }),
    pub.readContract({ address, abi, functionName: "owner" }),
  ]);
  if (owner.toLowerCase() !== account.address.toLowerCase()) {
    console.log(`${name} ${address}: NOT owner (owner=${owner}), SKIP`);
    continue;
  }
  if (before.toLowerCase() === recipient.toLowerCase()) {
    console.log(`${name} ${address}: already points at recipient, SKIP`);
    continue;
  }
  const hash = await wallet.writeContract({ address, abi, functionName: "setTreasury", args: [recipient] });
  const rcpt = await pub.waitForTransactionReceipt({ hash });
  const after = await pub.readContract({ address, abi, functionName: "treasury" });
  console.log(`${name} ${address}: ${before} -> ${after} | status=${rcpt.status} | tx https://testnet.monadvision.com/tx/${hash}`);
}
console.log("done");
