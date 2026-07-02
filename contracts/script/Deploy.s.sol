// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MoolaHubReputation} from "../src/MoolaHubReputation.sol";
import {MoolaHubSusuEscrow} from "../src/MoolaHubSusuEscrow.sol";
import {MoolaHubCircleFactory} from "../src/MoolaHubCircleFactory.sol";
import {MoolaHubGoalVault} from "../src/MoolaHubGoalVault.sol";
import {MoolaHubTreasury} from "../src/MoolaHubTreasury.sol";

/// @notice Deploys the MoolaHub on-chain stack to Monad Testnet (chainId 10143)
///         or any EVM. Fails closed: the token and role addresses are REQUIRED,
///         never defaulted to the deployer or a wrong-chain token (replit.md
///         role-address policy + the non-custodial invariant — OWNER/GUARDIAN
///         must never silently fall back to the deployer).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  - deployer key (testnet)
///   USDC_ADDRESS          - USDC token (Circle native Monad-testnet USDC, 6 dp)
///   OWNER_ADDRESS         - multisig owner (NOT the deployer)
///   GUARDIAN_ADDRESS      - circle guardian
/// Optional env:
///   FEE_RECIPIENT_ADDRESS - destination for platform fees; defaults to the deployed Treasury
///   FEE_BPS               - default 200 (2%)
///
/// Run:
///   forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast --verify
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(200)));

        vm.startBroadcast(pk);

        // 1. Treasury (optional fee sink / fallback) — owner is the multisig.
        MoolaHubTreasury treasury = new MoolaHubTreasury(owner);

        // Fee destination: when FEE_RECIPIENT_ADDRESS is set, fees go straight to
        // that wallet on every disbursement (auto-transfer, no pooling, no
        // withdrawal function). Falls back to the Treasury contract when unset.
        address feeSink = vm.envOr("FEE_RECIPIENT_ADDRESS", address(treasury));

        // 2. Reputation registry.
        MoolaHubReputation reputation = new MoolaHubReputation(owner);

        // 3. Escrow implementation (logic only; clones use it).
        MoolaHubSusuEscrow escrowImpl = new MoolaHubSusuEscrow();

        // 4. Circle factory.
        MoolaHubCircleFactory factory = new MoolaHubCircleFactory(
            address(escrowImpl), usdc, feeSink, guardian, address(reputation), feeBps, owner
        );

        // 5. Goal vault.
        MoolaHubGoalVault goalVault = new MoolaHubGoalVault(usdc, feeSink, feeBps, owner);

        // 6. Authorize the factory on the reputation registry so it can register
        //    escrow reporters. Only works if the deployer is the reputation owner;
        //    otherwise the multisig owner must call setAuthorizer(factory, true).
        if (owner == deployer) {
            reputation.setAuthorizer(address(factory), true);
        } else {
            console2.log("ACTION REQUIRED: owner must call reputation.setAuthorizer(factory, true)");
        }

        vm.stopBroadcast();

        console2.log("USDC:            ", usdc);
        console2.log("Treasury:        ", address(treasury));
        console2.log("FeeSink:         ", feeSink);
        console2.log("Reputation:      ", address(reputation));
        console2.log("EscrowImpl:      ", address(escrowImpl));
        console2.log("CircleFactory:   ", address(factory));
        console2.log("GoalVault:       ", address(goalVault));
        console2.log("Owner:           ", owner);
        console2.log("Guardian:        ", guardian);
        console2.log("FeeBps:          ", feeBps);

        // Record the deployment via a helper struct so run()'s local stack stays
        // shallow (the inline serialize block hits solc "stack too deep").
        Deployment memory d;
        d.chainId = block.chainid;
        d.deployer = deployer;
        d.owner = owner;
        d.guardian = guardian;
        d.usdc = usdc;
        d.treasury = address(treasury);
        d.feeSink = feeSink;
        d.reputation = address(reputation);
        d.escrowImplementation = address(escrowImpl);
        d.circleFactory = address(factory);
        d.goalVault = address(goalVault);
        d.feeBps = feeBps;
        _writeDeployment(d);
    }

    struct Deployment {
        uint256 chainId;
        address deployer;
        address owner;
        address guardian;
        address usdc;
        address treasury;
        address feeSink;
        address reputation;
        address escrowImplementation;
        address circleFactory;
        address goalVault;
        uint16 feeBps;
    }

    /// @dev Stamp the deployment record to ./deployments/latest.json AND a
    ///      per-network file (e.g. monad-testnet.json) so a record is never
    ///      ambiguous about which chain its addresses belong to. Reverts on an
    ///      unrecognized chain (fail closed) rather than writing blank metadata.
    function _writeDeployment(Deployment memory d) internal {
        (string memory network, string memory explorer) = _networkMeta(d.chainId);
        require(bytes(network).length != 0, "Deploy: unknown chainId, add it to _networkMeta");

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", d.chainId);
        vm.serializeString(json, "network", network);
        vm.serializeString(json, "explorer", explorer);
        vm.serializeAddress(json, "deployer", d.deployer);
        vm.serializeAddress(json, "owner", d.owner);
        vm.serializeAddress(json, "guardian", d.guardian);
        vm.serializeAddress(json, "usdc", d.usdc);
        vm.serializeAddress(json, "treasury", d.treasury);
        vm.serializeAddress(json, "feeSink", d.feeSink);
        vm.serializeAddress(json, "reputation", d.reputation);
        vm.serializeAddress(json, "escrowImplementation", d.escrowImplementation);
        vm.serializeAddress(json, "circleFactory", d.circleFactory);
        vm.serializeAddress(json, "goalVault", d.goalVault);
        string memory out = vm.serializeUint(json, "feeBps", d.feeBps);

        vm.writeJson(out, "./deployments/latest.json");
        vm.writeJson(out, string.concat("./deployments/", network, ".json"));
    }

    /// @dev chainId -> (network slug, explorer base url) for the deployment
    ///      record. Returns ("", "") for unrecognized chains (the caller reverts).
    ///      Register a chain here before deploying to it. Value: Monad Testnet
    ///      (10143). This project is Monad-only; other chains revert by design.
    function _networkMeta(uint256 chainId)
        internal
        pure
        returns (string memory network, string memory explorer)
    {
        if (chainId == 10143) return ("monad-testnet", "https://testnet.monadvision.com");
        return ("", "");
    }
}
