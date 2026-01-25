// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockCurate} from "../test/mocks/MockCurate.sol";

/**
 * @title Demo
 * @notice Demonstrates the full sequencer rotation lifecycle.
 *
 * This script shows:
 * 1. Deployment of all contracts
 * 2. Registration of sequencers in Curate registry
 * 3. Syncing sequencers to the manager
 * 4. Rotating through sequencers
 * 5. Challenging and removing a misbehaving sequencer
 * 6. Emergency pause by guardian
 *
 * Usage:
 *   anvil &
 *   forge script script/Demo.s.sol:Demo --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
 */
contract Demo is Script {
    // Test accounts from Anvil's default mnemonic
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant SEQUENCER_1_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant SEQUENCER_2_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant SEQUENCER_3_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant GUARDIAN_KEY = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant CHALLENGER_KEY = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant SEQUENCER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SEQUENCER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant SEQUENCER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address constant CHALLENGER = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    uint256 constant EPOCH_DURATION = 10; // 10 seconds for demo

    MockCurate public curate;
    MockSystemConfig public systemConfig;
    KlerosSequencerManager public manager;

    function run() external {
        console2.log("");
        console2.log("===========================================");
        console2.log("  KLEROS SEQUENCER MANAGER DEMO");
        console2.log("===========================================");
        console2.log("");

        // Step 1: Deploy contracts
        _step1_deploy();

        // Step 2: Register sequencers in Curate
        _step2_registerSequencers();

        // Step 3: Sync sequencers to manager
        _step3_syncSequencers();

        // Step 4: First rotation
        _step4_firstRotation();

        // Step 5: Wait and rotate again
        _step5_secondRotation();

        // Step 6: Challenge and remove a sequencer
        _step6_challengeSequencer();

        // Step 7: Rotation skips removed sequencer
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

    function _step2_registerSequencers() internal {
        console2.log("STEP 2: Registering sequencers in Curate...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        curate.registerItemDirectly(abi.encode(SEQUENCER_1));
        console2.log("  Registered SEQUENCER_1:", SEQUENCER_1);

        curate.registerItemDirectly(abi.encode(SEQUENCER_2));
        console2.log("  Registered SEQUENCER_2:", SEQUENCER_2);

        curate.registerItemDirectly(abi.encode(SEQUENCER_3));
        console2.log("  Registered SEQUENCER_3:", SEQUENCER_3);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step3_syncSequencers() internal {
        console2.log("STEP 3: Syncing sequencers to manager...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        manager.syncAddSequencer(SEQUENCER_1);
        console2.log("  Synced SEQUENCER_1 to active set");

        manager.syncAddSequencer(SEQUENCER_2);
        console2.log("  Synced SEQUENCER_2 to active set");

        manager.syncAddSequencer(SEQUENCER_3);
        console2.log("  Synced SEQUENCER_3 to active set");

        console2.log("  Active sequencer count:", manager.activeSequencerCount());

        vm.stopBroadcast();
        console2.log("");
    }

    function _step4_firstRotation() internal {
        console2.log("STEP 4: First rotation...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(DEPLOYER_KEY);

        console2.log("  Current sequencer before rotation:", manager.currentSequencer());
        console2.log("  Current batcher hash:", uint256(systemConfig.batcherHash()));

        manager.rotateSequencer();

        console2.log("  >>> Rotation executed!");
        console2.log("  New current sequencer:", manager.currentSequencer());
        console2.log("  New batcher hash:", uint256(systemConfig.batcherHash()));
        console2.log("  Expected:", uint256(uint160(SEQUENCER_1)));

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

        manager.rotateSequencer();

        console2.log("  >>> Second rotation executed!");
        console2.log("  New current sequencer:", manager.currentSequencer());
        console2.log("  Should be SEQUENCER_2:", SEQUENCER_2);

        vm.stopBroadcast();
        console2.log("");
    }

    function _step6_challengeSequencer() internal {
        console2.log("STEP 6: Challenge SEQUENCER_2 for misbehavior...");
        console2.log("-------------------------------------------");

        vm.startBroadcast(CHALLENGER_KEY);

        // Simulate a challenge in Curate (sets status to ClearingRequested)
        bytes32 itemID = manager.itemIDFor(SEQUENCER_2);
        curate.setClearingRequested(itemID);
        console2.log("  Challenge submitted for SEQUENCER_2");
        console2.log("  Status changed to ClearingRequested");

        // Anyone can now sync-remove the challenged sequencer
        manager.syncRemoveSequencer(SEQUENCER_2);
        console2.log("  SEQUENCER_2 removed from active set");
        console2.log("  Active sequencer count:", manager.activeSequencerCount());

        vm.stopBroadcast();
        console2.log("");
    }

    function _step7_rotationAfterChallenge() internal {
        console2.log("STEP 7: Rotation after challenge...");
        console2.log("-------------------------------------------");

        // After SEQUENCER_2 removal via swap-pop:
        // - activeSequencers = [SEQUENCER_1, SEQUENCER_3]
        // - currentIndex still points to position where SEQUENCER_2 was (now SEQUENCER_3)

        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.startBroadcast(DEPLOYER_KEY);

        console2.log("  Current sequencer before rotation:", manager.currentSequencer());
        console2.log("  (This is SEQUENCER_3 which took SEQUENCER_2's position via swap-pop)");

        manager.rotateSequencer();

        console2.log("  >>> Rotation executed!");
        console2.log("  New current sequencer:", manager.currentSequencer());
        console2.log("  Should be SEQUENCER_1 (next in round-robin):", SEQUENCER_1);

        // Wait and rotate again to show it wraps back to SEQUENCER_3
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        manager.rotateSequencer();

        console2.log("  >>> Another rotation...");
        console2.log("  Current sequencer:", manager.currentSequencer());
        console2.log("  Should be SEQUENCER_3:", SEQUENCER_3);

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

        try manager.rotateSequencer() {
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
