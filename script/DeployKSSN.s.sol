// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {ProposerRegistry} from "../src/ProposerRegistry.sol";
import {OpStackAdapterV1} from "../src/poc/opstack/OpStackAdapterV1.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {TestConstants} from "./TestConstants.sol";

/**
 * @title DeployKSSN
 * @notice Deployment script for ISOCHRON (default arbitrator: Kleros Court).
 *
 * This deploys the complete ISOCHRON architecture:
 * - ProposerRegistry (DPoS proposer management)
 * - SharedSequencerHub (Central hub for atomic multichain rotation)
 * - OpStackAdapterV1 (OP Stack rotation adapter)
 * - MockSystemConfig (for testing - represents connected chains)
 *
 * Architecture:
 *   Hub-and-Spoke model with:
 *   - Hub: SharedSequencerHub (L1) - central authority
 *   - Spokes: SystemConfig contracts for each L2 chain
 *   - Registry: ProposerRegistry for shared sequencer rotation
 *
 * Usage:
 *   anvil &
 *   forge script script/DeployKSSN.s.sol:DeployKSSN --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract DeployKSSN is Script {
    // Configuration
    uint256 constant EPOCH_DURATION = 1 minutes;
    uint256 constant GRACE_PERIOD = 30 seconds;
    uint256 constant MIN_PROPOSER_STAKE = 1 ether;
    uint256 constant MAX_ACTIVE_PROPOSERS = 100;

    // Deployed contracts
    ProposerRegistry public proposerRegistry;
    SharedSequencerHub public hub;
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig1;
    MockSystemConfig public systemConfig2;
    MockSystemConfig public systemConfig3;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            TestConstants.DEPLOYER_KEY
        );

        vm.startBroadcast(deployerPrivateKey);

        console2.log("=== Deploying ISOCHRON Architecture ===\n");

        // 1. Deploy ProposerRegistry
        proposerRegistry = new ProposerRegistry(
            TestConstants.DEPLOYER, // governance
            address(0), // Hub will be set after deployment
            MIN_PROPOSER_STAKE,
            MAX_ACTIVE_PROPOSERS
        );
        console2.log("ProposerRegistry deployed at:", address(proposerRegistry));

        // 2. Deploy SharedSequencerHub
        hub = new SharedSequencerHub(
            TestConstants.DEPLOYER, // governance
            TestConstants.GUARDIAN,
            address(proposerRegistry),
            EPOCH_DURATION,
            GRACE_PERIOD
        );
        console2.log("SharedSequencerHub deployed at:", address(hub));

        // 3. Set hub address in registries
        proposerRegistry.setHub(address(hub));
        console2.log("Hub address set in registries");

        // 4. Deploy adapter
        adapter = new OpStackAdapterV1();
        console2.log("OpStackAdapterV1 deployed at:", address(adapter));

        // 5. Deploy mock SystemConfigs for test chains
        systemConfig1 = new MockSystemConfig();
        systemConfig2 = new MockSystemConfig();
        systemConfig3 = new MockSystemConfig();
        console2.log("\nMock SystemConfigs deployed:");
        console2.log("  Chain", TestConstants.CHAIN_ID_1, ":", address(systemConfig1));
        console2.log("  Chain", TestConstants.CHAIN_ID_2, ":", address(systemConfig2));
        console2.log("  Chain", TestConstants.CHAIN_ID_3, ":", address(systemConfig3));

        // 6. Transfer SystemConfig ownership to hub
        systemConfig1.transferOwnership(address(hub));
        systemConfig2.transferOwnership(address(hub));
        systemConfig3.transferOwnership(address(hub));
        console2.log("SystemConfig ownership transferred to hub");

        // 7. Connect chains to hub
        hub.connectChain(TestConstants.CHAIN_ID_1, address(systemConfig1), address(adapter));
        hub.connectChain(TestConstants.CHAIN_ID_2, address(systemConfig2), address(adapter));
        hub.connectChain(TestConstants.CHAIN_ID_3, address(systemConfig3), address(adapter));

        console2.log("\nChains connected to hub:");
        console2.log("  Chain", TestConstants.CHAIN_ID_1);
        console2.log("  Chain", TestConstants.CHAIN_ID_2);
        console2.log("  Chain", TestConstants.CHAIN_ID_3);

        vm.stopBroadcast();

        // Register proposers (need to be called from proposer accounts)
        console2.log("\n=== Registering Proposers ===");

        // Proposer 1
        vm.startBroadcast(TestConstants.PROPOSER_1_KEY);
        proposerRegistry.register{value: MIN_PROPOSER_STAKE}(TestConstants.PROPOSER_1);
        proposerRegistry.setAdapterData(address(adapter), abi.encode(TestConstants.PROPOSER_1, TestConstants.PROPOSER_1));
        vm.stopBroadcast();
        console2.log("Proposer 1 registered:", TestConstants.PROPOSER_1);

        // Proposer 2
        vm.startBroadcast(TestConstants.PROPOSER_2_KEY);
        proposerRegistry.register{value: MIN_PROPOSER_STAKE}(TestConstants.PROPOSER_2);
        proposerRegistry.setAdapterData(address(adapter), abi.encode(TestConstants.PROPOSER_2, TestConstants.PROPOSER_2));
        vm.stopBroadcast();
        console2.log("Proposer 2 registered:", TestConstants.PROPOSER_2);

        // Proposer 3
        vm.startBroadcast(TestConstants.PROPOSER_3_KEY);
        proposerRegistry.register{value: MIN_PROPOSER_STAKE}(TestConstants.PROPOSER_3);
        proposerRegistry.setAdapterData(address(adapter), abi.encode(TestConstants.PROPOSER_3, TestConstants.PROPOSER_3));
        vm.stopBroadcast();
        console2.log("Proposer 3 registered:", TestConstants.PROPOSER_3);

        // Perform first rotation
        // Need to wait until epoch ends
        console2.log("\n=== Initial State ===");
        console2.log("Current proposer:", hub.currentProposer());
        console2.log("Current epoch:", hub.currentEpoch());
        console2.log("Chain count:", hub.getChainCount());
        console2.log("Active proposers:", proposerRegistry.getActiveProposerCount());
        vm.stopBroadcast();

        // Output deployment summary
        console2.log("\n=== ISOCHRON Deployment Summary ===");
        console2.log("SharedSequencerHub:", address(hub));
        console2.log("ProposerRegistry:", address(proposerRegistry));
        console2.log("OpStackAdapterV1:", address(adapter));
        console2.log("\nConnected Chains:");
        console2.log("  Chain", TestConstants.CHAIN_ID_1, ":", address(systemConfig1));
        console2.log("  Chain", TestConstants.CHAIN_ID_2, ":", address(systemConfig2));
        console2.log("  Chain", TestConstants.CHAIN_ID_3, ":", address(systemConfig3));

        console2.log("\n=== Usage Commands ===");
        console2.log("Wait for epoch to end, then rotate:");
        console2.log("  cast send", address(hub), "'rotateNetwork()' --rpc-url http://127.0.0.1:8545");
        console2.log("\nCheck current proposer:");
        console2.log("  cast call", address(hub), "'currentProposer()'");
        console2.log("\nCheck proposer selection:");
        console2.log("  cast call", address(proposerRegistry), "'selectNextProposer(uint256)' 1");
    }
}
