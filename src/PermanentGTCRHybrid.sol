// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IArbitrator} from "./interfaces/IArbitrator.sol";
import {IPermanentGTCRHybrid} from "./interfaces/IPermanentGTCRHybrid.sol";

/**
 * @title PermanentGTCRHybrid
 * @notice Hybrid PermanentGTCR with parallel on-chain operational keys storage.
 * @dev Implements standard PGTCR logic for Kleros UI compatibility, plus:
 *      - Parallel `itemKeys` mapping for operational keys (batcher/signer)
 *      - Keys default to owner if not explicitly set
 *      - "Cold Staker / Hot Operator" model support
 *
 * This is designed for the Constitutional L2 use case where:
 * - Staker registers item via curate.kleros.io (standard flow)
 * - Staker can optionally set different operational keys
 * - Sequencer Manager reads keys on-chain (no IPFS)
 *
 * Differences from standard PGTCR:
 * - Adds `itemKeys` mapping for operational keys
 * - Adds `setOperationalKeys()` function for staker to update keys
 * - Adds `getOperationalKeys()` view that defaults to owner
 *
 * @custom:security-contact security@example.com
 */
contract PermanentGTCRHybrid is IPermanentGTCRHybrid {
    // ============ Errors ============

    error InvalidDeposit();
    error ItemAlreadyExists();
    error ItemDoesNotExist();
    error ItemNotChallengeable();
    error RequestNotExecutable();
    error InvalidChallenger();
    error OnlySubmitter();
    error InvalidKeys();
    error DisputeNotResolved();
    error OnlyArbitrator();
    error InvalidRuling();
    error TransferFailed();
    error OnlyGovernor();

    // ============ Structs ============

    /// @notice Represents an item in the registry.
    struct Item {
        Status status;
        uint128 arbitrationDeposit;
        uint120 challengeCount;
        address payable submitter;
        uint48 includedAt;
        uint48 withdrawingTimestamp;
        uint256 stake;
    }

    /// @notice Represents operational keys for an item.
    struct OperatorKeys {
        address batcher;
        address unsafeSigner;
    }

    /// @notice Represents a dispute for an item.
    struct Dispute {
        bytes32 itemID;
        address payable challenger;
        uint256 challengerDeposit;
    }

    // ============ Constants ============

    /// @notice Number of ruling options (Refuse to rule, Accept, Reject).
    uint256 public constant NUM_RULING_OPTIONS = 2;

    /// @notice Ruling: Refuse to arbitrate.
    uint256 public constant RULING_REFUSE = 0;

    /// @notice Ruling: Accept the item (submitter wins).
    uint256 public constant RULING_ACCEPT = 1;

    /// @notice Ruling: Reject the item (challenger wins).
    uint256 public constant RULING_REJECT = 2;

    // ============ Immutables ============

    /// @notice The Kleros arbitrator contract.
    IArbitrator public immutable override arbitrator;

    /// @notice Extra data for arbitrator (court ID, jurors).
    bytes public override arbitratorExtraData;

    // ============ State ============

    /// @notice Minimum deposit required for submission.
    uint256 public override submissionMinDeposit;

    /// @notice Challenge period duration in seconds.
    uint256 public override challengePeriodDuration;

    /// @notice Governor address (can update parameters).
    address public override governor;

    /// @notice Mapping from item ID to item data.
    mapping(bytes32 => Item) private _items;

    /// @notice Mapping from item ID to operational keys (HYBRID EXTENSION).
    mapping(bytes32 => OperatorKeys) public itemKeys;

    /// @notice Mapping from dispute ID to dispute data.
    mapping(uint256 => Dispute) public disputes;

    /// @notice Stake multipliers in basis points.
    /// @dev [sharedStakeMultiplier, winnerStakeMultiplier, loserStakeMultiplier]
    uint256[3] public stakeMultipliers;

    // ============ Constructor ============

    /**
     * @notice Initializes the PermanentGTCRHybrid registry.
     * @param _arbitrator The Kleros arbitrator address.
     * @param _arbitratorExtraData Extra data for the arbitrator (court ID, jurors).
     * @param _governor The governor address.
     * @param _submissionMinDeposit Minimum deposit for submissions.
     * @param _challengePeriodDuration Challenge period in seconds.
     * @param _stakeMultipliers Stake multipliers [shared, winner, loser] in basis points.
     */
    constructor(
        address _arbitrator,
        bytes memory _arbitratorExtraData,
        address _governor,
        uint256 _submissionMinDeposit,
        uint256 _challengePeriodDuration,
        uint256[3] memory _stakeMultipliers
    ) {
        arbitrator = IArbitrator(_arbitrator);
        arbitratorExtraData = _arbitratorExtraData;
        governor = _governor;
        submissionMinDeposit = _submissionMinDeposit;
        challengePeriodDuration = _challengePeriodDuration;
        stakeMultipliers = _stakeMultipliers;
    }

    // ============ Modifiers ============

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor();
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != address(arbitrator)) revert OnlyArbitrator();
        _;
    }

    // ============ View Functions ============

    /**
     * @notice Gets the full item data.
     * @param _itemID The ID of the item.
     */
    function items(bytes32 _itemID) external view override returns (
        Status status,
        uint128 arbitrationDeposit,
        uint120 challengeCount,
        address payable submitter,
        uint48 includedAt,
        uint48 withdrawingTimestamp,
        uint256 stake
    ) {
        Item storage item = _items[_itemID];
        return (
            item.status,
            item.arbitrationDeposit,
            item.challengeCount,
            item.submitter,
            item.includedAt,
            item.withdrawingTimestamp,
            item.stake
        );
    }

    /**
     * @notice Gets the operational keys for an item.
     * @dev Returns the submitter address for both if keys not explicitly set.
     * @param _itemID The ID of the item.
     * @return batcher The batcher address.
     * @return unsafeSigner The unsafe block signer address.
     */
    function getOperationalKeys(bytes32 _itemID) public view override returns (
        address batcher,
        address unsafeSigner
    ) {
        Item storage item = _items[_itemID];
        OperatorKeys storage keys = itemKeys[_itemID];

        // If keys are set, return them; otherwise default to submitter
        if (keys.batcher != address(0)) {
            return (keys.batcher, keys.unsafeSigner);
        } else {
            return (item.submitter, item.submitter);
        }
    }

    /**
     * @notice Checks if an item is in a "registered" state (can operate).
     * @param _itemID The ID of the item.
     * @return True if the item is Submitted or Reincluded (not disputed).
     */
    function isRegistered(bytes32 _itemID) public view returns (bool) {
        Status status = _items[_itemID].status;
        return status == Status.Submitted || status == Status.Reincluded;
    }

    // ============ Submission Functions ============

    /**
     * @notice Submits an item to the registry.
     * @param _data The item data (typically IPFS URI for Kleros UI).
     * @param _deposit The deposit amount (ignored, uses msg.value).
     * @return itemID The ID of the submitted item.
     */
    function addItem(string calldata _data, uint256 _deposit) external payable override returns (bytes32 itemID) {
        // Silence unused parameter warning
        _deposit;

        if (msg.value < submissionMinDeposit) revert InvalidDeposit();

        // Generate item ID from data
        itemID = keccak256(abi.encodePacked(_data));

        Item storage item = _items[itemID];
        if (item.status != Status.Absent) revert ItemAlreadyExists();

        // Store item
        item.status = Status.Submitted;
        item.submitter = payable(msg.sender);
        item.stake = msg.value;
        item.includedAt = uint48(block.timestamp);

        emit ItemSubmitted(itemID, msg.sender, _data, msg.value);
        emit ItemStatusChange(itemID, Status.Submitted);

        return itemID;
    }

    /**
     * @notice Alternative submission that also sets operational keys.
     * @param _data The item data.
     * @param _batcher The batcher address.
     * @param _signer The unsafe block signer address.
     * @return itemID The ID of the submitted item.
     */
    function addItemWithKeys(
        string calldata _data,
        address _batcher,
        address _signer
    ) external payable returns (bytes32 itemID) {
        if (_batcher == address(0) || _signer == address(0)) revert InvalidKeys();

        itemID = addItem(_data, msg.value);

        // Set operational keys
        itemKeys[itemID] = OperatorKeys(_batcher, _signer);
        emit OperationalKeysUpdated(itemID, _batcher, _signer);

        return itemID;
    }

    // ============ Challenge Functions ============

    /**
     * @notice Challenges an item.
     * @param _itemID The ID of the item to challenge.
     * @return disputeID The ID of the created dispute.
     */
    function challengeItem(bytes32 _itemID) external payable override returns (uint256 disputeID) {
        Item storage item = _items[_itemID];

        // Can only challenge Submitted or Reincluded items
        if (item.status != Status.Submitted && item.status != Status.Reincluded) {
            revert ItemNotChallengeable();
        }

        // Check challenge period hasn't expired
        if (block.timestamp > item.includedAt + challengePeriodDuration) {
            revert ItemNotChallengeable();
        }

        // Cannot challenge your own item
        if (msg.sender == item.submitter) revert InvalidChallenger();

        // Calculate required deposit
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        uint256 requiredDeposit = arbitrationCost + (item.stake * stakeMultipliers[2]) / 10000;
        if (msg.value < requiredDeposit) revert InvalidDeposit();

        // Create dispute
        disputeID = arbitrator.createDispute{value: arbitrationCost}(
            NUM_RULING_OPTIONS,
            arbitratorExtraData
        );

        // Update item status
        item.status = Status.Disputed;
        item.arbitrationDeposit = uint128(arbitrationCost);
        item.challengeCount++;

        // Store dispute info
        disputes[disputeID] = Dispute({
            itemID: _itemID,
            challenger: payable(msg.sender),
            challengerDeposit: msg.value
        });

        emit ItemChallenged(_itemID, msg.sender, disputeID);
        emit ItemStatusChange(_itemID, Status.Disputed);

        return disputeID;
    }

    // ============ Execution Functions ============

    /**
     * @notice Executes a pending request after the challenge period.
     * @param _itemID The ID of the item.
     */
    function executeRequest(bytes32 _itemID) external override {
        Item storage item = _items[_itemID];

        // Must be in Submitted status (not disputed)
        if (item.status != Status.Submitted) revert RequestNotExecutable();

        // Challenge period must have passed
        if (block.timestamp <= item.includedAt + challengePeriodDuration) {
            revert RequestNotExecutable();
        }

        // Mark as Reincluded (permanently registered)
        item.status = Status.Reincluded;
        emit ItemStatusChange(_itemID, Status.Reincluded);

        // Return stake to submitter
        _sendValue(item.submitter, item.stake);
    }

    // ============ Arbitration Functions ============

    /**
     * @notice Called by the arbitrator to give a ruling.
     * @param _disputeID The ID of the dispute.
     * @param _ruling The ruling (0=refuse, 1=accept, 2=reject).
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator {
        if (_ruling > NUM_RULING_OPTIONS) revert InvalidRuling();

        Dispute storage dispute = disputes[_disputeID];
        bytes32 itemID = dispute.itemID;
        Item storage item = _items[itemID];

        if (item.status != Status.Disputed) revert DisputeNotResolved();

        emit Ruling(arbitrator, _disputeID, _ruling);

        if (_ruling == RULING_ACCEPT || _ruling == RULING_REFUSE) {
            // Submitter wins (or refuse to rule, default to submitter)
            item.status = Status.Reincluded;

            // Return stake to submitter + challenger deposit
            uint256 totalReward = item.stake + dispute.challengerDeposit - item.arbitrationDeposit;
            _sendValue(item.submitter, totalReward);
        } else {
            // Challenger wins (RULING_REJECT)
            item.status = Status.Absent;

            // Clear operational keys
            delete itemKeys[itemID];

            // Return challenger deposit + submitter stake
            uint256 totalReward = item.stake + dispute.challengerDeposit - item.arbitrationDeposit;
            _sendValue(dispute.challenger, totalReward);
        }

        emit ItemStatusChange(itemID, item.status);

        // Clean up
        delete disputes[_disputeID];
    }

    // ============ Hybrid Extension Functions ============

    /**
     * @notice Sets the operational keys for an item.
     * @dev Only the item submitter (stake owner) can call this.
     * @param _itemID The ID of the item.
     * @param _batcher The batcher address.
     * @param _signer The unsafe block signer address.
     */
    function setOperationalKeys(
        bytes32 _itemID,
        address _batcher,
        address _signer
    ) external override {
        Item storage item = _items[_itemID];

        // Only submitter can update keys
        if (msg.sender != item.submitter) revert OnlySubmitter();

        // Item must exist
        if (item.status == Status.Absent) revert ItemDoesNotExist();

        // Keys must be valid
        if (_batcher == address(0) || _signer == address(0)) revert InvalidKeys();

        itemKeys[_itemID] = OperatorKeys(_batcher, _signer);
        emit OperationalKeysUpdated(_itemID, _batcher, _signer);
    }

    // ============ Governor Functions ============

    /**
     * @notice Updates the minimum submission deposit.
     * @param _submissionMinDeposit The new minimum deposit.
     */
    function setSubmissionMinDeposit(uint256 _submissionMinDeposit) external onlyGovernor {
        submissionMinDeposit = _submissionMinDeposit;
    }

    /**
     * @notice Updates the challenge period duration.
     * @param _challengePeriodDuration The new duration in seconds.
     */
    function setChallengePeriodDuration(uint256 _challengePeriodDuration) external onlyGovernor {
        challengePeriodDuration = _challengePeriodDuration;
    }

    /**
     * @notice Transfers governor role.
     * @param _governor The new governor address.
     */
    function setGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    // ============ Internal Functions ============

    /**
     * @notice Safely sends ETH to an address.
     * @param _to The recipient address.
     * @param _amount The amount to send.
     */
    function _sendValue(address payable _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) revert TransferFailed();
    }
}
