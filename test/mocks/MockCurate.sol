// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICurate} from "../../src/interfaces/ICurate.sol";

/**
 * @title MockCurate
 * @notice Mock Kleros Curate Classic (GeneralizedTCR) for testing KlerosSequencerManager.
 * @dev Simulates the core functionality needed for testing the sequencer manager:
 *      - Item registration and status tracking
 *      - Status transitions (Absent -> Registered, Registered -> ClearingRequested, etc.)
 *
 * For the Constitutional L2, operators are registered as tuples (batcher, unsafeSigner).
 * Use registerOperatorDirectly() for convenient operator registration in tests.
 */
contract MockCurate is ICurate {
    struct Item {
        bytes data;
        Status status;
        uint256 numberOfRequests;
    }

    mapping(bytes32 => Item) public items;
    bytes32[] public itemList;

    uint256 public submissionBaseDeposit = 0.1 ether;
    uint256 public removalBaseDeposit = 0.1 ether;
    uint256 public submissionChallengeBaseDeposit = 0.1 ether;
    uint256 public removalChallengeBaseDeposit = 0.1 ether;
    uint256 public challengePeriodDuration = 3 days;

    // Events for testing
    event ItemAdded(bytes32 indexed itemID, bytes data);
    event ItemStatusChanged(bytes32 indexed itemID, Status newStatus);
    event ItemRemovalRequested(bytes32 indexed itemID);
    event RequestChallenged(bytes32 indexed itemID);
    event RequestExecuted(bytes32 indexed itemID);

    // ============ Admin Functions (for testing) ============

    /**
     * @notice Directly sets an item's status (admin function for testing).
     * @param _itemID The item ID.
     * @param _status The new status.
     */
    function setItemStatus(bytes32 _itemID, Status _status) external {
        items[_itemID].status = _status;
        emit ItemStatusChanged(_itemID, _status);
    }

    /**
     * @notice Registers an operator tuple directly (helper for testing).
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function registerOperatorDirectly(address batcher, address unsafeSigner) external {
        bytes memory data = abi.encode(batcher, unsafeSigner);
        bytes32 itemID = keccak256(abi.encodePacked(data));
        require(items[itemID].status == Status.Absent, "Operator already exists");

        items[itemID] = Item({data: data, status: Status.Registered, numberOfRequests: 1});
        itemList.push(itemID);

        emit ItemAdded(itemID, data);
        emit ItemStatusChanged(itemID, Status.Registered);
    }

    /**
     * @notice Sets clearing requested for an operator (simulates challenge).
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function setOperatorClearingRequested(address batcher, address unsafeSigner) external {
        bytes memory data = abi.encode(batcher, unsafeSigner);
        bytes32 itemID = keccak256(abi.encodePacked(data));
        require(items[itemID].status == Status.Registered, "Operator not registered");

        items[itemID].status = Status.ClearingRequested;
        items[itemID].numberOfRequests++;
        emit ItemStatusChanged(itemID, Status.ClearingRequested);
    }

    /**
     * @notice Removes an operator (sets to Absent).
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function removeOperatorDirectly(address batcher, address unsafeSigner) external {
        bytes memory data = abi.encode(batcher, unsafeSigner);
        bytes32 itemID = keccak256(abi.encodePacked(data));
        items[itemID].status = Status.Absent;
        emit ItemStatusChanged(itemID, Status.Absent);
    }

    /**
     * @notice Helper to compute operator item ID.
     */
    function operatorItemId(address batcher, address unsafeSigner) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(abi.encode(batcher, unsafeSigner)));
    }

    /**
     * @notice Registers an item directly (admin function for testing).
     * @param _data The item data (e.g., ABI-encoded address).
     */
    function registerItemDirectly(bytes calldata _data) external {
        bytes32 itemID = keccak256(abi.encodePacked(_data));
        require(items[itemID].status == Status.Absent, "Item already exists");

        items[itemID] = Item({data: _data, status: Status.Registered, numberOfRequests: 1});
        itemList.push(itemID);

        emit ItemAdded(itemID, _data);
        emit ItemStatusChanged(itemID, Status.Registered);
    }

    /**
     * @notice Marks an item as having a clearing request (simulates challenge).
     * @param _itemID The item ID.
     */
    function setClearingRequested(bytes32 _itemID) external {
        require(items[_itemID].status == Status.Registered, "Item not registered");
        items[_itemID].status = Status.ClearingRequested;
        items[_itemID].numberOfRequests++;
        emit ItemStatusChanged(_itemID, Status.ClearingRequested);
    }

    /**
     * @notice Removes an item (sets to Absent).
     * @param _itemID The item ID.
     */
    function removeItemDirectly(bytes32 _itemID) external {
        items[_itemID].status = Status.Absent;
        emit ItemStatusChanged(_itemID, Status.Absent);
    }

    // ============ ICurate Interface Implementation ============

    function getItemInfo(
        bytes32 _itemID
    ) external view override returns (bytes memory data, Status status, uint256 numberOfRequests) {
        Item storage item = items[_itemID];
        return (item.data, item.status, item.numberOfRequests);
    }

    function itemCount() external view override returns (uint256) {
        return itemList.length;
    }

    function addItem(bytes calldata _item) external payable override {
        require(msg.value >= submissionBaseDeposit, "Insufficient deposit");

        bytes32 itemID = keccak256(abi.encodePacked(_item));
        require(items[itemID].status == Status.Absent, "Item already exists");

        items[itemID] = Item({
            data: _item,
            status: Status.RegistrationRequested,
            numberOfRequests: 1
        });
        itemList.push(itemID);

        emit ItemAdded(itemID, _item);
        emit ItemStatusChanged(itemID, Status.RegistrationRequested);
    }

    function removeItem(bytes32 _itemID, string calldata) external payable override {
        require(msg.value >= removalBaseDeposit, "Insufficient deposit");
        require(items[_itemID].status == Status.Registered, "Item not registered");

        items[_itemID].status = Status.ClearingRequested;
        items[_itemID].numberOfRequests++;

        emit ItemRemovalRequested(_itemID);
        emit ItemStatusChanged(_itemID, Status.ClearingRequested);
    }

    function challengeRequest(bytes32 _itemID, string calldata) external payable override {
        Status status = items[_itemID].status;
        require(
            status == Status.RegistrationRequested || status == Status.ClearingRequested,
            "No pending request"
        );

        uint256 requiredDeposit = status == Status.RegistrationRequested
            ? submissionChallengeBaseDeposit
            : removalChallengeBaseDeposit;
        require(msg.value >= requiredDeposit, "Insufficient deposit");

        emit RequestChallenged(_itemID);
    }

    function executeRequest(bytes32 _itemID) external override {
        Status status = items[_itemID].status;

        if (status == Status.RegistrationRequested) {
            items[_itemID].status = Status.Registered;
            emit ItemStatusChanged(_itemID, Status.Registered);
        } else if (status == Status.ClearingRequested) {
            items[_itemID].status = Status.Absent;
            emit ItemStatusChanged(_itemID, Status.Absent);
        } else {
            revert("No pending request to execute");
        }

        emit RequestExecuted(_itemID);
    }

    function getRequestInfo(
        bytes32,
        uint256
    )
        external
        pure
        override
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
        )
    {
        // Return default values for mock
        return (false, 0, 0, false, [payable(address(0)), payable(address(0)), payable(address(0))], 0, 0, address(0), "", 0);
    }
}
