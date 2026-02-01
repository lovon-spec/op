// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SharedSequencerHub} from "../src/SharedSequencerHub.sol";
import {ISharedSequencerHub} from "../src/interfaces/ISharedSequencerHub.sol";
import {IChainRegistry} from "../src/interfaces/IChainRegistry.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";
import {MockProposerRegistry} from "./mocks/MockProposerRegistry.sol";
import {MockBuilderRegistry} from "./mocks/MockBuilderRegistry.sol";
import {MockSystemConfig} from "./mocks/MockSystemConfig.sol";
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
    MockBuilderRegistry public builderRegistry;
    OpStackAdapterV1 public adapter;

    // Multiple chain configs for testing
    MockSystemConfig public systemConfig1;
    MockSystemConfig public systemConfig2;
    MockSystemConfig public systemConfig3;

    uint256 public constant CHAIN_ID_1 = 10001;
    uint256 public constant CHAIN_ID_2 = 10002;
    uint256 public constant CHAIN_ID_3 = 10003;

    // ============ Setup ============

    function setUp() public {
        // Deploy registries
        proposerRegistry = new MockProposerRegistry();
        builderRegistry = new MockBuilderRegistry();

        // Deploy adapter
        adapter = new OpStackAdapterV1();

        // Deploy hub
        hub = new SharedSequencerHub(
            governance,
            guardian,
            address(proposerRegistry),
            address(builderRegistry),
            1 hours, // epoch duration
            600 // grace period
        );

        // Deploy system configs
        systemConfig1 = new MockSystemConfig();
        systemConfig2 = new MockSystemConfig();
        systemConfig3 = new MockSystemConfig();

        // Transfer ownership of system configs to hub
        systemConfig1.transferOwnership(address(hub));
        systemConfig2.transferOwnership(address(hub));
        systemConfig3.transferOwnership(address(hub));

        // Add proposers to registry
        proposerRegistry.addProposer(proposer1, 32 ether);
        proposerRegistry.addProposer(proposer2, 32 ether);
        proposerRegistry.addProposer(proposer3, 32 ether);

        // Connect chains as governance
        vm.startPrank(governance);
        hub.connectChain(CHAIN_ID_1, address(systemConfig1), bytes32(0), address(adapter));
        hub.connectChain(CHAIN_ID_2, address(systemConfig2), bytes32(0), address(adapter));
        hub.connectChain(CHAIN_ID_3, address(systemConfig3), bytes32(0), address(adapter));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialValues() public view {
        assertEq(hub.governance(), governance);
        assertEq(hub.guardian(), guardian);
        assertEq(hub.proposerRegistry(), address(proposerRegistry));
        assertEq(hub.builderRegistry(), address(builderRegistry));
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
            address(builderRegistry),
            0, // should use default
            0  // should use default
        );

        assertEq(hubWithDefaults.epochDuration(), 1 hours);
        assertEq(hubWithDefaults.gracePeriod(), 600);
    }

    // ============ Chain Management Tests ============

    function test_ConnectChain_Success() public {
        uint256 newChainId = 10004;
        MockSystemConfig newConfig = new MockSystemConfig();
        newConfig.transferOwnership(address(hub));

        vm.prank(governance);
        hub.connectChain(newChainId, address(newConfig), keccak256("POLICY_OFAC"), address(adapter));

        assertEq(hub.getChainCount(), 4);

        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(newChainId);
        assertEq(config.systemConfig, address(newConfig));
        assertEq(config.policyId, keccak256("POLICY_OFAC"));
        assertEq(config.adapter, address(adapter));
        assertTrue(config.isActive);
        assertEq(config.chainId, newChainId);
    }

    function test_ConnectChain_RevertsIfNotGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert(ISharedSequencerHub.NotGovernance.selector);
        hub.connectChain(10004, address(0x123), bytes32(0), address(adapter));
    }

    function test_ConnectChain_RevertsIfChainExists() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ISharedSequencerHub.ChainAlreadyExists.selector, CHAIN_ID_1));
        hub.connectChain(CHAIN_ID_1, address(0x123), bytes32(0), address(adapter));
    }

    function test_ConnectChain_RevertsIfInvalidSystemConfig() public {
        vm.prank(governance);
        vm.expectRevert(ISharedSequencerHub.InvalidSystemConfig.selector);
        hub.connectChain(10004, address(0), bytes32(0), address(adapter));
    }

    function test_ConnectChain_RevertsIfInvalidAdapter() public {
        vm.prank(governance);
        vm.expectRevert(ISharedSequencerHub.InvalidAdapter.selector);
        hub.connectChain(10004, address(0x123), bytes32(0), address(0));
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
        bytes32 newPolicyId = keccak256("NEW_POLICY");
        OpStackAdapterV1 newAdapter = new OpStackAdapterV1();

        vm.prank(governance);
        hub.updateChainConfig(CHAIN_ID_1, newPolicyId, address(newAdapter));

        ISharedSequencerHub.ChainConfig memory config = hub.getChainConfig(CHAIN_ID_1);
        assertEq(config.policyId, newPolicyId);
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

        assertEq(hub.currentProposer(), proposer1);
        assertEq(hub.currentEpoch(), 1);

        // Verify all chains were updated
        assertEq(systemConfig1.batcherHash(), bytes32(uint256(uint160(proposer1))));
        assertEq(systemConfig1.unsafeBlockSigner(), proposer1);
        assertEq(systemConfig2.batcherHash(), bytes32(uint256(uint160(proposer1))));
        assertEq(systemConfig2.unsafeBlockSigner(), proposer1);
        assertEq(systemConfig3.batcherHash(), bytes32(uint256(uint160(proposer1))));
        assertEq(systemConfig3.unsafeBlockSigner(), proposer1);
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
        // First rotation
        vm.warp(block.timestamp + 1 hours + 1);
        hub.rotateNetwork();
        assertEq(hub.currentProposer(), proposer1);
        assertEq(hub.currentEpoch(), 1);

        // Second rotation
        vm.warp(block.timestamp + 1 hours + 1);
        hub.rotateNetwork();
        assertEq(hub.currentProposer(), proposer2);
        assertEq(hub.currentEpoch(), 2);

        // Third rotation
        vm.warp(block.timestamp + 1 hours + 1);
        hub.rotateNetwork();
        assertEq(hub.currentProposer(), proposer3);
        assertEq(hub.currentEpoch(), 3);
    }

    function test_RotateNetwork_WithInactiveChain() public {
        // Deactivate chain 2
        vm.prank(governance);
        hub.setChainActiveStatus(CHAIN_ID_2, false);

        vm.warp(block.timestamp + 1 hours + 1);
        hub.rotateNetwork();

        // Chain 1 and 3 should be updated, chain 2 should not
        assertEq(systemConfig1.batcherHash(), bytes32(uint256(uint160(proposer1))));
        assertEq(systemConfig2.batcherHash(), bytes32(0)); // Not updated
        assertEq(systemConfig3.batcherHash(), bytes32(uint256(uint160(proposer1))));
    }

    // ============ Sharded Rotation Tests ============

    function test_RotateShard_SingleShard() public {
        vm.warp(block.timestamp + 1 hours + 1);

        // With only 3 chains, there's only 1 shard
        hub.rotateShard(0);

        assertEq(hub.currentProposer(), proposer1);
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

        assertTrue(hub.isCurrentProposer(proposer1));
        assertFalse(hub.isCurrentProposer(proposer2));
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

    function test_SetBuilderRegistry_Success() public {
        address newRegistry = address(0x999);

        vm.prank(governance);
        hub.setBuilderRegistry(newRegistry);

        assertEq(hub.builderRegistry(), newRegistry);
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

        vm.prank(guardian);
        hub.emergencyRotate(emergencyProposer);

        assertEq(hub.currentProposer(), emergencyProposer);
        assertEq(systemConfig1.batcherHash(), bytes32(uint256(uint160(emergencyProposer))));
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
        MockSystemConfig failingConfig = new MockSystemConfig();
        // Don't transfer ownership - this will cause rotation to fail for this chain

        vm.prank(governance);
        hub.connectChain(10004, address(failingConfig), bytes32(0), address(adapter));

        vm.warp(block.timestamp + 1 hours + 1);

        // Should not revert, but failing chain should be deactivated
        hub.rotateNetwork();

        // Successful chains should be updated
        assertEq(hub.currentProposer(), proposer1);

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
        MockSystemConfig newConfig = new MockSystemConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 20001;

        // Register chain directly in mock registry
        registry.registerChainDirectly(
            newChainId,
            address(newConfig),
            address(adapter),
            keccak256("POLICY_NEUTRAL"),
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
        assertEq(config.systemConfig, address(newConfig));
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
        vm.expectRevert(ISharedSequencerHub.InvalidSystemConfig.selector);
        hub.connectChainFromRegistry(20001);
    }

    function test_ConnectChainFromRegistry_RevertsIfAlreadyConnected() public {
        MockChainRegistry registry = new MockChainRegistry();
        MockSystemConfig newConfig = new MockSystemConfig();

        registry.registerChainDirectly(
            CHAIN_ID_1, // Already connected
            address(newConfig),
            address(adapter),
            bytes32(0),
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
        MockSystemConfig config1 = new MockSystemConfig();
        MockSystemConfig config2 = new MockSystemConfig();
        MockSystemConfig config3 = new MockSystemConfig();

        config1.transferOwnership(address(hub));
        config2.transferOwnership(address(hub));
        config3.transferOwnership(address(hub));

        uint256 chainId1 = 30001;
        uint256 chainId2 = 30002;
        uint256 chainId3 = 30003;

        registry.registerChainDirectly(chainId1, address(config1), address(adapter), bytes32(0), "Chain 1");
        registry.registerChainDirectly(chainId2, address(config2), address(adapter), bytes32(0), "Chain 2");
        registry.registerChainDirectly(chainId3, address(config3), address(adapter), bytes32(0), "Chain 3");

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

        MockSystemConfig newConfig = new MockSystemConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 40001;

        // Register both an existing chain and a new one
        registry.registerChainDirectly(CHAIN_ID_1, address(systemConfig1), address(adapter), bytes32(0), "Existing");
        registry.registerChainDirectly(newChainId, address(newConfig), address(adapter), bytes32(0), "New");

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
        MockSystemConfig newConfig = new MockSystemConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 50001;

        registry.registerChainDirectly(
            newChainId,
            address(newConfig),
            address(adapter),
            keccak256("OLD_POLICY"),
            "Test Chain"
        );

        vm.startPrank(governance);
        hub.setChainRegistry(address(registry));
        hub.connectChainFromRegistry(newChainId);
        vm.stopPrank();

        // Now update the registry with new policy
        OpStackAdapterV1 newAdapter = new OpStackAdapterV1();
        bytes32 newItemId = registry.getItemId(newChainId);
        IChainRegistry.Item memory item = registry.getItem(newItemId);

        // For testing, we'll just verify the sync function works
        // In reality, the registry would need to update the item data

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
        MockSystemConfig newConfig = new MockSystemConfig();
        newConfig.transferOwnership(address(hub));

        uint256 newChainId = 60001;

        registry.registerChainDirectly(
            newChainId,
            address(newConfig),
            address(adapter),
            bytes32(0),
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
        assertEq(newConfig.batcherHash(), bytes32(uint256(uint160(proposer1))));
        assertEq(newConfig.unsafeBlockSigner(), proposer1);
    }
}
