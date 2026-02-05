// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IProposerRegistry} from "./interfaces/IProposerRegistry.sol";

/**
 * @title ProposerRegistry
 * @notice "The Dumb Pipe" - Registry for proposers in ISOCHRON.
 * @dev Proposers are infrastructure providers focused on Liveness and rotation readiness.
 *      They operate a Top-N Delegated Proof of Stake (DPoS) system.
 *
 *      Key features:
 *      - Top-N Selection: Only the top 100 staked addresses are eligible
 *      - Rebalancing: Public function to swap low-stake active with high-stake inactive
 *      - Operational Key Separation: Staking key can differ from signing key
 *
 *      Selection Algorithm:
 *      - Round-robin through active proposers based on epoch number
 *      - Weighted selection can be added in future versions
 */
contract ProposerRegistry is IProposerRegistry {
    // ============ Constants ============

    /// @notice Default minimum stake (32 ETH)
    uint256 public constant DEFAULT_MINIMUM_STAKE = 32 ether;

    /// @notice Default maximum active set size (100)
    uint256 public constant DEFAULT_MAX_ACTIVE_SET_SIZE = 100;

    /// @notice Liveness score precision (10000 = 100.00%)
    uint256 public constant LIVENESS_PRECISION = 10000;

    /// @notice Minimum liveness score before slashing (95%)
    uint256 public constant MIN_LIVENESS_SCORE = 9500;

    /// @notice Slash percentage for liveness failure (basis points)
    uint256 public constant DEFAULT_LIVENESS_SLASH_PERCENTAGE = 500; // 5%

    // ============ State Variables ============

    /// @notice The minimum stake required to register
    uint256 public override minimumStake;

    /// @notice The maximum size of the active proposer set
    uint256 public override maxActiveSetSize;

    /// @notice The hub contract address
    address public override hub;

    /// @notice The governance address
    address public governance;

    /// @notice Proposer information mapping
    mapping(address => ProposerInfo) internal _proposers;

    /// @notice Array of active proposer addresses (for round-robin selection)
    address[] internal _activeProposers;

    /// @notice Mapping from active proposer to their index in the array (1-indexed)
    mapping(address => uint256) internal _activeProposerIndex;

    /// @notice Array of all registered proposer addresses
    address[] internal _registeredProposers;

    /// @notice Mapping from registered proposer to their index (1-indexed)
    mapping(address => uint256) internal _registeredProposerIndex;

    /// @notice Delegation mapping: delegator -> proposer -> amount
    mapping(address => mapping(address => uint256)) internal _delegations;

    /// @notice Total delegated amount per delegator
    mapping(address => uint256) internal _totalDelegated;

    /// @notice Adapter-specific rotation data for proposers
    mapping(address => mapping(address => bytes)) internal _adapterData;

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyHub() {
        if (msg.sender != hub) revert Unauthorized();
        _;
    }

    modifier onlyHubOrGovernance() {
        if (msg.sender != hub && msg.sender != governance) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initializes the ProposerRegistry.
     * @param _governance The governance address
     * @param _hub The hub contract address
     * @param _minimumStake The minimum stake (0 for default)
     * @param _maxActiveSetSize The max active set size (0 for default)
     */
    constructor(
        address _governance,
        address _hub,
        uint256 _minimumStake,
        uint256 _maxActiveSetSize
    ) {
        if (_governance == address(0)) revert Unauthorized();

        governance = _governance;
        hub = _hub;
        minimumStake = _minimumStake == 0 ? DEFAULT_MINIMUM_STAKE : _minimumStake;
        maxActiveSetSize = _maxActiveSetSize == 0 ? DEFAULT_MAX_ACTIVE_SET_SIZE : _maxActiveSetSize;
    }

    // ============ View Functions ============

    /// @inheritdoc IProposerRegistry
    function getProposerInfo(address _proposer) external view override returns (ProposerInfo memory) {
        return _proposers[_proposer];
    }

    /// @inheritdoc IProposerRegistry
    function getActiveProposers() external view override returns (address[] memory) {
        return _activeProposers;
    }

    /// @inheritdoc IProposerRegistry
    function getTotalStake(address _proposer) public view override returns (uint256) {
        ProposerInfo storage info = _proposers[_proposer];
        return info.stake + info.delegatedStake;
    }

    /// @inheritdoc IProposerRegistry
    function getRegisteredProposerCount() external view override returns (uint256) {
        return _registeredProposers.length;
    }

    /// @inheritdoc IProposerRegistry
    function getActiveProposerCount() external view override returns (uint256) {
        return _activeProposers.length;
    }

    /// @inheritdoc IProposerRegistry
    function isActiveProposer(address _proposer) public view override returns (bool) {
        return _activeProposerIndex[_proposer] != 0;
    }

    /// @inheritdoc IProposerRegistry
    function getDelegation(address _delegator, address _proposer) external view override returns (uint256) {
        return _delegations[_delegator][_proposer];
    }

    /// @inheritdoc IProposerRegistry
    function getAdapterData(address _proposer, address _adapter) external view override returns (bytes memory) {
        return _adapterData[_proposer][_adapter];
    }

    /// @inheritdoc IProposerRegistry
    function needsRebalancing() public view override returns (bool) {
        if (_activeProposers.length < maxActiveSetSize) {
            // Check if there are inactive proposers with stake
            for (uint256 i = 0; i < _registeredProposers.length; i++) {
                address proposer = _registeredProposers[i];
                if (!isActiveProposer(proposer) && getTotalStake(proposer) >= minimumStake) {
                    return true;
                }
            }
            return false;
        }

        // Active set is full, check if any inactive has more stake than active
        (address lowestActive, uint256 lowestStake) = getLowestActiveProposer();
        (address highestInactive, uint256 highestStake) = getHighestInactiveProposer();

        if (lowestActive == address(0) || highestInactive == address(0)) {
            return false;
        }

        return highestStake > lowestStake;
    }

    /// @inheritdoc IProposerRegistry
    function getLowestActiveProposer() public view override returns (address proposer, uint256 stake) {
        if (_activeProposers.length == 0) {
            return (address(0), 0);
        }

        proposer = _activeProposers[0];
        stake = getTotalStake(proposer);

        for (uint256 i = 1; i < _activeProposers.length; i++) {
            address current = _activeProposers[i];
            uint256 currentStake = getTotalStake(current);
            if (currentStake < stake) {
                proposer = current;
                stake = currentStake;
            }
        }
    }

    /// @inheritdoc IProposerRegistry
    function getHighestInactiveProposer() public view override returns (address proposer, uint256 stake) {
        proposer = address(0);
        stake = 0;

        for (uint256 i = 0; i < _registeredProposers.length; i++) {
            address current = _registeredProposers[i];
            if (isActiveProposer(current)) continue;

            uint256 currentStake = getTotalStake(current);
            if (currentStake > stake && currentStake >= minimumStake) {
                proposer = current;
                stake = currentStake;
            }
        }
    }

    /// @inheritdoc IProposerRegistry
    function selectNextProposer(uint256 _currentEpoch) external view override returns (address) {
        if (_activeProposers.length == 0) {
            return address(0);
        }

        // Simple round-robin selection based on epoch
        uint256 index = _currentEpoch % _activeProposers.length;
        return _activeProposers[index];
    }

    // ============ Proposer Functions ============

    /// @inheritdoc IProposerRegistry
    function register(address _operationalKey) external payable override {
        if (_proposers[msg.sender].isRegistered) revert ProposerAlreadyRegistered(msg.sender);
        if (msg.value < minimumStake) revert InsufficientStake(msg.value, minimumStake);
        if (_operationalKey == address(0)) revert InvalidOperationalKey();

        // Create proposer info
        _proposers[msg.sender] = ProposerInfo({
            stake: msg.value,
            delegatedStake: 0,
            isActive: false,
            isRegistered: true,
            lastActiveEpoch: 0,
            livenessScore: LIVENESS_PRECISION, // Start at 100%
            operationalKey: _operationalKey
        });

        // Add to registered list
        _registeredProposers.push(msg.sender);
        _registeredProposerIndex[msg.sender] = _registeredProposers.length;

        // Try to add to active set if not full
        _tryAddToActiveSet(msg.sender);

        emit ProposerRegistered(msg.sender, msg.value, _operationalKey);
    }

    /// @inheritdoc IProposerRegistry
    function unregister() external override {
        ProposerInfo storage info = _proposers[msg.sender];
        if (!info.isRegistered) revert ProposerNotRegistered(msg.sender);
        if (info.isActive) revert CannotUnregisterActiveProposer();

        uint256 stakeToReturn = info.stake;

        // Remove from registered list
        _removeFromRegisteredList(msg.sender);

        // Clear proposer info
        delete _proposers[msg.sender];

        // Return stake
        if (stakeToReturn > 0) {
            (bool success, ) = msg.sender.call{value: stakeToReturn}("");
            require(success, "Transfer failed");
        }

        emit ProposerUnregistered(msg.sender, stakeToReturn);
    }

    /// @inheritdoc IProposerRegistry
    function addStake() external payable override {
        ProposerInfo storage info = _proposers[msg.sender];
        if (!info.isRegistered) revert ProposerNotRegistered(msg.sender);

        info.stake += msg.value;

        emit StakeAdded(msg.sender, msg.value, info.stake);

        // Check if rebalancing needed
        if (!info.isActive && needsRebalancing()) {
            _rebalanceInternal();
        }
    }

    /// @inheritdoc IProposerRegistry
    function withdrawStake(uint256 _amount) external override {
        ProposerInfo storage info = _proposers[msg.sender];
        if (!info.isRegistered) revert ProposerNotRegistered(msg.sender);

        // Can't withdraw below minimum while registered and active
        if (info.isActive && info.stake - _amount < minimumStake) {
            revert InsufficientBalance(_amount, info.stake - minimumStake);
        }

        if (_amount > info.stake) revert InsufficientBalance(_amount, info.stake);

        info.stake -= _amount;

        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");

        emit StakeWithdrawn(msg.sender, _amount, info.stake);

        // If stake dropped below minimum while active, trigger rebalance
        if (info.isActive && getTotalStake(msg.sender) < minimumStake) {
            _removeFromActiveSet(msg.sender);
            _rebalanceInternal();
        }
    }

    /// @inheritdoc IProposerRegistry
    function updateOperationalKey(address _newKey) external override {
        ProposerInfo storage info = _proposers[msg.sender];
        if (!info.isRegistered) revert ProposerNotRegistered(msg.sender);
        if (_newKey == address(0)) revert InvalidOperationalKey();

        address oldKey = info.operationalKey;
        info.operationalKey = _newKey;

        emit OperationalKeyUpdated(msg.sender, oldKey, _newKey);
    }

    /// @inheritdoc IProposerRegistry
    function setAdapterData(address _adapter, bytes calldata _data) external override {
        ProposerInfo storage info = _proposers[msg.sender];
        if (!info.isRegistered) revert ProposerNotRegistered(msg.sender);
        if (_adapter == address(0)) revert Unauthorized();

        _adapterData[msg.sender][_adapter] = _data;

        emit AdapterDataUpdated(msg.sender, _adapter, _data);
    }

    // ============ Delegation Functions ============

    /// @inheritdoc IProposerRegistry
    function delegate(address _proposer) external payable override {
        if (!_proposers[_proposer].isRegistered) revert ProposerNotRegistered(_proposer);
        if (msg.value == 0) revert InsufficientStake(0, 1);

        _delegations[msg.sender][_proposer] += msg.value;
        _totalDelegated[msg.sender] += msg.value;
        _proposers[_proposer].delegatedStake += msg.value;

        emit StakeDelegated(msg.sender, _proposer, msg.value);

        // Check if rebalancing needed
        if (!_proposers[_proposer].isActive && needsRebalancing()) {
            _rebalanceInternal();
        }
    }

    /// @inheritdoc IProposerRegistry
    function undelegate(address _proposer, uint256 _amount) external override {
        uint256 delegated = _delegations[msg.sender][_proposer];
        if (_amount > delegated) revert InsufficientBalance(_amount, delegated);

        _delegations[msg.sender][_proposer] -= _amount;
        _totalDelegated[msg.sender] -= _amount;
        _proposers[_proposer].delegatedStake -= _amount;

        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");

        emit DelegationRemoved(msg.sender, _proposer, _amount);

        // If proposer dropped below minimum while active, trigger rebalance
        ProposerInfo storage info = _proposers[_proposer];
        if (info.isActive && getTotalStake(_proposer) < minimumStake) {
            _removeFromActiveSet(_proposer);
            _rebalanceInternal();
        }
    }

    // ============ Public Functions ============

    /// @inheritdoc IProposerRegistry
    function rebalance() external override {
        if (!needsRebalancing()) revert RebalanceNotNeeded();
        _rebalanceInternal();
    }

    // ============ Hub Functions ============

    /// @inheritdoc IProposerRegistry
    function reportLiveness(
        address _proposer,
        uint256 _epoch,
        uint256 _blocksProduced,
        uint256 _blocksExpected
    ) external override onlyHubOrGovernance {
        ProposerInfo storage info = _proposers[_proposer];
        if (!info.isRegistered) revert ProposerNotRegistered(_proposer);

        // Calculate liveness score for this epoch
        uint256 epochScore = _blocksExpected > 0
            ? (_blocksProduced * LIVENESS_PRECISION) / _blocksExpected
            : LIVENESS_PRECISION;

        // Weighted average with historical score (90% history, 10% new)
        info.livenessScore = (info.livenessScore * 9 + epochScore) / 10;
        info.lastActiveEpoch = _epoch;

        emit LivenessReported(_proposer, _epoch, info.livenessScore);

        // Auto-slash if liveness drops below threshold
        if (info.livenessScore < MIN_LIVENESS_SCORE) {
            _slashForLivenessInternal(_proposer, DEFAULT_LIVENESS_SLASH_PERCENTAGE);
        }
    }

    /// @inheritdoc IProposerRegistry
    function slashForLiveness(address _proposer, uint256 _percentage) external override onlyHubOrGovernance {
        _slashForLivenessInternal(_proposer, _percentage);
    }

    // ============ Governance Functions ============

    /// @inheritdoc IProposerRegistry
    function setMinimumStake(uint256 _newMinimum) external override onlyGovernance {
        minimumStake = _newMinimum;
    }

    /// @inheritdoc IProposerRegistry
    function setMaxActiveSetSize(uint256 _newSize) external override onlyGovernance {
        maxActiveSetSize = _newSize;
    }

    /// @inheritdoc IProposerRegistry
    function setHub(address _hub) external override onlyGovernance {
        if (_hub == address(0)) revert InvalidHub();
        hub = _hub;
    }

    /**
     * @notice Updates the governance address.
     * @param _newGovernance The new governance address
     */
    function setGovernance(address _newGovernance) external onlyGovernance {
        if (_newGovernance == address(0)) revert Unauthorized();
        governance = _newGovernance;
    }

    // ============ Internal Functions ============

    /**
     * @dev Attempts to add a proposer to the active set.
     */
    function _tryAddToActiveSet(address _proposer) internal {
        if (_activeProposers.length >= maxActiveSetSize) {
            return;
        }

        if (getTotalStake(_proposer) < minimumStake) {
            return;
        }

        _addToActiveSet(_proposer);
    }

    /**
     * @dev Adds a proposer to the active set.
     */
    function _addToActiveSet(address _proposer) internal {
        if (_activeProposerIndex[_proposer] != 0) return;

        _activeProposers.push(_proposer);
        _activeProposerIndex[_proposer] = _activeProposers.length;
        _proposers[_proposer].isActive = true;
    }

    /**
     * @dev Removes a proposer from the active set.
     */
    function _removeFromActiveSet(address _proposer) internal {
        uint256 index = _activeProposerIndex[_proposer];
        if (index == 0) return;

        uint256 arrayIndex = index - 1;

        // Swap with last if not already last
        if (arrayIndex != _activeProposers.length - 1) {
            address lastProposer = _activeProposers[_activeProposers.length - 1];
            _activeProposers[arrayIndex] = lastProposer;
            _activeProposerIndex[lastProposer] = index;
        }

        _activeProposers.pop();
        delete _activeProposerIndex[_proposer];
        _proposers[_proposer].isActive = false;
    }

    /**
     * @dev Removes a proposer from the registered list.
     */
    function _removeFromRegisteredList(address _proposer) internal {
        uint256 index = _registeredProposerIndex[_proposer];
        if (index == 0) return;

        uint256 arrayIndex = index - 1;

        if (arrayIndex != _registeredProposers.length - 1) {
            address lastProposer = _registeredProposers[_registeredProposers.length - 1];
            _registeredProposers[arrayIndex] = lastProposer;
            _registeredProposerIndex[lastProposer] = index;
        }

        _registeredProposers.pop();
        delete _registeredProposerIndex[_proposer];
    }

    /**
     * @dev Internal rebalancing logic.
     */
    function _rebalanceInternal() internal {
        // First, fill empty slots if active set not full
        while (_activeProposers.length < maxActiveSetSize) {
            (address candidate, uint256 candidateStake) = getHighestInactiveProposer();
            if (candidate == address(0) || candidateStake < minimumStake) break;
            _addToActiveSet(candidate);
        }

        // Then, swap lowest active with highest inactive if beneficial
        (address lowest, uint256 lowestStake) = getLowestActiveProposer();
        (address highest, uint256 highestStake) = getHighestInactiveProposer();

        if (lowest != address(0) && highest != address(0) && highestStake > lowestStake) {
            _removeFromActiveSet(lowest);
            _addToActiveSet(highest);

            emit ActiveSetRebalanced(lowest, highest, lowestStake, highestStake);
        }
    }

    /**
     * @dev Internal slashing for liveness.
     */
    function _slashForLivenessInternal(address _proposer, uint256 _percentage) internal {
        ProposerInfo storage info = _proposers[_proposer];
        if (!info.isRegistered) revert ProposerNotRegistered(_proposer);

        uint256 slashAmount = (info.stake * _percentage) / LIVENESS_PRECISION;
        if (slashAmount > info.stake) {
            slashAmount = info.stake;
        }

        info.stake -= slashAmount;

        // Remove from active set if stake drops below minimum
        if (info.isActive && getTotalStake(_proposer) < minimumStake) {
            _removeFromActiveSet(_proposer);
        }

        emit ProposerSlashedForLiveness(_proposer, slashAmount, info.livenessScore);

        // Slashed funds go to the contract (can be distributed to other stakers)
        // In a full implementation, this would go to a treasury or insurance fund
    }

    // ============ Helper Functions ============

    /**
     * @notice Returns all registered proposers.
     * @return Array of registered proposer addresses
     */
    function getRegisteredProposers() external view returns (address[] memory) {
        return _registeredProposers;
    }

    /**
     * @notice Checks if a proposer is registered.
     * @param _proposer The proposer address
     * @return True if registered
     */
    function isRegistered(address _proposer) external view returns (bool) {
        return _proposers[_proposer].isRegistered;
    }

    /**
     * @notice Returns the operational key for a proposer.
     * @param _proposer The proposer address
     * @return The operational key address
     */
    function getOperationalKey(address _proposer) external view returns (address) {
        return _proposers[_proposer].operationalKey;
    }

    /**
     * @notice Receive function to accept ETH.
     */
    receive() external payable {}
}
