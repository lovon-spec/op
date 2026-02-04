// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainRegistry} from "./interfaces/IChainRegistry.sol";

/**
 * @title ChainDeploymentKit
 * @notice A helper contract for rollup chains to easily integrate into KSSN.
 * @dev This contract provides a simplified interface for chain teams to:
 *      1. Register their chain in the ChainRegistry
 *      2. Track their registration status
 *      3. Manage their chain's configuration
 *
 *      Usage Flow:
 *      1. Chain team deploys their rollup with a configuration contract
 *      2. Chain team deploys ChainDeploymentKit (or uses shared instance)
 *      3. Chain team calls registerChain() with required deposit
 *      4. Community can challenge during the challenge period
 *      5. After period expires, chain team calls finalizeRegistration()
 *      6. Hub governance calls connectChainFromRegistry() to add to KSSN
 *
 *      This contract is designed to be deployed once per KSSN deployment
 *      and used by all chains seeking integration.
 *
 * @custom:security-contact security@kleros.io
 */
contract ChainDeploymentKit {
    // ============ State Variables ============

    /// @notice The Chain Registry contract
    IChainRegistry public immutable chainRegistry;

    /// @notice Default adapter for new chains (can be overridden per chain)
    address public defaultAdapter;

    /// @notice Governor who can update default adapter
    address public governor;

    /// @notice Mapping from chain ID to registration info
    mapping(uint256 => RegistrationInfo) public registrations;

    // ============ Structs ============

    /**
     * @notice Information about a chain's registration process.
     * @param itemId The registry item ID
     * @param registrant Address that registered the chain
     * @param registeredAt When registration was submitted
     * @param status Current status in the registration process
     */
    struct RegistrationInfo {
        bytes32 itemId;
        address registrant;
        uint256 registeredAt;
        RegistrationStatus status;
    }

    /**
     * @notice Status of a chain registration.
     */
    enum RegistrationStatus {
        NotStarted,     // Chain hasn't been registered
        Pending,        // Registration submitted, in challenge period
        Registered,     // Successfully registered in ChainRegistry
        Connected,      // Connected to KSSN Hub
        Failed          // Registration failed (challenged and lost)
    }

    // ============ Events ============

    /// @notice Emitted when a chain starts registration
    event RegistrationStarted(
        uint256 indexed chainId,
        bytes32 indexed itemId,
        address indexed registrant,
        address rollupConfig
    );

    /// @notice Emitted when registration is finalized
    event RegistrationFinalized(
        uint256 indexed chainId,
        bool success
    );

    /// @notice Emitted when default adapter is updated
    event DefaultAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    // ============ Errors ============

    error NotGovernor();
    error ChainAlreadyRegistered();
    error RegistrationNotPending();
    error InsufficientDeposit();
    error InvalidChainId();
    error InvalidRollupConfig();

    // ============ Constructor ============

    /**
     * @notice Initializes the ChainDeploymentKit.
     * @param _chainRegistry The ChainRegistry contract address
     * @param _defaultAdapter The default rollup adapter for new chains
     * @param _governor The governor address
     */
    constructor(
        address _chainRegistry,
        address _defaultAdapter,
        address _governor
    ) {
        chainRegistry = IChainRegistry(_chainRegistry);
        defaultAdapter = _defaultAdapter;
        governor = _governor;
    }

    // ============ Registration Functions ============

    /**
     * @notice Registers a new chain for KSSN integration.
     * @dev Submits the chain to the ChainRegistry. The caller must provide
     *      enough ETH to cover the required deposit + arbitration cost.
     *
     *      After this call, the registration enters the challenge period.
     *      Anyone can challenge the registration during this time.
     *
     * @param _chainId The L2 chain ID
     * @param _rollupConfig The rollup configuration contract address
     * @param _name Human-readable chain name
     * @param _metadataURI IPFS URI with additional chain info
     * @return itemId The registry item ID
     */
    function registerChain(
        uint256 _chainId,
        address _rollupConfig,
        string calldata _name,
        string calldata _metadataURI
    ) external payable returns (bytes32 itemId) {
        return registerChainWithAdapter(
            _chainId,
            _rollupConfig,
            defaultAdapter,
            _name,
            _metadataURI
        );
    }

    /**
     * @notice Registers a new chain with a custom adapter.
     * @param _chainId The L2 chain ID
     * @param _rollupConfig The rollup configuration contract address
     * @param _adapter The rollup adapter address
     * @param _name Human-readable chain name
     * @param _metadataURI IPFS URI with additional chain info
     * @return itemId The registry item ID
     */
    function registerChainWithAdapter(
        uint256 _chainId,
        address _rollupConfig,
        address _adapter,
        string calldata _name,
        string calldata _metadataURI
    ) public payable returns (bytes32 itemId) {
        if (_chainId == 0) revert InvalidChainId();
        if (_rollupConfig == address(0)) revert InvalidRollupConfig();

        // Check not already registered
        if (registrations[_chainId].status != RegistrationStatus.NotStarted) {
            revert ChainAlreadyRegistered();
        }

        // Submit to chain registry
        itemId = chainRegistry.addChain{value: msg.value}(
            _chainId,
            _rollupConfig,
            _adapter,
            _name,
            _metadataURI
        );

        // Store registration info
        registrations[_chainId] = RegistrationInfo({
            itemId: itemId,
            registrant: msg.sender,
            registeredAt: block.timestamp,
            status: RegistrationStatus.Pending
        });

        emit RegistrationStarted(_chainId, itemId, msg.sender, _rollupConfig);

        return itemId;
    }

    /**
     * @notice Finalizes a pending registration after the challenge period.
     * @dev Calls executeRequest on the ChainRegistry to complete registration.
     *      This can be called by anyone after the challenge period expires.
     *
     * @param _chainId The chain ID to finalize
     */
    function finalizeRegistration(uint256 _chainId) external {
        RegistrationInfo storage info = registrations[_chainId];
        if (info.status != RegistrationStatus.Pending) {
            revert RegistrationNotPending();
        }

        // Try to execute the request
        try chainRegistry.executeRequest(info.itemId) {
            info.status = RegistrationStatus.Registered;
            emit RegistrationFinalized(_chainId, true);
        } catch {
            // If execution fails, check if it was challenged and lost
            IChainRegistry.Item memory item = chainRegistry.getItem(info.itemId);
            if (item.status == IChainRegistry.Status.Absent) {
                info.status = RegistrationStatus.Failed;
                emit RegistrationFinalized(_chainId, false);
            }
            // If still pending (challenge not resolved), do nothing
        }
    }

    /**
     * @notice Requests removal of a registered chain from KSSN.
     * @dev Only the original registrant can request removal.
     * @param _chainId The chain ID to remove
     */
    function requestRemoval(uint256 _chainId) external payable {
        RegistrationInfo storage info = registrations[_chainId];
        if (msg.sender != info.registrant) revert NotGovernor();
        if (info.status != RegistrationStatus.Registered &&
            info.status != RegistrationStatus.Connected) {
            revert RegistrationNotPending();
        }

        chainRegistry.removeChain{value: msg.value}(_chainId);
    }

    // ============ View Functions ============

    /**
     * @notice Returns the registration status for a chain.
     * @param _chainId The chain ID
     * @return The current registration status
     */
    function getStatus(uint256 _chainId) external view returns (RegistrationStatus) {
        return registrations[_chainId].status;
    }

    /**
     * @notice Returns full registration info for a chain.
     * @param _chainId The chain ID
     * @return info The registration info struct
     */
    function getRegistrationInfo(uint256 _chainId) external view returns (RegistrationInfo memory) {
        return registrations[_chainId];
    }

    /**
     * @notice Returns the required deposit for registration.
     * @return The deposit amount in wei
     */
    function getRequiredDeposit() external view returns (uint256) {
        return chainRegistry.requiredDeposit();
    }

    /**
     * @notice Returns the challenge period duration.
     * @return The duration in seconds
     */
    function getChallengePeriod() external view returns (uint256) {
        return chainRegistry.challengePeriod();
    }

    /**
     * @notice Checks if a chain is ready to be connected to KSSN.
     * @dev A chain is ready when it's registered in the ChainRegistry.
     * @param _chainId The chain ID
     * @return True if ready for connection
     */
    function isReadyForConnection(uint256 _chainId) external view returns (bool) {
        return chainRegistry.isRegistered(_chainId);
    }

    /**
     * @notice Returns the time remaining in the challenge period.
     * @param _chainId The chain ID
     * @return Seconds remaining (0 if period has passed)
     */
    function getChallengeTimeRemaining(uint256 _chainId) external view returns (uint256) {
        RegistrationInfo memory info = registrations[_chainId];
        if (info.status != RegistrationStatus.Pending) return 0;

        uint256 endTime = info.registeredAt + chainRegistry.challengePeriod();
        if (block.timestamp >= endTime) return 0;

        return endTime - block.timestamp;
    }

    // ============ Governor Functions ============

    /**
     * @notice Updates the default adapter.
     * @param _newAdapter The new default adapter address
     */
    function setDefaultAdapter(address _newAdapter) external {
        if (msg.sender != governor) revert NotGovernor();

        address oldAdapter = defaultAdapter;
        defaultAdapter = _newAdapter;

        emit DefaultAdapterUpdated(oldAdapter, _newAdapter);
    }

    /**
     * @notice Transfers governance to a new address.
     * @param _newGovernor The new governor address
     */
    function transferGovernance(address _newGovernor) external {
        if (msg.sender != governor) revert NotGovernor();
        governor = _newGovernor;
    }

    /**
     * @notice Marks a chain as connected (called by Hub after connectChainFromRegistry).
     * @dev This is informational only - the actual connection is tracked in the Hub.
     * @param _chainId The chain ID that was connected
     */
    function markAsConnected(uint256 _chainId) external {
        if (msg.sender != governor) revert NotGovernor();

        RegistrationInfo storage info = registrations[_chainId];
        if (info.status == RegistrationStatus.Registered) {
            info.status = RegistrationStatus.Connected;
        }
    }

    /**
     * @notice Allows the contract to receive ETH (for refunds from registry).
     */
    receive() external payable {}
}
