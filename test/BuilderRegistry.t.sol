// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BuilderRegistry} from "../src/BuilderRegistry.sol";
import {IBuilderRegistry} from "../src/interfaces/IBuilderRegistry.sol";

/**
 * @title BuilderRegistryTest
 * @notice Tests for the BuilderRegistry contract.
 * @dev Tests policy tags, sovereignty matrix, bond management, and slashing.
 */
contract BuilderRegistryTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public hub = address(0x2);
    address public builder1 = address(0x10);
    address public builder2 = address(0x11);
    address public builder3 = address(0x12);
    address public randomUser = address(0x99);

    // ============ Contracts ============
    BuilderRegistry public registry;

    // ============ Constants ============
    uint256 public constant MIN_BOND = 500 ether;

    // ============ Cached Policy IDs ============
    // Cached to avoid external calls consuming vm.prank
    bytes32 public POLICY_OFAC;
    bytes32 public POLICY_KYC;
    bytes32 public POLICY_NEUTRAL;
    bytes32 public POLICY_NO_MEV;

    // ============ Setup ============

    function setUp() public {
        registry = new BuilderRegistry(governance, hub, MIN_BOND);

        // Cache policy IDs to avoid external calls consuming vm.prank
        POLICY_OFAC = registry.POLICY_OFAC();
        POLICY_KYC = registry.POLICY_KYC();
        POLICY_NEUTRAL = registry.POLICY_NEUTRAL();
        POLICY_NO_MEV = registry.POLICY_NO_MEV();

        // Fund test accounts
        vm.deal(builder1, 1000 ether);
        vm.deal(builder2, 1000 ether);
        vm.deal(builder3, 1000 ether);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialValues() public view {
        assertEq(registry.governance(), governance);
        assertEq(registry.hub(), hub);
        assertEq(registry.minimumBond(), MIN_BOND);
        assertEq(registry.slashCooldown(), 7 days);
    }

    function test_Constructor_RegistersDefaultPolicies() public view {
        assertTrue(registry.isPolicyRegistered(POLICY_OFAC));
        assertTrue(registry.isPolicyRegistered(POLICY_KYC));
        assertTrue(registry.isPolicyRegistered(POLICY_NO_MEV));
        assertTrue(registry.isPolicyRegistered(registry.POLICY_NO_GAMBLING()));
        assertTrue(registry.isPolicyRegistered(POLICY_NEUTRAL));
    }

    function test_Constructor_UsesDefaults() public {
        BuilderRegistry defaultRegistry = new BuilderRegistry(governance, hub, 0);
        assertEq(defaultRegistry.minimumBond(), 500 ether);
    }

    // ============ Registration Tests ============

    function test_Register_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        IBuilderRegistry.BuilderInfo memory info = registry.getBuilderInfo(builder1);
        assertEq(info.bond, MIN_BOND);
        assertTrue(info.isActive);
        assertEq(info.slashCount, 0);
    }

    function test_Register_GrantsNeutralPolicy() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        assertTrue(registry.hasPolicyTag(builder1, POLICY_NEUTRAL));
    }

    function test_Register_RevertsIfInsufficientBond() public {
        vm.prank(builder1);
        vm.expectRevert(
            abi.encodeWithSelector(IBuilderRegistry.InsufficientBond.selector, 1 ether, MIN_BOND)
        );
        registry.register{value: 1 ether}();
    }

    function test_Register_RevertsIfAlreadyRegistered() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(builder1);
        vm.expectRevert(abi.encodeWithSelector(IBuilderRegistry.BuilderAlreadyRegistered.selector, builder1));
        registry.register{value: MIN_BOND}();
    }

    // ============ Unregister Tests ============

    function test_Unregister_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        uint256 balanceBefore = builder1.balance;

        vm.prank(builder1);
        registry.unregister();

        assertEq(builder1.balance, balanceBefore + MIN_BOND);
        assertFalse(registry.isRegistered(builder1));
    }

    function test_Unregister_RevertsIfNotRegistered() public {
        vm.prank(builder1);
        vm.expectRevert(abi.encodeWithSelector(IBuilderRegistry.BuilderNotRegistered.selector, builder1));
        registry.unregister();
    }

    function test_Unregister_RevertsIfInCooldown() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        // Slash the builder to trigger cooldown
        vm.prank(hub);
        registry.slash(builder1, 1 ether, POLICY_NEUTRAL, "test");

        vm.prank(builder1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBuilderRegistry.BuilderInCooldown.selector,
                builder1,
                block.timestamp + 7 days
            )
        );
        registry.unregister();
    }

    // ============ Bond Management Tests ============

    function test_AddBond_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(builder1);
        registry.addBond{value: 100 ether}();

        IBuilderRegistry.BuilderInfo memory info = registry.getBuilderInfo(builder1);
        assertEq(info.bond, MIN_BOND + 100 ether);
    }

    function test_AddBond_RevertsIfNotRegistered() public {
        vm.prank(builder1);
        vm.expectRevert(abi.encodeWithSelector(IBuilderRegistry.BuilderNotRegistered.selector, builder1));
        registry.addBond{value: 100 ether}();
    }

    function test_WithdrawBond_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND + 100 ether}();

        uint256 balanceBefore = builder1.balance;

        vm.prank(builder1);
        registry.withdrawBond(50 ether);

        assertEq(builder1.balance, balanceBefore + 50 ether);
        IBuilderRegistry.BuilderInfo memory info = registry.getBuilderInfo(builder1);
        assertEq(info.bond, MIN_BOND + 50 ether);
    }

    function test_WithdrawBond_RevertsIfBelowMinimum() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(builder1);
        vm.expectRevert(
            abi.encodeWithSelector(IBuilderRegistry.InsufficientBond.selector, MIN_BOND - 1 ether, MIN_BOND)
        );
        registry.withdrawBond(1 ether);
    }

    // ============ Policy Tag Tests ============

    function test_GrantPolicyTag_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(governance);
        registry.grantPolicyTag(builder1, POLICY_OFAC, 0);

        assertTrue(registry.hasPolicyTag(builder1, POLICY_OFAC));
    }

    function test_GrantPolicyTag_WithExpiry() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        uint256 expiryTime = block.timestamp + 1 days;

        vm.prank(governance);
        registry.grantPolicyTag(builder1, POLICY_OFAC, expiryTime);

        assertTrue(registry.hasPolicyTag(builder1, POLICY_OFAC));

        // Fast forward past expiry
        vm.warp(expiryTime + 1);

        assertFalse(registry.hasPolicyTag(builder1, POLICY_OFAC));
    }

    function test_GrantPolicyTag_RevertsIfNotRegistered() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IBuilderRegistry.BuilderNotRegistered.selector, builder1));
        registry.grantPolicyTag(builder1, POLICY_OFAC, 0);
    }

    function test_GrantPolicyTag_RevertsIfInvalidPolicy() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        bytes32 invalidPolicy = keccak256("INVALID_POLICY");

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IBuilderRegistry.InvalidPolicyTag.selector, invalidPolicy));
        registry.grantPolicyTag(builder1, invalidPolicy, 0);
    }

    function test_RevokePolicyTag_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(governance);
        registry.grantPolicyTag(builder1, POLICY_OFAC, 0);

        vm.prank(governance);
        registry.revokePolicyTag(builder1, POLICY_OFAC, "Compliance failure");

        assertFalse(registry.hasPolicyTag(builder1, POLICY_OFAC));
    }

    function test_RevokePolicyTag_RevertsIfNotGranted() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(IBuilderRegistry.MissingPolicyTag.selector, builder1, POLICY_OFAC)
        );
        registry.revokePolicyTag(builder1, POLICY_OFAC, "test");
    }

    // ============ Eligibility Tests ============

    function test_IsBuilderEligible_ReturnsTrueForNeutral() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        assertTrue(registry.isBuilderEligible(builder1, POLICY_NEUTRAL));
    }

    function test_IsBuilderEligible_ReturnsFalseIfNotActive() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(governance);
        registry.deactivate(builder1, "test");

        assertFalse(registry.isBuilderEligible(builder1, POLICY_NEUTRAL));
    }

    function test_IsBuilderEligible_ReturnsFalseIfMissingTag() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        assertFalse(registry.isBuilderEligible(builder1, POLICY_OFAC));
    }

    function test_IsBuilderEligible_ReturnsFalseIfInCooldown() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(hub);
        registry.slash(builder1, 1 ether, POLICY_NEUTRAL, "test");

        assertFalse(registry.isBuilderEligible(builder1, POLICY_NEUTRAL));
    }

    function test_IsBuilderEligibleForBundle_UnionRule() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        // Grant OFAC and KYC tags
        vm.startPrank(governance);
        registry.grantPolicyTag(builder1, POLICY_OFAC, 0);
        registry.grantPolicyTag(builder1, POLICY_KYC, 0);
        vm.stopPrank();

        // Should be eligible for bundle requiring both OFAC and KYC
        bytes32[] memory policies = new bytes32[](2);
        policies[0] = POLICY_OFAC;
        policies[1] = POLICY_KYC;

        assertTrue(registry.isBuilderEligibleForBundle(builder1, policies));
    }

    function test_IsBuilderEligibleForBundle_FailsIfMissingOneTag() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        // Only grant OFAC tag
        vm.prank(governance);
        registry.grantPolicyTag(builder1, POLICY_OFAC, 0);

        // Should NOT be eligible for bundle requiring OFAC and KYC
        bytes32[] memory policies = new bytes32[](2);
        policies[0] = POLICY_OFAC;
        policies[1] = POLICY_KYC;

        assertFalse(registry.isBuilderEligibleForBundle(builder1, policies));
    }

    function test_IsBuilderEligibleForBundle_NeutralPolicySkipped() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        // Only has NEUTRAL (default) and we add OFAC
        vm.prank(governance);
        registry.grantPolicyTag(builder1, POLICY_OFAC, 0);

        // Bundle with NEUTRAL should work
        bytes32[] memory policies = new bytes32[](2);
        policies[0] = POLICY_NEUTRAL;
        policies[1] = POLICY_OFAC;

        assertTrue(registry.isBuilderEligibleForBundle(builder1, policies));
    }

    // ============ Slashing Tests ============

    function test_Slash_ReducesBond() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(hub);
        registry.slash(builder1, 100 ether, POLICY_OFAC, "OFAC violation");

        IBuilderRegistry.BuilderInfo memory info = registry.getBuilderInfo(builder1);
        assertEq(info.bond, MIN_BOND - 100 ether);
        assertEq(info.slashCount, 1);
    }

    function test_Slash_RevertsIfExceedsBond() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(hub);
        vm.expectRevert(
            abi.encodeWithSelector(IBuilderRegistry.SlashExceedsBond.selector, MIN_BOND + 1 ether, MIN_BOND)
        );
        registry.slash(builder1, MIN_BOND + 1 ether, POLICY_OFAC, "test");
    }

    function test_Slash_AutoDeactivatesAfterMaxSlashes() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        // Slash 3 times (MAX_SLASH_COUNT)
        vm.startPrank(hub);
        registry.slash(builder1, 1 ether, POLICY_OFAC, "slash 1");

        // Need to wait for cooldown between slashes for this test to work
        vm.warp(block.timestamp + 7 days + 1);
        registry.slash(builder1, 1 ether, POLICY_OFAC, "slash 2");

        vm.warp(block.timestamp + 7 days + 1);
        registry.slash(builder1, 1 ether, POLICY_OFAC, "slash 3");
        vm.stopPrank();

        IBuilderRegistry.BuilderInfo memory info = registry.getBuilderInfo(builder1);
        assertFalse(info.isActive);
        assertEq(info.slashCount, 3);
    }

    // ============ Deactivate/Reactivate Tests ============

    function test_Deactivate_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(governance);
        registry.deactivate(builder1, "Manual deactivation");

        IBuilderRegistry.BuilderInfo memory info = registry.getBuilderInfo(builder1);
        assertFalse(info.isActive);
    }

    function test_Deactivate_RevertsIfNotAuthorized() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(randomUser);
        vm.expectRevert(IBuilderRegistry.Unauthorized.selector);
        registry.deactivate(builder1, "test");
    }

    function test_Reactivate_Success() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(governance);
        registry.deactivate(builder1, "test");

        vm.prank(governance);
        registry.reactivate(builder1);

        IBuilderRegistry.BuilderInfo memory info = registry.getBuilderInfo(builder1);
        assertTrue(info.isActive);
    }

    // ============ Policy Registration Tests ============

    function test_RegisterPolicy_Success() public {
        bytes32 newPolicy = keccak256("CUSTOM_POLICY");

        vm.prank(governance);
        registry.registerPolicy(newPolicy, "Custom Policy", "A custom policy for testing");

        assertTrue(registry.isPolicyRegistered(newPolicy));

        (string memory name, string memory desc) = registry.getPolicyInfo(newPolicy);
        assertEq(name, "Custom Policy");
        assertEq(desc, "A custom policy for testing");
    }

    function test_RegisterPolicy_RevertsIfNotGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert(IBuilderRegistry.Unauthorized.selector);
        registry.registerPolicy(keccak256("TEST"), "Test", "Test");
    }

    // ============ Governance Tests ============

    function test_SetMinimumBond_Success() public {
        vm.prank(governance);
        registry.setMinimumBond(1000 ether);

        assertEq(registry.minimumBond(), 1000 ether);
    }

    function test_SetHub_Success() public {
        address newHub = address(0x777);

        vm.prank(governance);
        registry.setHub(newHub);

        assertEq(registry.hub(), newHub);
    }

    function test_SetSlashCooldown_Success() public {
        vm.prank(governance);
        registry.setSlashCooldown(14 days);

        assertEq(registry.slashCooldown(), 14 days);
    }

    function test_SetGovernance_Success() public {
        address newGovernance = address(0x888);

        vm.prank(governance);
        registry.setGovernance(newGovernance);

        assertEq(registry.governance(), newGovernance);
    }

    // ============ View Function Tests ============

    function test_GetBuildersForPolicy_ReturnsEligibleBuilders() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(builder2);
        registry.register{value: MIN_BOND}();

        // Grant OFAC only to builder1
        vm.prank(governance);
        registry.grantPolicyTag(builder1, POLICY_OFAC, 0);

        address[] memory builders = registry.getBuildersForPolicy(POLICY_OFAC);
        assertEq(builders.length, 1);
        assertEq(builders[0], builder1);
    }

    function test_GetActiveBuilders_ReturnsActiveOnly() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        vm.prank(builder2);
        registry.register{value: MIN_BOND}();

        vm.prank(governance);
        registry.deactivate(builder2, "test");

        address[] memory active = registry.getActiveBuilders();
        assertEq(active.length, 1);
        assertEq(active[0], builder1);
    }

    function test_IsInCooldown_ReturnsCorrectStatus() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        assertFalse(registry.isInCooldown(builder1));

        vm.prank(hub);
        registry.slash(builder1, 1 ether, POLICY_NEUTRAL, "test");

        assertTrue(registry.isInCooldown(builder1));

        vm.warp(block.timestamp + 7 days + 1);

        assertFalse(registry.isInCooldown(builder1));
    }

    function test_GetCooldownEnd_ReturnsCorrectTime() public {
        vm.prank(builder1);
        registry.register{value: MIN_BOND}();

        assertEq(registry.getCooldownEnd(builder1), 0);

        uint256 slashTime = block.timestamp;
        vm.prank(hub);
        registry.slash(builder1, 1 ether, POLICY_NEUTRAL, "test");

        assertEq(registry.getCooldownEnd(builder1), slashTime + 7 days);
    }

    // ============ Receive Tests ============

    function test_ReceiveEth_Accepts() public {
        (bool success, ) = address(registry).call{value: 1 ether}("");
        assertTrue(success);
    }
}
