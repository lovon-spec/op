// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISharedSequencerHub
 * @notice Interface for the Kleros Shared Sequencer Hub - the central nervous system of KSSN.
 * @dev The Hub is the single source of truth for the "Active Proposer" and manages
 *      atomic rotation of all connected OP Stack chains in a single transaction.
 *
 *      Key responsibilities:
 *      - Maintain the list of connected Spoke chains (ChainConfig)
 *      - Track proposer stakes and manage the active proposer set
 *      - Execute atomic network rotation via rotateNetwork()
 *      - Coordinate with ProposerRegistry for DPoS selection
 *      - Coordinate with BuilderRegistry for policy verification
 */
interface ISharedSequencerHub {
    // ============ Structs ============

    /**
     * @notice Configuration for a connected Spoke chain.
     * @param systemConfig The OP Stack SystemConfig contract address
     * @param policyId The Policy ID this chain requires (e.g., POLICY_OFAC)
     * @param adapter The adapter contract for version compatibility
     * @param isActive Whether this chain is currently active in the network
     * @param chainId The L2 chain ID for identification
     */
    struct ChainConfig {
        address systemConfig;
        bytes32 policyId;
        address adapter;
        bool isActive;
        uint256 chainId;
    }

    // ============ Errors ============

    /// @notice Thrown when caller is not authorized to perform rotation
    error UnauthorizedRotation();

    /// @notice Thrown when rotation is called outside the valid window
    error InvalidRotationWindow();

    /// @notice Thrown when trying to add a chain that already exists
    error ChainAlreadyExists(uint256 chainId);

    /// @notice Thrown when chain is not found
    error ChainNotFound(uint256 chainId);

    /// @notice Thrown when adapter address is invalid
    error InvalidAdapter();

    /// @notice Thrown when SystemConfig address is invalid
    error InvalidSystemConfig();

    /// @notice Thrown when policy ID is invalid
    error InvalidPolicyId();

    /// @notice Thrown when no active chains exist
    error NoActiveChains();

    /// @notice Thrown when the contract is paused
    error ContractPaused();

    /// @notice Thrown when caller is not the guardian
    error NotGuardian();

    /// @notice Thrown when caller is not the governance
    error NotGovernance();

    // ============ Events ============

    /// @notice Emitted when the network is rotated to a new proposer
    event NetworkRotated(
        address indexed newProposer,
        uint256 indexed epoch,
        uint256 chainsUpdated,
        uint256 timestamp
    );

    /// @notice Emitted when a new chain is connected to the hub
    event ChainConnected(
        uint256 indexed chainId,
        address indexed systemConfig,
        bytes32 policyId,
        address adapter
    );

    /// @notice Emitted when a chain is disconnected from the hub
    event ChainDisconnected(uint256 indexed chainId);

    /// @notice Emitted when a chain's configuration is updated
    event ChainConfigUpdated(
        uint256 indexed chainId,
        bytes32 newPolicyId,
        address newAdapter
    );

    /// @notice Emitted when a chain is activated or deactivated
    event ChainActiveStatusChanged(uint256 indexed chainId, bool isActive);

    /// @notice Emitted when the proposer registry is updated
    event ProposerRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Emitted when the builder registry is updated
    event BuilderRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Emitted when epoch duration is updated
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Emitted when contract is paused/unpaused
    event PauseStatusChanged(bool isPaused);

    // ============ View Functions ============

    /**
     * @notice Returns the current active proposer.
     * @return The address of the current proposer
     */
    function currentProposer() external view returns (address);

    /**
     * @notice Returns the current epoch number.
     * @return The current epoch
     */
    function currentEpoch() external view returns (uint256);

    /**
     * @notice Returns the epoch duration in seconds.
     * @return The epoch duration
     */
    function epochDuration() external view returns (uint256);

    /**
     * @notice Returns the grace period duration for Active Handoff.
     * @return The grace period in seconds
     */
    function gracePeriod() external view returns (uint256);

    /**
     * @notice Returns the timestamp when the current epoch started.
     * @return The epoch start timestamp
     */
    function epochStartTime() external view returns (uint256);

