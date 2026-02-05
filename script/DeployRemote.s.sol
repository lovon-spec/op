// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {ProposerRegistry} from "../src/ProposerRegistry.sol";
import {ChainRegistry} from "../src/ChainRegistry.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockArbitrator} from "../test/mocks/MockArbitrator.sol";
import {OpStackAdapterV1} from "../src/poc/opstack/OpStackAdapterV1.sol";
import {IArbitrator} from "../src/interfaces/IArbitrator.sol";
import {TestConstants} from "./TestConstants.sol";

/**
 * @title DeployRemote
 * @notice Deployment script for Sepolia or Mainnet using ISOCHRON architecture.
 *
 * This deploys the complete ISOCHRON Hub-and-Spoke architecture:
 * - ProposerRegistry (DPoS proposer management)
 * - ChainRegistry (GeneralizedTCR for chain onboarding with a configurable arbitrator)
 * - SharedSequencerHub (Central hub for atomic multichain rotation)
 * - OpStackAdapterV1 (OP Stack rotation adapter)
 *
 * Required environment variables:
 *   ARBITRATOR_ADDRESS   - Address of the arbitrator (default Kleros Court)
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
    uint256 constant ARBITRATION_COST_TEST = 0.05 ether;

    // Defaults for production mode
    uint256 constant SUBMISSION_DEPOSIT_PROD = 0.5 ether;
    uint256 constant CHALLENGE_PERIOD_PROD = 7 days;
    uint256 constant EPOCH_DURATION_PROD = 24 hours;
    uint256 constant GRACE_PERIOD_PROD = 1 hours;
    uint256 constant MIN_PROPOSER_STAKE_PROD = 32 ether;

    // ============ State ============

    ProposerRegistry public proposerRegistry;
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
            TestConstants.DEPLOYER_KEY
        );

        address guardian = vm.envOr("GUARDIAN", isProduction ? address(0) : TestConstants.GUARDIAN);

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

        // ============ Log configuration ============
        console2.log("=== ISOCHRON Remote Deployment ===");
        console2.log("Mode:", isProduction ? "PRODUCTION" : "TEST");
        console2.log("Architecture: Hub-and-Spoke with arbitrator governance (default Kleros Court)");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance / 1e18, "ETH");
        console2.log("");

        // ============ Deploy or use existing arbitrator ============
        IArbitrator arbitrator;
        if (isProduction) {
            address arbitratorAddress = vm.envAddress("ARBITRATOR_ADDRESS");
            arbitrator = IArbitrator(arbitratorAddress);
            console2.log("Using arbitrator:", arbitratorAddress);
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
            epochDuration,
            gracePeriod
        );
        console2.log("SharedSequencerHub deployed at:", address(hub));

        // ============ Set hub in registries ============
        proposerRegistry.setHub(address(hub));
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
        console2.log("       ISOCHRON DEPLOYMENT SUMMARY");
        console2.log("===========================================");
        console2.log("");
        console2.log("Architecture: Hub-and-Spoke shared sequencer");
        console2.log("");
        console2.log("Deployed Contracts:");
        console2.log("  SharedSequencerHub:  ", address(hub));
        console2.log("  ProposerRegistry:    ", address(proposerRegistry));
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
        console2.log("  - GeneralizedTCR chain onboarding with arbitrator (default Kleros Court)");
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
        console2.log("===========================================");
    }
}
