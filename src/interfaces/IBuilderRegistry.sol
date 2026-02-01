// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBuilderRegistry
 * @notice Interface for the Builder Registry - "The Value Engine" in KSSN PBS architecture.
 * @dev Builders are MEV Searchers / Market Makers responsible for transaction content.
 *      They maintain high bonds to cover "Bad Block" damages and must comply with
 *      chain-specific policies through the Sovereignty Matrix.
 *
 *      Key concepts:
 *      - Policy Tags: Specific policy identifiers (e.g., POLICY_OFAC, POLICY_KYC)
 *      - Sovereignty Matrix: Maps builders to their policy compliance status
 *      - Union Rule: For atomic cross-chain bundles, builder must have ALL required tags
 *
 *      Liability: Strictly liable for Content (Constitution violations) and Data Availability.
 */
interface IBuilderRegistry {
    // ============ Structs ============

    /**
     * @notice Builder information.
     * @param bond The amount of ETH bonded by this builder
     * @param isActive Whether this builder is currently active
     * @param registrationTime When the builder registered
     * @param slashCount Number of times this builder has been slashed
     * @param lastSlashTime Timestamp of last slash
     */
    struct BuilderInfo {
        uint256 bond;
        bool isActive;
        uint256 registrationTime;
        uint256 slashCount;
        uint256 lastSlashTime;
    }

    /**
     * @notice Policy tag status.
     * @param isGranted Whether the builder has this tag
     * @param grantedAt When the tag was granted
     * @param expiresAt When the tag expires (0 = never)
     * @param revokedAt When the tag was revoked (0 = not revoked)
     */
    struct PolicyTagStatus {
        bool isGranted;
        uint256 grantedAt;
        uint256 expiresAt;
        uint256 revokedAt;
    }

    // ============ Errors ============

    /// @notice Thrown when bond amount is below minimum
    error InsufficientBond(uint256 provided, uint256 required);

    /// @notice Thrown when builder is not registered
    error BuilderNotRegistered(address builder);

    /// @notice Thrown when builder is already registered
    error BuilderAlreadyRegistered(address builder);

    /// @notice Thrown when builder is not active
    error BuilderNotActive(address builder);

    /// @notice Thrown when policy tag is not valid
    error InvalidPolicyTag(bytes32 policyId);

    /// @notice Thrown when builder doesn't have required policy tag
    error MissingPolicyTag(address builder, bytes32 policyId);

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when slash amount exceeds bond
    error SlashExceedsBond(uint256 slashAmount, uint256 bond);

    /// @notice Thrown when policy tag has expired
    error PolicyTagExpired(address builder, bytes32 policyId);

    /// @notice Thrown when policy tag was revoked
    error PolicyTagWasRevoked(address builder, bytes32 policyId);

    /// @notice Thrown when builder is in cooldown period after slash
    error BuilderInCooldown(address builder, uint256 cooldownEnds);

    /// @notice Thrown when the hub address is invalid
    error InvalidHub();

    // ============ Events ============

    /// @notice Emitted when a builder registers
    event BuilderRegistered(address indexed builder, uint256 bond);

    /// @notice Emitted when a builder unregisters
    event BuilderUnregistered(address indexed builder, uint256 bondReturned);

    /// @notice Emitted when bond is added
    event BondAdded(address indexed builder, uint256 amount, uint256 newTotal);

    /// @notice Emitted when bond is withdrawn
    event BondWithdrawn(address indexed builder, uint256 amount, uint256 remaining);

    /// @notice Emitted when a policy tag is granted
    event PolicyTagGranted(
        address indexed builder,
        bytes32 indexed policyId,
        uint256 expiresAt
    );

    /// @notice Emitted when a policy tag is revoked
    event PolicyTagRevoked(
        address indexed builder,
        bytes32 indexed policyId,
        string reason
    );

    /// @notice Emitted when a builder is slashed
    event BuilderSlashed(
        address indexed builder,
        uint256 amount,
        bytes32 indexed policyId,
        string reason
    );

    /// @notice Emitted when a builder is deactivated
    event BuilderDeactivated(address indexed builder, string reason);

    /// @notice Emitted when a builder is reactivated
    event BuilderReactivated(address indexed builder);

    /// @notice Emitted when a new policy is registered
    event PolicyRegistered(
        bytes32 indexed policyId,
        string name,
        string description
    );

    /// @notice Emitted when eligibility is checked
    event EligibilityChecked(
        address indexed builder,
        bytes32 indexed policyId,
        bool eligible
    );

    // ============ Policy Constants ============
    // These are commonly used policy IDs

    /**
     * @notice OFAC compliance policy tag.
     * @dev Builders with this tag filter OFAC-sanctioned addresses.
     */
    function POLICY_OFAC() external pure returns (bytes32);

    /**
     * @notice KYC compliance policy tag.
     * @dev Builders with this tag only include KYC-verified transactions.
     */
    function POLICY_KYC() external pure returns (bytes32);

    /**
     * @notice No-MEV policy tag.
     * @dev Builders with this tag commit to fair ordering (no frontrunning).
     */
    function POLICY_NO_MEV() external pure returns (bytes32);

    /**
     * @notice No gambling policy tag.
     * @dev Builders with this tag filter gambling-related transactions.
     */
    function POLICY_NO_GAMBLING() external pure returns (bytes32);

    /**
     * @notice Neutral policy tag (no restrictions).
     * @dev Default policy for permissionless chains.
     */
    function POLICY_NEUTRAL() external pure returns (bytes32);

    // ============ View Functions ============

