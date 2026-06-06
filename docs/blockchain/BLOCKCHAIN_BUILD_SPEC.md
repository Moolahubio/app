# MoolaHub — Blockchain Backend & Smart Contract Build Specification

**Status:** Source of truth · v1.0 · June 2026
**Owner:** Product / Lead Dev
**Audience:** Blockchain engineer (smart contracts + on-chain backend)
**Target network:** Base Sepolia (testnet) → Base mainnet (later)
**Repo of record:** https://github.com/Moolahubio/app

> **Security notice.** MoolaHub is a financial application. Every line of contract code custodies user funds. Treat this document as binding: do not deviate from the security requirements in §10 without written sign-off from the Lead Dev. No contract reaches mainnet without an external audit (§10.6). All reference Solidity in this document is **unaudited illustration** of the intended behaviour and structure — it is a starting point, not production code.

---

## 0. How to read this document

This spec tells you (the blockchain engineer) exactly what to build and how to build it so MoolaHub becomes fully functional on-chain. It is organised so each contract has its own self-contained section with an interface, a reference skeleton, invariants, and acceptance criteria.

- §1–§4 — context: what MoolaHub is, what exists today, the target architecture, and the locked decisions.
- §5 — the account/wallet layer (Privy + ERC-4337). Build this first; everything else assumes it.
- §6–§9 — the contracts, one per section: Susu escrow, circle factory, goal vault, treasury.
- §10 — security requirements (mandatory).
- §11 — backend integration changes.
- §12 — testing & deployment on Base Sepolia.
- §13 — phasing, §14 — open questions, §15 — references.

Design philosophy is borrowed from the **non-discretionary escrow vault** pattern (the SynFutures × Anchored pre-market vault reference): funds in a contract may move to **only** a small, pre-encoded set of destinations; no operator key can redirect them; all economic parameters are fixed at deployment and independently verifiable on-chain. We apply that philosophy to MoolaHub's Susu circles, goal vaults, and fees.

---

## 1. What MoolaHub is

MoolaHub is a mobile-first savings app with two core products:

1. **Goals** — a user earmarks money toward a personal savings target (name, emoji, target amount, deadline, optional auto-save cadence).
2. **Susu circles** — a rotating savings & credit association (ROSCA / "esusu" / "ajo"). A fixed group of members each contributes a fixed amount every round; one member receives the whole pot each round, rotating until everyone has been paid once.

The unit of value is **USDC** (ERC-20, 6 decimals). The app already runs end-to-end against an internal ledger; this project moves real custody and settlement on-chain.

---

## 2. Current state (as built in `Moolahubio/app`)

This is what exists today. Read it carefully — the build is a migration, not a greenfield.

### 2.1 Stack
- **Monorepo:** pnpm workspaces, Node 24, TypeScript 5.9.
- **Frontend:** React 19 + Vite, shadcn/ui (`artifacts/moolahub-app`). Auth via `@privy-io/react-auth` v3.
- **Backend:** Express 5 (`artifacts/api-server`), PostgreSQL + Drizzle ORM (`lib/db`), Zod validation, Orval-generated API client from an OpenAPI spec (`lib/api-spec`). Auth via `@privy-io/server-auth`.
- **Chain integration:** `viem` v2 against Base Sepolia (`artifacts/api-server/src/lib/chain.ts`).

### 2.2 The money model today
- **A double-entry ledger in Postgres is the source of truth** (`lib/ledger.ts`, `transactions`/`postings`/`ledger_accounts`). Every movement is a balanced transaction; balances are always derived, never stored. Account keys: `wallet:<userId>`, `goal:<goalId>`, `pool:<circleId>`, `external`, `yield`, `fees`.
- **On-chain settlement mirrors the ledger asynchronously.** Movements commit to the ledger synchronously; a row is enqueued in `onchain_transfers` and a reconciler (`lib/settlement.ts`) retries the matching USDC transfer until it confirms. Claims use `FOR UPDATE SKIP LOCKED`; sends are idempotent; failures dead-letter after `SETTLEMENT_MAX_ATTEMPTS`.

### 2.3 What is NOT on-chain yet (the gap this project closes)
- **There are no smart contracts.** Every "on-chain" action is a plain ERC-20 `transfer()` between externally owned accounts (EOAs).
- **Wallets are custodial EOAs.** `lib/wallet.ts` generates a private key server-side and stores it **AES-256-GCM-encrypted** in `wallets.private_key_enc`. The server decrypts it at send time. This is explicitly described in the code as "a stand-in for a non-custodial signer."
- **The Susu "escrow" is the platform's own EOA.** In `lib/circles.ts`, `contribute()` settles member wallet → `platformAddress()`, and `maybeProcessPayout()` settles `platformAddress()` → recipient wallet. **The platform EOA literally custodies every circle's pot.** The `circles.contract_address` column exists but is unused/null. This is the central trust gap.
- **Goals are pure ledger earmarks** — no on-chain component (`lib/goals.ts`).
- **No fees** are charged today (the `fees` ledger account exists but is unused).

### 2.4 Relevant environment variables (today)
`BASE_NETWORK`, `BASE_RPC_URL`, `USDC_CONTRACT_ADDRESS`, `PLATFORM_PRIVATE_KEY`, `BASE_EXPLORER_URL`, `APP_ENCRYPTION_KEY`, `PRIVY_APP_ID`, `PRIVY_APP_SECRET`, `DATABASE_URL`, `SETTLEMENT_MAX_ATTEMPTS`.

---

## 3. Target architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Client (React + Privy)                                                │
│  • Privy embedded signer → ERC-4337 smart account (non-custodial)      │
│  • Signs UserOperations; gas sponsored by paymaster                    │
└───────────────┬───────────────────────────────────────────────────────┘
                │ session policy + UserOps
