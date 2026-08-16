// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IArbitrumRollup
 * @notice Minimal interface for Arbitrum Nitro's SequencerInbox and RollupCore.
 * @dev Used by ArbitrumAdapterV1 for sequencer rotation on Arbitrum chains.
 *      The SequencerInbox controls who can submit batches (the sequencer).
 *      The RollupCore manages the rollup state and validator set.
 */
interface ISequencerInbox {
    /// @notice Sets the batch poster (sequencer) authorized to submit batches
    function setIsBatchPoster(address addr, bool isBatchPoster_) external;

    /// @notice Checks if an address is an authorized batch poster
    function isBatchPoster(address) external view returns (bool);

    /// @notice Sets the sequencer (for sequencing window)
    function setIsSequencer(address addr, bool isSequencer_) external;
}

/**
 * @title IRollupCore
 * @notice Minimal interface for Arbitrum's RollupCore contract.
 */
interface IRollupCore {
    /// @notice Sets a new validator
    function setValidator(address[] memory _val, bool[] memory _status) external;

    /// @notice Checks if an address is a validator
    function isValidator(address) external view returns (bool);
}
