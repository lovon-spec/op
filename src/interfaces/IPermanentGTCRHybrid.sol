// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IArbitrable} from "./IArbitrable.sol";
import {IArbitrator} from "./IArbitrator.sol";

/**
 * @title IPermanentGTCRHybrid
 * @notice Interface for the Hybrid PermanentGTCR registry.
 * @dev Based on the original Kleros PermanentGTCR with operational keys extension.
 *      https://github.com/kleros/pgtcr/blob/master/contracts/src/PermanentGTCR.sol
 */
interface IPermanentGTCRHybrid is IArbitrable {
    // ============ Enums ============

    enum Status {
        Absent,     // Item does not exist
        Submitted,  // Item submitted, in challenge period
        Reincluded, // Item permanently included
        Disputed    // Item under dispute
    }

    enum Party {
        None,
        Submitter,
        Challenger
    }

    // ============ Events ============

    event ItemSubmitted(
        bytes32 indexed _itemID,
        address indexed _submitter,
        string _data,
        uint256 _stake
    );

    event ItemChallenged(
        bytes32 indexed _itemID,
        uint256 indexed _challengeID,
        uint256 indexed _disputeID
    );

    event ItemStatusChange(bytes32 indexed _itemID, Status _status);

    event OperationalKeysUpdated(
        bytes32 indexed _itemID,
        address indexed _batcher,
        address indexed _signer
    );

    // ============ View Functions ============

    /**
     * @notice Gets the full item data.
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

    function governor() external view returns (address);
    function arbitrator() external view returns (IArbitrator);
    function submissionMinDeposit() external view returns (uint256);
    function submissionPeriod() external view returns (uint256);
    function reinclusionPeriod() external view returns (uint256);
    function withdrawingPeriod() external view returns (uint256);
    function isRegistered(bytes32 _itemID) external view returns (bool);

    // ============ Hybrid Extension ============

    /**
     * @notice Gets the operational keys for an item.
     * @dev Returns submitter address for both if keys not explicitly set.
     */
    function getOperationalKeys(bytes32 _itemID) external view returns (
        address batcher,
        address unsafeSigner
    );

    /**
     * @notice Sets the operational keys for an item.
     * @dev Only the item submitter can call this.
     */
    function setOperationalKeys(
        bytes32 _itemID,
        address _batcher,
        address _signer
    ) external;

    // ============ Mutating Functions ============

    function addItem(string calldata _data) external payable;

    function addItemWithKeys(
        string calldata _data,
        address _batcher,
        address _signer
    ) external payable returns (bytes32 itemID);

    function challengeItem(bytes32 _itemID, string calldata _evidence) external payable;

    function executeRequest(bytes32 _itemID) external;

    function requestWithdrawal(bytes32 _itemID) external;

    function withdraw(bytes32 _itemID) external;

    function cancelWithdrawal(bytes32 _itemID) external;
}
