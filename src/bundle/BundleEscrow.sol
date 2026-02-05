// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBundleEscrow} from "../interfaces/IBundleEscrow.sol";

/**
 * @title BundleEscrow
 * @notice Holds tips and bonds for cross-chain bundle execution.
 * @dev Economic incentive alignment:
 *      - Searchers deposit tips that are released to the sequencer upon successful execution
 *      - Sequencers post bonds that are slashed on violation or expiry
 *      - Violation reporters receive a portion of the slashed bond (reporter reward)
 *
 *      Only the authorized BundleRegistry can trigger releases and slashing.
 */
contract BundleEscrow is IBundleEscrow {
    // ============ Constants ============

    /// @notice Default minimum bond (0.1 ETH)
    uint256 public constant DEFAULT_MINIMUM_BOND = 0.1 ether;

    /// @notice Reporter reward percentage (in basis points, 10000 = 100%)
    uint256 public constant REPORTER_REWARD_BPS = 1000; // 10%

    /// @notice Basis points divisor
    uint256 public constant BPS_DIVISOR = 10000;

    // ============ State Variables ============

    /// @notice The bundle registry contract (only caller for state changes)
    address public bundleRegistry;

    /// @notice Governance address
    address public governance;

    /// @notice Minimum bond amount
    uint256 public override minimumBond;

    /// @notice Mapping from bundleId to escrow entry
    mapping(bytes32 => EscrowEntry) internal _escrows;

    // ============ Modifiers ============

    modifier onlyBundleRegistry() {
        if (msg.sender != bundleRegistry) revert NotBundleRegistry();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotBundleRegistry();
        _;
    }

    // ============ Constructor ============

    constructor(address _bundleRegistry, address _governance, uint256 _minimumBond) {
        bundleRegistry = _bundleRegistry;
        governance = _governance;
        minimumBond = _minimumBond == 0 ? DEFAULT_MINIMUM_BOND : _minimumBond;
    }

    // ============ View Functions ============

    function getEscrow(bytes32 _bundleId) external view override returns (EscrowEntry memory) {
        return _escrows[_bundleId];
    }

    // ============ Functions ============

    function depositTip(bytes32 _bundleId) external payable override {
        EscrowEntry storage entry = _escrows[_bundleId];
        entry.tip += msg.value;
        if (entry.submitter == address(0)) {
            entry.submitter = msg.sender;
        }

        emit TipDeposited(_bundleId, msg.sender, msg.value);
    }

    function postBond(bytes32 _bundleId) external payable override {
        if (msg.value < minimumBond) revert InsufficientBond();

        EscrowEntry storage entry = _escrows[_bundleId];
        entry.bond += msg.value;
        entry.sequencer = msg.sender;

        emit BondPosted(_bundleId, msg.sender, msg.value);
    }

    function releaseTip(bytes32 _bundleId) external override onlyBundleRegistry {
        EscrowEntry storage entry = _escrows[_bundleId];
        if (entry.released) revert AlreadyReleased();

        uint256 tipAmount = entry.tip;
        if (tipAmount == 0) return;

        entry.tip = 0;

        if (entry.sequencer != address(0)) {
            _sendValue(payable(entry.sequencer), tipAmount);
            emit TipReleased(_bundleId, entry.sequencer, tipAmount);
        }
    }

    function returnBond(bytes32 _bundleId) external override onlyBundleRegistry {
        EscrowEntry storage entry = _escrows[_bundleId];
        if (entry.released) revert AlreadyReleased();

        uint256 bondAmount = entry.bond;
        if (bondAmount == 0) return;

        entry.bond = 0;
        entry.released = true;

        _sendValue(payable(entry.sequencer), bondAmount);
        emit BondReturned(_bundleId, entry.sequencer, bondAmount);
    }

    function slashBond(bytes32 _bundleId, address _reporter) external override onlyBundleRegistry {
        EscrowEntry storage entry = _escrows[_bundleId];
        if (entry.released) revert AlreadyReleased();

        uint256 bondAmount = entry.bond;
        if (bondAmount == 0) return;

        entry.bond = 0;
        entry.released = true;

        // Reporter gets a reward
        uint256 reporterReward = (bondAmount * REPORTER_REWARD_BPS) / BPS_DIVISOR;
        uint256 remaining = bondAmount - reporterReward;

        if (reporterReward > 0 && _reporter != address(0)) {
            _sendValue(payable(_reporter), reporterReward);
        }

        // Remaining goes to governance (treasury)
        if (remaining > 0) {
            _sendValue(payable(governance), remaining);
        }

        emit BondSlashed(_bundleId, entry.sequencer, bondAmount, _reporter);
    }

    function refundTip(bytes32 _bundleId) external override onlyBundleRegistry {
        EscrowEntry storage entry = _escrows[_bundleId];

        uint256 tipAmount = entry.tip;
        if (tipAmount == 0) return;

        entry.tip = 0;

        if (entry.submitter != address(0)) {
            _sendValue(payable(entry.submitter), tipAmount);
            emit TipRefunded(_bundleId, entry.submitter, tipAmount);
        }
    }

    // ============ Governance Functions ============

    function setBundleRegistry(address _bundleRegistry) external onlyGovernance {
        bundleRegistry = _bundleRegistry;
    }

    function setMinimumBond(uint256 _minimumBond) external onlyGovernance {
        minimumBond = _minimumBond;
    }

    // ============ Internal Functions ============

    function _sendValue(address payable _to, uint256 _amount) internal {
        if (_amount == 0) return;
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
