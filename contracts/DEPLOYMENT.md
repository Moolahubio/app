# MoolaHub Contracts — Base Sepolia Deployment Runbook

A step-by-step guide for **you** to deploy the contracts to Base Sepolia and be their **owner**. No one else needs your keys. Budget ~30 minutes the first time.

> **Testnet only.** Use a throwaway deployer key funded with test ETH. Never put a key that holds real money in a `.env` file. For mainnet later, the owner must be a multisig (see §10).

> **Migration note — current target is Monad Testnet (chainId 10143, MON gas).**
> The deploy scripts now default to the `monad_testnet` foundry profile and
> require `USDC_ADDRESS`/`OWNER_ADDRESS`/`GUARDIAN_ADDRESS` explicitly (fail-closed).
> Deploy with `--rpc-url monad_testnet` and verify per **§Verifying on Monad
> Testnet** below. The Base Sepolia steps that follow remain valid as a reference
> and fast rollback.

---

## Verifying on Monad Testnet

`foundry.toml` already defines the `monad_testnet` profile (chainId `10143`,
Etherscan v2 endpoint `https://api.etherscan.io/v2/api`). After deploying, verify
each contract; the per-circle clones are EIP-1167 minimal proxies, so verify each
implementation (`MoolaHubSusuEscrow`, `MoolaHubSusuAccumulation`) once.

Required env: `MONAD_TESTNET_RPC_URL`, and `MONADSCAN_API_KEY` (an Etherscan v2
multichain key) for the Etherscan path. Deploying with `--verify` auto-verifies;
to verify an already-deployed contract:

**Monadscan (Etherscan v2 — needs an API key):**
```bash
forge verify-contract <ADDRESS> src/MoolaHubGoalVault.sol:MoolaHubGoalVault \
  --chain 10143 --verifier etherscan --etherscan-api-key "$MONADSCAN_API_KEY" \
  --constructor-args $(cast abi-encode "constructor(address,address,uint16,address)" "$USDC_ADDRESS" "$FEE_RECIPIENT_ADDRESS" 200 "$OWNER_ADDRESS") \
  --watch
```

**MonadVision / Sourcify (no API key, trailing slash required):**
```bash
forge verify-contract <ADDRESS> src/MoolaHubGoalVault.sol:MoolaHubGoalVault \
  --chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/
```

**Hardhat alternative:** configure `etherscan.customChains` for `monadTestnet`
with `apiURL https://api.etherscan.io/v2/api?chainid=10143` and
`browserURL https://testnet.monadscan.com` (API key required), then
`npx hardhat verify <ADDRESS> --network monadTestnet`.

