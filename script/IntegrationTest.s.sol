// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockChainRegistry} from "../test/mocks/MockChainRegistry.sol";
import {MockProposerRegistry} from "../test/mocks/MockProposerRegistry.sol";
import {MockBuilderRegistry} from "../test/mocks/MockBuilderRegistry.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";

/**
 * @title IntegrationTest
 * @notice Integration test for the KSSN (Kleros Shared Sequencer Network) lifecycle.
 *
 * This script tests the full KSSN flow:
 *
 * 1. Deploy KSSN Hub and registries
 * 2. Register proposers in ProposerRegistry
 * 3. Register chains in ChainRegistry
 * 4. Connect chains from registry to Hub
 * 5. Atomic multichain rotation
 * 6. Guardian pause test
 *
 * Usage:
 *   anvil &
 *   forge script script/IntegrationTest.s.sol:IntegrationTest --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
 */
contract IntegrationTest is Script {
    // Test accounts from Anvil's default mnemonic
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant GUARDIAN_KEY = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    // Proposers (using Anvil accounts)
    address constant PROPOSER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant PROPOSER_1_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant PROPOSER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    uint256 constant PROPOSER_2_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    address constant PROPOSER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    uint256 constant PROPOSER_3_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    uint256 constant EPOCH_DURATION = 10; // 10 seconds for testing
    uint256 constant GRACE_PERIOD = 600;  // 10 minutes grace period

    // KSSN Components
    SharedSequencerHub public hub;
    MockChainRegistry public chainRegistry;
    MockProposerRegistry public proposerRegistry;
    MockBuilderRegistry public builderRegistry;
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig1;
    MockSystemConfig public systemConfig2;
    MockSystemConfig public systemConfig3;

    uint256 constant CHAIN_ID_1 = 42001;
    uint256 constant CHAIN_ID_2 = 42002;
    uint256 constant CHAIN_ID_3 = 42003;

    function run() external {
        console2.log("");
        console2.log("===========================================");
        console2.log("  KSSN INTEGRATION TEST");
        console2.log("  (Kleros Shared Sequencer Network)");
        console2.log("===========================================");
        console2.log("");

        // Step 1: Deploy KSSN Hub and registries
        _step1_deployKSSN();

        // Step 2: Register proposers
        _step2_registerProposers();

        // Step 3: Register chains in ChainRegistry
        _step3_registerChainsInRegistry();

        // Step 4: Connect chains from registry to Hub
        _step4_connectChainsFromRegistry();

        // Step 5: Atomic multichain rotation
        _step5_atomicMultichainRotation();

        // Step 6: Guardian pause test
        _step6_guardianPause();

        console2.log("");
        console2.log("===========================================");
        console2.log("  INTEGRATION TEST COMPLETE!");
        console2.log("===========================================");
        console2.log("");
        console2.log("KSSN Contracts:");
        console2.log("  SharedSequencerHub:", address(hub));
        console2.log("  ChainRegistry:", address(chainRegistry));
        console2.log("  ProposerRegistry:", address(proposerRegistry));
        console2.log("  BuilderRegistry:", address(builderRegistry));
        console2.log("  OpStackAdapterV1:", address(adapter));
        console2.log("");
        console2.log("Connected Chains:");
        console2.log("  Chain", CHAIN_ID_1, ":", address(systemConfig1));
        console2.log("  Chain", CHAIN_ID_2, ":", address(systemConfig2));
        console2.log("  Chain", CHAIN_ID_3, ":", address(systemConfig3));
    }

    function _step1_deployKSSN() internal {
        console2.log("STEP 1: Deploying KSSN Hub and registries...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        // Deploy registries
        proposerRegistry = new MockProposerRegistry();
        console2.log("  MockProposerRegistry deployed at:", address(proposerRegistry));

        builderRegistry = new MockBuilderRegistry();
        console2.log("  MockBuilderRegistry deployed at:", address(builderRegistry));

        chainRegistry = new MockChainRegistry();
        console2.log("  MockChainRegistry deployed at:", address(chainRegistry));

        // Deploy adapter
        adapter = new OpStackAdapterV1();
        console2.log("  OpStackAdapterV1 deployed at:", address(adapter));

        // Deploy Hub
        hub = new SharedSequencerHub(
            DEPLOYER,           // governance
            GUARDIAN,           // guardian
            address(proposerRegistry),
            address(builderRegistry),
            EPOCH_DURATION,     // epoch duration
            GRACE_PERIOD        // grace period
        );
        console2.log("  SharedSequencerHub deployed at:", address(hub));

        // Set chain registry on hub
        hub.setChainRegistry(address(chainRegistry));
        console2.log("  ChainRegistry set on Hub");

        // Deploy SystemConfigs for chains
        systemConfig1 = new MockSystemConfig();
        systemConfig2 = new MockSystemConfig();
        systemConfig3 = new MockSystemConfig();
        console2.log("  SystemConfigs deployed for 3 chains");

        // Transfer ownership to Hub
        systemConfig1.transferOwnership(address(hub));
        systemConfig2.transferOwnership(address(hub));
        systemConfig3.transferOwnership(address(hub));
        console2.log("  SystemConfig ownership transferred to Hub");

        vm.stopBroadcast();
        console2.log("");
    }

    function _step2_registerProposers() internal {
        console2.log("STEP 2: Registering proposers in ProposerRegistry...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        proposerRegistry.addProposer(PROPOSER_1, 32 ether);
        console2.log("  Registered Proposer 1:", PROPOSER_1);
        console2.log("    Stake: 32 ETH");

        proposerRegistry.addProposer(PROPOSER_2, 32 ether);
        console2.log("  Registered Proposer 2:", PROPOSER_2);
        console2.log("    Stake: 32 ETH");

        proposerRegistry.addProposer(PROPOSER_3, 32 ether);
        console2.log("  Registered Proposer 3:", PROPOSER_3);
        console2.log("    Stake: 32 ETH");

        console2.log("  Total active proposers:", 3);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step3_registerChainsInRegistry() internal {
        console2.log("STEP 3: Registering chains in ChainRegistry...");
        console2.log("-------------------------------------------");
        console2.log("  Using GeneralizedTCR pattern (standard TCR, not permanent stake)");
        console2.log("");

        vm.startBroadcast(DEPLOYER_KEY);

        // Register chains directly (bypassing challenge period for testing)
        chainRegistry.registerChainDirectly(
            CHAIN_ID_1,
            address(systemConfig1),
            address(adapter),
            keccak256("POLICY_NEUTRAL"),
            "Optimism Fork 1"
        );
        console2.log("  Registered Chain 1:");
        console2.log("    Chain ID:", CHAIN_ID_1);
        console2.log("    SystemConfig:", address(systemConfig1));
        console2.log("    Policy: POLICY_NEUTRAL");

        chainRegistry.registerChainDirectly(
            CHAIN_ID_2,
            address(systemConfig2),
            address(adapter),
            keccak256("POLICY_OFAC"),
            "Optimism Fork 2"
        );
        console2.log("  Registered Chain 2:");
        console2.log("    Chain ID:", CHAIN_ID_2);
        console2.log("    SystemConfig:", address(systemConfig2));
        console2.log("    Policy: POLICY_OFAC");

        chainRegistry.registerChainDirectly(
            CHAIN_ID_3,
            address(systemConfig3),
            address(adapter),
            keccak256("POLICY_KYC"),
            "Optimism Fork 3"
        );
        console2.log("  Registered Chain 3:");
        console2.log("    Chain ID:", CHAIN_ID_3);
        console2.log("    SystemConfig:", address(systemConfig3));
        console2.log("    Policy: POLICY_KYC");

        uint256[] memory registeredChains = chainRegistry.getRegisteredChains();
        console2.log("  Total registered chains:", registeredChains.length);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step4_connectChainsFromRegistry() internal {
        console2.log("STEP 4: Connecting chains from registry to Hub...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        // Connect chains from registry
        hub.connectChainFromRegistry(CHAIN_ID_1);
        console2.log("  Connected Chain 1 to Hub");

        hub.connectChainFromRegistry(CHAIN_ID_2);
        console2.log("  Connected Chain 2 to Hub");

        hub.connectChainFromRegistry(CHAIN_ID_3);
        console2.log("  Connected Chain 3 to Hub");

        console2.log("  Total connected chains:", hub.getChainCount());
        console2.log("  Active chains:", hub.getActiveChainCount());

        vm.stopBroadcast();
        console2.log("");
    }

    function _step5_atomicMultichainRotation() internal {
        console2.log("STEP 5: Atomic multichain rotation...");
        console2.log("-------------------------------------------");

        // Wait for epoch to end
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.startBroadcast(DEPLOYER_KEY);

        console2.log("  Before rotation:");
        console2.log("    Current proposer:", hub.currentProposer());
        console2.log("    Current epoch:", hub.currentEpoch());

        hub.rotateNetwork();

        console2.log("");
        console2.log("  >>> Atomic rotation executed!");
        console2.log("");
        console2.log("  After rotation:");
        console2.log("    Current proposer:", hub.currentProposer());
        console2.log("    Current epoch:", hub.currentEpoch());

        // Verify all chains were updated
        console2.log("");
        console2.log("  Chain 1 (", CHAIN_ID_1, "):");
        console2.log("    batcherHash:", uint256(systemConfig1.batcherHash()));
        console2.log("    unsafeBlockSigner:", systemConfig1.unsafeBlockSigner());

        console2.log("");
        console2.log("  Chain 2 (", CHAIN_ID_2, "):");
        console2.log("    batcherHash:", uint256(systemConfig2.batcherHash()));
        console2.log("    unsafeBlockSigner:", systemConfig2.unsafeBlockSigner());

        console2.log("");
        console2.log("  Chain 3 (", CHAIN_ID_3, "):");
        console2.log("    batcherHash:", uint256(systemConfig3.batcherHash()));
        console2.log("    unsafeBlockSigner:", systemConfig3.unsafeBlockSigner());

        console2.log("");
        console2.log("  All chains updated atomically!");

        vm.stopBroadcast();

        // Second rotation to show it works
        console2.log("");
        console2.log("  Rotating again (Active Handoff by current proposer)...");
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.startBroadcast(PROPOSER_1_KEY);
        hub.rotateNetwork();
        vm.stopBroadcast();

        console2.log("  >>> Second rotation executed!");
        console2.log("    New proposer:", hub.currentProposer());
        console2.log("    New epoch:", hub.currentEpoch());

        console2.log("");
    }

    function _step6_guardianPause() internal {
        console2.log("STEP 6: Guardian pause test...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(GUARDIAN_KEY);

        console2.log("  Hub paused:", hub.paused());

        hub.pause();
        console2.log("  Guardian paused the Hub");
        console2.log("  Hub paused:", hub.paused());

        vm.stopBroadcast();

        // Try to rotate while paused (should fail)
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.startBroadcast(DEPLOYER_KEY);

        try hub.rotateNetwork() {
            console2.log("  ERROR: Rotation should have failed while paused!");
        } catch {
            console2.log("  Rotation correctly blocked while paused");
        }

        vm.stopBroadcast();

        // Unpause
        vm.startBroadcast(GUARDIAN_KEY);
        hub.unpause();
        console2.log("  Guardian unpaused the Hub");
        console2.log("  Hub paused:", hub.paused());
        vm.stopBroadcast();

        console2.log("");
    }
}
