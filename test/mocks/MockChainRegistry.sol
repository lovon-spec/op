// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainRegistry} from "../../src/interfaces/IChainRegistry.sol";
import {IArbitrator} from "../../src/interfaces/IArbitrator.sol";

/**
 * @title MockChainRegistry
 * @notice Mock implementation of ChainRegistry for testing.
 * @dev Provides direct registration without challenge period for easy testing.
 */
contract MockChainRegistry is IChainRegistry {
    // ============ State Variables ============

    /// @notice Required deposit (fixed for testing)
    uint256 public override requiredDeposit = 0.1 ether;

    /// @notice Challenge period (fixed for testing)
    uint256 public override challengePeriod = 5 minutes;

    /// @notice Mapping from item ID to Item
    mapping(bytes32 => Item) internal _items;

    /// @notice Mapping from item ID to request index to Request
    mapping(bytes32 => mapping(uint256 => Request)) internal _requests;

    /// @notice Array of registered chain IDs
    uint256[] internal _registeredChainIds;

    /// @notice Mapping from chain ID to index in array (1-indexed)
    mapping(uint256 => uint256) internal _chainIdToIndex;

    // ============ View Functions ============

    function getItemId(uint256 _chainId) public pure override returns (bytes32) {
        return keccak256(abi.encode(_chainId));
    }

    function getItem(bytes32 _itemId) external view override returns (Item memory) {
        return _items[_itemId];
    }

    function getItemByChainId(uint256 _chainId) external view override returns (Item memory) {
        return _items[getItemId(_chainId)];
    }

    function getRequest(bytes32 _itemId, uint256 _requestIndex) external view override returns (Request memory) {
        return _requests[_itemId][_requestIndex];
    }

    function isRegistered(uint256 _chainId) external view override returns (bool) {
        bytes32 itemId = getItemId(_chainId);
        return _items[itemId].status == Status.Registered;
    }

    function getRegisteredChains() external view override returns (uint256[] memory) {
        return _registeredChainIds;
    }

    // ============ Registration Functions ============

    function addChain(
        uint256 _chainId,
        address _rollupConfig,
        address _adapter,
        string calldata _name,
        string calldata _metadataURI
    ) external payable override returns (bytes32 itemId) {
        if (_chainId == 0) revert InvalidChainId();
        if (_rollupConfig == address(0)) revert InvalidRollupConfig();
        if (_adapter == address(0)) revert InvalidAdapter();

        itemId = getItemId(_chainId);
        Item storage item = _items[itemId];

        if (item.status != Status.Absent) revert ItemAlreadyExists();

        item.status = Status.RegistrationRequested;
        item.data = ChainData({
            chainId: _chainId,
            rollupConfig: _rollupConfig,
            adapter: _adapter,
            name: _name,
            metadataURI: _metadataURI
        });
        item.submitter = msg.sender;
        item.submissionTime = block.timestamp;
        item.requestCount = 1;

        _requests[itemId][0].submissionTime = block.timestamp;
        _requests[itemId][0].requester = payable(msg.sender);
        _requests[itemId][0].deposit = msg.value;

        emit ChainSubmitted(
            itemId,
            _chainId,
            msg.sender,
            _rollupConfig,
            _adapter,
            _name
        );

        return itemId;
    }

    function removeChain(uint256 _chainId) external payable override {
        bytes32 itemId = getItemId(_chainId);
        Item storage item = _items[itemId];

        if (item.status != Status.Registered) revert InvalidStatus();

        item.status = Status.ClearingRequested;
        item.requestCount++;

        emit ChainRemovalRequested(itemId, _chainId, msg.sender);
    }

    function challengeRequest(bytes32 _itemId, string calldata _evidence) external payable override {
        Item storage item = _items[_itemId];

        if (item.status != Status.RegistrationRequested &&
            item.status != Status.ClearingRequested) {
            revert InvalidStatus();
        }

        uint256 requestIndex = item.requestCount - 1;
        Request storage request = _requests[_itemId][requestIndex];

        if (request.disputed) revert AlreadyDisputed();

        request.disputed = true;
        request.challenger = payable(msg.sender);

        emit RequestChallenged(_itemId, requestIndex, msg.sender, 0);
    }

    function executeRequest(bytes32 _itemId) external override {
        Item storage item = _items[_itemId];
        uint256 requestIndex = item.requestCount - 1;
        Request storage request = _requests[_itemId][requestIndex];

        if (request.disputed) revert AlreadyDisputed();
        if (request.resolved) revert AlreadyResolved();

        if (block.timestamp < request.submissionTime + challengePeriod) {
            revert ChallengePeriodNotPassed();
        }

        request.resolved = true;
        Status oldStatus = item.status;

        if (oldStatus == Status.RegistrationRequested) {
            item.status = Status.Registered;
            _addToRegisteredChains(item.data.chainId);
        } else if (oldStatus == Status.ClearingRequested) {
            item.status = Status.Absent;
            _removeFromRegisteredChains(item.data.chainId);
        }

        emit ChainStatusChanged(_itemId, item.data.chainId, item.status);
    }

    // ============ Test Helper Functions ============

    /**
     * @notice Directly registers a chain (bypasses challenge period).
     * @dev For testing only - sets status directly to Registered.
     */
    function registerChainDirectly(
        uint256 _chainId,
        address _rollupConfig,
        address _adapter,
        string calldata _name
    ) external returns (bytes32 itemId) {
        itemId = getItemId(_chainId);
        Item storage item = _items[itemId];

        item.status = Status.Registered;
        item.data = ChainData({
            chainId: _chainId,
            rollupConfig: _rollupConfig,
            adapter: _adapter,
            name: _name,
            metadataURI: ""
        });
        item.submitter = msg.sender;
        item.submissionTime = block.timestamp;

        _addToRegisteredChains(_chainId);

        emit ChainStatusChanged(itemId, _chainId, Status.Registered);

        return itemId;
    }

    /**
     * @notice Sets item status directly for testing.
     */
    function setItemStatus(bytes32 _itemId, Status _status) external {
        _items[_itemId].status = _status;
    }

    /**
     * @notice Unregisters a chain directly for testing.
     */
    function unregisterChainDirectly(uint256 _chainId) external {
        bytes32 itemId = getItemId(_chainId);
        _items[itemId].status = Status.Absent;
        _removeFromRegisteredChains(_chainId);
    }

    // ============ Governance Functions (No-op for testing) ============

    function setRequiredDeposit(uint256 _newDeposit) external override {
        requiredDeposit = _newDeposit;
    }

    function setChallengePeriod(uint256 _newPeriod) external override {
        challengePeriod = _newPeriod;
    }

    function setArbitrator(IArbitrator, bytes calldata) external override {
        // No-op for testing
    }

    // ============ Internal Functions ============

    function _addToRegisteredChains(uint256 _chainId) internal {
        if (_chainIdToIndex[_chainId] == 0) {
            _registeredChainIds.push(_chainId);
            _chainIdToIndex[_chainId] = _registeredChainIds.length;
        }
    }

    function _removeFromRegisteredChains(uint256 _chainId) internal {
        uint256 index = _chainIdToIndex[_chainId];
        if (index != 0) {
            uint256 arrayIndex = index - 1;
            uint256 lastIndex = _registeredChainIds.length - 1;

            if (arrayIndex != lastIndex) {
                uint256 lastChainId = _registeredChainIds[lastIndex];
                _registeredChainIds[arrayIndex] = lastChainId;
                _chainIdToIndex[lastChainId] = index;
            }

            _registeredChainIds.pop();
            delete _chainIdToIndex[_chainId];
        }
    }

    receive() external payable {}
}
