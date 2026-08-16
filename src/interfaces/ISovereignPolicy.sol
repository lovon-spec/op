// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISovereignPolicy
 * @notice Interface for sovereign sequencing policies - per-chain sequencing rules.
 * @dev Each chain in ISOCHRON can declare its own sequencing rules that the active
 *      sequencer must obey. Policies are enforced via deterministic fraud proofs
 *      where possible, with Kleros arbitration as fallback for subjective criteria.
 *
 *      Policy categories:
 *      - Ordering: FCFS, priority fee, custom ordering functions
 *      - Inclusion: Censorship resistance, forced inclusion deadlines
 *      - MEV: Sandwich protection, backrun-only, no MEV extraction
 *      - Timing: Block time targets, finality requirements
 *      - Custom: Chain-specific rules (encoded as policy data)
 *
 *      Policies are NOT hardcoded trusted setups. A sovereign chain MAY choose
 *      to use TEEs or other trust assumptions, but the framework does not require them.
 */
interface ISovereignPolicy {
    // ============ Enums ============

    /// @notice Policy enforcement mechanism
    enum EnforcementType {
        Deterministic,    // Provable on-chain via fraud proofs
        Subjective,       // Requires arbitration (Kleros default)
        Hybrid            // Deterministic where possible, arbitration fallback
    }

    /// @notice Ordering strategy
    enum OrderingStrategy {
        SequencerDiscretion,  // Sequencer chooses (default for private mempool)
        PriorityFee,          // Highest priority fee first
        FCFS,                 // First-come-first-served (requires timestamp proofs)
        Custom                // Custom ordering function
    }

    // ============ Structs ============

    /**
     * @notice Complete policy declaration for a chain.
     * @param chainId The chain this policy applies to
     * @param orderingStrategy How transactions should be ordered
     * @param enforcementType How violations are proven
     * @param maxBlockTime Maximum time between blocks (seconds)
     * @param forcedInclusionDeadline Max time a valid tx can be censored (seconds, 0 = disabled)
     * @param sandwichProtection Whether sandwich attacks are prohibited
     * @param backrunOnly Whether only backruns (not frontruns) are allowed for MEV
     * @param customPolicyContract Address of custom policy logic (optional)
     * @param policyData Additional encoded policy parameters
     * @param isActive Whether this policy is currently active
     * @param circuitBreaker Address authorized to pause sequencing (e.g. security council multisig)
     * @param isPaused Whether the chain is currently paused via circuit breaker
     */
    struct PolicyDeclaration {
        uint256 chainId;
        OrderingStrategy orderingStrategy;
        EnforcementType enforcementType;
        uint256 maxBlockTime;
        uint256 forcedInclusionDeadline;
        bool sandwichProtection;
        bool backrunOnly;
        address customPolicyContract;
        bytes policyData;
        bool isActive;
        address circuitBreaker;
        bool isPaused;
    }

    /**
     * @notice Result of a policy compliance check.
     * @param compliant Whether the action is compliant
     * @param violationType Type of violation (if any)
     * @param evidence Encoded evidence of violation
     */
    struct ComplianceResult {
        bool compliant;
        bytes32 violationType;
        bytes evidence;
    }

    // ============ Events ============

    event PolicyDeclared(uint256 indexed chainId, OrderingStrategy orderingStrategy, EnforcementType enforcementType);
    event PolicyUpdated(uint256 indexed chainId);
    event PolicyDeactivated(uint256 indexed chainId);
    event PolicyViolationDetected(uint256 indexed chainId, bytes32 indexed violationType, bytes evidence);
    event ChainPaused(uint256 indexed chainId, bool paused);

    // ============ View Functions ============

    function getPolicy(uint256 _chainId) external view returns (PolicyDeclaration memory);
    function isPolicyActive(uint256 _chainId) external view returns (bool);
    function version() external view returns (uint256);
    function policyInfo() external view returns (string memory name, string memory description);

    /**
     * @notice Checks if a proposed block is compliant with the chain's policy.
     * @param _chainId The chain to check against
     * @param _blockData Encoded block data to validate
     * @return result The compliance check result
     */
    function checkCompliance(uint256 _chainId, bytes calldata _blockData)
        external
        view
        returns (ComplianceResult memory result);
}
