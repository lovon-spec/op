// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";

/**
 * @title Deploy
 * @notice Deployment script for KlerosSequencerManager.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Required environment variables:
 *   - PRIVATE_KEY: Deployer private key
 *   - REGISTRY: Address of Kleros Curate Classic registry
 *   - SYSTEM_CONFIG: Address of OP Stack SystemConfig
 *   - EPOCH_DURATION: Duration of each epoch in seconds
 *   - GUARDIAN: Address of guardian (can be 0x0 to disable)
 */
contract Deploy is Script {
    function run() external {
        // Load configuration from environment
        address registry = vm.envAddress("REGISTRY");
        address systemConfig = vm.envAddress("SYSTEM_CONFIG");
        uint256 epochDuration = vm.envUint("EPOCH_DURATION");
        address guardian = vm.envAddress("GUARDIAN");

        console2.log("Deploying KlerosSequencerManager with:");
        console2.log("  Registry:", registry);
        console2.log("  SystemConfig:", systemConfig);
        console2.log("  Epoch Duration:", epochDuration);
        console2.log("  Guardian:", guardian);

        vm.startBroadcast();

        KlerosSequencerManager manager = new KlerosSequencerManager(
            registry,
            systemConfig,
            epochDuration,
            guardian
        );

        vm.stopBroadcast();

        console2.log("KlerosSequencerManager deployed at:", address(manager));
        console2.log("");
        console2.log("IMPORTANT: Transfer SystemConfig ownership to the manager:");
        console2.log("  systemConfig.transferOwnership(", address(manager), ")");
    }
}
