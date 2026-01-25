// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISystemConfig} from "./interfaces/ISystemConfig.sol";
import {ICurate} from "./interfaces/ICurate.sol";

/**
 * @title KlerosSequencerManager
 * @notice Kleros Curate Classic -> OP Stack SystemConfig bridge.
 * @dev Manages a rotating set of sequencer operators curated via a Kleros TCR.
 *
 * Architecture:
 * - Registry (Kleros Curate Classic) decides which operator addresses are legitimate.
 * - Manager maintains local active set and rotates authority each epoch.
 * - Sets SystemConfig.batcherHash to the selected operator (V0 bytes32(address)).
 *
 * Requirements:
 * - SystemConfig ownership must be transferred to this contract.
 * - Registry must be a Kleros Curate Classic (GeneralizedTCR) instance.
 *
 * Security:
 * - Bounded loops to prevent DoS.
 * - O(1) add/remove with swap-pop pattern.
 * - Guardian pause capability for emergency situations.
 *
 * @custom:security-contact security@example.com
 */
contract KlerosSequencerManager {
    // ============ Errors ============

    /// @notice Thrown when epoch has not ended yet.
    error EpochNotEnded();

    /// @notice Thrown when there are no active sequencers to rotate to.
    error NoActiveSequencers();

    /// @notice Thrown when trying to add a sequencer that is already active.
    error AlreadyActive();

    /// @notice Thrown when trying to remove a sequencer that is not active.
    error NotActive();

    /// @notice Thrown when sequencer is not registered in the registry.
    error NotRegisteredInRegistry();

    /// @notice Thrown when sequencer is still registered (cannot be removed).
    error StillRegisteredInRegistry();

    /// @notice Thrown when caller is not the guardian.
    error InvalidGuardian();

    /// @notice Thrown when contract is paused.
    error ContractPaused();

    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();

    /// @notice Thrown when epoch duration is zero.
    error ZeroEpochDuration();

    // ============ Types ============

    /// @notice Status values from Kleros Curate Classic.
    /// @dev Matches ICurate.Status enum.
    uint8 public constant STATUS_ABSENT = 0;
    uint8 public constant STATUS_REGISTERED = 1;
    uint8 public constant STATUS_REGISTRATION_REQUESTED = 2;
    uint8 public constant STATUS_CLEARING_REQUESTED = 3;

    // ============ Immutables ============

    /// @notice The Kleros Curate Classic registry contract.
    ICurate public immutable registry;

    /// @notice The OP Stack SystemConfig contract.
    ISystemConfig public immutable systemConfig;

    /// @notice Duration of each epoch in seconds.
    uint256 public immutable epochDuration;

    // ============ State ============

    /// @notice Array of currently active sequencer addresses.
    address[] public activeSequencers;

    /// @notice Current index in the rotation (points to last rotated sequencer).
    uint256 public currentIndex;

    /// @notice Timestamp of the last rotation.
    uint256 public lastRotationTimestamp;

    /// @notice Mapping to check if an address is in the active set.
    mapping(address => bool) public isActive;

    /// @notice Mapping from address to its index in activeSequencers array.
    mapping(address => uint256) public indexOf;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Guardian address that can pause/unpause.
    address public guardian;

    // ============ Events ============

    /// @notice Emitted when a sequencer is added to the active set.
    /// @param sequencer The address of the added sequencer.
    event SequencerAdded(address indexed sequencer);

    /// @notice Emitted when a sequencer is removed from the active set.
    /// @param sequencer The address of the removed sequencer.
    event SequencerRemoved(address indexed sequencer);

    /// @notice Emitted when rotation occurs and a new sequencer is selected.
    /// @param newSequencer The newly selected sequencer.
    /// @param newBatcherHash The batcher hash set in SystemConfig.
    /// @param timestamp The timestamp of the rotation.
    event SequencerRotated(
        address indexed newSequencer,
        bytes32 newBatcherHash,
        uint256 timestamp
    );

    /// @notice Emitted when rotation is skipped due to no valid sequencers.
    /// @param timestamp The timestamp when rotation was attempted.
    event RotationSkippedNoValidSequencer(uint256 timestamp);

    /// @notice Emitted when pause state changes.
    /// @param isPaused The new pause state.
    event PausedSet(bool isPaused);

    /// @notice Emitted when guardian is changed.
    /// @param newGuardian The new guardian address.
    event GuardianSet(address indexed newGuardian);

    // ============ Constructor ============

    /**
     * @notice Initializes the KlerosSequencerManager.
     * @param _registry Address of the Kleros Curate Classic registry.
     * @param _systemConfig Address of the OP Stack SystemConfig.
     * @param _epochDuration Duration of each epoch in seconds.
     * @param _guardian Address of the guardian (can be address(0) to disable).
     */
    constructor(
        address _registry,
        address _systemConfig,
        uint256 _epochDuration,
        address _guardian
    ) {
        if (_registry == address(0)) revert ZeroAddress();
        if (_systemConfig == address(0)) revert ZeroAddress();
        if (_epochDuration == 0) revert ZeroEpochDuration();

        registry = ICurate(_registry);
        systemConfig = ISystemConfig(_systemConfig);
        epochDuration = _epochDuration;

        guardian = _guardian;
        emit GuardianSet(_guardian);

        // Allow immediate first rotation if set is populated.
        lastRotationTimestamp = block.timestamp - _epochDuration;
    }

    // ============ Modifiers ============

    /// @notice Ensures contract is not paused.
    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /// @notice Ensures caller is the guardian.
    modifier onlyGuardian() {
        if (guardian == address(0) || msg.sender != guardian) revert InvalidGuardian();
        _;
    }

    // ============ Guardian Functions ============

    /**
     * @notice Sets the pause state of the contract.
     * @param _paused The new pause state.
     */
    function setPaused(bool _paused) external onlyGuardian {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /**
     * @notice Transfers guardian role to a new address.
     * @param _newGuardian The new guardian address (can be address(0) to disable).
     */
    function setGuardian(address _newGuardian) external onlyGuardian {
        guardian = _newGuardian;
        emit GuardianSet(_newGuardian);
    }

    // ============ View Functions ============

    /**
     * @notice Returns the number of active sequencers.
     * @return The count of active sequencers.
     */
    function activeSequencerCount() external view returns (uint256) {
        return activeSequencers.length;
    }

    /**
     * @notice Returns the full array of active sequencers.
     * @return Array of active sequencer addresses.
     */
    function getActiveSequencers() external view returns (address[] memory) {
        return activeSequencers;
    }

    /**
     * @notice Computes the item ID for a sequencer address.
     * @dev Curate Classic uses keccak256(abi.encodePacked(data)) where data is the ABI-encoded item.
     *      For an address-type registry, the data is just the address encoded.
     * @param sequencer The sequencer address.
     * @return The item ID used in the registry.
     */
    function itemIDFor(address sequencer) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(abi.encode(sequencer)));
    }

    /**
     * @notice Checks if a sequencer is registered in the Kleros registry.
     * @param sequencer The sequencer address to check.
     * @return True if the sequencer has STATUS_REGISTERED in the registry.
     */
    function isRegisteredInRegistry(address sequencer) public view returns (bool) {
        return _getRegistryStatus(sequencer) == STATUS_REGISTERED;
    }

    /**
     * @notice Returns the current registry status of a sequencer.
     * @param sequencer The sequencer address.
     * @return The status code (0=Absent, 1=Registered, 2=RegistrationRequested, 3=ClearingRequested).
     */
    function getRegistryStatus(address sequencer) external view returns (uint8) {
        return _getRegistryStatus(sequencer);
    }

    /**
     * @notice Returns the current active sequencer (the one with batcher authority).
     * @return The address of the current sequencer, or address(0) if none.
     */
    function currentSequencer() external view returns (address) {
        if (activeSequencers.length == 0) return address(0);
        return activeSequencers[currentIndex];
    }

    /**
     * @notice Returns the time until the next rotation is possible.
     * @return Seconds until next rotation (0 if rotation is possible now).
     */
    function timeUntilNextRotation() external view returns (uint256) {
        uint256 nextRotation = lastRotationTimestamp + epochDuration;
        if (block.timestamp >= nextRotation) return 0;
        return nextRotation - block.timestamp;
    }

    // ============ Sync Functions ============

    /**
     * @notice Adds a sequencer to the active set if they are registered in the registry.
     * @dev Anyone can call this to sync a registered sequencer into the active set.
     * @param sequencer The sequencer address to add.
     */
    function syncAddSequencer(address sequencer) external notPaused {
        if (sequencer == address(0)) revert ZeroAddress();
        if (isActive[sequencer]) revert AlreadyActive();
        if (!isRegisteredInRegistry(sequencer)) revert NotRegisteredInRegistry();

        indexOf[sequencer] = activeSequencers.length;
        activeSequencers.push(sequencer);
        isActive[sequencer] = true;

        emit SequencerAdded(sequencer);
    }

    /**
     * @notice Removes a sequencer from the active set if they are no longer registered.
     * @dev Anyone can call this to remove a sequencer that is no longer registered.
     *      Removal is allowed if status is not STATUS_REGISTERED (includes Absent,
     *      RegistrationRequested, and ClearingRequested).
     * @param sequencer The sequencer address to remove.
     */
    function syncRemoveSequencer(address sequencer) external notPaused {
        if (!isActive[sequencer]) revert NotActive();
        if (isRegisteredInRegistry(sequencer)) revert StillRegisteredInRegistry();

        _removeActiveSequencer(sequencer);
    }

    // ============ Rotation Functions ============

    /**
     * @notice Rotates to the next valid sequencer and updates SystemConfig.batcherHash.
     * @dev Anyone can call this once per epoch. The function:
     *      1. Checks if epoch has ended
     *      2. Iterates through sequencers to find a valid one
     *      3. Removes any invalid sequencers encountered
     *      4. Sets the batcher hash for the selected sequencer
     *
     *      Uses bounded iteration to prevent DoS.
     */
    function rotateSequencer() external notPaused {
        if (block.timestamp < lastRotationTimestamp + epochDuration) revert EpochNotEnded();
        if (activeSequencers.length == 0) revert NoActiveSequencers();

        uint256 initialLen = activeSequencers.length;
        uint256 checks = 0;

        bool found;
        address next;

        // Bounded search for a valid sequencer
        while (checks < initialLen && activeSequencers.length > 0) {
            uint256 len = activeSequencers.length;
            uint256 candidateIndex = (currentIndex + 1) % len;
            address candidate = activeSequencers[candidateIndex];

            if (isRegisteredInRegistry(candidate)) {
                found = true;
                next = candidate;
                currentIndex = candidateIndex;
                break;
            }

            // Candidate no longer valid, remove and continue
            _removeActiveSequencer(candidate);
            checks++;
        }

        if (!found) {
            emit RotationSkippedNoValidSequencer(block.timestamp);
            return;
        }

        bytes32 batcherHash = _toV0BatcherHash(next);
        systemConfig.setBatcherHash(batcherHash);

        lastRotationTimestamp = block.timestamp;
        emit SequencerRotated(next, batcherHash, block.timestamp);
    }

    /**
     * @notice Alias for rotateSequencer() for keeper compatibility.
     */
    function poke() external {
        this.rotateSequencer();
    }

    // ============ Internal Functions ============

    /**
     * @notice Removes a sequencer from the active set using swap-pop pattern.
     * @dev O(1) removal. Handles currentIndex adjustment when removing elements
     *      before the current position.
     * @param sequencer The sequencer to remove.
     */
    function _removeActiveSequencer(address sequencer) internal {
        uint256 idx = indexOf[sequencer];
        uint256 lastIdx = activeSequencers.length - 1;

        // If removing an element before currentIndex, shift currentIndex left
        if (idx < currentIndex) {
            currentIndex -= 1;
        }

        // Swap with last element if not already last
        if (idx != lastIdx) {
            address moved = activeSequencers[lastIdx];
            activeSequencers[idx] = moved;
            indexOf[moved] = idx;
        }

        activeSequencers.pop();
        delete indexOf[sequencer];
        isActive[sequencer] = false;

        // Reset currentIndex if array is empty or index is out of bounds
        if (activeSequencers.length == 0) {
            currentIndex = 0;
        } else if (currentIndex >= activeSequencers.length) {
            currentIndex = 0;
        }

        emit SequencerRemoved(sequencer);
    }

    /**
     * @notice Converts an address to V0 batcher hash format.
     * @param a The address to convert.
     * @return The V0 batcher hash (bytes32 with address in lower 160 bits).
     */
    function _toV0BatcherHash(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /**
     * @notice Gets the registry status for a sequencer from Curate Classic.
     * @param sequencer The sequencer address.
     * @return status The status code.
     */
    function _getRegistryStatus(address sequencer) internal view returns (uint8 status) {
        bytes32 itemID = itemIDFor(sequencer);
        (, ICurate.Status registryStatus, ) = registry.getItemInfo(itemID);
        return uint8(registryStatus);
    }
}
