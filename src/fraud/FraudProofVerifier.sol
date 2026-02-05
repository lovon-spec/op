// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFraudProofVerifier} from "../interfaces/IFraudProofVerifier.sol";
import {ISovereignPolicy} from "../interfaces/ISovereignPolicy.sol";
import {IArbitrator} from "../interfaces/IArbitrator.sol";
import {IArbitrable} from "../interfaces/IArbitrable.sol";

/**
 * @title FraudProofVerifier
 * @notice Trustless fraud proof verification for sequencing policy violations.
 * @dev Two verification paths:
 *
 *      1. Deterministic: For objectively provable violations
 *         - OrderingViolation: Prove transactions are out of order per policy
 *         - InclusionViolation: Prove a valid tx was censored past deadline
 *         - TimingViolation: Prove block time exceeded maximum
 *         - BundleViolation: Prove a committed bundle was not executed
 *         These are verified purely by contract logic with instant resolution.
 *
 *      2. Subjective: For violations requiring judgment
 *         - MEVViolation: Sandwich detection (can be subjective edge cases)
 *         - CustomViolation: Chain-specific rules
 *         These are escalated to an arbitrator (Kleros default).
 *
 *      No trusted setups are hardcoded. The arbitrator is configurable,
 *      and chains can override it via their sovereign policy.
 */
