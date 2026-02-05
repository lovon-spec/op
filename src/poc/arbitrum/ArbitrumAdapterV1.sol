// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISequencerAdapter} from "../../interfaces/ISequencerAdapter.sol";
import {ISequencerInbox} from "./interfaces/IArbitrumRollup.sol";

/**
 * @title ArbitrumAdapterV1
 * @notice Arbitrum Nitro adapter for sequencer rotation in ISOCHRON.
 * @dev Implements sequencer rotation for Arbitrum Nitro chains by:
 *      - Updating the SequencerInbox batch poster authorization
 *      - Revoking the old sequencer's batch poster rights
 *      - Granting the new sequencer batch poster rights
 *
 *      Called via delegatecall from SharedSequencerHub.
 *      The Hub must have admin rights over the target SequencerInbox.
 *
 *      Rotation payload: abi.encode(address newBatchPoster, address oldBatchPoster)
 *
 *      Version: 1.0.0 (1_000_000)
 */
contract ArbitrumAdapterV1 is ISequencerAdapter {
    // ============ Errors ============

    error RotationFailed(string reason);
    error InvalidSequencerInbox();
    error InvalidOperatorKeys();
    error InvalidRotationPayload();

    // ============ Events ============

    event SequencerRotated(
        address indexed sequencerInbox,
        address indexed newBatchPoster,
        address indexed oldBatchPoster
    );

    // ============ Constants ============

    uint256 public constant VERSION = 1_000_000;
    string public constant NAME = "ArbitrumAdapterV1";
    string public constant DESCRIPTION = "Arbitrum Nitro sequencer rotation adapter";

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
     * @dev Rotation payload: abi.encode(address newBatchPoster, address oldBatchPoster)
     */
    function rotateSequencer(address _sequencerInbox, bytes calldata _rotationData)
        external
        override
    {
        if (_sequencerInbox == address(0)) {
            revert InvalidSequencerInbox();
        }

        if (_rotationData.length != 64) {
            revert InvalidRotationPayload();
        }

        (address newBatchPoster, address oldBatchPoster) =
            abi.decode(_rotationData, (address, address));

        if (newBatchPoster == address(0)) {
            revert InvalidOperatorKeys();
        }

        ISequencerInbox inbox = ISequencerInbox(_sequencerInbox);

        // Revoke old batch poster if specified
        if (oldBatchPoster != address(0)) {
            try inbox.setIsBatchPoster(oldBatchPoster, false) {}
            catch Error(string memory reason) {
                revert RotationFailed(reason);
            } catch {
                revert RotationFailed("Revoke old batch poster failed");
            }
        }

        // Grant new batch poster
        try inbox.setIsBatchPoster(newBatchPoster, true) {}
        catch Error(string memory reason) {
            revert RotationFailed(reason);
        } catch {
            revert RotationFailed("Set new batch poster failed");
        }

        emit SequencerRotated(_sequencerInbox, newBatchPoster, oldBatchPoster);
    }
}
