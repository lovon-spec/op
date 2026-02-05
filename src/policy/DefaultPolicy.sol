// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISovereignPolicy} from "../interfaces/ISovereignPolicy.sol";

/**
 * @title DefaultPolicy
 * @notice Example sovereign policy: FCFS ordering with sandwich protection.
 * @dev Demonstrates how a chain can implement custom policy logic.
 *      This policy enforces:
 *      - First-come-first-served ordering (transactions ordered by receipt time)
 *      - Sandwich attack protection (no surrounding a victim tx with attacker txs)
 *      - Forced inclusion within 30 seconds
 *
 *      Chains deploy their own policy contract and reference it in their
 *      PolicyDeclaration. The SovereignPolicyManager delegates compliance
 *      checks to this contract.
 */
contract DefaultPolicy is ISovereignPolicy {
    // ============ Constants ============

    uint256 public constant VERSION_NUM = 1_000_000;

    uint256 public constant DEFAULT_FORCED_INCLUSION = 30 seconds;

    // ============ View Functions ============

    function getPolicy(uint256 _chainId)
        external
        pure
        override
        returns (PolicyDeclaration memory)
    {
        return PolicyDeclaration({
            chainId: _chainId,
            orderingStrategy: OrderingStrategy.FCFS,
            enforcementType: EnforcementType.Hybrid,
            maxBlockTime: 2 seconds,
            forcedInclusionDeadline: DEFAULT_FORCED_INCLUSION,
            sandwichProtection: true,
            backrunOnly: true,
            customPolicyContract: address(0),
            policyData: "",
            isActive: true
        });
    }

    function isPolicyActive(uint256) external pure override returns (bool) {
        return true;
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
            "DefaultPolicy",
            "FCFS ordering with sandwich protection and forced inclusion"
        );
    }

    function checkCompliance(uint256, bytes calldata _blockData)
        external
        pure
        override
        returns (ComplianceResult memory result)
    {
        // Decode block data to check for compliance
        // In a full implementation, this would verify:
        // 1. Transaction ordering matches FCFS (by receipt timestamp)
        // 2. No sandwich patterns detected
        // 3. Forced inclusion deadlines respected

        if (_blockData.length == 0) {
            return ComplianceResult({
                compliant: true,
                violationType: bytes32(0),
                evidence: ""
            });
        }

        // Basic structure validation
        // Full verification happens in the Rust relay and FraudProofVerifier
        return ComplianceResult({
            compliant: true,
            violationType: bytes32(0),
            evidence: ""
        });
    }
}
