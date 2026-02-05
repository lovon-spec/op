// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {CrossChainBundleRegistry} from "../src/bundle/CrossChainBundleRegistry.sol";
import {BundleEscrow} from "../src/bundle/BundleEscrow.sol";
import {ICrossChainBundle} from "../src/interfaces/ICrossChainBundle.sol";
import {IBundleEscrow} from "../src/interfaces/IBundleEscrow.sol";
import {MockHub} from "./mocks/MockHub.sol";

/**
 * @title CrossChainBundleTest
 * @notice Tests for CrossChainBundleRegistry and BundleEscrow.
 */
contract CrossChainBundleTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public sequencer = address(0x10);
    address public searcher = address(0x20);
    address public reporter = address(0x30);

    // ============ Contracts ============
    MockHub public hub;
    BundleEscrow public escrow;
    CrossChainBundleRegistry public bundleRegistry;

    // ============ Constants ============
    uint256 constant MIN_DEADLINE = 5 minutes;

    // ============ Setup ============

    function setUp() public {
        hub = new MockHub();
        hub.setCurrentProposer(sequencer);

        escrow = new BundleEscrow(address(0), governance, 0.1 ether);
        bundleRegistry = new CrossChainBundleRegistry(
            address(hub),
            address(escrow),
            address(0), // no fraud proof verifier for basic tests
            governance,
            MIN_DEADLINE
        );

        // Set bundle registry as authorized caller on escrow
        vm.prank(governance);
        escrow.setBundleRegistry(address(bundleRegistry));

        // Fund test accounts
        vm.deal(sequencer, 100 ether);
        vm.deal(searcher, 100 ether);
        vm.deal(reporter, 100 ether);
    }

    // ============ Bundle Commitment Tests ============

    function test_CommitBundle_Success() public {
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 10;
        chainIds[1] = 42161;

        bytes32 opsHash = keccak256("test-operations");
        uint256 deadline = block.timestamp + 10 minutes;

        vm.prank(sequencer);
        bytes32 bundleId = bundleRegistry.commitBundle{value: 1 ether}(
            opsHash,
            chainIds,
            deadline
        );

        assertTrue(bundleId != bytes32(0));

        ICrossChainBundle.BundleCommitment memory bundle = bundleRegistry.getBundle(bundleId);
        assertEq(bundle.sequencer, sequencer);
        assertEq(bundle.operationsHash, opsHash);
        assertEq(bundle.targetChainIds.length, 2);
        assertEq(bundle.deadline, deadline);
        assertEq(bundle.tip, 1 ether);
        assertEq(uint256(bundle.status), uint256(ICrossChainBundle.BundleStatus.Committed));
        assertEq(bundle.chainCount, 2);
    }

    function test_CommitBundle_RevertsIfNotSequencer() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 10;

        vm.prank(searcher);
        vm.expectRevert(ICrossChainBundle.NotActiveSequencer.selector);
        bundleRegistry.commitBundle(
            keccak256("test"),
            chainIds,
            block.timestamp + 10 minutes
        );
    }

    function test_CommitBundle_RevertsIfZeroChains() public {
        uint256[] memory chainIds = new uint256[](0);

        vm.prank(sequencer);
        vm.expectRevert(ICrossChainBundle.ZeroChainCount.selector);
        bundleRegistry.commitBundle(
            keccak256("test"),
            chainIds,
            block.timestamp + 10 minutes
        );
    }

    function test_CommitBundle_RevertsIfDeadlineTooSoon() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 10;

        vm.prank(sequencer);
        vm.expectRevert(ICrossChainBundle.DeadlineExpired.selector);
        bundleRegistry.commitBundle(
            keccak256("test"),
            chainIds,
            block.timestamp + 1 minutes // Too soon (needs 5 min)
        );
    }

    function test_CommitBundle_RevertsIfInvalidOpsHash() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 10;

        vm.prank(sequencer);
        vm.expectRevert(ICrossChainBundle.InvalidOperationsHash.selector);
        bundleRegistry.commitBundle(
            bytes32(0),
            chainIds,
            block.timestamp + 10 minutes
        );
    }

    // ============ Chain Execution Confirmation Tests ============

    function test_ConfirmChainExecution_Success() public {
        bytes32 bundleId = _commitTestBundle();

        bundleRegistry.confirmChainExecution(
            bundleId,
            10, // chainId
            12345, // blockNumber
            hex"deadbeef" // proof
        );

        assertTrue(bundleRegistry.isChainConfirmed(bundleId, 10));

        ICrossChainBundle.ChainExecutionProof memory proof =
            bundleRegistry.getChainExecution(bundleId, 10);
        assertEq(proof.blockNumber, 12345);
        assertTrue(proof.confirmed);
    }

    function test_ConfirmChainExecution_RevertsIfBundleNotFound() public {
        vm.expectRevert(ICrossChainBundle.BundleNotFound.selector);
        bundleRegistry.confirmChainExecution(
            bytes32(uint256(999)),
            10,
            12345,
            hex"deadbeef"
        );
    }

    function test_ConfirmChainExecution_RevertsIfChainNotInBundle() public {
        bytes32 bundleId = _commitTestBundle();

        vm.expectRevert(ICrossChainBundle.ChainNotInBundle.selector);
        bundleRegistry.confirmChainExecution(
            bundleId,
            999, // Not in bundle
            12345,
            hex"deadbeef"
        );
    }

    function test_ConfirmChainExecution_RevertsIfAlreadyConfirmed() public {
        bytes32 bundleId = _commitTestBundle();

        bundleRegistry.confirmChainExecution(bundleId, 10, 12345, hex"deadbeef");

        vm.expectRevert(ICrossChainBundle.AlreadyConfirmed.selector);
        bundleRegistry.confirmChainExecution(bundleId, 10, 12346, hex"cafe");
    }

    // ============ Bundle Completion Tests ============

    function test_CompleteBundle_Success() public {
        bytes32 bundleId = _commitTestBundle();

        // Confirm both chains
        bundleRegistry.confirmChainExecution(bundleId, 10, 12345, hex"aa");
        bundleRegistry.confirmChainExecution(bundleId, 42161, 67890, hex"bb");

        bundleRegistry.completeBundle(bundleId);

        assertEq(
            uint256(bundleRegistry.getBundleStatus(bundleId)),
            uint256(ICrossChainBundle.BundleStatus.Executed)
        );
    }

    function test_CompleteBundle_RevertsIfNotAllConfirmed() public {
        bytes32 bundleId = _commitTestBundle();

        // Only confirm one chain
        bundleRegistry.confirmChainExecution(bundleId, 10, 12345, hex"aa");

        vm.expectRevert(ICrossChainBundle.NotAllChainsConfirmed.selector);
        bundleRegistry.completeBundle(bundleId);
    }

    // ============ Bundle Expiry Tests ============

    function test_ExpireBundle_Success() public {
        bytes32 bundleId = _commitTestBundle();

        // Warp past deadline
        vm.warp(block.timestamp + 11 minutes);

        bundleRegistry.expireBundle(bundleId);

        assertEq(
            uint256(bundleRegistry.getBundleStatus(bundleId)),
            uint256(ICrossChainBundle.BundleStatus.Expired)
        );
    }

    function test_ExpireBundle_RevertsIfNotExpired() public {
        bytes32 bundleId = _commitTestBundle();

        vm.expectRevert(ICrossChainBundle.DeadlineNotExpired.selector);
        bundleRegistry.expireBundle(bundleId);
    }

    // ============ Bundle Cancellation Tests ============

    function test_CancelBundle_BySequencer() public {
        bytes32 bundleId = _commitTestBundle();

        vm.prank(sequencer);
        bundleRegistry.cancelBundle(bundleId);

        assertEq(
            uint256(bundleRegistry.getBundleStatus(bundleId)),
            uint256(ICrossChainBundle.BundleStatus.Cancelled)
        );
    }

    function test_CancelBundle_ByGovernance() public {
        bytes32 bundleId = _commitTestBundle();

        vm.prank(governance);
        bundleRegistry.cancelBundle(bundleId);

        assertEq(
            uint256(bundleRegistry.getBundleStatus(bundleId)),
            uint256(ICrossChainBundle.BundleStatus.Cancelled)
        );
    }

    // ============ Violation Reporting Tests ============

    function test_ReportViolation_Success() public {
        bytes32 bundleId = _commitTestBundle();

        bundleRegistry.reportViolation(
            bundleId,
            hex"f4a0d0400f",
            "Bundle not executed correctly"
        );

        assertEq(
            uint256(bundleRegistry.getBundleStatus(bundleId)),
            uint256(ICrossChainBundle.BundleStatus.Violated)
        );
    }

    // ============ View Function Tests ============

    function test_GetPendingBundleCount() public {
        assertEq(bundleRegistry.getPendingBundleCount(), 0);

        _commitTestBundle();
        assertEq(bundleRegistry.getPendingBundleCount(), 1);

        _commitTestBundle();
        assertEq(bundleRegistry.getPendingBundleCount(), 2);
    }

    function test_GetSequencerBundles() public {
        bytes32 bundleId1 = _commitTestBundle();
        bytes32 bundleId2 = _commitTestBundle();

        bytes32[] memory bundles = bundleRegistry.getSequencerBundles(sequencer);
        assertEq(bundles.length, 2);
        assertEq(bundles[0], bundleId1);
        assertEq(bundles[1], bundleId2);
    }

    // ============ Escrow Tests ============

    function test_Escrow_DepositTip() public {
        bytes32 bundleId = keccak256("test-bundle");

        vm.prank(searcher);
        escrow.depositTip{value: 1 ether}(bundleId);

        IBundleEscrow.EscrowEntry memory entry = escrow.getEscrow(bundleId);
        assertEq(entry.tip, 1 ether);
        assertEq(entry.submitter, searcher);
    }

    function test_Escrow_PostBond() public {
        bytes32 bundleId = keccak256("test-bundle");

        vm.prank(sequencer);
        escrow.postBond{value: 0.5 ether}(bundleId);

        IBundleEscrow.EscrowEntry memory entry = escrow.getEscrow(bundleId);
        assertEq(entry.bond, 0.5 ether);
        assertEq(entry.sequencer, sequencer);
    }

    function test_Escrow_PostBond_RevertsIfInsufficient() public {
        bytes32 bundleId = keccak256("test-bundle");

        vm.prank(sequencer);
        vm.expectRevert(IBundleEscrow.InsufficientBond.selector);
        escrow.postBond{value: 0.01 ether}(bundleId);
    }

    function test_Escrow_ReleaseTip() public {
        bytes32 bundleId = keccak256("test-bundle");

        // Deposit tip
        vm.prank(searcher);
        escrow.depositTip{value: 1 ether}(bundleId);

        // Post bond so sequencer is set
        vm.prank(sequencer);
        escrow.postBond{value: 0.5 ether}(bundleId);

        uint256 seqBalBefore = sequencer.balance;

        // Release tip (only by bundle registry)
        vm.prank(address(bundleRegistry));
        escrow.releaseTip(bundleId);

        assertEq(sequencer.balance, seqBalBefore + 1 ether);
    }

    function test_Escrow_SlashBond() public {
        bytes32 bundleId = keccak256("test-bundle");

        vm.prank(sequencer);
        escrow.postBond{value: 1 ether}(bundleId);

        uint256 reporterBalBefore = reporter.balance;
        uint256 govBalBefore = governance.balance;

        vm.prank(address(bundleRegistry));
        escrow.slashBond(bundleId, reporter);

        // Reporter gets 10% reward
        assertEq(reporter.balance, reporterBalBefore + 0.1 ether);
        // Governance gets 90% remaining
        assertEq(governance.balance, govBalBefore + 0.9 ether);
    }

    // ============ Governance Tests ============

    function test_SetEscrow() public {
        address newEscrow = address(0x999);

        vm.prank(governance);
        bundleRegistry.setEscrow(newEscrow);

        assertEq(bundleRegistry.escrow(), newEscrow);
    }

    function test_SetMinDeadlineDuration() public {
        vm.prank(governance);
        bundleRegistry.setMinDeadlineDuration(10 minutes);

        assertEq(bundleRegistry.minDeadlineDuration(), 10 minutes);
    }

    // ============ Helper Functions ============

    function _commitTestBundle() internal returns (bytes32) {
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 10;
        chainIds[1] = 42161;

        vm.prank(sequencer);
        return bundleRegistry.commitBundle{value: 0.1 ether}(
            keccak256(abi.encode("ops", block.timestamp, gasleft())),
            chainIds,
            block.timestamp + 10 minutes
        );
    }
}