┌───────────────▼───────────────────────────────────────────────────────┐
│  API server (Express)                                                  │
│  • Ledger = authoritative off-chain projection (orchestration, UX)     │
│  • Relayer: builds & submits UserOps via bundler (or user signs)       │
│  • Indexer: reads contract events → reconciles ledger to chain         │
└───────────────┬───────────────────────────────────────────────────────┘
                │ JSON-RPC + bundler/paymaster
┌───────────────▼───────────────────────────────────────────────────────┐
│  Base Sepolia                                                          │
│  • USDC (Circle testnet ERC-20)                                        │
│  • EntryPoint (ERC-4337) + user smart accounts                         │
│  • MoolaHubCircleFactory → MoolaHubSusuEscrow (per circle)             │
│  • MoolaHubGoalVault (singleton)                                       │
│  • MoolaHubTreasury (fees)                                             │
└───────────────────────────────────────────────────────────────────────┘
```

**Layering of authority (read this twice):**

- **The chain is authoritative for custody and for rotation correctness.** Once funds enter a Susu escrow, only the contract can move them, and only to the pre-encoded destinations (the round's scheduled recipient, or refunds back to contributors). No platform key can redirect them. This is the non-discretionary guarantee.
- **The Postgres ledger remains the application's authoritative source of truth for orchestration, accounting, the activity feed, and all off-chain-only state** (goal earmarks that never left the user's own wallet, invitations, notifications, fee accounting). The ledger is kept in lockstep with the chain by the indexer (§11.3).
- **Reconciliation rule:** for funds held in a contract, on-chain balances are ground truth; if the ledger ever disagrees with a confirmed on-chain event, the indexer corrects the ledger to match the chain, and the discrepancy is logged for an operator. The ledger never overrides a confirmed on-chain fact about custodied funds.

---

## 4. Locked decisions

These were decided by the Lead Dev and are not open for re-litigation in this build.

| # | Decision | Choice |
|---|----------|--------|
| D1 | Custody / wallet model | **Non-custodial: Privy + ERC-4337 smart accounts, gasless via paymaster.** Retire custodial EOAs. |
| D2 | Susu escrow trust model | **Fully on-chain enforced rotation** — non-discretionary; the contract decides the recipient and releases funds. The backend cannot pick who gets paid. |
| D3 | Source of truth | **Postgres ledger stays authoritative for the app; chain mirrors it** (with the custody caveat in §3). |
| D4 | v1 contract scope | **Susu escrow + factory, Goal vault, Treasury / fee collector.** Yield is out of scope for v1 (designed-for, not built). |
| D5 | Reference doc role | The pre-market vault doc is a **design-pattern reference only** — apply its non-discretionary escrow philosophy. We are **not** building a pre-market/pre-IPO vault. |
| D6 | Deliverable | This Markdown spec with Solidity interfaces + reference skeletons. |

### 4.1 Confirmed parameters (build round 2)

These finalise the open questions and are reflected in the **built, tested contracts** under `contracts/` (17/17 Foundry tests passing):

- **Fee: 2% (200 bps)** charged on **Susu disbursement** and **Goal withdrawal** only — never on deposits or contributions. A recipient owed 1000 receives 980; the 20 goes to the treasury. The fee is collected inside the escrow/vault (not at a separate cash-out step) so a user cannot bypass it by exporting their Privy wallet. `MAX_FEE_BPS` cap = **500 (5%)**.
- **Smart-account implementation: Safe** (via Privy). Note: Coinbase Smart Wallet / "Base Account" does **not** require a Coinbase exchange account (it's passkey-based, self-custodial) — but Safe fits Privy's embedded-signer model best, so we use Safe.
- **EntryPoint: ERC-4337 v0.7** (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`).
- **Contributions are user-signed** for v1 — no backend session keys / no relayer moving user funds. Auto-save becomes a reminder-driven, user-signed action (deferred).
- **ROSCA default risk: enforced off-chain**, but the chain **tracks bad actors** via `MoolaHubReputation` — escrows record a strike against any member who misses a round deadline. What to do with strikes is a later product decision.
- **Goal vault: early withdrawal always allowed** (it's the user's money); `unlockAt` is advisory UI metadata only.
- **No KYC/KYB** gating.
- **Deployment: by the project owner (you), on Base Sepolia.** See `contracts/DEPLOYMENT.md`. The deployer becomes the owner of the Treasury, Reputation, Factory, and Goal vault; escrows are ownerless (non-discretionary) with you as guardian.

---

## 5. Account & wallet layer — Privy + ERC-4337 (build first)

Everything downstream assumes users hold their own funds in a smart account they control. This replaces the custodial EOA model in `lib/wallet.ts` and `lib/crypto.ts`.

