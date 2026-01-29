// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MockAdapterV2} from "../test/mocks/MockAdapterV2.sol";

/**
 * @title DeployV2
 * @notice Deployment script for MockAdapterV2 - used by the demo to exercise adapter upgrades.
 *
 * Usage:
 *   forge script script/DeployV2.s.sol:DeployV2 --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * The deployed address can be extracted from broadcast/DeployV2.s.sol/31337/run-latest.json
 */
contract DeployV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        vm.startBroadcast(deployerPrivateKey);

        MockAdapterV2 adapterV2 = new MockAdapterV2();
        console2.log("MockAdapterV2 deployed at:", address(adapterV2));
        console2.log("  Version:", adapterV2.version());

        vm.stopBroadcast();
    }
}
