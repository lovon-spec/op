// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISystemConfig} from "./interfaces/ISystemConfig.sol";
import {IPermanentGTCRHybrid} from "./interfaces/IPermanentGTCRHybrid.sol";
import {ICurate} from "./interfaces/ICurate.sol";
import {IOpStackAdapter} from "./interfaces/IOpStackAdapter.sol";

/**
 * @title KlerosSequencerManager
 * @notice Hybrid PermanentGTCR -> OP Stack SystemConfig bridge with hot-swappable adapter.
 * @dev Manages a rotating set of sequencer operators curated via a Kleros PGTCR Hybrid registry.
 *
 *      This contract serves two purposes in the KSSN architecture:
 *
 *      1. STANDALONE MODE: For chains not yet integrated into KSSN, this contract
 *         provides a complete decentralized sequencer rotation system. Chains can
 *         use this as their sole sequencer management solution.
 *
 *      2. KSSN INTEGRATION FRAMEWORK: For chains joining KSSN, this contract provides
 *         the foundational operator registry and adapter pattern. When integrated:
 *         - The SharedSequencerHub becomes the central coordinator
 *         - This manager handles local operator validation and SystemConfig updates
 *         - The ChainRegistry (GeneralizedTCR) manages chain membership
 *
 *      Integration Path to KSSN:
 *      1. Deploy this manager for standalone operation
 *      2. Register chain in ChainRegistry via ChainDeploymentKit
 *      3. After approval, Hub governance calls connectChainFromRegistry()
 *      4. Hub coordinates atomic rotation across all connected chains
 *
 * Architecture (Snapshot + Reverse Mapping + Hot-Swappable Adapter):
 * - Registry stores items with on-chain operational keys (via Hybrid extension)
 * - Manager SNAPSHOTS keys when syncing (decouples from registry reads during rotation)
 * - Reverse mapping (OpId -> ItemID) enables O(1) registry verification
 * - Adapter pattern enables surviving OP Stack hardforks via hot-swap
 *
 * The "Cold Staker / Hot Operator" Model:
 * - Staker (Owner): Holds stake in registry, can update keys
 * - Operational Keys: Batcher + UnsafeSigner (can be different from owner)
 * - ItemID: Registry identifier for the license/stake
 * - OpId: Hash of operational keys (batcher, unsafeSigner)
 *
 * Green Adapter Architecture:
 * - Manager delegates SystemConfig calls to an external adapter via delegatecall
 * - Adapters are gated by a separate Kleros GTCR registry (adapterRegistry)
 * - "Ratchet" logic: new adapter version must be strictly greater
 * - "Hydra" defense: multiple adapters can be submitted to registry
 *
 * Data Flow:
 * 1. Registration: User creates item on curate.kleros.io
 *    - Default: Keys = msg.sender (owner)
 *    - Advanced: Owner calls setOperationalKeys(itemID, batcher, signer)
 *
 * 2. Sync (Activation): Keeper calls syncAddOperator(itemID)
 *    - Manager reads keys from Registry via getOperationalKeys()
 *    - Manager stores: activeOperators.push(keys) + opIdToItemId[opId] = itemID
 *
 * 3. Validation (Rotation): rotateOperator() calls isRegisteredInRegistry(keys)
 *    - Manager hashes keys to get OpId
 *    - Manager looks up ItemID via opIdToItemId (O(1))
 *    - Manager verifies against Registry: "Does ItemID still point to keys?"
 *
 * 4. Adapter Upgrade: Anyone can call upgradeAdapter(_newAdapter)
 *    - Verifies adapter is in adapterRegistry (Registered or ClearingRequested)
 *    - Verifies newVersion > currentVersion (ratchet)
 *    - Swaps to new adapter
 *
 * Security:
 * - Bounded loops to prevent DoS
 * - O(1) add/remove/verify with reverse mapping
 * - Guardian pause capability
 * - Atomic rotation of both keys via adapter
 * - Adapter upgrades gated by Kleros arbitration
 *
 * @custom:security-contact security@kleros.io
 */
