// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISequencerAdapter
 * @notice Generic interface for rollup-specific sequencer rotation adapters.
 * @dev Adapters implement chain-specific logic for rotating sequencers.
 *      The SharedSequencerHub calls adapters via regular `call` to obtain
 *      the calldata needed to update rollup configuration contracts, then
 *      executes those calls itself. This avoids delegatecall, preventing
 *      untrusted adapter code from modifying Hub storage.
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
     * @notice Returns the calldata the Hub should execute against the rollup config.
     * @dev Called via regular `call` from SharedSequencerHub. The adapter validates
     *      inputs and returns encoded function calls. The Hub then executes each
     *      call against the rollupConfig address using its own msg.sender context.
     *      This pattern ensures adapters cannot modify Hub storage.
     * @param _rollupConfig The rollup configuration contract address (chain-specific)
     * @param _rotationData Adapter-specific payload describing the next sequencer
     * @return calls Array of ABI-encoded calldata to execute against _rollupConfig
     */
    function getRotationCalldata(
        address _rollupConfig,
        bytes calldata _rotationData
    ) external view returns (bytes[] memory calls);
}
