// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MoolaHubReputation} from "../src/MoolaHubReputation.sol";
import {MoolaHubSusuEscrow} from "../src/MoolaHubSusuEscrow.sol";
import {MoolaHubCircleFactory} from "../src/MoolaHubCircleFactory.sol";
import {MoolaHubGoalVault} from "../src/MoolaHubGoalVault.sol";
import {MoolaHubTreasury} from "../src/MoolaHubTreasury.sol";

/// @notice Deploys the MoolaHub on-chain stack to Base Sepolia (or any EVM).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  - deployer key (testnet)
/// Optional env (with Base Sepolia defaults):
///   USDC_ADDRESS          - default 0x036CbD53842c5426634e7929541eC2318f3dCF7e (Circle, Base Sepolia)
///   OWNER_ADDRESS         - multisig owner; defaults to the deployer
///   GUARDIAN_ADDRESS      - circle guardian; defaults to the owner
///   FEE_BPS               - default 200 (2%)
///
/// Run:
///   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
contract Deploy is Script {
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envOr("USDC_ADDRESS", USDC_BASE_SEPOLIA);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address guardian = vm.envOr("GUARDIAN_ADDRESS", owner);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(200)));

        vm.startBroadcast(pk);

        // 1. Treasury (fee sink) — owner is the multisig.
        MoolaHubTreasury treasury = new MoolaHubTreasury(owner);

        // 2. Reputation registry.
        MoolaHubReputation reputation = new MoolaHubReputation(owner);

        // 3. Escrow implementation (logic only; clones use it).
        MoolaHubSusuEscrow escrowImpl = new MoolaHubSusuEscrow();

        // 4. Circle factory.
        MoolaHubCircleFactory factory = new MoolaHubCircleFactory(
            address(escrowImpl), usdc, address(treasury), guardian, address(reputation), feeBps, owner
        );

        // 5. Goal vault.
        MoolaHubGoalVault goalVault = new MoolaHubGoalVault(usdc, address(treasury), feeBps, owner);

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
        console2.log("Reputation:      ", address(reputation));
        console2.log("EscrowImpl:      ", address(escrowImpl));
        console2.log("CircleFactory:   ", address(factory));
        console2.log("GoalVault:       ", address(goalVault));
        console2.log("Owner:           ", owner);
        console2.log("Guardian:        ", guardian);
        console2.log("FeeBps:          ", feeBps);

        string memory json = "deployment";
        vm.serializeAddress(json, "usdc", usdc);
        vm.serializeAddress(json, "treasury", address(treasury));
        vm.serializeAddress(json, "reputation", address(reputation));
        vm.serializeAddress(json, "escrowImplementation", address(escrowImpl));
        vm.serializeAddress(json, "circleFactory", address(factory));
        vm.serializeAddress(json, "goalVault", address(goalVault));
        string memory out = vm.serializeUint(json, "feeBps", feeBps);
        vm.writeJson(out, "./deployments/latest.json");
    }
}
