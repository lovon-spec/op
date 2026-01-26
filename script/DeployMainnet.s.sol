// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {IPermanentGTCRFactory, IPermanentGTCR, IArbitrator, IERC20} from "../src/interfaces/IPermanentGTCRFactory.sol";

/**
 * @title DeployMainnet
 * @notice Deployment script for mainnet (or mainnet fork) using real Kleros contracts.
 *
 * This deploys:
 * - Creates a new PermanentGTCR via Kleros factory for operator curation
 * - MockSystemConfig (simulating OP Stack SystemConfig - replace with real in production)
 * - KlerosSequencerManager pointing to the real Kleros registry
 *
 * Real Kleros Contracts (Mainnet):
 * - PermanentGTCRFactory: 0x69816B499b0eD9a60ac52cF2beB24827E5F13A89
 * - KlerosCore (Court):   0x988b3a538b618c7a603e1c11ab82cd16dbe28069
 * - Court ID 4:           Blockchain (Technical)
 *
 * Usage:
 *   # Fork mode (local testing)
 *   anvil --fork-url https://mainnet.infura.io/v3/YOUR_KEY &
 *   forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url http://127.0.0.1:8545 --broadcast
 *
 *   # Production mode
 *   PRODUCTION=true forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url https://mainnet.infura.io/v3/YOUR_KEY \
 *     --private-key $DEPLOYER_KEY \
 *     --broadcast --verify
 */
