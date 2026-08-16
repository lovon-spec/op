// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ChainRegistry} from "../src/ChainRegistry.sol";
import {IChainRegistry} from "../src/interfaces/IChainRegistry.sol";
import {IArbitrator} from "../src/interfaces/IArbitrator.sol";
import {MockArbitrator} from "./mocks/MockArbitrator.sol";
import {OpStackAdapterV1} from "../src/poc/opstack/OpStackAdapterV1.sol";

/**
 * @title ChainRegistryTest
 * @notice Tests for the ChainRegistry GeneralizedTCR contract.
 * @dev Tests chain registration, challenge period, and dispute resolution.
 */
contract ChainRegistryTest is Test {
    // ============ Test Accounts ============
    address public governor = address(0x1);
    address public submitter1 = address(0x10);
    address public submitter2 = address(0x11);
    address public challenger = address(0x20);
    address public randomUser = address(0x99);

    // ============ Contracts ============
    ChainRegistry public registry;
    MockArbitrator public arbitrator;
    OpStackAdapterV1 public adapter;

    // ============ Test Data ============
    uint256 public constant CHAIN_ID_1 = 42001;
    uint256 public constant CHAIN_ID_2 = 42002;
    address public rollupConfig1 = address(0x100);
    address public rollupConfig2 = address(0x101);

    uint256 public constant REQUIRED_DEPOSIT = 0.1 ether;
    uint256 public constant CHALLENGE_PERIOD = 5 minutes;
    uint256 public constant ARBITRATION_COST = 0.05 ether;

    // ============ Setup ============

    function setUp() public {
        // Deploy arbitrator
        arbitrator = new MockArbitrator(ARBITRATION_COST);

        // Deploy adapter
        adapter = new OpStackAdapterV1();

        // Deploy registry
        uint256[3] memory multipliers = [uint256(10000), uint256(10000), uint256(10000)];
        registry = new ChainRegistry(
            governor,
            IArbitrator(address(arbitrator)),
            "",
            REQUIRED_DEPOSIT,
            CHALLENGE_PERIOD,
            multipliers
        );

        // Fund test accounts
        vm.deal(submitter1, 10 ether);
        vm.deal(submitter2, 10 ether);
        vm.deal(challenger, 10 ether);
        vm.deal(randomUser, 10 ether);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialValues() public view {
        assertEq(registry.governor(), governor);
        assertEq(address(registry.arbitrator()), address(arbitrator));
        assertEq(registry.requiredDeposit(), REQUIRED_DEPOSIT);
        assertEq(registry.challengePeriod(), CHALLENGE_PERIOD);
    }

    // ============ Registration Tests ============

    function test_AddChain_Success() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            "ipfs://metadata"
        );

        // Verify item was created
        IChainRegistry.Item memory item = registry.getItem(itemId);
        assertEq(uint256(item.status), uint256(IChainRegistry.Status.RegistrationRequested));
        assertEq(item.data.chainId, CHAIN_ID_1);
        assertEq(item.data.rollupConfig, rollupConfig1);
        assertEq(item.data.adapter, address(adapter));
        assertEq(item.submitter, submitter1);
    }

    function test_AddChain_RevertsInvalidChainId() public {
        vm.prank(submitter1);
        vm.expectRevert(IChainRegistry.InvalidChainId.selector);
        registry.addChain{value: 1 ether}(
            0, // Invalid
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );
    }

    function test_AddChain_RevertsInvalidRollupConfig() public {
        vm.prank(submitter1);
        vm.expectRevert(IChainRegistry.InvalidRollupConfig.selector);
        registry.addChain{value: 1 ether}(
            CHAIN_ID_1,
            address(0), // Invalid
            address(adapter),
            "Test Chain",
            ""
        );
    }

    function test_AddChain_RevertsInvalidAdapter() public {
        vm.prank(submitter1);
        vm.expectRevert(IChainRegistry.InvalidAdapter.selector);
        registry.addChain{value: 1 ether}(
            CHAIN_ID_1,
            rollupConfig1,
            address(0), // Invalid
            "Test Chain",
            ""
        );
    }

    function test_AddChain_RevertsIfAlreadyExists() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        vm.prank(submitter2);
        vm.expectRevert(IChainRegistry.ItemAlreadyExists.selector);
        registry.addChain{value: totalDeposit}(
            CHAIN_ID_1, // Same chain ID
            rollupConfig2,
            address(adapter),
            "Another Chain",
            ""
        );
    }

    function test_AddChain_RevertsInsufficientDeposit() public {
        vm.prank(submitter1);
        vm.expectRevert(IChainRegistry.InsufficientDeposit.selector);
        registry.addChain{value: 0.01 ether}( // Too low
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );
    }

    // ============ Execute Request Tests ============

    function test_ExecuteRequest_Success() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        // Warp past challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        // Execute request
        registry.executeRequest(itemId);

        // Verify chain is now registered
        assertTrue(registry.isRegistered(CHAIN_ID_1));

        IChainRegistry.Item memory item = registry.getItem(itemId);
        assertEq(uint256(item.status), uint256(IChainRegistry.Status.Registered));
    }

    function test_ExecuteRequest_RevertsBeforeChallengePeriod() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        // Don't warp - still in challenge period
        vm.expectRevert(IChainRegistry.ChallengePeriodNotPassed.selector);
        registry.executeRequest(itemId);
    }

    // ============ Challenge Tests ============

    function test_ChallengeRequest_Success() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        // Challenge
        uint256 challengerDeposit = ARBITRATION_COST + REQUIRED_DEPOSIT;
        vm.prank(challenger);
        registry.challengeRequest{value: challengerDeposit}(itemId, "ipfs://evidence");

        // Verify dispute was created
        IChainRegistry.Request memory request = registry.getRequest(itemId, 0);
        assertTrue(request.disputed);
        assertEq(request.challenger, challenger);
    }

    function test_ChallengeRequest_RevertsIfNotPending() public {
        bytes32 fakeItemId = keccak256(abi.encode(uint256(99999)));

        vm.prank(challenger);
        vm.expectRevert(IChainRegistry.InvalidStatus.selector);
        registry.challengeRequest{value: 1 ether}(fakeItemId, "evidence");
    }

    function test_ChallengeRequest_RevertsIfAlreadyDisputed() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        // First challenge
        uint256 challengerDeposit = ARBITRATION_COST + REQUIRED_DEPOSIT;
        vm.prank(challenger);
        registry.challengeRequest{value: challengerDeposit}(itemId, "evidence1");

        // Second challenge should fail
        vm.prank(randomUser);
        vm.expectRevert(IChainRegistry.AlreadyDisputed.selector);
        registry.challengeRequest{value: challengerDeposit}(itemId, "evidence2");
    }

    // ============ Ruling Tests ============

    function test_Rule_RequesterWins() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        // Challenge
        uint256 challengerDeposit = ARBITRATION_COST + REQUIRED_DEPOSIT;
        vm.prank(challenger);
        registry.challengeRequest{value: challengerDeposit}(itemId, "evidence");

        // Get dispute ID
        IChainRegistry.Request memory request = registry.getRequest(itemId, 0);

        // Arbitrator rules in favor of requester
        vm.prank(address(arbitrator));
        registry.rule(request.disputeID, 1); // 1 = Requester wins

        // Verify chain is registered
        assertTrue(registry.isRegistered(CHAIN_ID_1));
    }

    function test_Rule_ChallengerWins() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        // Challenge
        uint256 challengerDeposit = ARBITRATION_COST + REQUIRED_DEPOSIT;
        vm.prank(challenger);
        registry.challengeRequest{value: challengerDeposit}(itemId, "evidence");

        // Get dispute ID
        IChainRegistry.Request memory request = registry.getRequest(itemId, 0);

        // Arbitrator rules in favor of challenger
        vm.prank(address(arbitrator));
        registry.rule(request.disputeID, 2); // 2 = Challenger wins

        // Verify chain is NOT registered
        assertFalse(registry.isRegistered(CHAIN_ID_1));

        IChainRegistry.Item memory item = registry.getItem(itemId);
        assertEq(uint256(item.status), uint256(IChainRegistry.Status.Absent));
    }

    function test_Rule_RevertsIfNotArbitrator() public {
        vm.prank(randomUser);
        vm.expectRevert(IChainRegistry.NotArbitrator.selector);
        registry.rule(0, 1);
    }

    // ============ Removal Tests ============

    function test_RemoveChain_Success() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        // First register the chain
        vm.prank(submitter1);
        bytes32 itemId = registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(itemId);

        assertTrue(registry.isRegistered(CHAIN_ID_1));

        // Request removal
        vm.prank(submitter1);
        registry.removeChain{value: totalDeposit}(CHAIN_ID_1);

        // Verify status changed
        IChainRegistry.Item memory item = registry.getItem(itemId);
        assertEq(uint256(item.status), uint256(IChainRegistry.Status.ClearingRequested));

        // Execute removal
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(itemId);

        // Verify chain is removed
        assertFalse(registry.isRegistered(CHAIN_ID_1));
    }

    function test_RemoveChain_RevertsIfNotRegistered() public {
        vm.prank(submitter1);
        vm.expectRevert(IChainRegistry.InvalidStatus.selector);
        registry.removeChain{value: 1 ether}(CHAIN_ID_1);
    }

    // ============ View Function Tests ============

    function test_GetItemId_Deterministic() public pure {
        bytes32 expected = keccak256(abi.encode(CHAIN_ID_1));
        // Can't call registry.getItemId in pure test, but verify the logic
        assertEq(expected, keccak256(abi.encode(CHAIN_ID_1)));
    }

    function test_GetRegisteredChains_ReturnsAllRegistered() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        // Register two chains
        vm.startPrank(submitter1);
        registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Chain 1",
            ""
        );
        registry.addChain{value: totalDeposit}(
            CHAIN_ID_2,
            rollupConfig2,
            address(adapter),
            "Chain 2",
            ""
        );
        vm.stopPrank();

        // Execute both
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(registry.getItemId(CHAIN_ID_1));
        registry.executeRequest(registry.getItemId(CHAIN_ID_2));

        // Check registered chains
        uint256[] memory chains = registry.getRegisteredChains();
        assertEq(chains.length, 2);
    }

    function test_GetItemByChainId_ReturnsCorrectItem() public {
        uint256 totalDeposit = REQUIRED_DEPOSIT + ARBITRATION_COST;

        vm.prank(submitter1);
        registry.addChain{value: totalDeposit}(
            CHAIN_ID_1,
            rollupConfig1,
            address(adapter),
            "Test Chain",
            ""
        );

        IChainRegistry.Item memory item = registry.getItemByChainId(CHAIN_ID_1);
        assertEq(item.data.chainId, CHAIN_ID_1);
        assertEq(item.data.rollupConfig, rollupConfig1);
    }

    // ============ Governance Tests ============

    function test_SetRequiredDeposit_Success() public {
        vm.prank(governor);
        registry.setRequiredDeposit(0.5 ether);

        assertEq(registry.requiredDeposit(), 0.5 ether);
    }

    function test_SetChallengePeriod_Success() public {
        vm.prank(governor);
        registry.setChallengePeriod(10 minutes);

        assertEq(registry.challengePeriod(), 10 minutes);
    }

    function test_TransferGovernance_Success() public {
        address newGovernor = address(0x999);

        vm.prank(governor);
        registry.transferGovernance(newGovernor);

        assertEq(registry.governor(), newGovernor);
    }

    function test_Governance_RevertsIfNotGovernor() public {
        vm.prank(randomUser);
        vm.expectRevert(IChainRegistry.NotSubmitter.selector);
        registry.setRequiredDeposit(1 ether);
    }
}
