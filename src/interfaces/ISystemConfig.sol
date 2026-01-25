// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISystemConfig
 * @notice Interface for the OP Stack SystemConfig contract.
 * @dev The SystemConfig contract manages the configuration of an OP Stack chain,
 *      including the batcher hash which determines who can submit batches to L1.
 */
interface ISystemConfig {
    /**
     * @notice Sets the batcher hash, which identifies the authorized batch submitter.
     * @dev The batcher hash uses V0 format: bytes32(uint256(uint160(address))).
     *      Only the owner of SystemConfig can call this function.
     * @param _batcherHash The new batcher hash to set.
     */
    function setBatcherHash(bytes32 _batcherHash) external;

    /**
     * @notice Returns the current batcher hash.
     * @return The current batcher hash.
     */
    function batcherHash() external view returns (bytes32);

    /**
     * @notice Returns the owner of the SystemConfig.
     * @return The owner address.
     */
    function owner() external view returns (address);
}