### 5.1 Target
- Each user gets a **Privy embedded wallet** (signer) bound to an **ERC-4337 smart account**. Privy supports configurable account implementations — **Safe**, **Kernel (ZeroDev)**, **Biconomy**, **Alchemy Light Account**, **Coinbase Smart Wallet**. **Decision (D-r2): use Safe** — best fit for Privy's embedded-signer model, strongest audit pedigree. (Coinbase Smart Wallet does not require a Coinbase account, but is a bring-your-own-passkey UX, which doesn't fit the embedded model as cleanly.)
- **EntryPoint:** ERC-4337 **v0.7** (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`) is the safe default — broadest smart-account + bundler support today. **v0.8** (`0x4337084d9e255ff0702461cf8895ce9e3b5ff108`, adds EIP-7702) is available on Base/Base Sepolia and may be adopted once the chosen account implementation ships a v0.8 build; pin one version per environment.
- **Gas:** sponsored by a **paymaster** so users transact with zero ETH. Use **Coinbase Developer Platform (CDP) Paymaster + Bundler** (supports Base Sepolia and ERC-20/USDC gas). Pimlico, Alchemy, and ZeroDev are acceptable alternatives. Register the paymaster URL in the Privy dashboard.

### 5.2 Signing model — user-signed for v1 (D-r2)
**v1 is user-signed only.** Every fund-moving action (contribute, goal deposit/withdraw, external withdrawal) is a UserOp the user signs; gas is sponsored by the paymaster so it's still "gasless," but the user authorises each action. The backend never holds a key that can move user funds.

- Contributions use **EIP-2612 permit** so a contribution is a single signed action (permit + transfer in one), not approve-then-contribute. The escrow exposes `contributeWithPermit(...)`.
- Auto-save becomes a **reminder-driven, user-signed** action for v1 (a notification prompts the user to approve the periodic save).
- **Session keys / delegated relayer signing (ERC-7715 / ERC-7579) are deferred.** When revisited, a session key must be tightly scoped (only `contribute` on circles the user joined, capped at `contributionAmount`, once per round; goal deposits up to a per-period cap) and must never authorise withdrawals or arbitrary transfers. Until then, do not give the backend any fund-moving authority.

### 5.3 Migration from custodial EOAs
There are existing users with custodial EOAs (`wallets.private_key_enc`). Plan:
1. Provision a smart account for every user (new + existing).
2. For existing users with a non-zero on-chain USDC balance on their custodial EOA, sweep it to their new smart account in a one-time migration job (server signs the legacy EOA, which it still controls). Record each sweep in the ledger and the activity feed.
3. Mark the legacy key migrated; stop using it. Keep it encrypted and access-logged until all balances are confirmed zero, then schedule destruction.
4. New signups never generate a custodial key.

### 5.4 Acceptance criteria
- [ ] New user → smart account address provisioned and persisted; no server-held private key for that user.
- [ ] A contribution and a withdrawal both execute as gasless UserOps (user pays no ETH).
- [ ] Session key (if shipped) cannot move funds anywhere except the in-scope escrow/vault calls; verified by a negative test.
- [ ] Every legacy custodial balance is swept and reconciled; no user funds stranded.

---

## 6. Contract: `MoolaHubSusuEscrow` (rotating savings pot)

The heart of the system. One escrow instance per circle, deployed by the factory (§7) as a minimal-proxy clone of a single immutable implementation. It custodies a circle's contributions and enforces the rotation **trustlessly**: the recipient of each round is fixed by member position at deployment and cannot be changed by anyone.

### 6.1 Behaviour
- **Parameters are fixed at initialization** and immutable thereafter: the USDC token, the per-round contribution amount, the ordered member list (the order *is* the payout order), the number of rounds (= member count), the fee in basis points, the treasury address, the round duration, and the guardian.
- **Lifecycle:** `Active` → (`Completed` | `Cancelled`). The circle is initialized already-active with the locked roster (the app finalises the roster off-chain during the "forming" phase, then deploys).
- **Contribute:** a member transfers exactly `contributionAmount` USDC into the escrow for the current round. Each member may contribute at most once per round (enforced on-chain).
- **Automatic settlement:** when the last member contributes for a round, the escrow immediately pays the round's recipient — `recipient = members[round - 1]` — the pot minus the platform fee, sends the fee to the treasury, and advances the round. After the final round it marks itself `Completed`.
- **Non-discretionary:** no function lets anyone choose, change, or redirect the recipient. Funds can leave the escrow only as (a) a scheduled round payout to the positional recipient, (b) the platform fee to the immutable treasury, or (c) a refund to a contributor (cancellation path). Nothing else is possible.
- **Stall / cancellation:** if a round does not fill by its deadline plus a grace period, anyone may cancel the circle. Once cancelled, each contributor pulls back their **unsettled** contributions via `claimRefund`. Already-settled rounds stand (a paid recipient keeps the pot). The default-risk fairness tradeoff this implies is documented in §14.
- **Guardian:** may only `pause` (block new contributions and open the refund path in an emergency). The guardian **cannot** move funds to itself or any third party — verify this with a negative test.

### 6.2 Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMoolaHubSusuEscrow {
    enum Status { Active, Completed, Cancelled }

    event Contributed(address indexed member, uint256 indexed round, uint256 amount);
    event RoundSettled(uint256 indexed round, address indexed recipient, uint256 payout, uint256 fee);
    event CircleCompleted(uint256 totalRounds);
    event CircleCancelled(uint256 atRound, address indexed by);
    event Refunded(address indexed member, uint256 amount);

    /// @notice One-time initializer (clones have no constructor).
    function initialize(
        address usdc,
        uint256 contributionAmount,
        address[] calldata members, // index order == payout order
        uint16 feeBps,
        address treasury,
        uint64 roundDuration,
        uint64 gracePeriod,
        address guardian,
        bytes32 circleId           // off-chain UUID, for event correlation
    ) external;

    function contribute() external;          // pulls `contributionAmount` USDC from msg.sender
    function cancelStalled() external;        // permissionless once past deadline+grace
    function claimRefund() external;          // contributor pulls unsettled contributions back
    function pause() external;                // guardian only; opens refund path

    // Views
    function status() external view returns (Status);
    function currentRound() external view returns (uint256);
    function totalRounds() external view returns (uint256);
    function contributionAmount() external view returns (uint256);
    function members() external view returns (address[] memory);
    function currentRecipient() external view returns (address);
    function hasContributed(uint256 round, address member) external view returns (bool);
    function refundableOf(address member) external view returns (uint256);
}
```

### 6.3 Reference skeleton (unaudited — structure & security patterns)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMoolaHubSusuEscrow} from "./IMoolaHubSusuEscrow.sol";

contract MoolaHubSusuEscrow is IMoolaHubSusuEscrow, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 500; // hard cap 5% — protects users; MoolaHub uses 200 (2%)

    IERC20 public usdc;
    uint256 public contributionAmount;
    uint16 public feeBps;
    address public treasury;
    uint64 public roundDuration;
    uint64 public gracePeriod;
    address public guardian;
    bytes32 public circleId;

    address[] private _members;
    mapping(address => bool) public isMember;

    Status public status;
    uint256 public currentRound;     // 1-indexed
    uint256 public totalRounds;
    uint64 public roundDeadline;     // current round's deadline
    bool public paused;

    // round => member => contributed?
    mapping(uint256 => mapping(address => bool)) public hasContributed;
    mapping(uint256 => uint256) public roundContributions; // count per round
    // refundable principal per member (set on cancellation accounting path)
    mapping(address => uint256) public refundableOf;

    error NotMember();
    error NotActive();
    error AlreadyContributed();
    error NotGuardian();
    error NotStalled();
    error NothingToRefund();
    error BadConfig();

    /// @dev Disable initialization on the implementation itself.
    constructor() { _disableInitializers(); }

    function initialize(
        address _usdc,
        uint256 _contributionAmount,
        address[] calldata members_,
        uint16 _feeBps,
        address _treasury,
        uint64 _roundDuration,
        uint64 _gracePeriod,
        address _guardian,
        bytes32 _circleId
    ) external initializer {
        if (_usdc == address(0) || _treasury == address(0)) revert BadConfig();
        if (members_.length < 2) revert BadConfig();
        if (_contributionAmount == 0) revert BadConfig();
        if (_feeBps > MAX_FEE_BPS) revert BadConfig();

        usdc = IERC20(_usdc);
        contributionAmount = _contributionAmount;
        feeBps = _feeBps;
        treasury = _treasury;
        roundDuration = _roundDuration;
        gracePeriod = _gracePeriod;
        guardian = _guardian;
        circleId = _circleId;

        for (uint256 i; i < members_.length; ++i) {
            address m = members_[i];
            if (m == address(0) || isMember[m]) revert BadConfig(); // no zero / no dupes
            isMember[m] = true;
            _members.push(m);
        }

        status = Status.Active;
        currentRound = 1;
        totalRounds = members_.length;
        roundDeadline = uint64(block.timestamp) + _roundDuration;
    }

    function contribute() external nonReentrant {
        if (status != Status.Active || paused) revert NotActive();
        if (!isMember[msg.sender]) revert NotMember();
        uint256 round = currentRound;
        if (hasContributed[round][msg.sender]) revert AlreadyContributed();

        // Effects before interaction (CEI).
        hasContributed[round][msg.sender] = true;
        roundContributions[round] += 1;

        // Interaction: pull funds. Caller (smart account) must have approved.
        usdc.safeTransferFrom(msg.sender, address(this), contributionAmount);
        emit Contributed(msg.sender, round, contributionAmount);

        if (roundContributions[round] == totalRounds) {
            _settleRound(round);
        }
    }

    function _settleRound(uint256 round) private {
        address recipient = _members[round - 1]; // positional, non-discretionary
        uint256 pot = contributionAmount * totalRounds;
        uint256 fee = (pot * feeBps) / 10_000;
        uint256 payout = pot - fee;

        // Advance state before transfers (CEI).
        if (round == totalRounds) {
            status = Status.Completed;
        } else {
            currentRound = round + 1;
            roundDeadline = uint64(block.timestamp) + roundDuration;
        }

        if (fee > 0) usdc.safeTransfer(treasury, fee);
        usdc.safeTransfer(recipient, payout); // USDC has no transfer hook → safe push
        emit RoundSettled(round, recipient, payout, fee);
        if (status == Status.Completed) emit CircleCompleted(totalRounds);
    }

    function cancelStalled() external {
        if (status != Status.Active) revert NotActive();
        bool stalled = block.timestamp > roundDeadline + gracePeriod
            && roundContributions[currentRound] < totalRounds;
        if (!stalled && msg.sender != guardian) revert NotStalled();
        status = Status.Cancelled;
        _accrueRefunds(currentRound);
        emit CircleCancelled(currentRound, msg.sender);
    }

    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = true; // blocks contribute; does NOT let guardian move funds
    }

    /// @dev On cancellation, every contribution to the (unsettled) current round
    ///      is refundable to its contributor. Settled rounds stand.
    function _accrueRefunds(uint256 round) private {
        for (uint256 i; i < _members.length; ++i) {
            address m = _members[i];
            if (hasContributed[round][m]) refundableOf[m] += contributionAmount;
        }
    }

    function claimRefund() external nonReentrant {
        uint256 amount = refundableOf[msg.sender];
        if (amount == 0) revert NothingToRefund();
        refundableOf[msg.sender] = 0;          // effects
        usdc.safeTransfer(msg.sender, amount);  // interaction
        emit Refunded(msg.sender, amount);
    }

    function members() external view returns (address[] memory) { return _members; }
    function currentRecipient() external view returns (address) {
        return status == Status.Active ? _members[currentRound - 1] : address(0);
    }
}
```

### 6.4 Invariants (must hold; assert in invariant tests)
1. **Conservation:** `usdc.balanceOf(escrow) == Σ contributions_in − Σ payouts_out − Σ fees_out − Σ refunds_out` at all times.
2. **No leak:** the only addresses that ever receive USDC from the escrow are (a) `_members[round-1]` for each settled round, (b) `treasury`, (c) the original contributor on refund. Never an arbitrary address.
3. **Each member is paid exactly once** across a completed circle; `Σ payouts == contributionAmount * totalRounds * (1 − feeBps/1e4)` summed over rounds.
4. **One contribution per member per round.**
5. **Fee bound:** `feeBps <= MAX_FEE_BPS` always (enforced at init; no setter exists).
6. **Guardian cannot extract value:** there is no code path where `guardian` receives USDC.

### 6.5 Acceptance criteria
- [ ] Happy path: N members, N rounds, each round settles to the correct positional recipient, fee routed to treasury, `Completed` at the end.
- [ ] Double-contribute in a round reverts.
- [ ] Non-member contribute reverts.
- [ ] Stalled round past deadline+grace → `cancelStalled` → each unpaid contributor refunds their principal; settled recipients keep payouts; conservation holds.
- [ ] `pause` by guardian blocks contributions and cannot move funds (negative test).
- [ ] Reentrancy attempt on `contribute` / `claimRefund` via a malicious token mock fails (and is moot for real USDC).
- [ ] Rounding: with a fee that doesn't divide evenly, dust is handled deterministically (fee floor; recipient gets remainder) and conservation still holds.

---

## 7. Contract: `MoolaHubCircleFactory` (deploys & registers escrows)

Deploys one `MoolaHubSusuEscrow` clone per circle and records it on-chain. Deterministic addressing lets the backend compute and store `circles.contract_address` **before** the deploy transaction confirms.

### 7.1 Behaviour
- **Minimal-proxy clones (EIP-1167):** the factory holds one immutable escrow implementation and `clone`s it per circle — cheap deploys, identical audited logic every time.
- **Deterministic via CREATE2:** `salt = circleId` (the off-chain UUID, hashed). The backend predicts the address with `predictAddress(circleId)` and writes it to the DB before broadcasting.
- **Permissioned creation:** only the platform `deployer` role may create circles (the roster is KYC-gated and finalised off-chain). Use `Ownable2Step`; the owner should be a **multisig** (and a timelock for any implementation change).
- **Registry:** `escrowOf(circleId)` and a `CircleCreated` event for the indexer.
- **No upgrade-in-place of live escrows.** To change escrow logic, deploy a new factory pointing at a new implementation; existing circles keep running on their original immutable code.

### 7.2 Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMoolaHubCircleFactory {
    event CircleCreated(bytes32 indexed circleId, address indexed escrow, uint256 members, uint256 contributionAmount);

    function createCircle(
        bytes32 circleId,
        uint256 contributionAmount,
        address[] calldata members,
        uint16 feeBps,
        uint64 roundDuration,
        uint64 gracePeriod
    ) external returns (address escrow);

    function predictAddress(bytes32 circleId) external view returns (address);
    function escrowOf(bytes32 circleId) external view returns (address);
    function implementation() external view returns (address);
    function usdc() external view returns (address);
    function treasury() external view returns (address);
    function guardian() external view returns (address);
}
```

