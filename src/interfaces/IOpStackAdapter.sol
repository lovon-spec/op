// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOpStackAdapter
 * @notice Interface for OP Stack sequencer rotation adapters.
 * @dev Adapters implement chain-specific logic for rotating sequencers.
 *      This allows the KlerosSequencerManager to survive OP Stack hardforks
 *      by hot-swapping adapters without changing the core manager contract.
 *
 *      Key design principles:
 *      - "Ratchet" versioning: new adapters must have strictly higher version
 *      - "Hydra" defense: multiple adapters can be deployed to GTCR registry
 *      - Adapters are called via delegatecall from the manager
 */
interface IOpStackAdapter {
    // ============ Errors ============

    /// @notice Thrown when sequencer rotation fails
    error RotationFailed(string reason);

    /// @notice Thrown when SystemConfig address is invalid
    error InvalidSystemConfig();

    /// @notice Thrown when batcher or signer address is zero
    error InvalidOperatorKeys();

    // ============ Events ============

    /// @notice Emitted when a sequencer rotation is executed
    event SequencerRotated(
        address indexed systemConfig,
        address indexed batcher,
        address indexed unsafeSigner
    );

    // ============ View Functions ============

    /**
     * @notice Returns the adapter version.
     * @dev Used for "ratchet" upgrade logic - new versions must be strictly greater.
     *      Version format: major * 1000000 + minor * 1000 + patch
     *      e.g., v1.2.3 = 1002003
     * @return The version number
     */
    function version() external view returns (uint256);

    /**
     * @notice Returns human-readable adapter name and description.
     * @return name The adapter name (e.g., "OpStackAdapterV1")
     * @return description Brief description of adapter capabilities
     */
    function adapterInfo() external view returns (string memory name, string memory description);

    // ============ Mutating Functions ============

    /**
     * @notice Rotates the sequencer on the target SystemConfig contract.
     * @dev Called via delegatecall from KlerosSequencerManager.
     *      Must update both batcher and unsafe block signer addresses.
     *
     *      For OP Stack Bedrock/Ecotone:
     *      - Calls SystemConfig.setBatcherHash(bytes32(uint256(uint160(_batcher))))
     *      - Calls SystemConfig.setUnsafeBlockSigner(_signer)
     *
     * @param _systemConfig The SystemConfig contract address for the L2 chain
     * @param _batcher The new batch submitter address
     * @param _unsafeSigner The new unsafe block signer address
     */
    function rotateSequencer(
        address _systemConfig,
        address _batcher,
        address _unsafeSigner
    ) external;
}
