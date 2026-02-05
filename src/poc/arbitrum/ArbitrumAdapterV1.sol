// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISequencerAdapter} from "../../interfaces/ISequencerAdapter.sol";
import {ISequencerInbox} from "./interfaces/IArbitrumRollup.sol";

/**
 * @title ArbitrumAdapterV1
 * @notice Arbitrum Nitro adapter for sequencer rotation in ISOCHRON.
 * @dev Returns the calldata needed for Arbitrum Nitro sequencer rotation:
 *      - Revoking the old sequencer's batch poster rights
 *      - Granting the new sequencer batch poster rights
 *
 *      Called via regular `call` from SharedSequencerHub.
 *      The Hub must have admin rights over the target SequencerInbox.
 *
 *      Rotation payload: abi.encode(address newBatchPoster, address oldBatchPoster)
 *
 *      Version: 1.0.0 (1_000_000)
 */
contract ArbitrumAdapterV1 is ISequencerAdapter {
    // ============ Errors ============

    error InvalidSequencerInbox();
    error InvalidOperatorKeys();
    error InvalidRotationPayload();

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

    /**
     * @inheritdoc ISequencerAdapter
     * @dev Rotation payload: abi.encode(address newBatchPoster, address oldBatchPoster)
     *      Returns 1-2 calls depending on whether oldBatchPoster is specified.
     */
    function getRotationCalldata(
        address _sequencerInbox,
        bytes calldata _rotationData
    ) external pure override returns (bytes[] memory calls) {
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

        if (oldBatchPoster != address(0)) {
            calls = new bytes[](2);
            calls[0] = abi.encodeWithSelector(ISequencerInbox.setIsBatchPoster.selector, oldBatchPoster, false);
            calls[1] = abi.encodeWithSelector(ISequencerInbox.setIsBatchPoster.selector, newBatchPoster, true);
        } else {
            calls = new bytes[](1);
            calls[0] = abi.encodeWithSelector(ISequencerInbox.setIsBatchPoster.selector, newBatchPoster, true);
        }
    }
}
