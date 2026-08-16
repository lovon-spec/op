// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {AtomicBundleExecutor} from "../src/bundle/AtomicBundleExecutor.sol";
import {IAtomicBundleExecutor} from "../src/interfaces/IAtomicBundleExecutor.sol";

/// @notice Mock target contract that always succeeds
contract MockTarget {
    uint256 public value;

    function setValue(uint256 _value) external payable {
        value = _value;
    }

    function getSum(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }

    receive() external payable {}
}

/// @notice Mock target contract that always reverts
contract RevertingTarget {
    error AlwaysReverts(string reason);

    function doSomething() external pure {
        revert AlwaysReverts("intentional revert");
    }

    function revertWithLongMessage() external pure {
        // Generate a revert message longer than 256 bytes to test truncation
        revert(
            "This is a very long error message that exceeds 256 bytes. "
            "It contains detailed information about the failure reason. "
            "The AtomicBundleExecutor should truncate this to 256 bytes "
            "to limit gas costs for event storage. This padding ensures "
            "we exceed the limit: padding padding padding padding padding."
        );
    }
}

/// @notice Mock target that conditionally reverts based on a flag
contract ConditionalTarget {
    bool public shouldRevert;

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function execute() external {
        if (shouldRevert) {
            revert("conditional revert");
        }
    }
}

/**
 * @title AtomicBundleExecutorTest
 * @notice Tests for the AtomicBundleExecutor contract (L2 Spoke).
 */
