// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {PermanentGTCRHybrid, IERC20} from "../src/PermanentGTCRHybrid.sol";
import {IPermanentGTCRHybrid} from "../src/interfaces/IPermanentGTCRHybrid.sol";
import {MockSystemConfig} from "../test/mocks/MockSystemConfig.sol";
import {MockCurate} from "../test/mocks/MockCurate.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";
import {IArbitrator} from "../src/interfaces/IArbitrator.sol";

/**
 * @title DeployMainnet
 * @notice Deployment script for mainnet (or mainnet fork) using Kleros arbitration.
 *
 * This deploys:
 * - PermanentGTCRHybrid: Faithful PGTCR implementation + on-chain operational keys
 * - MockCurate: Adapter registry for gating adapter upgrades (use real Curate in production)
 * - OpStackAdapterV1: Hot-swappable adapter for OP Stack sequencer rotation
 * - MockSystemConfig (simulating OP Stack SystemConfig - replace with real in production)
 * - KlerosSequencerManager with snapshot + reverse mapping + adapter pattern
 *
 * Architecture:
 * - Uses PermanentGTCRHybrid (based on real Kleros PGTCR)
 * - Hybrid registry stores operational keys on-chain (not in IPFS)
 * - Manager uses O(1) reverse mapping for registry validation
 * - Hot-swappable adapter pattern for surviving OP Stack hardforks
 * - Full compatibility with Kleros arbitration and UI
 *
 * Real Kleros Contracts (Mainnet):
 * - KlerosCore (Court):   0x988b3a538b618c7a603e1c11ab82cd16dbe28069
 * - Court ID 4:           Blockchain (Technical)
 * - WETH:                 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
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

    /// @notice KlerosCore (arbitrator) on mainnet
    address constant KLEROS_COURT = 0x988b3A538b618C7A603e1c11Ab82Cd16dbE28069;

    /// @notice WETH on mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Blockchain (Technical) court ID
    uint96 constant COURT_ID = 4;

    /// @notice Minimum jurors for disputes
    uint256 constant MIN_JURORS = 3;

    // ============ Registry Parameters ============

    /// @notice Minimum deposit for adding an operator (0.01 ETH for testing)
    uint256 constant SUBMISSION_MIN_DEPOSIT_TEST = 0.01 ether;

    /// @notice Minimum deposit for production (0.5 ETH)
    uint256 constant SUBMISSION_MIN_DEPOSIT_PROD = 0.5 ether;

    /// @notice Challenge period for testing (5 minutes)
    uint256 constant SUBMISSION_PERIOD_TEST = 5 minutes;

    /// @notice Challenge period for production (7 days)
    uint256 constant SUBMISSION_PERIOD_PROD = 7 days;

    /// @notice Reinclusion period (same as submission)
    uint256 constant REINCLUSION_PERIOD_TEST = 5 minutes;
    uint256 constant REINCLUSION_PERIOD_PROD = 7 days;

    /// @notice Withdrawing period
    uint256 constant WITHDRAWING_PERIOD_TEST = 1 minutes;
    uint256 constant WITHDRAWING_PERIOD_PROD = 1 days;

    /// @notice Arbitration params cooldown
    uint256 constant ARBITRATION_COOLDOWN = 1 hours;

    // ============ Manager Parameters ============

    /// @notice Epoch duration for testing (1 hour)
    uint256 constant EPOCH_DURATION_TEST = 1 hours;

    /// @notice Epoch duration for production (24 hours)
    uint256 constant EPOCH_DURATION_PROD = 24 hours;

    // ============ Test Accounts (Anvil defaults) ============

    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Operator 1: batcher and unsafe signer
    address constant BATCHER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SIGNER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    // Operator 2: batcher and unsafe signer
    address constant BATCHER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant SIGNER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // Operator 3: batcher and unsafe signer
    address constant BATCHER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant SIGNER_3 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    // ============ State ============

    PermanentGTCRHybrid public registry;
    MockCurate public adapterRegistry;
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig;
    KlerosSequencerManager public manager;

    bool public isProduction;

    // Track item IDs for syncing
    bytes32 public itemID1;
    bytes32 public itemID2;
    bytes32 public itemID3;

    function run() external {
        // Check if this is production or test mode
        isProduction = vm.envOr("PRODUCTION", false);

        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        console2.log("=== Constitutional L2 - Mainnet Deployment ===");
        console2.log("Mode:", isProduction ? "PRODUCTION" : "TEST/FORK");
        console2.log("Architecture: Hybrid PGTCR + Snapshot Manager");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance / 1e18, "ETH");
        console2.log("");

        console2.log("Kleros Court:", KLEROS_COURT);
        console2.log("Court ID:", COURT_ID, "(Blockchain Technical)");
        console2.log("");

        // Create arbitrator extra data (court ID + min jurors)
        bytes memory arbitratorExtraData = abi.encode(COURT_ID, MIN_JURORS);

        // Get arbitration cost from real Kleros court
        uint256 arbitrationCost = IArbitrator(KLEROS_COURT).arbitrationCost(arbitratorExtraData);
        console2.log("Arbitration cost:", arbitrationCost / 1e15, "finney");

        // Select parameters based on mode
        uint256 submissionMinDeposit = isProduction ? SUBMISSION_MIN_DEPOSIT_PROD : SUBMISSION_MIN_DEPOSIT_TEST;
        uint256 submissionPeriod = isProduction ? SUBMISSION_PERIOD_PROD : SUBMISSION_PERIOD_TEST;
        uint256 reinclusionPeriod = isProduction ? REINCLUSION_PERIOD_PROD : REINCLUSION_PERIOD_TEST;
        uint256 withdrawingPeriod = isProduction ? WITHDRAWING_PERIOD_PROD : WITHDRAWING_PERIOD_TEST;
        uint256 epochDuration = isProduction ? EPOCH_DURATION_PROD : EPOCH_DURATION_TEST;

        console2.log("Submission deposit:", submissionMinDeposit / 1e15, "finney");
        console2.log("Submission period:", submissionPeriod / 60, "minutes");
        console2.log("Epoch duration:", epochDuration / 60, "minutes");
        console2.log("");

        // ============ Deploy PermanentGTCRHybrid ============
        console2.log("Deploying PermanentGTCRHybrid registry...");

        // Deploy with WETH address
        registry = new PermanentGTCRHybrid(WETH);

        // Stake multipliers [challenge, winner, loser, shared] in basis points (10000 = 100%)
        uint256[4] memory stakeMultipliers = [
            uint256(10000), // 100% challenge stake
            uint256(5000),  // 50% winner stake
            uint256(10000), // 100% loser stake
            uint256(5000)   // 50% shared stake
        ];

        // Initialize the registry
        registry.initialize(
            deployer,  // governor
            IArbitrator(KLEROS_COURT),
            arbitratorExtraData,
            IERC20(address(0)),  // Native ETH for deposits
            submissionMinDeposit,
            submissionPeriod,
            reinclusionPeriod,
            withdrawingPeriod,
            stakeMultipliers,
            ARBITRATION_COOLDOWN
        );

        console2.log("PermanentGTCRHybrid deployed at:", address(registry));
        console2.log("  Arbitrator:", address(registry.arbitrator()));
        console2.log("  Governor:", registry.governor());
        console2.log("  Min deposit:", registry.submissionMinDeposit() / 1e15, "finney");
        console2.log("  Submission period:", registry.submissionPeriod() / 60, "minutes");
        console2.log("");

        // ============ Deploy MockSystemConfig ============
        console2.log("Deploying MockSystemConfig (replace with real in production)...");
        systemConfig = new MockSystemConfig();
        console2.log("MockSystemConfig deployed at:", address(systemConfig));
        console2.log("");

        // ============ Deploy Adapter Registry (MockCurate) ============
        console2.log("Deploying MockCurate as Adapter Registry...");
        adapterRegistry = new MockCurate();
        console2.log("Adapter Registry deployed at:", address(adapterRegistry));
        console2.log("");

        // ============ Deploy OpStackAdapterV1 ============
        console2.log("Deploying OpStackAdapterV1...");
        adapter = new OpStackAdapterV1();
        console2.log("OpStackAdapterV1 deployed at:", address(adapter));
        console2.log("  Version:", adapter.version());
        (string memory adapterName, string memory adapterDesc) = adapter.adapterInfo();
        console2.log("  Name:", adapterName);
        console2.log("  Description:", adapterDesc);
        console2.log("");

        // Register adapter in the adapter registry
        console2.log("Registering adapter in Adapter Registry...");
        bytes memory adapterData = abi.encode(address(adapter));
        adapterRegistry.registerItemDirectly(adapterData);
        bytes32 adapterItemID = keccak256(abi.encodePacked(adapterData));
        console2.log("  Adapter registered with itemID:");
        console2.logBytes32(adapterItemID);
        console2.log("");

        // ============ Deploy KlerosSequencerManager ============
        console2.log("Deploying KlerosSequencerManager...");
        manager = new KlerosSequencerManager(
            address(registry),
            address(systemConfig),
            address(adapterRegistry),
            address(adapter),
            epochDuration,
            GUARDIAN
        );
        console2.log("KlerosSequencerManager deployed at:", address(manager));
        console2.log("  Operator Registry:", address(registry));
        console2.log("  SystemConfig:", address(systemConfig));
        console2.log("  Adapter Registry:", address(adapterRegistry));
        console2.log("  Initial Adapter:", address(adapter));
        console2.log("  Epoch Duration:", epochDuration / 60, "minutes");
        console2.log("  Guardian:", GUARDIAN);
        console2.log("");

        // Transfer SystemConfig ownership to manager
        systemConfig.transferOwnership(address(manager));
        console2.log("SystemConfig ownership transferred to manager");
        console2.log("");

        // Stop initial deployment broadcast
        vm.stopBroadcast();

        // In test/fork mode, register operators directly
        if (!isProduction) {
            console2.log("=== Test Mode: Registering operators ===");
            // Pass private key to manage broadcast lifecycle around vm.warp
            _registerTestOperators(deployerPrivateKey);
        } else {
            console2.log("=== Production Mode ===");
            console2.log("Operators must be submitted through the registry.");
            console2.log("1. Call registry.addItemWithKeys(data, batcher, signer) with deposit");
            console2.log("2. Wait for submission period");
            console2.log("3. Call registry.executeRequest(itemID)");
            console2.log("4. Call manager.syncAddOperator(itemID)");
        }

        // Output deployment summary
        _printSummary();
    }

    function _registerTestOperators(uint256 deployerPrivateKey) internal {
        uint256 deposit = registry.submissionMinDeposit();
        uint256 submissionPeriodDuration = registry.submissionPeriod();

        console2.log("Registering 3 test operators...");

        // 1. Register Operators
        vm.startBroadcast(deployerPrivateKey);
        itemID1 = _addOperatorToRegistry("operator1", BATCHER_1, SIGNER_1, deposit);
        itemID2 = _addOperatorToRegistry("operator2", BATCHER_2, SIGNER_2, deposit);
        itemID3 = _addOperatorToRegistry("operator3", BATCHER_3, SIGNER_3, deposit);
        vm.stopBroadcast();

        // 2. Time Travel using Anvil RPC (vm.warp only affects Foundry VM, not Anvil)
        // We use evm_increaseTime and evm_mine to actually advance time on the Anvil node
        console2.log("Fast-forwarding past submission period...");
        _advanceTimeOnNode(submissionPeriodDuration + 1);

        // 3. Execute Requests
        vm.startBroadcast(deployerPrivateKey);
        _executeRequest(itemID1, BATCHER_1);
        _executeRequest(itemID2, BATCHER_2);
        _executeRequest(itemID3, BATCHER_3);
        vm.stopBroadcast();

        // 4. Time Travel past reinclusion period
        uint256 reinclusionPeriodDuration = registry.reinclusionPeriod();
        console2.log("Fast-forwarding past reinclusion period...");
        _advanceTimeOnNode(reinclusionPeriodDuration + 1);

        // 5. Sync & Rotate
        vm.startBroadcast(deployerPrivateKey);
        console2.log("Syncing operators to manager...");
        manager.syncAddOperator(itemID1);
        manager.syncAddOperator(itemID2);
        manager.syncAddOperator(itemID3);

        console2.log("Performing first rotation...");
        manager.rotateOperator();

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("Current operator batcher:", current.batcher);

        // Final stop
        vm.stopBroadcast();
    }

    /**
     * @notice Advances time on the connected node (Anvil) using RPC calls.
     * @dev vm.warp() only affects Foundry's internal VM state, not the actual node.
     *      When using --broadcast, we need to use Anvil's evm_increaseTime and evm_mine
     *      RPC methods to actually advance the block timestamp on the node.
     * @param _seconds The number of seconds to advance time.
     */
    function _advanceTimeOnNode(uint256 _seconds) internal {
        // Call Anvil's evm_increaseTime RPC method
        string memory increaseTimeParams = string.concat("[", vm.toString(_seconds), "]");
        vm.rpc("evm_increaseTime", increaseTimeParams);

        // Mine a block to apply the time change
        vm.rpc("evm_mine", "[]");

        // Also update Foundry's VM state to keep them in sync
        vm.warp(block.timestamp + _seconds);
        vm.roll(block.number + 1);

        console2.log("  Advanced time by", _seconds, "seconds");
    }

    function _addOperatorToRegistry(
        string memory name,
        address batcher,
        address unsafeSigner,
        uint256 deposit
    ) internal returns (bytes32 itemID) {
        // Item data is just a label (for UI display), keys are stored separately
        string memory itemData = name;

        // Add item with explicit operational keys
        itemID = registry.addItemWithKeys{value: deposit}(itemData, batcher, unsafeSigner);

        console2.log("  Added operator:", name, "itemID:");
        console2.logBytes32(itemID);

        return itemID;
    }

    function _executeRequest(bytes32 itemID, address batcher) internal {
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
        console2.log("Architecture: Hybrid PGTCR + Snapshot Manager");
        console2.log("Based on: https://github.com/kleros/pgtcr");
        console2.log("");
        console2.log("Kleros Contracts (Mainnet):");
        console2.log("  Kleros Court:        ", KLEROS_COURT);
        console2.log("  Court ID:             4 (Blockchain Technical)");
        console2.log("");
        console2.log("Deployed Contracts:");
        console2.log("  Operator Registry:   ", address(registry));
        console2.log("  Adapter Registry:    ", address(adapterRegistry));
        console2.log("  OpStackAdapterV1:    ", address(adapter));
        console2.log("  MockSystemConfig:    ", address(systemConfig));
        console2.log("  SequencerManager:    ", address(manager));
        console2.log("");
        console2.log("Key Features:");
        console2.log("  - Full PGTCR logic (appeal funding, withdrawals, etc.)");
        console2.log("  - On-chain operational keys (no IPFS lookup)");
        console2.log("  - O(1) reverse mapping for validation");
        console2.log("  - Cold Staker / Hot Operator support");
        console2.log("  - Hot-swappable adapter pattern for hardfork survival");
        console2.log("  - Ratchet versioning for adapter upgrades");
        console2.log("  - ERC20 token support (currently using native ETH)");
        console2.log("");
        console2.log("Commands:");
        console2.log("  # Check current operator");
        console2.log("  cast call", address(manager), "'currentOperator()'");
        console2.log("");
        console2.log("  # Rotate operator (after epoch)");
        console2.log("  cast send", address(manager), "'rotateOperator()'");
        console2.log("");
        console2.log("  # Add new operator (by item ID)");
        console2.log("  cast send", address(manager), "'syncAddOperator(bytes32)' <itemID>");
        console2.log("");
        console2.log("  # Update operator keys (after owner changes in registry)");
        console2.log("  cast send", address(manager), "'syncUpdateOperator(bytes32)' <itemID>");
        console2.log("");
        console2.log("Registry Parameters:");
        console2.log("  Min deposit:         ", registry.submissionMinDeposit() / 1e15, "finney");
        console2.log("  Submission period:   ", registry.submissionPeriod() / 60, "minutes");
        console2.log("  Reinclusion period:  ", registry.reinclusionPeriod() / 60, "minutes");
        console2.log("  Withdrawing period:  ", registry.withdrawingPeriod() / 60, "minutes");
        console2.log("");
        if (!isProduction) {
            console2.log("TEST MODE: Operators pre-registered and synced.");
            console2.log("Run './start.sh demo' to see rotation in action.");
        }
        console2.log("===========================================");
    }
}
