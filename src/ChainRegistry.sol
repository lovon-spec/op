// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainRegistry} from "./interfaces/IChainRegistry.sol";
import {IArbitrator} from "./interfaces/IArbitrator.sol";
import {IArbitrable} from "./interfaces/IArbitrable.sol";

/**
 * @title IEvidence
 * @notice ERC-1497 Evidence Standard interface.
 */
interface IEvidence {
    event Evidence(
        IArbitrator indexed _arbitrator,
        uint256 indexed _evidenceGroupID,
        address indexed _party,
        string _evidence
    );
}

/**
 * @title ChainRegistry
 * @notice A GeneralizedTCR for L2 chains seeking integration into ISOCHRON.
 * @dev This contract implements a standard Token Curated Registry pattern where:
 *      - Chains apply for registration with a deposit
 *      - Community can challenge invalid applications during the challenge period
 *      - Disputes are resolved via configurable arbitration (Kleros Court default)
 *      - Deposits are returned to successful registrants (unlike PermanentGTCR)
 *
 *      This registry serves as the decentralized onboarding mechanism for ISOCHRON.
 *      Once a chain is Registered here, the Hub governance can call connectChain()
 *      to add it to the active sequencer rotation.
 *
 *      Key differences from PermanentGTCR (used for operators):
 *      - Standard TCR: deposits returned after successful registration
 *      - No perpetual stake requirement
 *      - Focused on chain metadata validation, not ongoing operational compliance
 *
 *      Integration Flow:
 *      1. Chain team deploys their rollup with a configuration contract
 *      2. Chain team calls addChain() with deposit and metadata
 *      3. After challenge period (or winning dispute), chain is Registered
 *      4. Hub governance reviews and calls SharedSequencerHub.connectChain()
 *      5. Chain is now part of ISOCHRON with atomic rotation
 *
 * @custom:security-contact security@isochron.network
 */
