// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IProposerRegistry
 * @notice Interface for the Proposer Registry - "The Dumb Pipe" in KSSN.
 * @dev Proposers are infrastructure providers focused solely on Liveness and
 *      rotation readiness. The registry tracks stake, liveness, and operator keys.
 *
 *      Selection mechanism: Top-N Delegated Proof of Stake (DPoS)
 *      - Gatekeeping: Top 100 staked addresses are eligible
 *      - Rebalancing: Public rebalance() function swaps low-stake active proposers
 *        with high-stake candidates
 *
 *      Liability: Strictly limited to Liveness and Registry Compliance.
 */
interface IProposerRegistry {
    // ============ Structs ============

    /**
     * @notice Proposer information.
     * @param stake The amount of ETH staked by this proposer
     * @param delegatedStake The total stake delegated to this proposer
     * @param isActive Whether this proposer is in the active set
     * @param isRegistered Whether this proposer is registered
     * @param lastActiveEpoch The last epoch where this proposer was active
     * @param livenessScore The proposer's liveness score (0-10000 = 0-100.00%)
     * @param operationalKey The key used for block signing (can differ from staking key)
     */
    struct ProposerInfo {
        uint256 stake;
        uint256 delegatedStake;
        bool isActive;
        bool isRegistered;
        uint256 lastActiveEpoch;
        uint256 livenessScore;
        address operationalKey;
    }

    // ============ Errors ============

    /// @notice Thrown when stake amount is below minimum
    error InsufficientStake(uint256 provided, uint256 required);

    /// @notice Thrown when proposer is not registered
    error ProposerNotRegistered(address proposer);

    /// @notice Thrown when proposer is already registered
    error ProposerAlreadyRegistered(address proposer);

    /// @notice Thrown when trying to unregister an active proposer
    error CannotUnregisterActiveProposer();

    /// @notice Thrown when active set is full and stake is too low
    error ActiveSetFull();

    /// @notice Thrown when rebalance is not needed
    error RebalanceNotNeeded();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when operational key is invalid
    error InvalidOperationalKey();

    /// @notice Thrown when withdrawal amount exceeds available
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Thrown when proposer is slashed
    error ProposerSlashed(address proposer);

    /// @notice Thrown when the hub address is invalid
    error InvalidHub();

    // ============ Events ============

    /// @notice Emitted when a proposer registers
    event ProposerRegistered(
        address indexed proposer,
        uint256 stake,
        address operationalKey
    );

    /// @notice Emitted when a proposer unregisters
    event ProposerUnregistered(address indexed proposer, uint256 stakeReturned);

    /// @notice Emitted when stake is added
    event StakeAdded(address indexed proposer, uint256 amount, uint256 newTotal);

    /// @notice Emitted when stake is withdrawn
    event StakeWithdrawn(address indexed proposer, uint256 amount, uint256 remaining);

    /// @notice Emitted when stake is delegated
    event StakeDelegated(
        address indexed delegator,
        address indexed proposer,
        uint256 amount
    );

    /// @notice Emitted when delegation is removed
    event DelegationRemoved(
        address indexed delegator,
        address indexed proposer,
        uint256 amount
    );

    /// @notice Emitted when the active set is rebalanced
    event ActiveSetRebalanced(
        address indexed demoted,
        address indexed promoted,
        uint256 demotedStake,
        uint256 promotedStake
    );

    /// @notice Emitted when a proposer is slashed for liveness failure
    event ProposerSlashedForLiveness(
        address indexed proposer,
        uint256 slashAmount,
        uint256 livenessScore
    );

    /// @notice Emitted when the next proposer is selected
    event NextProposerSelected(
        address indexed proposer,
        uint256 indexed epoch
    );

    /// @notice Emitted when operational key is updated
    event OperationalKeyUpdated(
        address indexed proposer,
        address indexed oldKey,
        address indexed newKey
    );

    /// @notice Emitted when liveness is reported
    event LivenessReported(
        address indexed proposer,
        uint256 epoch,
        uint256 newScore
    );

    // ============ View Functions ============

    /**
     * @notice Returns the minimum stake required to register.
     * @return The minimum stake in wei
     */
    function minimumStake() external view returns (uint256);

    /**
     * @notice Returns the maximum size of the active proposer set.
     * @return The maximum active set size
     */
    function maxActiveSetSize() external view returns (uint256);

    /**
     * @notice Returns information about a proposer.
     * @param _proposer The proposer address
     * @return The proposer information
     */
    function getProposerInfo(address _proposer) external view returns (ProposerInfo memory);

    /**
     * @notice Returns the current active proposer set.
     * @return Array of active proposer addresses
     */
    function getActiveProposers() external view returns (address[] memory);

