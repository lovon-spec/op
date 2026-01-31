// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBuilderRegistry} from "../../src/interfaces/IBuilderRegistry.sol";

/**
 * @title MockBuilderRegistry
 * @notice Mock BuilderRegistry for testing SharedSequencerHub.
 * @dev Provides controllable builder eligibility for testing.
 */
contract MockBuilderRegistry is IBuilderRegistry {
    // ============ Constants ============

    bytes32 public constant override POLICY_OFAC = keccak256("POLICY_OFAC");
    bytes32 public constant override POLICY_KYC = keccak256("POLICY_KYC");
    bytes32 public constant override POLICY_NO_MEV = keccak256("POLICY_NO_MEV");
    bytes32 public constant override POLICY_NO_GAMBLING = keccak256("POLICY_NO_GAMBLING");
    bytes32 public constant override POLICY_NEUTRAL = keccak256("POLICY_NEUTRAL");

    // ============ State Variables ============

    uint256 public override minimumBond = 1 ether;
    address public override hub;

    address[] public builders;
    mapping(address => BuilderInfo) public builderInfos;
    mapping(address => mapping(bytes32 => PolicyTagStatus)) public policyTags;

    // ============ Test Helpers ============

    function addBuilder(address _builder, uint256 _bond) external {
        builders.push(_builder);
        builderInfos[_builder] = BuilderInfo({
            bond: _bond,
            isActive: true,
            registrationTime: block.timestamp,
            slashCount: 0,
            lastSlashTime: 0
        });
    }

    function grantTag(address _builder, bytes32 _policyId) external {
        policyTags[_builder][_policyId] = PolicyTagStatus({
            isGranted: true,
            grantedAt: block.timestamp,
            expiresAt: 0,
            revokedAt: 0
        });
    }

    function setHub(address _hub) external override {
        hub = _hub;
    }

    // ============ View Functions ============

    function getBuilderInfo(address _builder) external view override returns (BuilderInfo memory) {
        return builderInfos[_builder];
    }

    function hasPolicyTag(address _builder, bytes32 _policyId) public view override returns (bool) {
        PolicyTagStatus storage status = policyTags[_builder][_policyId];
        if (!status.isGranted) return false;
        if (status.revokedAt > 0) return false;
        if (status.expiresAt > 0 && block.timestamp > status.expiresAt) return false;
        return true;
    }

    function getPolicyTagStatus(
        address _builder,
        bytes32 _policyId
    ) external view override returns (PolicyTagStatus memory) {
        return policyTags[_builder][_policyId];
    }

    function getBuilderPolicyTags(address) external pure override returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function isBuilderEligible(address _builder, bytes32 _policyId) public view override returns (bool) {
        BuilderInfo storage info = builderInfos[_builder];
        if (!info.isActive) return false;
        if (_policyId == POLICY_NEUTRAL) return true;
        return hasPolicyTag(_builder, _policyId);
    }

    function isBuilderEligibleForBundle(
        address _builder,
        bytes32[] calldata _policyIds
    ) external view override returns (bool) {
        BuilderInfo storage info = builderInfos[_builder];
        if (!info.isActive) return false;

        for (uint256 i = 0; i < _policyIds.length; i++) {
            if (_policyIds[i] == POLICY_NEUTRAL) continue;
            if (!hasPolicyTag(_builder, _policyIds[i])) return false;
        }
        return true;
    }

    function getRegisteredBuilderCount() external view override returns (uint256) {
        return builders.length;
    }

    function getActiveBuilderCount() external view override returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < builders.length; i++) {
            if (builderInfos[builders[i]].isActive) count++;
        }
        return count;
    }

    function getActiveBuilders() external view override returns (address[] memory) {
        return builders;
    }

    function getBuildersForPolicy(bytes32 _policyId) external view override returns (address[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < builders.length; i++) {
            if (isBuilderEligible(builders[i], _policyId)) count++;
        }

        address[] memory result = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < builders.length; i++) {
            if (isBuilderEligible(builders[i], _policyId)) {
                result[index++] = builders[i];
            }
        }
        return result;
    }

    // ============ Stub Functions ============

    function register() external payable override {}
    function unregister() external override {}
    function addBond() external payable override {}
    function withdrawBond(uint256) external override {}
    function grantPolicyTag(address, bytes32, uint256) external override {}
    function revokePolicyTag(address, bytes32, string calldata) external override {}
    function slash(address, uint256, bytes32, string calldata) external override {}
    function deactivate(address, string calldata) external override {}
    function reactivate(address) external override {}
    function registerPolicy(bytes32, string calldata, string calldata) external override {}
    function setMinimumBond(uint256 _newMinimum) external override {
        minimumBond = _newMinimum;
    }
    function setSlashCooldown(uint256) external override {}
}
