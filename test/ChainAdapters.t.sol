// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ArbitrumAdapterV1} from "../src/poc/arbitrum/ArbitrumAdapterV1.sol";
import {GenericAdapterV1} from "../src/poc/generic/GenericAdapterV1.sol";
import {MockSequencerInbox} from "./mocks/MockSequencerInbox.sol";

/**
 * @title ChainAdaptersTest
 * @notice Tests for ArbitrumAdapterV1 and GenericAdapterV1.
 */
contract ChainAdaptersTest is Test {
    // ============ Contracts ============
    ArbitrumAdapterV1 public arbitrumAdapter;
    GenericAdapterV1 public genericAdapter;
    MockSequencerInbox public sequencerInbox;
    MockGenericRollup public genericRollup;

    // ============ Test Accounts ============
    address public newBatchPoster = address(0x10);
    address public oldBatchPoster = address(0x11);

    // ============ Setup ============

    function setUp() public {
        arbitrumAdapter = new ArbitrumAdapterV1();
        genericAdapter = new GenericAdapterV1();
        sequencerInbox = new MockSequencerInbox();
        genericRollup = new MockGenericRollup();

        // Set up initial batch poster
        sequencerInbox.setIsBatchPoster(oldBatchPoster, true);
    }

    // ============ Arbitrum Adapter Tests ============

    function test_Arbitrum_Version() public view {
        assertEq(arbitrumAdapter.version(), 1_000_000);
    }

    function test_Arbitrum_AdapterInfo() public view {
        (string memory name, string memory description) = arbitrumAdapter.adapterInfo();
        assertEq(name, "ArbitrumAdapterV1");
        assertTrue(bytes(description).length > 0);
    }

    function test_Arbitrum_RotateSequencer_Success() public {
        bytes memory rotationData = abi.encode(newBatchPoster, oldBatchPoster);

        arbitrumAdapter.rotateSequencer(address(sequencerInbox), rotationData);

        assertTrue(sequencerInbox.batchPosters(newBatchPoster));
        assertFalse(sequencerInbox.batchPosters(oldBatchPoster));
    }

    function test_Arbitrum_RotateSequencer_WithoutOldPoster() public {
        bytes memory rotationData = abi.encode(newBatchPoster, address(0));

        arbitrumAdapter.rotateSequencer(address(sequencerInbox), rotationData);

        assertTrue(sequencerInbox.batchPosters(newBatchPoster));
        // Old poster still active since we passed address(0)
        assertTrue(sequencerInbox.batchPosters(oldBatchPoster));
    }

    function test_Arbitrum_RotateSequencer_RevertsIfInvalidInbox() public {
        bytes memory rotationData = abi.encode(newBatchPoster, oldBatchPoster);

        vm.expectRevert(ArbitrumAdapterV1.InvalidSequencerInbox.selector);
        arbitrumAdapter.rotateSequencer(address(0), rotationData);
    }

    function test_Arbitrum_RotateSequencer_RevertsIfInvalidPayload() public {
        vm.expectRevert(ArbitrumAdapterV1.InvalidRotationPayload.selector);
        arbitrumAdapter.rotateSequencer(address(sequencerInbox), hex"deadbeef");
    }

    function test_Arbitrum_RotateSequencer_RevertsIfZeroNewPoster() public {
        bytes memory rotationData = abi.encode(address(0), oldBatchPoster);

        vm.expectRevert(ArbitrumAdapterV1.InvalidOperatorKeys.selector);
        arbitrumAdapter.rotateSequencer(address(sequencerInbox), rotationData);
    }

    // ============ Generic Adapter Tests ============

    function test_Generic_Version() public view {
        assertEq(genericAdapter.version(), 1_000_000);
    }

    function test_Generic_AdapterInfo() public view {
        (string memory name, string memory description) = genericAdapter.adapterInfo();
        assertEq(name, "GenericAdapterV1");
        assertTrue(bytes(description).length > 0);
    }

    function test_Generic_SingleCall_Success() public {
        // Encode a single call: setSequencer(address)
        bytes4 selector = MockGenericRollup.setSequencer.selector;
        bytes memory callData = abi.encode(address(0x42));

        bytes memory rotationData = abi.encode(selector, callData);

        genericAdapter.rotateSequencer(address(genericRollup), rotationData);

        assertEq(genericRollup.currentSequencer(), address(0x42));
    }

    function test_Generic_RevertsIfInvalidConfig() public {
        vm.expectRevert(GenericAdapterV1.InvalidRollupConfig.selector);
        genericAdapter.rotateSequencer(address(0), hex"00000000");
    }

    function test_Generic_RevertsIfPayloadTooShort() public {
        vm.expectRevert(GenericAdapterV1.InvalidRotationPayload.selector);
        genericAdapter.rotateSequencer(address(genericRollup), hex"00");
    }
}

// Mock generic rollup config for testing
contract MockGenericRollup {
    address public currentSequencer;
    uint256 public blockTime;

    function setSequencer(address _sequencer) external {
        currentSequencer = _sequencer;
    }

    function setBlockTime(uint256 _blockTime) external {
        blockTime = _blockTime;
    }
}
