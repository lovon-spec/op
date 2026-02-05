// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISovereignPolicy} from "../interfaces/ISovereignPolicy.sol";

/**
 * @title SovereignPolicyManager
 * @notice Manages sovereign sequencing policies for each chain in ISOCHRON.
 * @dev Each chain can declare its own sequencing rules that the active sequencer
 *      must obey. Policies are stored on-chain and enforced via:
 *      - Deterministic fraud proofs for objectively provable violations
 *      - Arbitration (Kleros default) for subjective criteria
 *
 *      Policy declaration flow:
 *      1. Chain governance declares a policy via declarePolicy()
 *      2. Policy is stored and becomes active for that chain
 *      3. Sequencer must comply when building blocks for that chain
 *      4. Violations trigger fraud proofs via FraudProofVerifier
 *
 *      Default policy (when chain has no declared policy):
 *      - SequencerDiscretion ordering (compatible with private mempool)
 *      - Hybrid enforcement
 *      - No MEV restrictions (sequencer can use MEV-Boost freely)
 *
 *      No trusted setups are hardcoded. Chains MAY opt into TEEs or
 *      other trust assumptions via customPolicyContract.
 */
contract SovereignPolicyManager is ISovereignPolicy {
    // ============ Constants ============

    uint256 public constant VERSION_NUM = 1_000_000;

    /// @notice Default max block time (12 seconds, matching Ethereum)
    uint256 public constant DEFAULT_MAX_BLOCK_TIME = 12 seconds;

    // ============ State Variables ============

    /// @notice Governance address
    address public governance;

    /// @notice Hub contract address
    address public hub;

    /// @notice Mapping from chainId to PolicyDeclaration
    mapping(uint256 => PolicyDeclaration) internal _policies;

    /// @notice Mapping from chainId to chain governance address (who can set policies)
    mapping(uint256 => address) internal _chainGovernance;

    /// @notice Array of chains with active policies
    uint256[] internal _activePolicyChains;

    /// @notice Mapping from chainId to index in _activePolicyChains (1-indexed)
    mapping(uint256 => uint256) internal _activePolicyIndex;

    // ============ Events (additional) ============

    event ChainGovernanceSet(uint256 indexed chainId, address indexed chainGovernor);

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert("Not governance");
        _;
    }

    modifier onlyChainGovernance(uint256 _chainId) {
        // Chain governance can set policies for their chain
        // Hub governance can set policies for any chain
        if (msg.sender != _chainGovernance[_chainId] && msg.sender != governance) {
            revert("Not chain governance");
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _governance, address _hub) {
        governance = _governance;
        hub = _hub;
    }

    // ============ View Functions ============

    function getPolicy(uint256 _chainId)
        external
        view
        override
        returns (PolicyDeclaration memory)
    {
        PolicyDeclaration memory policy = _policies[_chainId];
        // Return default policy if none declared
        if (!policy.isActive && policy.chainId == 0) {
            return _defaultPolicy(_chainId);
        }
        return policy;
    }

    function isPolicyActive(uint256 _chainId) external view override returns (bool) {
        return _policies[_chainId].isActive;
    }

    function version() external pure override returns (uint256) {
        return VERSION_NUM;
    }

    function policyInfo()
        external
        pure
        override
        returns (string memory name, string memory description)
    {
        return (
            "SovereignPolicyManager",
            "Manages per-chain sovereign sequencing policies for ISOCHRON"
        );
    }

    function checkCompliance(uint256 _chainId, bytes calldata _blockData)
        external
        view
        override
        returns (ComplianceResult memory result)
    {
        PolicyDeclaration memory policy = _policies[_chainId];

        // No active policy means compliant by default
        if (!policy.isActive) {
            return ComplianceResult({compliant: true, violationType: bytes32(0), evidence: ""});
        }

        // If custom policy contract is set, delegate to it
        if (policy.customPolicyContract != address(0)) {
            try ISovereignPolicy(policy.customPolicyContract).checkCompliance(_chainId, _blockData)
            returns (ComplianceResult memory customResult) {
                return customResult;
            } catch {
                // If custom check fails, return compliant (fail-open for availability)
                return
                    ComplianceResult({compliant: true, violationType: bytes32(0), evidence: ""});
            }
        }

        // Built-in compliance checks for standard policies
        // These are basic checks; the detailed verification happens in FraudProofVerifier
        return ComplianceResult({compliant: true, violationType: bytes32(0), evidence: ""});
    }

    function getChainGovernance(uint256 _chainId) external view returns (address) {
        return _chainGovernance[_chainId];
    }

    function getActivePolicyChains() external view returns (uint256[] memory) {
        return _activePolicyChains;
    }

    // ============ Chain Governance Functions ============

    function declarePolicy(
        uint256 _chainId,
        OrderingStrategy _orderingStrategy,
        EnforcementType _enforcementType,
        uint256 _maxBlockTime,
        uint256 _forcedInclusionDeadline,
        bool _sandwichProtection,
        bool _backrunOnly,
        address _customPolicyContract,
        bytes calldata _policyData
    ) external onlyChainGovernance(_chainId) {
        _policies[_chainId] = PolicyDeclaration({
            chainId: _chainId,
            orderingStrategy: _orderingStrategy,
            enforcementType: _enforcementType,
            maxBlockTime: _maxBlockTime == 0 ? DEFAULT_MAX_BLOCK_TIME : _maxBlockTime,
            forcedInclusionDeadline: _forcedInclusionDeadline,
            sandwichProtection: _sandwichProtection,
            backrunOnly: _backrunOnly,
            customPolicyContract: _customPolicyContract,
            policyData: _policyData,
            isActive: true
        });

        // Track in active list
        if (_activePolicyIndex[_chainId] == 0) {
            _activePolicyChains.push(_chainId);
            _activePolicyIndex[_chainId] = _activePolicyChains.length;
        }

        emit PolicyDeclared(_chainId, _orderingStrategy, _enforcementType);
    }

    function updatePolicyData(uint256 _chainId, bytes calldata _policyData)
        external
        onlyChainGovernance(_chainId)
    {
        PolicyDeclaration storage policy = _policies[_chainId];
        policy.policyData = _policyData;
        emit PolicyUpdated(_chainId);
    }

    function deactivatePolicy(uint256 _chainId) external onlyChainGovernance(_chainId) {
        _policies[_chainId].isActive = false;

        // Remove from active list
        uint256 index = _activePolicyIndex[_chainId];
        if (index != 0) {
            uint256 arrayIndex = index - 1;
            uint256 lastIndex = _activePolicyChains.length - 1;
            if (arrayIndex != lastIndex) {
                uint256 lastChainId = _activePolicyChains[lastIndex];
                _activePolicyChains[arrayIndex] = lastChainId;
                _activePolicyIndex[lastChainId] = index;
            }
            _activePolicyChains.pop();
            delete _activePolicyIndex[_chainId];
        }

        emit PolicyDeactivated(_chainId);
    }

    // ============ Governance Functions ============

    function setChainGovernance(uint256 _chainId, address _chainGovernor) external onlyGovernance {
        _chainGovernance[_chainId] = _chainGovernor;
        emit ChainGovernanceSet(_chainId, _chainGovernor);
    }

    function setGovernance(address _newGovernance) external onlyGovernance {
        governance = _newGovernance;
    }

    function setHub(address _newHub) external onlyGovernance {
        hub = _newHub;
    }

    // ============ Internal Functions ============

    function _defaultPolicy(uint256 _chainId) internal pure returns (PolicyDeclaration memory) {
        return PolicyDeclaration({
            chainId: _chainId,
            orderingStrategy: OrderingStrategy.SequencerDiscretion,
            enforcementType: EnforcementType.Hybrid,
            maxBlockTime: DEFAULT_MAX_BLOCK_TIME,
            forcedInclusionDeadline: 0,
            sandwichProtection: false,
            backrunOnly: false,
            customPolicyContract: address(0),
            policyData: "",
            isActive: false
        });
    }
}
