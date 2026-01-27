// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IArbitrable} from "./IArbitrable.sol";

/**
 * @title IPermanentGTCRHybrid
 * @notice Interface for the Hybrid PermanentGTCR registry.
 * @dev Extends standard PGTCR with parallel on-chain operational keys storage.
 *
 * Architecture:
 * - Standard PGTCR storage for Owner/Submitter (staker) - compatible with Kleros UI
 * - Parallel `itemKeys` mapping for operational keys (batcher/signer)
 * - Keys default to owner if not explicitly set
 *
 * This allows:
 * - "Cold Staker / Hot Operator" model (stake holder != operational keys)
 * - On-chain key verification without IPFS lookups
 * - Full compatibility with curate.kleros.io
 */
interface IPermanentGTCRHybrid is IArbitrable {
    // ============ Enums ============

    /// @notice Status of an item in the registry.
    enum Status {
        Absent,      // Item does not exist
        Submitted,   // Item submitted, waiting for challenge period
        Reincluded,  // Item reincluded after removal
        Disputed     // Item currently under dispute
    }

    // ============ Events ============

    /// @notice Emitted when an item is submitted to the registry.
    event ItemSubmitted(
        bytes32 indexed _itemID,
        address indexed _submitter,
        string _data,
        uint256 _deposit
    );

    /// @notice Emitted when an item is challenged.
    event ItemChallenged(
        bytes32 indexed _itemID,
        address indexed _challenger,
        uint256 _disputeID
    );

    /// @notice Emitted when an item's status changes.
    event ItemStatusChange(
        bytes32 indexed _itemID,
        Status _status
    );

    /// @notice Emitted when operational keys are updated for an item.
    event OperationalKeysUpdated(
        bytes32 indexed _itemID,
        address indexed _batcher,
        address indexed _signer
    );

    // ============ Standard PGTCR Views ============

    /**
     * @notice Gets the full item data.
     * @param _itemID The ID of the item.
     * @return status The current status.
     * @return arbitrationDeposit Deposit for arbitration costs.
     * @return challengeCount Number of times challenged.
     * @return submitter The address that submitted the item (stake owner).
     * @return includedAt Timestamp when item was included.
     * @return withdrawingTimestamp Timestamp when withdrawal was requested.
     * @return stake The amount staked on this item.
     */
    function items(bytes32 _itemID) external view returns (
        Status status,
        uint128 arbitrationDeposit,
        uint120 challengeCount,
        address payable submitter,
        uint48 includedAt,
        uint48 withdrawingTimestamp,
        uint256 stake
    );

    /**
     * @notice Gets the arbitrator contract.
     */
    function arbitrator() external view returns (address);

    /**
     * @notice Gets the arbitrator extra data.
     */
    function arbitratorExtraData() external view returns (bytes memory);

    /**
     * @notice Gets the minimum submission deposit.
     */
    function submissionMinDeposit() external view returns (uint256);

    /**
     * @notice Gets the challenge period duration.
     */
    function challengePeriodDuration() external view returns (uint256);

    /**
     * @notice Gets the governor address.
     */
    function governor() external view returns (address);

    // ============ Hybrid Extension Views ============

    /**
     * @notice Gets the operational keys for an item.
     * @dev Returns the owner address for both if keys not explicitly set.
     * @param _itemID The ID of the item.
     * @return batcher The batcher address (for L1 batch submissions).
     * @return unsafeSigner The unsafe block signer address (for P2P).
     */
    function getOperationalKeys(bytes32 _itemID) external view returns (
        address batcher,
        address unsafeSigner
    );

    // ============ Mutating Functions ============

    /**
     * @notice Submits an item to the registry.
     * @param _data The item data (IPFS URI for Kleros UI compatibility).
     * @param _deposit The deposit amount.
     * @return itemID The ID of the submitted item.
     */
    function addItem(string calldata _data, uint256 _deposit) external payable returns (bytes32 itemID);

    /**
     * @notice Challenges an item.
     * @param _itemID The ID of the item to challenge.
     * @return disputeID The ID of the created dispute.
     */
    function challengeItem(bytes32 _itemID) external payable returns (uint256 disputeID);

    /**
     * @notice Executes a pending request (after challenge period).
     * @param _itemID The ID of the item.
     */
    function executeRequest(bytes32 _itemID) external;

    /**
     * @notice Sets the operational keys for an item.
     * @dev Only the item submitter (stake owner) can call this.
     * @param _itemID The ID of the item.
     * @param _batcher The batcher address.
     * @param _signer The unsafe block signer address.
     */
    function setOperationalKeys(bytes32 _itemID, address _batcher, address _signer) external;
}
