// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISovereignPolicy} from "./ISovereignPolicy.sol";
import {IArbitrator} from "./IArbitrator.sol";

/**
 * @title IFraudProofVerifier
 * @notice Interface for the Fraud Proof Verifier - trustless policy enforcement.
 * @dev Verifies fraud proofs for sequencing policy violations. Two verification paths:
 *
 *      1. Deterministic: For objectively provable violations (ordering, inclusion, timing)
 *         - Submitted as on-chain proofs
 *         - Verified purely by contract logic
 *         - Instant resolution
 *
 *      2. Subjective: For violations requiring human judgment (MEV quality, censorship intent)
 *         - Routed to arbitrator (Kleros default, but configurable per chain)
 *         - Challenge/response mechanism
 *         - Economic bonds for both sides
 *
 *      No trusted setups are hardcoded. Sovereign chains MAY opt into TEEs or
 *      other trust assumptions via their policy, but the verifier itself is trustless.
 */
interface IFraudProofVerifier {
    // ============ Enums ============

    /// @notice Type of fraud proof
    enum ProofType {
        OrderingViolation,     // Transactions not ordered per policy
        InclusionViolation,    // Valid transaction censored past deadline
        TimingViolation,       // Block time exceeded max allowed
        BundleViolation,       // Committed cross-chain bundle not executed
        MEVViolation,          // MEV rules violated (sandwich, frontrun)
        CustomViolation,       // Chain-specific custom violation
        UnjustifiedPause,      // Circuit breaker pause was not justified (subjective, Kleros)
        AtomicityViolation     // Bundle executed with mismatched results across chains
    }

    /// @notice Status of a fraud proof challenge
    enum ChallengeStatus {
        Pending,      // Submitted, awaiting verification
        Verified,     // Deterministic proof verified on-chain
        Disputed,     // Sent to arbitrator
        Accepted,     // Violation confirmed
        Rejected,     // Proof invalid / challenge failed
        Expired       // Response deadline passed
    }

    // ============ Structs ============

    /**
     * @notice A fraud proof challenge.
     * @param challengeId Unique identifier
     * @param challenger Address that submitted the challenge
     * @param sequencer The sequencer accused of violation
     * @param chainId The chain where the violation occurred
     * @param proofType Type of violation
     * @param proofData Encoded proof data
     * @param bond Challenger's bond amount
     * @param status Current challenge status
     * @param submitTime When the challenge was submitted
     * @param responseDeadline Deadline for sequencer response
     * @param disputeId Arbitrator dispute ID (if subjective)
     */
    struct Challenge {
        bytes32 challengeId;
        address challenger;
        address sequencer;
        uint256 chainId;
        ProofType proofType;
        bytes proofData;
        uint256 bond;
        ChallengeStatus status;
        uint256 submitTime;
        uint256 responseDeadline;
        uint256 disputeId;
    }

    // ============ Events ============

    event ChallengeSubmitted(
        bytes32 indexed challengeId,
        address indexed challenger,
        address indexed sequencer,
        uint256 chainId,
        ProofType proofType
    );

    event ChallengeVerified(bytes32 indexed challengeId, bool valid);
    event ChallengeDisputed(bytes32 indexed challengeId, uint256 disputeId);
    event ChallengeResolved(bytes32 indexed challengeId, ChallengeStatus status);
    event SequencerSlashed(address indexed sequencer, uint256 amount, bytes32 indexed challengeId);

    // ============ Errors ============

    error ChallengeAlreadyExists();
    error ChallengeNotFound();
    error InvalidProofType();
    error InvalidProofData();
    error InsufficientBond();
    error NotChallenger();
    error NotSequencer();
    error ChallengeNotPending();
    error ResponseDeadlinePassed();
    error ResponseDeadlineNotPassed();
    error InvalidChallengeStatus();
    error NotArbitrator();

    // ============ View Functions ============

    function getChallenge(bytes32 _challengeId) external view returns (Challenge memory);
    function getChallengeStatus(bytes32 _challengeId) external view returns (ChallengeStatus);
    function challengeBond() external view returns (uint256);
    function responseWindow() external view returns (uint256);

    // ============ Challenger Functions ============

    function submitChallenge(
        address _sequencer,
        uint256 _chainId,
        ProofType _proofType,
        bytes calldata _proofData
    ) external payable returns (bytes32 challengeId);

    // ============ Verification Functions ============

    function verifyDeterministicProof(bytes32 _challengeId) external;
    function escalateToArbitration(bytes32 _challengeId) external payable;

    // ============ Resolution Functions ============

    function resolveChallenge(bytes32 _challengeId) external;
}
