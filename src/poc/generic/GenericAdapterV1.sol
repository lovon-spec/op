// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISequencerAdapter} from "../../interfaces/ISequencerAdapter.sol";

/**
 * @title GenericAdapterV1
 * @notice Generic rollup adapter for chains with simple sequencer rotation.
 * @dev This adapter supports any rollup that implements a standard interface
 *      for sequencer rotation via a single function call. It uses a configurable
 *      function selector and ABI encoding to support heterogeneous chains.
 *
 *      Supports two modes:
 *      1. Direct call: Calls a function directly on the rollup config contract
 *      2. Multi-call: Executes multiple function calls for complex rotations
 *
 *      This adapter is designed as a plug-and-play solution for chains that
 *      don't need a specialized adapter (like OP Stack or Arbitrum).
 *
 *      Rotation payload format:
 *      Single call: abi.encode(bytes4 selector, bytes callData)
 *      Multi-call:  abi.encode(bytes4[] selectors, bytes[] callDatas)
 *
 *      Future adapters (e.g., Cosmos/IBC) can extend this pattern.
 *
 *      Version: 1.0.0 (1_000_000)
 */
contract GenericAdapterV1 is ISequencerAdapter {
    // ============ Errors ============

    error RotationFailed(string reason);
    error InvalidRollupConfig();
    error InvalidRotationPayload();
    error CallFailed(uint256 index);

    // ============ Events ============

    event SequencerRotated(address indexed rollupConfig, bytes4 selector);
    event MultiCallExecuted(address indexed rollupConfig, uint256 callCount);

    // ============ Constants ============

    uint256 public constant VERSION = 1_000_000;
    string public constant NAME = "GenericAdapterV1";
    string public constant DESCRIPTION =
        "Generic rollup adapter with configurable rotation calls";

    /// @notice Magic byte prefix for multi-call mode
    bytes1 public constant MULTI_CALL_PREFIX = 0xFF;

    // ============ View Functions ============

    function version() external pure override returns (uint256) {
        return VERSION;
    }

    function adapterInfo()
        external
        pure
        override
        returns (string memory name, string memory description)
    {
        return (NAME, DESCRIPTION);
    }

    // ============ Mutating Functions ============

    /**
     * @inheritdoc ISequencerAdapter
     * @dev Supports single-call and multi-call rotation modes.
     *
     *      Single call payload: abi.encode(bytes4 selector, bytes callData)
     *      The adapter calls rollupConfig.call(abi.encodePacked(selector, callData))
     *
     *      Multi-call payload: abi.encode(0xFF, bytes4[] selectors, bytes[] callDatas)
     *      The adapter calls each (selector, callData) pair in order
     */
    function rotateSequencer(address _rollupConfig, bytes calldata _rotationData) external override {
        if (_rollupConfig == address(0)) {
            revert InvalidRollupConfig();
        }

        if (_rotationData.length < 4) {
            revert InvalidRotationPayload();
        }

        // Check for multi-call mode (first byte is 0xFF)
        if (_rotationData.length > 0 && _rotationData[0] == MULTI_CALL_PREFIX) {
            _executeMultiCall(_rollupConfig, _rotationData[1:]);
        } else {
            _executeSingleCall(_rollupConfig, _rotationData);
        }
    }

    // ============ Internal Functions ============

    function _executeSingleCall(address _rollupConfig, bytes calldata _data) internal {
        // Decode: (bytes4 selector, bytes callData)
        (bytes4 selector, bytes memory callData) = abi.decode(_data, (bytes4, bytes));

        bytes memory fullCallData = abi.encodePacked(selector, callData);

        (bool success,) = _rollupConfig.call(fullCallData);
        if (!success) {
            revert RotationFailed("Single call failed");
        }

        emit SequencerRotated(_rollupConfig, selector);
    }

    function _executeMultiCall(address _rollupConfig, bytes calldata _data) internal {
        (bytes4[] memory selectors, bytes[] memory callDatas) =
            abi.decode(_data, (bytes4[], bytes[]));

        if (selectors.length != callDatas.length) {
            revert InvalidRotationPayload();
        }

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes memory fullCallData = abi.encodePacked(selectors[i], callDatas[i]);

            (bool success,) = _rollupConfig.call(fullCallData);
            if (!success) {
                revert CallFailed(i);
            }
        }

        emit MultiCallExecuted(_rollupConfig, selectors.length);
    }
}
