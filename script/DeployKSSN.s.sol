// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {ProposerRegistry} from "../src/ProposerRegistry.sol";
import {BuilderRegistry} from "../src/BuilderRegistry.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";

/**
 * @title DeployKSSN
 * @notice Deployment script for Kleros Shared Sequencer Network (KSSN).
 *
 * This deploys the complete KSSN architecture:
 * - ProposerRegistry (DPoS proposer management)
 * - BuilderRegistry (Policy-based builder management)
 * - SharedSequencerHub (Central hub for atomic multichain rotation)
 * - OpStackAdapterV1 (OP Stack rotation adapter)
 * - MockSystemConfig (for testing - represents connected chains)
 *
 * Architecture:
 *   Hub-and-Spoke model with:
 *   - Hub: SharedSequencerHub (L1) - central authority
 *   - Spokes: SystemConfig contracts for each L2 chain
 *   - Registries: ProposerRegistry + BuilderRegistry for PBS
 *
 * Usage:
 *   anvil &
 *   forge script script/DeployKSSN.s.sol:DeployKSSN --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract DeployKSSN is Script {
    // Test accounts from Anvil's default mnemonic
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant GOVERNANCE = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    // Proposers (will stake to become active)
    address constant PROPOSER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant PROPOSER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant PROPOSER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    // Builders
    address constant BUILDER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address constant BUILDER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // Configuration
    uint256 constant EPOCH_DURATION = 60; // 60 seconds for demo
    uint256 constant GRACE_PERIOD = 30; // 30 seconds grace period
    uint256 constant MIN_PROPOSER_STAKE = 1 ether; // Low for testing
    uint256 constant MIN_BUILDER_BOND = 1 ether; // Low for testing
    uint256 constant MAX_ACTIVE_PROPOSERS = 100;

    // Chain IDs for test chains
    uint256 constant CHAIN_ID_1 = 10001;
    uint256 constant CHAIN_ID_2 = 10002;
    uint256 constant CHAIN_ID_3 = 10003;

    // Deployed contracts
    ProposerRegistry public proposerRegistry;
    BuilderRegistry public builderRegistry;
    SharedSequencerHub public hub;
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig1;
    MockSystemConfig public systemConfig2;
    MockSystemConfig public systemConfig3;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        vm.startBroadcast(deployerPrivateKey);

        console2.log("=== Deploying KSSN Architecture ===\n");

        // 1. Deploy ProposerRegistry
        proposerRegistry = new ProposerRegistry(
            GOVERNANCE,
            address(0), // Hub will be set after deployment
            MIN_PROPOSER_STAKE,
            MAX_ACTIVE_PROPOSERS
        );
        console2.log("ProposerRegistry deployed at:", address(proposerRegistry));

        // 2. Deploy BuilderRegistry
        builderRegistry = new BuilderRegistry(
            GOVERNANCE,
            address(0), // Hub will be set after deployment
            MIN_BUILDER_BOND
        );
        console2.log("BuilderRegistry deployed at:", address(builderRegistry));

        // 3. Deploy SharedSequencerHub
        hub = new SharedSequencerHub(
            GOVERNANCE,
            GUARDIAN,
            address(proposerRegistry),
            address(builderRegistry),
            EPOCH_DURATION,
            GRACE_PERIOD
        );
        console2.log("SharedSequencerHub deployed at:", address(hub));

        // 4. Set hub address in registries
        proposerRegistry.setHub(address(hub));
        builderRegistry.setHub(address(hub));
        console2.log("Hub address set in registries");

        // 5. Deploy adapter
        adapter = new OpStackAdapterV1();
        console2.log("OpStackAdapterV1 deployed at:", address(adapter));

        // 6. Deploy mock SystemConfigs for test chains
        systemConfig1 = new MockSystemConfig();
        systemConfig2 = new MockSystemConfig();
        systemConfig3 = new MockSystemConfig();
        console2.log("\nMock SystemConfigs deployed:");
        console2.log("  Chain", CHAIN_ID_1, ":", address(systemConfig1));
        console2.log("  Chain", CHAIN_ID_2, ":", address(systemConfig2));
        console2.log("  Chain", CHAIN_ID_3, ":", address(systemConfig3));

        // 7. Transfer SystemConfig ownership to hub
        systemConfig1.transferOwnership(address(hub));
        systemConfig2.transferOwnership(address(hub));
        systemConfig3.transferOwnership(address(hub));
        console2.log("SystemConfig ownership transferred to hub");

        // 8. Connect chains to hub
        bytes32 policyNeutral = builderRegistry.POLICY_NEUTRAL();
        bytes32 policyOfac = builderRegistry.POLICY_OFAC();

        hub.connectChain(CHAIN_ID_1, address(systemConfig1), policyNeutral, address(adapter));
        hub.connectChain(CHAIN_ID_2, address(systemConfig2), policyNeutral, address(adapter));
        hub.connectChain(CHAIN_ID_3, address(systemConfig3), policyOfac, address(adapter)); // OFAC-compliant chain

        console2.log("\nChains connected to hub:");
        console2.log("  Chain", CHAIN_ID_1, "- Policy: NEUTRAL");
        console2.log("  Chain", CHAIN_ID_2, "- Policy: NEUTRAL");
        console2.log("  Chain", CHAIN_ID_3, "- Policy: OFAC");

        vm.stopBroadcast();

        // Register proposers (need to be called from proposer accounts)
        console2.log("\n=== Registering Proposers ===");

        // Proposer 1
        uint256 proposer1Key = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        vm.startBroadcast(proposer1Key);
        proposerRegistry.register{value: MIN_PROPOSER_STAKE}(PROPOSER_1);
        vm.stopBroadcast();
        console2.log("Proposer 1 registered:", PROPOSER_1);

        // Proposer 2
        uint256 proposer2Key = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
        vm.startBroadcast(proposer2Key);
        proposerRegistry.register{value: MIN_PROPOSER_STAKE}(PROPOSER_2);
        vm.stopBroadcast();
        console2.log("Proposer 2 registered:", PROPOSER_2);

        // Proposer 3
        uint256 proposer3Key = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
        vm.startBroadcast(proposer3Key);
        proposerRegistry.register{value: MIN_PROPOSER_STAKE}(PROPOSER_3);
        vm.stopBroadcast();
        console2.log("Proposer 3 registered:", PROPOSER_3);

        // Register builders
        console2.log("\n=== Registering Builders ===");

        // Builder 1
        uint256 builder1Key = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
        vm.startBroadcast(builder1Key);
        builderRegistry.register{value: MIN_BUILDER_BOND}();
        vm.stopBroadcast();
        console2.log("Builder 1 registered:", BUILDER_1);

        // Builder 2
        uint256 builder2Key = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
        vm.startBroadcast(builder2Key);
        builderRegistry.register{value: MIN_BUILDER_BOND}();
        vm.stopBroadcast();
        console2.log("Builder 2 registered:", BUILDER_2);

        // Grant OFAC policy to Builder 1 (so they can build for chain 3)
        vm.startBroadcast(deployerPrivateKey);
        builderRegistry.grantPolicyTag(BUILDER_1, policyOfac, 0);
        console2.log("OFAC policy granted to Builder 1");

        // Perform first rotation
        // Need to wait until epoch ends
        console2.log("\n=== Initial State ===");
        console2.log("Current proposer:", hub.currentProposer());
        console2.log("Current epoch:", hub.currentEpoch());
        console2.log("Chain count:", hub.getChainCount());
        console2.log("Active proposers:", proposerRegistry.getActiveProposerCount());
        console2.log("Active builders:", builderRegistry.getActiveBuilderCount());

        vm.stopBroadcast();

        // Output deployment summary
        console2.log("\n=== KSSN Deployment Summary ===");
        console2.log("SharedSequencerHub:", address(hub));
        console2.log("ProposerRegistry:", address(proposerRegistry));
        console2.log("BuilderRegistry:", address(builderRegistry));
        console2.log("OpStackAdapterV1:", address(adapter));
        console2.log("\nConnected Chains:");
        console2.log("  Chain", CHAIN_ID_1, ":", address(systemConfig1));
        console2.log("  Chain", CHAIN_ID_2, ":", address(systemConfig2));
        console2.log("  Chain", CHAIN_ID_3, ":", address(systemConfig3));

        console2.log("\n=== Usage Commands ===");
        console2.log("Wait for epoch to end, then rotate:");
        console2.log("  cast send", address(hub), "'rotateNetwork()' --rpc-url http://127.0.0.1:8545");
        console2.log("\nCheck current proposer:");
        console2.log("  cast call", address(hub), "'currentProposer()'");
        console2.log("\nCheck proposer selection:");
        console2.log("  cast call", address(proposerRegistry), "'selectNextProposer(uint256)' 1");
        console2.log("\nCheck builder eligibility:");
        console2.log("  cast call", address(builderRegistry), "'isBuilderEligible(address,bytes32)'", BUILDER_1);
    }
}