### 7.3 Reference skeleton (unaudited)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMoolaHubSusuEscrow} from "./IMoolaHubSusuEscrow.sol";
import {IMoolaHubCircleFactory} from "./IMoolaHubCircleFactory.sol";

contract MoolaHubCircleFactory is IMoolaHubCircleFactory, Ownable2Step {
    using Clones for address;

    address public immutable implementation; // immutable escrow logic
    address public immutable usdc;
    address public treasury;
    address public guardian;

    mapping(bytes32 => address) public escrowOf;

    error AlreadyExists();
    error BadConfig();

    constructor(address _implementation, address _usdc, address _treasury, address _guardian, address _owner)
        Ownable(_owner)
    {
        if (_implementation == address(0) || _usdc == address(0) || _treasury == address(0)) revert BadConfig();
        implementation = _implementation;
        usdc = _usdc;
        treasury = _treasury;
        guardian = _guardian;
    }

    function createCircle(
        bytes32 circleId,
        uint256 contributionAmount,
        address[] calldata members,
        uint16 feeBps,
        uint64 roundDuration,
        uint64 gracePeriod
    ) external onlyOwner returns (address escrow) {
        if (escrowOf[circleId] != address(0)) revert AlreadyExists();
        escrow = implementation.cloneDeterministic(circleId);
        escrowOf[circleId] = escrow;
        IMoolaHubSusuEscrow(escrow).initialize(
            usdc, contributionAmount, members, feeBps, treasury, roundDuration, gracePeriod, guardian, circleId
        );
        emit CircleCreated(circleId, escrow, members.length, contributionAmount);
    }

    function predictAddress(bytes32 circleId) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, circleId, address(this));
    }

    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert BadConfig(); treasury = t; }
    function setGuardian(address g) external onlyOwner { guardian = g; }
}
```

> **Note on `setTreasury`/`setGuardian`:** these affect **future** circles only — a deployed escrow snapshots treasury and guardian at `initialize`. Gate the factory owner behind a multisig + timelock so these cannot be flipped unilaterally.

### 7.4 Acceptance criteria
- [ ] `predictAddress(circleId)` equals the deployed clone address.
- [ ] Creating the same `circleId` twice reverts.
- [ ] Non-owner `createCircle` reverts.
- [ ] A created escrow is fully initialised and immediately `Active` with the correct roster/params.

---

## 8. Contract: `MoolaHubGoalVault` (personal savings, user-controlled)

Goals are pure ledger earmarks today. This optional-but-in-scope vault gives users a way to commit goal savings on-chain — useful for savings discipline and as the integration point for yield later (§13). It is **strictly non-custodial**: only the owner of a balance can move it.

### 8.1 Behaviour
- **Singleton** contract with per-`(owner, goalId)` accounting (cheaper than one contract per goal).
- **Deposit:** the user's smart account transfers USDC in, tagged with a `goalId` (the off-chain UUID hashed to `bytes32`).
- **Withdraw:** only the owning account may withdraw its own goal balance. The platform has **no** withdrawal path. There is no admin transfer function — by design.
- **Early withdrawal always allowed (D-r2):** a user may set an advisory `unlockAt` (e.g., the goal deadline), but it is UI metadata only and never blocks a withdrawal — it's the user's money.
- **2% fee on withdrawal (D-r2).** Deposits are free; `withdraw(goalId, grossAmount)` deducts 200 bps to the treasury and pays the user the net. Collecting it here (not at a separate cash-out) means a user can't dodge the fee by exporting their wallet. `MAX_FEE_BPS` cap = 500.

### 8.2 Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMoolaHubGoalVault {
    event GoalDeposited(address indexed owner, bytes32 indexed goalId, uint256 amount);
    event GoalWithdrawn(address indexed owner, bytes32 indexed goalId, uint256 amount);

    function deposit(bytes32 goalId, uint256 amount) external;          // pulls from msg.sender
    function withdraw(bytes32 goalId, uint256 amount) external;          // only to msg.sender
    function balanceOf(address owner, bytes32 goalId) external view returns (uint256);
    function setUnlock(bytes32 goalId, uint64 unlockAt) external;        // advisory in v1
}
```

