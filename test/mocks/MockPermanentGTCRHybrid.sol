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
 * - registerOperatorDirectly(batcher, signer) to add operators with keys (skips challenge)
 * - setOperatorStatus(itemID, status) to change status
 * - setOperatorClearingRequested(batcher, signer) to simulate removal
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
    IArbitrator public override arbitrator;
    uint256 public override submissionMinDeposit = 0.01 ether;
    uint256 public override submissionPeriod = 5 minutes;
    uint256 public override reinclusionPeriod = 5 minutes;
    uint256 public override withdrawingPeriod = 1 minutes;

    constructor() {
        governor = msg.sender;
    }

    // ============ Admin Functions (for testing) ============

    /**
     * @notice Registers an operator directly with Reincluded status (bypasses challenge).
     * @dev Sets includedAt in the past so items are immediately valid for sync.
     *      This simulates an operator that has already passed the maturity period.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return itemID The item ID.
     */
    function registerOperatorDirectly(address batcher, address unsafeSigner) external returns (bytes32 itemID) {
        // Create item data (just a hash for testing)
        string memory data = string(abi.encode(batcher, unsafeSigner));
        itemID = keccak256(abi.encodePacked(data));

        require(_items[itemID].status == Status.Absent, "Operator already exists");

        // Set includedAt in the past so item is immediately valid for sync
        // (block.timestamp - reinclusionPeriod - 1 ensures maturity check passes)
        uint48 pastTimestamp = uint48(block.timestamp > reinclusionPeriod + 1 ? block.timestamp - reinclusionPeriod - 1 : 0);

        _items[itemID] = Item({
            status: Status.Reincluded, // Use Reincluded for "registered" state
            arbitrationDeposit: 0,
            challengeCount: 0,
            submitter: payable(msg.sender),
            includedAt: pastTimestamp,
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
     * @notice Directly sets an item's includedAt timestamp (for testing maturity).
     * @param _itemID The item ID.
     * @param _includedAt The new includedAt timestamp.
     */
    function setIncludedAt(bytes32 _itemID, uint48 _includedAt) external {
        _items[_itemID].includedAt = _includedAt;
    }

    /**
     * @notice Directly sets an item's withdrawingTimestamp (for testing withdrawal lock).
     * @param _itemID The item ID.
     * @param _withdrawingTimestamp The new withdrawingTimestamp.
     */
    function setWithdrawingTimestamp(bytes32 _itemID, uint48 _withdrawingTimestamp) external {
        _items[_itemID].withdrawingTimestamp = _withdrawingTimestamp;
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

    function isRegistered(bytes32 _itemID) external view override returns (bool) {
        Status status = _items[_itemID].status;
        return status == Status.Submitted || status == Status.Reincluded;
    }

    function isChallengeable(bytes32 _itemID) external view override returns (bool) {
        Item storage item = _items[_itemID];

        // Items that have completed withdrawal period are not challengeable
        if (item.withdrawingTimestamp > 0 &&
            block.timestamp >= item.withdrawingTimestamp + withdrawingPeriod) {
            return false;
        }

        // Both Submitted and Reincluded items are challengeable FOREVER
        // (no time restriction - "Challengeable Forever" semantics)
        if (item.status == Status.Submitted || item.status == Status.Reincluded) {
            return true;
        }

        return false;
    }

    function isValidForSync(bytes32 _itemID) external view override returns (bool) {
        Item storage item = _items[_itemID];

        uint256 duration;

        if (item.status == Status.Submitted) {
            duration = submissionPeriod;
        } else if (item.status == Status.Reincluded) {
            duration = reinclusionPeriod;
        } else {
            return false;
        }

        // MATURITY CHECK: Item must be older than the required period
        return block.timestamp > item.includedAt + duration;
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

    function addItem(string calldata _data) external payable override {
        require(msg.value >= submissionMinDeposit, "Insufficient deposit");

        bytes32 itemID = keccak256(abi.encodePacked(_data));
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
    }

    function addItemWithKeys(
        string calldata _data,
        address _batcher,
        address _signer
    ) external payable override returns (bytes32 itemID) {
        require(msg.value >= submissionMinDeposit, "Insufficient deposit");
        require(_batcher != address(0) && _signer != address(0), "Invalid keys");

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

        itemKeys[itemID] = OperatorKeys(_batcher, _signer);
        itemList.push(itemID);

        emit ItemSubmitted(itemID, msg.sender, _data, msg.value);
        emit ItemStatusChange(itemID, Status.Submitted);
        emit OperationalKeysUpdated(itemID, _batcher, _signer);

        return itemID;
    }

    function challengeItem(bytes32 _itemID, string calldata) external payable override {
        require(
            _items[_itemID].status == Status.Submitted ||
            _items[_itemID].status == Status.Reincluded,
            "Cannot challenge"
        );

        _items[_itemID].status = Status.Disputed;
        _items[_itemID].challengeCount++;

        emit ItemChallenged(_itemID, _items[_itemID].challengeCount - 1, 0);
        emit ItemStatusChange(_itemID, Status.Disputed);
    }

    function executeRequest(bytes32 _itemID) external override {
        require(_items[_itemID].status == Status.Submitted, "Not executable");

        // Check challenge period
        require(
            block.timestamp > _items[_itemID].includedAt + submissionPeriod,
            "Challenge period not over"
        );

        _items[_itemID].status = Status.Reincluded;
        emit ItemStatusChange(_itemID, Status.Reincluded);

        // Return stake to submitter
        payable(_items[_itemID].submitter).transfer(_items[_itemID].stake);
    }

    function requestWithdrawal(bytes32 _itemID) external override {
        require(msg.sender == _items[_itemID].submitter, "Only submitter");
        require(_items[_itemID].status == Status.Reincluded, "Not registered");

        _items[_itemID].withdrawingTimestamp = uint48(block.timestamp);
    }

    function withdraw(bytes32 _itemID) external override {
        require(_items[_itemID].withdrawingTimestamp != 0, "Not withdrawing");
        require(
            block.timestamp >= _items[_itemID].withdrawingTimestamp + withdrawingPeriod,
            "Withdrawing period not over"
        );

        _items[_itemID].status = Status.Absent;
        _items[_itemID].withdrawingTimestamp = 0;
        delete itemKeys[_itemID];

        emit ItemStatusChange(_itemID, Status.Absent);
    }

    function cancelWithdrawal(bytes32 _itemID) external override {
        require(msg.sender == _items[_itemID].submitter, "Only submitter");
        require(_items[_itemID].withdrawingTimestamp != 0, "Not withdrawing");

        _items[_itemID].withdrawingTimestamp = 0;
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
