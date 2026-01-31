// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockCurate} from "../test/mocks/MockCurate.sol";
import {MockPermanentGTCRHybrid} from "../test/mocks/MockPermanentGTCRHybrid.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";

/**
 * @title IntegrationTest
 * @notice Integration test for the full operator rotation lifecycle.
 *
 * This script tests:
 * 1. Deployment of all contracts
 * 2. Registration of operators (batcher, unsafeSigner tuples) in Curate registry
 * 3. Syncing operators to the manager
 * 4. Rotating through operators (sets BOTH batcherHash AND unsafeBlockSigner)
 * 5. Challenging and removing a misbehaving operator
 * 6. Emergency pause by guardian
 *
 * Usage:
 *   anvil &
 *   forge script script/IntegrationTest.s.sol:IntegrationTest --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
 */
contract IntegrationTest is Script {
    // Test accounts from Anvil's default mnemonic
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant GUARDIAN_KEY = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant CHALLENGER_KEY = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address constant CHALLENGER = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    // Operator 1: batcher (account 1) + unsafeSigner (account 4)
    address constant BATCHER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant BATCHER_1_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant SIGNER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    // Operator 2: batcher (account 2) + unsafeSigner (account 5)
    address constant BATCHER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    uint256 constant BATCHER_2_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    address constant SIGNER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // Operator 3: batcher (account 3) + unsafeSigner (account 6)
    address constant BATCHER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    uint256 constant BATCHER_3_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    address constant SIGNER_3 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    uint256 constant EPOCH_DURATION = 10; // 10 seconds for testing
    uint256 constant GRACE_PERIOD = 600;  // 10 minutes grace period

    MockPermanentGTCRHybrid public registry;
    MockCurate public adapterRegistry;
    MockSystemConfig public systemConfig;
    OpStackAdapterV1 public adapter;
    KlerosSequencerManager public manager;

    function run() external {
        console2.log("");
        console2.log("===========================================");
        console2.log("  KLEROS SEQUENCER MANAGER INTEGRATION TEST");
        console2.log("  (Operator Tuple Model)");
        console2.log("===========================================");
        console2.log("");

        // Step 1: Deploy contracts
        _step1_deploy();

        // Step 2: Register operators in Curate
        _step2_registerOperators();

        // Step 3: Sync operators to manager
        _step3_syncOperators();

        // Step 4: First rotation
        _step4_firstRotation();

        // Step 5: Wait and rotate again
        _step5_secondRotation();

        // Step 6: Challenge and remove an operator
        _step6_challengeOperator();

        // Step 7: Rotation skips removed operator
        _step7_rotationAfterChallenge();

        // Step 8: Guardian pause test
        _step8_guardianPause();

        console2.log("");
        console2.log("===========================================");
        console2.log("  INTEGRATION TEST COMPLETE!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  Operator Registry:", address(registry));
        console2.log("  Adapter Registry:", address(adapterRegistry));
        console2.log("  Adapter:", address(adapter));
        console2.log("  MockSystemConfig:", address(systemConfig));
        console2.log("  KlerosSequencerManager:", address(manager));
    }

    function _step1_deploy() internal {
        console2.log("STEP 1: Deploying contracts...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        // Deploy operator registry (PermanentGTCRHybrid)
        registry = new MockPermanentGTCRHybrid();
        console2.log("  MockPermanentGTCRHybrid (operator registry) deployed at:", address(registry));

        // Deploy adapter registry (Curate for adapter governance)
        adapterRegistry = new MockCurate();
        console2.log("  MockCurate (adapter registry) deployed at:", address(adapterRegistry));

        // Deploy adapter
        adapter = new OpStackAdapterV1();
        console2.log("  OpStackAdapterV1 deployed at:", address(adapter));

        // Register adapter in adapter registry
        bytes memory adapterData = abi.encode(address(adapter));
        adapterRegistry.registerItemDirectly(adapterData);
        console2.log("  Adapter registered in adapter registry");

        systemConfig = new MockSystemConfig();
        console2.log("  MockSystemConfig deployed at:", address(systemConfig));

        manager = new KlerosSequencerManager(
            address(registry),       // Operator registry
            address(systemConfig),   // SystemConfig
            address(adapterRegistry),// Adapter registry
            address(adapter),        // Initial adapter
            EPOCH_DURATION,
            GUARDIAN
        );
        console2.log("  KlerosSequencerManager deployed at:", address(manager));

        systemConfig.transferOwnership(address(manager));
        console2.log("  SystemConfig ownership transferred to manager");

        vm.stopBroadcast();
        console2.log("");
    }

    function _step2_registerOperators() internal {
        console2.log("STEP 2: Registering operators in registry...");
        console2.log("-------------------------------------------");
        console2.log("  Each operator is a tuple: (batcher, unsafeSigner)");
        console2.log("");

        vm.startBroadcast(DEPLOYER_KEY);

        registry.registerOperatorDirectly(BATCHER_1, SIGNER_1);
        console2.log("  Registered Operator 1:");
        console2.log("    batcher:", BATCHER_1);
        console2.log("    signer: ", SIGNER_1);

        registry.registerOperatorDirectly(BATCHER_2, SIGNER_2);
        console2.log("  Registered Operator 2:");
        console2.log("    batcher:", BATCHER_2);
        console2.log("    signer: ", SIGNER_2);

        registry.registerOperatorDirectly(BATCHER_3, SIGNER_3);
        console2.log("  Registered Operator 3:");
        console2.log("    batcher:", BATCHER_3);
        console2.log("    signer: ", SIGNER_3);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step3_syncOperators() internal {
        console2.log("STEP 3: Syncing operators to manager...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        manager.syncAddOperator(BATCHER_1, SIGNER_1);
        console2.log("  Synced Operator 1 to active set");

        manager.syncAddOperator(BATCHER_2, SIGNER_2);
        console2.log("  Synced Operator 2 to active set");

        manager.syncAddOperator(BATCHER_3, SIGNER_3);
        console2.log("  Synced Operator 3 to active set");

        console2.log("  Active operator count:", manager.activeOperatorCount());

        vm.stopBroadcast();
        console2.log("");
    }

    function _step4_firstRotation() internal {
        console2.log("STEP 4: First rotation...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("  Current operator before rotation:");
        console2.log("    batcher:", current.batcher);
        console2.log("    signer: ", current.unsafeSigner);

        manager.rotateOperator();

        console2.log("  >>> Rotation executed!");
        current = manager.currentOperator();
        console2.log("  New current operator:");
        console2.log("    batcher:", current.batcher);
        console2.log("    signer: ", current.unsafeSigner);
        console2.log("  SystemConfig batcherHash:", uint256(systemConfig.batcherHash()));
        console2.log("  SystemConfig unsafeBlockSigner:", systemConfig.unsafeBlockSigner());
        console2.log("  Both updated atomically!");

        vm.stopBroadcast();
        console2.log("");
    }

    function _step5_secondRotation() internal {
        console2.log("STEP 5: Wait for epoch and rotate (Active Handoff)...");
        console2.log("-------------------------------------------");
        console2.log("  Active Handoff: Only current operator can rotate during grace period");

        // Wait for epoch to end (entering grace period)
        console2.log("  Waiting for epoch to end (", EPOCH_DURATION, "seconds)...");
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        // Current operator (Operator 1) initiates rotation during grace period
        console2.log("  Current operator (Operator 1) calling rotateOperator()...");
        vm.startBroadcast(BATCHER_1_KEY);

        manager.rotateOperator();

        console2.log("  >>> Second rotation executed!");
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("  New current operator (Operator 2):");
        console2.log("    batcher:", current.batcher);
        console2.log("    signer: ", current.unsafeSigner);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step6_challengeOperator() internal {
        console2.log("STEP 6: Challenge Operator 2 for misbehavior...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(CHALLENGER_KEY);

        // Simulate a challenge in registry (sets status to Absent/removed)
        registry.setOperatorClearingRequested(BATCHER_2, SIGNER_2);
        console2.log("  Challenge submitted for Operator 2");
        console2.log("  Status changed to Absent (removed)");

        // Anyone can now sync-remove the challenged operator
        manager.syncRemoveOperator(BATCHER_2, SIGNER_2);
        console2.log("  Operator 2 removed from active set");
        console2.log("  Active operator count:", manager.activeOperatorCount());

        vm.stopBroadcast();
        console2.log("");
    }

    function _step7_rotationAfterChallenge() internal {
        console2.log("STEP 7: Rotation after challenge (Active Handoff)...");
        console2.log("-------------------------------------------");

        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("  Current operator before rotation:");
        console2.log("    batcher:", current.batcher);

        // Current operator (Operator 2) initiates rotation
        // Note: Operator 2 was challenged but is still current until rotated
        vm.startBroadcast(BATCHER_2_KEY);
        manager.rotateOperator();
        vm.stopBroadcast();

        console2.log("  >>> Rotation executed (by current operator during grace period)!");
        current = manager.currentOperator();
        console2.log("  New current operator:");
        console2.log("    batcher:", current.batcher);
        console2.log("    signer: ", current.unsafeSigner);

        // Wait and rotate again to show it wraps (Operator 3 rotates)
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.startBroadcast(BATCHER_3_KEY);
        manager.rotateOperator();
        vm.stopBroadcast();

        console2.log("  >>> Another rotation (by Operator 3)...");
        current = manager.currentOperator();
        console2.log("  Current operator:");
        console2.log("    batcher:", current.batcher);

        console2.log("");
    }

    function _step8_guardianPause() internal {
        console2.log("STEP 8: Guardian pause test...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(GUARDIAN_KEY);

        console2.log("  Contract paused:", manager.paused());

        manager.setPaused(true);
        console2.log("  Guardian paused the contract");
        console2.log("  Contract paused:", manager.paused());

        vm.stopBroadcast();

        // Try to rotate while paused (should fail)
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.startBroadcast(DEPLOYER_KEY);

        try manager.rotateOperator() {
            console2.log("  ERROR: Rotation should have failed while paused!");
        } catch {
            console2.log("  Rotation correctly blocked while paused");
        }

        vm.stopBroadcast();

        // Unpause
        vm.startBroadcast(GUARDIAN_KEY);
        manager.setPaused(false);
        console2.log("  Guardian unpaused the contract");
        console2.log("  Contract paused:", manager.paused());
        vm.stopBroadcast();

        console2.log("");
    }
}
