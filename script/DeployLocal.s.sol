// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockCurate} from "../test/mocks/MockCurate.sol";

/**
 * @title DeployLocal
 * @notice Deployment script for local Anvil testing.
 *
 * This deploys:
 * - MockCurate (simulating Kleros Curate Classic)
 * - MockSystemConfig (simulating OP Stack SystemConfig)
 * - KlerosSequencerManager (the main contract)
 *
 * Then registers test sequencers and transfers ownership.
 *
 * Usage:
 *   anvil &
 *   forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract DeployLocal is Script {
    // Test accounts from Anvil's default mnemonic
    // "test test test test test test test test test test test junk"
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant SEQUENCER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SEQUENCER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant SEQUENCER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    uint256 constant EPOCH_DURATION = 60; // 1 minute for testing

    MockCurate public curate;
    MockSystemConfig public systemConfig;
    KlerosSequencerManager public manager;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockCurate (simulating Kleros registry)
        curate = new MockCurate();
        console2.log("MockCurate deployed at:", address(curate));

        // Deploy MockSystemConfig (simulating OP Stack SystemConfig)
        systemConfig = new MockSystemConfig();
        console2.log("MockSystemConfig deployed at:", address(systemConfig));

        // Deploy KlerosSequencerManager
        manager = new KlerosSequencerManager(
            address(curate),
            address(systemConfig),
            EPOCH_DURATION,
            GUARDIAN
        );
        console2.log("KlerosSequencerManager deployed at:", address(manager));
        console2.log("  Registry:", address(curate));
        console2.log("  SystemConfig:", address(systemConfig));
        console2.log("  Epoch Duration:", EPOCH_DURATION, "seconds");
        console2.log("  Guardian:", GUARDIAN);

        // Transfer SystemConfig ownership to manager
        systemConfig.transferOwnership(address(manager));
        console2.log("SystemConfig ownership transferred to manager");

        // Register test sequencers in the mock registry
        _registerSequencer(SEQUENCER_1);
        _registerSequencer(SEQUENCER_2);
        _registerSequencer(SEQUENCER_3);

        // Add sequencers to the manager
        manager.syncAddSequencer(SEQUENCER_1);
        manager.syncAddSequencer(SEQUENCER_2);
        manager.syncAddSequencer(SEQUENCER_3);

        console2.log("\nRegistered sequencers:");
        console2.log("  1:", SEQUENCER_1);
        console2.log("  2:", SEQUENCER_2);
        console2.log("  3:", SEQUENCER_3);

        // Perform first rotation
        manager.rotateSequencer();
        console2.log("\nFirst rotation complete. Current sequencer:", manager.currentSequencer());
        console2.log("Batcher hash:", uint256(systemConfig.batcherHash()));

        vm.stopBroadcast();

        // Output deployment info
        console2.log("\n=== Deployment Summary ===");
        console2.log("MockCurate:", address(curate));
        console2.log("MockSystemConfig:", address(systemConfig));
        console2.log("KlerosSequencerManager:", address(manager));
        console2.log("\nTo rotate sequencer (after epoch ends):");
        console2.log("  cast send", address(manager), "'rotateSequencer()'");
        console2.log("\nTo check current sequencer:");
        console2.log("  cast call", address(manager), "'currentSequencer()'");
    }

    function _registerSequencer(address sequencer) internal {
        bytes memory data = abi.encode(sequencer);
        curate.registerItemDirectly(data);
        console2.log("Registered in curate:", sequencer);
    }
}
