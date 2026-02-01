// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {ProposerRegistry} from "../src/ProposerRegistry.sol";
import {BuilderRegistry} from "../src/BuilderRegistry.sol";
import {ChainRegistry} from "../src/ChainRegistry.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockArbitrator} from "../test/mocks/MockArbitrator.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";
import {IArbitrator} from "../src/interfaces/IArbitrator.sol";

/**
 * @title DeployRemote
 * @notice Deployment script for Sepolia or Mainnet using KSSN architecture.
 *
 * This deploys the complete KSSN Hub-and-Spoke architecture:
 * - ProposerRegistry (DPoS proposer management)
 * - BuilderRegistry (Policy-based builder management)
 * - ChainRegistry (GeneralizedTCR for chain onboarding with Kleros)
 * - SharedSequencerHub (Central hub for atomic multichain rotation)
 * - OpStackAdapterV1 (OP Stack rotation adapter)
 *
 * Required environment variables:
 *   KLEROS_COURT   - Address of KlerosCore arbitrator (or use MockArbitrator for testing)
 *
 * Optional environment variables (with defaults):
 *   SUBMISSION_DEPOSIT      - Required deposit for chain registration (default: 0.1 ETH)
 *   CHALLENGE_PERIOD        - Challenge period in seconds (default: 300 for test, 604800 for prod)
 *   EPOCH_DURATION          - Epoch duration in seconds (default: 3600 for test, 86400 for prod)
 *   PRODUCTION              - Set to "true" for production parameters (default: false)
 *
 * Usage:
 *   # Sepolia
 *   source .env.sepolia
 *   forge script script/DeployRemote.s.sol:DeployRemote --rpc-url $RPC_URL --broadcast
 *
 *   # Mainnet
 *   source .env.mainnet
 *   PRODUCTION=true forge script script/DeployRemote.s.sol:DeployRemote \
 *     --rpc-url $RPC_URL --private-key $DEPLOYER_KEY --broadcast --verify
 */