### 8.3 Reference skeleton (unaudited)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMoolaHubGoalVault} from "./IMoolaHubGoalVault.sol";

contract MoolaHubGoalVault is IMoolaHubGoalVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    mapping(address => mapping(bytes32 => uint256)) private _bal;     // owner => goalId => amount
    mapping(address => mapping(bytes32 => uint64))  public unlockAt;  // advisory

    error ZeroAmount();
    error Insufficient();

    constructor(address _usdc) { usdc = IERC20(_usdc); }

    function deposit(bytes32 goalId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _bal[msg.sender][goalId] += amount;                 // effects
        usdc.safeTransferFrom(msg.sender, address(this), amount); // interaction
        emit GoalDeposited(msg.sender, goalId, amount);
    }

    function withdraw(bytes32 goalId, uint256 amount) external nonReentrant {
        uint256 b = _bal[msg.sender][goalId];
        if (amount == 0) revert ZeroAmount();
        if (amount > b) revert Insufficient();
        _bal[msg.sender][goalId] = b - amount;              // effects
        usdc.safeTransfer(msg.sender, amount);              // only ever to the owner
        emit GoalWithdrawn(msg.sender, goalId, amount);
    }

    function setUnlock(bytes32 goalId, uint64 _unlockAt) external { unlockAt[msg.sender][goalId] = _unlockAt; }
    function balanceOf(address owner, bytes32 goalId) external view returns (uint256) { return _bal[owner][goalId]; }
}
```

### 8.4 Invariants & acceptance
1. `usdc.balanceOf(vault) == Σ all _bal[owner][goalId]`.
2. The only USDC outflow path is `withdraw`, and it pays **`msg.sender`** only — never a third party, never an admin.
- [ ] Deposit then withdraw round-trips exactly; partial withdrawals work.
- [ ] No one but the owner can withdraw an owner's balance (negative test).
- [ ] There is no admin/owner function anywhere in the bytecode that moves user funds (review + test).

---

## 9. Contract: `MoolaHubTreasury` (fee collector)

Receives platform fees from escrows (and, later, yield-share). Holds them until governance withdraws to an operational multisig. It **never** touches user principal — fees are computed and split inside the escrow; the treasury is a passive sink with a guarded withdrawal.

### 9.1 Behaviour
- Accepts USDC (plain transfers from escrows; no special entrypoint required).
- `withdraw(to, amount)` callable only by the owner (**multisig**, ideally behind a timelock), to a destination on an allowlist or to the owner itself — keep it tight.
- `sweep(token)` to recover unrelated tokens accidentally sent, owner-only.
- Emits events for every inflow attribution (optional `recordFee(circleId, amount)` the escrow can call) and every withdrawal, for accounting parity with the ledger `fees` account.

### 9.2 Interface & skeleton (unaudited)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract MoolaHubTreasury is Ownable2Step {
    using SafeERC20 for IERC20;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address _owner) Ownable(_owner) {} // _owner = multisig

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }
}
```

