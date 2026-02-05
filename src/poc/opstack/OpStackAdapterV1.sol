// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISequencerAdapter} from "../../interfaces/ISequencerAdapter.sol";
import {ISystemConfig} from "./interfaces/ISystemConfig.sol";

/**
 * @title OpStackAdapterV1
 * @notice OP Stack adapter for Bedrock/Ecotone sequencer rotation.
 * @dev Implements sequencer rotation for OP Stack chains by returning
 *      the calldata needed to update SystemConfig:
 *      - setBatcherHash() for batch submitter authorization
 *      - setUnsafeBlockSigner() for P2P block signing authorization
 *
 *      This adapter is called via regular `call` from SharedSequencerHub.
 *      It returns calldata that the Hub executes against the target
 *      SystemConfig contract(s). The Hub must be the owner of SystemConfig.
 *
 *      Version: 1.0.0 (1_000_000)
 */
contract OpStackAdapterV1 is ISequencerAdapter {
    // ============ Errors ============

    /// @notice Thrown when SystemConfig address is invalid
    error InvalidSystemConfig();

    /// @notice Thrown when batcher or signer address is zero
    error InvalidOperatorKeys();

    /// @notice Thrown when rotation payload is malformed
    error InvalidRotationPayload();

    // ============ Constants ============

    /// @notice Adapter version (1.0.0 = 1_000_000)
    uint256 public constant VERSION = 1_000_000;

    /// @notice Adapter name
    string public constant NAME = "OpStackAdapterV1";

    /// @notice Adapter description
    string public constant DESCRIPTION = "OP Stack Bedrock/Ecotone sequencer rotation adapter";

    // ============ View Functions ============

    /**
     * @inheritdoc ISequencerAdapter
     */
    function version() external pure virtual override returns (uint256) {
        return VERSION;
    }

    /**
     * @inheritdoc ISequencerAdapter
     */
    function adapterInfo() external pure virtual override returns (string memory name, string memory description) {
        return (NAME, DESCRIPTION);
    }

    /**
     * @inheritdoc ISequencerAdapter
     * @dev Rotation payload is abi-encoded as (address batcher, address unsafeSigner).
     *      Returns two calls: setBatcherHash and setUnsafeBlockSigner.
     */
    function getRotationCalldata(
        address _systemConfig,
        bytes calldata _rotationData
    ) external pure virtual override returns (bytes[] memory calls) {
        if (_systemConfig == address(0)) {
            revert InvalidSystemConfig();
        }

        if (_rotationData.length != 64) {
            revert InvalidRotationPayload();
        }

        (address batcher, address unsafeSigner) = abi.decode(_rotationData, (address, address));

        if (batcher == address(0) || unsafeSigner == address(0)) {
            revert InvalidOperatorKeys();
        }

        // Convert batcher address to V0 hash format
        bytes32 batcherHash = bytes32(uint256(uint160(batcher)));

        calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(ISystemConfig.setBatcherHash.selector, batcherHash);
        calls[1] = abi.encodeWithSelector(ISystemConfig.setUnsafeBlockSigner.selector, unsafeSigner);
    }
}
