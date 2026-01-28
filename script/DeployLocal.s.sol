// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockCurate} from "../test/mocks/MockCurate.sol";
import {MockPermanentGTCRHybrid} from "../test/mocks/MockPermanentGTCRHybrid.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";

/**
 * @title DeployLocal
 * @notice Deployment script for local Anvil testing with Green Adapter Architecture.
 *
 * This deploys:
 * - MockPermanentGTCRHybrid (simulating Kleros operator registry)
 * - MockCurate (simulating Kleros adapter registry)
 * - OpStackAdapterV1 (the sequencer rotation adapter)
 * - MockSystemConfig (simulating OP Stack SystemConfig)
 * - KlerosSequencerManager (the main contract)
 *
 * Then registers test operators (batcher, unsafeSigner tuples) and transfers ownership.
 *
 * Usage:
 *   anvil &
 *   forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract DeployLocal is Script {
    // Test accounts from Anvil's default mnemonic
    // "test test test test test test test test test test test junk"
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Operator 1: accounts 1 (batcher) and 4 (unsafe signer)
    address constant BATCHER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SIGNER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    // Operator 2: accounts 2 (batcher) and 5 (unsafe signer)
    address constant BATCHER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant SIGNER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // Operator 3: accounts 3 (batcher) and 6 (unsafe signer)
    address constant BATCHER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant SIGNER_3 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    uint256 constant EPOCH_DURATION = 10; // 10 seconds for demo

    MockPermanentGTCRHybrid public registry;
    MockCurate public adapterRegistry;
    MockSystemConfig public systemConfig;
    OpStackAdapterV1 public adapter;
    KlerosSequencerManager public manager;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        vm.startBroadcast(deployerPrivateKey);

        // Deploy operator registry (PermanentGTCRHybrid)
        registry = new MockPermanentGTCRHybrid();
        console2.log("MockPermanentGTCRHybrid (operator registry) deployed at:", address(registry));

        // Deploy adapter registry (Curate for adapter governance)
        adapterRegistry = new MockCurate();
        console2.log("MockCurate (adapter registry) deployed at:", address(adapterRegistry));

        // Deploy adapter
        adapter = new OpStackAdapterV1();
        console2.log("OpStackAdapterV1 deployed at:", address(adapter));

        // Register adapter in adapter registry
        bytes memory adapterData = abi.encode(address(adapter));
        adapterRegistry.registerItemDirectly(adapterData);
        console2.log("Adapter registered in adapter registry");

        // Deploy MockSystemConfig (simulating OP Stack SystemConfig)
        systemConfig = new MockSystemConfig();
        console2.log("MockSystemConfig deployed at:", address(systemConfig));

        // Deploy KlerosSequencerManager with Green Adapter Architecture
        manager = new KlerosSequencerManager(
            address(registry),       // Operator registry
            address(systemConfig),   // SystemConfig
            address(adapterRegistry),// Adapter registry
            address(adapter),        // Initial adapter
            EPOCH_DURATION,
            GUARDIAN
        );
        console2.log("KlerosSequencerManager deployed at:", address(manager));
        console2.log("  Operator Registry:", address(registry));
        console2.log("  Adapter Registry:", address(adapterRegistry));
        console2.log("  Adapter:", address(adapter));
        console2.log("  SystemConfig:", address(systemConfig));
        console2.log("  Epoch Duration:", EPOCH_DURATION, "seconds");
        console2.log("  Guardian:", GUARDIAN);

        // Transfer SystemConfig ownership to manager
        systemConfig.transferOwnership(address(manager));
        console2.log("SystemConfig ownership transferred to manager");

        // Register test operators in the mock registry
        // Each operator is a tuple of (batcher, unsafeSigner)
        console2.log("\nRegistering operators in operator registry:");
        _registerOperator(BATCHER_1, SIGNER_1, 1);
        _registerOperator(BATCHER_2, SIGNER_2, 2);
        _registerOperator(BATCHER_3, SIGNER_3, 3);

        // Add operators to the manager
        manager.syncAddOperator(BATCHER_1, SIGNER_1);
        manager.syncAddOperator(BATCHER_2, SIGNER_2);
        manager.syncAddOperator(BATCHER_3, SIGNER_3);

        console2.log("\nOperators added to manager:");
        console2.log("  Operator 1: batcher=", BATCHER_1, "signer=", SIGNER_1);
        console2.log("  Operator 2: batcher=", BATCHER_2, "signer=", SIGNER_2);
        console2.log("  Operator 3: batcher=", BATCHER_3, "signer=", SIGNER_3);

        // Perform first rotation
        manager.rotateOperator();
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("\nFirst rotation complete:");
        console2.log("  Current batcher:", current.batcher);
        console2.log("  Current unsafe signer:", current.unsafeSigner);
        console2.log("  Batcher hash:", uint256(systemConfig.batcherHash()));
        console2.log("  Unsafe block signer:", systemConfig.unsafeBlockSigner());

        vm.stopBroadcast();

        // Output deployment info
        console2.log("\n=== Deployment Summary ===");
        console2.log("Operator Registry:", address(registry));
        console2.log("Adapter Registry:", address(adapterRegistry));
        console2.log("Adapter:", address(adapter));
        console2.log("MockSystemConfig:", address(systemConfig));
        console2.log("KlerosSequencerManager:", address(manager));
        console2.log("\nTo rotate operator (after epoch ends):");
        console2.log("  cast send", address(manager), "'rotateOperator()'");
        console2.log("\nTo check current operator:");
        console2.log("  cast call", address(manager), "'currentOperator()'");
    }

    function _registerOperator(address batcher, address unsafeSigner, uint256 num) internal {
        registry.registerOperatorDirectly(batcher, unsafeSigner);
        console2.log("  Operator", num, "registered: batcher=", batcher);
    }
}
