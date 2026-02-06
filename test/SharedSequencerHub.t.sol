// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {ISharedSequencerHub} from "../src/interfaces/ISharedSequencerHub.sol";
import {MockSequencerAdapter} from "./mocks/MockSequencerAdapter.sol";
import {MockProposerRegistry} from "./mocks/MockProposerRegistry.sol";
import {MockRollupConfig} from "./mocks/MockRollupConfig.sol";
import {MockChainRegistry} from "./mocks/MockChainRegistry.sol";

/**
 * @title SharedSequencerHubTest
 * @notice Tests for the SharedSequencerHub contract.
 * @dev Tests atomic rotation, chain management, and governance functions.
 */
contract SharedSequencerHubTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public guardian = address(0x2);
    address public proposer1 = address(0x10);
    address public proposer2 = address(0x11);
    address public proposer3 = address(0x12);
    address public randomUser = address(0x99);

    // ============ Contracts ============
    SharedSequencerHub public hub;
    MockProposerRegistry public proposerRegistry;
    MockSequencerAdapter public adapter;

    // Multiple chain configs for testing
    MockRollupConfig public rollupConfig1;
    MockRollupConfig public rollupConfig2;
    MockRollupConfig public rollupConfig3;

    uint256 public constant CHAIN_ID_1 = 10001;
    uint256 public constant CHAIN_ID_2 = 10002;
    uint256 public constant CHAIN_ID_3 = 10003;

    // ============ Setup ============

    function setUp() public {
        // Deploy registries
        proposerRegistry = new MockProposerRegistry();

        // Deploy adapter
        adapter = new MockSequencerAdapter();

        // Deploy hub
        hub = new SharedSequencerHub(
            governance,
            guardian,
            address(proposerRegistry),
            1 hours, // epoch duration
            600 // grace period
        );

        // Deploy system configs
        rollupConfig1 = new MockRollupConfig();
        rollupConfig2 = new MockRollupConfig();
        rollupConfig3 = new MockRollupConfig();

        // Transfer ownership of system configs to hub
        rollupConfig1.transferOwnership(address(hub));
        rollupConfig2.transferOwnership(address(hub));
        rollupConfig3.transferOwnership(address(hub));

        // Add proposers to registry
        proposerRegistry.addProposer(proposer1, 32 ether);
        proposerRegistry.addProposer(proposer2, 32 ether);
        proposerRegistry.addProposer(proposer3, 32 ether);

        vm.prank(proposer1);
        proposerRegistry.setAdapterData(address(adapter), abi.encode(proposer1));
        vm.prank(proposer2);
        proposerRegistry.setAdapterData(address(adapter), abi.encode(proposer2));
        vm.prank(proposer3);
        proposerRegistry.setAdapterData(address(adapter), abi.encode(proposer3));

        // Connect chains as governance
        vm.startPrank(governance);
        hub.connectChain(CHAIN_ID_1, address(rollupConfig1), address(adapter));
        hub.connectChain(CHAIN_ID_2, address(rollupConfig2), address(adapter));
        hub.connectChain(CHAIN_ID_3, address(rollupConfig3), address(adapter));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialValues() public view {
        assertEq(hub.governance(), governance);
        assertEq(hub.guardian(), guardian);
        assertEq(hub.proposerRegistry(), address(proposerRegistry));
        assertEq(hub.epochDuration(), 1 hours);
        assertEq(hub.gracePeriod(), 600);
        assertEq(hub.currentEpoch(), 0);
        assertEq(hub.currentProposer(), address(0));
        assertFalse(hub.isPaused());
    }

    function test_Constructor_UsesDefaultsWhenZero() public {
        SharedSequencerHub hubWithDefaults = new SharedSequencerHub(
            governance,
            guardian,
            address(proposerRegistry),
            0, // should use default
            0  // should use default
        );

        assertEq(hubWithDefaults.epochDuration(), 1 hours);
        assertEq(hubWithDefaults.gracePeriod(), 600);
    }

    // ============ Chain Management Tests ============

    function test_ConnectChain_Success() public {
        uint256 newChainId = 10004;
        MockRollupConfig newConfig = new MockRollupConfig();
        newConfig.transferOwnership(address(hub));

        vm.prank(governance);
        hub.connectChain(newChainId, address(newConfig), address(adapter));

        assertEq(hub.getChainCount(), 4);

        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(newChainId);
        assertEq(config.rollupConfig, address(newConfig));
        assertEq(config.adapter, address(adapter));
        assertTrue(config.isActive);
        assertEq(config.chainId, newChainId);
    }

    function test_ConnectChain_RevertsIfNotGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert(ISharedSequencerHub.NotGovernance.selector);
        hub.connectChain(10004, address(0x123), address(adapter));
    }

    function test_ConnectChain_RevertsIfChainExists() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ISharedSequencerHub.ChainAlreadyExists.selector, CHAIN_ID_1));
        hub.connectChain(CHAIN_ID_1, address(0x123), address(adapter));
    }

    function test_ConnectChain_RevertsIfInvalidRollupConfig() public {
        vm.prank(governance);
        vm.expectRevert(ISharedSequencerHub.InvalidRollupConfig.selector);
        hub.connectChain(10004, address(0), address(adapter));
    }

    function test_ConnectChain_RevertsIfInvalidAdapter() public {
        vm.prank(governance);
        vm.expectRevert(ISharedSequencerHub.InvalidAdapter.selector);
        hub.connectChain(10004, address(0x123), address(0));
    }

    function test_DisconnectChain_Success() public {
        vm.prank(governance);
        hub.disconnectChain(CHAIN_ID_2);

        assertEq(hub.getChainCount(), 2);

        vm.expectRevert(abi.encodeWithSelector(ISharedSequencerHub.ChainNotFound.selector, CHAIN_ID_2));
        hub.getChainConfig(CHAIN_ID_2);
    }

    function test_DisconnectChain_RevertsIfNotGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert(ISharedSequencerHub.NotGovernance.selector);
        hub.disconnectChain(CHAIN_ID_1);
    }

    function test_UpdateChainConfig_Success() public {
        MockSequencerAdapter newAdapter = new MockSequencerAdapter();

        vm.prank(governance);
        hub.updateChainConfig(CHAIN_ID_1, address(newAdapter));

        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(CHAIN_ID_1);
        assertEq(config.adapter, address(newAdapter));
    }

    function test_SetChainActiveStatus_Success() public {
        vm.prank(governance);
        hub.setChainActiveStatus(CHAIN_ID_1, false);

        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(CHAIN_ID_1);
        assertFalse(config.isActive);
    }

    // ============ Rotation Tests ============

    function test_RotateNetwork_Success() public {
        // Fast forward past epoch duration
        vm.warp(block.timestamp + 1 hours + 1);

        // Anyone can call rotation after epoch ends
        hub.rotateNetwork();

        // For epoch 1: selectNextProposer(1) returns proposers[1 % 3] = proposer2
        assertEq(hub.currentProposer(), proposer2);
        assertEq(hub.currentEpoch(), 1);

        // Verify all chains were updated to proposer2
        assertEq(rollupConfig1.sequencer(), proposer2);
        assertEq(rollupConfig2.sequencer(), proposer2);
        assertEq(rollupConfig3.sequencer(), proposer2);
    }

    function test_RotateNetwork_RevertsBeforeEpochEnd() public {
        vm.expectRevert(ISharedSequencerHub.InvalidRotationWindow.selector);
        hub.rotateNetwork();
    }

    function test_RotateNetwork_RevertsWhenPaused() public {
        vm.prank(guardian);
        hub.pause();

        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectRevert(ISharedSequencerHub.ContractPaused.selector);
        hub.rotateNetwork();
    }

    function test_RotateNetwork_MultipleRotations() public {
        uint256 epochDuration = 1 hours;
        uint256 startTime = block.timestamp;

        // First rotation - epoch 1: proposers[1 % 3] = proposer2
        vm.warp(startTime + epochDuration + 1);
        hub.rotateNetwork();
        assertEq(hub.currentProposer(), proposer2);
        assertEq(hub.currentEpoch(), 1);

        // Second rotation - epoch 2: proposers[2 % 3] = proposer3
        vm.warp(startTime + 2 * epochDuration + 1);
        hub.rotateNetwork();
        assertEq(hub.currentProposer(), proposer3);
        assertEq(hub.currentEpoch(), 2);

        // Third rotation - epoch 3: proposers[3 % 3] = proposer1
        vm.warp(startTime + 3 * epochDuration + 1);
        hub.rotateNetwork();
        assertEq(hub.currentProposer(), proposer1);
        assertEq(hub.currentEpoch(), 3);
    }

    function test_RotateNetwork_WithInactiveChain() public {
        // Deactivate chain 2
        vm.prank(governance);
        hub.setChainActiveStatus(CHAIN_ID_2, false);

        vm.warp(block.timestamp + 1 hours + 1);
        hub.rotateNetwork();

        // Chain 1 and 3 should be updated to proposer2 (epoch 1), chain 2 should not
        assertEq(rollupConfig1.sequencer(), proposer2);
        assertEq(rollupConfig2.sequencer(), address(0)); // Not updated
        assertEq(rollupConfig3.sequencer(), proposer2);
    }

    // ============ Sharded Rotation Tests ============

    function test_RotateShard_SingleShard() public {
        vm.warp(block.timestamp + 1 hours + 1);

        // With only 3 chains, there's only 1 shard
        hub.rotateShard(0);

        // Epoch 1: proposer2 (index 1 % 3 = 1)
        assertEq(hub.currentProposer(), proposer2);
        assertEq(hub.currentEpoch(), 1);
    }

    function test_GetShardCount_ReturnsCorrectCount() public view {
        // With 3 chains and MAX_CHAINS_PER_SHARD = 200, should be 1 shard
        assertEq(hub.getShardCount(), 1);
    }

    // ============ View Function Tests ============

    function test_TimeUntilNextRotation_ReturnsCorrectValue() public view {
        uint256 remaining = hub.timeUntilNextRotation();
        assertEq(remaining, 1 hours);
    }

    function test_TimeUntilNextRotation_ReturnsZeroAfterEpoch() public {
        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(hub.timeUntilNextRotation(), 0);
    }

    function test_IsRotationWindowOpen_ReturnsFalseBeforeEpochEnd() public view {
        assertFalse(hub.isRotationWindowOpen());
    }

    function test_IsRotationWindowOpen_ReturnsTrueDuringGracePeriod() public {
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(hub.isRotationWindowOpen());
    }

    function test_IsRotationWindowOpen_ReturnsFalseAfterGracePeriod() public {
        vm.warp(block.timestamp + 1 hours + 601);
        assertFalse(hub.isRotationWindowOpen());
    }

    function test_GetAllChainConfigs_ReturnsAllChains() public view {
        ISharedSequencerHub.ChainConfig[] memory configs = hub.getAllChainConfigs();
        assertEq(configs.length, 3);
    }

    function test_GetActiveChainCount_ReturnsCorrectCount() public {
        assertEq(hub.getActiveChainCount(), 3);

        vm.prank(governance);
        hub.setChainActiveStatus(CHAIN_ID_1, false);

        assertEq(hub.getActiveChainCount(), 2);
    }

    function test_IsCurrentProposer_ReturnsTrueForCurrentProposer() public {
        vm.warp(block.timestamp + 1 hours + 1);
        hub.rotateNetwork();

        // For epoch 1: proposer2 is selected (index 1 % 3 = 1)
        assertTrue(hub.isCurrentProposer(proposer2));
        assertFalse(hub.isCurrentProposer(proposer1));
    }

    function test_GetEpochEndTime_ReturnsCorrectTime() public view {
        uint256 epochEnd = hub.getEpochEndTime();
        assertEq(epochEnd, block.timestamp + 1 hours);
    }

    function test_IsInGracePeriod_ReturnsTrueInGracePeriod() public {
        assertFalse(hub.isInGracePeriod());

        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(hub.isInGracePeriod());

        vm.warp(block.timestamp + 600);
        assertFalse(hub.isInGracePeriod());
    }

    function test_IsForcedRotationAllowed_ReturnsTrueAfterGracePeriod() public {
        assertFalse(hub.isForcedRotationAllowed());

        vm.warp(block.timestamp + 1 hours + 1);
        assertFalse(hub.isForcedRotationAllowed());

        vm.warp(block.timestamp + 600);
        assertTrue(hub.isForcedRotationAllowed());
    }

    // ============ Registry Management Tests ============

    function test_SetProposerRegistry_Success() public {
        address newRegistry = address(0x999);

        vm.prank(governance);
        hub.setProposerRegistry(newRegistry);

        assertEq(hub.proposerRegistry(), newRegistry);
    }

    function test_SetEpochDuration_Success() public {
        vm.prank(governance);
        hub.setEpochDuration(2 hours);

        assertEq(hub.epochDuration(), 2 hours);
    }

    // ============ Guardian Functions Tests ============

    function test_Pause_Success() public {
        vm.prank(guardian);
        hub.pause();

        assertTrue(hub.isPaused());
    }

    function test_Unpause_Success() public {
        vm.prank(guardian);
        hub.pause();

        vm.prank(guardian);
        hub.unpause();

        assertFalse(hub.isPaused());
    }

    function test_Pause_RevertsIfNotGuardian() public {
        vm.prank(randomUser);
        vm.expectRevert(ISharedSequencerHub.NotGuardian.selector);
        hub.pause();
    }

    function test_Pause_GovernanceCanAlsoPause() public {
        vm.prank(governance);
        hub.pause();

        assertTrue(hub.isPaused());
    }

    function test_EmergencyRotate_Success() public {
        address emergencyProposer = address(0x777);

        vm.prank(emergencyProposer);
        proposerRegistry.setAdapterData(address(adapter), abi.encode(emergencyProposer));

        vm.prank(guardian);
        hub.emergencyRotate(emergencyProposer);

        assertEq(hub.currentProposer(), emergencyProposer);
        assertEq(rollupConfig1.sequencer(), emergencyProposer);
    }

    function test_EmergencyRotate_RevertsIfNotGuardian() public {
        vm.prank(randomUser);
        vm.expectRevert(ISharedSequencerHub.NotGuardian.selector);
        hub.emergencyRotate(address(0x777));
    }

    // ============ Governance Management Tests ============

    function test_SetGovernance_Success() public {
        address newGovernance = address(0x888);

        vm.prank(governance);
        hub.setGovernance(newGovernance);

        assertEq(hub.governance(), newGovernance);
    }

    function test_SetGuardian_Success() public {
        address newGuardian = address(0x888);

        vm.prank(governance);
        hub.setGuardian(newGuardian);

        assertEq(hub.guardian(), newGuardian);
    }

    function test_SetGracePeriod_Success() public {
        vm.prank(governance);
        hub.setGracePeriod(1200);

        assertEq(hub.gracePeriod(), 1200);
    }

    // ============ Edge Case Tests ============

    function test_RotateNetwork_HandlesFailedChainGracefully() public {
        // Create a system config that will fail (not owned by hub)
        MockRollupConfig failingConfig = new MockRollupConfig();
        // Don't transfer ownership - this will cause rotation to fail for this chain

        vm.prank(governance);
        hub.connectChain(10004, address(failingConfig), address(adapter));

        vm.warp(block.timestamp + 1 hours + 1);

        // Should not revert, but failing chain should be deactivated
        hub.rotateNetwork();

        // Successful chains should be updated - epoch 1 selects proposer2
        assertEq(hub.currentProposer(), proposer2);

        // Failing chain should be deactivated
        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(10004);
        assertFalse(config.isActive);
    }

    function test_GetChainConfigByIndex_Success() public view {
        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfigByIndex(0);
        assertEq(config.chainId, CHAIN_ID_1);
    }

    function test_GetChainConfigByIndex_RevertsIfOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(ISharedSequencerHub.ChainNotFound.selector, 99));
        hub.getChainConfigByIndex(99);
    }

    // ============ Chain Registry Integration Tests ============

    function test_SetChainRegistry_Success() public {
        MockChainRegistry registry = new MockChainRegistry();

        vm.prank(governance);
        hub.setChainRegistry(address(registry));

        assertEq(hub.chainRegistry(), address(registry));
    }

    function test_SetChainRegistry_RevertsIfNotGovernance() public {
        MockChainRegistry registry = new MockChainRegistry();

        vm.prank(randomUser);
        vm.expectRevert(ISharedSequencerHub.NotGovernance.selector);
        hub.setChainRegistry(address(registry));
    }

    function test_ConnectChainFromRegistry_Success() public {
        // Setup chain registry
        MockChainRegistry registry = new MockChainRegistry();
        MockRollupConfig newConfig = new MockRollupConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 20001;

        // Register chain directly in mock registry
        registry.registerChainDirectly(
            newChainId,
            address(newConfig),
            address(adapter),
            "Test Chain"
        );

        // Set registry and connect
        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));
        hub.connectChainFromRegistry(newChainId);
        vm.stopPrank();

        // Verify chain was connected
        assertEq(hub.getChainCount(), 4); // 3 original + 1 new

        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(newChainId);
        assertEq(config.rollupConfig, address(newConfig));
        assertEq(config.adapter, address(adapter));
        assertTrue(config.isActive);
    }

    function test_ConnectChainFromRegistry_RevertsIfNotRegistered() public {
        MockChainRegistry registry = new MockChainRegistry();

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));

        vm.expectRevert(abi.encodeWithSelector(ISharedSequencerHub.ChainNotFound.selector, 99999));
        hub.connectChainFromRegistry(99999);
        vm.stopPrank();
    }

    function test_ConnectChainFromRegistry_RevertsIfNoRegistry() public {
        vm.prank(governance);
        vm.expectRevert(ISharedSequencerHub.InvalidRollupConfig.selector);
        hub.connectChainFromRegistry(20001);
    }

    function test_ConnectChainFromRegistry_RevertsIfAlreadyConnected() public {
        MockChainRegistry registry = new MockChainRegistry();
        MockRollupConfig newConfig = new MockRollupConfig();

        registry.registerChainDirectly(
            CHAIN_ID_1, // Already connected
            address(newConfig),
            address(adapter),
            "Test Chain"
        );

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));

        vm.expectRevert(abi.encodeWithSelector(ISharedSequencerHub.ChainAlreadyExists.selector, CHAIN_ID_1));
        hub.connectChainFromRegistry(CHAIN_ID_1);
        vm.stopPrank();
    }

    function test_BatchConnectChainsFromRegistry_Success() public {
        MockChainRegistry registry = new MockChainRegistry();

        // Create and register multiple new chains
        MockRollupConfig config1 = new MockRollupConfig();
        MockRollupConfig config2 = new MockRollupConfig();
        MockRollupConfig config3 = new MockRollupConfig();

        config1.transferOwnership(address(hub));
        config2.transferOwnership(address(hub));
        config3.transferOwnership(address(hub));

        uint256 chainId1 = 30001;
        uint256 chainId2 = 30002;
        uint256 chainId3 = 30003;

        registry.registerChainDirectly(chainId1, address(config1), address(adapter), "Chain 1");
        registry.registerChainDirectly(chainId2, address(config2), address(adapter), "Chain 2");
        registry.registerChainDirectly(chainId3, address(config3), address(adapter), "Chain 3");

        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = chainId1;
        chainIds[1] = chainId2;
        chainIds[2] = chainId3;

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));
        hub.batchConnectChainsFromRegistry(chainIds);
        vm.stopPrank();

        assertEq(hub.getChainCount(), 6); // 3 original + 3 new
    }

    function test_BatchConnectChainsFromRegistry_SkipsAlreadyConnected() public {
        MockChainRegistry registry = new MockChainRegistry();

        MockRollupConfig newConfig = new MockRollupConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 40001;

        // Register both an existing chain and a new one
        registry.registerChainDirectly(CHAIN_ID_1, address(rollupConfig1), address(adapter), "Existing");
        registry.registerChainDirectly(newChainId, address(newConfig), address(adapter), "New");

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = CHAIN_ID_1; // Already connected - should skip
        chainIds[1] = newChainId;  // New - should connect

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));
        hub.batchConnectChainsFromRegistry(chainIds);
        vm.stopPrank();

        assertEq(hub.getChainCount(), 4); // 3 original + 1 new (skipped duplicate)
    }

    function test_SyncChainFromRegistry_Success() public {
        MockChainRegistry registry = new MockChainRegistry();

        // First connect a chain
        MockRollupConfig newConfig = new MockRollupConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 50001;

        registry.registerChainDirectly(
            newChainId,
            address(newConfig),
            address(adapter),
            "Test Chain"
        );

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));
        hub.connectChainFromRegistry(newChainId);
        vm.stopPrank();

        // For testing, we'll just verify the sync function works

        vm.prank(governance);
        hub.syncChainFromRegistry(newChainId);

        // Verify the chain config exists (sync completed without revert)
        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(newChainId);
        assertEq(config.chainId, newChainId);
    }

    function test_SyncChainFromRegistry_RevertsIfNotConnected() public {
        MockChainRegistry registry = new MockChainRegistry();

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));

        vm.expectRevert(abi.encodeWithSelector(ISharedSequencerHub.ChainNotFound.selector, 99999));
        hub.syncChainFromRegistry(99999);
        vm.stopPrank();
    }

    function test_RotateNetwork_WithRegistryConnectedChains() public {
        // Setup chain registry and connect a new chain
        MockChainRegistry registry = new MockChainRegistry();
        MockRollupConfig newConfig = new MockRollupConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 60001;

        registry.registerChainDirectly(
            newChainId,
            address(newConfig),
            address(adapter),
            "Registry Chain"
        );

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));
        hub.connectChainFromRegistry(newChainId);
        vm.stopPrank();

        // Fast forward and rotate
        vm.warp(block.timestamp + 1 hours + 1);
        hub.rotateNetwork();

        // Verify all chains including the registry-connected one were updated
        // Epoch 1 selects proposer2 (index 1 % 3 = 1)
        assertEq(newConfig.sequencer(), proposer2);
    }

    // ============ Liveness Reporting Tests ============

    function test_RotateNetwork_ReportsLivenessForOutgoingProposer() public {
        // Epoch 1: warp past epoch + grace period so anyone can rotate
        // epochStartTime starts at block.timestamp (~1), epochDuration = 3600, grace = 600
        // Epoch end = 1 + 3600 = 3601, grace end = 4201, so warp to 4202
        vm.warp(4202);
        hub.rotateNetwork();
        assertEq(hub.currentProposer(), proposer2);
        // After rotation: epochStartTime = 4202, epoch = 1

        // Epoch 2: epochEndTime = 4202 + 3600 = 7802, grace end = 7802 + 600 = 8402
        vm.warp(8403);
        hub.rotateNetwork();

        // Verify liveness was reported for the outgoing proposer (proposer2)
        assertEq(proposerRegistry.lastLivenessProposer(), proposer2);
        assertEq(proposerRegistry.lastLivenessEpoch(), 1);
        // First rotation: currentProposer was address(0) -> skip. Second rotation: report for proposer2
        assertEq(proposerRegistry.livenessReportCount(), 1);
    }

    function test_RotateNetwork_FullLivenessWhenWithinGracePeriod() public {
        // First rotation: warp past epoch + grace
        vm.warp(4202);
        hub.rotateNetwork();
        // After rotation: epochStartTime = 4202, currentProposer = proposer2

        // Second rotation: within grace period
        // Epoch end = 4202 + 3600 = 7802
        // Grace period [7802, 7802+600=8402]
        // Warp to 8102 (5 min into grace period)
        vm.warp(8102);
        vm.prank(proposer2); // proposer2 is currentProposer
        hub.rotateNetwork();

        // Within grace period = full liveness credit
        assertEq(proposerRegistry.lastLivenessBlocksProduced(), proposerRegistry.lastLivenessBlocksExpected());
    }

    function test_RotateNetwork_PenalizedLivenessWhenForcedRotation() public {
        // First rotation: warp past epoch + grace
        vm.warp(4202);
        hub.rotateNetwork();
        // After rotation: epochStartTime = 4202

        // Forced rotation: well past grace period
        // Epoch end = 4202 + 3600 = 7802, grace end = 8402
        // Warp to 8402 + 1800 = 10202 (1800s past grace)
        vm.warp(10202);
        hub.rotateNetwork();

        // Liveness should be penalized proportionally
        uint256 produced = proposerRegistry.lastLivenessBlocksProduced();
        uint256 expected = proposerRegistry.lastLivenessBlocksExpected();
        assertEq(expected, 3600); // epochDuration
        assertTrue(produced < expected);
    }

    function test_RotateNetwork_NoLivenessReportWhenNoCurrentProposer() public {
        // First rotation - no prior proposer (currentProposer = address(0))
        assertEq(hub.currentProposer(), address(0));

        vm.warp(4202);
        hub.rotateNetwork();

        // _reportOutgoingProposerLiveness skips when currentProposer == address(0)
        assertEq(proposerRegistry.livenessReportCount(), 0);
    }

    function test_RotateShard_ReportsLiveness() public {
        // First rotation via shard
        vm.warp(4202);
        hub.rotateShard(0);
        assertEq(hub.currentProposer(), proposer2);
        // After rotation: epochStartTime = 4202

        // Second rotation via shard (past grace period)
        // Epoch end = 4202 + 3600 = 7802, grace end = 8402
        vm.warp(8403);
        hub.rotateShard(0);

        // Verify liveness was reported for outgoing proposer
        assertEq(proposerRegistry.lastLivenessProposer(), proposer2);
        // First rotation: address(0) -> skip. Second: report for proposer2
        assertEq(proposerRegistry.livenessReportCount(), 1);
    }
}
