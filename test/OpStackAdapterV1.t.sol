// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {OpStackAdapterV1} from "../src/adapters/OpStackAdapterV1.sol";
import {IOpStackAdapter} from "../src/interfaces/IOpStackAdapter.sol";
import {MockSystemConfig} from "./mocks/MockSystemConfig.sol";

/**
 * @title OpStackAdapterV1Test
 * @notice Comprehensive unit tests for OpStackAdapterV1 contract.
 *
 * Tests cover:
 * - Version and metadata functions
 * - Sequencer rotation functionality
 * - Error cases (invalid inputs)
 * - BatcherHash format validation
 * - Event emission
 */
contract OpStackAdapterV1Test is Test {
    OpStackAdapterV1 public adapter;
    MockSystemConfig public systemConfig;

    address public batcher = address(0x100);
    address public unsafeSigner = address(0x200);

    // Events
    event SequencerRotated(
        address indexed systemConfig,
        address indexed batcher,
        address indexed unsafeSigner
    );

    function setUp() public {
        // Deploy adapter
        adapter = new OpStackAdapterV1();

        // Deploy mock SystemConfig - this test contract is the initial owner
        systemConfig = new MockSystemConfig();

        // Transfer ownership to the adapter for direct call tests.
        // When calling adapter.rotateSequencer() directly (not via delegatecall),
        // the adapter makes external calls to SystemConfig where msg.sender = adapter address.
        // In real usage, the adapter is called via delegatecall from the manager,
        // so msg.sender would be the manager (which owns SystemConfig).
        systemConfig.transferOwnership(address(adapter));
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

    // ============ Rotation Tests ============

    function test_RotateSequencer_Success() public {
        vm.expectEmit(true, true, true, false);
        emit SequencerRotated(address(systemConfig), batcher, unsafeSigner);

        // This contract is the owner of SystemConfig
        adapter.rotateSequencer(address(systemConfig), batcher, unsafeSigner);

        // Verify SystemConfig was updated
        bytes32 expectedBatcherHash = bytes32(uint256(uint160(batcher)));
        assertEq(systemConfig.batcherHash(), expectedBatcherHash);
        assertEq(systemConfig.unsafeBlockSigner(), unsafeSigner);
    }

    function test_RotateSequencer_BatcherHashFormat() public {
        // Test that batcher address is correctly converted to V0 hash format
        adapter.rotateSequencer(address(systemConfig), batcher, unsafeSigner);

        bytes32 batcherHash = systemConfig.batcherHash();

        // V0 format: bytes32(uint256(uint160(address)))
        // This means the address is right-aligned in the 32-byte value
        assertEq(batcherHash, bytes32(uint256(uint160(batcher))));

        // Verify we can extract the original address
        address extracted = address(uint160(uint256(batcherHash)));
        assertEq(extracted, batcher);
    }

    function test_RotateSequencer_DifferentAddresses() public {
        address batcher1 = address(0x1111);
        address signer1 = address(0x2222);
        address batcher2 = address(0x3333);
        address signer2 = address(0x4444);

        // First rotation
        adapter.rotateSequencer(address(systemConfig), batcher1, signer1);

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(batcher1))));
        assertEq(systemConfig.unsafeBlockSigner(), signer1);

        // Second rotation
        adapter.rotateSequencer(address(systemConfig), batcher2, signer2);

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(batcher2))));
        assertEq(systemConfig.unsafeBlockSigner(), signer2);
    }

    function test_RotateSequencer_SameBatcherAndSigner() public {
        // Test case where batcher and signer are the same address
        address combined = address(0x5555);

        adapter.rotateSequencer(address(systemConfig), combined, combined);

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(combined))));
        assertEq(systemConfig.unsafeBlockSigner(), combined);
    }

    // ============ Error Tests ============

    function test_RotateSequencer_RevertZeroSystemConfig() public {
        vm.expectRevert(IOpStackAdapter.InvalidSystemConfig.selector);
        adapter.rotateSequencer(address(0), batcher, unsafeSigner);
    }

    function test_RotateSequencer_RevertZeroBatcher() public {
        vm.expectRevert(IOpStackAdapter.InvalidOperatorKeys.selector);
        adapter.rotateSequencer(address(systemConfig), address(0), unsafeSigner);
    }

    function test_RotateSequencer_RevertZeroSigner() public {
        vm.expectRevert(IOpStackAdapter.InvalidOperatorKeys.selector);
        adapter.rotateSequencer(address(systemConfig), batcher, address(0));
    }

    function test_RotateSequencer_RevertBothZero() public {
        vm.expectRevert(IOpStackAdapter.InvalidOperatorKeys.selector);
        adapter.rotateSequencer(address(systemConfig), address(0), address(0));
    }

    function test_RotateSequencer_RevertNotOwner() public {
        // Create a separate SystemConfig owned by someone else
        MockSystemConfig otherConfig = new MockSystemConfig();
        // otherConfig is owned by this test contract, not the adapter

        // When adapter calls otherConfig, msg.sender = adapter (not owner)
        // The adapter wraps the error in RotationFailed
        vm.expectRevert(
            abi.encodeWithSelector(
                IOpStackAdapter.RotationFailed.selector,
                "SystemConfig: caller is not the owner"
            )
        );
        adapter.rotateSequencer(address(otherConfig), batcher, unsafeSigner);
    }

    function test_RotateSequencer_RevertInvalidSystemConfig() public {
        // Create a contract that doesn't implement the required functions
        address invalidConfig = address(new InvalidSystemConfig());

        vm.expectRevert();
        adapter.rotateSequencer(invalidConfig, batcher, unsafeSigner);
    }

    // ============ Delegatecall Context Tests ============

    function test_RotateSequencer_WorksViaDelegatecall() public {
        // Simulate how SharedSequencerHub calls the adapter via delegatecall
        // The manager must be the owner of SystemConfig

        // Create a fresh SystemConfig for this test
        MockSystemConfig delegatecallConfig = new MockSystemConfig();

        // Create caller and transfer ownership to it
        DelegatecallCaller caller = new DelegatecallCaller(address(adapter));
        delegatecallConfig.transferOwnership(address(caller));

        // Execute rotation via delegatecall
        // When using delegatecall, msg.sender is preserved as the caller
        caller.executeRotation(address(delegatecallConfig), batcher, unsafeSigner);

        // Verify the rotation worked
        assertEq(delegatecallConfig.batcherHash(), bytes32(uint256(uint160(batcher))));
        assertEq(delegatecallConfig.unsafeBlockSigner(), unsafeSigner);
    }

    // ============ Fuzz Tests ============

    function testFuzz_RotateSequencer(address _batcher, address _signer) public {
        vm.assume(_batcher != address(0));
        vm.assume(_signer != address(0));

        adapter.rotateSequencer(address(systemConfig), _batcher, _signer);

        assertEq(systemConfig.batcherHash(), bytes32(uint256(uint160(_batcher))));
        assertEq(systemConfig.unsafeBlockSigner(), _signer);
    }

    function testFuzz_BatcherHashConversion(address _batcher) public {
        vm.assume(_batcher != address(0));

        adapter.rotateSequencer(address(systemConfig), _batcher, unsafeSigner);

        bytes32 batcherHash = systemConfig.batcherHash();
        address extracted = address(uint160(uint256(batcherHash)));

        assertEq(extracted, _batcher);
    }

    // ============ Interface Compliance Tests ============

    function test_ImplementsIOpStackAdapter() public view {
        // Verify the adapter implements all required interface functions
        adapter.version();
        adapter.adapterInfo();
        // rotateSequencer is tested above
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
 * @title DelegatecallCaller
 * @notice Helper contract to test delegatecall behavior.
 */
contract DelegatecallCaller {
    address public immutable adapter;

    constructor(address _adapter) {
        adapter = _adapter;
    }

    function executeRotation(
        address _systemConfig,
        address _batcher,
        address _unsafeSigner
    ) external {
        bytes memory data = abi.encodeWithSelector(
            IOpStackAdapter.rotateSequencer.selector,
            _systemConfig,
            _batcher,
            _unsafeSigner
        );

        (bool success, bytes memory returnData) = adapter.delegatecall(data);

        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            revert("Delegatecall failed");
        }
    }
}