    /**
     * @notice Returns the minimum bond required to register.
     * @return The minimum bond in wei
     */
    function minimumBond() external view returns (uint256);

    /**
     * @notice Returns information about a builder.
     * @param _builder The builder address
     * @return The builder information
     */
    function getBuilderInfo(address _builder) external view returns (BuilderInfo memory);

    /**
     * @notice Returns whether a builder has a specific policy tag.
     * @param _builder The builder address
     * @param _policyId The policy ID to check
     * @return True if the builder has the tag and it's valid
     */
    function hasPolicyTag(address _builder, bytes32 _policyId) external view returns (bool);

    /**
     * @notice Returns the full status of a policy tag for a builder.
     * @param _builder The builder address
     * @param _policyId The policy ID
     * @return The policy tag status
     */
    function getPolicyTagStatus(
        address _builder,
        bytes32 _policyId
    ) external view returns (PolicyTagStatus memory);

    /**
     * @notice Returns all policy tags held by a builder.
     * @param _builder The builder address
     * @return Array of policy IDs
     */
    function getBuilderPolicyTags(address _builder) external view returns (bytes32[] memory);

    /**
     * @notice Checks if a builder is eligible to build for a specific chain policy.
     * @dev Called by Proposer clients to verify builder eligibility.
     * @param _builder The builder address
     * @param _policyId The policy ID required by the chain
     * @return True if builder is active and has the required policy tag
     */
    function isBuilderEligible(address _builder, bytes32 _policyId) external view returns (bool);

    /**
     * @notice Checks if a builder is eligible for an atomic bundle across multiple chains.
     * @dev Implements the "Union Rule" - builder must have ALL required policy tags.
     * @param _builder The builder address
     * @param _policyIds Array of policy IDs required by the chains in the bundle
     * @return True if builder has all required policy tags
     */
    function isBuilderEligibleForBundle(
        address _builder,
        bytes32[] calldata _policyIds
    ) external view returns (bool);

    /**
     * @notice Returns the number of registered builders.
     * @return The count
     */
    function getRegisteredBuilderCount() external view returns (uint256);

    /**
     * @notice Returns the number of active builders.
     * @return The count
     */
    function getActiveBuilderCount() external view returns (uint256);

    /**
     * @notice Returns all active builders.
     * @return Array of active builder addresses
     */
    function getActiveBuilders() external view returns (address[] memory);

    /**
     * @notice Returns builders eligible for a specific policy.
     * @param _policyId The policy ID
     * @return Array of eligible builder addresses
     */
    function getBuildersForPolicy(bytes32 _policyId) external view returns (address[] memory);

    /**
     * @notice Returns the hub contract address.
     * @return The hub address
     */
    function hub() external view returns (address);

    // ============ Builder Functions ============

    /**
     * @notice Registers as a builder with initial bond.
     */
    function register() external payable;

    /**
     * @notice Unregisters as a builder and withdraws all bond.
     * @dev Cannot unregister if slashed within cooldown period.
     */
    function unregister() external;

    /**
     * @notice Adds bond to an existing registration.
     */
    function addBond() external payable;

    /**
     * @notice Withdraws bond (partial withdrawal allowed).
     * @dev Cannot withdraw below minimum bond while registered.
     * @param _amount The amount to withdraw
     */
    function withdrawBond(uint256 _amount) external;

    // ============ Policy Functions (Governance/Kleros) ============

    /**
     * @notice Grants a policy tag to a builder.
     * @dev Called by governance or Kleros Curate registry.
     * @param _builder The builder address
     * @param _policyId The policy ID to grant
     * @param _expiresAt Expiration timestamp (0 = never)
     */
    function grantPolicyTag(
        address _builder,
        bytes32 _policyId,
        uint256 _expiresAt
    ) external;

    /**
     * @notice Revokes a policy tag from a builder.
     * @dev Called by governance or through Kleros dispute.
     * @param _builder The builder address
     * @param _policyId The policy ID to revoke
     * @param _reason The reason for revocation
     */
    function revokePolicyTag(
        address _builder,
        bytes32 _policyId,
        string calldata _reason
    ) external;

    /**
     * @notice Slashes a builder's bond for policy violation.
     * @dev Called through Kleros dispute resolution.
     * @param _builder The builder address
     * @param _amount The amount to slash
     * @param _policyId The violated policy
     * @param _reason The reason for slashing
     */
    function slash(
        address _builder,
        uint256 _amount,
        bytes32 _policyId,
        string calldata _reason
    ) external;

    /**
     * @notice Deactivates a builder.
     * @dev Called by governance or through Kleros dispute.
     * @param _builder The builder address
     * @param _reason The reason for deactivation
     */
    function deactivate(address _builder, string calldata _reason) external;

    /**
     * @notice Reactivates a builder.
     * @dev Called by governance after issues are resolved.
     * @param _builder The builder address
     */
    function reactivate(address _builder) external;

    // ============ Governance Functions ============

    /**
     * @notice Registers a new policy type.
     * @param _policyId The policy ID
     * @param _name Human-readable policy name
     * @param _description Policy description
     */
    function registerPolicy(
        bytes32 _policyId,
        string calldata _name,
        string calldata _description
    ) external;

    /**
     * @notice Sets the minimum bond requirement.
     * @param _newMinimum The new minimum bond
     */
    function setMinimumBond(uint256 _newMinimum) external;

    /**
     * @notice Sets the hub contract address.
     * @param _hub The new hub address
     */
    function setHub(address _hub) external;

    /**
     * @notice Sets the cooldown period after slashing.
     * @param _period The cooldown period in seconds
     */
    function setSlashCooldown(uint256 _period) external;
}
