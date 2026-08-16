// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniversalBuilder} from "../interfaces/IUniversalBuilder.sol";

/**
 * @title FlashblocksBuilder
 * @notice Default block builder using MEV-Boost + Flashblocks private mempool.
 * @dev This is ISOCHRON's default block building mechanism:
 *      - Private mempool: transactions are not publicly visible before inclusion
 *      - MEV-Boost compatible: integrates with the existing MEV-Boost relay infrastructure
 *      - Flashblocks streaming: sub-block granularity for faster confirmations
 *      - Bundle support: cross-chain bundles are given priority inclusion
 *
 *      The builder validates that build requests conform to its requirements
 *      but actual block construction happens off-chain in the relay (Rust component).
 *      This contract serves as the on-chain registration and validation layer.
 *
 *      Upgrade path: When the network moves to more public/trustless building,
 *      a new builder can be registered and set as default without changing
 *      any core protocol contracts.
 */
contract FlashblocksBuilder is IUniversalBuilder {
    // ============ Constants ============

    uint256 public constant VERSION_NUM = 1_000_000;
    string public constant NAME = "FlashblocksBuilder";
    string public constant DESCRIPTION =
        "MEV-Boost + Flashblocks private mempool builder (ISOCHRON default)";

    /// @notice Maximum bundles per block
    uint256 public constant MAX_BUNDLES_PER_BLOCK = 128;

    /// @notice Minimum gas limit for a build request
    uint256 public constant MIN_GAS_LIMIT = 1_000_000;

    // ============ State Variables ============

    /// @notice Governance address
    address public governance;

    /// @notice Relay endpoint URI (off-chain, stored for discoverability)
    string public relayEndpoint;

    /// @notice Set of supported chain IDs
    mapping(uint256 => bool) internal _supportedChains;

    /// @notice Array of supported chain IDs for enumeration
    uint256[] internal _supportedChainIds;

    // ============ Events ============

    event ChainSupportAdded(uint256 indexed chainId);
    event ChainSupportRemoved(uint256 indexed chainId);
    event RelayEndpointUpdated(string newEndpoint);

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert("Not governance");
        _;
    }

    // ============ Constructor ============

    constructor(address _governance, string memory _relayEndpoint) {
        governance = _governance;
        relayEndpoint = _relayEndpoint;
    }

    // ============ View Functions ============

    function builderType() external pure override returns (BuilderType) {
        return BuilderType.PrivateMempool;
    }

    function version() external pure override returns (uint256) {
        return VERSION_NUM;
    }

    function builderInfo()
        external
        pure
        override
        returns (string memory name, string memory description)
    {
        return (NAME, DESCRIPTION);
    }

    function supportsChain(uint256 _chainId) external view override returns (bool) {
        return _supportedChains[_chainId];
    }

    function getSupportedChains() external view returns (uint256[] memory) {
        return _supportedChainIds;
    }

    function validateBuildRequest(BuildRequest calldata _request)
        external
        view
        override
        returns (bool valid, string memory reason)
    {
        // Check chain support
        if (!_supportedChains[_request.chainId]) {
            return (false, "Chain not supported by this builder");
        }

        // Check gas limit
        if (_request.gasLimit < MIN_GAS_LIMIT) {
            return (false, "Gas limit below minimum");
        }

        // Check bundle count
        if (_request.bundles.length > MAX_BUNDLES_PER_BLOCK) {
            return (false, "Too many bundles for single block");
        }

        // Check timestamp is not in the past
        if (_request.timestamp < block.timestamp) {
            return (false, "Timestamp in the past");
        }

        return (true, "");
    }

    // ============ Governance Functions ============

    function addChainSupport(uint256 _chainId) external onlyGovernance {
        if (!_supportedChains[_chainId]) {
            _supportedChains[_chainId] = true;
            _supportedChainIds.push(_chainId);
            emit ChainSupportAdded(_chainId);
        }
    }

    function removeChainSupport(uint256 _chainId) external onlyGovernance {
        if (_supportedChains[_chainId]) {
            _supportedChains[_chainId] = false;
            // Remove from array
            for (uint256 i = 0; i < _supportedChainIds.length; i++) {
                if (_supportedChainIds[i] == _chainId) {
                    _supportedChainIds[i] = _supportedChainIds[_supportedChainIds.length - 1];
                    _supportedChainIds.pop();
                    break;
                }
            }
            emit ChainSupportRemoved(_chainId);
        }
    }

    function setRelayEndpoint(string calldata _endpoint) external onlyGovernance {
        relayEndpoint = _endpoint;
        emit RelayEndpointUpdated(_endpoint);
    }

    function setGovernance(address _newGovernance) external onlyGovernance {
        governance = _newGovernance;
    }
}
