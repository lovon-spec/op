// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockSystemConfig} from "./mocks/MockSystemConfig.sol";
import {MockCurate} from "./mocks/MockCurate.sol";
import {ICurate} from "../src/interfaces/ICurate.sol";

/**
 * @title KlerosSequencerManagerTest
 * @notice Comprehensive test suite for KlerosSequencerManager.
 *
 * NOTE: Tests use "operator tuples" where each operator has both:
 *   - batcher: address that posts batches to L1
 *   - unsafeSigner: address that signs P2P blocks
 * Both are rotated atomically by the manager.
 */
contract KlerosSequencerManagerTest is Test {
    KlerosSequencerManager public manager;
    MockSystemConfig public systemConfig;
    MockCurate public curate;

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

    uint256 public constant EPOCH_DURATION = 1 hours;

    // Events to test (must match contract exactly)
    event OperatorAdded(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);
    event OperatorRemoved(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);
    event OperatorRotated(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner, bytes32 batcherHash, uint256 timestamp);
    event RotationSkippedNoValidOperator(uint256 timestamp);
    event PausedSet(bool isPaused);
    event GuardianSet(address indexed newGuardian);

    function setUp() public {
        // Set a reasonable block timestamp to avoid underflow in constructor
        vm.warp(EPOCH_DURATION + 1);

        // Deploy mocks
        systemConfig = new MockSystemConfig();
        curate = new MockCurate();

        // Deploy manager
        manager = new KlerosSequencerManager(
            address(curate),
            address(systemConfig),
            EPOCH_DURATION,
            guardian
        );

        // Transfer SystemConfig ownership to manager
        systemConfig.transferOwnership(address(manager));
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsCorrectValues() public view {
        assertEq(address(manager.registry()), address(curate));
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
        new KlerosSequencerManager(address(curate), address(0), EPOCH_DURATION, guardian);
    }

    function test_Constructor_RevertZeroEpochDuration() public {
        vm.expectRevert(KlerosSequencerManager.ZeroEpochDuration.selector);
        new KlerosSequencerManager(address(curate), address(systemConfig), 0, guardian);
    }

    function test_Constructor_AllowsZeroGuardian() public {
        KlerosSequencerManager m = new KlerosSequencerManager(
            address(curate),
            address(systemConfig),
            EPOCH_DURATION,
            address(0)
        );
        assertEq(m.guardian(), address(0));
    }

    // ============ Item ID Tests ============

    function test_ItemIDFor_ComputesCorrectly() public view {
        bytes32 expected = keccak256(abi.encodePacked(abi.encode(alice_batcher, alice_signer)));
        assertEq(manager.itemIDFor(alice_batcher, alice_signer), expected);
    }

    function test_ItemIDFor_DifferentOperatorsDifferentIDs() public view {
        assertNotEq(
            manager.itemIDFor(alice_batcher, alice_signer),
            manager.itemIDFor(bob_batcher, bob_signer)
        );
    }

    function test_OperatorId_ComputesCorrectly() public view {
        bytes32 expected = keccak256(abi.encode(alice_batcher, alice_signer));
        assertEq(manager.operatorId(alice_batcher, alice_signer), expected);
    }

    // ============ Registry Status Tests ============

    function test_IsRegisteredInRegistry_ReturnsTrueForRegistered() public {
        _registerOperator(alice_batcher, alice_signer);
        assertTrue(manager.isRegisteredInRegistry(alice_batcher, alice_signer));
    }

    function test_IsRegisteredInRegistry_ReturnsFalseForAbsent() public view {
        assertFalse(manager.isRegisteredInRegistry(alice_batcher, alice_signer));
    }

    function test_IsRegisteredInRegistry_ReturnsFalseForClearingRequested() public {
        _registerOperator(alice_batcher, alice_signer);
        curate.setOperatorClearingRequested(alice_batcher, alice_signer);
        assertFalse(manager.isRegisteredInRegistry(alice_batcher, alice_signer));
    }

    function test_GetRegistryStatus_ReturnsCorrectStatus() public {
        assertEq(manager.getRegistryStatus(alice_batcher, alice_signer), manager.STATUS_ABSENT());

        _registerOperator(alice_batcher, alice_signer);
        assertEq(manager.getRegistryStatus(alice_batcher, alice_signer), manager.STATUS_REGISTERED());

        curate.setOperatorClearingRequested(alice_batcher, alice_signer);
        assertEq(manager.getRegistryStatus(alice_batcher, alice_signer), manager.STATUS_CLEARING_REQUESTED());
    }

    // ============ Sync Add Tests ============

    function test_SyncAddOperator_AddsRegisteredOperator() public {
        _registerOperator(alice_batcher, alice_signer);

        bytes32 opId = manager.operatorId(alice_batcher, alice_signer);
        vm.expectEmit(true, true, true, false);
        emit OperatorAdded(opId, alice_batcher, alice_signer);

        manager.syncAddOperator(alice_batcher, alice_signer);

        assertTrue(manager.isActive(opId));
        assertEq(manager.activeOperatorCount(), 1);
    }

    function test_SyncAddOperator_RevertIfNotRegistered() public {
        vm.expectRevert(KlerosSequencerManager.NotRegisteredInRegistry.selector);
        manager.syncAddOperator(alice_batcher, alice_signer);
    }

    function test_SyncAddOperator_RevertIfAlreadyActive() public {
        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);

        vm.expectRevert(KlerosSequencerManager.AlreadyActive.selector);
        manager.syncAddOperator(alice_batcher, alice_signer);
    }

    function test_SyncAddOperator_RevertIfZeroBatcher() public {
        vm.expectRevert(KlerosSequencerManager.ZeroAddress.selector);
        manager.syncAddOperator(address(0), alice_signer);
    }

    function test_SyncAddOperator_RevertIfZeroSigner() public {
        vm.expectRevert(KlerosSequencerManager.ZeroAddress.selector);
        manager.syncAddOperator(alice_batcher, address(0));
    }

    function test_SyncAddOperator_RevertIfPaused() public {
        _registerOperator(alice_batcher, alice_signer);

        vm.prank(guardian);
        manager.setPaused(true);

        vm.expectRevert(KlerosSequencerManager.ContractPaused.selector);
        manager.syncAddOperator(alice_batcher, alice_signer);
    }

    function test_SyncAddOperator_MultipleOperators() public {
        _registerOperator(alice_batcher, alice_signer);
        _registerOperator(bob_batcher, bob_signer);
        _registerOperator(charlie_batcher, charlie_signer);

        manager.syncAddOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(bob_batcher, bob_signer);
        manager.syncAddOperator(charlie_batcher, charlie_signer);

        assertEq(manager.activeOperatorCount(), 3);
    }

    // ============ Sync Remove Tests ============

    function test_SyncRemoveOperator_RemovesInvalidOperator() public {
        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);

        // Simulate challenge (clearing requested)
        curate.setOperatorClearingRequested(alice_batcher, alice_signer);

        bytes32 opId = manager.operatorId(alice_batcher, alice_signer);
        vm.expectEmit(true, true, true, false);
        emit OperatorRemoved(opId, alice_batcher, alice_signer);

        manager.syncRemoveOperator(alice_batcher, alice_signer);

        assertFalse(manager.isActive(opId));
        assertEq(manager.activeOperatorCount(), 0);
    }

    function test_SyncRemoveOperator_RevertIfNotActive() public {
        vm.expectRevert(KlerosSequencerManager.NotActive.selector);
        manager.syncRemoveOperator(alice_batcher, alice_signer);
    }

    function test_SyncRemoveOperator_RevertIfStillRegistered() public {
        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);

        vm.expectRevert(KlerosSequencerManager.StillRegisteredInRegistry.selector);
        manager.syncRemoveOperator(alice_batcher, alice_signer);
    }

    function test_SyncRemoveOperator_RevertIfPaused() public {
        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);

        curate.setOperatorClearingRequested(alice_batcher, alice_signer);

        vm.prank(guardian);
        manager.setPaused(true);

        vm.expectRevert(KlerosSequencerManager.ContractPaused.selector);
        manager.syncRemoveOperator(alice_batcher, alice_signer);
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

        // Wait for epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Second rotation -> bob (index 1)
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, bob_batcher);
        assertEq(current.unsafeSigner, bob_signer);

        // Wait for epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Third rotation -> charlie (index 2)
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, charlie_batcher);
        assertEq(current.unsafeSigner, charlie_signer);

        // Wait for epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Fourth rotation -> wraps to alice (index 0)
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);
        assertEq(current.unsafeSigner, alice_signer);
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
        curate.setOperatorClearingRequested(bob_batcher, bob_signer);

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
        curate.setOperatorClearingRequested(alice_batcher, alice_signer);
        curate.setOperatorClearingRequested(bob_batcher, bob_signer);
        curate.setOperatorClearingRequested(charlie_batcher, charlie_signer);

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

    // ============ Current Index Handling Tests ============

    function test_RemoveBeforeCurrentIndex_AdjustsIndex() public {
        _setupThreeOperators();

        // Rotate to bob (index 1)
        manager.rotateOperator();
        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateOperator();
        assertEq(manager.currentIndex(), 1);

        // Remove alice (index 0, before currentIndex)
        curate.setOperatorClearingRequested(alice_batcher, alice_signer);
        manager.syncRemoveOperator(alice_batcher, alice_signer);

        // currentIndex should be adjusted
        assertEq(manager.currentIndex(), 0);
    }

    function test_RemoveAtCurrentIndex_ResetsIndex() public {
        _setupThreeOperators();

        // Rotate to charlie (index 2)
        manager.rotateOperator();
        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateOperator();
        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateOperator();
        assertEq(manager.currentIndex(), 2);

        // Remove charlie (at currentIndex, which is also lastIndex)
        curate.setOperatorClearingRequested(charlie_batcher, charlie_signer);
        manager.syncRemoveOperator(charlie_batcher, charlie_signer);

        // currentIndex should reset to max (meaning next rotation starts from 0)
        assertEq(manager.currentIndex(), type(uint256).max);

        // Verify next rotation selects alice (index 0)
        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateOperator();
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

    function test_SetGuardian_CanDisableBySettingZero() public {
        vm.prank(guardian);
        manager.setGuardian(address(0));

        assertEq(manager.guardian(), address(0));

        // Now no one can call guardian functions
        vm.expectRevert(KlerosSequencerManager.InvalidGuardian.selector);
        vm.prank(guardian);
        manager.setPaused(true);
    }

    // ============ View Functions Tests ============

    function test_ActiveOperatorCount() public {
        assertEq(manager.activeOperatorCount(), 0);

        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);
        assertEq(manager.activeOperatorCount(), 1);

        _registerOperator(bob_batcher, bob_signer);
        manager.syncAddOperator(bob_batcher, bob_signer);
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

        // Initially should be 0 (can rotate immediately due to constructor setup)
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
        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);

        manager.rotateOperator();
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);

        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateOperator();
        current = manager.currentOperator();
        assertEq(current.batcher, alice_batcher);
    }

    function test_SwapPopRemoval_MaintainsCorrectOrder() public {
        _setupThreeOperators();
        _registerOperator(dave_batcher, dave_signer);
        manager.syncAddOperator(dave_batcher, dave_signer);

        // Order: [alice, bob, charlie, dave]
        // Remove bob -> [alice, dave, charlie]
        curate.setOperatorClearingRequested(bob_batcher, bob_signer);
        manager.syncRemoveOperator(bob_batcher, bob_signer);

        assertEq(manager.activeOperatorCount(), 3);

        KlerosSequencerManager.Operator[] memory operators = manager.getActiveOperators();
        assertEq(operators[0].batcher, alice_batcher);
        assertEq(operators[1].batcher, dave_batcher);
        assertEq(operators[2].batcher, charlie_batcher);
    }

    function test_BatcherHash_V0Format() public {
        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);
        manager.rotateOperator();

        bytes32 expected = bytes32(uint256(uint160(alice_batcher)));
        assertEq(systemConfig.batcherHash(), expected);

        // Verify we can extract the address back
        address extracted = address(uint160(uint256(systemConfig.batcherHash())));
        assertEq(extracted, alice_batcher);
    }

    function test_UnsafeBlockSigner_SetCorrectly() public {
        _registerOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(alice_batcher, alice_signer);
        manager.rotateOperator();

        assertEq(systemConfig.unsafeBlockSigner(), alice_signer);
    }

    // ============ Legacy API Tests ============

    function test_LegacyCurrentSequencer_ReturnsBatcher() public {
        _setupThreeOperators();
        manager.rotateOperator();

        // Legacy currentSequencer returns just the batcher address
        assertEq(manager.currentSequencer(), alice_batcher);
    }

    function test_LegacyActiveSequencerCount_ReturnsOperatorCount() public {
        _setupThreeOperators();
        assertEq(manager.activeSequencerCount(), 3);
    }

    function test_LegacyRotateSequencer_Works() public {
        _setupThreeOperators();

        // Legacy rotateSequencer should work
        manager.rotateSequencer();

        assertEq(manager.currentSequencer(), alice_batcher);
    }

    // ============ Fuzz Tests ============

    function testFuzz_ItemIDFor_Deterministic(address batcher, address signer) public view {
        bytes32 id1 = manager.itemIDFor(batcher, signer);
        bytes32 id2 = manager.itemIDFor(batcher, signer);
        assertEq(id1, id2);
    }

    function testFuzz_AddRemoveOperator(address batcher, address signer) public {
        vm.assume(batcher != address(0));
        vm.assume(signer != address(0));

        _registerOperator(batcher, signer);
        manager.syncAddOperator(batcher, signer);

        bytes32 opId = manager.operatorId(batcher, signer);
        assertTrue(manager.isActive(opId));

        curate.setOperatorClearingRequested(batcher, signer);
        manager.syncRemoveOperator(batcher, signer);

        assertFalse(manager.isActive(opId));
    }

    // ============ Helper Functions ============

    function _registerOperator(address batcher, address signer) internal {
        curate.registerOperatorDirectly(batcher, signer);
    }

    function _setupThreeOperators() internal {
        _registerOperator(alice_batcher, alice_signer);
        _registerOperator(bob_batcher, bob_signer);
        _registerOperator(charlie_batcher, charlie_signer);

        manager.syncAddOperator(alice_batcher, alice_signer);
        manager.syncAddOperator(bob_batcher, bob_signer);
        manager.syncAddOperator(charlie_batcher, charlie_signer);
    }
}
