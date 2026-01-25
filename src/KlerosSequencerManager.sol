// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISystemConfig} from "./interfaces/ISystemConfig.sol";
import {ICurate} from "./interfaces/ICurate.sol";

/**
 * @title KlerosSequencerManager
 * @notice Kleros Curate Classic -> OP Stack SystemConfig bridge with full operator tuple support.
 * @dev Manages a rotating set of sequencer operators curated via a Kleros TCR.
 *
 * IMPORTANT: OP Stack sequencer authority requires TWO keys rotated together:
 *   1. batcher - EOA that posts batches to L1 (sets SystemConfig.batcherHash)
 *   2. unsafeSigner - Key that signs unsafe blocks on P2P (sets SystemConfig.unsafeBlockSigner)
 *
 * Architecture:
 * - Registry (Kleros Curate Classic) decides which operator IDs are legitimate.
 * - Each operator ID maps to an Operator tuple (batcher, unsafeSigner).
 * - Manager maintains local active set and rotates authority each epoch.
 * - Sets BOTH batcherHash AND unsafeBlockSigner atomically on rotation.
 *
 * Requirements:
 * - SystemConfig ownership must be transferred to this contract.
 * - Registry must be a Kleros Curate Classic (GeneralizedTCR) instance.
 * - Registry items should encode the operator tuple (batcher, unsafeSigner).
 *
 * Security:
 * - Bounded loops to prevent DoS.
 * - O(1) add/remove with swap-pop pattern.
 * - Guardian pause capability for emergency situations.
 * - Atomic rotation of both keys prevents "half-rotated" state.
 *
 * @custom:security-contact security@example.com
 */
