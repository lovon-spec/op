// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IArbitrator} from "../../src/interfaces/IArbitrator.sol";
import {IArbitrable} from "../../src/interfaces/IArbitrable.sol";

/**
 * @title MockArbitrator
 * @notice Mock Kleros arbitrator for testing PermanentGTCRHybrid.
 * @dev Simulates dispute creation, rulings, and appeals for testing.
 */
contract MockArbitrator is IArbitrator {
    uint256 public constant ARBITRATION_COST = 0.05 ether;
    uint256 public constant APPEAL_COST = 0.1 ether;
    uint256 public constant APPEAL_PERIOD = 1 days;

    struct Dispute {
        address arbitrable;
        uint256 choices;
        uint256 ruling;
        uint256 status; // 0: waiting, 1: appealable, 2: solved
        uint256 appealPeriodStart;
        uint256 appealPeriodEnd;
    }

    mapping(uint256 => Dispute) public disputes;
    uint256 public disputeCount;

    // ============ IArbitrator Implementation ============

    function createDispute(
        uint256 _choices,
        bytes calldata
    ) external payable override returns (uint256 disputeID) {
        require(msg.value >= ARBITRATION_COST, "Insufficient arbitration fee");

        disputeID = disputeCount++;
        disputes[disputeID] = Dispute({
            arbitrable: msg.sender,
            choices: _choices,
            ruling: 0,
            status: 0, // waiting
            appealPeriodStart: 0,
            appealPeriodEnd: 0
        });

        emit DisputeCreation(disputeID, msg.sender);
        return disputeID;
    }

    function arbitrationCost(bytes calldata) external pure override returns (uint256) {
        return ARBITRATION_COST;
    }

    function appealCost(uint256, bytes calldata) external pure override returns (uint256) {
        return APPEAL_COST;
    }

    function currentRuling(uint256 _disputeID) external view override returns (uint256) {
        return disputes[_disputeID].ruling;
    }

    function disputeStatus(uint256 _disputeID) external view override returns (uint256) {
        return disputes[_disputeID].status;
    }

    function appealPeriod(uint256 _disputeID) external view override returns (uint256 start, uint256 end) {
        Dispute storage dispute = disputes[_disputeID];
        return (dispute.appealPeriodStart, dispute.appealPeriodEnd);
    }

    function appeal(uint256 _disputeID, bytes calldata) external payable override {
        require(msg.value >= APPEAL_COST, "Insufficient appeal fee");
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.status == 1, "Not appealable");
        require(
            block.timestamp >= dispute.appealPeriodStart && block.timestamp < dispute.appealPeriodEnd,
            "Not in appeal period"
        );

        // Reset to waiting status
        dispute.status = 0;
        dispute.appealPeriodStart = 0;
        dispute.appealPeriodEnd = 0;
    }

    // ============ Admin Functions (for testing) ============

    /**
     * @notice Gives a ruling for a dispute (simulates Kleros ruling).
     * @param _disputeID The dispute ID.
     * @param _ruling The ruling (0=refuse, 1=submitter wins, 2=challenger wins).
     */
    function giveRuling(uint256 _disputeID, uint256 _ruling) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.status == 0, "Already ruled");
        require(_ruling <= dispute.choices, "Invalid ruling");

        dispute.ruling = _ruling;
        dispute.status = 1; // appealable
        dispute.appealPeriodStart = block.timestamp;
        dispute.appealPeriodEnd = block.timestamp + APPEAL_PERIOD;

        emit AppealPossible(_disputeID, dispute.arbitrable);
    }

    /**
     * @notice Executes a ruling (sends it to the arbitrable contract).
     * @param _disputeID The dispute ID.
     */
    function executeRuling(uint256 _disputeID) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.status == 1, "Not appealable");
        require(block.timestamp >= dispute.appealPeriodEnd, "Appeal period not over");

        dispute.status = 2; // solved

        IArbitrable(dispute.arbitrable).rule(_disputeID, dispute.ruling);

        emit Ruling(address(this), _disputeID, dispute.ruling);
    }

    /**
     * @notice Forces a ruling to be executed immediately (for testing).
     * @param _disputeID The dispute ID.
     * @param _ruling The ruling.
     */
    function forceRuling(uint256 _disputeID, uint256 _ruling) external {
        Dispute storage dispute = disputes[_disputeID];
        dispute.ruling = _ruling;
        dispute.status = 2; // solved

        IArbitrable(dispute.arbitrable).rule(_disputeID, _ruling);

        emit Ruling(address(this), _disputeID, _ruling);
    }

    // Allow receiving ETH
    receive() external payable {}
}