### 9.3 Acceptance
- [ ] Only the owner (multisig) can withdraw.
- [ ] Fees routed by a settling escrow land here and match the ledger `fees` account after indexing.

> **Fee policy (D-r2).** **2% (200 bps)** on Susu disbursements and Goal withdrawals; nothing on deposits/contributions. `MAX_FEE_BPS` cap = 500 (5%). The fee per circle is fixed at deployment and visible on-chain; the Goal vault fee is owner-tunable within the cap. The treasury holds the collected USDC; only the owner (you / a multisig) can withdraw it.

---

## 10. Security requirements (mandatory)

These are non-negotiable. A PR that violates any of them does not merge.

### 10.1 Token handling
- Use **OpenZeppelin `SafeERC20`** for every transfer (`safeTransfer`, `safeTransferFrom`). Never bare `transfer`/`transferFrom`.
- USDC has **6 decimals**. All amounts are in USDC base units (6 dp). The backend uses integer **cents** (1/100 USDC); conversion is `cents * 10^4` units (see `centsToUnits`/`unitsToCents` in `chain.ts`). Keep one conversion helper and unit-test it.
- USDC is not fee-on-transfer and has no transfer hook, so push payouts are safe. Even so, **prefer effects-before-interactions** everywhere; do not assume token behaviour.

### 10.2 Reentrancy & ordering
- `nonReentrant` on every state-mutating function that moves tokens.
- **Checks-Effects-Interactions** strictly: update all storage before any external call. (The skeletons follow this; preserve it.)
- No external call inside a loop that also writes shared accounting without reentrancy protection.

