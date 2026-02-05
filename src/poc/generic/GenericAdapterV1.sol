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
 *      1. Direct call: Returns calldata for a single function call on the rollup config
 *      2. Multi-call: Returns calldata for multiple function calls for complex rotations
 *
 *      This adapter is designed as a plug-and-play solution for chains that
 *      don't need a specialized adapter (like OP Stack or Arbitrum).
 *
 *      Rotation payload format:
 *      Single call: abi.encode(bytes4 selector, bytes callData)
 *      Multi-call:  0xFF ++ abi.encode(bytes4[] selectors, bytes[] callDatas)
 *
 *      Future adapters (e.g., Cosmos/IBC) can extend this pattern.
 *
 *      Version: 1.0.0 (1_000_000)
 */
contract GenericAdapterV1 is ISequencerAdapter {
    // ============ Errors ============

    error InvalidRollupConfig();
    error InvalidRotationPayload();

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

    /**
     * @inheritdoc ISequencerAdapter
     * @dev Supports single-call and multi-call rotation modes.
     *
     *      Single call payload: abi.encode(bytes4 selector, bytes callData)
     *      Returns: [abi.encodePacked(selector, callData)]
     *
     *      Multi-call payload: 0xFF ++ abi.encode(bytes4[] selectors, bytes[] callDatas)
     *      Returns: [abi.encodePacked(selectors[0], callDatas[0]), ...]
     */
    function getRotationCalldata(
        address _rollupConfig,
        bytes calldata _rotationData
    ) external pure override returns (bytes[] memory calls) {
        if (_rollupConfig == address(0)) {
            revert InvalidRollupConfig();
        }

        if (_rotationData.length < 4) {
            revert InvalidRotationPayload();
        }

        // Check for multi-call mode (first byte is 0xFF)
        if (_rotationData[0] == MULTI_CALL_PREFIX) {
            calls = _buildMultiCallData(_rotationData[1:]);
        } else {
            calls = new bytes[](1);
            calls[0] = _buildSingleCallData(_rotationData);
        }
    }

    // ============ Internal Functions ============

    function _buildSingleCallData(bytes calldata _data) internal pure returns (bytes memory) {
        (bytes4 selector, bytes memory callData) = abi.decode(_data, (bytes4, bytes));
        return abi.encodePacked(selector, callData);
    }

    function _buildMultiCallData(bytes calldata _data) internal pure returns (bytes[] memory calls) {
        (bytes4[] memory selectors, bytes[] memory callDatas) =
            abi.decode(_data, (bytes4[], bytes[]));

        if (selectors.length != callDatas.length) {
            revert InvalidRotationPayload();
        }

        calls = new bytes[](selectors.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            calls[i] = abi.encodePacked(selectors[i], callDatas[i]);
        }
    }
}