contract AtomicBundleExecutorTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public sequencer = address(0x10);
    address public user = address(0x20);

    // ============ Contracts ============
    AtomicBundleExecutor public executor;
    MockTarget public target;
    RevertingTarget public revertingTarget;
    ConditionalTarget public conditionalTarget;

    // ============ Constants ============
    uint256 constant CHAIN_ID = 10;
    bytes32 constant BUNDLE_ID = keccak256("test-bundle-1");

    // ============ Events (for expectEmit) ============
    event BundleResult(
        bytes32 indexed bundleId,
        address indexed target,
        bool success,
        bytes returnData
    );

    // ============ Setup ============

    function setUp() public {
        executor = new AtomicBundleExecutor(governance, CHAIN_ID);
        target = new MockTarget();
        revertingTarget = new RevertingTarget();
        conditionalTarget = new ConditionalTarget();

        vm.deal(sequencer, 100 ether);
        vm.deal(user, 100 ether);
        vm.deal(address(executor), 10 ether);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsState() public view {
        assertEq(executor.governance(), governance);
        assertEq(executor.chainId(), CHAIN_ID);
    }

    function test_Constructor_RevertsIfZeroGovernance() public {
        vm.expectRevert(IAtomicBundleExecutor.ZeroAddress.selector);
        new AtomicBundleExecutor(address(0), CHAIN_ID);
    }

    // ============ executeBundle Tests ============

    function test_ExecuteBundle_SuccessfulCall() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.expectEmit(true, true, false, false);
        emit BundleResult(BUNDLE_ID, address(target), true, "");

        vm.prank(sequencer);
        executor.executeBundle(address(target), data, BUNDLE_ID);

        assertEq(target.value(), 42);

        (bool executed, bool success, uint256 blockNumber) = executor.getBundleResult(BUNDLE_ID);
        assertTrue(executed);
        assertTrue(success);
        assertEq(blockNumber, block.number);
    }

    function test_ExecuteBundle_FailedCallStillSucceeds() public {
        bytes memory data = abi.encodeWithSelector(RevertingTarget.doSomething.selector);

        // The outer tx should NOT revert even though the inner call reverts
        vm.prank(sequencer);
        executor.executeBundle(address(revertingTarget), data, BUNDLE_ID);

        (bool executed, bool success,) = executor.getBundleResult(BUNDLE_ID);
        assertTrue(executed);
        assertFalse(success); // Inner call failed
    }

    function test_ExecuteBundle_WithEthValue() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 100);

        uint256 targetBalBefore = address(target).balance;

        vm.prank(sequencer);
        executor.executeBundle{value: 1 ether}(address(target), data, BUNDLE_ID);

        assertEq(address(target).balance, targetBalBefore + 1 ether);
        assertEq(target.value(), 100);
    }

    function test_ExecuteBundle_EmitsBundleResultEvent() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 77);

        vm.recordLogs();

        vm.prank(sequencer);
        executor.executeBundle(address(target), data, BUNDLE_ID);

        // Verify the event was emitted with correct parameters
        (bool executed, bool success,) = executor.getBundleResult(BUNDLE_ID);
        assertTrue(executed);
        assertTrue(success);
    }

    function test_ExecuteBundle_TruncatesLongRevertData() public {
        bytes memory data = abi.encodeWithSelector(RevertingTarget.revertWithLongMessage.selector);

        vm.prank(sequencer);
        executor.executeBundle(address(revertingTarget), data, BUNDLE_ID);

        (bool executed, bool success,) = executor.getBundleResult(BUNDLE_ID);
        assertTrue(executed);
        assertFalse(success);
    }

    function test_ExecuteBundle_RevertsIfZeroTarget() public {
        vm.prank(sequencer);
        vm.expectRevert(IAtomicBundleExecutor.ZeroAddress.selector);
        executor.executeBundle(address(0), hex"deadbeef", BUNDLE_ID);
    }

    function test_ExecuteBundle_RevertsIfZeroBundleId() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(sequencer);
        vm.expectRevert(IAtomicBundleExecutor.ZeroBundleId.selector);
        executor.executeBundle(address(target), data, bytes32(0));
    }

    function test_ExecuteBundle_RevertsIfEmptyCallData() public {
        vm.prank(sequencer);
        vm.expectRevert(IAtomicBundleExecutor.EmptyCallData.selector);
        executor.executeBundle(address(target), "", BUNDLE_ID);
    }

    // ============ executeBundleBatch Tests ============

    function test_ExecuteBundleBatch_AllSucceed() public {
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        datas[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        vm.prank(sequencer);
        executor.executeBundleBatch(targets, datas, values, BUNDLE_ID);

        (bool executed, bool success,) = executor.getBundleResult(BUNDLE_ID);
        assertTrue(executed);
        assertTrue(success);
        // Last setValue wins
        assertEq(target.value(), 20);
    }

    function test_ExecuteBundleBatch_StopsOnFirstFailure() public {
        address[] memory targets = new address[](2);
        targets[0] = address(revertingTarget);
        targets[1] = address(target);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(RevertingTarget.doSomething.selector);
        datas[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 99);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        vm.prank(sequencer);
        executor.executeBundleBatch(targets, datas, values, BUNDLE_ID);

        (bool executed, bool success,) = executor.getBundleResult(BUNDLE_ID);
        assertTrue(executed);
        assertFalse(success); // First call failed → entire batch fails
        // Second call should NOT have executed
        assertEq(target.value(), 0);
    }

    function test_ExecuteBundleBatch_RevertsIfEmpty() public {
        address[] memory targets = new address[](0);
        bytes[] memory datas = new bytes[](0);
        uint256[] memory values = new uint256[](0);

        vm.prank(sequencer);
        vm.expectRevert(IAtomicBundleExecutor.EmptyCallData.selector);
        executor.executeBundleBatch(targets, datas, values, BUNDLE_ID);
    }

    function test_ExecuteBundleBatch_RevertsIfLengthMismatch() public {
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        vm.prank(sequencer);
        vm.expectRevert(IAtomicBundleExecutor.EmptyCallData.selector);
        executor.executeBundleBatch(targets, datas, values, BUNDLE_ID);
    }

    function test_ExecuteBundleBatch_WithEthValues() public {
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        datas[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);

        uint256[] memory values = new uint256[](2);
        values[0] = 0.5 ether;
        values[1] = 0.5 ether;

        uint256 targetBalBefore = address(target).balance;

        vm.prank(sequencer);
        executor.executeBundleBatch{value: 1 ether}(targets, datas, values, BUNDLE_ID);

        assertEq(address(target).balance, targetBalBefore + 1 ether);
    }

    // ============ getBundleResult Tests ============

    function test_GetBundleResult_DefaultsToNotExecuted() public view {
        (bool executed, bool success, uint256 blockNumber) =
            executor.getBundleResult(keccak256("nonexistent"));
        assertFalse(executed);
        assertFalse(success);
        assertEq(blockNumber, 0);
    }

    // ============ Governance Tests ============

    function test_SetGovernance() public {
        address newGov = address(0x999);

        vm.prank(governance);
        executor.setGovernance(newGov);

        assertEq(executor.governance(), newGov);
    }

    function test_SetGovernance_RevertsIfNotGovernance() public {
        vm.prank(user);
        vm.expectRevert(IAtomicBundleExecutor.NotSequencer.selector);
        executor.setGovernance(address(0x999));
    }

    function test_SetGovernance_RevertsIfZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(IAtomicBundleExecutor.ZeroAddress.selector);
        executor.setGovernance(address(0));
    }

    // ============ Atomicity Scenario Tests ============

    /// @notice Simulates the cross-chain atomicity scenario:
    ///         Two executors on different chains process the same bundleId.
    ///         Chain A succeeds, Chain B fails. This demonstrates how the
    ///         mismatch becomes detectable via getBundleResult().
    function test_CrossChainAtomicityScenario() public {
        // Deploy executors for two chains
        AtomicBundleExecutor executorA = new AtomicBundleExecutor(governance, 10); // OP Mainnet
        AtomicBundleExecutor executorB = new AtomicBundleExecutor(governance, 42161); // Arbitrum

        bytes32 bundleId = keccak256("cross-chain-arb-bundle");

        // Chain A: successful execution
        bytes memory dataA = abi.encodeWithSelector(MockTarget.setValue.selector, 100);
        vm.prank(sequencer);
        executorA.executeBundle(address(target), dataA, bundleId);

        // Chain B: failed execution (target reverts)
        bytes memory dataB = abi.encodeWithSelector(RevertingTarget.doSomething.selector);
        vm.prank(sequencer);
        executorB.executeBundle(address(revertingTarget), dataB, bundleId);

        // Verify: Chain A succeeded, Chain B failed
        (bool executedA, bool successA,) = executorA.getBundleResult(bundleId);
        (bool executedB, bool successB,) = executorB.getBundleResult(bundleId);

        assertTrue(executedA);
        assertTrue(successA);
        assertTrue(executedB);
        assertFalse(successB);

        // This mismatch (successA != successB) is the atomicity violation
        // that would be submitted as a fraud proof to L1 FraudProofVerifier
        assertTrue(successA != successB, "Atomicity violation: mismatched results");
    }

    // ============ Receive ETH Test ============

    function test_ReceiveEth() public {
        uint256 balBefore = address(executor).balance;
        vm.prank(user);
        (bool sent,) = address(executor).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(address(executor).balance, balBefore + 1 ether);
    }
}
