// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniversalBuilder
 * @notice Interface for block builders in ISOCHRON's universal sequencing layer.
 * @dev Builders are responsible for ordering transactions within blocks for each chain.
 *      The default implementation uses MEV-Boost + Flashblocks (private mempool),
 *      but the architecture supports any building mechanism:
 *      - Private mempool (Flashblocks, MEV-Boost) - default
 *      - Public mempool (PBS, traditional)
 *      - Encrypted mempool (threshold encryption, SGX)
 *      - Custom ordering (FCFS, priority fee, etc.)
 *
 *      Each chain can specify its preferred builder via sovereign policies.
 *      The active sequencer delegates block building to the registered builder.
 */
interface IUniversalBuilder {
    // ============ Enums ============

    /// @notice Builder type classification
    enum BuilderType {
        PrivateMempool,     // MEV-Boost / Flashblocks style
        PublicMempool,      // Traditional PBS
        EncryptedMempool,   // Threshold/TEE encrypted ordering
        Custom              // Chain-specific custom builder
    }

    // ============ Structs ============

    /**
     * @notice Block building request from the sequencer.
     * @param chainId Target chain for the block
     * @param parentHash Parent block hash
     * @param timestamp Target block timestamp
     * @param gasLimit Block gas limit
     * @param bundles Cross-chain bundle IDs that must be included
     * @param policyData Sovereign policy constraints (encoded)
     */
    struct BuildRequest {
        uint256 chainId;
        bytes32 parentHash;
        uint256 timestamp;
        uint256 gasLimit;
        bytes32[] bundles;
        bytes policyData;
    }

    /**
     * @notice Built block response.
     * @param chainId Target chain
     * @param blockHash Hash of the built block
     * @param stateRoot Resulting state root
     * @param txCount Number of transactions
     * @param bundlesIncluded Bundle IDs successfully included
     * @param builderSignature Builder's signature over the block
     */
    struct BuildResponse {
        uint256 chainId;
        bytes32 blockHash;
        bytes32 stateRoot;
        uint256 txCount;
        bytes32[] bundlesIncluded;
        bytes builderSignature;
    }

    // ============ Events ============

    event BlockBuildRequested(uint256 indexed chainId, bytes32 parentHash, uint256 timestamp);
    event BlockBuilt(uint256 indexed chainId, bytes32 indexed blockHash, uint256 txCount);

    // ============ View Functions ============

    function builderType() external view returns (BuilderType);
    function version() external view returns (uint256);
    function builderInfo() external view returns (string memory name, string memory description);
    function supportsChain(uint256 _chainId) external view returns (bool);

    // ============ Builder Functions ============

    /**
     * @notice Validates that a build request conforms to the builder's constraints.
     * @param _request The build request to validate
     * @return valid Whether the request is valid
     * @return reason Reason if invalid
     */
    function validateBuildRequest(BuildRequest calldata _request)
        external
        view
        returns (bool valid, string memory reason);
}
