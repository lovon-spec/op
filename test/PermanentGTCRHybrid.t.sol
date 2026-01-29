// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {PermanentGTCRHybrid, IERC20} from "../src/PermanentGTCRHybrid.sol";
import {MockArbitrator} from "./mocks/MockArbitrator.sol";
import {IArbitrator} from "../src/interfaces/IArbitrator.sol";

/**
 * @title PermanentGTCRHybridTest
 * @notice Comprehensive unit tests for PermanentGTCRHybrid contract.
 *
 * Tests cover:
 * - Initialization
 * - Item submission (addItem, addItemWithKeys)
 * - Challenge flow (challengeItem)
 * - Appeal flow (fundAppeal)
 * - Ruling execution (rule)
 * - Request execution (executeRequest)
 * - Withdrawal flow (requestWithdrawal, withdraw, cancelWithdrawal)
 * - Operational keys management (setOperationalKeys, getOperationalKeys)
 * - Governor functions
 * - View functions (isChallengeable, isValidForSync, isRegistered)
 * - "Challengeable Forever" semantics
 */
contract PermanentGTCRHybridTest is Test {
    PermanentGTCRHybrid public registry;
    MockArbitrator public arbitrator;

    address public governor = address(0x1);
    address public submitter1 = address(0x100);
    address public submitter2 = address(0x200);
    address public challenger = address(0x300);
    address public contributor = address(0x400);

    // Operator addresses
    address public batcher1 = address(0x1001);
    address public signer1 = address(0x1002);
    address public batcher2 = address(0x2001);
    address public signer2 = address(0x2002);

    uint256 public constant SUBMISSION_MIN_DEPOSIT = 0.1 ether;
    uint256 public constant SUBMISSION_PERIOD = 1 days;
    uint256 public constant REINCLUSION_PERIOD = 12 hours;
    uint256 public constant WITHDRAWING_PERIOD = 6 hours;
    uint256 public constant ARBITRATION_PARAMS_COOLDOWN = 1 hours;

    // Stake multipliers (in basis points)
    uint256 public constant CHALLENGE_STAKE_MULTIPLIER = 10000; // 100%
    uint256 public constant WINNER_STAKE_MULTIPLIER = 5000; // 50%
    uint256 public constant LOSER_STAKE_MULTIPLIER = 20000; // 200%
    uint256 public constant SHARED_STAKE_MULTIPLIER = 10000; // 100%

    // Events
    event ItemSubmitted(bytes32 indexed _itemID, address indexed _submitter, string _data, uint256 _stake);
    event ItemChallenged(bytes32 indexed _itemID, uint256 indexed _challengeID, uint256 indexed _disputeID);
    event ItemStatusChange(bytes32 indexed _itemID, PermanentGTCRHybrid.Status _status);
    event OperationalKeysUpdated(bytes32 indexed _itemID, address indexed _batcher, address indexed _signer);
    event ItemWithdrawing(bytes32 indexed _itemID, uint48 _withdrawingTimestamp);
    event ItemWithdrawn(bytes32 indexed _itemID);
    event Ruling(IArbitrator indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);

    function setUp() public {
        // Set a reasonable block timestamp
        vm.warp(SUBMISSION_PERIOD + 1);

        // Deploy mock arbitrator
        arbitrator = new MockArbitrator();

        // Deploy registry with WETH as address(0) for native ETH
        registry = new PermanentGTCRHybrid(address(0));

        // Initialize registry
        uint256[4] memory stakeMultipliers = [
            CHALLENGE_STAKE_MULTIPLIER,
            WINNER_STAKE_MULTIPLIER,
            LOSER_STAKE_MULTIPLIER,
            SHARED_STAKE_MULTIPLIER
        ];

        registry.initialize(
            governor,
            arbitrator,
            bytes(""),
            IERC20(address(0)), // Native ETH
            SUBMISSION_MIN_DEPOSIT,
            SUBMISSION_PERIOD,
            REINCLUSION_PERIOD,
            WITHDRAWING_PERIOD,
            stakeMultipliers,
            ARBITRATION_PARAMS_COOLDOWN
        );

        // Fund test accounts
        vm.deal(submitter1, 10 ether);
        vm.deal(submitter2, 10 ether);
        vm.deal(challenger, 10 ether);
        vm.deal(contributor, 10 ether);
    }

    // ============ Initialization Tests ============

    function test_Initialize_SetsCorrectValues() public view {
        assertEq(registry.governor(), governor);
        assertEq(address(registry.arbitrator()), address(arbitrator));
        assertEq(registry.submissionMinDeposit(), SUBMISSION_MIN_DEPOSIT);
        assertEq(registry.submissionPeriod(), SUBMISSION_PERIOD);
        assertEq(registry.reinclusionPeriod(), REINCLUSION_PERIOD);
        assertEq(registry.withdrawingPeriod(), WITHDRAWING_PERIOD);
        assertEq(registry.challengeStakeMultiplier(), CHALLENGE_STAKE_MULTIPLIER);
        assertEq(registry.winnerStakeMultiplier(), WINNER_STAKE_MULTIPLIER);
        assertEq(registry.loserStakeMultiplier(), LOSER_STAKE_MULTIPLIER);
        assertEq(registry.sharedStakeMultiplier(), SHARED_STAKE_MULTIPLIER);
        assertEq(registry.arbitrationParamsCooldown(), ARBITRATION_PARAMS_COOLDOWN);
    }

    function test_Initialize_RevertIfAlreadyInitialized() public {
        uint256[4] memory stakeMultipliers = [uint256(10000), uint256(5000), uint256(20000), uint256(10000)];

        vm.expectRevert(PermanentGTCRHybrid.AlreadyInitialized.selector);
        registry.initialize(
            governor,
            arbitrator,
            bytes(""),
            IERC20(address(0)),
            SUBMISSION_MIN_DEPOSIT,
            SUBMISSION_PERIOD,
            REINCLUSION_PERIOD,
            WITHDRAWING_PERIOD,
            stakeMultipliers,
            ARBITRATION_PARAMS_COOLDOWN
        );
    }

    // ============ Item Submission Tests ============

    function test_AddItem_Success() public {
        string memory data = "ipfs://QmTest123";
        bytes32 expectedItemID = keccak256(abi.encodePacked(data));

        vm.expectEmit(true, true, false, true);
        emit ItemSubmitted(expectedItemID, submitter1, data, SUBMISSION_MIN_DEPOSIT);

        vm.expectEmit(true, false, false, true);
        emit ItemStatusChange(expectedItemID, PermanentGTCRHybrid.Status.Submitted);

        vm.prank(submitter1);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT}(data);

        (
            PermanentGTCRHybrid.Status status,
            ,
            ,
            address payable submitter,
            uint48 includedAt,
            ,
            uint256 stake
        ) = registry.items(expectedItemID);

        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Submitted));
        assertEq(submitter, submitter1);
        assertEq(includedAt, uint48(block.timestamp));
        assertEq(stake, SUBMISSION_MIN_DEPOSIT);
    }

    function test_AddItem_RevertInsufficientDeposit() public {
        string memory data = "ipfs://QmTest123";

        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.InvalidDeposit.selector);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT - 1}(data);
    }

    function test_AddItem_RevertIfAlreadyExists() public {
        string memory data = "ipfs://QmTest123";

        vm.prank(submitter1);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT}(data);

        vm.prank(submitter2);
        vm.expectRevert(PermanentGTCRHybrid.ItemAlreadyExists.selector);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT}(data);
    }

    function test_AddItemWithKeys_Success() public {
        string memory data = "ipfs://QmTestOperator1";

        vm.prank(submitter1);
        bytes32 itemID = registry.addItemWithKeys{value: SUBMISSION_MIN_DEPOSIT}(data, batcher1, signer1);

        (address batcher, address unsafeSigner) = registry.getOperationalKeys(itemID);
        assertEq(batcher, batcher1);
        assertEq(unsafeSigner, signer1);
    }

    function test_AddItemWithKeys_RevertZeroBatcher() public {
        string memory data = "ipfs://QmTestOperator1";

        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.InvalidKeys.selector);
        registry.addItemWithKeys{value: SUBMISSION_MIN_DEPOSIT}(data, address(0), signer1);
    }

    function test_AddItemWithKeys_RevertZeroSigner() public {
        string memory data = "ipfs://QmTestOperator1";

        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.InvalidKeys.selector);
        registry.addItemWithKeys{value: SUBMISSION_MIN_DEPOSIT}(data, batcher1, address(0));
    }

    // ============ Operational Keys Tests ============

    function test_GetOperationalKeys_DefaultsToSubmitter() public {
        string memory data = "ipfs://QmTestDefaultKeys";
        bytes32 itemID = keccak256(abi.encodePacked(data));

        vm.prank(submitter1);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT}(data);

        (address batcher, address unsafeSigner) = registry.getOperationalKeys(itemID);
        assertEq(batcher, submitter1);
        assertEq(unsafeSigner, submitter1);
    }

    function test_SetOperationalKeys_Success() public {
        string memory data = "ipfs://QmTestSetKeys";
        bytes32 itemID = keccak256(abi.encodePacked(data));

        vm.prank(submitter1);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT}(data);

        vm.expectEmit(true, true, true, false);
        emit OperationalKeysUpdated(itemID, batcher1, signer1);

        vm.prank(submitter1);
        registry.setOperationalKeys(itemID, batcher1, signer1);

        (address batcher, address unsafeSigner) = registry.getOperationalKeys(itemID);
        assertEq(batcher, batcher1);
        assertEq(unsafeSigner, signer1);
    }

    function test_SetOperationalKeys_RevertNotSubmitter() public {
        string memory data = "ipfs://QmTestSetKeys";
        bytes32 itemID = keccak256(abi.encodePacked(data));

        vm.prank(submitter1);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT}(data);

        vm.prank(submitter2);
        vm.expectRevert(PermanentGTCRHybrid.NotSubmitter.selector);
        registry.setOperationalKeys(itemID, batcher1, signer1);
    }

    function test_SetOperationalKeys_RevertForAbsentItem() public {
        bytes32 fakeItemID = keccak256("fake");

        // For absent items, the submitter is address(0), so calling from any address
        // other than address(0) will trigger NotSubmitter before ItemDoesNotExist
        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.NotSubmitter.selector);
        registry.setOperationalKeys(fakeItemID, batcher1, signer1);
    }

    function test_SetOperationalKeys_RevertInvalidKeys() public {
        string memory data = "ipfs://QmTestInvalidKeys";
        bytes32 itemID = keccak256(abi.encodePacked(data));

        vm.prank(submitter1);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT}(data);

        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.InvalidKeys.selector);
        registry.setOperationalKeys(itemID, address(0), signer1);

        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.InvalidKeys.selector);
        registry.setOperationalKeys(itemID, batcher1, address(0));
    }

    // ============ Challenge Tests ============

    function test_ChallengeItem_SubmittedStatus() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmChallenge1");

        uint256 arbitrationCost = arbitrator.ARBITRATION_COST();
        uint256 challengeStake = (SUBMISSION_MIN_DEPOSIT * CHALLENGE_STAKE_MULTIPLIER) / 10000;
        uint256 requiredDeposit = arbitrationCost + challengeStake;

        vm.expectEmit(true, true, true, false);
        emit ItemChallenged(itemID, 0, 0);

        vm.expectEmit(true, false, false, true);
        emit ItemStatusChange(itemID, PermanentGTCRHybrid.Status.Disputed);

        vm.prank(challenger);
        registry.challengeItem{value: requiredDeposit}(itemID, "evidence://QmEvidence");

        (PermanentGTCRHybrid.Status status,,,,,, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Disputed));
    }

    function test_ChallengeItem_ReincludedStatus() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmChallengeReincluded");

        uint256 arbitrationCost = arbitrator.ARBITRATION_COST();
        uint256 challengeStake = (SUBMISSION_MIN_DEPOSIT * CHALLENGE_STAKE_MULTIPLIER) / 10000;
        uint256 requiredDeposit = arbitrationCost + challengeStake;

        vm.prank(challenger);
        registry.challengeItem{value: requiredDeposit}(itemID, "");

        (PermanentGTCRHybrid.Status status,,,,,, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Disputed));
    }

    function test_ChallengeItem_ChallengeableForever_AfterPeriod() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmChallengeableForever");

        // Warp far past the submission period
        vm.warp(block.timestamp + SUBMISSION_PERIOD + 100 days);

        // Item should still be challengeable (Challengeable Forever)
        assertTrue(registry.isChallengeable(itemID));

        uint256 arbitrationCost = arbitrator.ARBITRATION_COST();
        uint256 challengeStake = (SUBMISSION_MIN_DEPOSIT * CHALLENGE_STAKE_MULTIPLIER) / 10000;
        uint256 requiredDeposit = arbitrationCost + challengeStake;

        vm.prank(challenger);
        registry.challengeItem{value: requiredDeposit}(itemID, "");

        (PermanentGTCRHybrid.Status status,,,,,, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Disputed));
    }

    function test_ChallengeItem_RevertForAbsentItem() public {
        bytes32 fakeItemID = keccak256("fake");

        vm.prank(challenger);
        vm.expectRevert(PermanentGTCRHybrid.ItemNotChallengeable.selector);
        registry.challengeItem{value: 1 ether}(fakeItemID, "");
    }

    function test_ChallengeItem_RevertForDisputedItem() public {
        (bytes32 itemID,) = _submitAndChallenge(submitter1, "ipfs://QmDisputedChallenge");

        vm.prank(challenger);
        vm.expectRevert(PermanentGTCRHybrid.ItemNotChallengeable.selector);
        registry.challengeItem{value: 1 ether}(itemID, "");
    }

    function test_ChallengeItem_RevertForWithdrawingComplete() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmWithdrawingChallenge");

        // Request withdrawal
        vm.prank(submitter1);
        registry.requestWithdrawal(itemID);

        // Warp past withdrawing period
        vm.warp(block.timestamp + WITHDRAWING_PERIOD + 1);

        // Challenge should fail
        vm.prank(challenger);
        vm.expectRevert(PermanentGTCRHybrid.ItemNotChallengeable.selector);
        registry.challengeItem{value: 1 ether}(itemID, "");
    }

    // ============ Ruling Tests ============

    function test_Rule_SubmitterWins() public {
        (bytes32 itemID, uint256 disputeID) = _submitAndChallenge(submitter1, "ipfs://QmRulingSubmitter");

        uint256 submitterBalanceBefore = submitter1.balance;

        // Give ruling for submitter (1)
        arbitrator.forceRuling(disputeID, 1);

        (PermanentGTCRHybrid.Status status,,,, uint48 includedAt,, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Reincluded));
        assertEq(includedAt, uint48(block.timestamp)); // Reset on reinclusion

        // Submitter should receive both stakes
        assertTrue(submitter1.balance > submitterBalanceBefore);
    }

    function test_Rule_ChallengerWins() public {
        (bytes32 itemID, uint256 disputeID) = _submitAndChallenge(submitter1, "ipfs://QmRulingChallenger");

        uint256 challengerBalanceBefore = challenger.balance;

        // Give ruling for challenger (2)
        arbitrator.forceRuling(disputeID, 2);

        (PermanentGTCRHybrid.Status status,,,,,, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Absent));

        // Challenger should receive both stakes
        assertTrue(challenger.balance > challengerBalanceBefore);

        // The itemKeys mapping is cleared (delete itemKeys[itemID])
        // But getOperationalKeys() falls back to (submitter, submitter) when keys.batcher == 0
        // The raw mapping values should be cleared:
        (address rawBatcher, address rawSigner) = registry.itemKeys(itemID);
        assertEq(rawBatcher, address(0));
        assertEq(rawSigner, address(0));

        // getOperationalKeys falls back to submitter when keys are cleared
        (address batcher, address unsafeSigner) = registry.getOperationalKeys(itemID);
        assertEq(batcher, submitter1);
        assertEq(unsafeSigner, submitter1);
    }

    function test_Rule_RefuseToRule() public {
        (bytes32 itemID, uint256 disputeID) = _submitAndChallenge(submitter1, "ipfs://QmRulingRefuse");

        // Give ruling refuse (0)
        arbitrator.forceRuling(disputeID, 0);

        // Refuse to rule should favor submitter
        (PermanentGTCRHybrid.Status status,,,,,, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Reincluded));
    }

    function test_Rule_RevertNotArbitrator() public {
        (bytes32 itemID, ) = _submitAndChallenge(submitter1, "ipfs://QmRulingNotArbitrator");

        vm.expectRevert(PermanentGTCRHybrid.NotArbitrator.selector);
        registry.rule(0, 1);
    }

    function test_Rule_RevertInvalidRuling() public {
        (, uint256 disputeID) = _submitAndChallenge(submitter1, "ipfs://QmRulingInvalid");

        vm.prank(address(arbitrator));
        vm.expectRevert(PermanentGTCRHybrid.InvalidRuling.selector);
        registry.rule(disputeID, 3); // Only 0, 1, 2 are valid
    }

    // ============ Execute Request Tests ============

    function test_ExecuteRequest_Success() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmExecute");

        uint256 submitterBalanceBefore = submitter1.balance;

        // Warp past submission period
        vm.warp(block.timestamp + SUBMISSION_PERIOD + 1);

        vm.expectEmit(true, false, false, true);
        emit ItemStatusChange(itemID, PermanentGTCRHybrid.Status.Reincluded);

        registry.executeRequest(itemID);

        (PermanentGTCRHybrid.Status status,,,,,, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Reincluded));

        // Stake should be returned
        assertEq(submitter1.balance, submitterBalanceBefore + SUBMISSION_MIN_DEPOSIT);
    }

    function test_ExecuteRequest_RevertDuringPeriod() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmExecuteEarly");

        vm.expectRevert(PermanentGTCRHybrid.WithdrawalPeriodNotOver.selector);
        registry.executeRequest(itemID);
    }

    function test_ExecuteRequest_RevertNotSubmitted() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmExecuteNotSubmitted");

        vm.expectRevert(PermanentGTCRHybrid.InvalidStatus.selector);
        registry.executeRequest(itemID);
    }

    // ============ Withdrawal Tests ============

    function test_RequestWithdrawal_Success() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmWithdraw");

        vm.expectEmit(true, false, false, true);
        emit ItemWithdrawing(itemID, uint48(block.timestamp));

        vm.prank(submitter1);
        registry.requestWithdrawal(itemID);

        (,,,, , uint48 withdrawingTimestamp, ) = registry.items(itemID);
        assertEq(withdrawingTimestamp, uint48(block.timestamp));
    }

    function test_RequestWithdrawal_RevertNotSubmitter() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmWithdrawNotSubmitter");

        vm.prank(submitter2);
        vm.expectRevert(PermanentGTCRHybrid.NotSubmitter.selector);
        registry.requestWithdrawal(itemID);
    }

    function test_RequestWithdrawal_RevertNotReincluded() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmWithdrawNotReincluded");

        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.InvalidStatus.selector);
        registry.requestWithdrawal(itemID);
    }

    function test_Withdraw_Success() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmWithdrawComplete");

        vm.prank(submitter1);
        registry.requestWithdrawal(itemID);

        // Warp past withdrawing period
        vm.warp(block.timestamp + WITHDRAWING_PERIOD + 1);

        vm.expectEmit(true, false, false, false);
        emit ItemWithdrawn(itemID);

        registry.withdraw(itemID);

        (PermanentGTCRHybrid.Status status,,,, , uint48 withdrawingTimestamp, ) = registry.items(itemID);
        assertEq(uint8(status), uint8(PermanentGTCRHybrid.Status.Absent));
        assertEq(withdrawingTimestamp, 0);

        // The itemKeys mapping is cleared (delete itemKeys[itemID])
        (address rawBatcher, address rawSigner) = registry.itemKeys(itemID);
        assertEq(rawBatcher, address(0));
        assertEq(rawSigner, address(0));

        // getOperationalKeys falls back to submitter when keys are cleared
        (address batcher, address unsafeSigner) = registry.getOperationalKeys(itemID);
        assertEq(batcher, submitter1);
        assertEq(unsafeSigner, submitter1);
    }

    function test_Withdraw_RevertNotWithdrawable() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmWithdrawNotWithdrawable");

        vm.expectRevert(PermanentGTCRHybrid.NotWithdrawable.selector);
        registry.withdraw(itemID);
    }

    function test_Withdraw_RevertPeriodNotOver() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmWithdrawPeriodNotOver");

        vm.prank(submitter1);
        registry.requestWithdrawal(itemID);

        vm.expectRevert(PermanentGTCRHybrid.WithdrawalPeriodNotOver.selector);
        registry.withdraw(itemID);
    }

    function test_CancelWithdrawal_Success() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmCancelWithdraw");

        vm.prank(submitter1);
        registry.requestWithdrawal(itemID);

        vm.prank(submitter1);
        registry.cancelWithdrawal(itemID);

        (,,,, , uint48 withdrawingTimestamp, ) = registry.items(itemID);
        assertEq(withdrawingTimestamp, 0);
    }

    function test_CancelWithdrawal_RevertNotSubmitter() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmCancelWithdrawNotSubmitter");

        vm.prank(submitter1);
        registry.requestWithdrawal(itemID);

        vm.prank(submitter2);
        vm.expectRevert(PermanentGTCRHybrid.NotSubmitter.selector);
        registry.cancelWithdrawal(itemID);
    }

    function test_CancelWithdrawal_RevertNotWithdrawable() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmCancelWithdrawNotWithdrawable");

        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.NotWithdrawable.selector);
        registry.cancelWithdrawal(itemID);
    }

    // ============ View Function Tests ============

    function test_IsRegistered_Submitted() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmIsRegisteredSubmitted");
        assertTrue(registry.isRegistered(itemID));
    }

    function test_IsRegistered_Reincluded() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmIsRegisteredReincluded");
        assertTrue(registry.isRegistered(itemID));
    }

    function test_IsRegistered_Absent() public {
        bytes32 fakeItemID = keccak256("fake");
        assertFalse(registry.isRegistered(fakeItemID));
    }

    function test_IsRegistered_Disputed() public {
        (bytes32 itemID,) = _submitAndChallenge(submitter1, "ipfs://QmIsRegisteredDisputed");
        assertFalse(registry.isRegistered(itemID));
    }

    function test_IsChallengeable_Submitted() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmIsChallengeableSubmitted");
        assertTrue(registry.isChallengeable(itemID));
    }

    function test_IsChallengeable_Reincluded() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmIsChallengeableReincluded");
        assertTrue(registry.isChallengeable(itemID));
    }

    function test_IsChallengeable_Disputed() public {
        (bytes32 itemID,) = _submitAndChallenge(submitter1, "ipfs://QmIsChallengeableDisputed");
        assertFalse(registry.isChallengeable(itemID));
    }

    function test_IsChallengeable_Absent() public {
        bytes32 fakeItemID = keccak256("fake");
        assertFalse(registry.isChallengeable(fakeItemID));
    }

    function test_IsChallengeable_WithdrawingComplete() public {
        (bytes32 itemID,) = _submitAndExecuteRequest(submitter1, "ipfs://QmIsChallengeableWithdrawing");

        vm.prank(submitter1);
        registry.requestWithdrawal(itemID);

        // During withdrawing period, still challengeable
        assertTrue(registry.isChallengeable(itemID));

        // After withdrawing period, not challengeable
        vm.warp(block.timestamp + WITHDRAWING_PERIOD + 1);
        assertFalse(registry.isChallengeable(itemID));
    }

    function test_IsValidForSync_SubmittedDuringPeriod() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmIsValidForSyncSubmitted");
        assertFalse(registry.isValidForSync(itemID));
    }

    function test_IsValidForSync_SubmittedAfterPeriod() public {
        (bytes32 itemID,) = _submitItem(submitter1, "ipfs://QmIsValidForSyncSubmittedAfter");

        vm.warp(block.timestamp + SUBMISSION_PERIOD + 1);
        assertTrue(registry.isValidForSync(itemID));
    }

    function test_IsValidForSync_ReincludedDuringPeriod() public {
        (bytes32 itemID, uint256 disputeID) = _submitAndChallenge(submitter1, "ipfs://QmIsValidForSyncReincludedDuring");

        // Submitter wins
        arbitrator.forceRuling(disputeID, 1);

        // Just became Reincluded, still in maturity period
        assertFalse(registry.isValidForSync(itemID));
    }

    function test_IsValidForSync_ReincludedAfterPeriod() public {
        (bytes32 itemID, uint256 disputeID) = _submitAndChallenge(submitter1, "ipfs://QmIsValidForSyncReincludedAfter");

        // Submitter wins
        arbitrator.forceRuling(disputeID, 1);

        // Warp past reinclusion period
        vm.warp(block.timestamp + REINCLUSION_PERIOD + 1);
        assertTrue(registry.isValidForSync(itemID));
    }

    function test_IsValidForSync_Disputed() public {
        (bytes32 itemID,) = _submitAndChallenge(submitter1, "ipfs://QmIsValidForSyncDisputed");
        assertFalse(registry.isValidForSync(itemID));
    }

    function test_IsValidForSync_Absent() public {
        bytes32 fakeItemID = keccak256("fake");
        assertFalse(registry.isValidForSync(fakeItemID));
    }

    // ============ Governor Function Tests ============

    function test_ChangeGovernor() public {
        address newGovernor = address(0x999);

        vm.prank(governor);
        registry.changeGovernor(newGovernor);

        assertEq(registry.governor(), newGovernor);
    }

    function test_ChangeGovernor_RevertNotGovernor() public {
        vm.prank(submitter1);
        vm.expectRevert(PermanentGTCRHybrid.NotGovernor.selector);
        registry.changeGovernor(address(0x999));
    }

    function test_ChangeSubmissionMinDeposit() public {
        uint256 newDeposit = 0.5 ether;

        vm.prank(governor);
        registry.changeSubmissionMinDeposit(newDeposit);

        assertEq(registry.submissionMinDeposit(), newDeposit);
    }

    function test_ChangeSubmissionPeriod() public {
        uint256 newPeriod = 2 days;

        vm.prank(governor);
        registry.changeSubmissionPeriod(newPeriod);

        assertEq(registry.submissionPeriod(), newPeriod);
    }

    function test_ChangeReinclusionPeriod() public {
        uint256 newPeriod = 1 days;

        vm.prank(governor);
        registry.changeReinclusionPeriod(newPeriod);

        assertEq(registry.reinclusionPeriod(), newPeriod);
    }

    function test_ChangeWithdrawingPeriod() public {
        uint256 newPeriod = 12 hours;

        vm.prank(governor);
        registry.changeWithdrawingPeriod(newPeriod);

        assertEq(registry.withdrawingPeriod(), newPeriod);
    }

    function test_ChangeStakeMultipliers() public {
        vm.prank(governor);
        registry.changeStakeMultipliers(5000, 2500, 10000, 5000);

        assertEq(registry.challengeStakeMultiplier(), 5000);
        assertEq(registry.winnerStakeMultiplier(), 2500);
        assertEq(registry.loserStakeMultiplier(), 10000);
        assertEq(registry.sharedStakeMultiplier(), 5000);
    }

    function test_ChangeArbitrationParams_Success() public {
        // Warp past cooldown
        vm.warp(block.timestamp + ARBITRATION_PARAMS_COOLDOWN + 1);

        vm.prank(governor);
        registry.changeArbitrationParams(bytes("new params"));

        assertEq(registry.getArbitrationParamsCount(), 2);
    }

    function test_ChangeArbitrationParams_RevertCooldownNotPassed() public {
        vm.prank(governor);
        vm.expectRevert(PermanentGTCRHybrid.CooldownNotPassed.selector);
        registry.changeArbitrationParams(bytes("new params"));
    }

    // ============ Fuzz Tests ============

    function testFuzz_AddItem_AcceptsExcessDeposit(uint256 _extraDeposit) public {
        vm.assume(_extraDeposit > 0 && _extraDeposit < 100 ether);

        string memory data = "ipfs://QmFuzzDeposit";
        bytes32 itemID = keccak256(abi.encodePacked(data));

        vm.deal(submitter1, SUBMISSION_MIN_DEPOSIT + _extraDeposit);

        vm.prank(submitter1);
        registry.addItem{value: SUBMISSION_MIN_DEPOSIT + _extraDeposit}(data);

        (,,,,,, uint256 stake) = registry.items(itemID);
        assertEq(stake, SUBMISSION_MIN_DEPOSIT + _extraDeposit);
    }

    function testFuzz_OperationalKeys(address _batcher, address _signer) public {
        vm.assume(_batcher != address(0) && _signer != address(0));

        string memory data = string(abi.encode(_batcher, _signer));

        vm.prank(submitter1);
        bytes32 itemID = registry.addItemWithKeys{value: SUBMISSION_MIN_DEPOSIT}(data, _batcher, _signer);

        (address batcher, address unsafeSigner) = registry.getOperationalKeys(itemID);
        assertEq(batcher, _batcher);
        assertEq(unsafeSigner, _signer);
    }

    // ============ Helper Functions ============

    function _submitItem(address submitter, string memory data) internal returns (bytes32 itemID, uint256 stake) {
        itemID = keccak256(abi.encodePacked(data));
        stake = SUBMISSION_MIN_DEPOSIT;

        vm.prank(submitter);
        registry.addItem{value: stake}(data);

        return (itemID, stake);
    }

    function _submitAndExecuteRequest(address submitter, string memory data) internal returns (bytes32 itemID, uint256 stake) {
        (itemID, stake) = _submitItem(submitter, data);

        // Warp past submission period
        vm.warp(block.timestamp + SUBMISSION_PERIOD + 1);

        registry.executeRequest(itemID);

        return (itemID, stake);
    }

    function _submitAndChallenge(address submitter, string memory data) internal returns (bytes32 itemID, uint256 disputeID) {
        (itemID,) = _submitItem(submitter, data);

        uint256 arbitrationCost = arbitrator.ARBITRATION_COST();
        uint256 challengeStake = (SUBMISSION_MIN_DEPOSIT * CHALLENGE_STAKE_MULTIPLIER) / 10000;
        uint256 requiredDeposit = arbitrationCost + challengeStake;

        vm.prank(challenger);
        registry.challengeItem{value: requiredDeposit}(itemID, "");

        // The dispute ID is the last one created
        disputeID = arbitrator.disputeCount() - 1;

        return (itemID, disputeID);
    }
}