### 10.3 Access control & keys
- Privileged roles (`factory owner`, `treasury owner`) are **multisigs**, ideally behind a **timelock**. Use `Ownable2Step` (two-step transfer) — never single-step `Ownable` for these.
- The **guardian** can only pause/open refunds; prove on-chain it can never receive funds.
- Escrows are **non-discretionary**: no owner, no admin, no setter that can move user funds or change the roster/recipient after init.
- Deployer and relayer keys live in a **KMS / hardware-backed signer**, never in plaintext or in the repo. Rotate on a schedule. The current `PLATFORM_PRIVATE_KEY` env pattern is acceptable for **testnet only**; for mainnet move to KMS.

### 10.4 Immutability & upgradeability
- Escrow instances are **immutable** (clones of an immutable implementation, no proxy admin). Upgrades happen by deploying a new factory + implementation; live circles never change code.
- If any contract must be upgradeable later, use **UUPS** behind a timelock + multisig, with `Initializable` storage gaps and namespaced storage (EIP-7201). Not needed for v1.

### 10.5 Arithmetic & edge cases
- Solidity ≥0.8 (checked math). Still reason about **rounding**: fees floor, recipient takes the remainder; assert conservation in tests.
- Guard `initialize`: `< 2` members, zero amount, zero addresses, duplicate members, `feeBps > MAX_FEE_BPS` all revert.
- Clones cannot use constructors — `_disableInitializers()` on the implementation and the `initializer` modifier on `initialize` (prevents re-init / implementation hijack).

### 10.6 Process
- **Foundry test suite** with ≥ 95% line coverage on money paths and **invariant/fuzz tests** for the conservation invariants in §6.4 and §8.4.
- **Static analysis** in CI: `slither` (and optionally `mythril`) clean or triaged.
- **External audit** of all four contracts before mainnet. Ship and soak on **Base Sepolia first**. (The reference doc shipped its v1 unaudited and flagged it as a risk — MoolaHub will not repeat that on mainnet.)
- A documented **incident runbook**: how to pause, how refunds work, who holds multisig keys.

---

## 11. Backend integration (what changes in `artifacts/api-server`)

The ledger and its reconciler stay; the on-chain rail underneath them is rebuilt.

### 11.1 Wallet provisioning — replace custodial EOAs
- **Remove** server-side key generation and storage: `generateAccount()` usage in `lib/wallet.ts`, `private_key_enc` writes, and `getSigningSecret()`. Keep `crypto.ts` only for the migration window (to read legacy keys during the sweep in §5.3), then retire.
- **Add** Privy smart-account provisioning at signup; persist the smart-account address in `wallets.address`. Add a `wallet_kind` column (`'smart_account'`) and keep `network = 'base-sepolia'`.

### 11.2 Money flows — call contracts, not EOA transfers
- **Susu contribute** (`lib/circles.ts::contribute`): instead of enqueuing an EOA→platform USDC transfer, submit a `contribute()` UserOp on the circle's escrow (user-signed, or relayer via session key). The escrow auto-settles the payout on the final contribution — **delete the platform-EOA payout logic** in `maybeProcessPayout`; the contract pays the recipient. The backend's job becomes: submit contributions, then **observe** `RoundSettled`/`PaidOut` events and mirror them to the ledger.
- **Circle start** (`lib/circles.ts::startCircle`): when the creator locks the roster, resolve each member's smart-account address, call `factory.createCircle(circleId, …)`, store the returned (or pre-predicted) address in `circles.contract_address`. Until this exists, a circle cannot go `active`.
- **Goal allocate** (`lib/goals.ts`): keep as a ledger-only earmark by default. If product enables on-chain goal locking, additionally submit `goalVault.deposit(goalId, amount)`; release calls `withdraw`.
- **Withdraw to external** (`lib/deposits.ts::withdrawToAddress`): becomes a USDC transfer UserOp from the user's smart account. No platform key involved.
- **Faucet** (`lib/deposits.ts::faucetDeposit`): testnet only — fund the user's smart account from a faucet/distributor for demos.

### 11.3 Indexer — keep the ledger in lockstep with chain
- Repurpose the `onchain_transfers` reconciler (`lib/settlement.ts`) into two halves:
  1. a **submitter** that sends UserOps via the bundler and tracks the resulting tx/userOp hash;
  2. an **indexer** that polls (or subscribes to) `CircleCreated`, `Contributed`, `RoundSettled`, `Refunded`, and `GoalDeposited/Withdrawn` and writes the corresponding ledger transactions (`contribution`, `payout`, `deposit`, `withdrawal`) idempotently keyed by `(txHash, logIndex)` — the existing dedupe key pattern in `syncDeposits`.
- On any divergence between a confirmed event and the ledger, **correct the ledger to match the chain** and emit an operator alert (§3 reconciliation rule).
- Keep the existing operator surface (`routes/operations.ts`, `getSettlementOverview`) and extend it with smart-account/bundler/paymaster health and per-circle escrow balances.

### 11.4 New / changed env vars
```
# Contracts (filled after deploy; see §12)
CIRCLE_FACTORY_ADDRESS=
GOAL_VAULT_ADDRESS=
TREASURY_ADDRESS=
USDC_CONTRACT_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e   # Base Sepolia (Circle)

# ERC-4337 / Privy
ENTRYPOINT_ADDRESS=0x0000000071727De22E5E9d8BAf0edAc6f37da032       # v0.7 (default)
BUNDLER_RPC_URL=          # CDP / Pimlico / Alchemy
PAYMASTER_RPC_URL=        # CDP paymaster (Base Sepolia)
PRIVY_APP_ID=
PRIVY_APP_SECRET=

# Signing (testnet); move to KMS for mainnet
DEPLOYER_PRIVATE_KEY=     # factory owner ops (multisig on mainnet)
RELAYER_PRIVATE_KEY=      # submits sponsored UserOps for session-key actions
BASE_RPC_URL=https://sepolia.base.org
BASE_EXPLORER_URL=https://sepolia.basescan.org
```

