// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";

/**
 * @title DeploySepolia
 * @notice Deployment script for KlerosSequencerManager on Sepolia testnet.
 *
 * This script deploys to Sepolia and is configured for testing with:
 * - Kleros Curate on Sepolia (or mock if not available)
 * - OP Stack SystemConfig on Sepolia
 *
 * IMPORTANT: Operators are now tuples of (batcher, unsafeSigner).
 * Both keys must be registered together in Kleros Curate.
 *
 * Usage:
 *   source .env.sepolia
 *   forge script script/DeploySepolia.s.sol:DeploySepolia \
 *     --rpc-url $L1_RPC \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Deployer private key
 *   - REGISTRY: Address of Kleros Curate registry on Sepolia
 *   - SYSTEM_CONFIG: Address of OP Stack SystemConfig on Sepolia
 *   - EPOCH_DURATION: Duration of each epoch in seconds (e.g., 3600)
 *   - GUARDIAN: Address of guardian (can be deployer initially)
 */
contract DeploySepolia is Script {
    // Sepolia chain ID
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;

    function run() external {
        // Verify we're on Sepolia
        require(block.chainid == SEPOLIA_CHAIN_ID, "Not on Sepolia");

        // Load configuration from environment
        address registry = vm.envAddress("REGISTRY");
        address systemConfig = vm.envAddress("SYSTEM_CONFIG");
        uint256 epochDuration = vm.envUint("EPOCH_DURATION");
        address guardian = vm.envAddress("GUARDIAN");

        console2.log("");
        console2.log("=== Deploying KlerosSequencerManager to Sepolia ===");
        console2.log("");
        console2.log("Configuration:");
        console2.log("  Registry (Kleros Curate):", registry);
        console2.log("  SystemConfig (OP Stack):", systemConfig);
        console2.log("  Epoch Duration:", epochDuration, "seconds");
        console2.log("  Guardian:", guardian);
        console2.log("");

        // Validate addresses
        require(registry != address(0), "Registry cannot be zero address");
        require(systemConfig != address(0), "SystemConfig cannot be zero address");
        require(epochDuration > 0, "Epoch duration must be positive");

        vm.startBroadcast();

        KlerosSequencerManager manager = new KlerosSequencerManager(
            registry,
            systemConfig,
            epochDuration,
            guardian
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("");
        console2.log("KlerosSequencerManager:", address(manager));
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Transfer SystemConfig ownership to the manager:");
        console2.log("   cast send", systemConfig, '"transferOwnership(address)"', address(manager));
        console2.log("");
        console2.log("2. Register operator tuples in Kleros Curate:");
        console2.log("   Each operator must register BOTH their batcher and unsafeSigner addresses");
        console2.log("   Registry item format: abi.encode(batcher, unsafeSigner)");
        console2.log("");
        console2.log("3. Sync registered operators to the manager:");
        console2.log("   cast send", address(manager), '"syncAddOperator(address,address)"', "<batcher> <unsafeSigner>");
        console2.log("");
        console2.log("4. Set up a keeper to call rotateOperator() each epoch");
        console2.log("");
    }
}
