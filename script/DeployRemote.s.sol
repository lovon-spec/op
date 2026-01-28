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
 * @title DeployRemote
 * @notice Deployment script for Sepolia or Mainnet using Kleros arbitration.
 *
 * All network-specific addresses are read from environment variables,
 * making this a single script that works for both Sepolia and Mainnet.
 *
 * This deploys:
 * - PermanentGTCRHybrid: Faithful PGTCR implementation + on-chain operational keys
 * - MockCurate: Adapter registry for gating adapter upgrades (use real Curate in production)
 * - OpStackAdapterV1: Hot-swappable adapter for OP Stack sequencer rotation
 * - MockSystemConfig (simulating OP Stack SystemConfig - replace with real in production)
 * - KlerosSequencerManager with snapshot + reverse mapping + adapter pattern
 *
 * Required environment variables:
 *   KLEROS_COURT   - Address of KlerosCore arbitrator
 *   WETH           - Address of WETH (deposit token)
 *
 * Optional environment variables (with defaults):
 *   COURT_ID                - Court ID (default: 4, Blockchain Technical)
 *   MIN_JURORS              - Minimum jurors for disputes (default: 3)
 *   SUBMISSION_DEPOSIT      - Submission deposit in wei (default: test=0.01 ETH, prod=0.5 ETH)
 *   SUBMISSION_PERIOD       - Challenge period in seconds (default: test=300, prod=604800)
 *   REINCLUSION_PERIOD      - Reinclusion period in seconds (default: test=300, prod=604800)
 *   WITHDRAWING_PERIOD      - Withdrawing period in seconds (default: test=60, prod=86400)
 *   EPOCH_DURATION          - Epoch duration in seconds (default: test=3600, prod=86400)
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
    // ============ Default Parameters (used when env vars not set) ============

    // Defaults for test mode
    uint256 constant SUBMISSION_MIN_DEPOSIT_TEST = 0.01 ether;
    uint256 constant SUBMISSION_PERIOD_TEST = 5 minutes;
    uint256 constant REINCLUSION_PERIOD_TEST = 5 minutes;
    uint256 constant WITHDRAWING_PERIOD_TEST = 1 minutes;
    uint256 constant EPOCH_DURATION_TEST = 1 hours;
    uint256 constant ARBITRATION_COOLDOWN = 1 hours;

    // Defaults for production mode
    uint256 constant SUBMISSION_MIN_DEPOSIT_PROD = 0.5 ether;
    uint256 constant SUBMISSION_PERIOD_PROD = 7 days;
    uint256 constant REINCLUSION_PERIOD_PROD = 7 days;
    uint256 constant WITHDRAWING_PERIOD_PROD = 1 days;
    uint256 constant EPOCH_DURATION_PROD = 24 hours;

    // ============ Test Accounts (Anvil defaults, only used in test mode) ============

    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    address constant BATCHER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SIGNER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    address constant BATCHER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant SIGNER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    address constant BATCHER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant SIGNER_3 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    address constant DEFAULT_GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    // ============ State ============

    PermanentGTCRHybrid public registry;
    MockCurate public adapterRegistry;
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig;
    KlerosSequencerManager public manager;

    bool public isProduction;

    bytes32 public itemID1;
    bytes32 public itemID2;
    bytes32 public itemID3;

    function run() external {
        // ============ Read configuration from environment ============
        address klerosCourt = vm.envAddress("KLEROS_COURT");
        address weth = vm.envAddress("WETH");

        uint96 courtId = uint96(vm.envOr("COURT_ID", uint256(4)));
        uint256 minJurors = vm.envOr("MIN_JURORS", uint256(3));

        isProduction = vm.envOr("PRODUCTION", false);

        address guardian = vm.envOr("GUARDIAN", isProduction ? address(0) : DEFAULT_GUARDIAN);

        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        // Select parameters based on mode, with env var overrides
        uint256 submissionMinDeposit = vm.envOr(
            "SUBMISSION_DEPOSIT",
            isProduction ? SUBMISSION_MIN_DEPOSIT_PROD : SUBMISSION_MIN_DEPOSIT_TEST
        );
        uint256 submissionPeriod = vm.envOr(
            "SUBMISSION_PERIOD",
            isProduction ? SUBMISSION_PERIOD_PROD : SUBMISSION_PERIOD_TEST
        );
        uint256 reinclusionPeriod = vm.envOr(
            "REINCLUSION_PERIOD",
            isProduction ? REINCLUSION_PERIOD_PROD : REINCLUSION_PERIOD_TEST
        );
        uint256 withdrawingPeriod = vm.envOr(
            "WITHDRAWING_PERIOD",
            isProduction ? WITHDRAWING_PERIOD_PROD : WITHDRAWING_PERIOD_TEST
        );
        uint256 epochDuration = vm.envOr(
            "EPOCH_DURATION",
            isProduction ? EPOCH_DURATION_PROD : EPOCH_DURATION_TEST
        );

        // ============ Log configuration ============
        console2.log("=== Constitutional L2 - Remote Deployment ===");
        console2.log("Mode:", isProduction ? "PRODUCTION" : "TEST");
        console2.log("Architecture: Hybrid PGTCR + Snapshot Manager");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance / 1e18, "ETH");
        console2.log("");

        console2.log("Kleros Court:", klerosCourt);
        console2.log("WETH:", weth);
        console2.log("Court ID:", courtId);
        console2.log("");

        // Create arbitrator extra data (court ID + min jurors)
        bytes memory arbitratorExtraData = abi.encode(courtId, minJurors);

        // Get arbitration cost from Kleros court
        uint256 arbitrationCost = IArbitrator(klerosCourt).arbitrationCost(arbitratorExtraData);
        console2.log("Arbitration cost:", arbitrationCost / 1e15, "finney");

        console2.log("Submission deposit:", submissionMinDeposit / 1e15, "finney");
        console2.log("Submission period:", submissionPeriod / 60, "minutes");
        console2.log("Epoch duration:", epochDuration / 60, "minutes");
        console2.log("");

        // ============ Deploy PermanentGTCRHybrid ============
        console2.log("Deploying PermanentGTCRHybrid registry...");

        registry = new PermanentGTCRHybrid(weth);

        uint256[4] memory stakeMultipliers = [
            uint256(10000), // 100% challenge stake
            uint256(5000),  // 50% winner stake
            uint256(10000), // 100% loser stake
            uint256(5000)   // 50% shared stake
        ];

        registry.initialize(
            deployer,
            IArbitrator(klerosCourt),
            arbitratorExtraData,
            IERC20(address(0)),
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
            guardian
        );
        console2.log("KlerosSequencerManager deployed at:", address(manager));
        console2.log("  Operator Registry:", address(registry));
        console2.log("  SystemConfig:", address(systemConfig));
        console2.log("  Adapter Registry:", address(adapterRegistry));
        console2.log("  Initial Adapter:", address(adapter));
        console2.log("  Epoch Duration:", epochDuration / 60, "minutes");
        console2.log("  Guardian:", guardian);
        console2.log("");

        // Transfer SystemConfig ownership to manager
        systemConfig.transferOwnership(address(manager));
        console2.log("SystemConfig ownership transferred to manager");
        console2.log("");

        vm.stopBroadcast();

        // In test mode, register operators (Phase 1 only)
        // Time advancement and Phase 2 (execute/sync) must be done via shell commands
        if (!isProduction) {
            console2.log("=== Test Mode: Registering operators (Phase 1) ===");
            _registerTestOperatorsPhase1(deployerPrivateKey);
        } else {
            console2.log("=== Production Mode ===");
            console2.log("Operators must be submitted through the registry.");
            console2.log("1. Call registry.addItemWithKeys(data, batcher, signer) with deposit");
            console2.log("2. Wait for submission period");
            console2.log("3. Call registry.executeRequest(itemID)");
            console2.log("4. Call manager.syncAddOperator(itemID)");
        }

        _printSummary(klerosCourt, courtId);
    }

    function _registerTestOperatorsPhase1(uint256 deployerPrivateKey) internal {
        uint256 deposit = registry.submissionMinDeposit();

        console2.log("Registering 3 test operators...");

        vm.startBroadcast(deployerPrivateKey);
        itemID1 = _addOperatorToRegistry("operator1", BATCHER_1, SIGNER_1, deposit);
        itemID2 = _addOperatorToRegistry("operator2", BATCHER_2, SIGNER_2, deposit);
        itemID3 = _addOperatorToRegistry("operator3", BATCHER_3, SIGNER_3, deposit);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Phase 1 Complete ===");
        console2.log("Item IDs registered (save these for Phase 2):");
        console2.log("  ITEM_ID_1:");
        console2.logBytes32(itemID1);
        console2.log("  ITEM_ID_2:");
        console2.logBytes32(itemID2);
        console2.log("  ITEM_ID_3:");
        console2.logBytes32(itemID3);
        console2.log("");
        console2.log("Next steps (handled by shell script):");
        console2.log("  1. Advance time past submission period (300s)");
        console2.log("  2. Execute requests for each item");
        console2.log("  3. Advance time past reinclusion period (300s)");
        console2.log("  4. Sync operators and rotate");
    }

    /**
     * @notice Phase 2: Execute requests, sync operators, and rotate.
     * @dev Called after shell script advances time on Anvil.
     */
    function runPhase2() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        address registryAddr = vm.envAddress("REGISTRY_ADDRESS");
        address managerAddr = vm.envAddress("MANAGER_ADDRESS");

        bytes32 id1 = vm.envBytes32("ITEM_ID_1");
        bytes32 id2 = vm.envBytes32("ITEM_ID_2");
        bytes32 id3 = vm.envBytes32("ITEM_ID_3");

        registry = PermanentGTCRHybrid(payable(registryAddr));
        manager = KlerosSequencerManager(managerAddr);

        console2.log("=== Phase 2: Execute, Sync, and Rotate ===");

        vm.startBroadcast(deployerPrivateKey);

        console2.log("Executing requests...");
        _executeRequest(id1, BATCHER_1);
        _executeRequest(id2, BATCHER_2);
        _executeRequest(id3, BATCHER_3);

        vm.stopBroadcast();

        console2.log("Phase 2a complete. Now advance time past reinclusion period.");
    }

    /**
     * @notice Phase 3: Sync operators and rotate after reinclusion period.
     */
    function runPhase3() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        address managerAddr = vm.envAddress("MANAGER_ADDRESS");

        bytes32 id1 = vm.envBytes32("ITEM_ID_1");
        bytes32 id2 = vm.envBytes32("ITEM_ID_2");
        bytes32 id3 = vm.envBytes32("ITEM_ID_3");

        manager = KlerosSequencerManager(managerAddr);

        console2.log("=== Phase 3: Sync and Rotate ===");

        vm.startBroadcast(deployerPrivateKey);

        console2.log("Syncing operators to manager...");
        manager.syncAddOperator(id1);
        manager.syncAddOperator(id2);
        manager.syncAddOperator(id3);

        console2.log("Performing first rotation...");
        manager.rotateOperator();

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("Current operator batcher:", current.batcher);

        vm.stopBroadcast();

        console2.log("=== All phases complete! ===");
    }

    function _addOperatorToRegistry(
        string memory name,
        address batcher,
        address unsafeSigner,
        uint256 deposit
    ) internal returns (bytes32 itemID) {
        string memory itemData = name;
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

    function _printSummary(address klerosCourt, uint96 courtId) internal view {
        console2.log("");
        console2.log("===========================================");
        console2.log("       DEPLOYMENT SUMMARY");
        console2.log("===========================================");
        console2.log("");
        console2.log("Architecture: Hybrid PGTCR + Snapshot Manager");
        console2.log("Based on: https://github.com/kleros/pgtcr");
        console2.log("");
        console2.log("Kleros Contracts:");
        console2.log("  Kleros Court:        ", klerosCourt);
        console2.log("  Court ID:            ", courtId);
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
            console2.log("TEST MODE: Operators pre-registered.");
            console2.log("Run Phase 2/3 shell commands to activate operators.");
        }
        console2.log("===========================================");
    }
}