contract ChainRegistry is IChainRegistry, IArbitrable, IEvidence {
    // ============ Constants ============

    /// @notice Number of ruling options for the arbitrator
    uint256 public constant NUM_RULING_OPTIONS = 2;

    /// @notice Multiplier divisor for stake calculations
    uint256 public constant MULTIPLIER_DIVISOR = 10000;

    // ============ State Variables ============

    /// @notice Governance address that can update parameters
    address public governor;

    /// @notice The default arbitrator contract (Kleros Court today)
    IArbitrator public arbitrator;

    /// @notice Extra data for the arbitrator (court selection, etc.)
    bytes public arbitratorExtraData;

    /// @notice Required deposit for submissions
    uint256 public override requiredDeposit;

    /// @notice Challenge period duration in seconds
    uint256 public override challengePeriod;

    /// @notice Stake multiplier for challengers (in basis points)
    /// @dev Used to calculate required challenger deposit
    uint256 public challengerStakeMultiplier;

    /// @notice Stake multiplier for winners (in basis points)
    /// @dev Reserved for future reward distribution. Currently unused but part of standard TCR pattern.
    uint256 public winnerStakeMultiplier;

    /// @notice Stake multiplier for losers (in basis points)
    /// @dev Reserved for future reward distribution. Currently unused but part of standard TCR pattern.
    uint256 public loserStakeMultiplier;

    /// @notice Mapping from item ID to Item
    mapping(bytes32 => Item) internal _items;

    /// @notice Mapping from item ID to request index to Request
    mapping(bytes32 => mapping(uint256 => Request)) internal _requests;

    /// @notice Mapping from dispute ID to item ID
    mapping(uint256 => bytes32) public disputeIDToItemId;

    /// @notice Mapping from dispute ID to request index
    mapping(uint256 => uint256) public disputeIDToRequestIndex;

    /// @notice Array of all registered chain IDs (for enumeration)
    uint256[] internal _registeredChainIds;

    /// @notice Mapping from chain ID to index in _registeredChainIds (1-indexed)
    mapping(uint256 => uint256) internal _chainIdToIndex;

    // ============ Modifiers ============

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotSubmitter();
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != address(arbitrator)) revert NotArbitrator();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initializes the Chain Registry.
     * @param _governor The governance address
     * @param _arbitrator The default arbitrator contract (Kleros Court today)
     * @param _arbitratorExtraData Extra data for court selection
     * @param _requiredDeposit Required deposit for submissions
     * @param _challengePeriod Challenge period in seconds
     * @param _stakeMultipliers [challenger, winner, loser] multipliers in basis points
     */
    constructor(
        address _governor,
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _requiredDeposit,
        uint256 _challengePeriod,
        uint256[3] memory _stakeMultipliers
    ) {
        governor = _governor;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        requiredDeposit = _requiredDeposit;
        challengePeriod = _challengePeriod;
        challengerStakeMultiplier = _stakeMultipliers[0];
        winnerStakeMultiplier = _stakeMultipliers[1];
        loserStakeMultiplier = _stakeMultipliers[2];
    }

    // ============ View Functions ============

    /// @inheritdoc IChainRegistry
    function getItemId(uint256 _chainId) public pure override returns (bytes32) {
        return keccak256(abi.encode(_chainId));
    }

    /// @inheritdoc IChainRegistry
    function getItem(bytes32 _itemId) external view override returns (Item memory) {
        return _items[_itemId];
    }

    /// @inheritdoc IChainRegistry
    function getItemByChainId(uint256 _chainId) external view override returns (Item memory) {
        return _items[getItemId(_chainId)];
    }

    /// @inheritdoc IChainRegistry
    function getRequest(bytes32 _itemId, uint256 _requestIndex) external view override returns (Request memory) {
        return _requests[_itemId][_requestIndex];
    }

    /// @inheritdoc IChainRegistry
    function isRegistered(uint256 _chainId) external view override returns (bool) {
        bytes32 itemId = getItemId(_chainId);
        return _items[itemId].status == Status.Registered;
    }

    /// @inheritdoc IChainRegistry
    function getRegisteredChains() external view override returns (uint256[] memory) {
        return _registeredChainIds;
    }

    /**
     * @notice Returns the number of registered chains.
     * @return The count of registered chains
     */
    function registeredChainCount() external view returns (uint256) {
        return _registeredChainIds.length;
    }

    // ============ Registration Functions ============

    /// @inheritdoc IChainRegistry
    function addChain(
        uint256 _chainId,
        address _rollupConfig,
        address _adapter,
        string calldata _name,
        string calldata _metadataURI
    ) external payable override returns (bytes32 itemId) {
        if (_chainId == 0) revert InvalidChainId();
        if (_rollupConfig == address(0)) revert InvalidRollupConfig();
        if (_adapter == address(0)) revert InvalidAdapter();

        itemId = getItemId(_chainId);
        Item storage item = _items[itemId];

        // Check item doesn't already exist
        if (item.status != Status.Absent) revert ItemAlreadyExists();

        // Calculate required deposit (base + arbitration cost)
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        uint256 totalRequired = requiredDeposit + arbitrationCost;

        if (msg.value < totalRequired) revert InsufficientDeposit();

        // Create the item
        item.status = Status.RegistrationRequested;
        item.data = ChainData({
            chainId: _chainId,
            rollupConfig: _rollupConfig,
            adapter: _adapter,
            name: _name,
            metadataURI: _metadataURI
        });
        item.submitter = msg.sender;
        item.submissionTime = block.timestamp;
        item.requestCount = 1;

        // Create the first request
        Request storage request = _requests[itemId][0];
        request.submissionTime = block.timestamp;
        request.requester = payable(msg.sender);
        request.arbitrator = arbitrator;
        request.arbitratorExtraData = arbitratorExtraData;
        request.deposit = msg.value;

        emit ChainSubmitted(
            itemId,
            _chainId,
            msg.sender,
            _rollupConfig,
            _adapter,
            _name
        );

        // Refund excess
        if (msg.value > totalRequired) {
            _sendValue(payable(msg.sender), msg.value - totalRequired);
        }

        return itemId;
    }

    /// @inheritdoc IChainRegistry
    function removeChain(uint256 _chainId) external payable override {
        bytes32 itemId = getItemId(_chainId);
        Item storage item = _items[itemId];

        if (item.status != Status.Registered) revert InvalidStatus();

        // Calculate required deposit
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        uint256 totalRequired = requiredDeposit + arbitrationCost;

        if (msg.value < totalRequired) revert InsufficientDeposit();

        // Update status
        item.status = Status.ClearingRequested;
        uint256 requestIndex = item.requestCount;
        item.requestCount++;

        // Create the removal request
        Request storage request = _requests[itemId][requestIndex];
        request.submissionTime = block.timestamp;
        request.requester = payable(msg.sender);
        request.arbitrator = arbitrator;
        request.arbitratorExtraData = arbitratorExtraData;
        request.deposit = msg.value;

        emit ChainRemovalRequested(itemId, _chainId, msg.sender);

        // Refund excess
        if (msg.value > totalRequired) {
            _sendValue(payable(msg.sender), msg.value - totalRequired);
        }
    }

    /// @inheritdoc IChainRegistry
    function challengeRequest(bytes32 _itemId, string calldata _evidence) external payable override {
        Item storage item = _items[_itemId];

        // Can only challenge pending requests
        if (item.status != Status.RegistrationRequested &&
            item.status != Status.ClearingRequested) {
            revert InvalidStatus();
        }

        uint256 requestIndex = item.requestCount - 1;
        Request storage request = _requests[_itemId][requestIndex];

        if (request.disputed) revert AlreadyDisputed();

        // Calculate required deposit (challenger stake)
        uint256 arbitrationCost = request.arbitrator.arbitrationCost(request.arbitratorExtraData);
        uint256 challengerStake = (requiredDeposit * challengerStakeMultiplier) / MULTIPLIER_DIVISOR;
        uint256 totalRequired = arbitrationCost + challengerStake;

        if (msg.value < totalRequired) revert InsufficientDeposit();

        // Create dispute
        uint256 disputeID = request.arbitrator.createDispute{value: arbitrationCost}(
            NUM_RULING_OPTIONS,
            request.arbitratorExtraData
        );

        // Update request
        request.disputed = true;
        request.disputeID = disputeID;
        request.challenger = payable(msg.sender);
        // Only add the challenger stake to deposit (arbitration cost was already sent to arbitrator)
        request.deposit += (msg.value - arbitrationCost);

        // Store mapping for ruling callback
        disputeIDToItemId[disputeID] = _itemId;
        disputeIDToRequestIndex[disputeID] = requestIndex;

        emit RequestChallenged(_itemId, requestIndex, msg.sender, disputeID);

        // Emit evidence if provided
        if (bytes(_evidence).length > 0) {
            emit Evidence(request.arbitrator, disputeID, msg.sender, _evidence);
        }

        // Refund excess
        if (msg.value > totalRequired) {
            _sendValue(payable(msg.sender), msg.value - totalRequired);
        }
    }

    /// @inheritdoc IChainRegistry
    function executeRequest(bytes32 _itemId) external override {
        Item storage item = _items[_itemId];
        uint256 requestIndex = item.requestCount - 1;
        Request storage request = _requests[_itemId][requestIndex];

        if (request.disputed) revert AlreadyDisputed();
        if (request.resolved) revert AlreadyResolved();

        // Check challenge period has passed
        if (block.timestamp < request.submissionTime + challengePeriod) {
            revert ChallengePeriodNotPassed();
        }

        // Execute the request
        request.resolved = true;
        Status oldStatus = item.status;

        if (oldStatus == Status.RegistrationRequested) {
            // Registration successful
            item.status = Status.Registered;
            _addToRegisteredChains(item.data.chainId);

            // Return deposit to requester
            _sendValue(request.requester, request.deposit);
        } else if (oldStatus == Status.ClearingRequested) {
            // Removal successful
            item.status = Status.Absent;
            _removeFromRegisteredChains(item.data.chainId);

            // Return deposit to requester
            _sendValue(request.requester, request.deposit);
        }

        emit ChainStatusChanged(_itemId, item.data.chainId, item.status);
    }

    // ============ Arbitrable Interface ============

    /**
     * @notice Called by the arbitrator to give a ruling.
     * @param _disputeID The dispute ID
     * @param _ruling The ruling (0 = refuse, 1 = requester wins, 2 = challenger wins)
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator {
        if (_ruling > NUM_RULING_OPTIONS) revert InvalidRuling();

        bytes32 itemId = disputeIDToItemId[_disputeID];
        uint256 requestIndex = disputeIDToRequestIndex[_disputeID];

        Item storage item = _items[itemId];
        Request storage request = _requests[itemId][requestIndex];

        if (request.resolved) revert AlreadyResolved();
        if (!request.disputed) revert NotDisputed();

        request.resolved = true;
        request.ruling = Party(_ruling);

        // Process ruling
        if (_ruling == uint256(Party.Requester) || _ruling == uint256(Party.None)) {
            // Requester wins (or refuse to rule - defaults to requester)
            if (item.status == Status.RegistrationRequested) {
                item.status = Status.Registered;
                _addToRegisteredChains(item.data.chainId);
            } else if (item.status == Status.ClearingRequested) {
                item.status = Status.Absent;
                _removeFromRegisteredChains(item.data.chainId);
            }

            // Requester gets their deposit + challenger stake
            _sendValue(request.requester, request.deposit);
        } else {
            // Challenger wins
            if (item.status == Status.RegistrationRequested) {
                item.status = Status.Absent;
            } else if (item.status == Status.ClearingRequested) {
                item.status = Status.Registered;
            }

            // Challenger gets the deposits
            _sendValue(request.challenger, request.deposit);
        }

        emit DisputeResolved(itemId, requestIndex, request.ruling);
        emit ChainStatusChanged(itemId, item.data.chainId, item.status);
        emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);
    }

    // ============ Governance Functions ============

    /// @inheritdoc IChainRegistry
    function setRequiredDeposit(uint256 _newDeposit) external override onlyGovernor {
        requiredDeposit = _newDeposit;
    }

    /// @inheritdoc IChainRegistry
    function setChallengePeriod(uint256 _newPeriod) external override onlyGovernor {
        challengePeriod = _newPeriod;
    }

    /// @inheritdoc IChainRegistry
    function setArbitrator(IArbitrator _arbitrator, bytes calldata _arbitratorExtraData) external override onlyGovernor {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /**
     * @notice Updates the stake multipliers.
     * @param _challenger Challenger stake multiplier (basis points)
     * @param _winner Winner stake multiplier (basis points)
     * @param _loser Loser stake multiplier (basis points)
     */
    function setStakeMultipliers(
        uint256 _challenger,
        uint256 _winner,
        uint256 _loser
    ) external onlyGovernor {
        challengerStakeMultiplier = _challenger;
        winnerStakeMultiplier = _winner;
        loserStakeMultiplier = _loser;
    }

    /**
     * @notice Transfers governance to a new address.
     * @param _newGovernor The new governor address
     */
    function transferGovernance(address _newGovernor) external onlyGovernor {
        governor = _newGovernor;
    }

    // ============ Internal Functions ============

    /**
     * @dev Adds a chain ID to the registered chains array.
     */
    function _addToRegisteredChains(uint256 _chainId) internal {
        if (_chainIdToIndex[_chainId] == 0) {
            _registeredChainIds.push(_chainId);
            _chainIdToIndex[_chainId] = _registeredChainIds.length;
        }
    }

    /**
     * @dev Removes a chain ID from the registered chains array.
     */
    function _removeFromRegisteredChains(uint256 _chainId) internal {
        uint256 index = _chainIdToIndex[_chainId];
        if (index != 0) {
            uint256 arrayIndex = index - 1;
            uint256 lastIndex = _registeredChainIds.length - 1;

            if (arrayIndex != lastIndex) {
                uint256 lastChainId = _registeredChainIds[lastIndex];
                _registeredChainIds[arrayIndex] = lastChainId;
                _chainIdToIndex[lastChainId] = index;
            }

            _registeredChainIds.pop();
            delete _chainIdToIndex[_chainId];
        }
    }

    /**
     * @dev Sends ETH to an address.
     */
    function _sendValue(address payable _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Allows the contract to receive ETH.
     */
    receive() external payable {}
}
