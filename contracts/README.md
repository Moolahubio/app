# MoolaHub Contracts

Solidity contracts for MoolaHub's on-chain layer on **Base Sepolia** (testnet first). Built with Foundry + OpenZeppelin v5, Solidity 0.8.28.

> **Unaudited.** Custodies user funds — must pass an external audit before mainnet. See `../docs/blockchain/BLOCKCHAIN_BUILD_SPEC.md` for the full design and security requirements.

## Contracts

| Contract | What it does |
|----------|--------------|
| `MoolaHubSusuEscrow` | Per-circle rotating-savings (ROSCA) escrow. Non-discretionary: pays each round's positional recipient automatically; 2% fee to treasury; refunds on cancellation; flags missed contributions to the reputation registry. Deployed as EIP-1167 clones. |
| `MoolaHubCircleFactory` | Deploys & registers escrow clones deterministically (CREATE2). Holds uniform policy (fee, treasury, guardian, reputation). Owner-gated creation. |
| `MoolaHubGoalVault` | Singleton personal-savings vault. Non-custodial (only the owner of a balance can withdraw). Free deposits; 2% withdrawal fee; early withdrawal always allowed. |
| `MoolaHubTreasury` | Passive fee sink; owner-only withdrawals. Never touches principal. |
| `MoolaHubReputation` | Append-only bad-actor registry; escrows report members who miss a round deadline. Enforcement is off-chain. |

## Layout

```
src/                interfaces/ + the five contracts
script/Deploy.s.sol full-stack deployment script
test/               unit tests + MockUSDC (6dp, EIP-2612 permit)
foundry.toml        toolchain + Base Sepolia rpc/etherscan config
```

## Quickstart

```bash
git clone --depth 1 --branch v5.1.0 https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
git clone --depth 1 --branch v1.9.4 https://github.com/foundry-rs/forge-std lib/forge-std
forge build
forge test -vv      # 17 tests
```

## Deploy

You deploy and own the contracts. Follow **[`DEPLOYMENT.md`](./DEPLOYMENT.md)** — a step-by-step Base Sepolia runbook including an end-to-end functional test.

## Key parameters

- Fee: **2% (200 bps)** on Susu disbursement and Goal withdrawal; cap 5%.
- USDC (Base Sepolia, Circle): `0x036CbD53842c5426634e7929541eC2318f3dCF7e`
- Account model: Privy + ERC-4337 (Safe), EntryPoint v0.7, user-signed, gasless via paymaster.
