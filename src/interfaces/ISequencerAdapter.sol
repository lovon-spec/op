// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISequencerAdapter
 * @notice Generic interface for rollup-specific sequencer rotation adapters.
 * @dev Adapters implement chain-specific logic for rotating sequencers.
 *      The SharedSequencerHub delegates to adapters to support heterogeneous
 *      rollups and versioned upgrade paths without changing core contracts.
 */
interface ISequencerAdapter {
    /**
     * @notice Returns the adapter version.
     * @dev Version format: major * 1_000_000 + minor * 1_000 + patch.
     * @return The version number
     */
    function version() external view returns (uint256);

    /**
     * @notice Returns human-readable adapter name and description.
     * @return name The adapter name
     * @return description Brief description of adapter capabilities
     */
    function adapterInfo() external view returns (string memory name, string memory description);

    /**
     * @notice Rotates the sequencer for a rollup-specific configuration contract.
     * @dev Called via delegatecall from SharedSequencerHub.
     * @param _rollupConfig The rollup configuration contract address (chain-specific)
     * @param _rotationData Adapter-specific payload describing the next sequencer
     */
    function rotateSequencer(address _rollupConfig, bytes calldata _rotationData) external;
}
