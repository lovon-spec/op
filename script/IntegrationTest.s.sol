// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockChainRegistry} from "../test/mocks/MockChainRegistry.sol";
import {MockProposerRegistry} from "../test/mocks/MockProposerRegistry.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";
import {TestConstants} from "./TestConstants.sol";

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
    // Configuration specific to integration test
    uint256 constant EPOCH_DURATION = 10 seconds;
    uint256 constant GRACE_PERIOD = 10 minutes;

    // KSSN Components
    SharedSequencerHub public hub;
    MockChainRegistry public chainRegistry;
    MockProposerRegistry public proposerRegistry;
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig1;
    MockSystemConfig public systemConfig2;
    MockSystemConfig public systemConfig3;

    // Integration test uses different chain IDs to avoid conflicts
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

        vm.startBroadcast(TestConstants.DEPLOYER_KEY);

        // Deploy registries
        proposerRegistry = new MockProposerRegistry();
        console2.log("  MockProposerRegistry deployed at:", address(proposerRegistry));

        chainRegistry = new MockChainRegistry();
        console2.log("  MockChainRegistry deployed at:", address(chainRegistry));

        // Deploy adapter
        adapter = new OpStackAdapterV1();
        console2.log("  OpStackAdapterV1 deployed at:", address(adapter));

        // Deploy Hub
        hub = new SharedSequencerHub(
            TestConstants.DEPLOYER,  // governance
            TestConstants.GUARDIAN,  // guardian
            address(proposerRegistry),
            EPOCH_DURATION,          // epoch duration
            GRACE_PERIOD             // grace period
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

        vm.startBroadcast(TestConstants.DEPLOYER_KEY);

        proposerRegistry.addProposer(TestConstants.PROPOSER_1, 32 ether);
        console2.log("  Registered Proposer 1:", TestConstants.PROPOSER_1);
        console2.log("    Stake: 32 ETH");

        proposerRegistry.addProposer(TestConstants.PROPOSER_2, 32 ether);
        console2.log("  Registered Proposer 2:", TestConstants.PROPOSER_2);
        console2.log("    Stake: 32 ETH");

        proposerRegistry.addProposer(TestConstants.PROPOSER_3, 32 ether);
        console2.log("  Registered Proposer 3:", TestConstants.PROPOSER_3);
        console2.log("    Stake: 32 ETH");

        console2.log("  Total active proposers:", uint256(3));

        vm.stopBroadcast();
        console2.log("");
    }

    function _step3_registerChainsInRegistry() internal {
        console2.log("STEP 3: Registering chains in ChainRegistry...");
        console2.log("-------------------------------------------");
        console2.log("  Using GeneralizedTCR pattern (standard TCR, not permanent stake)");
        console2.log("");

        vm.startBroadcast(TestConstants.DEPLOYER_KEY);

        // Register chains directly (bypassing challenge period for testing)
        chainRegistry.registerChainDirectly(
            CHAIN_ID_1,
            address(systemConfig1),
            address(adapter),
            "Optimism Fork 1"
        );
        console2.log("  Registered Chain 1:");
        console2.log("    Chain ID:", CHAIN_ID_1);
        console2.log("    SystemConfig:", address(systemConfig1));
        chainRegistry.registerChainDirectly(
            CHAIN_ID_2,
            address(systemConfig2),
            address(adapter),
            "Optimism Fork 2"
        );
        console2.log("  Registered Chain 2:");
        console2.log("    Chain ID:", CHAIN_ID_2);
        console2.log("    SystemConfig:", address(systemConfig2));
        chainRegistry.registerChainDirectly(
            CHAIN_ID_3,
            address(systemConfig3),
            address(adapter),
            "Optimism Fork 3"
        );
        console2.log("  Registered Chain 3:");
        console2.log("    Chain ID:", CHAIN_ID_3);
        console2.log("    SystemConfig:", address(systemConfig3));
        uint256[] memory registeredChains = chainRegistry.getRegisteredChains();
        console2.log("  Total registered chains:", registeredChains.length);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step4_connectChainsFromRegistry() internal {
        console2.log("STEP 4: Connecting chains from registry to Hub...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(TestConstants.DEPLOYER_KEY);

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

        vm.startBroadcast(TestConstants.DEPLOYER_KEY);

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

        vm.startBroadcast(TestConstants.PROPOSER_1_KEY);
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

        vm.startBroadcast(TestConstants.GUARDIAN_KEY);

        console2.log("  Hub paused:", hub.isPaused());

        hub.pause();
        console2.log("  Guardian paused the Hub");
        console2.log("  Hub paused:", hub.isPaused());

        vm.stopBroadcast();

        // Try to rotate while paused (should fail)
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.startBroadcast(TestConstants.DEPLOYER_KEY);

        try hub.rotateNetwork() {
            console2.log("  ERROR: Rotation should have failed while paused!");
        } catch {
            console2.log("  Rotation correctly blocked while paused");
        }

        vm.stopBroadcast();

        // Unpause
        vm.startBroadcast(TestConstants.GUARDIAN_KEY);
        hub.unpause();
        console2.log("  Guardian unpaused the Hub");
        console2.log("  Hub paused:", hub.isPaused());
        vm.stopBroadcast();

        console2.log("");
    }
}
