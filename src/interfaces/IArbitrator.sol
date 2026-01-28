// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IArbitrator
 * @notice Interface for Kleros arbitrator contracts.
 * @dev Based on ERC-792 Arbitration Standard.
 */
interface IArbitrator {
    /**
     * @notice Emitted when a dispute is created.
     * @param _disputeID The ID of the dispute.
     * @param _arbitrable The contract requesting arbitration.
     */
    event DisputeCreation(uint256 indexed _disputeID, address indexed _arbitrable);

    /**
     * @notice Emitted when an appeal is possible.
     * @param _disputeID The ID of the dispute.
     * @param _arbitrable The contract that can be appealed.
     */
    event AppealPossible(uint256 indexed _disputeID, address indexed _arbitrable);

    /**
     * @notice Emitted when a dispute receives a ruling.
     * @param _arbitrator The arbitrator giving the ruling.
     * @param _disputeID The ID of the dispute.
     * @param _ruling The ruling given by the arbitrator.
     */
    event Ruling(address indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);

    /**
     * @notice Creates a dispute.
     * @param _choices Amount of choices the arbitrator can make.
     * @param _extraData Additional data for the arbitrator.
     * @return disputeID The ID of the created dispute.
     */
    function createDispute(
        uint256 _choices,
        bytes calldata _extraData
    ) external payable returns (uint256 disputeID);

    /**
     * @notice Computes the cost of arbitration.
     * @param _extraData Additional data for the arbitrator.
     * @return cost The cost of arbitration in wei.
     */
    function arbitrationCost(bytes calldata _extraData) external view returns (uint256 cost);

    /**
     * @notice Computes the cost of appeal.
     * @param _disputeID The ID of the dispute.
     * @param _extraData Additional data for the arbitrator.
     * @return cost The cost of appeal in wei.
     */
    function appealCost(
        uint256 _disputeID,
        bytes calldata _extraData
    ) external view returns (uint256 cost);

    /**
     * @notice Gets the current ruling for a dispute.
     * @param _disputeID The ID of the dispute.
     * @return ruling The current ruling.
     */
    function currentRuling(uint256 _disputeID) external view returns (uint256 ruling);

    /**
     * @notice Gets the status of a dispute.
     * @param _disputeID The ID of the dispute.
     * @return status The status (0: waiting, 1: appealable, 2: solved).
     */
    function disputeStatus(uint256 _disputeID) external view returns (uint256 status);

    /**
     * @notice Gets the appeal period for a dispute.
     * @param _disputeID The ID of the dispute.
     * @return start The start of the appeal period.
     * @return end The end of the appeal period.
     */
    function appealPeriod(uint256 _disputeID) external view returns (uint256 start, uint256 end);
}
