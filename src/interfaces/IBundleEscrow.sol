// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBundleEscrow
 * @notice Interface for the Bundle Escrow - holds tips and bonds for cross-chain bundles.
 * @dev The escrow ensures economic incentives align:
 *      - Searchers deposit tips that are released to the sequencer upon successful execution
 *      - Sequencers post bonds that are slashed on violation
 *      - Violation reporters receive a portion of the slashed bond
 */
interface IBundleEscrow {
    // ============ Structs ============

    /**
     * @notice Escrow entry for a bundle.
     * @param tip Tip amount deposited by the bundle submitter
     * @param bond Bond posted by the sequencer
     * @param submitter Address that deposited the tip
     * @param sequencer Address that posted the bond
     * @param released Whether funds have been released
     */
    struct EscrowEntry {
        uint256 tip;
        uint256 bond;
        address submitter;
        address sequencer;
        bool released;
    }

    // ============ Events ============

    event TipDeposited(bytes32 indexed bundleId, address indexed submitter, uint256 amount);
    event BondPosted(bytes32 indexed bundleId, address indexed sequencer, uint256 amount);
    event TipReleased(bytes32 indexed bundleId, address indexed sequencer, uint256 amount);
    event BondReturned(bytes32 indexed bundleId, address indexed sequencer, uint256 amount);
    event BondSlashed(bytes32 indexed bundleId, address indexed sequencer, uint256 amount, address reporter);
    event TipRefunded(bytes32 indexed bundleId, address indexed submitter, uint256 amount);

    // ============ Errors ============

    error EscrowAlreadyExists();
    error EscrowNotFound();
    error AlreadyReleased();
    error InsufficientBond();
    error NotBundleRegistry();
    error TransferFailed();

    // ============ View Functions ============

    function getEscrow(bytes32 _bundleId) external view returns (EscrowEntry memory);
    function minimumBond() external view returns (uint256);

    // ============ Functions ============

    function depositTip(bytes32 _bundleId) external payable;
    function postBond(bytes32 _bundleId) external payable;
    function releaseTip(bytes32 _bundleId) external;
    function returnBond(bytes32 _bundleId) external;
    function slashBond(bytes32 _bundleId, address _reporter) external;
    function refundTip(bytes32 _bundleId) external;
}
