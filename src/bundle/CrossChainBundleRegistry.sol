// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICrossChainBundle} from "../interfaces/ICrossChainBundle.sol";
import {IBundleEscrow} from "../interfaces/IBundleEscrow.sol";
import {IFraudProofVerifier} from "../interfaces/IFraudProofVerifier.sol";

/**
 * @title CrossChainBundleRegistry
 * @notice Registry for atomic cross-chain bundle execution commitments.
 * @dev The active sequencer commits to executing bundles across multiple chains.
 *      This contract stores commitments, tracks per-chain execution confirmations,
 *      and coordinates with the escrow for economic incentives.
 *
 *      Architecture:
 *      - Commitments are posted by the active sequencer
 *      - Per-chain execution is confirmed by submitting inclusion proofs
 *      - A bundle is complete when all chains confirm execution
 *      - Violations trigger fraud proofs and slashing via FraudProofVerifier
 *
 *      The registry is chain-agnostic. It stores hashes and proofs,
 *      not the actual transaction data (which lives off-chain in the relay).
 */
contract CrossChainBundleRegistry is ICrossChainBundle {
    // ============ State Variables ============

    /// @notice Reference to the hub contract for sequencer verification
    address public hub;

    /// @notice Reference to the escrow contract
    address public escrow;

    /// @notice Reference to the fraud proof verifier
    address public fraudProofVerifier;

    /// @notice Governance address
    address public governance;

    /// @notice Minimum deadline duration from commitment (prevents too-tight deadlines)
    uint256 public minDeadlineDuration;

    /// @notice Nonce for bundle ID generation
    uint256 internal _nonce;

    /// @notice Mapping from bundleId to BundleCommitment
    mapping(bytes32 => BundleCommitment) internal _bundles;

    /// @notice Mapping from bundleId to chainId to ChainExecutionProof
    mapping(bytes32 => mapping(uint256 => ChainExecutionProof)) internal _chainExecutions;

    /// @notice Mapping from bundleId to number of confirmed chains
    mapping(bytes32 => uint256) internal _confirmedChainCount;

    /// @notice Mapping from sequencer to their bundle IDs
    mapping(address => bytes32[]) internal _sequencerBundles;

    /// @notice Array of pending bundle IDs
    bytes32[] internal _pendingBundles;

    /// @notice Mapping from bundleId to index in _pendingBundles (1-indexed)
    mapping(bytes32 => uint256) internal _pendingBundleIndex;

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotActiveSequencer();
        _;
    }

    modifier onlyActiveSequencer() {
        // Check with the hub that msg.sender is the current active sequencer
        // For flexibility, also allow governance to act as sequencer in tests
        (bool success, bytes memory data) = hub.staticcall(
            abi.encodeWithSignature("currentProposer()")
        );
        if (!success) revert NotActiveSequencer();
        address currentProposer = abi.decode(data, (address));
        if (msg.sender != currentProposer && msg.sender != governance) {
            revert NotActiveSequencer();
        }
        _;
    }

    // ============ Constructor ============

    constructor(
        address _hub,
        address _escrow,
        address _fraudProofVerifier,
        address _governance,
        uint256 _minDeadlineDuration
    ) {
        hub = _hub;
        escrow = _escrow;
        fraudProofVerifier = _fraudProofVerifier;
        governance = _governance;
        minDeadlineDuration = _minDeadlineDuration == 0 ? 5 minutes : _minDeadlineDuration;
    }

    // ============ View Functions ============

    function getBundle(bytes32 _bundleId) external view override returns (BundleCommitment memory) {
        return _bundles[_bundleId];
    }

    function getBundleStatus(bytes32 _bundleId) external view override returns (BundleStatus) {
        return _bundles[_bundleId].status;
    }

    function getChainExecution(bytes32 _bundleId, uint256 _chainId)
        external
        view
        override
        returns (ChainExecutionProof memory)
    {
        return _chainExecutions[_bundleId][_chainId];
    }

    function isChainConfirmed(bytes32 _bundleId, uint256 _chainId)
        external
        view
        override
        returns (bool)
    {
        return _chainExecutions[_bundleId][_chainId].confirmed;
    }

    function getPendingBundleCount() external view override returns (uint256) {
        return _pendingBundles.length;
    }

    function getSequencerBundles(address _sequencer)
        external
        view
        override
        returns (bytes32[] memory)
    {
        return _sequencerBundles[_sequencer];
    }

    // ============ Sequencer Functions ============

    function commitBundle(
        bytes32 _operationsHash,
        uint256[] calldata _targetChainIds,
        uint256 _deadline
    ) external payable override onlyActiveSequencer returns (bytes32 bundleId) {
        if (_targetChainIds.length == 0) revert ZeroChainCount();
        if (_operationsHash == bytes32(0)) revert InvalidOperationsHash();
        if (_deadline < block.timestamp + minDeadlineDuration) revert DeadlineExpired();

        // Generate unique bundle ID
        bundleId = keccak256(abi.encode(_operationsHash, msg.sender, _nonce++, block.timestamp));

        if (_bundles[bundleId].commitTimestamp != 0) revert BundleAlreadyExists();

        // Store commitment
        _bundles[bundleId] = BundleCommitment({
            bundleId: bundleId,
            sequencer: msg.sender,
            operationsHash: _operationsHash,
            targetChainIds: _targetChainIds,
            deadline: _deadline,
            tip: msg.value,
            status: BundleStatus.Committed,
            commitTimestamp: block.timestamp,
            chainCount: _targetChainIds.length
        });

        // Track pending bundle
        _pendingBundles.push(bundleId);
        _pendingBundleIndex[bundleId] = _pendingBundles.length;

        // Track per-sequencer
        _sequencerBundles[msg.sender].push(bundleId);

        // If tip was sent, deposit to escrow
        if (msg.value > 0 && escrow != address(0)) {
            IBundleEscrow(escrow).depositTip{value: msg.value}(bundleId);
        }

        emit BundleCommitted(
            bundleId,
            msg.sender,
            _operationsHash,
            _deadline,
            msg.value,
            _targetChainIds.length
        );

        return bundleId;
    }

    function confirmChainExecution(
        bytes32 _bundleId,
        uint256 _chainId,
        uint256 _blockNumber,
        bytes calldata _txInclusionProof
    ) external override {
        BundleCommitment storage bundle = _bundles[_bundleId];
        if (bundle.commitTimestamp == 0) revert BundleNotFound();
        if (bundle.status != BundleStatus.Committed) revert InvalidBundleStatus();

        // Verify chain is part of this bundle
        bool found = false;
        for (uint256 i = 0; i < bundle.targetChainIds.length; i++) {
            if (bundle.targetChainIds[i] == _chainId) {
                found = true;
                break;
            }
        }
        if (!found) revert ChainNotInBundle();

        // Check not already confirmed
        if (_chainExecutions[_bundleId][_chainId].confirmed) revert AlreadyConfirmed();

        // Store execution proof
        _chainExecutions[_bundleId][_chainId] = ChainExecutionProof({
            chainId: _chainId,
            blockNumber: _blockNumber,
            txInclusionProof: _txInclusionProof,
            confirmed: true
        });

        _confirmedChainCount[_bundleId]++;

        emit BundleExecutionConfirmed(_bundleId, _chainId, _blockNumber);
    }

    function completeBundle(bytes32 _bundleId) external override {
        BundleCommitment storage bundle = _bundles[_bundleId];
        if (bundle.commitTimestamp == 0) revert BundleNotFound();
        if (bundle.status != BundleStatus.Committed) revert InvalidBundleStatus();

        // All chains must be confirmed
        if (_confirmedChainCount[_bundleId] < bundle.chainCount) revert NotAllChainsConfirmed();

        bundle.status = BundleStatus.Executed;

        // Remove from pending
        _removePendingBundle(_bundleId);

        // Release tip to sequencer via escrow
        if (escrow != address(0)) {
            try IBundleEscrow(escrow).releaseTip(_bundleId) {} catch {}
            try IBundleEscrow(escrow).returnBond(_bundleId) {} catch {}
        }

        emit BundleCompleted(_bundleId);
    }

    function cancelBundle(bytes32 _bundleId) external override {
        BundleCommitment storage bundle = _bundles[_bundleId];
        if (bundle.commitTimestamp == 0) revert BundleNotFound();
        if (bundle.status != BundleStatus.Committed) revert InvalidBundleStatus();
        if (msg.sender != bundle.sequencer && msg.sender != governance) revert NotActiveSequencer();

        bundle.status = BundleStatus.Cancelled;

        // Remove from pending
        _removePendingBundle(_bundleId);

        // Penalty: slash a portion of the bond
        uint256 penalty = 0;
        if (escrow != address(0)) {
            try IBundleEscrow(escrow).slashBond(_bundleId, address(this)) {
                penalty = 1; // Signal that slashing occurred
            } catch {}
            // Refund tip to submitter
            try IBundleEscrow(escrow).refundTip(_bundleId) {} catch {}
        }

        emit BundleCancelled(_bundleId, penalty);
    }

    // ============ Public Functions ============

    function expireBundle(bytes32 _bundleId) external override {
        BundleCommitment storage bundle = _bundles[_bundleId];
        if (bundle.commitTimestamp == 0) revert BundleNotFound();
        if (bundle.status != BundleStatus.Committed) revert InvalidBundleStatus();
        if (block.timestamp <= bundle.deadline) revert DeadlineNotExpired();

        bundle.status = BundleStatus.Expired;

        // Remove from pending
        _removePendingBundle(_bundleId);

        // Slash sequencer bond and refund tip
        if (escrow != address(0)) {
            try IBundleEscrow(escrow).slashBond(_bundleId, msg.sender) {} catch {}
            try IBundleEscrow(escrow).refundTip(_bundleId) {} catch {}
        }

        emit BundleExpired(_bundleId);
    }

    function reportViolation(
        bytes32 _bundleId,
        bytes calldata _fraudProof,
        string calldata _reason
    ) external override {
        BundleCommitment storage bundle = _bundles[_bundleId];
        if (bundle.commitTimestamp == 0) revert BundleNotFound();
        if (bundle.status != BundleStatus.Committed && bundle.status != BundleStatus.Executed) {
            revert InvalidBundleStatus();
        }

        // If fraud proof verifier is set, submit the challenge through it
        if (fraudProofVerifier != address(0)) {
            IFraudProofVerifier(fraudProofVerifier).submitChallenge(
                bundle.sequencer,
                bundle.targetChainIds[0], // Primary chain
                IFraudProofVerifier.ProofType.BundleViolation,
                _fraudProof
            );
        }

        bundle.status = BundleStatus.Violated;

        // Remove from pending if still there
        if (_pendingBundleIndex[_bundleId] != 0) {
            _removePendingBundle(_bundleId);
        }

        // Slash sequencer bond
        if (escrow != address(0)) {
            try IBundleEscrow(escrow).slashBond(_bundleId, msg.sender) {} catch {}
            try IBundleEscrow(escrow).refundTip(_bundleId) {} catch {}
        }

        emit BundleViolation(_bundleId, msg.sender, _reason);
    }

    // ============ Governance Functions ============

    function setEscrow(address _escrow) external onlyGovernance {
        escrow = _escrow;
    }

    function setFraudProofVerifier(address _verifier) external onlyGovernance {
        fraudProofVerifier = _verifier;
    }

    function setMinDeadlineDuration(uint256 _duration) external onlyGovernance {
        minDeadlineDuration = _duration;
    }

    // ============ Internal Functions ============

    function _removePendingBundle(bytes32 _bundleId) internal {
        uint256 index = _pendingBundleIndex[_bundleId];
        if (index == 0) return;

        uint256 arrayIndex = index - 1;
        uint256 lastIndex = _pendingBundles.length - 1;

        if (arrayIndex != lastIndex) {
            bytes32 lastBundleId = _pendingBundles[lastIndex];
            _pendingBundles[arrayIndex] = lastBundleId;
            _pendingBundleIndex[lastBundleId] = index;
        }

        _pendingBundles.pop();
        delete _pendingBundleIndex[_bundleId];
    }
}
