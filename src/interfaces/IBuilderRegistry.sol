// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniversalBuilder} from "./IUniversalBuilder.sol";

/**
 * @title IBuilderRegistry
 * @notice Interface for the Builder Registry - manages approved block builders.
 * @dev The registry tracks approved builders and their capabilities.
 *      Chains can select their preferred builder, or use the network default.
 *
 *      Default: MEV-Boost + Flashblocks (private mempool)
 *      Upgradeable to any future building mechanism.
 */
interface IBuilderRegistry {
    // ============ Structs ============

    /**
     * @notice Builder registration info.
     * @param builder The builder contract address
     * @param builderType Type classification
     * @param isActive Whether the builder is currently active
     * @param registrationTime When the builder was registered
     * @param name Human-readable name
     */
    struct BuilderInfo {
        address builder;
        IUniversalBuilder.BuilderType builderType;
        bool isActive;
        uint256 registrationTime;
        string name;
    }

    // ============ Events ============

    event BuilderRegistered(address indexed builder, string name, IUniversalBuilder.BuilderType builderType);
    event BuilderDeactivated(address indexed builder);
    event BuilderActivated(address indexed builder);
    event DefaultBuilderUpdated(address indexed oldBuilder, address indexed newBuilder);
    event ChainBuilderSet(uint256 indexed chainId, address indexed builder);

    // ============ Errors ============

    error BuilderAlreadyRegistered();
    error BuilderNotRegistered();
    error BuilderNotActive();
    error InvalidBuilder();
    error NotGovernance();

    // ============ View Functions ============

    function getBuilder(address _builder) external view returns (BuilderInfo memory);
    function getDefaultBuilder() external view returns (address);
    function getChainBuilder(uint256 _chainId) external view returns (address);
    function getEffectiveBuilder(uint256 _chainId) external view returns (address);
    function isActiveBuilder(address _builder) external view returns (bool);
    function getActiveBuilders() external view returns (address[] memory);

    // ============ Governance Functions ============

    function registerBuilder(address _builder) external;
    function deactivateBuilder(address _builder) external;
    function activateBuilder(address _builder) external;
    function setDefaultBuilder(address _builder) external;
    function setChainBuilder(uint256 _chainId, address _builder) external;
}
