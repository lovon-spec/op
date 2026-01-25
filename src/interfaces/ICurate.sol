// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICurate
 * @notice Interface for Kleros Curate Classic (GeneralizedTCR) registry.
 * @dev This is the interface for the original Curate contract that stores
 *      all item data on-chain, allowing other contracts to query item status.
 *
 * Reference: https://github.com/kleros/tcr/blob/master/contracts/GeneralizedTCR.sol
 */
interface ICurate {
    /**
     * @notice Status of an item in the registry.
     */
    enum Status {
        Absent, // The item is not in the registry.
        Registered, // The item is in the registry.
        RegistrationRequested, // The item has a request to be added to the registry.
        ClearingRequested // The item has a request to be removed from the registry.
    }

    /**
     * @notice Gets information about an item.
     * @param _itemID The ID of the item to query.
     * @return data The data associated with the item (e.g., ABI-encoded address).
     * @return status The current status of the item.
     * @return numberOfRequests The total number of requests made for this item.
     */
    function getItemInfo(
        bytes32 _itemID
    ) external view returns (bytes memory data, Status status, uint256 numberOfRequests);

    /**
     * @notice Gets the total number of items submitted to the registry.
     * @return The count of items.
     */
    function itemCount() external view returns (uint256);

    /**
     * @notice Gets the item ID at a specific index in the items array.
     * @param _index The index of the item.
     * @return The item ID.
     */
    function itemList(uint256 _index) external view returns (bytes32);

    /**
     * @notice Submits an item to the registry.
     * @param _item The data describing the item (e.g., ABI-encoded address).
     */
    function addItem(bytes calldata _item) external payable;

    /**
     * @notice Submits a request to remove an item from the registry.
     * @param _itemID The ID of the item to remove.
     * @param _evidence A link to evidence supporting the removal request.
     */
    function removeItem(bytes32 _itemID, string calldata _evidence) external payable;

    /**
     * @notice Challenges the latest request for an item.
     * @param _itemID The ID of the item with the request to challenge.
     * @param _evidence A link to evidence supporting the challenge.
     */
    function challengeRequest(bytes32 _itemID, string calldata _evidence) external payable;

    /**
     * @notice Executes a request that has passed the challenge period.
     * @param _itemID The ID of the item to execute.
     */
    function executeRequest(bytes32 _itemID) external;

    /**
     * @notice Gets information about a specific request.
     * @param _itemID The ID of the item.
     * @param _request The request index.
     * @return disputed True if the request has been disputed.
     * @return disputeID The ID of the dispute (if any).
     * @return submissionTime The time the request was submitted.
     * @return resolved True if the request has been resolved.
     * @return parties The parties involved [requester, challenger].
     * @return numberOfRounds The number of funding rounds.
     * @return ruling The final ruling given by the arbitrator (if resolved).
     * @return arbitrator The arbitrator used for the request.
     * @return arbitratorExtraData Extra data for the arbitrator.
     * @return metaEvidenceID The meta evidence ID for this request type.
     */
    function getRequestInfo(
        bytes32 _itemID,
        uint256 _request
    )
        external
        view
        returns (
            bool disputed,
            uint256 disputeID,
            uint256 submissionTime,
            bool resolved,
            address payable[3] memory parties,
            uint256 numberOfRounds,
            uint256 ruling,
            address arbitrator,
            bytes memory arbitratorExtraData,
            uint256 metaEvidenceID
        );

    /**
     * @notice The amount required to submit/remove an item or challenge a request.
     * @return The base deposit amount.
     */
    function submissionBaseDeposit() external view returns (uint256);

    /**
     * @notice The base deposit for removing an item.
     * @return The removal base deposit amount.
     */
    function removalBaseDeposit() external view returns (uint256);

    /**
     * @notice The base deposit for challenging a submission.
     * @return The submission challenge deposit amount.
     */
    function submissionChallengeBaseDeposit() external view returns (uint256);

    /**
     * @notice The base deposit for challenging a removal.
     * @return The removal challenge deposit amount.
     */
    function removalChallengeBaseDeposit() external view returns (uint256);

    /**
     * @notice The time in seconds parties have to challenge a request.
     * @return The challenge period duration.
     */
    function challengePeriodDuration() external view returns (uint256);
}
