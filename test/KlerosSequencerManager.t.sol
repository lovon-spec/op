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
 */
contract KlerosSequencerManagerTest is Test {
    KlerosSequencerManager public manager;
    MockSystemConfig public systemConfig;
    MockCurate public curate;

    address public guardian = address(0x1);
    address public alice = address(0x100);
    address public bob = address(0x200);
    address public charlie = address(0x300);
    address public dave = address(0x400);

    uint256 public constant EPOCH_DURATION = 1 hours;

    // Events to test
    event SequencerAdded(address indexed sequencer);
    event SequencerRemoved(address indexed sequencer);
    event SequencerRotated(address indexed newSequencer, bytes32 newBatcherHash, uint256 timestamp);
    event RotationSkippedNoValidSequencer(uint256 timestamp);
    event PausedSet(bool isPaused);
    event GuardianSet(address indexed newGuardian);

    function setUp() public {
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
        bytes32 expected = keccak256(abi.encodePacked(abi.encode(alice)));
        assertEq(manager.itemIDFor(alice), expected);
    }

    function test_ItemIDFor_DifferentAddressesDifferentIDs() public view {
        assertNotEq(manager.itemIDFor(alice), manager.itemIDFor(bob));
    }

    // ============ Registry Status Tests ============

    function test_IsRegisteredInRegistry_ReturnsTrueForRegistered() public {
        _registerSequencer(alice);
        assertTrue(manager.isRegisteredInRegistry(alice));
    }

    function test_IsRegisteredInRegistry_ReturnsFalseForAbsent() public view {
        assertFalse(manager.isRegisteredInRegistry(alice));
    }

    function test_IsRegisteredInRegistry_ReturnsFalseForClearingRequested() public {
        _registerSequencer(alice);
        bytes32 itemID = manager.itemIDFor(alice);
        curate.setClearingRequested(itemID);
        assertFalse(manager.isRegisteredInRegistry(alice));
    }

    function test_GetRegistryStatus_ReturnsCorrectStatus() public {
        assertEq(manager.getRegistryStatus(alice), manager.STATUS_ABSENT());

        _registerSequencer(alice);
        assertEq(manager.getRegistryStatus(alice), manager.STATUS_REGISTERED());

        bytes32 itemID = manager.itemIDFor(alice);
        curate.setClearingRequested(itemID);
        assertEq(manager.getRegistryStatus(alice), manager.STATUS_CLEARING_REQUESTED());
    }

    // ============ Sync Add Tests ============

    function test_SyncAddSequencer_AddsRegisteredSequencer() public {
        _registerSequencer(alice);

        vm.expectEmit(true, false, false, false);
        emit SequencerAdded(alice);

        manager.syncAddSequencer(alice);

        assertTrue(manager.isActive(alice));
        assertEq(manager.activeSequencerCount(), 1);
        assertEq(manager.indexOf(alice), 0);
    }

    function test_SyncAddSequencer_RevertIfNotRegistered() public {
        vm.expectRevert(KlerosSequencerManager.NotRegisteredInRegistry.selector);
        manager.syncAddSequencer(alice);
    }

    function test_SyncAddSequencer_RevertIfAlreadyActive() public {
        _registerSequencer(alice);
        manager.syncAddSequencer(alice);

        vm.expectRevert(KlerosSequencerManager.AlreadyActive.selector);
        manager.syncAddSequencer(alice);
    }

    function test_SyncAddSequencer_RevertIfZeroAddress() public {
        vm.expectRevert(KlerosSequencerManager.ZeroAddress.selector);
        manager.syncAddSequencer(address(0));
    }

    function test_SyncAddSequencer_RevertIfPaused() public {
        _registerSequencer(alice);

        vm.prank(guardian);
        manager.setPaused(true);

        vm.expectRevert(KlerosSequencerManager.ContractPaused.selector);
        manager.syncAddSequencer(alice);
    }

    function test_SyncAddSequencer_MultipleSequencers() public {
        _registerSequencer(alice);
        _registerSequencer(bob);
        _registerSequencer(charlie);

        manager.syncAddSequencer(alice);
        manager.syncAddSequencer(bob);
        manager.syncAddSequencer(charlie);

        assertEq(manager.activeSequencerCount(), 3);
        assertEq(manager.indexOf(alice), 0);
        assertEq(manager.indexOf(bob), 1);
        assertEq(manager.indexOf(charlie), 2);
    }

    // ============ Sync Remove Tests ============

    function test_SyncRemoveSequencer_RemovesInvalidSequencer() public {
        _registerSequencer(alice);
        manager.syncAddSequencer(alice);

        // Simulate challenge (clearing requested)
        bytes32 itemID = manager.itemIDFor(alice);
        curate.setClearingRequested(itemID);

        vm.expectEmit(true, false, false, false);
        emit SequencerRemoved(alice);

        manager.syncRemoveSequencer(alice);

        assertFalse(manager.isActive(alice));
        assertEq(manager.activeSequencerCount(), 0);
    }

    function test_SyncRemoveSequencer_RevertIfNotActive() public {
        vm.expectRevert(KlerosSequencerManager.NotActive.selector);
        manager.syncRemoveSequencer(alice);
    }

    function test_SyncRemoveSequencer_RevertIfStillRegistered() public {
        _registerSequencer(alice);
        manager.syncAddSequencer(alice);

        vm.expectRevert(KlerosSequencerManager.StillRegisteredInRegistry.selector);
        manager.syncRemoveSequencer(alice);
    }

    function test_SyncRemoveSequencer_RevertIfPaused() public {
        _registerSequencer(alice);
        manager.syncAddSequencer(alice);

        bytes32 itemID = manager.itemIDFor(alice);
        curate.setClearingRequested(itemID);

        vm.prank(guardian);
        manager.setPaused(true);

        vm.expectRevert(KlerosSequencerManager.ContractPaused.selector);
        manager.syncRemoveSequencer(alice);
    }

    // ============ Rotation Tests ============

    function test_RotateSequencer_SelectsNextSequencer() public {
        _setupThreeSequencers();

        bytes32 expectedHash = bytes32(uint256(uint160(alice)));

        vm.expectEmit(true, true, true, true);
        emit SequencerRotated(alice, expectedHash, block.timestamp);

        manager.rotateSequencer();

        assertEq(manager.currentIndex(), 0);
        assertEq(systemConfig.batcherHash(), expectedHash);
    }

    function test_RotateSequencer_RotatesThroughAllSequencers() public {
        _setupThreeSequencers();

        // First rotation -> alice (index 0)
        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), alice);

        // Wait for epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Second rotation -> bob (index 1)
        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), bob);

        // Wait for epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Third rotation -> charlie (index 2)
        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), charlie);

        // Wait for epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Fourth rotation -> wraps to alice (index 0)
        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), alice);
    }

    function test_RotateSequencer_RevertIfEpochNotEnded() public {
        _setupThreeSequencers();
        manager.rotateSequencer();

        vm.expectRevert(KlerosSequencerManager.EpochNotEnded.selector);
        manager.rotateSequencer();
    }

    function test_RotateSequencer_RevertIfNoActiveSequencers() public {
        vm.expectRevert(KlerosSequencerManager.NoActiveSequencers.selector);
        manager.rotateSequencer();
    }

    function test_RotateSequencer_SkipsInvalidSequencers() public {
        _setupThreeSequencers();

        // Invalidate bob
        bytes32 bobItemID = manager.itemIDFor(bob);
        curate.setClearingRequested(bobItemID);

        // First rotation -> alice (valid)
        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        // Second rotation -> should skip bob and go to charlie
        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), charlie);

        // Bob should be removed
        assertFalse(manager.isActive(bob));
        assertEq(manager.activeSequencerCount(), 2);
    }

    function test_RotateSequencer_RemovesAllInvalidAndEmitsSkipped() public {
        _setupThreeSequencers();

        // Invalidate all
        curate.setClearingRequested(manager.itemIDFor(alice));
        curate.setClearingRequested(manager.itemIDFor(bob));
        curate.setClearingRequested(manager.itemIDFor(charlie));

        vm.expectEmit(false, false, false, true);
        emit RotationSkippedNoValidSequencer(block.timestamp);

        manager.rotateSequencer();

        assertEq(manager.activeSequencerCount(), 0);
    }

    function test_RotateSequencer_RevertIfPaused() public {
        _setupThreeSequencers();

        vm.prank(guardian);
        manager.setPaused(true);

        vm.expectRevert(KlerosSequencerManager.ContractPaused.selector);
        manager.rotateSequencer();
    }

    function test_Poke_CallsRotateSequencer() public {
        _setupThreeSequencers();

        manager.poke();

        assertEq(manager.currentSequencer(), alice);
    }

    // ============ Current Index Handling Tests ============

    function test_RemoveBeforeCurrentIndex_AdjustsIndex() public {
        _setupThreeSequencers();

        // Rotate to bob (index 1)
        manager.rotateSequencer();
        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateSequencer();
        assertEq(manager.currentIndex(), 1);

        // Remove alice (index 0, before currentIndex)
        curate.setClearingRequested(manager.itemIDFor(alice));
        manager.syncRemoveSequencer(alice);

        // currentIndex should be adjusted
        assertEq(manager.currentIndex(), 0);
    }

    function test_RemoveAtCurrentIndex_ResetsIndex() public {
        _setupThreeSequencers();

        // Rotate to charlie (index 2)
        manager.rotateSequencer();
        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateSequencer();
        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateSequencer();
        assertEq(manager.currentIndex(), 2);

        // Remove charlie (at currentIndex, which is also lastIndex)
        curate.setClearingRequested(manager.itemIDFor(charlie));
        manager.syncRemoveSequencer(charlie);

        // currentIndex should wrap to 0
        assertEq(manager.currentIndex(), 0);
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

    function test_ActiveSequencerCount() public {
        assertEq(manager.activeSequencerCount(), 0);

        _registerSequencer(alice);
        manager.syncAddSequencer(alice);
        assertEq(manager.activeSequencerCount(), 1);

        _registerSequencer(bob);
        manager.syncAddSequencer(bob);
        assertEq(manager.activeSequencerCount(), 2);
    }

    function test_GetActiveSequencers() public {
        _setupThreeSequencers();

        address[] memory sequencers = manager.getActiveSequencers();
        assertEq(sequencers.length, 3);
        assertEq(sequencers[0], alice);
        assertEq(sequencers[1], bob);
        assertEq(sequencers[2], charlie);
    }

    function test_CurrentSequencer_ReturnsZeroWhenEmpty() public view {
        assertEq(manager.currentSequencer(), address(0));
    }

    function test_CurrentSequencer_ReturnsCorrectAddress() public {
        _setupThreeSequencers();
        manager.rotateSequencer();

        assertEq(manager.currentSequencer(), alice);
    }

    function test_TimeUntilNextRotation() public {
        _setupThreeSequencers();

        // Initially should be 0 (can rotate immediately due to constructor setup)
        assertEq(manager.timeUntilNextRotation(), 0);

        manager.rotateSequencer();

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

    function test_SingleSequencer_RotatesBackToItself() public {
        _registerSequencer(alice);
        manager.syncAddSequencer(alice);

        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        manager.rotateSequencer();
        assertEq(manager.currentSequencer(), alice);
    }

    function test_SwapPopRemoval_MaintainsCorrectIndexes() public {
        _setupThreeSequencers();
        _registerSequencer(dave);
        manager.syncAddSequencer(dave);

        // Order: [alice, bob, charlie, dave]
        // Remove bob -> [alice, dave, charlie]
        curate.setClearingRequested(manager.itemIDFor(bob));
        manager.syncRemoveSequencer(bob);

        assertEq(manager.activeSequencerCount(), 3);
        assertEq(manager.indexOf(alice), 0);
        assertEq(manager.indexOf(dave), 1);
        assertEq(manager.indexOf(charlie), 2);

        address[] memory sequencers = manager.getActiveSequencers();
        assertEq(sequencers[0], alice);
        assertEq(sequencers[1], dave);
        assertEq(sequencers[2], charlie);
    }

    function test_BatcherHash_V0Format() public {
        _registerSequencer(alice);
        manager.syncAddSequencer(alice);
        manager.rotateSequencer();

        bytes32 expected = bytes32(uint256(uint160(alice)));
        assertEq(systemConfig.batcherHash(), expected);

        // Verify we can extract the address back
        address extracted = address(uint160(uint256(systemConfig.batcherHash())));
        assertEq(extracted, alice);
    }

    // ============ Fuzz Tests ============

    function testFuzz_ItemIDFor_Deterministic(address sequencer) public view {
        bytes32 id1 = manager.itemIDFor(sequencer);
        bytes32 id2 = manager.itemIDFor(sequencer);
        assertEq(id1, id2);
    }

    function testFuzz_AddRemoveSequencer(address sequencer) public {
        vm.assume(sequencer != address(0));

        _registerSequencer(sequencer);
        manager.syncAddSequencer(sequencer);

        assertTrue(manager.isActive(sequencer));

        curate.setClearingRequested(manager.itemIDFor(sequencer));
        manager.syncRemoveSequencer(sequencer);

        assertFalse(manager.isActive(sequencer));
    }

    // ============ Helper Functions ============

    function _registerSequencer(address sequencer) internal {
        bytes memory data = abi.encode(sequencer);
        curate.registerItemDirectly(data);
    }

    function _setupThreeSequencers() internal {
        _registerSequencer(alice);
        _registerSequencer(bob);
        _registerSequencer(charlie);

        manager.syncAddSequencer(alice);
        manager.syncAddSequencer(bob);
        manager.syncAddSequencer(charlie);
    }
}
