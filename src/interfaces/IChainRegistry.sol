// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IArbitrator} from "./IArbitrator.sol";

/**
 * @title IChainRegistry
 * @notice Interface for the Chain Registry - a GeneralizedTCR for KSSN chain integration.
 * @dev This registry allows L2 chains to apply for integration into the Kleros Shared
 *      Sequencer Network. Unlike the operator registries (which use PermanentGTCR with
 *      permanent stakes), this uses a standard GeneralizedTCR pattern where deposits
 *      are returned after successful registration.
 *
 *      Chain Integration Flow:
 *      1. Chain team calls addChain() with deposit + chain metadata
 *      2. Challenge period allows community to dispute invalid chains
 *      3. After period expires (or dispute resolved), chain becomes Registered
 *      4. Hub governance can then call connectChain() using the registered data
 *      5. Chain can request removal via removeChain() if they want to exit KSSN
 *
 *      Acceptance Criteria (enforced via Kleros arbitration):
 *      - Valid OP Stack deployment with accessible SystemConfig
 *      - Chain team has operational capability (infrastructure, monitoring)
 *      - Chain follows KSSN sequencer service-level agreement
 *      - No duplicate chain IDs
 */
interface IChainRegistry {
    // ============ Enums ============

    /**
     * @notice Status of a chain registration item.
     */
    enum Status {
        Absent,                 // Chain not in registry
        RegistrationRequested,  // Registration pending, in challenge period
        Registered,             // Chain is registered and eligible for KSSN
        ClearingRequested       // Removal pending, in challenge period
    }

    /**
     * @notice Parties in a dispute.
     */
    enum Party {
        None,
        Requester,   // Party requesting registration/removal
        Challenger   // Party challenging the request
    }

    // ============ Structs ============

    /**
     * @notice Metadata for a chain registration.
     * @param chainId The L2 chain ID
     * @param systemConfig The SystemConfig contract address on L1
     * @param adapter The OP Stack adapter address
     * @param name Human-readable chain name
     * @param metadataURI IPFS URI with additional chain info (logo, description, etc.)
     */
    struct ChainData {
        uint256 chainId;
        address systemConfig;
        address adapter;
        string name;
        string metadataURI;
    }

    /**
     * @notice A chain registration item in the registry.
     * @param status Current status of the item
     * @param data Chain metadata
     * @param submitter Address that submitted this chain
     * @param submissionTime When the item was submitted
     * @param requestCount Number of requests (challenges) made on this item
     */
    struct Item {
        Status status;
        ChainData data;
        address submitter;
        uint256 submissionTime;
        uint256 requestCount;
    }

    /**
     * @notice A request to change an item's status (registration or clearing).
     * @param disputed Whether this request is under dispute
     * @param disputeID The Kleros dispute ID (if disputed)
     * @param submissionTime When the request was made
     * @param resolved Whether the request has been resolved
     * @param requester Address that made the request
     * @param challenger Address that challenged (if any)
     * @param ruling Final ruling (if resolved)
     * @param arbitrator Arbitrator used for this request
     * @param arbitratorExtraData Extra data for the arbitrator
     * @param deposit Total deposit for this request
     */
    struct Request {
        bool disputed;
        uint256 disputeID;
        uint256 submissionTime;
        bool resolved;
        address payable requester;
        address payable challenger;
        Party ruling;
        IArbitrator arbitrator;
        bytes arbitratorExtraData;
        uint256 deposit;
    }

    // ============ Events ============

    /// @notice Emitted when a chain registration is requested
    event ChainSubmitted(
        bytes32 indexed itemId,
        uint256 indexed chainId,
        address indexed submitter,
        address systemConfig,
        address adapter,
        string name
    );

    /// @notice Emitted when a chain removal is requested
    event ChainRemovalRequested(
        bytes32 indexed itemId,
        uint256 indexed chainId,
        address indexed requester
    );

    /// @notice Emitted when a request is challenged
    event RequestChallenged(
        bytes32 indexed itemId,
        uint256 indexed requestIndex,
        address indexed challenger,
        uint256 disputeID
    );

    /// @notice Emitted when a chain status changes
    event ChainStatusChanged(
        bytes32 indexed itemId,
        uint256 indexed chainId,
        Status newStatus
    );