contract KlerosSequencerManager {
    // ============ Errors ============

    error EpochNotEnded();
    error NoActiveOperators();
    error AlreadyActive();
    error NotActive();
    error NotRegisteredInRegistry();
    error StillRegisteredInRegistry();
    error InvalidGuardian();
    error ContractPaused();
    error ZeroAddress();
    error ZeroEpochDuration();
    error InvalidSigner();
    error ItemAlreadySynced();
    error AdapterNotRegistered();
    error AdapterVersionNotHigher();
    error AdapterCallFailed();
    error NoAdapterSet();
    error ChallengePeriodNotPassed();
    error OnlyCurrentOperatorDuringGracePeriod();

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

    // ============ Immutables ============

    /// @notice The Kleros PermanentGTCR Hybrid registry for operators.
    IPermanentGTCRHybrid public immutable registry;

    /// @notice The OP Stack SystemConfig contract.
    ISystemConfig public immutable systemConfig;

    /// @notice The Kleros Curate registry for approved adapters.
    ICurate public immutable adapterRegistry;

    /// @notice Duration of each epoch in seconds.
    uint256 public immutable epochDuration;

    // ============ Constants ============

    /// @notice Grace period after epoch ends during which only the current operator can rotate.
    /// @dev This enables "Active Handoff" - the operator can flush their batch queue before rotating.
    uint256 public constant GRACE_PERIOD = 600; // 10 minutes

    // ============ State ============

    /// @notice Array of currently active operators (SNAPSHOT).
    Operator[] public activeOperators;

    /// @notice Current index in the rotation.
    uint256 public currentIndex;

    /// @notice Timestamp of the last rotation.
    uint256 public lastRotationTimestamp;

    /// @notice Maps OpId (hash of keys) -> IsActive in local set.
    mapping(bytes32 => bool) public isActive;

    /// @notice Maps OpId -> Index in activeOperators array.
    mapping(bytes32 => uint256) public indexOf;

    /// @notice Maps OpId (hash of keys) -> Kleros Item ID (REVERSE MAPPING).
    /// @dev Enables O(1) lookup of registry item for validation.
    mapping(bytes32 => bytes32) public opIdToItemId;

    /// @notice Maps Kleros Item ID -> OpId (hash of keys).
    /// @dev Used for updates and to prevent double-sync of same item.
    mapping(bytes32 => bytes32) public itemIdToOpId;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Guardian address that can pause/unpause.
    address public guardian;

    /// @notice Current OP Stack adapter for sequencer rotation.
    IOpStackAdapter public opAdapter;

    // ============ Events ============

    event OperatorAdded(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);
    event OperatorUpdated(bytes32 indexed oldOperatorId, bytes32 indexed newOperatorId, address batcher, address unsafeSigner);
    event OperatorRemoved(bytes32 indexed operatorId, address indexed batcher, address indexed unsafeSigner);
    event OperatorRotated(
        bytes32 indexed operatorId,
        address indexed batcher,
        address indexed unsafeSigner,
        bytes32 batcherHash,
        uint256 timestamp
    );
    event RotationSkippedNoValidOperator(uint256 timestamp);
    event PausedSet(bool isPaused);
    event GuardianSet(address indexed newGuardian);
    event AdapterUpgraded(address indexed oldAdapter, address indexed newAdapter, uint256 oldVersion, uint256 newVersion);

    // ============ Constructor ============

    /**
     * @notice Initializes the KlerosSequencerManager.
     * @param _registry Address of the Kleros PermanentGTCR Hybrid registry for operators.
     * @param _systemConfig Address of the OP Stack SystemConfig.
     * @param _adapterRegistry Address of the Kleros Curate registry for approved adapters.
     * @param _initialAdapter Address of the initial OP Stack adapter.
     * @param _epochDuration Duration of each epoch in seconds.
     * @param _guardian Address of the guardian (can be address(0) to disable).
     */
    constructor(
        address _registry,
        address _systemConfig,
        address _adapterRegistry,
        address _initialAdapter,
        uint256 _epochDuration,
        address _guardian
    ) {
        if (_registry == address(0)) revert ZeroAddress();
        if (_systemConfig == address(0)) revert ZeroAddress();
        if (_adapterRegistry == address(0)) revert ZeroAddress();
        if (_initialAdapter == address(0)) revert ZeroAddress();
        if (_epochDuration == 0) revert ZeroEpochDuration();

        registry = IPermanentGTCRHybrid(_registry);
        systemConfig = ISystemConfig(_systemConfig);
        adapterRegistry = ICurate(_adapterRegistry);
        opAdapter = IOpStackAdapter(_initialAdapter);
        epochDuration = _epochDuration;

        guardian = _guardian;
        emit GuardianSet(_guardian);

        // Emit adapter set event (oldAdapter = address(0) for initial)
        emit AdapterUpgraded(address(0), _initialAdapter, 0, IOpStackAdapter(_initialAdapter).version());

        currentIndex = type(uint256).max;

        unchecked {
            if (block.timestamp >= _epochDuration) {
                lastRotationTimestamp = block.timestamp - _epochDuration;
            } else {
                lastRotationTimestamp = 0;
            }
        }
    }

    // ============ Modifiers ============

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyGuardian() {
        if (guardian == address(0) || msg.sender != guardian) revert InvalidGuardian();
        _;
    }

    // ============ Guardian Functions ============

    function setPaused(bool _paused) external onlyGuardian {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function setGuardian(address _newGuardian) external onlyGuardian {
        guardian = _newGuardian;
        emit GuardianSet(_newGuardian);
    }

    // ============ Adapter Functions ============

    /**
     * @notice Upgrades to a new OP Stack adapter.
     * @dev Anyone can call this. Validates:
     *      1. New adapter is in adapterRegistry (Registered OR ClearingRequested)
     *      2. New adapter version is strictly greater than current (ratchet)
     *
     *      The "Hydra" defense allows multiple adapters to be submitted to the registry
     *      to defeat submission griefing attacks.
     *
     * @param _newAdapter Address of the new adapter to use.
     */
    function upgradeAdapter(address _newAdapter) external notPaused {
        if (_newAdapter == address(0)) revert ZeroAddress();

        // 1. Verify adapter is registered in Kleros Curate registry
        bytes32 itemID = keccak256(abi.encode(_newAdapter));
        (, ICurate.Status status,) = adapterRegistry.getItemInfo(itemID);

        // Accept: Registered (1) OR ClearingRequested (3)
        // This allows upgrades even while removal is pending (gives time to deploy new adapter)
        if (status != ICurate.Status.Registered && status != ICurate.Status.ClearingRequested) {
            revert AdapterNotRegistered();
        }

        // 2. Ratchet check: new version must be strictly greater
        uint256 currentVersion = opAdapter.version();
        uint256 newVersion = IOpStackAdapter(_newAdapter).version();

        if (newVersion <= currentVersion) {
            revert AdapterVersionNotHigher();
        }

        // 3. Perform the upgrade
        address oldAdapter = address(opAdapter);
        opAdapter = IOpStackAdapter(_newAdapter);

        emit AdapterUpgraded(oldAdapter, _newAdapter, currentVersion, newVersion);
    }

    /**
     * @notice Returns information about the current adapter.
     * @return adapter The current adapter address.
     * @return version The current adapter version.
     * @return name The adapter name.
     * @return description The adapter description.
     */
    function getAdapterInfo() external view returns (
        address adapter,
        uint256 version,
        string memory name,
        string memory description
    ) {
        adapter = address(opAdapter);
        version = opAdapter.version();
        (name, description) = opAdapter.adapterInfo();
    }

    // ============ View Functions ============

    function activeOperatorCount() external view returns (uint256) {
        return activeOperators.length;
    }

    function getActiveOperators() external view returns (Operator[] memory) {
        return activeOperators;
    }

    /**
     * @notice Computes the operator ID from keys.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return The operator ID (hash of keys).
     */
    function operatorId(address batcher, address unsafeSigner) public pure returns (bytes32) {
        return keccak256(abi.encode(batcher, unsafeSigner));
    }

    /**
     * @notice Checks if an operator is registered in the registry (O(1) via reverse mapping).
     * @dev Uses snapshot + reverse mapping for efficient validation.
     *      IMPORTANT: Items must have passed their challenge period to be considered valid.
     *      - Submitted items: must be past submissionPeriod
     *      - Reincluded items: always valid (already passed a challenge period or won dispute)
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     * @return True if registered, challenge period passed, and keys still match.
     */
    function isRegisteredInRegistry(address batcher, address unsafeSigner) public view returns (bool) {
        // 1. Get OpId from keys
        bytes32 opId = operatorId(batcher, unsafeSigner);

        // 2. Reverse lookup ItemID
        bytes32 itemID = opIdToItemId[opId];
        if (itemID == bytes32(0)) return false;

        // 3. Verify item is valid in registry
        if (!_isItemValidInRegistry(itemID)) {
            return false;
        }

        // 4. Verify sync (Keys still match in registry?)
        (address regBatcher, address regSigner) = registry.getOperationalKeys(itemID);
        return (regBatcher == batcher && regSigner == unsafeSigner);
    }

    /**
     * @notice Checks if an item is valid for use (passed maturity period).
     * @dev MATURITY REQUIREMENT: Items must have been in their current status
     *      long enough to allow challenges before being used for operator duties.
     *
     *      - Submitted items: valid only after submissionPeriod has elapsed
     *      - Reincluded items: valid only after reinclusionPeriod has elapsed
     *        (includedAt is reset when item becomes Reincluded after dispute)
     *      - Disputed/Absent items: never valid
     *
     * @param _itemID The registry item ID.
     * @return True if the item has passed its maturity period.
     */
    function _isItemValidInRegistry(bytes32 _itemID) internal view returns (bool) {
        (
            IPermanentGTCRHybrid.Status status,
            ,
            ,
            ,
            uint48 includedAt,
            ,

        ) = registry.items(_itemID);

        uint256 duration;

        if (status == IPermanentGTCRHybrid.Status.Submitted) {
            duration = registry.submissionPeriod();
        } else if (status == IPermanentGTCRHybrid.Status.Reincluded) {
            duration = registry.reinclusionPeriod();
        } else {
            // Disputed or Absent items are not valid
            return false;
        }

        // MATURITY CHECK: Item must be older than the challenge period
        return block.timestamp > includedAt + duration;
    }

    /**
     * @notice Returns the current active operator.
     * @return The current Operator tuple.
     */
    function currentOperator() external view returns (Operator memory) {
        if (activeOperators.length == 0) return Operator(address(0), address(0));
        if (currentIndex >= activeOperators.length) return Operator(address(0), address(0));
        return activeOperators[currentIndex];
    }

    function timeUntilNextRotation() external view returns (uint256) {
        uint256 nextRotation = lastRotationTimestamp + epochDuration;
        if (block.timestamp >= nextRotation) return 0;
        return nextRotation - block.timestamp;
    }

    function isCurrentOperator(address batcher, address unsafeSigner) external view returns (bool) {
        if (activeOperators.length == 0) return false;
        if (currentIndex >= activeOperators.length) return false;
        Operator memory current = activeOperators[currentIndex];
        return current.batcher == batcher && current.unsafeSigner == unsafeSigner;
    }

    // ============ Sync Functions ============

    /**
     * @notice Adds an operator to the active set by Kleros item ID.
     * @dev Snapshots keys from registry and creates reverse mapping.
     *      IMPORTANT: Item must have passed its challenge period before syncing.
     *      For Submitted items, this means waiting for submissionPeriod to elapse.
     * @param _itemID The Kleros registry item ID.
     */
    function syncAddOperator(bytes32 _itemID) external notPaused {
        // 1. Check item is valid (passed challenge period)
        if (!_isItemValidInRegistry(_itemID)) {
            revert NotRegisteredInRegistry();
        }

        // 2. Prevent double sync of same item
        if (itemIdToOpId[_itemID] != bytes32(0)) revert ItemAlreadySynced();

        // 3. Snapshot keys from registry
        (address batcher, address unsafeSigner) = registry.getOperationalKeys(_itemID);
        if (batcher == address(0) || unsafeSigner == address(0)) revert InvalidSigner();

        // 4. Create operator ID
        bytes32 opId = operatorId(batcher, unsafeSigner);
        if (isActive[opId]) revert AlreadyActive(); // Keys already in use by another item?

        // 5. Store in active set
        indexOf[opId] = activeOperators.length;
        activeOperators.push(Operator(batcher, unsafeSigner));
        isActive[opId] = true;

        // 6. Store reverse mappings (THE LINK)
        opIdToItemId[opId] = _itemID;
        itemIdToOpId[_itemID] = opId;

        emit OperatorAdded(opId, batcher, unsafeSigner);
    }

    /**
     * @notice Updates keys for an existing operator when registry keys change.
     * @dev Must be called manually if owner updates keys in registry.
     * @param _itemID The Kleros registry item ID.
     */
    function syncUpdateOperator(bytes32 _itemID) external notPaused {
        // 1. Find old operator info
        bytes32 oldOpId = itemIdToOpId[_itemID];
        if (!isActive[oldOpId]) revert NotActive();

        // 2. Get new keys from registry
        (address newBatcher, address newSigner) = registry.getOperationalKeys(_itemID);
        if (newBatcher == address(0) || newSigner == address(0)) revert InvalidSigner();

        bytes32 newOpId = operatorId(newBatcher, newSigner);

        // 3. Update array (swap in place)
        uint256 idx = indexOf[oldOpId];
        activeOperators[idx] = Operator(newBatcher, newSigner);

        // 4. Update mappings
        delete isActive[oldOpId];
        delete indexOf[oldOpId];
        delete opIdToItemId[oldOpId];

        isActive[newOpId] = true;
        indexOf[newOpId] = idx;
        opIdToItemId[newOpId] = _itemID;
        itemIdToOpId[_itemID] = newOpId;

        emit OperatorUpdated(oldOpId, newOpId, newBatcher, newSigner);
    }

    /**
     * @notice Removes an operator from the active set by Kleros item ID.
     * @dev Can only remove if no longer registered in registry.
     * @param _itemID The Kleros registry item ID.
     */
    function syncRemoveOperator(bytes32 _itemID) external notPaused {
        bytes32 opId = itemIdToOpId[_itemID];
        if (!isActive[opId]) revert NotActive();

        // Check if actually removed from registry
        (IPermanentGTCRHybrid.Status status,,,,,,) = registry.items(_itemID);
        if (status == IPermanentGTCRHybrid.Status.Submitted ||
            status == IPermanentGTCRHybrid.Status.Reincluded) {
            revert StillRegisteredInRegistry();
        }

        // Remove from active set
        Operator memory op = activeOperators[indexOf[opId]];
        _removeActiveOperator(opId, op.batcher, op.unsafeSigner);

        // Clean up extra mappings
        delete opIdToItemId[opId];
        delete itemIdToOpId[_itemID];
    }

    // ============ Legacy Sync (Backwards Compatibility) ============

    /**
     * @notice Adds an operator by addresses (legacy interface).
     * @dev Computes itemID from addresses. Use syncAddOperator(itemID) for new integrations.
     *      IMPORTANT: Item must have passed its challenge period before syncing.
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function syncAddOperator(address batcher, address unsafeSigner) external notPaused {
        if (batcher == address(0)) revert ZeroAddress();
        if (unsafeSigner == address(0)) revert ZeroAddress();

        bytes32 opId = operatorId(batcher, unsafeSigner);
        if (isActive[opId]) revert AlreadyActive();

        // For legacy calls, we need to verify the keys match what's in registry
        // This requires the keys to be the itemID computed from encoded data
        bytes32 itemID = keccak256(abi.encodePacked(abi.encode(batcher, unsafeSigner)));

        // Check item is valid (passed challenge period)
        if (!_isItemValidInRegistry(itemID)) {
            revert NotRegisteredInRegistry();
        }

        if (itemIdToOpId[itemID] != bytes32(0)) revert ItemAlreadySynced();

        indexOf[opId] = activeOperators.length;
        activeOperators.push(Operator(batcher, unsafeSigner));
        isActive[opId] = true;

        opIdToItemId[opId] = itemID;
        itemIdToOpId[itemID] = opId;

        emit OperatorAdded(opId, batcher, unsafeSigner);
    }

    /**
     * @notice Removes an operator by addresses (legacy interface).
     * @param batcher The batcher address.
     * @param unsafeSigner The unsafe block signer address.
     */
    function syncRemoveOperator(address batcher, address unsafeSigner) external notPaused {
        bytes32 opId = operatorId(batcher, unsafeSigner);
        if (!isActive[opId]) revert NotActive();

        bytes32 itemID = opIdToItemId[opId];

        (IPermanentGTCRHybrid.Status status,,,,,,) = registry.items(itemID);
        if (status == IPermanentGTCRHybrid.Status.Submitted ||
            status == IPermanentGTCRHybrid.Status.Reincluded) {
            revert StillRegisteredInRegistry();
        }

        _removeActiveOperator(opId, batcher, unsafeSigner);
        delete opIdToItemId[opId];
        delete itemIdToOpId[itemID];
    }

    // ============ Rotation Functions ============

    /**
     * @notice Rotates to the next valid operator and updates SystemConfig.
     * @dev Uses O(1) validation via reverse mapping.
     *
     *      Implements "Active Handoff" 3-Phase State Machine:
     *      - Phase 1 (Protected): 0 to epochDuration - Nobody can rotate
     *      - Phase 2 (Voluntary): epochDuration to epochDuration + GRACE_PERIOD - Only current operator can rotate
     *      - Phase 3 (Forced): After Phase 2 - Anyone can rotate (Dead Man's Switch)
     *
     *      Phase 2 enables zero-downtime handoffs: the outgoing operator flushes their
     *      batch queue before triggering rotation, preventing L2 re-orgs.
     */
    function rotateOperator() external notPaused {
        // 1. Calculate timing
        uint256 timeSinceStart = block.timestamp - lastRotationTimestamp;

        // Phase 1 check: Protected period - nobody can rotate
        if (timeSinceStart < epochDuration) revert EpochNotEnded();

        if (activeOperators.length == 0) revert NoActiveOperators();

        // 2. Check if there's a current operator to protect
        //    Grace period only applies when there IS a current operator.
        //    If no current operator (first rotation or recovery), anyone can rotate.
        bool hasCurrentOperator = (currentIndex < activeOperators.length);

        if (hasCurrentOperator) {
            // 3. Identify if caller is the current operator
            Operator memory currentOp = activeOperators[currentIndex];
            bool isCallerCurrentOperator = (msg.sender == currentOp.batcher || msg.sender == currentOp.unsafeSigner);

            // 4. Phase Logic: Determine if we're in Dead Man's Switch (Phase 3)
            bool isDeadMansSwitch = timeSinceStart > (epochDuration + GRACE_PERIOD);

            // Enforce Phase 2 exclusivity: Only current operator can rotate during grace period
            if (!isDeadMansSwitch && !isCallerCurrentOperator) {
                revert OnlyCurrentOperatorDuringGracePeriod();
            }
        }
        // If no current operator, skip grace period check - allows bootstrap/recovery

        uint256 initialLen = activeOperators.length;
        uint256 checks = 0;

        bool found;
        Operator memory next;
        bytes32 nextOpId;

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

            // Candidate no longer valid, remove
            bytes32 itemID = opIdToItemId[candidateId];
            _removeActiveOperator(candidateId, candidate.batcher, candidate.unsafeSigner);
            delete opIdToItemId[candidateId];
            if (itemID != bytes32(0)) {
                delete itemIdToOpId[itemID];
            }
            checks++;
        }

        if (!found) {
            emit RotationSkippedNoValidOperator(block.timestamp);
            return;
        }

        // Use adapter via delegatecall for SystemConfig updates
        // This allows the adapter to be hot-swapped to survive OP Stack hardforks
        _rotateViaAdapter(next.batcher, next.unsafeSigner);

        bytes32 batcherHash = _toV0BatcherHash(next.batcher);
        lastRotationTimestamp = block.timestamp;
        emit OperatorRotated(nextOpId, next.batcher, next.unsafeSigner, batcherHash, block.timestamp);
    }

    function poke() external {
        this.rotateOperator();
    }

    // ============ Legacy Compatibility ============

    function currentSequencer() external view returns (address) {
        if (activeOperators.length == 0) return address(0);
        if (currentIndex >= activeOperators.length) return address(0);
        return activeOperators[currentIndex].batcher;
    }

    function rotateSequencer() external {
        this.rotateOperator();
    }

    function activeSequencerCount() external view returns (uint256) {
        return activeOperators.length;
    }

    // ============ Internal Functions ============

    function _removeActiveOperator(bytes32 opId, address batcher, address unsafeSigner) internal {
        uint256 idx = indexOf[opId];
        uint256 lastIdx = activeOperators.length - 1;

        if (currentIndex < activeOperators.length && idx < currentIndex) {
            currentIndex -= 1;
        }

        if (idx != lastIdx) {
            Operator memory moved = activeOperators[lastIdx];
            bytes32 movedId = operatorId(moved.batcher, moved.unsafeSigner);
            activeOperators[idx] = moved;
            indexOf[movedId] = idx;
        }

        activeOperators.pop();
        delete indexOf[opId];
        isActive[opId] = false;

        if (activeOperators.length == 0 || currentIndex >= activeOperators.length) {
            currentIndex = type(uint256).max;
        }

        emit OperatorRemoved(opId, batcher, unsafeSigner);
    }

    function _toV0BatcherHash(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /**
     * @notice Executes sequencer rotation via the adapter using delegatecall.
     * @dev The adapter's rotateSequencer function is called via delegatecall,
     *      which means the adapter code runs in this contract's context.
     *      This is safe because:
     *      1. Adapters are gated by Kleros arbitration
     *      2. Version ratchet prevents rollback attacks
     *      3. Adapters only interact with SystemConfig
     *
     * @param _batcher The new batcher address.
     * @param _unsafeSigner The new unsafe block signer address.
     */
    function _rotateViaAdapter(address _batcher, address _unsafeSigner) internal {
        if (address(opAdapter) == address(0)) revert NoAdapterSet();

        // Encode the call to rotateSequencer
        bytes memory data = abi.encodeWithSelector(
            IOpStackAdapter.rotateSequencer.selector,
            address(systemConfig),
            _batcher,
            _unsafeSigner
        );

        // Execute via delegatecall - adapter runs in our context
        (bool success, bytes memory returnData) = address(opAdapter).delegatecall(data);

        if (!success) {
            // Bubble up the revert reason if available
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            revert AdapterCallFailed();
        }
    }
}