    /**
     * @notice Returns time remaining until the next rotation window.
     * @return Time in seconds until rotation is allowed
     */
    function timeUntilNextRotation() external view returns (uint256);

    /**
     * @notice Checks if rotation is currently allowed.
     * @return True if within the rotation window
     */
    function isRotationWindowOpen() external view returns (bool);

    /**
     * @notice Returns the total number of connected chains.
     * @return The chain count
     */
    function getChainCount() external view returns (uint256);

    /**
     * @notice Returns the configuration for a specific chain.
     * @param _chainId The L2 chain ID
     * @return The chain configuration
     */
    function getChainConfig(uint256 _chainId) external view returns (ChainConfig memory);

    /**
     * @notice Returns all connected chain configurations.
     * @return Array of chain configurations
     */
    function getAllChainConfigs() external view returns (ChainConfig[] memory);

    /**
     * @notice Returns the count of active chains.
     * @return Number of active chains
     */
    function getActiveChainCount() external view returns (uint256);

    /**
     * @notice Returns the proposer registry address.
     * @return The registry address
     */
    function proposerRegistry() external view returns (address);

    /**
     * @notice Returns the builder registry address.
     * @return The registry address
     */
    function builderRegistry() external view returns (address);

    /**
     * @notice Checks if the contract is paused.
     * @return True if paused
     */
    function isPaused() external view returns (bool);

    // ============ Proposer Functions ============

    /**
     * @notice Rotates the proposer for the entire network atomically.
     * @dev Called by the outgoing proposer (Active Handoff) or by anyone after grace period.
     *      Updates the SystemConfig of every connected Spoke chain in a single loop.
     *      Costs ~60k gas per chain. Max ~450 chains per block at 30M gas limit.
     */
    function rotateNetwork() external;

    /**
     * @notice Rotates a shard of chains (for scaling beyond ~400 chains).
     * @dev Used when the network grows beyond single-tx capacity.
     * @param _shardIndex The shard index (0, 1, 2, ...)
     */
    function rotateShard(uint256 _shardIndex) external;

    // ============ Governance Functions ============

    /**
     * @notice Connects a new Spoke chain to the hub.
     * @param _chainId The L2 chain ID
     * @param _systemConfig The SystemConfig contract address
     * @param _policyId The required policy ID for this chain
     * @param _adapter The adapter contract address
     */
    function connectChain(
        uint256 _chainId,
        address _systemConfig,
        bytes32 _policyId,
        address _adapter
    ) external;

    /**
     * @notice Disconnects a Spoke chain from the hub.
     * @param _chainId The L2 chain ID to disconnect
     */
    function disconnectChain(uint256 _chainId) external;

    /**
     * @notice Updates the configuration for a connected chain.
     * @param _chainId The L2 chain ID
     * @param _policyId The new policy ID (or bytes32(0) to keep current)
     * @param _adapter The new adapter address (or address(0) to keep current)
     */
    function updateChainConfig(
        uint256 _chainId,
        bytes32 _policyId,
        address _adapter
    ) external;

    /**
     * @notice Sets the active status for a chain.
     * @param _chainId The L2 chain ID
     * @param _isActive The new active status
     */
    function setChainActiveStatus(uint256 _chainId, bool _isActive) external;

    /**
     * @notice Updates the proposer registry address.
     * @param _newRegistry The new registry address
     */
    function setProposerRegistry(address _newRegistry) external;

    /**
     * @notice Updates the builder registry address.
     * @param _newRegistry The new registry address
     */
    function setBuilderRegistry(address _newRegistry) external;

    /**
     * @notice Updates the epoch duration.
     * @param _newDuration The new duration in seconds
     */
    function setEpochDuration(uint256 _newDuration) external;

    // ============ Guardian Functions ============

    /**
     * @notice Pauses the contract (emergency stop).
     */
    function pause() external;

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external;

    /**
     * @notice Forces a rotation in emergency situations.
     * @param _newProposer The address of the emergency proposer
     */
    function emergencyRotate(address _newProposer) external;
}
