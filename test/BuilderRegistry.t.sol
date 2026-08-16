// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BuilderRegistry} from "../src/builder/BuilderRegistry.sol";
import {FlashblocksBuilder} from "../src/builder/FlashblocksBuilder.sol";
import {IBuilderRegistry} from "../src/interfaces/IBuilderRegistry.sol";
import {IUniversalBuilder} from "../src/interfaces/IUniversalBuilder.sol";

/**
 * @title BuilderRegistryTest
 * @notice Tests for BuilderRegistry and FlashblocksBuilder.
 */
contract BuilderRegistryTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public randomUser = address(0x99);

    // ============ Contracts ============
    BuilderRegistry public registry;
    FlashblocksBuilder public flashblocks;

    // ============ Setup ============

    function setUp() public {
        registry = new BuilderRegistry(governance);
        flashblocks = new FlashblocksBuilder(governance, "http://localhost:8550");

        // Add chain support to flashblocks builder
        vm.startPrank(governance);
        flashblocks.addChainSupport(10);
        flashblocks.addChainSupport(42161);
        vm.stopPrank();
    }

    // ============ Builder Registration Tests ============

    function test_RegisterBuilder_Success() public {
        vm.prank(governance);
        registry.registerBuilder(address(flashblocks));

        IBuilderRegistry.BuilderInfo memory info = registry.getBuilder(address(flashblocks));
        assertEq(info.builder, address(flashblocks));
        assertTrue(info.isActive);
        assertEq(uint256(info.builderType), uint256(IUniversalBuilder.BuilderType.PrivateMempool));
    }

    function test_RegisterBuilder_RevertsIfNotGovernance() public {
        vm.prank(randomUser);
        vm.expectRevert(IBuilderRegistry.NotGovernance.selector);
        registry.registerBuilder(address(flashblocks));
    }

    function test_RegisterBuilder_RevertsIfAlreadyRegistered() public {
        vm.startPrank(governance);
        registry.registerBuilder(address(flashblocks));

        vm.expectRevert(IBuilderRegistry.BuilderAlreadyRegistered.selector);
        registry.registerBuilder(address(flashblocks));
        vm.stopPrank();
    }

    function test_RegisterBuilder_RevertsIfZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(IBuilderRegistry.InvalidBuilder.selector);
        registry.registerBuilder(address(0));
    }

    // ============ Builder Activation Tests ============

    function test_DeactivateBuilder_Success() public {
        vm.startPrank(governance);
        registry.registerBuilder(address(flashblocks));
        registry.deactivateBuilder(address(flashblocks));
        vm.stopPrank();

        assertFalse(registry.isActiveBuilder(address(flashblocks)));
    }

    function test_ActivateBuilder_Success() public {
        vm.startPrank(governance);
        registry.registerBuilder(address(flashblocks));
        registry.deactivateBuilder(address(flashblocks));
        registry.activateBuilder(address(flashblocks));
        vm.stopPrank();

        assertTrue(registry.isActiveBuilder(address(flashblocks)));
    }

    // ============ Default Builder Tests ============

    function test_SetDefaultBuilder_Success() public {
        vm.startPrank(governance);
        registry.registerBuilder(address(flashblocks));
        registry.setDefaultBuilder(address(flashblocks));
        vm.stopPrank();

        assertEq(registry.getDefaultBuilder(), address(flashblocks));
    }

    function test_SetDefaultBuilder_RevertsIfNotRegistered() public {
        vm.prank(governance);
        vm.expectRevert(IBuilderRegistry.BuilderNotRegistered.selector);
        registry.setDefaultBuilder(address(0x999));
    }

    // ============ Chain Builder Tests ============

    function test_SetChainBuilder_Success() public {
        vm.startPrank(governance);
        registry.registerBuilder(address(flashblocks));
        registry.setChainBuilder(10, address(flashblocks));
        vm.stopPrank();

        assertEq(registry.getChainBuilder(10), address(flashblocks));
    }

    function test_GetEffectiveBuilder_ReturnsChainBuilder() public {
        vm.startPrank(governance);
        registry.registerBuilder(address(flashblocks));
        registry.setDefaultBuilder(address(flashblocks));

        // Create a second builder
        FlashblocksBuilder builder2 = new FlashblocksBuilder(governance, "http://localhost:8551");
        registry.registerBuilder(address(builder2));
        registry.setChainBuilder(10, address(builder2));
        vm.stopPrank();

        // Chain 10 should return builder2, not default
        assertEq(registry.getEffectiveBuilder(10), address(builder2));
        // Chain 42161 has no override, returns default
        assertEq(registry.getEffectiveBuilder(42161), address(flashblocks));
    }

    // ============ Active Builders Tests ============

    function test_GetActiveBuilders_ReturnsOnlyActive() public {
        FlashblocksBuilder builder2 = new FlashblocksBuilder(governance, "http://localhost:8551");

        vm.startPrank(governance);
        registry.registerBuilder(address(flashblocks));
        registry.registerBuilder(address(builder2));
        registry.deactivateBuilder(address(builder2));
        vm.stopPrank();

        address[] memory active = registry.getActiveBuilders();
        assertEq(active.length, 1);
        assertEq(active[0], address(flashblocks));
    }

    // ============ FlashblocksBuilder Tests ============

    function test_Flashblocks_BuilderType() public view {
        assertEq(
            uint256(flashblocks.builderType()),
            uint256(IUniversalBuilder.BuilderType.PrivateMempool)
        );
    }

    function test_Flashblocks_Version() public view {
        assertEq(flashblocks.version(), 1_000_000);
    }

    function test_Flashblocks_SupportsChain() public view {
        assertTrue(flashblocks.supportsChain(10));
        assertTrue(flashblocks.supportsChain(42161));
        assertFalse(flashblocks.supportsChain(999));
    }

    function test_Flashblocks_ValidateBuildRequest_Valid() public view {
        bytes32[] memory bundles = new bytes32[](1);
        bundles[0] = keccak256("bundle1");

        IUniversalBuilder.BuildRequest memory request = IUniversalBuilder.BuildRequest({
            chainId: 10,
            parentHash: keccak256("parent"),
            timestamp: block.timestamp + 1,
            gasLimit: 30_000_000,
            bundles: bundles,
            policyData: ""
        });

        (bool valid, string memory reason) = flashblocks.validateBuildRequest(request);
        assertTrue(valid);
        assertEq(bytes(reason).length, 0);
    }

    function test_Flashblocks_ValidateBuildRequest_UnsupportedChain() public view {
        bytes32[] memory bundles = new bytes32[](0);

        IUniversalBuilder.BuildRequest memory request = IUniversalBuilder.BuildRequest({
            chainId: 999,
            parentHash: keccak256("parent"),
            timestamp: block.timestamp + 1,
            gasLimit: 30_000_000,
            bundles: bundles,
            policyData: ""
        });

        (bool valid, string memory reason) = flashblocks.validateBuildRequest(request);
        assertFalse(valid);
        assertEq(reason, "Chain not supported by this builder");
    }

    function test_Flashblocks_ValidateBuildRequest_GasTooLow() public view {
        bytes32[] memory bundles = new bytes32[](0);

        IUniversalBuilder.BuildRequest memory request = IUniversalBuilder.BuildRequest({
            chainId: 10,
            parentHash: keccak256("parent"),
            timestamp: block.timestamp + 1,
            gasLimit: 100,
            bundles: bundles,
            policyData: ""
        });

        (bool valid, string memory reason) = flashblocks.validateBuildRequest(request);
        assertFalse(valid);
        assertEq(reason, "Gas limit below minimum");
    }

    function test_Flashblocks_AddRemoveChainSupport() public {
        vm.startPrank(governance);
        flashblocks.addChainSupport(8453);
        assertTrue(flashblocks.supportsChain(8453));

        flashblocks.removeChainSupport(8453);
        assertFalse(flashblocks.supportsChain(8453));
        vm.stopPrank();
    }

    function test_Flashblocks_SetRelayEndpoint() public {
        vm.prank(governance);
        flashblocks.setRelayEndpoint("http://new-relay:8550");

        assertEq(flashblocks.relayEndpoint(), "http://new-relay:8550");
    }
}
