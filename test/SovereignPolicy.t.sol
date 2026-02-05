// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SovereignPolicyManager} from "../src/policy/SovereignPolicyManager.sol";
import {DefaultPolicy} from "../src/policy/DefaultPolicy.sol";
import {ISovereignPolicy} from "../src/interfaces/ISovereignPolicy.sol";

/**
 * @title SovereignPolicyTest
 * @notice Tests for SovereignPolicyManager and DefaultPolicy.
 */
contract SovereignPolicyTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public hubAddr = address(0x2);
    address public chainGovernor1 = address(0x10);
    address public chainGovernor2 = address(0x11);
    address public randomUser = address(0x99);

    // ============ Contracts ============
    SovereignPolicyManager public policyManager;
    DefaultPolicy public defaultPolicy;

    // ============ Constants ============
    uint256 public constant CHAIN_ID_OP = 10;
    uint256 public constant CHAIN_ID_ARB = 42161;

    // ============ Setup ============

    function setUp() public {
        policyManager = new SovereignPolicyManager(governance, hubAddr);
        defaultPolicy = new DefaultPolicy();

        // Set chain governance
        vm.startPrank(governance);
        policyManager.setChainGovernance(CHAIN_ID_OP, chainGovernor1);
        policyManager.setChainGovernance(CHAIN_ID_ARB, chainGovernor2);
        vm.stopPrank();
    }

    // ============ Policy Declaration Tests ============

    function test_DeclarePolicy_Success() public {
        vm.prank(chainGovernor1);
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.FCFS,
            ISovereignPolicy.EnforcementType.Hybrid,
            2 seconds,
            30 seconds,
            true, // sandwich protection
            true, // backrun only
            address(0),
            ""
        );

        ISovereignPolicy.PolicyDeclaration memory policy = policyManager.getPolicy(CHAIN_ID_OP);
        assertEq(policy.chainId, CHAIN_ID_OP);
        assertEq(uint256(policy.orderingStrategy), uint256(ISovereignPolicy.OrderingStrategy.FCFS));
        assertEq(uint256(policy.enforcementType), uint256(ISovereignPolicy.EnforcementType.Hybrid));
        assertEq(policy.maxBlockTime, 2 seconds);
        assertEq(policy.forcedInclusionDeadline, 30 seconds);
        assertTrue(policy.sandwichProtection);
        assertTrue(policy.backrunOnly);
        assertTrue(policy.isActive);
    }

    function test_DeclarePolicy_RevertsIfNotChainGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert("Not chain governance");
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.FCFS,
            ISovereignPolicy.EnforcementType.Deterministic,
            2 seconds,
            0,
            false,
            false,
            address(0),
            ""
        );
    }

    function test_DeclarePolicy_HubGovernanceCanSetAnyChain() public {
        vm.prank(governance);
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.PriorityFee,
            ISovereignPolicy.EnforcementType.Deterministic,
            12 seconds,
            0,
            false,
            false,
            address(0),
            ""
        );

        ISovereignPolicy.PolicyDeclaration memory policy = policyManager.getPolicy(CHAIN_ID_OP);
        assertEq(
            uint256(policy.orderingStrategy),
            uint256(ISovereignPolicy.OrderingStrategy.PriorityFee)
        );
    }

    function test_DeclarePolicy_UsesDefaultMaxBlockTime() public {
        vm.prank(chainGovernor1);
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.SequencerDiscretion,
            ISovereignPolicy.EnforcementType.Hybrid,
            0, // should use default (12 seconds)
            0,
            false,
            false,
            address(0),
            ""
        );

        ISovereignPolicy.PolicyDeclaration memory policy = policyManager.getPolicy(CHAIN_ID_OP);
        assertEq(policy.maxBlockTime, 12 seconds);
    }

    // ============ Policy Status Tests ============

    function test_IsPolicyActive_ReturnsTrueWhenDeclared() public {
        vm.prank(chainGovernor1);
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.FCFS,
            ISovereignPolicy.EnforcementType.Deterministic,
            2 seconds,
            30 seconds,
            true,
            false,
            address(0),
            ""
        );

        assertTrue(policyManager.isPolicyActive(CHAIN_ID_OP));
    }

    function test_IsPolicyActive_ReturnsFalseWhenNotDeclared() public view {
        assertFalse(policyManager.isPolicyActive(999));
    }

    // ============ Policy Deactivation Tests ============

    function test_DeactivatePolicy_Success() public {
        vm.prank(chainGovernor1);
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.FCFS,
            ISovereignPolicy.EnforcementType.Deterministic,
            2 seconds,
            0,
            false,
            false,
            address(0),
            ""
        );

        assertTrue(policyManager.isPolicyActive(CHAIN_ID_OP));

        vm.prank(chainGovernor1);
        policyManager.deactivatePolicy(CHAIN_ID_OP);

        assertFalse(policyManager.isPolicyActive(CHAIN_ID_OP));
    }

    // ============ Default Policy Tests ============

    function test_GetPolicy_ReturnsDefaultWhenNoDeclared() public view {
        ISovereignPolicy.PolicyDeclaration memory policy = policyManager.getPolicy(999);
        assertEq(policy.chainId, 999);
        assertEq(
            uint256(policy.orderingStrategy),
            uint256(ISovereignPolicy.OrderingStrategy.SequencerDiscretion)
        );
        assertFalse(policy.isActive);
    }

    // ============ Custom Policy Contract Tests ============

    function test_DeclarePolicy_WithCustomContract() public {
        vm.prank(chainGovernor1);
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.Custom,
            ISovereignPolicy.EnforcementType.Hybrid,
            2 seconds,
            30 seconds,
            true,
            true,
            address(defaultPolicy),
            ""
        );

        ISovereignPolicy.PolicyDeclaration memory policy = policyManager.getPolicy(CHAIN_ID_OP);
        assertEq(policy.customPolicyContract, address(defaultPolicy));
    }

    // ============ Compliance Check Tests ============

    function test_CheckCompliance_CompliantByDefault() public view {
        ISovereignPolicy.ComplianceResult memory result =
            policyManager.checkCompliance(999, "");
        assertTrue(result.compliant);
    }

    function test_CheckCompliance_DelegatesToCustomPolicy() public {
        vm.prank(chainGovernor1);
        policyManager.declarePolicy(
            CHAIN_ID_OP,
            ISovereignPolicy.OrderingStrategy.Custom,
            ISovereignPolicy.EnforcementType.Hybrid,
            2 seconds,
            0,
            true,
            true,
            address(defaultPolicy),
            ""
        );

        ISovereignPolicy.ComplianceResult memory result =
            policyManager.checkCompliance(CHAIN_ID_OP, "");
        assertTrue(result.compliant);
    }

    // ============ Active Policy Chains Tests ============

    function test_GetActivePolicyChains() public {
        vm.prank(chainGovernor1);
        policyManager.declarePolicy(
            CHAIN_ID_OP, ISovereignPolicy.OrderingStrategy.FCFS,
            ISovereignPolicy.EnforcementType.Deterministic, 2 seconds, 0, false, false, address(0), ""
        );

        vm.prank(chainGovernor2);
        policyManager.declarePolicy(
            CHAIN_ID_ARB, ISovereignPolicy.OrderingStrategy.PriorityFee,
            ISovereignPolicy.EnforcementType.Deterministic, 2 seconds, 0, false, false, address(0), ""
        );

        uint256[] memory chains = policyManager.getActivePolicyChains();
        assertEq(chains.length, 2);
    }

    // ============ Governance Tests ============

    function test_SetChainGovernance_Success() public {
        address newGov = address(0xABC);

        vm.prank(governance);
        policyManager.setChainGovernance(CHAIN_ID_OP, newGov);

        assertEq(policyManager.getChainGovernance(CHAIN_ID_OP), newGov);
    }

    function test_SetChainGovernance_RevertsIfNotGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert("Not governance");
        policyManager.setChainGovernance(CHAIN_ID_OP, address(0xABC));
    }

    // ============ DefaultPolicy Contract Tests ============

    function test_DefaultPolicy_GetPolicy() public view {
        ISovereignPolicy.PolicyDeclaration memory policy = defaultPolicy.getPolicy(10);
        assertEq(uint256(policy.orderingStrategy), uint256(ISovereignPolicy.OrderingStrategy.FCFS));
        assertTrue(policy.sandwichProtection);
        assertTrue(policy.backrunOnly);
        assertTrue(policy.isActive);
        assertEq(policy.maxBlockTime, 2 seconds);
    }

    function test_DefaultPolicy_CheckCompliance() public view {
        ISovereignPolicy.ComplianceResult memory result = defaultPolicy.checkCompliance(10, "");
        assertTrue(result.compliant);
    }

    // ============ Policy Info Tests ============

    function test_PolicyManager_Version() public view {
        assertEq(policyManager.version(), 1_000_000);
    }

    function test_PolicyManager_Info() public view {
        (string memory name, ) = policyManager.policyInfo();
        assertEq(name, "SovereignPolicyManager");
    }
}