The verify step can print a misleading error even on success — confirm on the
explorer (https://testnet.monadvision.com or https://testnet.monadscan.com).
Source: docs.monad.xyz/guides/verify-smart-contract (foundry / hardhat).

---

## What you will deploy & who owns it

| Contract | Purpose | Owner after deploy |
|----------|---------|--------------------|
| `MoolaHubTreasury` | Holds the 2% fees | **You** |
| `MoolaHubReputation` | Tracks bad actors (missed contributions) | **You** |
| `MoolaHubSusuEscrow` (implementation) | Logic for circle escrows (cloned per circle) | No owner (logic only) |
| `MoolaHubCircleFactory` | Deploys circle escrows | **You** |
| `MoolaHubGoalVault` | Personal goal savings | **You** |
| Each circle escrow (a clone) | One per Susu circle | **No owner** (non-discretionary); **you** are guardian |

"You" = the address of the key you deploy with (unless you set `OWNER_ADDRESS`). Ownership is set at construction, so there's nothing extra to claim — you're the owner the moment it deploys.

---

## 1. Install Foundry

Foundry (`forge`, `cast`) is the toolchain.

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version   # confirm it prints a version
```

## 2. Create / choose your deployer wallet

You need a key that will be the owner. Two options:

**Option A — generate a fresh testnet key (recommended):**
```bash
cast wallet new
# prints an Address and a Private key — save both somewhere safe (testnet only)
```

**Option B — use an existing wallet** (e.g. MetaMask): export its private key. Again, only do this for a wallet you keep for testnet.

Note the **address** — that's who will own the contracts.

## 3. Fund the deployer with Base Sepolia ETH

You need a little test ETH for gas.

- Base Sepolia faucet list: https://docs.base.org/tools/network-faucets
- Coinbase Developer Platform faucet: https://portal.cdp.coinbase.com/products/faucet

Send test ETH to your deployer address. ~0.05 ETH is plenty.

Check it arrived:
```bash
cast balance <YOUR_ADDRESS> --rpc-url https://sepolia.base.org
```

## 4. Get the code and install dependencies

From the repo root:
```bash
cd contracts
git clone --depth 1 --branch v5.1.0 https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
git clone --depth 1 --branch v1.9.4 https://github.com/foundry-rs/forge-std lib/forge-std
```

This populates `lib/`. The remappings are already configured in `foundry.toml`.

## 5. Configure environment

Create `contracts/.env` (it's gitignored — never commit it):

```bash
# Your deployer key — you become the owner. TESTNET ONLY.
DEPLOYER_PRIVATE_KEY=0xYOUR_PRIVATE_KEY

# RPC + verification
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
BASESCAN_API_KEY=YOUR_BASESCAN_KEY        # from https://basescan.org/myapikey (free; optional but recommended)

# Optional overrides (sensible defaults if omitted):
# USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e   # Circle USDC on Base Sepolia (default)
# OWNER_ADDRESS=0x...    # defaults to the deployer (you)
# GUARDIAN_ADDRESS=0x... # defaults to the owner
# FEE_BPS=200            # 2% (default)
```

Load it into your shell:
```bash
set -a; source .env; set +a
```

## 6. Build and run the tests locally

Always do this before deploying:
```bash
forge build
forge test -vv     # expect: 17 passed; 0 failed
```

## 7. Choose your USDC

**Path A — functional test with a USDC you control (easiest to see it work).**
Deploy a mintable test USDC so you can fund test members freely:
```bash
forge create test/mocks/MockUSDC.sol:MockUSDC \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY --broadcast
# note the "Deployed to:" address, then point the stack at it:
export USDC_ADDRESS=<MOCKUSDC_ADDRESS>
```

**Path B — integrate with real Circle test USDC.**
Leave `USDC_ADDRESS` unset (defaults to Circle's `0x036C…F7e`). Get test USDC from https://faucet.circle.com (select Base Sepolia) into your member wallets.

## 8. Dry-run the deployment (no broadcast)

This simulates everything without spending gas — catches config errors first:
```bash
forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia -vvvv
```
Read the simulated logs; confirm the addresses and `Owner:` line look right.

## 9. Deploy + verify on Base Sepolia

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base_sepolia \
  --broadcast \
  --verify \
  -vvvv
```

On success it prints every contract address and writes them to `deployments/latest.json`. (If `--verify` fails because the key is missing, deploy without it and verify later — the contracts still work.)

## 10. Confirm you are the owner

```bash
cast call <CIRCLE_FACTORY> "owner()(address)" --rpc-url base_sepolia   # should equal your address
cast call <TREASURY>       "owner()(address)" --rpc-url base_sepolia
cast call <GOAL_VAULT>     "owner()(address)" --rpc-url base_sepolia
cast call <REPUTATION>     "owner()(address)" --rpc-url base_sepolia
cast call <REPUTATION>     "factory()(address)" --rpc-url base_sepolia # should equal the factory
```

These contracts use two-step ownership transfer (`Ownable2Step`), so if you ever hand ownership to a multisig, the new owner must call `acceptOwnership()` — your control can't be lost by a typo.

## 11. End-to-end functional test on testnet

This proves a full circle works. Using **Path A (MockUSDC)** so you can mint.

```bash
# --- set these from your deploy output ---
export RPC=base_sepolia
export FACTORY=<CIRCLE_FACTORY>
export USDC=<MOCKUSDC_ADDRESS>
export TREASURY=<TREASURY>

# Two test members (besides you). Generate them:
cast wallet new   # -> M2 address + key
cast wallet new   # -> M3 address + key
export M1=<YOUR_ADDRESS>      M1_KEY=$DEPLOYER_PRIVATE_KEY
export M2=<M2_ADDR>          M2_KEY=<M2_KEY>
export M3=<M3_ADDR>          M3_KEY=<M3_KEY>

# Give the two new members a little gas ETH (so they can sign), then mint each member 100 test USDC:
cast send $USDC "mint(address,uint256)" $M1 100000000 --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY
cast send $USDC "mint(address,uint256)" $M2 100000000 --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY
cast send $USDC "mint(address,uint256)" $M3 100000000 --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY

# 1) Create a circle (owner only). 100 USDC/round, 3 members, 7-day rounds, 1-day grace.
CIRCLE_ID=$(cast keccak "test-circle-1")
cast send $FACTORY "createCircle(bytes32,uint256,address[],uint64,uint64)" \
  $CIRCLE_ID 100000000 "[$M1,$M2,$M3]" 604800 86400 \
  --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY

# 2) Get the escrow address
export ESCROW=$(cast call $FACTORY "escrowOf(bytes32)(address)" $CIRCLE_ID --rpc-url $RPC)
echo "escrow: $ESCROW"

# 3) Each member approves the escrow, then contributes
cast send $USDC "approve(address,uint256)" $ESCROW 100000000 --rpc-url $RPC --private-key $M1_KEY
cast send $ESCROW "contribute()" --rpc-url $RPC --private-key $M1_KEY
cast send $USDC "approve(address,uint256)" $ESCROW 100000000 --rpc-url $RPC --private-key $M2_KEY
cast send $ESCROW "contribute()" --rpc-url $RPC --private-key $M2_KEY
cast send $USDC "approve(address,uint256)" $ESCROW 100000000 --rpc-url $RPC --private-key $M3_KEY
cast send $ESCROW "contribute()" --rpc-url $RPC --private-key $M3_KEY   # this fills round 1 and auto-pays M1

# 4) Verify: round 1 recipient (M1) received 98 USDC, treasury got 2 USDC, round advanced to 2
cast call $USDC "balanceOf(address)(uint256)" $M1 --rpc-url $RPC        # +98e6 vs before
cast call $USDC "balanceOf(address)(uint256)" $TREASURY --rpc-url $RPC  # 2e6
cast call $ESCROW "currentRound()(uint256)" --rpc-url $RPC              # 2
```

Repeat the approve+contribute cycle for rounds 2 and 3 to watch M2 then M3 get paid, and the escrow complete. View everything on https://sepolia.basescan.org by searching the escrow address.

**Goal vault quick check:**
```bash
export VAULT=<GOAL_VAULT>
GOAL=$(cast keccak "vacation")
cast send $USDC "approve(address,uint256)" $VAULT 50000000 --rpc-url $RPC --private-key $M1_KEY
cast send $VAULT "deposit(bytes32,uint256)" $GOAL 50000000 --rpc-url $RPC --private-key $M1_KEY
cast send $VAULT "withdraw(bytes32,uint256)" $GOAL 50000000 --rpc-url $RPC --private-key $M1_KEY
# M1 receives 49 USDC (2% fee); treasury +1 USDC
```

## 12. Hand the addresses to the backend

Copy the addresses from `deployments/latest.json` into the API server env (see `docs/blockchain/BLOCKCHAIN_BUILD_SPEC.md` §11.4):
`CIRCLE_FACTORY_ADDRESS`, `GOAL_VAULT_ADDRESS`, `TREASURY_ADDRESS`, `USDC_CONTRACT_ADDRESS`.

---

## Security reminders

- **Never commit `.env`** or share your private key. It's gitignored — keep it that way.
- The deployer key is **testnet only**. For mainnet, deploy with `OWNER_ADDRESS` set to a **multisig** (e.g. Safe) and ideally a timelock, and have the multisig call `reputation.setFactory(...)` (the script prints a reminder when owner ≠ deployer).
- **Escrows are non-discretionary** — even you, as guardian, can only pause and open refunds; you cannot redirect a payout. That's by design.
- These contracts are **unaudited**. Do not move real user funds on mainnet until an external audit is complete (spec §10.6).
