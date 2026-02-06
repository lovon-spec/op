// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IProposerRegistry} from "../../src/interfaces/IProposerRegistry.sol";

/**
 * @title MockProposerRegistry
 * @notice Mock ProposerRegistry for testing SharedSequencerHub.
 * @dev Provides controllable proposer selection for testing.
 */
contract MockProposerRegistry is IProposerRegistry {
    // ============ State Variables ============

    address[] public proposers;
    mapping(address => ProposerInfo) public proposerInfos;
    uint256 public override minimumStake = 1 ether;
    uint256 public override maxActiveSetSize = 100;
    address public override hub;
    mapping(address => mapping(address => bytes)) public adapterData;

    // For testing: control which proposer is selected
    address public nextProposerOverride;
    bool public useOverride;

    // For testing: track liveness reports
    address public lastLivenessProposer;
    uint256 public lastLivenessEpoch;
    uint256 public lastLivenessBlocksProduced;
    uint256 public lastLivenessBlocksExpected;
    uint256 public livenessReportCount;

    // ============ Constructor ============

    constructor() {
        // Add some default proposers for testing
    }

    // ============ Test Helpers ============

    function addProposer(address _proposer, uint256 _stake) external {
        proposers.push(_proposer);
        proposerInfos[_proposer] = ProposerInfo({
            stake: _stake,
            delegatedStake: 0,
            isActive: true,
            isRegistered: true,
            lastActiveEpoch: 0,
            livenessScore: 10000,
            operationalKey: _proposer
        });
    }

    function setNextProposerOverride(address _proposer) external {
        nextProposerOverride = _proposer;
        useOverride = true;
    }

    function clearOverride() external {
        useOverride = false;
    }

    function setHub(address _hub) external override {
        hub = _hub;
    }

    // ============ View Functions ============

    function getProposerInfo(address _proposer) external view override returns (ProposerInfo memory) {
        return proposerInfos[_proposer];
    }

    function getActiveProposers() external view override returns (address[] memory) {
        return proposers;
    }

    function getTotalStake(address _proposer) external view override returns (uint256) {
        ProposerInfo storage info = proposerInfos[_proposer];
        return info.stake + info.delegatedStake;
    }

    function getRegisteredProposerCount() external view override returns (uint256) {
        return proposers.length;
    }

    function getActiveProposerCount() external view override returns (uint256) {
        return proposers.length;
    }

    function isActiveProposer(address _proposer) external view override returns (bool) {
        return proposerInfos[_proposer].isActive;
    }

    function getDelegation(address, address) external pure override returns (uint256) {
        return 0;
    }

    function getAdapterData(address _proposer, address _adapter) external view override returns (bytes memory) {
        return adapterData[_proposer][_adapter];
    }

    function needsRebalancing() external pure override returns (bool) {
        return false;
    }

    function getLowestActiveProposer() external view override returns (address, uint256) {
        if (proposers.length == 0) return (address(0), 0);
        return (proposers[0], proposerInfos[proposers[0]].stake);
    }

    function getHighestInactiveProposer() external pure override returns (address, uint256) {
        return (address(0), 0);
    }

    function selectNextProposer(uint256 _currentEpoch) external view override returns (address) {
        if (useOverride) {
            return nextProposerOverride;
        }
        if (proposers.length == 0) {
            return address(0);
        }
        return proposers[_currentEpoch % proposers.length];
    }

    // ============ Stub Functions ============

    function register(address) external payable override {}
    function unregister() external override {}
    function addStake() external payable override {}
    function withdrawStake(uint256) external override {}
    function updateOperationalKey(address) external override {}
    function setAdapterData(address _adapter, bytes calldata _data) external override {
        adapterData[msg.sender][_adapter] = _data;
    }
    function delegate(address) external payable override {}
    function undelegate(address, uint256) external override {}
    function rebalance() external override {}
    function reportLiveness(address _proposer, uint256 _epoch, uint256 _blocksProduced, uint256 _blocksExpected) external override {
        lastLivenessProposer = _proposer;
        lastLivenessEpoch = _epoch;
        lastLivenessBlocksProduced = _blocksProduced;
        lastLivenessBlocksExpected = _blocksExpected;
        livenessReportCount++;
    }
    function slashForLiveness(address, uint256) external override {}
    function setMinimumStake(uint256 _newMinimum) external override {
        minimumStake = _newMinimum;
    }
    function setMaxActiveSetSize(uint256 _newSize) external override {
        maxActiveSetSize = _newSize;
    }
}
