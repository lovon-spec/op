// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IArbitrator} from "./interfaces/IArbitrator.sol";
import {IArbitrable} from "./interfaces/IArbitrable.sol";

/**
 * @title IERC20
 * @notice Minimal ERC20 interface for token deposits.
 */
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

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
 * @title IWETH
 * @notice Wrapped native token interface.
 */
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
}

/**
 * @title PermanentGTCRHybrid
 * @notice A Kleros PermanentGTCR with on-chain operational keys and "Challengeable Forever" semantics.
 * @dev This contract is based on the original Kleros PermanentGTCR:
 *      https://github.com/kleros/pgtcr/blob/master/contracts/src/PermanentGTCR.sol
 *
 *      MODIFICATIONS from original PGTCR:
 *
 *      1. Hybrid Extension (on-chain operational keys):
 *         - `itemKeys` mapping for on-chain operational keys (batcher/signer)
 *         - `setOperationalKeys()` function for item owners to set keys
 *         - `getOperationalKeys()` view function (defaults to submitter if unset)
 *         - `OperationalKeysUpdated` event
 *
 *      2. "Challengeable Forever" (NO IMMUNITY):
 *         - Original PGTCR: Items become unchallengeable after their period
 *         - This version: ALL items (Submitted and Reincluded) can be challenged AT ANY TIME
 *         - There is NO "safe harbor" after any period
 *         - Reason: Constitutional L2 requires ongoing enforcement of policies
 *           (censorship, MEV, liveness violations can occur at any time)
 *         - Exception: Items that have completed their withdrawal period are not challengeable
 *
 *      3. Maturity Requirement for Activation:
 *         - Items must wait for their challenge period before being valid for sync:
 *           - Submitted items: must wait for submissionPeriod
 *           - Reincluded items: must wait for reinclusionPeriod (after winning dispute)
 *         - This ensures adequate time for challenges before activation
 *
 *      Item Status Flow:
 *      - Submitted: New item, challengeable FOREVER, valid for sync after submissionPeriod
 *      - After submissionPeriod: Call executeRequest() to become Reincluded
 *      - Reincluded: Active license, challengeable FOREVER, valid for sync after reinclusionPeriod
 *      - Disputed: Under arbitration
 *      - Absent: Removed or never existed
 *
 * Trust assumptions (from original):
 * - Arbitrator is trusted to rule correctly.
 * - Governor is trusted to not spam arbitration setting updates.
 * - Token is trusted to not revert on valid transfers.
 */
