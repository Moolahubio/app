// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MoolaHubSusuAccumulation} from "../src/MoolaHubSusuAccumulation.sol";
import {MoolaHubAccumulationFactory} from "../src/MoolaHubAccumulationFactory.sol";
import {IMoolaHubReputation} from "../src/interfaces/IMoolaHubReputation.sol";

/// @notice Deploy the accumulation-mode implementation + factory to Base Sepolia.
///         Each accumulation circle is then created as a cheap clone via
///         `factory.createAccumulationCircle(...)` (by the owner / backend), so
///         every group gets its own contract with its own parameters.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  - deployer (also the reputation owner, to authorize the factory)
///   TREASURY_ADDRESS      - the MoolaHubTreasury you deployed
///   REPUTATION_ADDRESS    - the MoolaHubReputation you deployed
/// Optional env (defaults):
///   USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e (Circle USDC, Base Sepolia)
///   OWNER_ADDRESS=deployer   GUARDIAN_ADDRESS=owner   FEE_BPS=200
///
/// Run:
///   forge script script/DeployAccumulation.s.sol:DeployAccumulation --rpc-url base_sepolia --broadcast --verify
contract DeployAccumulation is Script {
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envOr("USDC_ADDRESS", USDC_BASE_SEPOLIA);
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address reputationAddr = vm.envAddress("REPUTATION_ADDRESS");
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address guardian = vm.envOr("GUARDIAN_ADDRESS", owner);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(200)));

        vm.startBroadcast(pk);

        MoolaHubSusuAccumulation impl = new MoolaHubSusuAccumulation();
        MoolaHubAccumulationFactory factory =
            new MoolaHubAccumulationFactory(address(impl), usdc, treasury, guardian, reputationAddr, feeBps, owner);

        // Authorize the new factory to register circle reporters (requires the
        // deployer to be the reputation owner — true if you deployed the stack).
        if (owner == deployer) {
            IMoolaHubReputation(reputationAddr).setAuthorizer(address(factory), true);
        } else {
            console2.log("ACTION REQUIRED: owner must call reputation.setAuthorizer(accumulationFactory, true)");
        }

        vm.stopBroadcast();

        console2.log("AccumulationImpl:    ", address(impl));
        console2.log("AccumulationFactory: ", address(factory));
        console2.log("Owner:               ", owner);
    }
}
