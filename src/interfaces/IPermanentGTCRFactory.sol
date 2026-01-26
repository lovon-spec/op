// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC20
 * @notice Minimal ERC20 interface for Kleros GTCR token parameter.
 * @dev Only needed to pass address(0) for native ETH stakes.
 */
interface IERC20 {}

/**
 * @title IArbitrator
 * @notice Minimal interface for Kleros arbitrator (KlerosCore).
 */
interface IArbitrator {
    function arbitrationCost(bytes calldata _extraData) external view returns (uint256);
}

/**
 * @title IPermanentGTCRFactory
 * @notice Interface for the Kleros PermanentGTCR Factory contract.
 * @dev Deployed on mainnet at 0x69816B499b0eD9a60ac52cF2beB24827E5F13A89
 *
 * The factory creates minimal proxy clones of PermanentGTCR instances.
 */
interface IPermanentGTCRFactory {
    /**
     * @notice Deploys a new PermanentGTCR instance.
     * @param _arbitrator Arbitrator to resolve potential disputes.
     * @param _arbitratorExtraData Extra data for the arbitrator (court ID + juror count for Kleros).
     * @param _metaEvidence The URI of the meta evidence object (IPFS).
     * @param _governor The trusted governor of this contract.
     * @param _token The ERC20 token for stakes (address(0) for native ETH).
     * @param _submissionMinDeposit Minimum deposit required for item submission.
     * @param _periods Array of 4 periods: [validityPeriod, safetyPeriod, withdrawalPeriod, paramEnforcementPeriod]
     * @param _stakeMultipliers Array of 4 basis point multipliers: [sharedStake, winnerStake, loserStake, challengeStake]
     * @return The address of the newly deployed PermanentGTCR instance.
     */
    function deploy(
        IArbitrator _arbitrator,
        bytes calldata _arbitratorExtraData,
        string calldata _metaEvidence,
        address _governor,
        IERC20 _token,
        uint256 _submissionMinDeposit,
        uint256[4] calldata _periods,
        uint256[4] calldata _stakeMultipliers
    ) external returns (address);

    /**
     * @notice Returns the implementation address used for clones.
     */
    function implementation() external view returns (address);
}

/**
 * @title IPermanentGTCR
 * @notice Interface for interacting with a deployed PermanentGTCR instance.
 */
interface IPermanentGTCR {
    enum Status {
        Absent,      // Item never existed or was removed
        Submitted,   // Item is in registry, challengeable
        Reincluded,  // Item re-added via dispute
        Disputed     // Item currently disputed
    }

    /**
     * @notice Adds an item to the registry.
     * @param _item The data describing the item (ABI-encoded).
     * @param _deposit The deposit amount for the submission.
     */
    function addItem(string calldata _item, uint256 _deposit) external payable;

    /**
     * @notice Gets the status and info of an item.
     * @param _itemID The ID of the item (keccak256 of the item data).
     * @return data The item data.
     * @return status The current status.
     * @return numberOfRequests The number of requests for this item.
     */
    function items(bytes32 _itemID) external view returns (
        bytes memory data,
        Status status,
        uint256 numberOfRequests
    );

    /**
     * @notice Gets information about an item.
     */
    function getItemInfo(bytes32 _itemID) external view returns (
        bytes memory data,
        Status status,
        uint256 numberOfRequests
    );

    /**
     * @notice The minimum deposit required for submissions.
     */
    function submissionMinDeposit() external view returns (uint256);

    /**
     * @notice The arbitrator address.
     */
    function arbitrator() external view returns (address);

    /**
     * @notice The governor address.
     */
    function governor() external view returns (address);

    /**
     * @notice Executes a pending request after the challenge period.
     * @param _itemID The ID of the item.
     */
    function executeRequest(bytes32 _itemID) external;

    /**
     * @notice The duration of the challenge period.
     */
    function challengePeriodDuration() external view returns (uint256);
}