contract KlerosSequencerManager {
    // ============ Errors ============

    /// @notice Thrown when epoch has not ended yet.
    error EpochNotEnded();

    /// @notice Thrown when there are no active operators to rotate to.
    error NoActiveOperators();

    /// @notice Thrown when trying to add an operator that is already active.
    error AlreadyActive();

    /// @notice Thrown when trying to remove an operator that is not active.
    error NotActive();

    /// @notice Thrown when operator is not registered in the registry.
    error NotRegisteredInRegistry();

    /// @notice Thrown when operator is still registered (cannot be removed).
    error StillRegisteredInRegistry();

    /// @notice Thrown when caller is not the guardian.
    error InvalidGuardian();

    /// @notice Thrown when contract is paused.
    error ContractPaused();

    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();

    /// @notice Thrown when epoch duration is zero.
    error ZeroEpochDuration();

    /// @notice Thrown when batcher and unsafeSigner are the same (potential misconfiguration).
    error BatcherAndSignerSame();

    // ============ Types ============

    /**
     * @notice Represents a sequencer operator with both required keys.
     * @param batcher The EOA address that will post batches to L1.
     * @param unsafeSigner The address that signs unsafe blocks on the P2P layer.
     */
    struct Operator {
        address batcher;
        address unsafeSigner;
    }

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

    /// @notice Array of currently active operators.
    Operator[] public activeOperators;

    /// @notice Current index in the rotation (points to last rotated operator).
    uint256 public currentIndex;

    /// @notice Timestamp of the last rotation.
    uint256 public lastRotationTimestamp;

    /// @notice Mapping to check if an operator ID is in the active set.
    /// @dev Operator ID is keccak256(abi.encode(batcher, unsafeSigner))
    mapping(bytes32 => bool) public isActive;

    /// @notice Mapping from operator ID to its index in activeOperators array.
    mapping(bytes32 => uint256) public indexOf;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Guardian address that can pause/unpause.
    address public guardian;

    // ============ Events ============

    /// @notice Emitted when an operator is added to the active set.
    /// @param operatorId The unique ID of the operator.
    /// @param batcher The batcher address.
    /// @param unsafeSigner The unsafe block signer address.
    event OperatorAdded(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);

    /// @notice Emitted when an operator is removed from the active set.
    /// @param operatorId The unique ID of the operator.
    /// @param batcher The batcher address.
    /// @param unsafeSigner The unsafe block signer address.
    event OperatorRemoved(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);

    /// @notice Emitted when rotation occurs and a new operator is selected.
    /// @param operatorId The unique ID of the new operator.
    /// @param batcher The batcher address.
    /// @param unsafeSigner The unsafe block signer address.
    /// @param batcherHash The batcher hash set in SystemConfig.
    /// @param timestamp The timestamp of the rotation.
    event OperatorRotated(
        bytes32 indexed operatorId,
        address indexed batcher,
        address indexed unsafeSigner,
        bytes32 batcherHash,
        uint256 timestamp
    );

    /// @notice Emitted when rotation is skipped due to no valid operators.
    /// @param timestamp The timestamp when rotation was attempted.
    event RotationSkippedNoValidOperator(uint256 timestamp);

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

        // Initialize currentIndex to max so first rotation selects index 0
        currentIndex = type(uint256).max;

        // Allow immediate first rotation if set is populated.
        unchecked {
            if (block.timestamp >= _epochDuration) {
                lastRotationTimestamp = block.timestamp - _epochDuration;
            } else {
                lastRotationTimestamp = 0;
            }
        }
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
     * @notice Returns the number of active operators.
     * @return The count of active operators.
     */
    function activeOperatorCount() external view returns (uint256) {
        return activeOperators.length;
    }

    /**
     * @notice Returns the full array of active operators.
     * @return Array of active Operator structs.
     */
    function getActiveOperators() external view returns (Operator[] memory) {
        return activeOperators;
    }

    /**
     * @notice Computes the operator ID for an operator tuple.
     * @dev The operator ID is used both as the internal key and as the Kleros registry item ID.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return The operator ID.
     */
    function operatorId(address batcher, address unsafeSigner) public pure returns (bytes32) {
        return keccak256(abi.encode(batcher, unsafeSigner));
    }

    /**
     * @notice Computes the Kleros registry item ID for an operator tuple.
     * @dev Curate Classic uses keccak256(abi.encodePacked(data)) where data is the ABI-encoded item.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return The item ID used in the registry.
     */
    function itemIDFor(address batcher, address unsafeSigner) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(abi.encode(batcher, unsafeSigner)));
    }

    /**
     * @notice Checks if an operator is registered in the Kleros registry.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return True if the operator has STATUS_REGISTERED in the registry.
     */
    function isRegisteredInRegistry(address batcher, address unsafeSigner) public view returns (bool) {
        return _getRegistryStatus(batcher, unsafeSigner) == STATUS_REGISTERED;
    }

    /**
     * @notice Returns the current registry status of an operator.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return The status code (0=Absent, 1=Registered, 2=RegistrationRequested, 3=ClearingRequested).
     */
    function getRegistryStatus(address batcher, address unsafeSigner) external view returns (uint8) {
        return _getRegistryStatus(batcher, unsafeSigner);
    }

    /**
     * @notice Returns the current active operator (the one with sequencer authority).
     * @return The current Operator tuple, or (address(0), address(0)) if none.
     */
    function currentOperator() external view returns (Operator memory) {
        if (activeOperators.length == 0) return Operator(address(0), address(0));
        if (currentIndex >= activeOperators.length) return Operator(address(0), address(0));
        return activeOperators[currentIndex];
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

    /**
     * @notice Checks if a specific operator is currently the active one.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return True if this operator is currently selected.
     */
    function isCurrentOperator(address batcher, address unsafeSigner) external view returns (bool) {
        if (activeOperators.length == 0) return false;
        if (currentIndex >= activeOperators.length) return false;
        Operator memory current = activeOperators[currentIndex];
        return current.batcher == batcher && current.unsafeSigner == unsafeSigner;
    }

    // ============ Sync Functions ============

    /**
     * @notice Adds an operator to the active set if they are registered in the registry.
     * @dev Anyone can call this to sync a registered operator into the active set.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function syncAddOperator(address batcher, address unsafeSigner) external notPaused {
        if (batcher == address(0)) revert ZeroAddress();
        if (unsafeSigner == address(0)) revert ZeroAddress();

        bytes32 opId = operatorId(batcher, unsafeSigner);
        if (isActive[opId]) revert AlreadyActive();
        if (!isRegisteredInRegistry(batcher, unsafeSigner)) revert NotRegisteredInRegistry();

        indexOf[opId] = activeOperators.length;
        activeOperators.push(Operator(batcher, unsafeSigner));
        isActive[opId] = true;

        emit OperatorAdded(opId, batcher, unsafeSigner);
    }

    /**
     * @notice Removes an operator from the active set if they are no longer registered.
     * @dev Anyone can call this to remove an operator that is no longer registered.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function syncRemoveOperator(address batcher, address unsafeSigner) external notPaused {
        bytes32 opId = operatorId(batcher, unsafeSigner);
        if (!isActive[opId]) revert NotActive();
        if (isRegisteredInRegistry(batcher, unsafeSigner)) revert StillRegisteredInRegistry();

        _removeActiveOperator(opId, batcher, unsafeSigner);
    }

    // ============ Rotation Functions ============

    /**
     * @notice Rotates to the next valid operator and updates SystemConfig atomically.
     * @dev Anyone can call this once per epoch. The function:
     *      1. Checks if epoch has ended
     *      2. Iterates through operators to find a valid one
     *      3. Removes any invalid operators encountered
     *      4. Sets BOTH batcherHash AND unsafeBlockSigner atomically
     *
     *      Uses bounded iteration to prevent DoS.
     */
    function rotateOperator() external notPaused {
        if (block.timestamp < lastRotationTimestamp + epochDuration) revert EpochNotEnded();
        if (activeOperators.length == 0) revert NoActiveOperators();

        uint256 initialLen = activeOperators.length;
        uint256 checks = 0;

        bool found;
        Operator memory next;
        bytes32 nextOpId;

        // Bounded search for a valid operator
        while (checks < initialLen && activeOperators.length > 0) {
            uint256 len = activeOperators.length;
            uint256 candidateIndex;
            unchecked {
                candidateIndex = (currentIndex + 1) % len;
            }
            Operator memory candidate = activeOperators[candidateIndex];
            bytes32 candidateId = operatorId(candidate.batcher, candidate.unsafeSigner);

            if (isRegisteredInRegistry(candidate.batcher, candidate.unsafeSigner)) {
                found = true;
                next = candidate;
                nextOpId = candidateId;
                currentIndex = candidateIndex;
                break;
            }

            // Candidate no longer valid, remove and continue
            _removeActiveOperator(candidateId, candidate.batcher, candidate.unsafeSigner);
            checks++;
        }

        if (!found) {
            emit RotationSkippedNoValidOperator(block.timestamp);
            return;
        }

        // CRITICAL: Update both batcherHash and unsafeBlockSigner atomically
        bytes32 batcherHash = _toV0BatcherHash(next.batcher);
        systemConfig.setBatcherHash(batcherHash);
        systemConfig.setUnsafeBlockSigner(next.unsafeSigner);

        lastRotationTimestamp = block.timestamp;
        emit OperatorRotated(nextOpId, next.batcher, next.unsafeSigner, batcherHash, block.timestamp);
    }

    /**
     * @notice Alias for rotateOperator() for keeper compatibility.
     */
    function poke() external {
        this.rotateOperator();
    }

    // ============ Legacy Compatibility ============

    /**
     * @notice Returns the current batcher address for backwards compatibility.
     * @return The batcher address of the current operator, or address(0) if none.
     * @dev DEPRECATED: Use currentOperator() instead to get both addresses.
     */
    function currentSequencer() external view returns (address) {
        if (activeOperators.length == 0) return address(0);
        if (currentIndex >= activeOperators.length) return address(0);
        return activeOperators[currentIndex].batcher;
    }

    /**
     * @notice Alias for rotateOperator() for backwards compatibility.
     * @dev DEPRECATED: Use rotateOperator() instead.
     */
    function rotateSequencer() external {
        this.rotateOperator();
    }

    /**
     * @notice Returns the number of active operators (legacy name).
     * @dev DEPRECATED: Use activeOperatorCount() instead.
     */
    function activeSequencerCount() external view returns (uint256) {
        return activeOperators.length;
    }

    // ============ Internal Functions ============

    /**
     * @notice Removes an operator from the active set using swap-pop pattern.
     * @dev O(1) removal. Handles currentIndex adjustment.
     */
    function _removeActiveOperator(bytes32 opId, address batcher, address unsafeSigner) internal {
        uint256 idx = indexOf[opId];
        uint256 lastIdx = activeOperators.length - 1;

        // If removing an element before currentIndex, shift currentIndex left
        if (currentIndex < activeOperators.length && idx < currentIndex) {
            currentIndex -= 1;
        }

        // Swap with last element if not already last
        if (idx != lastIdx) {
            Operator memory moved = activeOperators[lastIdx];
            bytes32 movedId = operatorId(moved.batcher, moved.unsafeSigner);
            activeOperators[idx] = moved;
            indexOf[movedId] = idx;
        }

        activeOperators.pop();
        delete indexOf[opId];
        isActive[opId] = false;

        // Reset currentIndex if array is empty or index is out of bounds
        if (activeOperators.length == 0 || currentIndex >= activeOperators.length) {
            currentIndex = type(uint256).max;
        }

        emit OperatorRemoved(opId, batcher, unsafeSigner);
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
     * @notice Gets the registry status for an operator from Curate Classic.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return status The status code.
     */
    function _getRegistryStatus(address batcher, address unsafeSigner) internal view returns (uint8 status) {
        bytes32 itemID = itemIDFor(batcher, unsafeSigner);
        (, ICurate.Status registryStatus, ) = registry.getItemInfo(itemID);
        return uint8(registryStatus);
    }
}
