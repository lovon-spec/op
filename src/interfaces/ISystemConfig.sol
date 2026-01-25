// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISystemConfig
 * @notice Interface for the OP Stack SystemConfig contract.
 * @dev The SystemConfig contract manages the configuration of an OP Stack chain,
 *      including both the batcher hash (for batch posting authorization) and the
 *      unsafe block signer (for P2P block signing authorization).
 *
 * IMPORTANT: OP Stack sequencer authority requires BOTH:
 *   1. batcherHash - Authorizes which address can post batches to L1
 *   2. unsafeBlockSigner - Authorizes which key signs unsafe blocks on P2P layer
 *
 * Both must be rotated together to avoid a "half-rotated" state.
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
     * @notice Sets the unsafe block signer address.
     * @dev The unsafe block signer is the key authorized to sign "unsafe" blocks
     *      that are gossiped on the P2P layer before batch submission.
     *      Only the owner of SystemConfig can call this function.
     * @param _unsafeBlockSigner The new unsafe block signer address.
     */
    function setUnsafeBlockSigner(address _unsafeBlockSigner) external;

    /**
     * @notice Returns the current unsafe block signer.
     * @return The current unsafe block signer address.
     */
    function unsafeBlockSigner() external view returns (address);

    /**
     * @notice Returns the owner of the SystemConfig.
     * @return The owner address.
     */
    function owner() external view returns (address);
}
