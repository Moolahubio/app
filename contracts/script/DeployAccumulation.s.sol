// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MoolaHubSusuAccumulation} from "../src/MoolaHubSusuAccumulation.sol";
import {MoolaHubAccumulationFactory} from "../src/MoolaHubAccumulationFactory.sol";
import {IMoolaHubReputation} from "../src/interfaces/IMoolaHubReputation.sol";

/// @notice Deploy the accumulation-mode implementation + factory to Monad Testnet
///         (chainId 10143) or any EVM. Each accumulation circle is then created
///         as a cheap clone via `factory.createAccumulationCircle(...)` (by the
///         owner / backend), so every group gets its own contract with its own
///         parameters.
///
///         Fails closed: token and role addresses are REQUIRED, never defaulted
///         to the deployer (replit.md role-address policy + non-custodial invariant).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  - deployer (also the reputation owner, to authorize the factory)
///   USDC_ADDRESS          - USDC token (Circle native Monad-testnet USDC, 6 dp)
///   OWNER_ADDRESS         - multisig owner (NOT the deployer)
///   GUARDIAN_ADDRESS      - circle guardian
///   TREASURY_ADDRESS      - the MoolaHubTreasury you deployed
///   REPUTATION_ADDRESS    - the MoolaHubReputation you deployed
/// Optional env:
///   FEE_RECIPIENT_ADDRESS - fee destination; defaults to TREASURY_ADDRESS
///   FEE_BPS               - default 200 (2%)
///
/// Run:
///   forge script script/DeployAccumulation.s.sol:DeployAccumulation --rpc-url monad_testnet --broadcast --verify
contract DeployAccumulation is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address reputationAddr = vm.envAddress("REPUTATION_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        // Default platform fees straight to the recipient EOA when set; otherwise
        // fall back to the Treasury contract.
        address feeSink = vm.envOr("FEE_RECIPIENT_ADDRESS", treasury);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(200)));

        vm.startBroadcast(pk);

        MoolaHubSusuAccumulation impl = new MoolaHubSusuAccumulation();
        MoolaHubAccumulationFactory factory =
            new MoolaHubAccumulationFactory(address(impl), usdc, feeSink, guardian, reputationAddr, feeBps, owner);

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
        console2.log("FeeSink:             ", feeSink);
        console2.log("Owner:               ", owner);
    }
}
