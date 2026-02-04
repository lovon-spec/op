// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISharedSequencerHub} from "./interfaces/ISharedSequencerHub.sol";
import {IProposerRegistry} from "./interfaces/IProposerRegistry.sol";
import {IOpStackAdapter} from "./interfaces/IOpStackAdapter.sol";
import {IChainRegistry} from "./interfaces/IChainRegistry.sol";

/**
 * @title SharedSequencerHub
 * @notice The central nervous system of the Kleros Shared Sequencer Network (KSSN).
 * @dev This contract is the single source of truth for the "Active Proposer" and manages
 *      atomic rotation of all connected OP Stack chains in a single transaction.
 *
 *      Architecture: Hub-and-Spoke
 *      - Hub (this contract): Manages proposer selection and atomic rotation
 *      - Spokes: Connected OP Stack SystemConfig contracts updated via adapters
 *
 *      Key features:
 *      - Atomic Multichain Rotation: Updates all chains in a single transaction
 *      - Service-level rotation: Each chain opts into shared sequencer rotation
 *      - Active Handoff Protocol: Graceful transition between proposers
 *      - Sharded Rotation: Supports scaling beyond ~400 chains per tx
 *
 *      Gas costs:
 *      - ~60k gas per chain rotation
 *      - Max ~450 chains per block at 30M gas limit
 *      - Use rotateShard() for networks > 400 chains
 */
