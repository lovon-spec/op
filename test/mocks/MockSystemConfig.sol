// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISystemConfig} from "../../src/interfaces/ISystemConfig.sol";

/**
 * @title MockSystemConfig
 * @notice Mock OP Stack SystemConfig for testing KlerosSequencerManager.
 */
contract MockSystemConfig is ISystemConfig {
    bytes32 private _batcherHash;
    address private _owner;

    event BatcherHashSet(bytes32 indexed batcherHash);

    constructor() {
        _owner = msg.sender;
    }

    function setBatcherHash(bytes32 batcherHash_) external override {
        require(msg.sender == _owner, "SystemConfig: caller is not the owner");
        _batcherHash = batcherHash_;
        emit BatcherHashSet(batcherHash_);
    }

    function batcherHash() external view override returns (bytes32) {
        return _batcherHash;
    }

    function owner() external view override returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == _owner, "SystemConfig: caller is not the owner");
        _owner = newOwner;
    }
}
