// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";

/**
 * @title DeployMainnet
 * @notice Deployment script for KlerosSequencerManager on Ethereum mainnet.
 *
 * IMPORTANT: This deploys to mainnet with real value at stake.
 * Double-check all parameters before deploying.
 *
 * CRITICAL: Operators are tuples of (batcher, unsafeSigner). OP Stack requires:
 *   1. batcher - EOA that posts batches to L1 (sets SystemConfig.batcherHash)
 *   2. unsafeSigner - Key that signs unsafe blocks on P2P (sets SystemConfig.unsafeBlockSigner)
 *
 * Both keys are rotated atomically to prevent half-rotated states.
 *
 * Usage:
 *   source .env.mainnet
 *   forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url $L1_RPC \
 *     --broadcast \
 *     --verify \
 *     --slow \
 *     -vvvv
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Deployer private key
 *   - REGISTRY: Address of Kleros Curate Classic registry on mainnet
 *   - SYSTEM_CONFIG: Address of OP Stack SystemConfig on mainnet
 *   - EPOCH_DURATION: Duration of each epoch in seconds (e.g., 3600 for 1 hour)
 *   - GUARDIAN: Address of guardian multisig
 *
 * Kleros Curate on Mainnet:
 *   - Factory: 0x0000000000000000000000000000000000000000 (deploy new TCR or use existing)
 *   - See: https://curate.kleros.io/
 */
contract DeployMainnet is Script {
    // Mainnet chain ID
    uint256 constant MAINNET_CHAIN_ID = 1;

    function run() external {
        // Verify we're on mainnet
        require(block.chainid == MAINNET_CHAIN_ID, "Not on Mainnet");

        // Load configuration from environment
        address registry = vm.envAddress("REGISTRY");
        address systemConfig = vm.envAddress("SYSTEM_CONFIG");
        uint256 epochDuration = vm.envUint("EPOCH_DURATION");
        address guardian = vm.envAddress("GUARDIAN");

        console2.log("");
        console2.log("================================================================");
        console2.log("       MAINNET DEPLOYMENT - CONSTITUTIONAL L2                   ");
        console2.log("================================================================");
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
        require(epochDuration >= 300, "Epoch duration should be at least 5 minutes");
        require(guardian != address(0), "Guardian required for mainnet");

        // Sanity checks for mainnet
        require(epochDuration <= 86400, "Epoch duration seems too long (>24h)");

        console2.log("Pre-deployment checks passed.");
        console2.log("");
        console2.log("IMPORTANT: Verify the following before proceeding:");
        console2.log("  1. Registry is a valid Kleros Curate TCR with correct policy");
        console2.log("  2. TCR item type is tuple (address batcher, address unsafeSigner)");
        console2.log("  3. SystemConfig is the correct OP Stack contract");
        console2.log("  4. Guardian is a secure multisig (not an EOA)");
        console2.log("  5. Epoch duration is appropriate for your use case");
        console2.log("");

        vm.startBroadcast();

        KlerosSequencerManager manager = new KlerosSequencerManager(
            registry,
            systemConfig,
            epochDuration,
            guardian
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("================================================================");
        console2.log("                   DEPLOYMENT COMPLETE                          ");
        console2.log("================================================================");
        console2.log("");
        console2.log("KlerosSequencerManager:", address(manager));
        console2.log("");
        console2.log("CRITICAL NEXT STEPS:");
        console2.log("");
        console2.log("1. TRANSFER OWNERSHIP (requires current SystemConfig owner):");
        console2.log("   cast send", systemConfig);
        console2.log('     "transferOwnership(address)"', address(manager));
        console2.log("     --rpc-url $L1_RPC --private-key <owner-key>");
        console2.log("");
        console2.log("2. VERIFY CONTRACT on Etherscan:");
        console2.log("   forge verify-contract", address(manager));
        console2.log("     KlerosSequencerManager --chain mainnet");
        console2.log("");
        console2.log("3. REGISTER OPERATORS in Kleros Curate:");
        console2.log("   - Visit https://curate.kleros.io/");
        console2.log("   - Submit operator TUPLES: (batcher, unsafeSigner)");
        console2.log("   - Item data format: abi.encode(batcher, unsafeSigner)");
        console2.log("   - Wait for challenge period to pass");
        console2.log("");
        console2.log("4. SYNC OPERATORS to the manager:");
        console2.log("   cast send", address(manager));
        console2.log('     "syncAddOperator(address,address)" <batcher> <unsafeSigner>');
        console2.log("");
        console2.log("5. SET UP KEEPER for automatic rotation:");
        console2.log("   - Use Gelato, Chainlink Automation, or custom keeper");
        console2.log("   - Call rotateOperator() every", epochDuration, "seconds");
        console2.log("");
        console2.log("6. DEPLOY SELF-ACTIVATION AGENTS:");
        console2.log("   - Each operator must run a self-activation agent");
        console2.log("   - Agent watches isCurrentOperator() and starts/stops services");
        console2.log("   - See agent/ directory for reference implementation");
        console2.log("");
    }
}
