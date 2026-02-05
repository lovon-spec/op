// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBuilderRegistry} from "../interfaces/IBuilderRegistry.sol";
import {IUniversalBuilder} from "../interfaces/IUniversalBuilder.sol";

/**
 * @title BuilderRegistry
 * @notice Registry for approved block builders in ISOCHRON.
 * @dev Manages the lifecycle of block builders:
 *      - Registration and deactivation by governance
 *      - Default builder (MEV-Boost + Flashblocks) used when chain has no preference
 *      - Per-chain builder overrides for sovereign chain preferences
 *
 *      The registry is upgrade-friendly: new builder types can be registered
 *      without changing core protocol contracts.
 */
contract BuilderRegistry is IBuilderRegistry {
    // ============ State Variables ============

    /// @notice Governance address
    address public governance;

    /// @notice Default builder address (used when chain has no preference)
    address public defaultBuilder;

    /// @notice Mapping from builder address to info
    mapping(address => BuilderInfo) internal _builders;

    /// @notice Array of all registered builder addresses
    address[] internal _registeredBuilders;

    /// @notice Mapping from builder to index in _registeredBuilders (1-indexed)
    mapping(address => uint256) internal _builderIndex;

    /// @notice Per-chain builder overrides
    mapping(uint256 => address) internal _chainBuilders;

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // ============ Constructor ============

    constructor(address _governance) {
        if (_governance == address(0)) revert NotGovernance();
        governance = _governance;
    }

    // ============ View Functions ============

    function getBuilder(address _builder) external view override returns (BuilderInfo memory) {
        return _builders[_builder];
    }

    function getDefaultBuilder() external view override returns (address) {
        return defaultBuilder;
    }

    function getChainBuilder(uint256 _chainId) external view override returns (address) {
        return _chainBuilders[_chainId];
    }

    function getEffectiveBuilder(uint256 _chainId) external view override returns (address) {
        address chainBuilder = _chainBuilders[_chainId];
        if (chainBuilder != address(0) && _builders[chainBuilder].isActive) {
            return chainBuilder;
        }
        return defaultBuilder;
    }

    function isActiveBuilder(address _builder) external view override returns (bool) {
        return _builders[_builder].isActive;
    }

    function getActiveBuilders() external view override returns (address[] memory) {
        // Count active builders
        uint256 count = 0;
        for (uint256 i = 0; i < _registeredBuilders.length; i++) {
            if (_builders[_registeredBuilders[i]].isActive) {
                count++;
            }
        }

        // Build result array
        address[] memory active = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < _registeredBuilders.length; i++) {
            if (_builders[_registeredBuilders[i]].isActive) {
                active[idx++] = _registeredBuilders[i];
            }
        }

        return active;
    }

    // ============ Governance Functions ============

    function registerBuilder(address _builder) external override onlyGovernance {
        if (_builder == address(0)) revert InvalidBuilder();
        if (_builderIndex[_builder] != 0) revert BuilderAlreadyRegistered();

        // Query builder info
        IUniversalBuilder builder = IUniversalBuilder(_builder);
        (string memory name, ) = builder.builderInfo();
        IUniversalBuilder.BuilderType bType = builder.builderType();

        _builders[_builder] = BuilderInfo({
            builder: _builder,
            builderType: bType,
            isActive: true,
            registrationTime: block.timestamp,
            name: name
        });

        _registeredBuilders.push(_builder);
        _builderIndex[_builder] = _registeredBuilders.length;

        emit BuilderRegistered(_builder, name, bType);
    }

    function deactivateBuilder(address _builder) external override onlyGovernance {
        if (_builderIndex[_builder] == 0) revert BuilderNotRegistered();
        _builders[_builder].isActive = false;
        emit BuilderDeactivated(_builder);
    }

    function activateBuilder(address _builder) external override onlyGovernance {
        if (_builderIndex[_builder] == 0) revert BuilderNotRegistered();
        _builders[_builder].isActive = true;
        emit BuilderActivated(_builder);
    }

    function setDefaultBuilder(address _builder) external override onlyGovernance {
        if (_builder != address(0) && _builderIndex[_builder] == 0) revert BuilderNotRegistered();

        address oldBuilder = defaultBuilder;
        defaultBuilder = _builder;
        emit DefaultBuilderUpdated(oldBuilder, _builder);
    }

    function setChainBuilder(uint256 _chainId, address _builder) external override onlyGovernance {
        if (_builder != address(0) && _builderIndex[_builder] == 0) revert BuilderNotRegistered();

        _chainBuilders[_chainId] = _builder;
        emit ChainBuilderSet(_chainId, _builder);
    }

    function setGovernance(address _newGovernance) external onlyGovernance {
        if (_newGovernance == address(0)) revert NotGovernance();
        governance = _newGovernance;
    }
}