    /// @notice Emitted when a dispute is resolved
    event DisputeResolved(
        bytes32 indexed itemId,
        uint256 indexed requestIndex,
        Party ruling
    );

    /// @notice Emitted when deposits are withdrawn
    event DepositWithdrawn(
        bytes32 indexed itemId,
        uint256 indexed requestIndex,
        address indexed beneficiary,
        uint256 amount
    );

    // ============ Errors ============

    error InvalidChainId();
    error InvalidSystemConfig();
    error InvalidAdapter();
    error ItemAlreadyExists();
    error ItemDoesNotExist();
    error InvalidStatus();
    error ChallengePeriodNotPassed();
    error AlreadyDisputed();
    error NotDisputed();
    error InsufficientDeposit();
    error NotArbitrator();
    error InvalidRuling();
    error AlreadyResolved();
    error NotSubmitter();
    error TransferFailed();

    // ============ View Functions ============

    /**
     * @notice Returns the item ID for a chain.
     * @param _chainId The chain ID
     * @return The item ID (keccak256 of chainId)
     */
    function getItemId(uint256 _chainId) external pure returns (bytes32);

    /**
     * @notice Returns item info for a chain.
     * @param _itemId The item ID
     * @return item The item struct
     */
    function getItem(bytes32 _itemId) external view returns (Item memory item);

    /**
     * @notice Returns item info by chain ID.
     * @param _chainId The chain ID
     * @return item The item struct
     */
    function getItemByChainId(uint256 _chainId) external view returns (Item memory item);

    /**
     * @notice Returns request info for an item.
     * @param _itemId The item ID
     * @param _requestIndex The request index
     * @return request The request struct
     */
    function getRequest(bytes32 _itemId, uint256 _requestIndex) external view returns (Request memory request);

    /**
     * @notice Checks if a chain is registered.
     * @param _chainId The chain ID
     * @return True if the chain is registered
     */
    function isRegistered(uint256 _chainId) external view returns (bool);

    /**
     * @notice Returns all registered chain IDs.
     * @return Array of registered chain IDs
     */
    function getRegisteredChains() external view returns (uint256[] memory);

    /**
     * @notice Returns the required deposit for registration.
     * @return The deposit amount in wei
     */
    function requiredDeposit() external view returns (uint256);

    /**
     * @notice Returns the challenge period duration.
     * @return The duration in seconds
     */
    function challengePeriod() external view returns (uint256);

    // ============ Registration Functions ============

    /**
     * @notice Submits a chain for registration.
     * @param _chainId The L2 chain ID
     * @param _systemConfig The SystemConfig contract address
     * @param _adapter The OP Stack adapter address
     * @param _name Human-readable chain name
     * @param _metadataURI IPFS URI with additional info
     * @return itemId The item ID for the submission
     */
    function addChain(
        uint256 _chainId,
        address _systemConfig,
        address _adapter,
        string calldata _name,
        string calldata _metadataURI
    ) external payable returns (bytes32 itemId);

    /**
     * @notice Requests removal of a registered chain.
     * @param _chainId The chain ID to remove
     */
    function removeChain(uint256 _chainId) external payable;

    /**
     * @notice Challenges a pending request.
     * @param _itemId The item ID
     * @param _evidence URI to evidence supporting the challenge
     */
    function challengeRequest(bytes32 _itemId, string calldata _evidence) external payable;

    /**
     * @notice Executes a request after the challenge period.
     * @param _itemId The item ID
     */
    function executeRequest(bytes32 _itemId) external;

    // ============ Governance Functions ============

    /**
     * @notice Updates the required deposit amount.
     * @param _newDeposit The new deposit amount
     */
    function setRequiredDeposit(uint256 _newDeposit) external;

    /**
     * @notice Updates the challenge period duration.
     * @param _newPeriod The new period in seconds
     */
    function setChallengePeriod(uint256 _newPeriod) external;

    /**
     * @notice Updates the arbitrator settings.
     * @param _arbitrator The new arbitrator address
     * @param _arbitratorExtraData New extra data for the arbitrator
     */
    function setArbitrator(IArbitrator _arbitrator, bytes calldata _arbitratorExtraData) external;
}
