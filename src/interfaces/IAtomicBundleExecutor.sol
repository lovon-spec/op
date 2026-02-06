// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAtomicBundleExecutor
 * @notice Interface for the Atomic Bundle Executor deployed on each L2 Spoke chain.
 * @dev This contract is the entry point for all atomic bundle transactions on L2.
 *      Users and sequencers route bundle operations through this executor instead of
 *      calling target contracts directly. The executor wraps each call so that:
 *
 *      1. The outer transaction ALWAYS succeeds (no revert)
 *      2. The inner call result (success/failure) is recorded via a BundleResult event
 *      3. The event log is provable on L1 via Merkle proofs for fraud proof verification
 *
 *      This design enables Optimistic State Atomicity: if the sequencer executes a
 *      bundle where operation A succeeds on Chain A but operation B fails on Chain B,
 *      a challenger can prove the status mismatch on L1 and slash the sequencer.
 *
 *      The sequencer is therefore incentivized to simulate bundles off-chain and only
 *      include bundles where ALL operations succeed or ALL operations fail.
 */
interface IAtomicBundleExecutor {
    // ============ Events ============

    /// @notice Emitted for every bundle operation executed through this contract.
    /// @param bundleId The cross-chain bundle identifier
    /// @param target The target contract that was called
    /// @param success Whether the inner call succeeded
    /// @param returnData The return data from the inner call (truncated to 256 bytes on failure)
    event BundleResult(
        bytes32 indexed bundleId,
        address indexed target,
        bool success,
        bytes returnData
    );

    /// @notice Emitted when an executor is registered for a chain
    /// @param chainId The chain ID this executor is deployed on
    /// @param executor The executor contract address
    event ExecutorRegistered(uint256 indexed chainId, address indexed executor);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroBundleId();
    error EmptyCallData();
    error ExecutionWindowClosed();
    error NotSequencer();

    // ============ Functions ============

    /// @notice Execute a single bundle operation on this chain.
    /// @dev The outer transaction always succeeds. The inner call result is
    ///      recorded in the BundleResult event. This allows the fraud proof
    ///      system to verify execution outcomes across chains.
    /// @param target The target contract to call
    /// @param data The calldata for the target contract
    /// @param bundleId The cross-chain bundle identifier
    function executeBundle(
        address target,
        bytes calldata data,
        bytes32 bundleId
    ) external payable;

    /// @notice Execute multiple bundle operations atomically on this chain.
    /// @dev All operations for the same bundle on this chain are executed in
    ///      sequence. A single BundleResult event is emitted with the aggregate
    ///      success status (all must succeed for success=true).
    /// @param targets The target contracts to call
    /// @param datas The calldatas for each target
    /// @param values The ETH values to send with each call
    /// @param bundleId The cross-chain bundle identifier
    function executeBundleBatch(
        address[] calldata targets,
        bytes[] calldata datas,
        uint256[] calldata values,
        bytes32 bundleId
    ) external payable;

    /// @notice Query the result of a bundle execution on this chain.
    /// @param bundleId The cross-chain bundle identifier
    /// @return executed Whether the bundle was executed on this chain
    /// @return success Whether the execution succeeded
    /// @return blockNumber The block in which it was executed
    function getBundleResult(bytes32 bundleId)
        external
        view
        returns (bool executed, bool success, uint256 blockNumber);
}