contract DeployMainnet is Script {
    // ============ Kleros Mainnet Contracts ============

    /// @notice PermanentGTCRFactory on mainnet
    address constant KLEROS_GTCR_FACTORY = 0x69816B499b0eD9a60ac52cF2beB24827E5F13A89;

    /// @notice KlerosCore (arbitrator) on mainnet
    address constant KLEROS_COURT = 0x988b3a538b618c7a603e1c11ab82cd16dbe28069;

    /// @notice Blockchain (Technical) court ID
    uint96 constant COURT_ID = 4;

    /// @notice Minimum jurors for disputes
    uint256 constant MIN_JURORS = 3;

    // ============ Registry Parameters ============

    // For testing/demo - use lower values
    // For production - increase these significantly

    /// @notice Minimum deposit for adding an operator (0.01 ETH for testing)
    uint256 constant SUBMISSION_MIN_DEPOSIT_TEST = 0.01 ether;

    /// @notice Minimum deposit for production (0.5 ETH)
    uint256 constant SUBMISSION_MIN_DEPOSIT_PROD = 0.5 ether;

    /// @notice Challenge period for testing (5 minutes)
    uint256 constant CHALLENGE_PERIOD_TEST = 5 minutes;

    /// @notice Challenge period for production (7 days)
    uint256 constant CHALLENGE_PERIOD_PROD = 7 days;

    // ============ Manager Parameters ============

    /// @notice Epoch duration for testing (1 hour)
    uint256 constant EPOCH_DURATION_TEST = 1 hours;

    /// @notice Epoch duration for production (24 hours)
    uint256 constant EPOCH_DURATION_PROD = 24 hours;

    // ============ Test Accounts (Anvil defaults) ============

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

    // ============ State ============

    IPermanentGTCRFactory public factory;
    IPermanentGTCR public registry;
    MockSystemConfig public systemConfig;
    KlerosSequencerManager public manager;

    bool public isProduction;

    function run() external {
        // Check if this is production or test mode
        isProduction = vm.envOr("PRODUCTION", false);

        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        console2.log("=== Constitutional L2 - Mainnet Deployment ===");
        console2.log("Mode:", isProduction ? "PRODUCTION" : "TEST/FORK");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance / 1e18, "ETH");
        console2.log("");

        // Get the factory
        factory = IPermanentGTCRFactory(KLEROS_GTCR_FACTORY);
        console2.log("Kleros GTCR Factory:", address(factory));
        console2.log("Kleros Court:", KLEROS_COURT);
        console2.log("Court ID:", COURT_ID, "(Blockchain Technical)");
        console2.log("");

        // Create arbitrator extra data (court ID + min jurors)
        bytes memory arbitratorExtraData = abi.encode(COURT_ID, MIN_JURORS);

        // Get arbitration cost
        uint256 arbitrationCost = IArbitrator(KLEROS_COURT).arbitrationCost(arbitratorExtraData);
        console2.log("Arbitration cost:", arbitrationCost / 1e15, "finney");

        // Select parameters based on mode
        uint256 submissionMinDeposit = isProduction ? SUBMISSION_MIN_DEPOSIT_PROD : SUBMISSION_MIN_DEPOSIT_TEST;
        uint256 challengePeriod = isProduction ? CHALLENGE_PERIOD_PROD : CHALLENGE_PERIOD_TEST;
        uint256 epochDuration = isProduction ? EPOCH_DURATION_PROD : EPOCH_DURATION_TEST;

        console2.log("Submission deposit:", submissionMinDeposit / 1e15, "finney");
        console2.log("Challenge period:", challengePeriod / 60, "minutes");
        console2.log("Epoch duration:", epochDuration / 60, "minutes");
        console2.log("");

        // Deploy the operator registry via Kleros factory
        console2.log("Creating PermanentGTCR for operator curation...");

        // Periods: [validity, safety, withdrawal, paramEnforcement]
        uint256[4] memory periods = [
            challengePeriod,  // validity period (challenge window)
            1 hours,          // safety period
            1 hours,          // withdrawal period
            1 hours           // parameter enforcement period
        ];

        // Stake multipliers in basis points (10000 = 100%)
        // [shared, winner, loser, challenge]
        uint256[4] memory stakeMultipliers = [
            uint256(5000),  // 50% shared stake
            uint256(5000),  // 50% winner stake
            uint256(10000), // 100% loser stake
            uint256(10000)  // 100% challenge stake
        ];

        // Meta evidence URI (empty for testing, should be IPFS URI for production)
        string memory metaEvidence = isProduction
            ? "ipfs://QmTODO_UPLOAD_META_EVIDENCE"  // TODO: Upload proper meta evidence
            : "/ipfs/QmTest";  // Placeholder for testing

        address registryAddress = factory.deploy(
            IArbitrator(KLEROS_COURT),
            arbitratorExtraData,
            metaEvidence,
            deployer,  // governor
            IERC20(address(0)),  // Native ETH for stakes
            submissionMinDeposit,
            periods,
            stakeMultipliers
        );

        registry = IPermanentGTCR(registryAddress);
        console2.log("PermanentGTCR deployed at:", registryAddress);
        console2.log("  Arbitrator:", registry.arbitrator());
        console2.log("  Governor:", registry.governor());
        console2.log("  Min deposit:", registry.submissionMinDeposit() / 1e15, "finney");
        console2.log("");

        // Deploy MockSystemConfig (replace with real SystemConfig address in production)
        console2.log("Deploying MockSystemConfig (replace with real in production)...");
        systemConfig = new MockSystemConfig();
        console2.log("MockSystemConfig deployed at:", address(systemConfig));
        console2.log("");

        // Deploy KlerosSequencerManager
        console2.log("Deploying KlerosSequencerManager...");
        manager = new KlerosSequencerManager(
            address(registry),
            address(systemConfig),
            epochDuration,
            GUARDIAN
        );
        console2.log("KlerosSequencerManager deployed at:", address(manager));
        console2.log("  Registry:", address(registry));
        console2.log("  SystemConfig:", address(systemConfig));
        console2.log("  Epoch Duration:", epochDuration / 60, "minutes");
        console2.log("  Guardian:", GUARDIAN);
        console2.log("");

        // Transfer SystemConfig ownership to manager
        systemConfig.transferOwnership(address(manager));
        console2.log("SystemConfig ownership transferred to manager");
        console2.log("");

        // In test/fork mode, register operators directly (bypassing challenge period)
        if (!isProduction) {
            console2.log("=== Test Mode: Registering operators (fast-forward) ===");
            _registerTestOperators();
        } else {
            console2.log("=== Production Mode ===");
            console2.log("Operators must be submitted through the Curate interface.");
            console2.log("After challenge period, call syncAddOperator() to add them to the manager.");
        }

        vm.stopBroadcast();

        // Output deployment summary
        _printSummary();
    }

    function _registerTestOperators() internal {
        // In fork mode, we can simulate the registration process
        // by adding items and fast-forwarding time

        uint256 deposit = registry.submissionMinDeposit();
        uint256 challengePeriod = registry.challengePeriodDuration();

        console2.log("Registering 3 test operators...");
        console2.log("Deposit per operator:", deposit / 1e15, "finney");

        // Add operators to the registry
        // The item data is the ABI-encoded operator tuple
        _addOperatorToRegistry(BATCHER_1, SIGNER_1, deposit);
        _addOperatorToRegistry(BATCHER_2, SIGNER_2, deposit);
        _addOperatorToRegistry(BATCHER_3, SIGNER_3, deposit);

        // Fast-forward time past challenge period (only works in fork/test mode)
        console2.log("Fast-forwarding past challenge period...");
        vm.warp(block.timestamp + challengePeriod + 1);

        // Execute requests to finalize registration
        _executeRequest(BATCHER_1, SIGNER_1);
        _executeRequest(BATCHER_2, SIGNER_2);
        _executeRequest(BATCHER_3, SIGNER_3);

        // Sync operators to manager
        console2.log("Syncing operators to manager...");
        manager.syncAddOperator(BATCHER_1, SIGNER_1);
        manager.syncAddOperator(BATCHER_2, SIGNER_2);
        manager.syncAddOperator(BATCHER_3, SIGNER_3);

        console2.log("Operators synced:");
        console2.log("  Operator 1: batcher=", BATCHER_1);
        console2.log("  Operator 2: batcher=", BATCHER_2);
        console2.log("  Operator 3: batcher=", BATCHER_3);

        // Perform first rotation
        console2.log("");
        console2.log("Performing first rotation...");
        manager.rotateOperator();

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("Current operator:");
        console2.log("  Batcher:", current.batcher);
        console2.log("  Unsafe signer:", current.unsafeSigner);
    }

    function _addOperatorToRegistry(address batcher, address unsafeSigner, uint256 deposit) internal {
        // Encode operator tuple as string (PermanentGTCR uses string for item data)
        string memory itemData = string(abi.encode(batcher, unsafeSigner));

        // Add item to registry
        registry.addItem{value: deposit}(itemData, deposit);

        console2.log("  Added operator: batcher=", batcher);
    }

    function _executeRequest(address batcher, address unsafeSigner) internal {
        // Compute item ID
        bytes32 itemID = keccak256(abi.encodePacked(abi.encode(batcher, unsafeSigner)));

        // Execute the request
        try registry.executeRequest(itemID) {
            console2.log("  Executed request for:", batcher);
        } catch {
            console2.log("  Request execution skipped (may already be executed)");
        }
    }

    function _printSummary() internal view {
        console2.log("");
        console2.log("===========================================");
        console2.log("       DEPLOYMENT SUMMARY");
        console2.log("===========================================");
        console2.log("");
        console2.log("Kleros Contracts (Mainnet):");
        console2.log("  GTCR Factory:        ", KLEROS_GTCR_FACTORY);
        console2.log("  Kleros Court:        ", KLEROS_COURT);
        console2.log("  Court ID:             4 (Blockchain Technical)");
        console2.log("");
        console2.log("Deployed Contracts:");
        console2.log("  Operator Registry:   ", address(registry));
        console2.log("  MockSystemConfig:    ", address(systemConfig));
        console2.log("  SequencerManager:    ", address(manager));
        console2.log("");
        console2.log("Commands:");
        console2.log("  # Check current operator");
        console2.log("  cast call", address(manager), "'currentOperator()'");
        console2.log("");
        console2.log("  # Rotate operator (after epoch)");
        console2.log("  cast send", address(manager), "'rotateOperator()'");
        console2.log("");
        console2.log("  # Add new operator (must be registered in Curate first)");
        console2.log("  cast send", address(manager), "'syncAddOperator(address,address)' <batcher> <signer>");
        console2.log("");
        console2.log("Registry Parameters:");
        console2.log("  Min deposit:         ", registry.submissionMinDeposit() / 1e15, "finney");
        console2.log("  Challenge period:    ", registry.challengePeriodDuration() / 60, "minutes");
        console2.log("");
        if (!isProduction) {
            console2.log("TEST MODE: Operators pre-registered and synced.");
            console2.log("Run './start.sh mainnet-demo' to see rotation in action.");
        }
        console2.log("===========================================");
    }
}
