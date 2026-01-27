// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPermanentGTCRHybrid} from "../../src/interfaces/IPermanentGTCRHybrid.sol";
import {IArbitrator} from "../../src/interfaces/IArbitrator.sol";

/**
 * @title MockPermanentGTCRHybrid
 * @notice Mock Kleros PermanentGTCR Hybrid for testing KlerosSequencerManager.
 * @dev Simulates the hybrid registry with on-chain operational keys.
 *
 * For testing, use:
 * - registerOperatorDirectly(batcher, signer) to add operators with keys
 * - setOperatorStatus(itemID, status) to change status
 * - setOperatorClearingRequested(batcher, signer) to simulate challenge
 */
contract MockPermanentGTCRHybrid is IPermanentGTCRHybrid {
    struct Item {
        Status status;
        uint128 arbitrationDeposit;
        uint120 challengeCount;
        address payable submitter;
        uint48 includedAt;
        uint48 withdrawingTimestamp;
        uint256 stake;
    }

    struct OperatorKeys {
        address batcher;
        address unsafeSigner;
    }

    mapping(bytes32 => Item) private _items;
    mapping(bytes32 => OperatorKeys) public itemKeys;
    bytes32[] public itemList;

    address public override governor;
    address public override arbitrator;
    bytes public override arbitratorExtraData;
    uint256 public override submissionMinDeposit = 0.01 ether;
    uint256 public override challengePeriodDuration = 5 minutes;

    constructor() {
        governor = msg.sender;
    }

    // ============ Admin Functions (for testing) ============

    /**
     * @notice Registers an operator directly with Submitted status.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return itemID The item ID.
     */
    function registerOperatorDirectly(address batcher, address unsafeSigner) external returns (bytes32 itemID) {
        // Create item data (just a hash for testing)
        string memory data = string(abi.encode(batcher, unsafeSigner));
        itemID = keccak256(abi.encodePacked(data));

        require(_items[itemID].status == Status.Absent, "Operator already exists");

        _items[itemID] = Item({
            status: Status.Reincluded, // Use Reincluded for "registered" state
            arbitrationDeposit: 0,
            challengeCount: 0,
            submitter: payable(msg.sender),
            includedAt: uint48(block.timestamp),
            withdrawingTimestamp: 0,
            stake: submissionMinDeposit
        });

        itemKeys[itemID] = OperatorKeys(batcher, unsafeSigner);
        itemList.push(itemID);

        emit ItemSubmitted(itemID, msg.sender, data, submissionMinDeposit);
        emit OperationalKeysUpdated(itemID, batcher, unsafeSigner);
        emit ItemStatusChange(itemID, Status.Reincluded);

        return itemID;
    }

    /**
     * @notice Sets clearing requested for an operator (simulates removal).
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function setOperatorClearingRequested(address batcher, address unsafeSigner) external {
        string memory data = string(abi.encode(batcher, unsafeSigner));
        bytes32 itemID = keccak256(abi.encodePacked(data));

        _items[itemID].status = Status.Absent;
        emit ItemStatusChange(itemID, Status.Absent);
    }

    /**
     * @notice Directly sets an item's status (admin function for testing).
     * @param _itemID The item ID.
     * @param _status The new status.
     */
    function setItemStatus(bytes32 _itemID, Status _status) external {
        _items[_itemID].status = _status;
        emit ItemStatusChange(_itemID, _status);
    }

    /**
     * @notice Helper to compute operator item ID.
     */
    function operatorItemId(address batcher, address unsafeSigner) external pure returns (bytes32) {
        string memory data = string(abi.encode(batcher, unsafeSigner));
        return keccak256(abi.encodePacked(data));
    }

    // ============ IPermanentGTCRHybrid Implementation ============

    function items(bytes32 _itemID) external view override returns (
        Status status,
        uint128 arbitrationDeposit,
        uint120 challengeCount,
        address payable submitter,
        uint48 includedAt,
        uint48 withdrawingTimestamp,
        uint256 stake
    ) {
        Item storage item = _items[_itemID];
        return (
            item.status,
            item.arbitrationDeposit,
            item.challengeCount,
            item.submitter,
            item.includedAt,
            item.withdrawingTimestamp,
            item.stake
        );
    }

    function getOperationalKeys(bytes32 _itemID) public view override returns (
        address batcher,
        address unsafeSigner
    ) {
        OperatorKeys storage keys = itemKeys[_itemID];

        // If keys are set, return them; otherwise default to submitter
        if (keys.batcher != address(0)) {
            return (keys.batcher, keys.unsafeSigner);
        } else {
            return (_items[_itemID].submitter, _items[_itemID].submitter);
        }
    }

    function addItem(string calldata _data, uint256) external payable override returns (bytes32 itemID) {
        require(msg.value >= submissionMinDeposit, "Insufficient deposit");

        itemID = keccak256(abi.encodePacked(_data));
        require(_items[itemID].status == Status.Absent, "Item already exists");

        _items[itemID] = Item({
            status: Status.Submitted,
            arbitrationDeposit: 0,
            challengeCount: 0,
            submitter: payable(msg.sender),
            includedAt: uint48(block.timestamp),
            withdrawingTimestamp: 0,
            stake: msg.value
        });

        // Default keys to submitter
        itemKeys[itemID] = OperatorKeys(msg.sender, msg.sender);
        itemList.push(itemID);

        emit ItemSubmitted(itemID, msg.sender, _data, msg.value);
        emit ItemStatusChange(itemID, Status.Submitted);

        return itemID;
    }

    function challengeItem(bytes32 _itemID) external payable override returns (uint256) {
        require(
            _items[_itemID].status == Status.Submitted ||
            _items[_itemID].status == Status.Reincluded,
            "Cannot challenge"
        );

        _items[_itemID].status = Status.Disputed;
        _items[_itemID].challengeCount++;

        emit ItemChallenged(_itemID, msg.sender, 0);
        emit ItemStatusChange(_itemID, Status.Disputed);

        return 0; // Mock dispute ID
    }

    function executeRequest(bytes32 _itemID) external override {
        require(_items[_itemID].status == Status.Submitted, "Not executable");

        // Check challenge period
        require(
            block.timestamp > _items[_itemID].includedAt + challengePeriodDuration,
            "Challenge period not over"
        );

        _items[_itemID].status = Status.Reincluded;
        emit ItemStatusChange(_itemID, Status.Reincluded);

        // Return stake to submitter
        payable(_items[_itemID].submitter).transfer(_items[_itemID].stake);
    }

    function setOperationalKeys(bytes32 _itemID, address _batcher, address _signer) external override {
        require(msg.sender == _items[_itemID].submitter, "Only submitter");
        require(_items[_itemID].status != Status.Absent, "Item does not exist");
        require(_batcher != address(0) && _signer != address(0), "Invalid keys");

        itemKeys[_itemID] = OperatorKeys(_batcher, _signer);
        emit OperationalKeysUpdated(_itemID, _batcher, _signer);
    }

    // IArbitrable - required by interface
    function rule(uint256, uint256) external pure override {
        revert("Mock: use setItemStatus instead");
    }

    // Allow receiving ETH
    receive() external payable {}
}
