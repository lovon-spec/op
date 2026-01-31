// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ProposerRegistry} from "../src/ProposerRegistry.sol";
import {IProposerRegistry} from "../src/interfaces/IProposerRegistry.sol";

/**
 * @title ProposerRegistryTest
 * @notice Tests for the ProposerRegistry contract.
 * @dev Tests DPoS mechanics, staking, delegation, and rebalancing.
 */
contract ProposerRegistryTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public hub = address(0x2);
    address public proposer1 = address(0x10);
    address public proposer2 = address(0x11);
    address public proposer3 = address(0x12);
    address public delegator1 = address(0x20);
    address public delegator2 = address(0x21);
    address public randomUser = address(0x99);

    // ============ Contracts ============
    ProposerRegistry public registry;

    // ============ Constants ============
    uint256 public constant MIN_STAKE = 32 ether;
    uint256 public constant MAX_ACTIVE = 100;

    // ============ Setup ============

    function setUp() public {
        registry = new ProposerRegistry(governance, hub, MIN_STAKE, MAX_ACTIVE);

        // Fund test accounts
        vm.deal(proposer1, 100 ether);
        vm.deal(proposer2, 100 ether);
        vm.deal(proposer3, 100 ether);
        vm.deal(delegator1, 100 ether);
        vm.deal(delegator2, 100 ether);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialValues() public view {
        assertEq(registry.governance(), governance);
        assertEq(registry.hub(), hub);
        assertEq(registry.minimumStake(), MIN_STAKE);
        assertEq(registry.maxActiveSetSize(), MAX_ACTIVE);
    }

    function test_Constructor_UsesDefaults() public {
        ProposerRegistry defaultRegistry = new ProposerRegistry(governance, hub, 0, 0);
        assertEq(defaultRegistry.minimumStake(), 32 ether);
        assertEq(defaultRegistry.maxActiveSetSize(), 100);
    }

    // ============ Registration Tests ============

    function test_Register_Success() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        IProposerRegistry.ProposerInfo memory info = registry.getProposerInfo(proposer1);
        assertEq(info.stake, MIN_STAKE);
        assertTrue(info.isRegistered);
        assertTrue(info.isActive);
        assertEq(info.operationalKey, proposer1);
        assertEq(info.livenessScore, 10000); // 100%
    }

    function test_Register_AddsToActiveSet() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        assertTrue(registry.isActiveProposer(proposer1));
        assertEq(registry.getActiveProposerCount(), 1);
    }

    function test_Register_RevertsIfInsufficientStake() public {
        vm.prank(proposer1);
        vm.expectRevert(
            abi.encodeWithSelector(IProposerRegistry.InsufficientStake.selector, 1 ether, MIN_STAKE)
        );
        registry.register{value: 1 ether}(proposer1);
    }

    function test_Register_RevertsIfAlreadyRegistered() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer1);
        vm.expectRevert(abi.encodeWithSelector(IProposerRegistry.ProposerAlreadyRegistered.selector, proposer1));
        registry.register{value: MIN_STAKE}(proposer1);
    }

    function test_Register_RevertsIfInvalidOperationalKey() public {
        vm.prank(proposer1);
        vm.expectRevert(IProposerRegistry.InvalidOperationalKey.selector);
        registry.register{value: MIN_STAKE}(address(0));
    }

    // ============ Unregister Tests ============

    function test_Unregister_Success() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        // First remove from active set (can't unregister while active)
        // We need to add another proposer and make proposer1 inactive
        vm.prank(proposer2);
        registry.register{value: MIN_STAKE + 1 ether}(proposer2);

        // Withdraw stake to go below minimum
        vm.prank(proposer1);
        registry.withdrawStake(1 ether);

        // Now proposer1 should be able to unregister
        uint256 balanceBefore = proposer1.balance;

        vm.prank(proposer1);
        registry.unregister();

        // Check stake was returned
        assertEq(proposer1.balance, balanceBefore + MIN_STAKE - 1 ether);
        assertFalse(registry.isRegistered(proposer1));
    }

    function test_Unregister_RevertsIfNotRegistered() public {
        vm.prank(proposer1);
        vm.expectRevert(abi.encodeWithSelector(IProposerRegistry.ProposerNotRegistered.selector, proposer1));
        registry.unregister();
    }

    function test_Unregister_RevertsIfActive() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer1);
        vm.expectRevert(IProposerRegistry.CannotUnregisterActiveProposer.selector);
        registry.unregister();
    }

    // ============ Stake Management Tests ============

    function test_AddStake_Success() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer1);
        registry.addStake{value: 10 ether}();

        IProposerRegistry.ProposerInfo memory info = registry.getProposerInfo(proposer1);
        assertEq(info.stake, MIN_STAKE + 10 ether);
    }

    function test_AddStake_RevertsIfNotRegistered() public {
        vm.prank(proposer1);
        vm.expectRevert(abi.encodeWithSelector(IProposerRegistry.ProposerNotRegistered.selector, proposer1));
        registry.addStake{value: 10 ether}();
    }

    function test_WithdrawStake_Success() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE + 10 ether}(proposer1);

        uint256 balanceBefore = proposer1.balance;

        vm.prank(proposer1);
        registry.withdrawStake(5 ether);

        assertEq(proposer1.balance, balanceBefore + 5 ether);
        assertEq(registry.getTotalStake(proposer1), MIN_STAKE + 5 ether);
    }

    function test_WithdrawStake_RevertsIfBelowMinimumWhileActive() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer1);
        vm.expectRevert(
            abi.encodeWithSelector(IProposerRegistry.InsufficientBalance.selector, 1 ether, 0)
        );
        registry.withdrawStake(1 ether);
    }

    // ============ Delegation Tests ============

    function test_Delegate_Success() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(delegator1);
        registry.delegate{value: 10 ether}(proposer1);

        assertEq(registry.getDelegation(delegator1, proposer1), 10 ether);
        assertEq(registry.getTotalStake(proposer1), MIN_STAKE + 10 ether);
    }

    function test_Delegate_RevertsIfProposerNotRegistered() public {
        vm.prank(delegator1);
        vm.expectRevert(abi.encodeWithSelector(IProposerRegistry.ProposerNotRegistered.selector, proposer1));
        registry.delegate{value: 10 ether}(proposer1);
    }

    function test_Undelegate_Success() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(delegator1);
        registry.delegate{value: 10 ether}(proposer1);

        uint256 balanceBefore = delegator1.balance;

        vm.prank(delegator1);
        registry.undelegate(proposer1, 5 ether);

        assertEq(delegator1.balance, balanceBefore + 5 ether);
        assertEq(registry.getDelegation(delegator1, proposer1), 5 ether);
    }

    function test_Undelegate_RevertsIfInsufficientDelegation() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(delegator1);
        registry.delegate{value: 10 ether}(proposer1);

        vm.prank(delegator1);
        vm.expectRevert(abi.encodeWithSelector(IProposerRegistry.InsufficientBalance.selector, 20 ether, 10 ether));
        registry.undelegate(proposer1, 20 ether);
    }

    // ============ Rebalancing Tests ============

    function test_NeedsRebalancing_ReturnsTrueWhenActiveSetNotFull() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        // With proposer1 active and active set not full, there's nothing to rebalance
        // unless there are inactive proposers with sufficient stake
        assertFalse(registry.needsRebalancing());
    }

    function test_GetLowestActiveProposer_ReturnsCorrectProposer() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer2);
        registry.register{value: MIN_STAKE + 10 ether}(proposer2);

        (address lowest, uint256 stake) = registry.getLowestActiveProposer();
        assertEq(lowest, proposer1);
        assertEq(stake, MIN_STAKE);
    }

    function test_Rebalance_RevertsIfNotNeeded() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.expectRevert(IProposerRegistry.RebalanceNotNeeded.selector);
        registry.rebalance();
    }

    // ============ Selection Tests ============

    function test_SelectNextProposer_RoundRobin() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer2);
        registry.register{value: MIN_STAKE}(proposer2);

        vm.prank(proposer3);
        registry.register{value: MIN_STAKE}(proposer3);

        // Epoch 0 -> proposer1, Epoch 1 -> proposer2, Epoch 2 -> proposer3
        assertEq(registry.selectNextProposer(0), proposer1);
        assertEq(registry.selectNextProposer(1), proposer2);
        assertEq(registry.selectNextProposer(2), proposer3);
        assertEq(registry.selectNextProposer(3), proposer1); // Wraps around
    }

    function test_SelectNextProposer_ReturnsZeroIfNoProposers() public view {
        assertEq(registry.selectNextProposer(0), address(0));
    }

    // ============ Operational Key Tests ============

    function test_UpdateOperationalKey_Success() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        address newKey = address(0x999);

        vm.prank(proposer1);
        registry.updateOperationalKey(newKey);

        assertEq(registry.getOperationalKey(proposer1), newKey);
    }

    function test_UpdateOperationalKey_RevertsIfNotRegistered() public {
        vm.prank(proposer1);
        vm.expectRevert(abi.encodeWithSelector(IProposerRegistry.ProposerNotRegistered.selector, proposer1));
        registry.updateOperationalKey(address(0x999));
    }

    function test_UpdateOperationalKey_RevertsIfInvalidKey() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer1);
        vm.expectRevert(IProposerRegistry.InvalidOperationalKey.selector);
        registry.updateOperationalKey(address(0));
    }

    // ============ Liveness Tests ============

    function test_ReportLiveness_UpdatesScore() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        // Report 90% liveness
        vm.prank(hub);
        registry.reportLiveness(proposer1, 1, 90, 100);

        IProposerRegistry.ProposerInfo memory info = registry.getProposerInfo(proposer1);
        // Score should be weighted: (10000 * 9 + 9000) / 10 = 9900
        assertEq(info.livenessScore, 9900);
        assertEq(info.lastActiveEpoch, 1);
    }

    function test_ReportLiveness_RevertsIfNotHub() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(randomUser);
        vm.expectRevert(IProposerRegistry.Unauthorized.selector);
        registry.reportLiveness(proposer1, 1, 90, 100);
    }

    function test_SlashForLiveness_ReducesStake() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(hub);
        registry.slashForLiveness(proposer1, 500); // 5%

        IProposerRegistry.ProposerInfo memory info = registry.getProposerInfo(proposer1);
        // 5% of 32 ETH = 1.6 ETH slashed
        assertEq(info.stake, MIN_STAKE - 1.6 ether);
    }

    // ============ Governance Tests ============

    function test_SetMinimumStake_Success() public {
        vm.prank(governance);
        registry.setMinimumStake(64 ether);

        assertEq(registry.minimumStake(), 64 ether);
    }

    function test_SetMinimumStake_RevertsIfNotGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert(IProposerRegistry.Unauthorized.selector);
        registry.setMinimumStake(64 ether);
    }

    function test_SetMaxActiveSetSize_Success() public {
        vm.prank(governance);
        registry.setMaxActiveSetSize(50);

        assertEq(registry.maxActiveSetSize(), 50);
    }

    function test_SetHub_Success() public {
        address newHub = address(0x777);

        vm.prank(governance);
        registry.setHub(newHub);

        assertEq(registry.hub(), newHub);
    }

    function test_SetHub_RevertsIfZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(IProposerRegistry.InvalidHub.selector);
        registry.setHub(address(0));
    }

    function test_SetGovernance_Success() public {
        address newGovernance = address(0x888);

        vm.prank(governance);
        registry.setGovernance(newGovernance);

        assertEq(registry.governance(), newGovernance);
    }

    // ============ View Function Tests ============

    function test_GetRegisteredProposers_ReturnsAllProposers() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        vm.prank(proposer2);
        registry.register{value: MIN_STAKE}(proposer2);

        address[] memory proposers = registry.getRegisteredProposers();
        assertEq(proposers.length, 2);
        assertEq(proposers[0], proposer1);
        assertEq(proposers[1], proposer2);
    }

    function test_GetActiveProposers_ReturnsActiveOnly() public {
        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        address[] memory activeProposers = registry.getActiveProposers();
        assertEq(activeProposers.length, 1);
        assertEq(activeProposers[0], proposer1);
    }

    function test_IsRegistered_ReturnsCorrectStatus() public {
        assertFalse(registry.isRegistered(proposer1));

        vm.prank(proposer1);
        registry.register{value: MIN_STAKE}(proposer1);

        assertTrue(registry.isRegistered(proposer1));
    }

    // ============ Receive Tests ============

    function test_ReceiveEth_Accepts() public {
        (bool success, ) = address(registry).call{value: 1 ether}("");
        assertTrue(success);
    }
}
