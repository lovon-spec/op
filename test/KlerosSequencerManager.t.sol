// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "./mocks/MockSystemConfig.sol";
import {MockPermanentGTCRHybrid} from "./mocks/MockPermanentGTCRHybrid.sol";
import {IPermanentGTCRHybrid} from "../src/interfaces/IPermanentGTCRHybrid.sol";

/**
 * @title KlerosSequencerManagerTest
 * @notice Comprehensive test suite for KlerosSequencerManager with Hybrid PGTCR.
 *
 * Architecture:
 * - Uses IPermanentGTCRHybrid for registry (on-chain operational keys)
 * - Manager uses snapshot + reverse mapping for O(1) validation
 * - Supports syncAddOperator(bytes32 itemID) and legacy syncAddOperator(address, address)
 */
contract KlerosSequencerManagerTest is Test {
    KlerosSequencerManager public manager;
    MockSystemConfig public systemConfig;
    MockPermanentGTCRHybrid public registry;

    address public guardian = address(0x1);

    // Operator tuples: (batcher, unsafeSigner)
    address public alice_batcher = address(0x100);
    address public alice_signer = address(0x101);
    address public bob_batcher = address(0x200);
    address public bob_signer = address(0x201);
    address public charlie_batcher = address(0x300);
    address public charlie_signer = address(0x301);
    address public dave_batcher = address(0x400);
    address public dave_signer = address(0x401);

    // Item IDs (set during registration)
    bytes32 public alice_itemID;
    bytes32 public bob_itemID;
    bytes32 public charlie_itemID;
    bytes32 public dave_itemID;

    uint256 public constant EPOCH_DURATION = 1 hours;

    // Events to test
    event OperatorAdded(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);
    event OperatorUpdated(bytes32 indexed oldOperatorId, bytes32 indexed newOperatorId, address batcher, address unsafeSigner);
    event OperatorRemoved(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);
    event OperatorRotated(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner, bytes32 batcherHash, uint256 timestamp);
    event RotationSkippedNoValidOperator(uint256 timestamp);
    event PausedSet(bool isPaused);
    event GuardianSet(address indexed newGuardian);

    function setUp() public {
        // Set a reasonable block timestamp
        vm.warp(EPOCH_DURATION + 1);

        // Deploy mocks
        systemConfig = new MockSystemConfig();
        registry = new MockPermanentGTCRHybrid();

        // Deploy manager
        manager = new KlerosSequencerManager(
            address(registry),
            address(systemConfig),
            EPOCH_DURATION,
            guardian
        );

        // Transfer SystemConfig ownership to manager
        systemConfig.transferOwnership(address(manager));
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsCorrectValues() public view {
        assertEq(address(manager.registry()), address(registry));
        assertEq(address(manager.systemConfig()), address(systemConfig));
        assertEq(manager.epochDuration(), EPOCH_DURATION);
        assertEq(manager.guardian(), guardian);
        assertEq(manager.paused(), false);
    }

    function test_Constructor_RevertZeroRegistry() public {
        vm.expectRevert(KlerosSequencerManager.ZeroAddress.selector);
        new KlerosSequencerManager(address(0), address(systemConfig), EPOCH_DURATION, guardian);
    }

    function test_Constructor_RevertZeroSystemConfig() public {
        vm.expectRevert(KlerosSequencerManager.ZeroAddress.selector);
        new KlerosSequencerManager(address(registry), address(0), EPOCH_DURATION, guardian);
    }

    function test_Constructor_RevertZeroEpochDuration() public {
        vm.expectRevert(KlerosSequencerManager.ZeroEpochDuration.selector);
        new KlerosSequencerManager(address(registry), address(systemConfig), 0, guardian);
    }

    function test_Constructor_AllowsZeroGuardian() public {
        KlerosSequencerManager m = new KlerosSequencerManager(
            address(registry),
            address(systemConfig),
            EPOCH_DURATION,
            address(0)
        );
        assertEq(m.guardian(), address(0));
    }

    // ============ Operator ID Tests ============

    function test_OperatorId_ComputesCorrectly() public view {
        bytes32 expected = keccak256(abi.encode(alice_batcher, alice_signer));
        assertEq(manager.operatorId(alice_batcher, alice_signer), expected);
    }

    function test_OperatorId_DifferentOperatorsDifferentIDs() public view {
        assertNotEq(
            manager.operatorId(alice_batcher, alice_signer),
            manager.operatorId(bob_batcher, bob_signer)
        );
    }

    // ============ Registry Status Tests ============

    function test_IsRegisteredInRegistry_ReturnsTrueForRegistered() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);
        assertTrue(manager.isRegisteredInRegistry(alice_batcher, alice_signer));
    }

    function test_IsRegisteredInRegistry_ReturnsFalseForAbsent() public view {
        assertFalse(manager.isRegisteredInRegistry(alice_batcher, alice_signer));
    }

    function test_IsRegisteredInRegistry_ReturnsFalseForRemoved() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);

        registry.setOperatorClearingRequested(alice_batcher, alice_signer);
        assertFalse(manager.isRegisteredInRegistry(alice_batcher, alice_signer));
    }

    // ============ Sync Add Tests (by itemID) ============

    function test_SyncAddOperator_ByItemID() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);

        bytes32 opId = manager.operatorId(alice_batcher, alice_signer);
        vm.expectEmit(true, true, true, false);
        emit OperatorAdded(opId, alice_batcher, alice_signer);

        manager.syncAddOperator(alice_itemID);

        assertTrue(manager.isActive(opId));
        assertEq(manager.activeOperatorCount(), 1);

        // Verify reverse mapping
        assertEq(manager.opIdToItemId(opId), alice_itemID);
        assertEq(manager.itemIdToOpId(alice_itemID), opId);
    }

    function test_SyncAddOperator_RevertIfNotRegistered() public {
        bytes32 fakeItemID = keccak256("fake");
        vm.expectRevert(KlerosSequencerManager.NotRegisteredInRegistry.selector);
        manager.syncAddOperator(fakeItemID);
    }

    function test_SyncAddOperator_RevertIfAlreadySynced() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);

        vm.expectRevert(KlerosSequencerManager.ItemAlreadySynced.selector);
        manager.syncAddOperator(alice_itemID);
    }

    function test_SyncAddOperator_RevertIfPaused() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);

        vm.prank(guardian);
        manager.setPaused(true);

        vm.expectRevert(KlerosSequencerManager.ContractPaused.selector);
        manager.syncAddOperator(alice_itemID);
    }

    function test_SyncAddOperator_MultipleOperators() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        bob_itemID = _registerOperator(bob_batcher, bob_signer);
        charlie_itemID = _registerOperator(charlie_batcher, charlie_signer);

        manager.syncAddOperator(alice_itemID);
        manager.syncAddOperator(bob_itemID);
        manager.syncAddOperator(charlie_itemID);

        assertEq(manager.activeOperatorCount(), 3);
    }

    // ============ Sync Add Tests (Legacy by addresses) ============

    function test_SyncAddOperator_LegacyByAddresses() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);

        bytes32 opId = manager.operatorId(alice_batcher, alice_signer);
        vm.expectEmit(true, true, true, false);
        emit OperatorAdded(opId, alice_batcher, alice_signer);

        manager.syncAddOperator(alice_batcher, alice_signer);

        assertTrue(manager.isActive(opId));
        assertEq(manager.activeOperatorCount(), 1);
    }

    function test_SyncAddOperator_Legacy_RevertIfZeroBatcher() public {
        vm.expectRevert(KlerosSequencerManager.ZeroAddress.selector);
        manager.syncAddOperator(address(0), alice_signer);
    }

    function test_SyncAddOperator_Legacy_RevertIfZeroSigner() public {
        vm.expectRevert(KlerosSequencerManager.ZeroAddress.selector);
        manager.syncAddOperator(alice_batcher, address(0));
    }

    // ============ Sync Update Tests ============

    function test_SyncUpdateOperator_UpdatesKeys() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);

        bytes32 oldOpId = manager.operatorId(alice_batcher, alice_signer);

        // Change keys in registry
        address newBatcher = address(0x999);
        address newSigner = address(0x998);
        registry.setOperationalKeys(alice_itemID, newBatcher, newSigner);

        bytes32 newOpId = manager.operatorId(newBatcher, newSigner);

        vm.expectEmit(true, true, false, true);
        emit OperatorUpdated(oldOpId, newOpId, newBatcher, newSigner);

        manager.syncUpdateOperator(alice_itemID);

        // Old keys should be inactive
        assertFalse(manager.isActive(oldOpId));

        // New keys should be active
        assertTrue(manager.isActive(newOpId));
        assertEq(manager.opIdToItemId(newOpId), alice_itemID);
    }

    function test_SyncUpdateOperator_RevertIfNotActive() public {
        bytes32 fakeItemID = keccak256("fake");
        vm.expectRevert(KlerosSequencerManager.NotActive.selector);
        manager.syncUpdateOperator(fakeItemID);
    }

    // ============ Sync Remove Tests (by itemID) ============

    function test_SyncRemoveOperator_ByItemID() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);

        // Remove from registry
        registry.setOperatorClearingRequested(alice_batcher, alice_signer);

        bytes32 opId = manager.operatorId(alice_batcher, alice_signer);
        vm.expectEmit(true, true, true, false);
        emit OperatorRemoved(opId, alice_batcher, alice_signer);

        manager.syncRemoveOperator(alice_itemID);

        assertFalse(manager.isActive(opId));
        assertEq(manager.activeOperatorCount(), 0);
    }

    function test_SyncRemoveOperator_RevertIfNotActive() public {
        bytes32 fakeItemID = keccak256("fake");
        vm.expectRevert(KlerosSequencerManager.NotActive.selector);
        manager.syncRemoveOperator(fakeItemID);
    }

    function test_SyncRemoveOperator_RevertIfStillRegistered() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);

        vm.expectRevert(KlerosSequencerManager.StillRegisteredInRegistry.selector);
        manager.syncRemoveOperator(alice_itemID);
    }

    // ============ Sync Remove Tests (Legacy by addresses) ============

    function test_SyncRemoveOperator_LegacyByAddresses() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);

        registry.setOperatorClearingRequested(alice_batcher, alice_signer);

        bytes32 opId = manager.operatorId(alice_batcher, alice_signer);
        vm.expectEmit(true, true, true, false);
        emit OperatorRemoved(opId, alice_batcher, alice_signer);

        manager.syncRemoveOperator(alice_batcher, alice_signer);

        assertFalse(manager.isActive(opId));
    }

    // ============ Rotation Tests ============

    function test_RotateOperator_SelectsNextOperator() public {
        _setupThreeOperators();

        bytes32 expectedHash = bytes32(uint256(uint160(alice_batcher)));
        bytes32 opId = manager.operatorId(alice_batcher, alice_signer);

        vm.expectEmit(true, true, true, true);
        emit OperatorRotated(opId, alice_batcher, alice_signer, expectedHash, block.timestamp);

        manager.rotateOperator();

        assertEq(manager.currentIndex(), 0);
        assertEq(systemConfig.batcherHash(), expectedHash);
        assertEq(systemConfig.unsafeBlockSigner(), alice_signer);
    }

    function test_RotateOperator_RotatesThroughAllOperators() public {
        _setupThreeOperators();

        // First rotation -> alice (index 0)
        manager.rotateOperator();
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);
        assertEq(current.unsafeSigner, alice_signer);

        vm.warp(block.timestamp + EPOCH_DURATION);

        // Second rotation -> bob (index 1)
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, bob_batcher);
        assertEq(current.unsafeSigner, bob_signer);

        vm.warp(block.timestamp + EPOCH_DURATION);

        // Third rotation -> charlie (index 2)
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, charlie_batcher);
        assertEq(current.unsafeSigner, charlie_signer);

        vm.warp(block.timestamp + EPOCH_DURATION);

        // Fourth rotation -> wraps to alice (index 0)
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);
    }

    function test_RotateOperator_RevertIfEpochNotEnded() public {
        _setupThreeOperators();
        manager.rotateOperator();

        vm.expectRevert(KlerosSequencerManager.EpochNotEnded.selector);
        manager.rotateOperator();
    }

    function test_RotateOperator_RevertIfNoActiveOperators() public {
        vm.expectRevert(KlerosSequencerManager.NoActiveOperators.selector);
        manager.rotateOperator();
    }

    function test_RotateOperator_SkipsInvalidOperators() public {
        _setupThreeOperators();

        // Invalidate bob
        registry.setOperatorClearingRequested(bob_batcher, bob_signer);

        // First rotation -> alice (valid)
        manager.rotateOperator();
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);

        vm.warp(block.timestamp + EPOCH_DURATION);

        // Second rotation -> should skip bob and go to charlie
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, charlie_batcher);

        // Bob should be removed
        bytes32 bobOpId = manager.operatorId(bob_batcher, bob_signer);
        assertFalse(manager.isActive(bobOpId));
        assertEq(manager.activeOperatorCount(), 2);
    }

    function test_RotateOperator_RemovesAllInvalidAndEmitsSkipped() public {
        _setupThreeOperators();

        // Invalidate all
        registry.setOperatorClearingRequested(alice_batcher, alice_signer);
        registry.setOperatorClearingRequested(bob_batcher, bob_signer);
        registry.setOperatorClearingRequested(charlie_batcher, charlie_signer);

        vm.expectEmit(false, false, false, true);
        emit RotationSkippedNoValidOperator(block.timestamp);

        manager.rotateOperator();

        assertEq(manager.activeOperatorCount(), 0);
    }

    function test_RotateOperator_RevertIfPaused() public {
        _setupThreeOperators();

        vm.prank(guardian);
        manager.setPaused(true);

        vm.expectRevert(KlerosSequencerManager.ContractPaused.selector);
        manager.rotateOperator();
    }

    function test_Poke_CallsRotateOperator() public {
        _setupThreeOperators();

        manager.poke();

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);
    }

    // ============ Guardian Tests ============

    function test_SetPaused_OnlyGuardian() public {
        vm.expectRevert(KlerosSequencerManager.InvalidGuardian.selector);
        manager.setPaused(true);

        vm.prank(guardian);
        vm.expectEmit(false, false, false, true);
        emit PausedSet(true);
        manager.setPaused(true);

        assertTrue(manager.paused());
    }

    function test_SetGuardian_OnlyGuardian() public {
        address newGuardian = address(0x999);

        vm.expectRevert(KlerosSequencerManager.InvalidGuardian.selector);
        manager.setGuardian(newGuardian);

        vm.prank(guardian);
        vm.expectEmit(true, false, false, false);
        emit GuardianSet(newGuardian);
        manager.setGuardian(newGuardian);

        assertEq(manager.guardian(), newGuardian);
    }

    // ============ View Functions Tests ============

    function test_ActiveOperatorCount() public {
        assertEq(manager.activeOperatorCount(), 0);

        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);
        assertEq(manager.activeOperatorCount(), 1);

        bob_itemID = _registerOperator(bob_batcher, bob_signer);
        manager.syncAddOperator(bob_itemID);
        assertEq(manager.activeOperatorCount(), 2);
    }

    function test_GetActiveOperators() public {
        _setupThreeOperators();

        KlerosSequencerManager.Operator[] memory operators = manager.getActiveOperators();
        assertEq(operators.length, 3);
        assertEq(operators[0].batcher, alice_batcher);
        assertEq(operators[0].unsafeSigner, alice_signer);
        assertEq(operators[1].batcher, bob_batcher);
        assertEq(operators[1].unsafeSigner, bob_signer);
        assertEq(operators[2].batcher, charlie_batcher);
        assertEq(operators[2].unsafeSigner, charlie_signer);
    }

    function test_CurrentOperator_ReturnsZeroWhenEmpty() public view {
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        assertEq(current.batcher, address(0));
        assertEq(current.unsafeSigner, address(0));
    }

    function test_CurrentOperator_ReturnsCorrectTuple() public {
        _setupThreeOperators();
        manager.rotateOperator();

        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);
        assertEq(current.unsafeSigner, alice_signer);
    }

    function test_IsCurrentOperator_ReturnsTrue() public {
        _setupThreeOperators();
        manager.rotateOperator();

        assertTrue(manager.isCurrentOperator(alice_batcher, alice_signer));
        assertFalse(manager.isCurrentOperator(bob_batcher, bob_signer));
    }

    function test_TimeUntilNextRotation() public {
        _setupThreeOperators();

        // Initially should be 0 (can rotate immediately)
        assertEq(manager.timeUntilNextRotation(), 0);

        manager.rotateOperator();

        // Should be close to EPOCH_DURATION
        assertGt(manager.timeUntilNextRotation(), EPOCH_DURATION - 10);
        assertLe(manager.timeUntilNextRotation(), EPOCH_DURATION);

        // Warp half epoch
        vm.warp(block.timestamp + EPOCH_DURATION / 2);
        assertLe(manager.timeUntilNextRotation(), EPOCH_DURATION / 2 + 1);

        // Warp past epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        assertEq(manager.timeUntilNextRotation(), 0);
    }

    // ============ Edge Cases Tests ============

    function test_SingleOperator_RotatesBackToItself() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);

        manager.rotateOperator();
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);

        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);
    }

    function test_BatcherHash_V0Format() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);
        manager.rotateOperator();

        bytes32 expected = bytes32(uint256(uint160(alice_batcher)));
        assertEq(systemConfig.batcherHash(), expected);

        // Verify we can extract the address back
        address extracted = address(uint160(uint256(systemConfig.batcherHash())));
        assertEq(extracted, alice_batcher);
    }

    function test_UnsafeBlockSigner_SetCorrectly() public {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_itemID);
        manager.rotateOperator();

        assertEq(systemConfig.unsafeBlockSigner(), alice_signer);
    }

    // ============ Legacy API Tests ============

    function test_LegacyCurrentSequencer_ReturnsBatcher() public {
        _setupThreeOperators();
        manager.rotateOperator();

        assertEq(manager.currentSequencer(), alice_batcher);
    }

    function test_LegacyActiveSequencerCount_ReturnsOperatorCount() public {
        _setupThreeOperators();
        assertEq(manager.activeSequencerCount(), 3);
    }

    function test_LegacyRotateSequencer_Works() public {
        _setupThreeOperators();

        manager.rotateSequencer();

        assertEq(manager.currentSequencer(), alice_batcher);
    }

    // ============ Fuzz Tests ============

    function testFuzz_OperatorId_Deterministic(address batcher, address signer) public view {
        bytes32 id1 = manager.operatorId(batcher, signer);
        bytes32 id2 = manager.operatorId(batcher, signer);
        assertEq(id1, id2);
    }

    function testFuzz_AddRemoveOperator(address batcher, address signer) public {
        vm.assume(batcher != address(0));
        vm.assume(signer != address(0));

        bytes32 itemID = _registerOperator(batcher, signer);
        manager.syncAddOperator(itemID);

        bytes32 opId = manager.operatorId(batcher, signer);
        assertTrue(manager.isActive(opId));

        registry.setOperatorClearingRequested(batcher, signer);
        manager.syncRemoveOperator(itemID);

        assertFalse(manager.isActive(opId));
    }

    // ============ Helper Functions ============

    function _registerOperator(address batcher, address signer) internal returns (bytes32 itemID) {
        return registry.registerOperatorDirectly(batcher, signer);
    }

    function _setupThreeOperators() internal {
        alice_itemID = _registerOperator(alice_batcher, alice_signer);
        bob_itemID = _registerOperator(bob_batcher, bob_signer);
        charlie_itemID = _registerOperator(charlie_batcher, charlie_signer);

        manager.syncAddOperator(alice_itemID);
        manager.syncAddOperator(bob_itemID);
        manager.syncAddOperator(charlie_itemID);
    }
}
