// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISequencerAdapter} from "../../src/interfaces/ISequencerAdapter.sol";

interface IMockRollupConfig {
    function setSequencer(address _newSequencer) external;
}

/**
 * @title MockSequencerAdapter
 * @notice Simple adapter used in tests for rollup-agnostic rotations.
 */
contract MockSequencerAdapter is ISequencerAdapter {
    error InvalidRollupConfig();
    error InvalidRotationData();

    uint256 public constant VERSION = 1_000_000;
    string public constant NAME = "MockSequencerAdapter";
    string public constant DESCRIPTION = "Test adapter for generic rollup configs";

    function version() external pure override returns (uint256) {
        return VERSION;
    }

    function adapterInfo() external pure override returns (string memory name, string memory description) {
        return (NAME, DESCRIPTION);
    }

    function getRotationCalldata(
        address _rollupConfig,
        bytes calldata _rotationData
    ) external pure override returns (bytes[] memory calls) {
        if (_rollupConfig == address(0)) revert InvalidRollupConfig();
        if (_rotationData.length != 32) revert InvalidRotationData();

        address nextSequencer = abi.decode(_rotationData, (address));

        calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IMockRollupConfig.setSequencer.selector, nextSequencer);
    }
}