contract PermanentGTCRHybrid is IArbitrable, IEvidence {
    // ============ Enums ============

    enum Status {
        Absent,     // Item does not exist
        Submitted,  // Item submitted, in challenge period
        Reincluded, // Item permanently included
        Disputed    // Item under dispute
    }

    enum Party {
        None,
        Submitter,
        Challenger
    }

    // ============ Structs ============

    struct Item {
        Status status;
        uint128 arbitrationDeposit;
        uint120 challengeCount;
        address payable submitter;
        uint48 includedAt;
        uint48 withdrawingTimestamp;
        uint256 stake;
    }

    struct Challenge {
        uint32 arbitrationParamsIndex;
        uint32 roundCount;
        Party ruling;
        address payable challenger;
        uint256 stake;
        uint256 disputeID;
    }

    struct Round {
        Party sideFunded;
        uint256 feeRewards;
        uint256[3] amountPaid;
    }

    struct ArbitrationParams {
        uint64 timestamp;
        bytes arbitratorExtraData;
    }

    // === HYBRID EXTENSION ===
    struct OperatorKeys {
        address batcher;
        address unsafeSigner;
    }

    // ============ Constants ============

    uint256 public constant MULTIPLIER_DIVISOR = 10000;
    uint256 public constant NUM_RULING_OPTIONS = 2;

    // ============ Immutables ============

    /// @notice Wrapped native token (e.g., WETH)
    address public immutable W_NATIVE;

    // ============ State ============

    bool private initialized;
    address public governor;
    IERC20 public token;

    uint256 public submissionMinDeposit;
    uint256 public submissionPeriod;
    uint256 public reinclusionPeriod;
    uint256 public withdrawingPeriod;
    uint256 public arbitrationParamsCooldown;

    uint256 public challengeStakeMultiplier;
    uint256 public winnerStakeMultiplier;
    uint256 public loserStakeMultiplier;
    uint256 public sharedStakeMultiplier;

    IArbitrator public arbitrator;
    ArbitrationParams[] public arbitrationParamsChanges;

    mapping(bytes32 => Item) public items;
    mapping(bytes32 => mapping(uint256 => Challenge)) public challenges;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => Round))) public rounds;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => mapping(address => uint256[3])))) public contributions;
    mapping(uint256 => bytes32) public disputeIDToItemID;

    // === HYBRID EXTENSION ===
    mapping(bytes32 => OperatorKeys) public itemKeys;

    // ============ Events ============

    event ItemSubmitted(
        bytes32 indexed _itemID,
        address indexed _submitter,
        string _data,
        uint256 _stake
    );

    event ItemChallenged(
        bytes32 indexed _itemID,
        uint256 indexed _challengeID,
        uint256 indexed _disputeID
    );

    event ItemStatusChange(bytes32 indexed _itemID, Status _status);

    event Contribution(
        bytes32 indexed _itemID,
        uint256 indexed _challengeID,
        uint256 indexed _roundID,
        address _contributor,
        Party _side,
        uint256 _amount
    );

    event AppealPossible(bytes32 indexed _itemID, uint256 indexed _challengeID);

    event RewardWithdrawn(
        bytes32 indexed _itemID,
        uint256 indexed _challengeID,
        uint256 indexed _roundID,
        address _contributor,
        uint256 _amount
    );

    event ItemWithdrawing(bytes32 indexed _itemID, uint48 _withdrawingTimestamp);

    event ItemWithdrawn(bytes32 indexed _itemID);

    // === HYBRID EXTENSION ===
    event OperationalKeysUpdated(
        bytes32 indexed _itemID,
        address indexed _batcher,
        address indexed _signer
    );

    // ============ Errors ============

    error AlreadyInitialized();
    error NotGovernor();
    error InvalidDeposit();
    error ItemAlreadyExists();
    error ItemDoesNotExist();
    error ItemNotChallengeable();
    error InvalidStatus();
    error ChallengeNotAppealable();
    error AppealPeriodOver();
    error SideAlreadyFunded();
    error LoserMustContributeFirst();
    error NotArbitrator();
    error InvalidRuling();
    error InvalidChallenge();
    error NotSubmitter();
    error NotWithdrawable();
    error WithdrawalPeriodNotOver();
    error TransferFailed();
    error InvalidKeys();
    error CooldownNotPassed();

    // ============ Modifiers ============

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != address(arbitrator)) revert NotArbitrator();
        _;
    }

    // ============ Constructor ============

    constructor(address _wNative) {
        W_NATIVE = _wNative;
    }

    // ============ Initialization ============

    /**
     * @notice Initializes the registry (upgradeable pattern).
     * @param _governor The governor address.
     * @param _arbitrator The arbitrator contract.
     * @param _arbitratorExtraData Extra data for the arbitrator.
     * @param _token The ERC20 token for deposits (address(0) for native).
     * @param _submissionMinDeposit Minimum deposit for submissions.
     * @param _submissionPeriod Challenge period for new submissions.
     * @param _reinclusionPeriod Challenge period for reinclusions.
     * @param _withdrawingPeriod Period to wait before withdrawing.
     * @param _stakeMultipliers [challenge, winner, loser, shared] in basis points.
     * @param _arbitrationParamsCooldown Cooldown between arbitration param changes.
     */
    function initialize(
        address _governor,
        IArbitrator _arbitrator,
        bytes calldata _arbitratorExtraData,
        IERC20 _token,
        uint256 _submissionMinDeposit,
        uint256 _submissionPeriod,
        uint256 _reinclusionPeriod,
        uint256 _withdrawingPeriod,
        uint256[4] calldata _stakeMultipliers,
        uint256 _arbitrationParamsCooldown
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        governor = _governor;
        arbitrator = _arbitrator;
        token = _token;
        submissionMinDeposit = _submissionMinDeposit;
        submissionPeriod = _submissionPeriod;
        reinclusionPeriod = _reinclusionPeriod;
        withdrawingPeriod = _withdrawingPeriod;
        challengeStakeMultiplier = _stakeMultipliers[0];
        winnerStakeMultiplier = _stakeMultipliers[1];
        loserStakeMultiplier = _stakeMultipliers[2];
        sharedStakeMultiplier = _stakeMultipliers[3];
        arbitrationParamsCooldown = _arbitrationParamsCooldown;

        arbitrationParamsChanges.push(
            ArbitrationParams({
                timestamp: uint64(block.timestamp),
                arbitratorExtraData: _arbitratorExtraData
            })
        );
    }

    // ============ Item Submission ============

    /**
     * @notice Submits an item to the registry.
     * @param _data The item data (IPFS URI for Kleros UI).
     */
    function addItem(string calldata _data) external payable {
        bytes32 itemID = keccak256(abi.encodePacked(_data));
        Item storage item = items[itemID];

        if (item.status != Status.Absent) revert ItemAlreadyExists();

        uint256 stake = _processDeposit(submissionMinDeposit);

        item.status = Status.Submitted;
        item.submitter = payable(msg.sender);
        item.stake = stake;
        item.includedAt = uint48(block.timestamp);

        emit ItemSubmitted(itemID, msg.sender, _data, stake);
        emit ItemStatusChange(itemID, Status.Submitted);
    }

    /**
     * @notice Submits an item with explicit operational keys.
     * @dev Hybrid extension - sets keys at submission time.
     * @param _data The item data.
     * @param _batcher The batcher address.
     * @param _signer The unsafe block signer address.
     */
    function addItemWithKeys(
        string calldata _data,
        address _batcher,
        address _signer
    ) external payable returns (bytes32 itemID) {
        if (_batcher == address(0) || _signer == address(0)) revert InvalidKeys();

        itemID = keccak256(abi.encodePacked(_data));
        Item storage item = items[itemID];

        if (item.status != Status.Absent) revert ItemAlreadyExists();

        uint256 stake = _processDeposit(submissionMinDeposit);

        item.status = Status.Submitted;
        item.submitter = payable(msg.sender);
        item.stake = stake;
        item.includedAt = uint48(block.timestamp);

        // Set operational keys
        itemKeys[itemID] = OperatorKeys(_batcher, _signer);

        emit ItemSubmitted(itemID, msg.sender, _data, stake);
        emit ItemStatusChange(itemID, Status.Submitted);
        emit OperationalKeysUpdated(itemID, _batcher, _signer);

        return itemID;
    }

    // ============ Challenge ============

    /**
     * @notice Challenges an item.
     * @dev "CHALLENGEABLE FOREVER" - Both Submitted and Reincluded items can be
     *      challenged at ANY TIME. There is no "safe harbor" after any period.
     *
     *      This differs from the original PGTCR which made items unchallengeable after the period.
     *      The Constitutional L2 requires perpetual challengeability for policy enforcement
     *      (censorship, MEV, liveness violations can occur at any time).
     *
     *      Exception: Items that have completed their withdrawal period (withdrawingTimestamp +
     *      withdrawingPeriod elapsed) cannot be challenged - they are effectively exiting.
     *
     * @param _itemID The item ID.
     * @param _evidence Evidence URI.
     */
    function challengeItem(bytes32 _itemID, string calldata _evidence) external payable {
        Item storage item = items[_itemID];

        if (item.status != Status.Submitted && item.status != Status.Reincluded) {
            revert ItemNotChallengeable();
        }

        // Prevent challenging items that have effectively finished withdrawing
        // (withdrawal period elapsed but not yet executed)
        if (item.withdrawingTimestamp > 0 &&
            block.timestamp >= item.withdrawingTimestamp + withdrawingPeriod) {
            revert ItemNotChallengeable();
        }

        // NOTE: Both Submitted and Reincluded items are challengeable at ANY TIME.
        // This is the "Challengeable Forever" requirement for Constitutional L2.
        // There is NO "safe harbor" after any period - constitutional violations
        // (censorship, MEV, liveness) can occur at any time and must be actionable.

        ArbitrationParams storage arbParams = arbitrationParamsChanges[arbitrationParamsChanges.length - 1];
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbParams.arbitratorExtraData);

        uint256 challengerStake = (item.stake * challengeStakeMultiplier) / MULTIPLIER_DIVISOR;
        uint256 requiredDeposit = arbitrationCost + challengerStake;
        uint256 stake = _processDeposit(requiredDeposit);

        uint256 disputeID = arbitrator.createDispute{value: address(token) == address(0) ? arbitrationCost : 0}(
            NUM_RULING_OPTIONS,
            arbParams.arbitratorExtraData
        );

        uint256 challengeID = item.challengeCount;
        item.challengeCount++;
        item.status = Status.Disputed;
        // forge-lint: disable-next-line(unsafe-typecast)
        item.arbitrationDeposit = uint128(arbitrationCost);

        Challenge storage challenge = challenges[_itemID][challengeID];
        challenge.arbitrationParamsIndex = uint32(arbitrationParamsChanges.length - 1);
        challenge.challenger = payable(msg.sender);
        challenge.stake = stake - arbitrationCost;
        challenge.disputeID = disputeID;

        disputeIDToItemID[disputeID] = _itemID;

        emit ItemChallenged(_itemID, challengeID, disputeID);
        emit ItemStatusChange(_itemID, Status.Disputed);

        if (bytes(_evidence).length > 0) {
            emit Evidence(arbitrator, uint256(_itemID), msg.sender, _evidence);
        }
    }

    // ============ Appeal Funding ============

    /**
     * @notice Funds an appeal for a side.
     * @param _itemID The item ID.
     * @param _challengeID The challenge ID.
     * @param _side The side to fund.
     */
    function fundAppeal(bytes32 _itemID, uint256 _challengeID, Party _side) external payable {
        Challenge storage challenge = challenges[_itemID][_challengeID];
        if (challenge.disputeID == 0) revert InvalidChallenge();

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(challenge.disputeID);
        if (block.timestamp < appealPeriodStart || block.timestamp >= appealPeriodEnd) {
            revert AppealPeriodOver();
        }

        Party winner = Party(arbitrator.currentRuling(challenge.disputeID));
        Party loser = winner == Party.Submitter ? Party.Challenger : Party.Submitter;

        if (_side != winner && _side != loser) revert InvalidRuling();

        Round storage round = rounds[_itemID][_challengeID][challenge.roundCount];
        if (round.sideFunded == _side) revert SideAlreadyFunded();

        // Loser must contribute first in second half of appeal period
        if (_side == winner && round.sideFunded == Party.None) {
            uint256 appealPeriodMiddle = appealPeriodStart + (appealPeriodEnd - appealPeriodStart) / 2;
            if (block.timestamp < appealPeriodMiddle) revert LoserMustContributeFirst();
        }

        ArbitrationParams storage arbParams = arbitrationParamsChanges[challenge.arbitrationParamsIndex];
        uint256 appealCost = arbitrator.appealCost(challenge.disputeID, arbParams.arbitratorExtraData);

        uint256 multiplier = _side == winner ? winnerStakeMultiplier : loserStakeMultiplier;
        uint256 totalRequired = appealCost + (appealCost * multiplier) / MULTIPLIER_DIVISOR;
        uint256 alreadyPaid = round.amountPaid[uint256(_side)];
        uint256 stillRequired = totalRequired > alreadyPaid ? totalRequired - alreadyPaid : 0;

        uint256 contribution = _processDeposit(stillRequired > msg.value ? msg.value : stillRequired);

        round.amountPaid[uint256(_side)] += contribution;
        contributions[_itemID][_challengeID][challenge.roundCount][msg.sender][uint256(_side)] += contribution;

        emit Contribution(_itemID, _challengeID, challenge.roundCount, msg.sender, _side, contribution);

        if (round.amountPaid[uint256(_side)] >= totalRequired) {
            if (round.sideFunded == Party.None) {
                round.sideFunded = _side;
            } else {
                // Both sides funded - create appeal
                round.feeRewards = round.amountPaid[uint256(Party.Submitter)] + round.amountPaid[uint256(Party.Challenger)] - appealCost;

                arbitrator.appeal{value: address(token) == address(0) ? appealCost : 0}(
                    challenge.disputeID,
                    arbParams.arbitratorExtraData
                );

                challenge.roundCount++;
                round.sideFunded = Party.None;
            }
        }

        // Refund excess
        if (msg.value > contribution) {
            _sendValue(payable(msg.sender), msg.value - contribution);
        }
    }

    // ============ Ruling ============

    /**
     * @notice Gives a ruling for a dispute (called by arbitrator).
     * @param _disputeID The dispute ID.
     * @param _ruling The ruling (0=refuse, 1=submitter wins, 2=challenger wins).
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator {
        if (_ruling > NUM_RULING_OPTIONS) revert InvalidRuling();

        bytes32 itemID = disputeIDToItemID[_disputeID];
        Item storage item = items[itemID];
        if (item.status != Status.Disputed) revert InvalidStatus();

        uint256 challengeID = item.challengeCount - 1;
        Challenge storage challenge = challenges[itemID][challengeID];

        Round storage round = rounds[itemID][challengeID][challenge.roundCount];
        if (round.sideFunded == Party.Submitter) {
            challenge.ruling = Party.Submitter;
        } else if (round.sideFunded == Party.Challenger) {
            challenge.ruling = Party.Challenger;
        } else {
            challenge.ruling = Party(_ruling);
        }

        emit Ruling(arbitrator, _disputeID, uint256(challenge.ruling));

        if (challenge.ruling == Party.Challenger) {
            // Challenger wins - item removed
            item.status = Status.Absent;
            delete itemKeys[itemID]; // Clear operational keys

            uint256 totalStake = item.stake + challenge.stake;
            _sendTokens(challenge.challenger, totalStake);
        } else {
            // Submitter wins or refuse to rule
            item.status = Status.Reincluded;
            item.includedAt = uint48(block.timestamp);

            uint256 totalStake = item.stake + challenge.stake;
            _sendTokens(item.submitter, totalStake);
        }

        emit ItemStatusChange(itemID, item.status);
    }

    // ============ Execution ============

    /**
     * @notice Executes a pending submission after challenge period.
     * @param _itemID The item ID.
     */
    function executeRequest(bytes32 _itemID) external {
        Item storage item = items[_itemID];

        if (item.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp <= item.includedAt + submissionPeriod) revert WithdrawalPeriodNotOver();

        item.status = Status.Reincluded;

        // Return stake to submitter
        _sendTokens(item.submitter, item.stake);

        emit ItemStatusChange(_itemID, Status.Reincluded);
    }

    // ============ Withdrawal ============

    /**
     * @notice Requests withdrawal of an item.
     * @param _itemID The item ID.
     */
    function requestWithdrawal(bytes32 _itemID) external {
        Item storage item = items[_itemID];

        if (msg.sender != item.submitter) revert NotSubmitter();
        if (item.status != Status.Reincluded) revert InvalidStatus();

        item.withdrawingTimestamp = uint48(block.timestamp);

        emit ItemWithdrawing(_itemID, item.withdrawingTimestamp);
    }

    /**
     * @notice Completes withdrawal of an item.
     * @param _itemID The item ID.
     */
    function withdraw(bytes32 _itemID) external {
        Item storage item = items[_itemID];

        if (item.withdrawingTimestamp == 0) revert NotWithdrawable();
        if (block.timestamp < item.withdrawingTimestamp + withdrawingPeriod) {
            revert WithdrawalPeriodNotOver();
        }

        item.status = Status.Absent;
        item.withdrawingTimestamp = 0;
        delete itemKeys[_itemID];

        emit ItemWithdrawn(_itemID);
        emit ItemStatusChange(_itemID, Status.Absent);
    }

    /**
     * @notice Cancels a withdrawal request.
     * @param _itemID The item ID.
     */
    function cancelWithdrawal(bytes32 _itemID) external {
        Item storage item = items[_itemID];

        if (msg.sender != item.submitter) revert NotSubmitter();
        if (item.withdrawingTimestamp == 0) revert NotWithdrawable();

        item.withdrawingTimestamp = 0;
    }

    // ============ Reward Withdrawal ============

    /**
     * @notice Withdraws fees and rewards from a round.
     * @param _itemID The item ID.
     * @param _challengeID The challenge ID.
     * @param _roundID The round ID.
     * @param _contributor The contributor address.
     */
    function withdrawFeesAndRewards(
        bytes32 _itemID,
        uint256 _challengeID,
        uint256 _roundID,
        address payable _contributor
    ) external {
        Challenge storage challenge = challenges[_itemID][_challengeID];
        Round storage round = rounds[_itemID][_challengeID][_roundID];

        uint256 reward;
        uint256[3] storage contribs = contributions[_itemID][_challengeID][_roundID][_contributor];

        if (challenge.ruling == Party.None || _roundID == challenge.roundCount) {
            // Refund contributions if no ruling or final round
            reward = contribs[uint256(Party.Submitter)] + contribs[uint256(Party.Challenger)];
        } else if (challenge.ruling == Party.Submitter) {
            if (round.sideFunded == Party.Submitter) {
                reward = contribs[uint256(Party.Submitter)] +
                    (contribs[uint256(Party.Submitter)] * round.feeRewards) / round.amountPaid[uint256(Party.Submitter)];
            } else {
                reward = contribs[uint256(Party.Submitter)];
            }
        } else {
            if (round.sideFunded == Party.Challenger) {
                reward = contribs[uint256(Party.Challenger)] +
                    (contribs[uint256(Party.Challenger)] * round.feeRewards) / round.amountPaid[uint256(Party.Challenger)];
            } else {
                reward = contribs[uint256(Party.Challenger)];
            }
        }

        contribs[uint256(Party.Submitter)] = 0;
        contribs[uint256(Party.Challenger)] = 0;

        if (reward > 0) {
            _sendTokens(_contributor, reward);
            emit RewardWithdrawn(_itemID, _challengeID, _roundID, _contributor, reward);
        }
    }

    // ============ Hybrid Extension: Operational Keys ============

    /**
     * @notice Sets the operational keys for an item.
     * @dev Only the item submitter can call this. Keys default to submitter if unset.
     * @param _itemID The item ID.
     * @param _batcher The batcher address for L1 batch submissions.
     * @param _signer The unsafe block signer address for P2P.
     */
    function setOperationalKeys(
        bytes32 _itemID,
        address _batcher,
        address _signer
    ) external {
        Item storage item = items[_itemID];

        if (msg.sender != item.submitter) revert NotSubmitter();
        if (item.status == Status.Absent) revert ItemDoesNotExist();
        if (_batcher == address(0) || _signer == address(0)) revert InvalidKeys();

        itemKeys[_itemID] = OperatorKeys(_batcher, _signer);
        emit OperationalKeysUpdated(_itemID, _batcher, _signer);
    }

    /**
     * @notice Gets the operational keys for an item.
     * @dev Returns submitter address for both if keys not explicitly set.
     * @param _itemID The item ID.
     * @return batcher The batcher address.
     * @return unsafeSigner The unsafe block signer address.
     */
    function getOperationalKeys(bytes32 _itemID) external view returns (
        address batcher,
        address unsafeSigner
    ) {
        OperatorKeys storage keys = itemKeys[_itemID];
        Item storage item = items[_itemID];

        if (keys.batcher != address(0)) {
            return (keys.batcher, keys.unsafeSigner);
        } else {
            return (item.submitter, item.submitter);
        }
    }

    // ============ Governor Functions ============

    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    function changeSubmissionMinDeposit(uint256 _submissionMinDeposit) external onlyGovernor {
        submissionMinDeposit = _submissionMinDeposit;
    }

    function changeSubmissionPeriod(uint256 _submissionPeriod) external onlyGovernor {
        submissionPeriod = _submissionPeriod;
    }

    function changeReinclusionPeriod(uint256 _reinclusionPeriod) external onlyGovernor {
        reinclusionPeriod = _reinclusionPeriod;
    }

    function changeWithdrawingPeriod(uint256 _withdrawingPeriod) external onlyGovernor {
        withdrawingPeriod = _withdrawingPeriod;
    }

    function changeStakeMultipliers(
        uint256 _challengeStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier,
        uint256 _sharedStakeMultiplier
    ) external onlyGovernor {
        challengeStakeMultiplier = _challengeStakeMultiplier;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    function changeArbitrationParams(bytes calldata _arbitratorExtraData) external onlyGovernor {
        ArbitrationParams storage lastParams = arbitrationParamsChanges[arbitrationParamsChanges.length - 1];
        if (block.timestamp < lastParams.timestamp + arbitrationParamsCooldown) {
            revert CooldownNotPassed();
        }

        arbitrationParamsChanges.push(
            ArbitrationParams({
                timestamp: uint64(block.timestamp),
                arbitratorExtraData: _arbitratorExtraData
            })
        );
    }

    // ============ View Functions ============

    function itemCount() external pure returns (uint256) {
        // Note: Original uses itemList array, simplified here
        return 0; // Would need to track separately
    }

    function getArbitrationParamsCount() external view returns (uint256) {
        return arbitrationParamsChanges.length;
    }

    function isRegistered(bytes32 _itemID) external view returns (bool) {
        Status status = items[_itemID].status;
        return status == Status.Submitted || status == Status.Reincluded;
    }

    /**
     * @notice Checks if an item is currently challengeable.
     * @dev - Submitted items: ALWAYS challengeable (no immunity after period)
     *      - Reincluded items: ALWAYS challengeable (perpetual for policy enforcement)
     *      - Items with elapsed withdrawal period: NOT challengeable
     *      - Disputed/Absent items: NOT challengeable
     * @param _itemID The item ID.
     * @return True if the item can be challenged right now.
     */
    function isChallengeable(bytes32 _itemID) external view returns (bool) {
        Item storage item = items[_itemID];

        // Items that are withdrawing and past the period are not challengeable
        if (item.withdrawingTimestamp > 0 &&
            block.timestamp >= item.withdrawingTimestamp + withdrawingPeriod) {
            return false;
        }

        // Both Submitted and Reincluded items are challengeable forever
        if (item.status == Status.Submitted || item.status == Status.Reincluded) {
            return true;
        }

        // Disputed or Absent items are not challengeable
        return false;
    }

    /**
     * @notice Checks if an item is valid for sync to SequencerManager.
     * @dev MATURITY REQUIREMENT: Items must have been in their current status
     *      long enough to allow challenges before being activated.
     *
     *      - Submitted items: valid only AFTER submissionPeriod (passed initial review)
     *      - Reincluded items: valid only AFTER reinclusionPeriod (passed re-review)
     *      - Disputed/Absent items: never valid
     *
     * @param _itemID The item ID.
     * @return True if the item has passed its maturity period.
     */
    function isValidForSync(bytes32 _itemID) external view returns (bool) {
        Item storage item = items[_itemID];

        uint256 duration;

        if (item.status == Status.Submitted) {
            duration = submissionPeriod;
        } else if (item.status == Status.Reincluded) {
            duration = reinclusionPeriod;
        } else {
            return false;
        }

        // MATURITY CHECK: Item must be older than the required period
        return block.timestamp > item.includedAt + duration;
    }

    // ============ Internal Functions ============

    function _processDeposit(uint256 _amount) internal returns (uint256) {
        if (address(token) == address(0)) {
            // Native token
            if (msg.value < _amount) revert InvalidDeposit();
            return msg.value;
        } else {
            // ERC20 token
            uint256 balanceBefore = token.balanceOf(address(this));
            require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
            uint256 balanceAfter = token.balanceOf(address(this));
            return balanceAfter - balanceBefore;
        }
    }

    function _sendTokens(address payable _to, uint256 _amount) internal {
        if (_amount == 0) return;

        if (address(token) == address(0)) {
            _sendValue(_to, _amount);
        } else {
            require(token.transfer(_to, _amount), "Transfer failed");
        }
    }

    function _sendValue(address payable _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) revert TransferFailed();
    }

    // Allow receiving ETH
    receive() external payable {}
}
