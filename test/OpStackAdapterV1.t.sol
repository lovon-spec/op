// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {OpStackAdapterV1} from "../src/poc/opstack/OpStackAdapterV1.sol";
import {ISystemConfig} from "../src/poc/opstack/interfaces/ISystemConfig.sol";
import {MockSystemConfig} from "./mocks/MockSystemConfig.sol";

/**
 * @title OpStackAdapterV1Test
 * @notice Comprehensive unit tests for OpStackAdapterV1 contract.
 *
 * Tests cover:
 * - Version and metadata functions
 * - Rotation calldata generation
 * - Error cases (invalid inputs)
 * - BatcherHash format validation
 * - Hub-executed rotation via returned calldata
 */
contract OpStackAdapterV1Test is Test {
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig;

    address public batcher = address(0x100);
    address public unsafeSigner = address(0x200);

    function setUp() public {
        // Deploy adapter
        adapter = new OpStackAdapterV1();

        // Deploy mock SystemConfig - this test contract is the initial owner
        systemConfig = new MockSystemConfig();
    }

    // ============ Version Tests ============

    function test_Version_ReturnsCorrectValue() public view {
        assertEq(adapter.version(), 1_000_000);
    }

    function test_Version_Constant() public view {
        assertEq(adapter.VERSION(), 1_000_000);
    }

    // ============ Adapter Info Tests ============

    function test_AdapterInfo_ReturnsCorrectName() public view {
        (string memory name, ) = adapter.adapterInfo();
        assertEq(name, "OpStackAdapterV1");
    }

    function test_AdapterInfo_ReturnsCorrectDescription() public view {
        (, string memory description) = adapter.adapterInfo();
        assertEq(description, "OP Stack Bedrock/Ecotone sequencer rotation adapter");
    }

    function test_Name_Constant() public view {
        assertEq(adapter.NAME(), "OpStackAdapterV1");
    }

    function test_Description_Constant() public view {
        assertEq(adapter.DESCRIPTION(), "OP Stack Bedrock/Ecotone sequencer rotation adapter");
    }

    // ============ Rotation Calldata Tests ============

    function test_GetRotationCalldata_ReturnsCorrectCalls() public view {
        bytes[] memory calls = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(batcher, unsafeSigner)
        );

        assertEq(calls.length, 2);

        // Verify first call is setBatcherHash
        bytes32 expectedBatcherHash = bytes32(uint256(uint160(batcher)));
        assertEq(calls[0], abi.encodeWithSelector(ISystemConfig.setBatcherHash.selector, expectedBatcherHash));

        // Verify second call is setUnsafeBlockSigner
        assertEq(calls[1], abi.encodeWithSelector(ISystemConfig.setUnsafeBlockSigner.selector, unsafeSigner));
    }

    function test_GetRotationCalldata_ExecutedByHub() public {
        // Simulate the Hub pattern: get calldata from adapter, execute against rollup config
        // This test contract acts as the Hub (owner of systemConfig)

        bytes[] memory calls = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(batcher, unsafeSigner)
        );

        // Execute calls against systemConfig (this contract is the owner)
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = address(systemConfig).call(calls[i]);
            assertTrue(success);
        }

        // Verify SystemConfig was updated
        bytes32 expectedBatcherHash = bytes32(uint256(uint160(batcher)));
        assertEq(systemConfig.batcherHash(), expectedBatcherHash);
        assertEq(systemConfig.unsafeBlockSigner(), unsafeSigner);
    }

    function test_GetRotationCalldata_BatcherHashFormat() public {
        bytes[] memory calls = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(batcher, unsafeSigner)
        );

        // Execute to verify batcher hash format
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = address(systemConfig).call(calls[i]);
            assertTrue(success);
        }

        bytes32 batcherHash = systemConfig.batcherHash();

        // V0 format: bytes32(uint256(uint160(address)))
        assertEq(batcherHash, bytes32(uint256(uint160(batcher))));

        // Verify we can extract the original address
        address extracted = address(uint160(uint256(batcherHash)));
        assertEq(extracted, batcher);
    }

    function test_GetRotationCalldata_DifferentAddresses() public {
        address batcher1 = address(0x1111);
        address signer1 = address(0x2222);
        address batcher2 = address(0x3333);
        address signer2 = address(0x4444);

        // First rotation
        bytes[] memory calls1 = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(batcher1, signer1)
        );
        for (uint256 i = 0; i < calls1.length; i++) {
            (bool success, ) = address(systemConfig).call(calls1[i]);
            assertTrue(success);
        }

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(batcher1))));
        assertEq(systemConfig.unsafeBlockSigner(), signer1);

        // Second rotation
        bytes[] memory calls2 = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(batcher2, signer2)
        );
        for (uint256 i = 0; i < calls2.length; i++) {
            (bool success, ) = address(systemConfig).call(calls2[i]);
            assertTrue(success);
        }

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(batcher2))));
        assertEq(systemConfig.unsafeBlockSigner(), signer2);
    }

    function test_GetRotationCalldata_SameBatcherAndSigner() public {
        address combined = address(0x5555);

        bytes[] memory calls = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(combined, combined)
        );

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = address(systemConfig).call(calls[i]);
            assertTrue(success);
        }

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(combined))));
        assertEq(systemConfig.unsafeBlockSigner(), combined);
    }

    // ============ Error Tests ============

    function test_GetRotationCalldata_RevertZeroSystemConfig() public {
        vm.expectRevert(OpStackAdapterV1.InvalidSystemConfig.selector);
        adapter.getRotationCalldata(address(0), abi.encode(batcher, unsafeSigner));
    }

    function test_GetRotationCalldata_RevertZeroBatcher() public {
        vm.expectRevert(OpStackAdapterV1.InvalidOperatorKeys.selector);
        adapter.getRotationCalldata(address(systemConfig), abi.encode(address(0), unsafeSigner));
    }

    function test_GetRotationCalldata_RevertZeroSigner() public {
        vm.expectRevert(OpStackAdapterV1.InvalidOperatorKeys.selector);
        adapter.getRotationCalldata(address(systemConfig), abi.encode(batcher, address(0)));
    }

    function test_GetRotationCalldata_RevertBothZero() public {
        vm.expectRevert(OpStackAdapterV1.InvalidOperatorKeys.selector);
        adapter.getRotationCalldata(address(systemConfig), abi.encode(address(0), address(0)));
    }

    function test_GetRotationCalldata_RevertNotOwner() public {
        // Create a SystemConfig owned by someone else
        MockSystemConfig otherConfig = new MockSystemConfig();

        // Get calldata (this succeeds - adapter just returns calldata)
        bytes[] memory calls = adapter.getRotationCalldata(
            address(otherConfig),
            abi.encode(batcher, unsafeSigner)
        );

        // Execute from a non-owner address - should fail at the rollup config level
        vm.prank(address(0xDEAD));
        (bool success, ) = address(otherConfig).call(calls[0]);
        assertFalse(success);
    }

    // ============ Hub Pattern Tests ============

    function test_GetRotationCalldata_HubPatternPreservesOwnership() public {
        // Simulate the full Hub pattern:
        // 1. Hub (HubCaller) owns the systemConfig
        // 2. Hub calls adapter.getRotationCalldata() (regular call)
        // 3. Hub executes returned calldata against systemConfig

        MockSystemConfig hubOwnedConfig = new MockSystemConfig();
        HubCaller hubCaller = new HubCaller(address(adapter));
        hubOwnedConfig.transferOwnership(address(hubCaller));

        // Hub executes the rotation
        hubCaller.executeRotation(address(hubOwnedConfig), batcher, unsafeSigner);

        // Verify the rotation worked
        assertEq(hubOwnedConfig.batcherHash(), bytes32(uint256(uint160(batcher))));
        assertEq(hubOwnedConfig.unsafeBlockSigner(), unsafeSigner);
    }

    function test_GetRotationCalldata_AdapterCannotModifyHubStorage() public {
        // This test verifies the security improvement: adapter is called via
        // regular `call` (view function), so it cannot modify caller storage.
        // The adapter just returns data - no delegatecall involved.

        HubCaller hubCaller = new HubCaller(address(adapter));
        uint256 valueBefore = hubCaller.safetyCheck();

        MockSystemConfig hubOwnedConfig = new MockSystemConfig();
        hubOwnedConfig.transferOwnership(address(hubCaller));
        hubCaller.executeRotation(address(hubOwnedConfig), batcher, unsafeSigner);

        // Hub's storage is unchanged (adapter couldn't modify it)
        assertEq(hubCaller.safetyCheck(), valueBefore);
    }

    // ============ Fuzz Tests ============

    function testFuzz_GetRotationCalldata(address _batcher, address _signer) public {
        vm.assume(_batcher != address(0));
        vm.assume(_signer != address(0));

        bytes[] memory calls = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(_batcher, _signer)
        );

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = address(systemConfig).call(calls[i]);
            assertTrue(success);
        }

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(_batcher))));
        assertEq(systemConfig.unsafeBlockSigner(), _signer);
    }

    function testFuzz_BatcherHashConversion(address _batcher) public {
        vm.assume(_batcher != address(0));

        bytes[] memory calls = adapter.getRotationCalldata(
            address(systemConfig),
            abi.encode(_batcher, unsafeSigner)
        );

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = address(systemConfig).call(calls[i]);
            assertTrue(success);
        }

        bytes32 batcherHash = systemConfig.batcherHash();
        address extracted = address(uint160(uint256(batcherHash)));

        assertEq(extracted, _batcher);
    }

    // ============ Interface Compliance Tests ============

    function test_ImplementsISequencerAdapter() public view {
        // Verify the adapter implements all required interface functions
        adapter.version();
        adapter.adapterInfo();
        // getRotationCalldata is tested above
    }
}

/**
 * @title InvalidSystemConfig
 * @notice Mock that doesn't implement the required interface.
 */
contract InvalidSystemConfig {
    // Empty contract - will revert on any call
}

/**
 * @title HubCaller
 * @notice Helper contract to test the Hub call pattern (replacing old DelegatecallCaller).
 * @dev Simulates how SharedSequencerHub calls adapters: regular call to get calldata,
 *      then execute calldata against the rollup config.
 */
contract HubCaller {
    address public immutable adapter;
    uint256 public safetyCheck = 42; // Used to verify adapter can't modify our storage

    constructor(address _adapter) {
        adapter = _adapter;
    }

    function executeRotation(
        address _systemConfig,
        address _batcher,
        address _unsafeSigner
    ) external {
        // Step 1: Call adapter (regular call) to get rotation calldata
        bytes[] memory calls = OpStackAdapterV1(adapter).getRotationCalldata(
            _systemConfig,
            abi.encode(_batcher, _unsafeSigner)
        );

        // Step 2: Execute each call against the rollup config
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = _systemConfig.call(calls[i]);
            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        revert(add(returnData, 32), mload(returnData))
                    }
                }
                revert("Call failed");
            }
        }
    }
}