contract DeployRemote is Script {
    // ============ Default Parameters ============

    // Defaults for test mode
    uint256 constant SUBMISSION_DEPOSIT_TEST = 0.1 ether;
    uint256 constant CHALLENGE_PERIOD_TEST = 5 minutes;
    uint256 constant EPOCH_DURATION_TEST = 1 hours;
    uint256 constant GRACE_PERIOD_TEST = 5 minutes;
    uint256 constant MIN_PROPOSER_STAKE_TEST = 1 ether;
    uint256 constant MIN_BUILDER_BOND_TEST = 1 ether;
    uint256 constant ARBITRATION_COST_TEST = 0.05 ether;

    // Defaults for production mode
    uint256 constant SUBMISSION_DEPOSIT_PROD = 0.5 ether;
    uint256 constant CHALLENGE_PERIOD_PROD = 7 days;
    uint256 constant EPOCH_DURATION_PROD = 24 hours;
    uint256 constant GRACE_PERIOD_PROD = 1 hours;
    uint256 constant MIN_PROPOSER_STAKE_PROD = 32 ether;
    uint256 constant MIN_BUILDER_BOND_PROD = 500 ether;

    // ============ Test Accounts (Anvil defaults, only used in test mode) ============

    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    address constant PROPOSER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant PROPOSER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant PROPOSER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    address constant BUILDER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address constant BUILDER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // ============ State ============

    ProposerRegistry public proposerRegistry;
    BuilderRegistry public builderRegistry;
    ChainRegistry public chainRegistry;
    SharedSequencerHub public hub;
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig;

    bool public isProduction;

    function run() external {
        // ============ Read configuration from environment ============
        isProduction = vm.envOr("PRODUCTION", false);

        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        address guardian = vm.envOr("GUARDIAN", isProduction ? address(0) : GUARDIAN);

        // Select parameters based on mode
        uint256 epochDuration = vm.envOr(
            "EPOCH_DURATION",
            isProduction ? EPOCH_DURATION_PROD : EPOCH_DURATION_TEST
        );
        uint256 gracePeriod = vm.envOr(
            "GRACE_PERIOD",
            isProduction ? GRACE_PERIOD_PROD : GRACE_PERIOD_TEST
        );
        uint256 submissionDeposit = vm.envOr(
            "SUBMISSION_DEPOSIT",
            isProduction ? SUBMISSION_DEPOSIT_PROD : SUBMISSION_DEPOSIT_TEST
        );
        uint256 challengePeriod = vm.envOr(
            "CHALLENGE_PERIOD",
            isProduction ? CHALLENGE_PERIOD_PROD : CHALLENGE_PERIOD_TEST
        );
        uint256 minProposerStake = vm.envOr(
            "MIN_PROPOSER_STAKE",
            isProduction ? MIN_PROPOSER_STAKE_PROD : MIN_PROPOSER_STAKE_TEST
        );
        uint256 minBuilderBond = vm.envOr(
            "MIN_BUILDER_BOND",
            isProduction ? MIN_BUILDER_BOND_PROD : MIN_BUILDER_BOND_TEST
        );

        // ============ Log configuration ============
        console2.log("=== KSSN Remote Deployment ===");
        console2.log("Mode:", isProduction ? "PRODUCTION" : "TEST");
        console2.log("Architecture: Hub-and-Spoke with Kleros Governance");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance / 1e18, "ETH");
        console2.log("");

        // ============ Deploy or use existing arbitrator ============
        IArbitrator arbitrator;
        if (isProduction) {
            address klerosCourt = vm.envAddress("KLEROS_COURT");
            arbitrator = IArbitrator(klerosCourt);
            console2.log("Using Kleros Court:", klerosCourt);
        } else {
            MockArbitrator mockArbitrator = new MockArbitrator(ARBITRATION_COST_TEST);
            arbitrator = IArbitrator(address(mockArbitrator));
            console2.log("MockArbitrator deployed at:", address(mockArbitrator));
        }

        // ============ Deploy ProposerRegistry ============
        console2.log("\nDeploying ProposerRegistry...");
        proposerRegistry = new ProposerRegistry(
            deployer,           // governance
            address(0),         // hub (set later)
            minProposerStake,
            100                 // max active set size
        );
        console2.log("ProposerRegistry deployed at:", address(proposerRegistry));

        // ============ Deploy BuilderRegistry ============
        console2.log("Deploying BuilderRegistry...");
        builderRegistry = new BuilderRegistry(
            deployer,           // governance
            address(0),         // hub (set later)
            minBuilderBond
        );
        console2.log("BuilderRegistry deployed at:", address(builderRegistry));

        // ============ Deploy ChainRegistry ============
        console2.log("Deploying ChainRegistry...");
        uint256[3] memory multipliers = [uint256(10000), uint256(10000), uint256(10000)];
        chainRegistry = new ChainRegistry(
            deployer,           // governor
            arbitrator,
            "",                 // registrationMetaEvidence
            submissionDeposit,
            challengePeriod,
            multipliers
        );
        console2.log("ChainRegistry deployed at:", address(chainRegistry));

        // ============ Deploy SharedSequencerHub ============
        console2.log("Deploying SharedSequencerHub...");
        hub = new SharedSequencerHub(
            deployer,           // governance
            guardian,
            address(proposerRegistry),
            address(builderRegistry),
            epochDuration,
            gracePeriod
        );
        console2.log("SharedSequencerHub deployed at:", address(hub));

        // ============ Set hub in registries ============
        proposerRegistry.setHub(address(hub));
        builderRegistry.setHub(address(hub));
        console2.log("Hub address set in registries");

        // ============ Deploy OpStackAdapterV1 ============
        console2.log("Deploying OpStackAdapterV1...");
        adapter = new OpStackAdapterV1();
        console2.log("OpStackAdapterV1 deployed at:", address(adapter));

        // ============ Deploy MockSystemConfig (for testing) ============
        if (!isProduction) {
            console2.log("Deploying MockSystemConfig...");
            systemConfig = new MockSystemConfig();
            systemConfig.transferOwnership(address(hub));
            console2.log("MockSystemConfig deployed at:", address(systemConfig));
        }

        vm.stopBroadcast();

        // ============ Print Summary ============
        _printSummary(
            address(arbitrator),
            epochDuration,
            submissionDeposit,
            challengePeriod
        );
    }

    function _printSummary(
        address arbitrator,
        uint256 epochDuration,
        uint256 submissionDeposit,
        uint256 challengePeriod
    ) internal view {
        console2.log("");
        console2.log("===========================================");
        console2.log("       KSSN DEPLOYMENT SUMMARY");
        console2.log("===========================================");
        console2.log("");
        console2.log("Architecture: Hub-and-Spoke with PBS");
        console2.log("");
        console2.log("Deployed Contracts:");
        console2.log("  SharedSequencerHub:  ", address(hub));
        console2.log("  ProposerRegistry:    ", address(proposerRegistry));
        console2.log("  BuilderRegistry:     ", address(builderRegistry));
        console2.log("  ChainRegistry:       ", address(chainRegistry));
        console2.log("  OpStackAdapterV1:    ", address(adapter));
        console2.log("  Arbitrator:          ", arbitrator);
        if (!isProduction) {
            console2.log("  MockSystemConfig:    ", address(systemConfig));
        }
        console2.log("");
        console2.log("Parameters:");
        console2.log("  Epoch duration:      ", epochDuration / 60, "minutes");
        console2.log("  Submission deposit:  ", submissionDeposit / 1e15, "finney");
        console2.log("  Challenge period:    ", challengePeriod / 60, "minutes");
        console2.log("");
        console2.log("Key Features:");
        console2.log("  - Hub-and-Spoke atomic multichain rotation");
        console2.log("  - Top-N DPoS proposer selection");
        console2.log("  - Policy-based builder eligibility (Sovereignty Matrix)");
        console2.log("  - GeneralizedTCR chain onboarding with Kleros");
        console2.log("  - Hot-swappable adapters for different chain types");
        console2.log("");
        console2.log("Commands:");
        console2.log("  # Rotate network (after epoch)");
        console2.log("  cast send", address(hub), "'rotateNetwork()'");
        console2.log("");
        console2.log("  # Check current proposer");
        console2.log("  cast call", address(hub), "'currentProposer()'");
        console2.log("");
        console2.log("  # Register as proposer");
        console2.log("  cast send", address(proposerRegistry), "'register(address)' <operationalKey> --value 32ether");
        console2.log("");
        console2.log("  # Register as builder");
        console2.log("  cast send", address(builderRegistry), "'register()' --value 500ether");
        console2.log("===========================================");
    }
}