### 11.5 Data model touch-points (existing tables)
- `circles.contract_address` — now populated with the escrow clone address (already exists; nullable until deploy).
- `contributions.tx_hash` — set from the `Contributed` event.
- `transactions.tx_hash` / `onchain_status` — driven by the indexer.
- `onchain_transfers` — repurposed as the UserOp submission/queue table (or add a sibling `userops` table; keep the claim-with-`SKIP LOCKED` pattern).
- `wallets` — drop reliance on `private_key_enc` post-migration; add `wallet_kind`.

---

## 12. Testing & deployment on Base Sepolia

### 12.1 Toolchain & repo layout
Add a contracts workspace to the monorepo, e.g. `contracts/` (Foundry):

```
contracts/
  src/         IMoolaHubSusuEscrow.sol, MoolaHubSusuEscrow.sol,
               MoolaHubCircleFactory.sol, MoolaHubGoalVault.sol, MoolaHubTreasury.sol
  test/        unit + invariant (fuzz) tests
  script/      Deploy.s.sol
  foundry.toml
```

- **Solidity:** `^0.8.28`. **OpenZeppelin Contracts v5.x** (`5.6.x` current) via `forge install OpenZeppelin/openzeppelin-contracts`.
- Respect the monorepo's supply-chain rule (`pnpm-workspace.yaml minimumReleaseAge`); pin contract deps by commit/tag.

### 12.2 Network facts (Base Sepolia)
| Item | Value |
|------|-------|
| Chain ID | `84532` |
| RPC | `https://sepolia.base.org` (or your provider) |
| Explorer | `https://sepolia.basescan.org` |
| USDC (Circle) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| EntryPoint v0.8 | `0x4337084d9e255ff0702461cf8895ce9e3b5ff108` |
| Test ETH | Base Sepolia faucet (for the deployer) |
| Test USDC | Circle testnet faucet |

### 12.3 Deploy order
1. `MoolaHubTreasury(owner = multisig)`.
2. `MoolaHubSusuEscrow` implementation (logic only; `_disableInitializers` runs in its constructor).
3. `MoolaHubCircleFactory(implementation, usdc, treasury, guardian, owner)`.
4. `MoolaHubGoalVault(usdc)`.
5. **Verify all on Basescan.** Write the addresses into the backend env (§11.4) and a committed `contracts/deployments/base-sepolia.json` the backend reads.

### 12.4 End-to-end test on testnet
- Create a 3-member circle via the factory; predict vs. deployed address match.
- 3 smart accounts each `approve` + `contribute`; assert each round settles to the right recipient and the fee hits the treasury.
- Cancel a stalled circle and refund.
- Round-trip a goal deposit/withdraw.
- Confirm the indexer mirrored every event into the ledger and balances reconcile.

---

## 13. Phasing

- **Phase 1 — Accounts:** Privy smart accounts + paymaster (gasless), custodial-EOA migration/sweep. (§5)
- **Phase 2 — Susu on-chain:** escrow + factory; wire `startCircle`/`contribute`; indexer mirrors events; **delete platform-EOA escrow logic**. (§6, §7, §11)
- **Phase 3 — Goal vault + treasury:** on-chain goal locking (if product enables) and fee routing. (§8, §9)
- **Phase 4 — Hardening:** invariant/fuzz tests, slither, external audit, incident runbook → mainnet readiness. (§10)
- **Designed-for, not built:** yield (route idle escrow/vault USDC into an audited lending market such as a Base money-market) — keep the vault interface yield-ready but ship v1 without it. (D4)

---

## 14. Open questions / decisions needed

| # | Question | Status |
|---|----------|--------|
| Q1 | Fee. | **Resolved:** 2% (200 bps) on Susu disbursement + Goal withdrawal; cap 500. |
| Q2 | ROSCA default risk (member takes early pot then stops). | **Resolved (v1):** enforced off-chain; chain tracks bad actors via `MoolaHubReputation`. Revisit collateral/buffer before mainnet. |
| Q3 | Goal vault lock. | **Resolved:** early withdrawal always allowed; `unlockAt` advisory only. |
| Q4 | Smart-account implementation. | **Resolved:** Safe (via Privy). Coinbase Smart Wallet needs no Coinbase account but doesn't fit embedded UX. |
| Q5 | EntryPoint version. | **Resolved:** v0.7. |
| Q6 | Session keys vs user-signed. | **Resolved:** user-signed only for v1; session keys deferred. |
| Q7 | Multisig + timelock for factory/treasury ownership. | **Open:** for testnet, owner = your EOA; before mainnet move to a multisig + timelock. |
| Q8 | KYC/KYB. | **Resolved:** not required. |

---

## 15. References

- **Reference design pattern:** SynFutures × Anchored Pre-Market Vault (non-discretionary escrow; bounded fund flows; immutable params; on-chain settlement posting) — pattern only (D5).
- Circle — USDC contract addresses (Base Sepolia testnet).
- Privy — Smart wallets (ERC-4337) overview & supported account implementations; paymaster registration; session keys (ERC-7715 / ERC-7579).
- eth-infinitism — ERC-4337 EntryPoint v0.7 / v0.8 releases.
- Coinbase Developer Platform — Paymaster & Bundler (Base Sepolia; ERC-20/USDC gas).
- OpenZeppelin Contracts v5.x (`SafeERC20`, `ReentrancyGuard`, `Clones`, `Ownable2Step`, `Initializable`).
- MoolaHub repo (`Moolahubio/app`): `lib/db/src/schema/*`, `artifacts/api-server/src/lib/{chain,settlement,deposits,wallet,circles,goals,ledger,crypto,privy}.ts`.

---

*End of specification. Changes to this document require Lead Dev sign-off and a version bump.*
