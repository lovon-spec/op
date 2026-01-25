// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockCurate} from "../test/mocks/MockCurate.sol";

/**
 * @title Demo
 * @notice Demonstrates the full operator rotation lifecycle.
 *
 * This script shows:
 * 1. Deployment of all contracts
 * 2. Registration of operators (batcher, unsafeSigner tuples) in Curate registry
 * 3. Syncing operators to the manager
 * 4. Rotating through operators (sets BOTH batcherHash AND unsafeBlockSigner)
 * 5. Challenging and removing a misbehaving operator
 * 6. Emergency pause by guardian
 *
 * Usage:
 *   anvil &
 *   forge script script/Demo.s.sol:Demo --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
 */
contract Demo is Script {
    // Test accounts from Anvil's default mnemonic
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant GUARDIAN_KEY = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant CHALLENGER_KEY = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address constant CHALLENGER = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    // Operator 1: batcher (account 1) + unsafeSigner (account 4)
    address constant BATCHER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SIGNER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    // Operator 2: batcher (account 2) + unsafeSigner (account 5)
    address constant BATCHER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant SIGNER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // Operator 3: batcher (account 3) + unsafeSigner (account 6)
    address constant BATCHER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant SIGNER_3 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    uint256 constant EPOCH_DURATION = 10; // 10 seconds for demo

    MockCurate public curate;
    MockSystemConfig public systemConfig;
    KlerosSequencerManager public manager;

    function run() external {
        console2.log("");
        console2.log("===========================================");
        console2.log("  KLEROS SEQUENCER MANAGER DEMO");
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

        // Step 8: Guardian pause demo
        _step8_guardianPause();

        console2.log("");
        console2.log("===========================================");
        console2.log("  DEMO COMPLETE!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  MockCurate:", address(curate));
        console2.log("  MockSystemConfig:", address(systemConfig));
        console2.log("  KlerosSequencerManager:", address(manager));
    }

    function _step1_deploy() internal {
        console2.log("STEP 1: Deploying contracts...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        curate = new MockCurate();
        console2.log("  MockCurate deployed at:", address(curate));

        systemConfig = new MockSystemConfig();
        console2.log("  MockSystemConfig deployed at:", address(systemConfig));

        manager = new KlerosSequencerManager(
            address(curate),
            address(systemConfig),
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
        console2.log("STEP 2: Registering operators in Curate...");
        console2.log("-------------------------------------------");
        console2.log("  Each operator is a tuple: (batcher, unsafeSigner)");
        console2.log("");

        vm.startBroadcast(DEPLOYER_KEY);

        curate.registerOperatorDirectly(BATCHER_1, SIGNER_1);
        console2.log("  Registered Operator 1:");
        console2.log("    batcher:", BATCHER_1);
        console2.log("    signer: ", SIGNER_1);

        curate.registerOperatorDirectly(BATCHER_2, SIGNER_2);
        console2.log("  Registered Operator 2:");
        console2.log("    batcher:", BATCHER_2);
        console2.log("    signer: ", SIGNER_2);

        curate.registerOperatorDirectly(BATCHER_3, SIGNER_3);
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
        console2.log("STEP 5: Wait for epoch and rotate again...");
        console2.log("-------------------------------------------");

        // Wait for epoch to end
        console2.log("  Waiting for epoch to end (", EPOCH_DURATION, "seconds)...");
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.startBroadcast(DEPLOYER_KEY);

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

        // Simulate a challenge in Curate (sets status to ClearingRequested)
        curate.setOperatorClearingRequested(BATCHER_2, SIGNER_2);
        console2.log("  Challenge submitted for Operator 2");
        console2.log("  Status changed to ClearingRequested");

        // Anyone can now sync-remove the challenged operator
        manager.syncRemoveOperator(BATCHER_2, SIGNER_2);
        console2.log("  Operator 2 removed from active set");
        console2.log("  Active operator count:", manager.activeOperatorCount());

        vm.stopBroadcast();
        console2.log("");
    }

    function _step7_rotationAfterChallenge() internal {
        console2.log("STEP 7: Rotation after challenge...");
        console2.log("-------------------------------------------");

        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.startBroadcast(DEPLOYER_KEY);

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("  Current operator before rotation:");
        console2.log("    batcher:", current.batcher);

        manager.rotateOperator();

        console2.log("  >>> Rotation executed!");
        current = manager.currentOperator();
        console2.log("  New current operator:");
        console2.log("    batcher:", current.batcher);
        console2.log("    signer: ", current.unsafeSigner);

        // Wait and rotate again to show it wraps
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        manager.rotateOperator();

        console2.log("  >>> Another rotation...");
        current = manager.currentOperator();
        console2.log("  Current operator:");
        console2.log("    batcher:", current.batcher);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step8_guardianPause() internal {
        console2.log("STEP 8: Guardian pause demonstration...");
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
