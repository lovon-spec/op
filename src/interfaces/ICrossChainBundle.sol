// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICrossChainBundle
 * @notice Interface for the Cross-Chain Bundle Registry - atomic multi-chain transaction execution.
 * @dev A cross-chain bundle is an ordered set of transaction commitments that must execute
 *      atomically across multiple chains. The active sequencer commits to including these
 *      bundles, and violations can be proven via fraud proofs.
 *
 *      Bundle lifecycle:
 *      1. Searcher/user submits bundle off-chain to the relay
 *      2. Active sequencer signs a commitment and posts it on-chain
 *      3. Sequencer includes transactions on each target chain within the deadline
 *      4. Anyone can verify execution and raise fraud proofs for violations
 *
 *      The registry is chain-agnostic: it stores commitments and proofs,
 *      while execution details are handled by chain-specific adapters.
 */
interface ICrossChainBundle {
    // ============ Enums ============

    /// @notice Bundle execution status
    enum BundleStatus {
        Committed,    // Sequencer committed to execute
        Executed,     // All chains confirmed execution
        Violated,     // Fraud proof accepted - bundle was not executed correctly
        Expired,      // Deadline passed without execution confirmation
        Cancelled     // Cancelled before deadline (by sequencer with penalty)
    }

    // ============ Structs ============

    /**
     * @notice A single chain-specific operation within a cross-chain bundle.
     * @param chainId Target chain for this operation
     * @param txHash Hash of the transaction to be included
     * @param index Ordering index within the bundle for this chain
     * @param gasLimit Maximum gas for this operation
     */
    struct BundleOperation {
        uint256 chainId;
        bytes32 txHash;
        uint256 index;
        uint256 gasLimit;
    }

    /**
     * @notice A cross-chain bundle commitment.
     * @param bundleId Unique identifier (hash of operations + nonce)
     * @param sequencer The sequencer who committed to this bundle
     * @param operationsHash Merkle root of the ordered BundleOperations
     * @param targetChainIds Array of chain IDs involved
     * @param deadline Block timestamp by which all operations must be included
     * @param tip Total tip offered for bundle execution (held in escrow)
     * @param status Current bundle status
     * @param commitTimestamp When the commitment was made
     * @param chainCount Number of chains involved
     */
    struct BundleCommitment {
        bytes32 bundleId;
        address sequencer;
        bytes32 operationsHash;
        uint256[] targetChainIds;
        uint256 deadline;
        uint256 tip;
        BundleStatus status;
        uint256 commitTimestamp;
        uint256 chainCount;
    }

    /**
     * @notice Per-chain execution proof for a bundle.
     * @param chainId The chain where execution occurred
     * @param blockNumber The block containing the transactions
     * @param txInclusionProof Merkle proof of transaction inclusion
     * @param confirmed Whether this chain's operations are confirmed
     */
    struct ChainExecutionProof {
        uint256 chainId;
        uint256 blockNumber;
        bytes txInclusionProof;
        bool confirmed;
    }

    // ============ Events ============

    event BundleCommitted(
        bytes32 indexed bundleId,
        address indexed sequencer,
        bytes32 operationsHash,
        uint256 deadline,
        uint256 tip,
        uint256 chainCount
    );

    event BundleExecutionConfirmed(
        bytes32 indexed bundleId,
        uint256 indexed chainId,
        uint256 blockNumber
    );

    event BundleCompleted(bytes32 indexed bundleId);

    event BundleViolation(
        bytes32 indexed bundleId,
        address indexed reporter,
        string reason
    );

    event BundleExpired(bytes32 indexed bundleId);

    event BundleCancelled(bytes32 indexed bundleId, uint256 penalty);

    // ============ Errors ============

    error BundleAlreadyExists();
    error BundleNotFound();
    error InvalidBundleStatus();
    error NotActiveSequencer();
    error DeadlineExpired();
    error DeadlineNotExpired();
    error InvalidOperationsHash();
    error ChainNotInBundle();
    error AlreadyConfirmed();
    error InvalidProof();
    error NotAllChainsConfirmed();
    error InsufficientTip();
    error ZeroChainCount();

    // ============ View Functions ============

    function getBundle(bytes32 _bundleId) external view returns (BundleCommitment memory);
    function getBundleStatus(bytes32 _bundleId) external view returns (BundleStatus);
    function getChainExecution(bytes32 _bundleId, uint256 _chainId) external view returns (ChainExecutionProof memory);
    function isChainConfirmed(bytes32 _bundleId, uint256 _chainId) external view returns (bool);
    function getPendingBundleCount() external view returns (uint256);
    function getSequencerBundles(address _sequencer) external view returns (bytes32[] memory);

    // ============ Sequencer Functions ============

    function commitBundle(
        bytes32 _operationsHash,
        uint256[] calldata _targetChainIds,
        uint256 _deadline
    ) external payable returns (bytes32 bundleId);

    function confirmChainExecution(
        bytes32 _bundleId,
        uint256 _chainId,
        uint256 _blockNumber,
        bytes calldata _txInclusionProof
    ) external;

    function completeBundle(bytes32 _bundleId) external;

    function cancelBundle(bytes32 _bundleId) external;

    // ============ Public Functions ============

    function expireBundle(bytes32 _bundleId) external;

    function reportViolation(
        bytes32 _bundleId,
        bytes calldata _fraudProof,
        string calldata _reason
    ) external;
}