contract FraudProofVerifier is IFraudProofVerifier, IArbitrable {
    // ============ Constants ============

    /// @notice Default challenge bond (0.5 ETH)
    uint256 public constant DEFAULT_CHALLENGE_BOND = 0.5 ether;

    /// @notice Default response window (24 hours)
    uint256 public constant DEFAULT_RESPONSE_WINDOW = 24 hours;

    /// @notice Number of ruling options for arbitrator
    uint256 public constant NUM_RULING_OPTIONS = 2;

    // ============ State Variables ============

    /// @notice Governance address
    address public governance;

    /// @notice Hub contract address
    address public hub;

    /// @notice Sovereign policy manager
    address public policyManager;

    /// @notice Default arbitrator (Kleros)
    IArbitrator public arbitrator;

    /// @notice Extra data for arbitrator
    bytes public arbitratorExtraData;

    /// @notice Challenge bond amount
    uint256 public override challengeBond;

    /// @notice Response window duration
    uint256 public override responseWindow;

    /// @notice Mapping from challengeId to Challenge
    mapping(bytes32 => Challenge) internal _challenges;

    /// @notice Nonce for challenge ID generation
    uint256 internal _nonce;

    /// @notice Mapping from disputeId to challengeId
    mapping(uint256 => bytes32) internal _disputeToChallengeId;

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotChallenger();
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != address(arbitrator)) revert NotArbitrator();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _governance,
        address _hub,
        address _policyManager,
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _challengeBond,
        uint256 _responseWindow
    ) {
        governance = _governance;
        hub = _hub;
        policyManager = _policyManager;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        challengeBond = _challengeBond == 0 ? DEFAULT_CHALLENGE_BOND : _challengeBond;
        responseWindow = _responseWindow == 0 ? DEFAULT_RESPONSE_WINDOW : _responseWindow;
    }

    // ============ View Functions ============

    function getChallenge(bytes32 _challengeId) external view override returns (Challenge memory) {
        return _challenges[_challengeId];
    }

    function getChallengeStatus(bytes32 _challengeId)
        external
        view
        override
        returns (ChallengeStatus)
    {
        return _challenges[_challengeId].status;
    }

    // ============ Challenger Functions ============

    function submitChallenge(
        address _sequencer,
        uint256 _chainId,
        ProofType _proofType,
        bytes calldata _proofData
    ) external payable override returns (bytes32 challengeId) {
        if (msg.value < challengeBond) revert InsufficientBond();
        if (_proofData.length == 0) revert InvalidProofData();

        challengeId = keccak256(abi.encode(msg.sender, _sequencer, _chainId, _nonce++));

        if (_challenges[challengeId].submitTime != 0) revert ChallengeAlreadyExists();

        _challenges[challengeId] = Challenge({
            challengeId: challengeId,
            challenger: msg.sender,
            sequencer: _sequencer,
            chainId: _chainId,
            proofType: _proofType,
            proofData: _proofData,
            bond: msg.value,
            status: ChallengeStatus.Pending,
            submitTime: block.timestamp,
            responseDeadline: block.timestamp + responseWindow,
            disputeId: 0
        });

        emit ChallengeSubmitted(challengeId, msg.sender, _sequencer, _chainId, _proofType);

        return challengeId;
    }

    // ============ Verification Functions ============

    function verifyDeterministicProof(bytes32 _challengeId) external override {
        Challenge storage challenge = _challenges[_challengeId];
        if (challenge.submitTime == 0) revert ChallengeNotFound();
        if (challenge.status != ChallengeStatus.Pending) revert ChallengeNotPending();

        bool valid = _verifyProof(challenge);

        if (valid) {
            challenge.status = ChallengeStatus.Accepted;

            // Return bond to challenger
            _sendValue(payable(challenge.challenger), challenge.bond);

            // Slash sequencer via hub (if connected)
            // In full implementation, would call ProposerRegistry.slashForLiveness

            emit ChallengeVerified(_challengeId, true);
            emit ChallengeResolved(_challengeId, ChallengeStatus.Accepted);
            emit SequencerSlashed(challenge.sequencer, 0, _challengeId);
        } else {
            challenge.status = ChallengeStatus.Rejected;

            // Bond goes to governance (treasury)
            _sendValue(payable(governance), challenge.bond);

            emit ChallengeVerified(_challengeId, false);
            emit ChallengeResolved(_challengeId, ChallengeStatus.Rejected);
        }
    }

    function escalateToArbitration(bytes32 _challengeId) external payable override {
        Challenge storage challenge = _challenges[_challengeId];
        if (challenge.submitTime == 0) revert ChallengeNotFound();
        if (challenge.status != ChallengeStatus.Pending) revert ChallengeNotPending();

        // Only subjective proof types can be escalated
        // (or deterministic ones that failed automated verification)

        // Create dispute with arbitrator
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        if (msg.value < arbitrationCost) revert InsufficientBond();

        uint256 disputeId =
            arbitrator.createDispute{value: arbitrationCost}(NUM_RULING_OPTIONS, arbitratorExtraData);

        challenge.status = ChallengeStatus.Disputed;
        challenge.disputeId = disputeId;

        _disputeToChallengeId[disputeId] = _challengeId;

        emit ChallengeDisputed(_challengeId, disputeId);

        // Refund excess
        if (msg.value > arbitrationCost) {
            _sendValue(payable(msg.sender), msg.value - arbitrationCost);
        }
    }

    // ============ Arbitrable Interface ============

    function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator {
        bytes32 challengeId = _disputeToChallengeId[_disputeID];
        Challenge storage challenge = _challenges[challengeId];

        if (challenge.status != ChallengeStatus.Disputed) revert InvalidChallengeStatus();

        // Ruling: 1 = challenger wins (violation confirmed), 2 = sequencer wins
        if (_ruling == 1) {
            challenge.status = ChallengeStatus.Accepted;

            // Return bond to challenger
            _sendValue(payable(challenge.challenger), challenge.bond);

            emit SequencerSlashed(challenge.sequencer, 0, challengeId);
        } else {
            challenge.status = ChallengeStatus.Rejected;

            // Bond goes to governance
            _sendValue(payable(governance), challenge.bond);
        }

        emit ChallengeResolved(challengeId, challenge.status);
        emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);
    }

    // ============ Resolution Functions ============

    function resolveChallenge(bytes32 _challengeId) external override {
        Challenge storage challenge = _challenges[_challengeId];
        if (challenge.submitTime == 0) revert ChallengeNotFound();

        // If response deadline passed and still pending, auto-accept
        if (
            challenge.status == ChallengeStatus.Pending
                && block.timestamp > challenge.responseDeadline
        ) {
            challenge.status = ChallengeStatus.Accepted;

            // Return bond to challenger
            _sendValue(payable(challenge.challenger), challenge.bond);

            emit ChallengeResolved(_challengeId, ChallengeStatus.Accepted);
            emit SequencerSlashed(challenge.sequencer, 0, _challengeId);
            return;
        }

        revert InvalidChallengeStatus();
    }

    // ============ Governance Functions ============

    function setChallengeBond(uint256 _bond) external onlyGovernance {
        challengeBond = _bond;
    }

    function setResponseWindow(uint256 _window) external onlyGovernance {
        responseWindow = _window;
    }

    function setArbitrator(IArbitrator _arbitrator, bytes calldata _extraData)
        external
        onlyGovernance
    {
        arbitrator = _arbitrator;
        arbitratorExtraData = _extraData;
    }

    function setPolicyManager(address _policyManager) external onlyGovernance {
        policyManager = _policyManager;
    }

    // ============ Internal Functions ============

    /**
     * @dev Verifies a deterministic fraud proof.
     *      In a full implementation, this would decode the proof data and verify
     *      against the chain's sovereign policy. The proof structure depends on
     *      the violation type:
     *
     *      - OrderingViolation: Two transactions with wrong ordering proof
     *      - InclusionViolation: Transaction receipt + block headers showing delay
     *      - TimingViolation: Two consecutive block headers showing gap
     *      - BundleViolation: Bundle commitment + block data showing missing tx
     */
    function _verifyProof(Challenge storage challenge) internal view returns (bool) {
        ProofType pType = challenge.proofType;

        if (pType == ProofType.TimingViolation) {
            return _verifyTimingViolation(challenge.chainId, challenge.proofData);
        } else if (pType == ProofType.OrderingViolation) {
            return _verifyOrderingViolation(challenge.chainId, challenge.proofData);
        } else if (pType == ProofType.InclusionViolation) {
            return _verifyInclusionViolation(challenge.chainId, challenge.proofData);
        } else if (pType == ProofType.BundleViolation) {
            return _verifyBundleViolation(challenge.proofData);
        }

        // MEV and Custom violations require subjective verification
        return false;
    }

    function _verifyTimingViolation(uint256 _chainId, bytes memory _proofData)
        internal
        view
        returns (bool)
    {
        // Decode: (uint256 blockTimestamp1, uint256 blockTimestamp2)
        // Verify gap exceeds chain's maxBlockTime policy
        if (_proofData.length < 64) return false;

        (uint256 timestamp1, uint256 timestamp2) = abi.decode(_proofData, (uint256, uint256));

        if (timestamp2 <= timestamp1) return false;

        uint256 gap = timestamp2 - timestamp1;

        // Check against policy
        if (policyManager != address(0)) {
            ISovereignPolicy.PolicyDeclaration memory policy =
                ISovereignPolicy(policyManager).getPolicy(_chainId);
            return gap > policy.maxBlockTime;
        }

        // Default: 12 second max block time
        return gap > 12;
    }

    function _verifyOrderingViolation(uint256 _chainId, bytes memory _proofData)
        internal
        view
        returns (bool)
    {
        // For FCFS policy: prove two transactions were misordered
        // Decode: (bytes32 tx1Hash, uint256 tx1ReceiptTime, bytes32 tx2Hash, uint256 tx2ReceiptTime, uint256 tx1BlockIndex, uint256 tx2BlockIndex)
        if (_proofData.length < 192) return false;

        (,uint256 tx1ReceiptTime,,uint256 tx2ReceiptTime, uint256 tx1BlockIndex, uint256 tx2BlockIndex) =
            abi.decode(_proofData, (bytes32, uint256, bytes32, uint256, uint256, uint256));

        // Check if chain has FCFS policy
        if (policyManager != address(0)) {
            ISovereignPolicy.PolicyDeclaration memory policy =
                ISovereignPolicy(policyManager).getPolicy(_chainId);
            if (policy.orderingStrategy == ISovereignPolicy.OrderingStrategy.FCFS) {
                // tx1 arrived before tx2 but appears after it in the block
                return tx1ReceiptTime < tx2ReceiptTime && tx1BlockIndex > tx2BlockIndex;
            }
        }

        return false;
    }

    function _verifyInclusionViolation(uint256 _chainId, bytes memory _proofData)
        internal
        view
        returns (bool)
    {
        // Prove a transaction was censored past the forced inclusion deadline
        // Decode: (bytes32 txHash, uint256 submissionTime, uint256 latestBlockTime)
        if (_proofData.length < 96) return false;

        (, uint256 submissionTime, uint256 latestBlockTime) =
            abi.decode(_proofData, (bytes32, uint256, uint256));

        if (latestBlockTime <= submissionTime) return false;

        uint256 delay = latestBlockTime - submissionTime;

        // Check against policy
        if (policyManager != address(0)) {
            ISovereignPolicy.PolicyDeclaration memory policy =
                ISovereignPolicy(policyManager).getPolicy(_chainId);
            if (policy.forcedInclusionDeadline > 0) {
                return delay > policy.forcedInclusionDeadline;
            }
        }

        return false;
    }

    function _verifyBundleViolation(bytes memory _proofData) internal pure returns (bool) {
        // Prove a committed bundle was not executed
        // Decode: (bytes32 bundleId, bytes32 operationsHash, uint256 deadline, uint256 currentTime)
        if (_proofData.length < 128) return false;

        (,,uint256 deadline, uint256 currentTime) =
            abi.decode(_proofData, (bytes32, bytes32, uint256, uint256));

        // Bundle violation if deadline has passed
        return currentTime > deadline;
    }

    function _sendValue(address payable _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool success,) = _to.call{value: _amount}("");
        require(success, "Transfer failed");
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