    /**
     * @notice Returns the total stake (own + delegated) for a proposer.
     * @param _proposer The proposer address
     * @return The total effective stake
     */
    function getTotalStake(address _proposer) external view returns (uint256);

    /**
     * @notice Returns the number of registered proposers.
     * @return The count
     */
    function getRegisteredProposerCount() external view returns (uint256);

    /**
     * @notice Returns the number of active proposers.
     * @return The count
     */
    function getActiveProposerCount() external view returns (uint256);

    /**
     * @notice Checks if a proposer is in the active set.
     * @param _proposer The proposer address
     * @return True if active
     */
    function isActiveProposer(address _proposer) external view returns (bool);

    /**
     * @notice Returns the stake delegated by an address to a proposer.
     * @param _delegator The delegator address
     * @param _proposer The proposer address
     * @return The delegated amount
     */
    function getDelegation(address _delegator, address _proposer) external view returns (uint256);

    /**
     * @notice Checks if the active set needs rebalancing.
     * @return True if rebalancing would change the set
     */
    function needsRebalancing() external view returns (bool);

    /**
     * @notice Gets the lowest-staked active proposer.
     * @return proposer The proposer address
     * @return stake The proposer's total stake
     */
    function getLowestActiveProposer() external view returns (address proposer, uint256 stake);

    /**
     * @notice Gets the highest-staked inactive proposer.
     * @return proposer The proposer address
     * @return stake The proposer's total stake
     */
    function getHighestInactiveProposer() external view returns (address proposer, uint256 stake);

    /**
     * @notice Selects the next proposer based on the selection algorithm.
     * @dev Used by the Hub to determine who should propose next.
     *      Can be round-robin, weighted random, or stake-weighted.
     * @param _currentEpoch The current epoch number
     * @return The next proposer's address
     */
    function selectNextProposer(uint256 _currentEpoch) external view returns (address);

    /**
     * @notice Returns the hub contract address.
     * @return The hub address
     */
    function hub() external view returns (address);

    // ============ Proposer Functions ============

    /**
     * @notice Registers as a proposer with initial stake.
     * @param _operationalKey The key to use for block signing
     */
    function register(address _operationalKey) external payable;

    /**
     * @notice Unregisters as a proposer and withdraws all stake.
     * @dev Cannot unregister while in the active set.
     */
    function unregister() external;

    /**
     * @notice Adds stake to an existing registration.
     */
    function addStake() external payable;

    /**
     * @notice Withdraws stake (partial withdrawal allowed).
     * @dev Cannot withdraw below minimum stake while registered.
     * @param _amount The amount to withdraw
     */
    function withdrawStake(uint256 _amount) external;

    /**
     * @notice Updates the operational key.
     * @param _newKey The new operational key
     */
    function updateOperationalKey(address _newKey) external;

    // ============ Delegation Functions ============

    /**
     * @notice Delegates stake to a proposer.
     * @param _proposer The proposer to delegate to
     */
    function delegate(address _proposer) external payable;

    /**
     * @notice Removes delegation from a proposer.
     * @param _proposer The proposer to undelegate from
     * @param _amount The amount to undelegate
     */
    function undelegate(address _proposer, uint256 _amount) external;

    // ============ Public Functions ============

    /**
     * @notice Rebalances the active set by swapping lowest-stake active with highest-stake inactive.
     * @dev Anyone can call this function. Incentivized by gas refund or small reward.
     */
    function rebalance() external;

    // ============ Hub Functions ============

    /**
     * @notice Reports liveness for a proposer after their epoch.
     * @dev Called by the Hub after epoch completion.
     * @param _proposer The proposer address
     * @param _epoch The epoch number
     * @param _blocksProduced Number of blocks produced
     * @param _blocksExpected Number of blocks expected
     */
    function reportLiveness(
        address _proposer,
        uint256 _epoch,
        uint256 _blocksProduced,
        uint256 _blocksExpected
    ) external;

    /**
     * @notice Slashes a proposer for liveness failure.
     * @dev Called by governance or through Kleros dispute.
     * @param _proposer The proposer to slash
     * @param _percentage The percentage to slash (in basis points, 10000 = 100%)
     */
    function slashForLiveness(address _proposer, uint256 _percentage) external;

    // ============ Governance Functions ============

    /**
     * @notice Sets the minimum stake requirement.
     * @param _newMinimum The new minimum stake
     */
    function setMinimumStake(uint256 _newMinimum) external;

    /**
     * @notice Sets the maximum active set size.
     * @param _newSize The new maximum size
     */
    function setMaxActiveSetSize(uint256 _newSize) external;

    /**
     * @notice Sets the hub contract address.
     * @param _hub The new hub address
     */
    function setHub(address _hub) external;
}
