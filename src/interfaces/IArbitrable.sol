// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IArbitrator} from "./IArbitrator.sol";

/**
 * @title IArbitrable
 * @notice Interface for contracts that can be arbitrated.
 * @dev Based on ERC-792 Arbitration Standard.
 */
interface IArbitrable {
    /**
     * @notice Emitted when a ruling is executed.
     * @param _arbitrator The arbitrator giving the ruling.
     * @param _disputeID The ID of the dispute.
     * @param _ruling The ruling given by the arbitrator.
     */
    event Ruling(
        IArbitrator indexed _arbitrator,
        uint256 indexed _disputeID,
        uint256 _ruling
    );

    /**
     * @notice Gives a ruling for a dispute.
     * @dev Must only be called by the arbitrator.
     * @param _disputeID The ID of the dispute.
     * @param _ruling The ruling given.
     */
    function rule(uint256 _disputeID, uint256 _ruling) external;
}