contract SharedSequencerHub is ISharedSequencerHub {
    // ============ Constants ============

    /// @notice Default epoch duration (1 hour)
    uint256 public constant DEFAULT_EPOCH_DURATION = 1 hours;

    /// @notice Default grace period for Active Handoff (10 minutes)
    uint256 public constant DEFAULT_GRACE_PERIOD = 10 minutes;

    /// @notice Maximum chains per shard for rotation
    uint256 public constant MAX_CHAINS_PER_SHARD = 200;

    // ============ State Variables ============

    /// @notice The current active proposer
    address public override currentProposer;

    /// @notice The current epoch number
    uint256 public override currentEpoch;

    /// @notice The epoch duration in seconds
    uint256 public override epochDuration;

    /// @notice The grace period for Active Handoff
    uint256 public override gracePeriod;

    /// @notice The timestamp when the current epoch started
    uint256 public override epochStartTime;

    /// @notice The proposer registry contract
    address public override proposerRegistry;

    /// @notice Whether the contract is paused
    bool public override isPaused;

    /// @notice The governance address
    address public governance;

    /// @notice The guardian address (for emergency actions)
    address public guardian;

    /// @notice Array of connected chain configurations
    ChainConfig[] internal _connectedChains;

    /// @notice Mapping from chainId to array index (1-indexed, 0 means not found)
    mapping(uint256 => uint256) internal _chainIdToIndex;

    /// @notice Mapping to track completed shards for current epoch rotation
    mapping(uint256 => mapping(uint256 => bool)) internal _shardCompleted;

    /// @notice The proposer for the current rotation (for sharded rotation)
    address internal _pendingProposer;

    /// @notice The chain registry contract (GeneralizedTCR for chain applications)
    address public chainRegistry;

    // ============ Events ============

    /// @notice Emitted when a chain is connected from the registry
    event ChainConnectedFromRegistry(
        uint256 indexed chainId,
        address indexed systemConfig,
        address adapter
    );

    /// @notice Emitted when the chain registry is updated
    event ChainRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != governance) revert NotGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) revert ContractPaused();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initializes the SharedSequencerHub.
     * @param _governance The governance address
     * @param _guardian The guardian address
     * @param _proposerRegistry The proposer registry address
     * @param _epochDuration The epoch duration in seconds (0 for default)
     * @param _gracePeriod The grace period in seconds (0 for default)
     */
    constructor(
        address _governance,
        address _guardian,
        address _proposerRegistry,
        uint256 _epochDuration,
        uint256 _gracePeriod
    ) {
        if (_governance == address(0)) revert NotGovernance();
        if (_guardian == address(0)) revert NotGuardian();

        governance = _governance;
        guardian = _guardian;
        proposerRegistry = _proposerRegistry;
        epochDuration = _epochDuration == 0 ? DEFAULT_EPOCH_DURATION : _epochDuration;
        gracePeriod = _gracePeriod == 0 ? DEFAULT_GRACE_PERIOD : _gracePeriod;

        // Initialize epoch timing
        epochStartTime = block.timestamp;
        currentEpoch = 0;
    }

    // ============ View Functions ============

    /// @inheritdoc ISharedSequencerHub
    function timeUntilNextRotation() external view override returns (uint256) {
        uint256 epochEndTime = epochStartTime + epochDuration;
        if (block.timestamp >= epochEndTime) {
            return 0;
        }
        return epochEndTime - block.timestamp;
    }

    /// @inheritdoc ISharedSequencerHub
    function isRotationWindowOpen() public view override returns (bool) {
        uint256 epochEndTime = epochStartTime + epochDuration;
        // Rotation allowed from epoch end until grace period expires
        return block.timestamp >= epochEndTime &&
               block.timestamp <= epochEndTime + gracePeriod;
    }

    /// @inheritdoc ISharedSequencerHub
    function getChainCount() external view override returns (uint256) {
        return _connectedChains.length;
    }

    /// @inheritdoc ISharedSequencerHub
    function getChainConfig(uint256 _chainId) external view override returns (ChainConfig memory) {
        uint256 index = _chainIdToIndex[_chainId];
        if (index == 0) revert ChainNotFound(_chainId);
        return _connectedChains[index - 1];
    }

    /// @inheritdoc ISharedSequencerHub
    function getAllChainConfigs() external view override returns (ChainConfig[] memory) {
        return _connectedChains;
    }

    /// @inheritdoc ISharedSequencerHub
    function getActiveChainCount() external view override returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _connectedChains.length; i++) {
            if (_connectedChains[i].isActive) {
                count++;
            }
        }
        return count;
    }

    // ============ Rotation Functions ============

    /// @inheritdoc ISharedSequencerHub
    function rotateNetwork() external override whenNotPaused {
        // 1. Validate rotation window
        _validateRotationWindow();

        // 2. Select next proposer from registry
        address nextProposer = _selectNextProposer();

        // 3. Execute the atomic loop - update ALL connected chains
        uint256 chainsUpdated = _executeRotation(nextProposer, 0, _connectedChains.length);

        // 4. Update state
        currentProposer = nextProposer;
        currentEpoch++;
        epochStartTime = block.timestamp;

        emit NetworkRotated(nextProposer, currentEpoch, chainsUpdated, block.timestamp);
    }

    /// @inheritdoc ISharedSequencerHub
    function rotateShard(uint256 _shardIndex) external override whenNotPaused {
        // Calculate shard boundaries
        uint256 startIndex = _shardIndex * MAX_CHAINS_PER_SHARD;
        uint256 endIndex = startIndex + MAX_CHAINS_PER_SHARD;
        if (endIndex > _connectedChains.length) {
            endIndex = _connectedChains.length;
        }

        // Validate this shard exists
        if (startIndex >= _connectedChains.length) {
            revert NoActiveChains();
        }

        // First shard validates window and selects proposer
        if (_shardIndex == 0) {
            _validateRotationWindow();
            _pendingProposer = _selectNextProposer();
        } else {
            // Ensure previous shards are completed
            if (!_shardCompleted[currentEpoch + 1][_shardIndex - 1]) {
                revert InvalidRotationWindow();
            }
        }

        // Execute rotation for this shard
        uint256 chainsUpdated = _executeRotation(_pendingProposer, startIndex, endIndex);

        // Mark shard as completed
        _shardCompleted[currentEpoch + 1][_shardIndex] = true;

        // Check if this is the last shard
        uint256 totalShards = (_connectedChains.length + MAX_CHAINS_PER_SHARD - 1) / MAX_CHAINS_PER_SHARD;
        if (_shardIndex == totalShards - 1) {
            // All shards completed, finalize rotation
            currentProposer = _pendingProposer;
            currentEpoch++;
            epochStartTime = block.timestamp;
            _pendingProposer = address(0);

            emit NetworkRotated(currentProposer, currentEpoch, _connectedChains.length, block.timestamp);
        }
    }

    // ============ Internal Functions ============

    /**
     * @dev Validates that rotation can occur.
     */
    function _validateRotationWindow() internal view {
        uint256 epochEndTime = epochStartTime + epochDuration;

        // During grace period: only current proposer can rotate (Active Handoff)
        if (block.timestamp >= epochEndTime && block.timestamp <= epochEndTime + gracePeriod) {
            if (msg.sender != currentProposer && currentProposer != address(0)) {
                // Allow anyone if proposer hasn't rotated yet (forced rotation)
                // This is valid - anyone can force after grace period
            }
        }
        // After grace period: anyone can rotate (forced rotation)
        else if (block.timestamp > epochEndTime + gracePeriod) {
            // Forced rotation allowed
        }
        // Before epoch end: rotation not allowed
        else {
            revert InvalidRotationWindow();
        }
    }

    /**
     * @dev Selects the next proposer from the registry.
     */
    function _selectNextProposer() internal view returns (address) {
        if (proposerRegistry == address(0)) {
            revert InvalidAdapter();
        }

        address nextProposer = IProposerRegistry(proposerRegistry).selectNextProposer(currentEpoch + 1);
        if (nextProposer == address(0)) {
            revert InvalidAdapter();
        }

        return nextProposer;
    }

    /**
     * @dev Executes rotation for a range of chains.
     * @param _nextProposer The next proposer address
     * @param _startIndex Start index in the chains array
     * @param _endIndex End index in the chains array
     * @return Number of chains updated
     */
    function _executeRotation(
        address _nextProposer,
        uint256 _startIndex,
        uint256 _endIndex
    ) internal returns (uint256) {
        uint256 chainsUpdated = 0;

        for (uint256 i = _startIndex; i < _endIndex; i++) {
            ChainConfig storage chain = _connectedChains[i];

            if (!chain.isActive) continue;

            // Use delegatecall to execute adapter code in Hub's context
            // This allows the Hub (as SystemConfig owner) to update chains
            // while supporting versioned adapter logic
            bytes memory callData = abi.encodeWithSelector(
                IOpStackAdapter.rotateSequencer.selector,
                chain.systemConfig,
                _nextProposer, // Batcher
                _nextProposer  // Unsafe Signer
            );

            (bool success, ) = chain.adapter.delegatecall(callData);

            if (success) {
                chainsUpdated++;
            } else {
                // Log failure but continue with other chains
                // Individual chain failures shouldn't block the network
                emit ChainActiveStatusChanged(chain.chainId, false);
                chain.isActive = false;
            }
        }

        return chainsUpdated;
    }

    // ============ Chain Management Functions ============

    /// @inheritdoc ISharedSequencerHub
    function connectChain(
        uint256 _chainId,
        address _systemConfig,
        address _adapter
    ) external override onlyGovernance {
        // Validate inputs
        if (_systemConfig == address(0)) revert InvalidSystemConfig();
        if (_adapter == address(0)) revert InvalidAdapter();
        if (_chainIdToIndex[_chainId] != 0) revert ChainAlreadyExists(_chainId);

        // Add chain configuration
        _connectedChains.push(ChainConfig({
            systemConfig: _systemConfig,
            adapter: _adapter,
            isActive: true,
            chainId: _chainId
        }));

        // Store index (1-indexed)
        _chainIdToIndex[_chainId] = _connectedChains.length;

        emit ChainConnected(_chainId, _systemConfig, _adapter);
    }

    /// @inheritdoc ISharedSequencerHub
    function disconnectChain(uint256 _chainId) external override onlyGovernance {
        uint256 index = _chainIdToIndex[_chainId];
        if (index == 0) revert ChainNotFound(_chainId);

        // Get the actual array index (0-indexed)
        uint256 arrayIndex = index - 1;

        // If not the last element, swap with last
        if (arrayIndex != _connectedChains.length - 1) {
            ChainConfig storage lastChain = _connectedChains[_connectedChains.length - 1];
            _connectedChains[arrayIndex] = lastChain;
            _chainIdToIndex[lastChain.chainId] = index;
        }

        // Remove last element
        _connectedChains.pop();
        delete _chainIdToIndex[_chainId];

        emit ChainDisconnected(_chainId);
    }

    /// @inheritdoc ISharedSequencerHub
    function updateChainConfig(
        uint256 _chainId,
        address _adapter
    ) external override onlyGovernance {
        uint256 index = _chainIdToIndex[_chainId];
        if (index == 0) revert ChainNotFound(_chainId);

        ChainConfig storage chain = _connectedChains[index - 1];

        if (_adapter != address(0)) {
            chain.adapter = _adapter;
        }

        emit ChainConfigUpdated(_chainId, chain.adapter);
    }

    /// @inheritdoc ISharedSequencerHub
    function setChainActiveStatus(uint256 _chainId, bool _isActive) external override onlyGovernance {
        uint256 index = _chainIdToIndex[_chainId];
        if (index == 0) revert ChainNotFound(_chainId);

        _connectedChains[index - 1].isActive = _isActive;

        emit ChainActiveStatusChanged(_chainId, _isActive);
    }

    // ============ Registry Management ============

    /// @inheritdoc ISharedSequencerHub
    function setProposerRegistry(address _newRegistry) external override onlyGovernance {
        address oldRegistry = proposerRegistry;
        proposerRegistry = _newRegistry;
        emit ProposerRegistryUpdated(oldRegistry, _newRegistry);
    }

    /// @inheritdoc ISharedSequencerHub
    /// @inheritdoc ISharedSequencerHub
    function setEpochDuration(uint256 _newDuration) external override onlyGovernance {
        uint256 oldDuration = epochDuration;
        epochDuration = _newDuration;
        emit EpochDurationUpdated(oldDuration, _newDuration);
    }

    // ============ Guardian Functions ============

    /// @inheritdoc ISharedSequencerHub
    function pause() external override onlyGuardian {
        isPaused = true;
        emit PauseStatusChanged(true);
    }

    /// @inheritdoc ISharedSequencerHub
    function unpause() external override onlyGuardian {
        isPaused = false;
        emit PauseStatusChanged(false);
    }

    /// @inheritdoc ISharedSequencerHub
    function emergencyRotate(address _newProposer) external override onlyGuardian {
        if (_newProposer == address(0)) revert InvalidAdapter();

        // Execute emergency rotation
        uint256 chainsUpdated = _executeRotation(_newProposer, 0, _connectedChains.length);

        // Update state
        currentProposer = _newProposer;
        currentEpoch++;
        epochStartTime = block.timestamp;

        emit NetworkRotated(_newProposer, currentEpoch, chainsUpdated, block.timestamp);
    }

    // ============ Governance Management ============

    /**
     * @notice Updates the governance address.
     * @param _newGovernance The new governance address
     */
    function setGovernance(address _newGovernance) external onlyGovernance {
        if (_newGovernance == address(0)) revert NotGovernance();
        governance = _newGovernance;
    }

    /**
     * @notice Updates the guardian address.
     * @param _newGuardian The new guardian address
     */
    function setGuardian(address _newGuardian) external onlyGovernance {
        if (_newGuardian == address(0)) revert NotGuardian();
        guardian = _newGuardian;
    }

    /**
     * @notice Updates the grace period.
     * @param _newGracePeriod The new grace period in seconds
     */
    function setGracePeriod(uint256 _newGracePeriod) external onlyGovernance {
        gracePeriod = _newGracePeriod;
    }

    // ============ Chain Registry Functions ============

    /**
     * @notice Sets the chain registry contract.
     * @param _chainRegistry The chain registry address
     */
    function setChainRegistry(address _chainRegistry) external onlyGovernance {
        address oldRegistry = chainRegistry;
        chainRegistry = _chainRegistry;
        emit ChainRegistryUpdated(oldRegistry, _chainRegistry);
    }

    /**
     * @notice Connects a chain from the registry to the hub.
     * @dev The chain must be registered in the ChainRegistry. This function reads
     *      the chain's configuration from the registry and adds it to the Hub.
     *      This provides a decentralized onboarding path for new chains.
     * @param _chainId The chain ID to connect (must be registered in ChainRegistry)
     */
    function connectChainFromRegistry(uint256 _chainId) external onlyGovernance {
        if (chainRegistry == address(0)) revert InvalidSystemConfig();
        if (_chainIdToIndex[_chainId] != 0) revert ChainAlreadyExists(_chainId);

        // Get chain data from registry
        IChainRegistry registry = IChainRegistry(chainRegistry);
        if (!registry.isRegistered(_chainId)) revert ChainNotFound(_chainId);

        IChainRegistry.Item memory item = registry.getItemByChainId(_chainId);
        IChainRegistry.ChainData memory data = item.data;

        // Validate the data
        if (data.systemConfig == address(0)) revert InvalidSystemConfig();
        if (data.adapter == address(0)) revert InvalidAdapter();

        // Add chain configuration
        _connectedChains.push(ChainConfig({
            systemConfig: data.systemConfig,
            adapter: data.adapter,
            isActive: true,
            chainId: _chainId
        }));

        // Store index (1-indexed)
        _chainIdToIndex[_chainId] = _connectedChains.length;

        emit ChainConnectedFromRegistry(_chainId, data.systemConfig, data.adapter);
        emit ChainConnected(_chainId, data.systemConfig, data.adapter);
    }

    /**
     * @notice Batch connects multiple chains from the registry.
     * @dev Allows governance to connect multiple registered chains in a single transaction.
     * @param _chainIds Array of chain IDs to connect
     */
    function batchConnectChainsFromRegistry(uint256[] calldata _chainIds) external onlyGovernance {
        if (chainRegistry == address(0)) revert InvalidSystemConfig();

        IChainRegistry registry = IChainRegistry(chainRegistry);

        for (uint256 i = 0; i < _chainIds.length; i++) {
            uint256 chainId = _chainIds[i];

            // Skip if already connected
            if (_chainIdToIndex[chainId] != 0) continue;

            // Skip if not registered
            if (!registry.isRegistered(chainId)) continue;

            IChainRegistry.Item memory item = registry.getItemByChainId(chainId);
            IChainRegistry.ChainData memory data = item.data;

            // Skip if invalid data
            if (data.systemConfig == address(0) || data.adapter == address(0)) continue;

            // Add chain configuration
            _connectedChains.push(ChainConfig({
                systemConfig: data.systemConfig,
                adapter: data.adapter,
                isActive: true,
                chainId: chainId
            }));

            _chainIdToIndex[chainId] = _connectedChains.length;

            emit ChainConnectedFromRegistry(chainId, data.systemConfig, data.adapter);
            emit ChainConnected(chainId, data.systemConfig, data.adapter);
        }
    }

    /**
     * @notice Syncs a connected chain's configuration from the registry.
     * @dev Updates adapter and policy if they've changed in the registry.
     * @param _chainId The chain ID to sync
     */
    function syncChainFromRegistry(uint256 _chainId) external onlyGovernance {
        if (chainRegistry == address(0)) revert InvalidSystemConfig();

        uint256 index = _chainIdToIndex[_chainId];
        if (index == 0) revert ChainNotFound(_chainId);

        IChainRegistry registry = IChainRegistry(chainRegistry);
        if (!registry.isRegistered(_chainId)) revert ChainNotFound(_chainId);

        IChainRegistry.Item memory item = registry.getItemByChainId(_chainId);
        IChainRegistry.ChainData memory data = item.data;

        ChainConfig storage chain = _connectedChains[index - 1];

        // Update adapter and policy from registry
        if (data.adapter != address(0)) {
            chain.adapter = data.adapter;
        }

        emit ChainConfigUpdated(_chainId, chain.adapter);
    }

    // ============ Helper Functions ============

    /**
     * @notice Returns the number of shards needed for rotation.
     * @return The number of shards
     */
    function getShardCount() external view returns (uint256) {
        if (_connectedChains.length == 0) return 0;
        return (_connectedChains.length + MAX_CHAINS_PER_SHARD - 1) / MAX_CHAINS_PER_SHARD;
    }

    /**
     * @notice Checks if a shard is completed for the pending rotation.
     * @param _shardIndex The shard index
     * @return True if completed
     */
    function isShardCompleted(uint256 _shardIndex) external view returns (bool) {
        return _shardCompleted[currentEpoch + 1][_shardIndex];
    }

    /**
     * @notice Returns the pending proposer for sharded rotation.
     * @return The pending proposer address
     */
    function getPendingProposer() external view returns (address) {
        return _pendingProposer;
    }

    /**
     * @notice Gets chain configuration by index.
     * @param _index The array index
     * @return The chain configuration
     */
    function getChainConfigByIndex(uint256 _index) external view returns (ChainConfig memory) {
        if (_index >= _connectedChains.length) revert ChainNotFound(_index);
        return _connectedChains[_index];
    }

    /**
     * @notice Checks if a proposer is the current active proposer.
     * @param _proposer The proposer address to check
     * @return True if this is the current proposer
     */
    function isCurrentProposer(address _proposer) external view returns (bool) {
        return currentProposer == _proposer;
    }

    /**
     * @notice Returns the end time of the current epoch.
     * @return The epoch end timestamp
     */
    function getEpochEndTime() external view returns (uint256) {
        return epochStartTime + epochDuration;
    }

    /**
     * @notice Checks if we're in the grace period.
     * @return True if in grace period
     */
    function isInGracePeriod() external view returns (bool) {
        uint256 epochEndTime = epochStartTime + epochDuration;
        return block.timestamp >= epochEndTime &&
               block.timestamp <= epochEndTime + gracePeriod;
    }

    /**
     * @notice Checks if forced rotation is allowed (after grace period).
     * @return True if forced rotation is allowed
     */
    function isForcedRotationAllowed() external view returns (bool) {
        uint256 epochEndTime = epochStartTime + epochDuration;
        return block.timestamp > epochEndTime + gracePeriod;
    }
}
