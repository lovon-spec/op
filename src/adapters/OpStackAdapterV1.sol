// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOpStackAdapter} from "../interfaces/IOpStackAdapter.sol";
import {ISystemConfig} from "../interfaces/ISystemConfig.sol";

/**
 * @title OpStackAdapterV1
 * @notice OP Stack adapter for Bedrock/Ecotone sequencer rotation.
 * @dev Implements sequencer rotation for OP Stack chains using:
 *      - setBatcherHash() for batch submitter authorization
 *      - setUnsafeBlockSigner() for P2P block signing authorization
 *
 *      This adapter is designed to be called via delegatecall from
 *      SharedSequencerHub, which must be the owner of the target
 *      SystemConfig contract(s).
 *
 *      KSSN Architecture:
 *      - Hub owns all connected SystemConfig contracts
 *      - Hub delegatecalls to adapter for version-specific logic
 *      - Adapter code executes in Hub's context (msg.sender = Hub)
 *
 *      Version: 1.0.0 (1000000)
 */
contract OpStackAdapterV1 is IOpStackAdapter {
    // ============ Constants ============

    /// @notice Adapter version (1.0.0 = 1000000)
    uint256 public constant VERSION = 1_000_000;

    /// @notice Adapter name
    string public constant NAME = "OpStackAdapterV1";

    /// @notice Adapter description
    string public constant DESCRIPTION = "OP Stack Bedrock/Ecotone sequencer rotation adapter";

    // ============ View Functions ============

    /**
     * @inheritdoc IOpStackAdapter
     */
    function version() external pure virtual override returns (uint256) {
        return VERSION;
    }

    /**
     * @inheritdoc IOpStackAdapter
     */
    function adapterInfo() external pure virtual override returns (string memory name, string memory description) {
        return (NAME, DESCRIPTION);
    }

    // ============ Mutating Functions ============

    /**
     * @inheritdoc IOpStackAdapter
     * @dev Rotates the sequencer by updating both batcher hash and unsafe block signer.
     *      IMPORTANT: This function is designed to be called via delegatecall.
     *      The caller (KlerosSequencerManager) must be the owner of SystemConfig.
     *
     *      Rotation is atomic - both values are updated in a single transaction.
     *      If either call fails, the entire transaction reverts.
     */
    function rotateSequencer(
        address _systemConfig,
        address _batcher,
        address _unsafeSigner
    ) external override {
        // Validate inputs
        if (_systemConfig == address(0)) {
            revert InvalidSystemConfig();
        }
        if (_batcher == address(0) || _unsafeSigner == address(0)) {
            revert InvalidOperatorKeys();
        }

        ISystemConfig config = ISystemConfig(_systemConfig);

        // Convert batcher address to V0 hash format
        bytes32 batcherHash = bytes32(uint256(uint160(_batcher)));

        // Rotate batcher hash
        // Note: This will revert if caller is not SystemConfig owner
        try config.setBatcherHash(batcherHash) {
            // Success
        } catch Error(string memory reason) {
            revert RotationFailed(reason);
        } catch {
            revert RotationFailed("setBatcherHash failed");
        }

        // Rotate unsafe block signer
        try config.setUnsafeBlockSigner(_unsafeSigner) {
            // Success
        } catch Error(string memory reason) {
            revert RotationFailed(reason);
        } catch {
            revert RotationFailed("setUnsafeBlockSigner failed");
        }

        emit SequencerRotated(_systemConfig, _batcher, _unsafeSigner);
    }
}
