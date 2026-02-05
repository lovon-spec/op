// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {FraudProofVerifier} from "../src/fraud/FraudProofVerifier.sol";
import {SovereignPolicyManager} from "../src/policy/SovereignPolicyManager.sol";
import {ISovereignPolicy} from "../src/interfaces/ISovereignPolicy.sol";
import {IFraudProofVerifier} from "../src/interfaces/IFraudProofVerifier.sol";
import {MockArbitrator} from "./mocks/MockArbitrator.sol";

/**
 * @title FraudProofVerifierTest
 * @notice Tests for the FraudProofVerifier contract.
 */
contract FraudProofVerifierTest is Test {
    // ============ Test Accounts ============
    address public governance = address(0x1);
    address public hubAddr = address(0x2);
    address public sequencer = address(0x10);
    address public challenger = address(0x20);

    // ============ Contracts ============
    FraudProofVerifier public verifier;
    SovereignPolicyManager public policyManager;
    MockArbitrator public arbitrator;

    // ============ Constants ============
    uint256 public constant CHAIN_ID = 10;
    uint256 public constant CHALLENGE_BOND = 0.5 ether;

    // ============ Setup ============

    function setUp() public {
        arbitrator = new MockArbitrator(0.1 ether);
        policyManager = new SovereignPolicyManager(governance, hubAddr);

        verifier = new FraudProofVerifier(
            governance,
            hubAddr,
            address(policyManager),
            arbitrator,
            "",
            CHALLENGE_BOND,
            24 hours
        );

        // Set up a chain policy with timing constraints
        vm.prank(governance);
        policyManager.setChainGovernance(CHAIN_ID, governance);

        vm.prank(governance);
        policyManager.declarePolicy(
            CHAIN_ID,
            ISovereignPolicy.OrderingStrategy.FCFS,
            ISovereignPolicy.EnforcementType.Hybrid,
            12 seconds, // max block time
            30 seconds, // forced inclusion deadline
            true, // sandwich protection
            false,
            address(0),
            ""
        );

        // Fund accounts
        vm.deal(challenger, 100 ether);
        vm.deal(sequencer, 100 ether);
        vm.deal(governance, 100 ether);
    }

    // ============ Submit Challenge Tests ============

    function test_SubmitChallenge_Success() public {
        bytes memory proofData = abi.encode(uint256(100), uint256(200));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.TimingViolation,
            proofData
        );

        assertTrue(challengeId != bytes32(0));

        IFraudProofVerifier.Challenge memory challenge = verifier.getChallenge(challengeId);
        assertEq(challenge.challenger, challenger);
        assertEq(challenge.sequencer, sequencer);
        assertEq(challenge.chainId, CHAIN_ID);
        assertEq(uint256(challenge.proofType), uint256(IFraudProofVerifier.ProofType.TimingViolation));
        assertEq(challenge.bond, CHALLENGE_BOND);
        assertEq(uint256(challenge.status), uint256(IFraudProofVerifier.ChallengeStatus.Pending));
    }

    function test_SubmitChallenge_RevertsIfInsufficientBond() public {
        vm.prank(challenger);
        vm.expectRevert(IFraudProofVerifier.InsufficientBond.selector);
        verifier.submitChallenge{value: 0.1 ether}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.TimingViolation,
            abi.encode(uint256(100), uint256(200))
        );
    }

    function test_SubmitChallenge_RevertsIfEmptyProof() public {
        vm.prank(challenger);
        vm.expectRevert(IFraudProofVerifier.InvalidProofData.selector);
        verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.TimingViolation,
            ""
        );
    }

    // ============ Deterministic Verification Tests ============

    function test_VerifyTimingViolation_Accepts() public {
        // Block gap of 20 seconds exceeds 12 second max
        bytes memory proofData = abi.encode(uint256(1000), uint256(1020));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.TimingViolation,
            proofData
        );

        uint256 challengerBalBefore = challenger.balance;

        verifier.verifyDeterministicProof(challengeId);

        assertEq(
            uint256(verifier.getChallengeStatus(challengeId)),
            uint256(IFraudProofVerifier.ChallengeStatus.Accepted)
        );

        // Challenger should get bond back
        assertEq(challenger.balance, challengerBalBefore + CHALLENGE_BOND);
    }

    function test_VerifyTimingViolation_Rejects() public {
        // Block gap of 5 seconds is within 12 second max
        bytes memory proofData = abi.encode(uint256(1000), uint256(1005));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.TimingViolation,
            proofData
        );

        uint256 govBalBefore = governance.balance;

        verifier.verifyDeterministicProof(challengeId);

        assertEq(
            uint256(verifier.getChallengeStatus(challengeId)),
            uint256(IFraudProofVerifier.ChallengeStatus.Rejected)
        );

        // Bond goes to governance
        assertEq(governance.balance, govBalBefore + CHALLENGE_BOND);
    }

    function test_VerifyInclusionViolation_Accepts() public {
        // Transaction was submitted at time 1000, latest block at 1050
        // 50 seconds > 30 second forced inclusion deadline
        bytes memory proofData = abi.encode(bytes32(uint256(1)), uint256(1000), uint256(1050));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.InclusionViolation,
            proofData
        );

        verifier.verifyDeterministicProof(challengeId);

        assertEq(
            uint256(verifier.getChallengeStatus(challengeId)),
            uint256(IFraudProofVerifier.ChallengeStatus.Accepted)
        );
    }

    function test_VerifyBundleViolation_Accepts() public {
        // Bundle deadline passed
        bytes memory proofData = abi.encode(
            bytes32(uint256(1)), // bundleId
            bytes32(uint256(2)), // opsHash
            uint256(1000),       // deadline
            uint256(1500)        // currentTime > deadline
        );

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.BundleViolation,
            proofData
        );

        verifier.verifyDeterministicProof(challengeId);

        assertEq(
            uint256(verifier.getChallengeStatus(challengeId)),
            uint256(IFraudProofVerifier.ChallengeStatus.Accepted)
        );
    }

    // ============ Arbitration Escalation Tests ============

    function test_EscalateToArbitration_Success() public {
        bytes memory proofData = abi.encode(uint256(100), uint256(200));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.MEVViolation,
            proofData
        );

        vm.prank(challenger);
        verifier.escalateToArbitration{value: 0.1 ether}(challengeId);

        IFraudProofVerifier.Challenge memory challenge = verifier.getChallenge(challengeId);
        assertEq(uint256(challenge.status), uint256(IFraudProofVerifier.ChallengeStatus.Disputed));
        assertTrue(challenge.disputeId >= 0);
    }

    function test_EscalateToArbitration_RevertsIfInsufficientFee() public {
        bytes memory proofData = abi.encode(uint256(100), uint256(200));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.MEVViolation,
            proofData
        );

        vm.prank(challenger);
        vm.expectRevert(IFraudProofVerifier.InsufficientBond.selector);
        verifier.escalateToArbitration{value: 0.01 ether}(challengeId);
    }

    // ============ Arbitrator Ruling Tests ============

    function test_ArbitratorRuling_ChallengerWins() public {
        bytes memory proofData = abi.encode(uint256(100), uint256(200));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.MEVViolation,
            proofData
        );

        vm.prank(challenger);
        verifier.escalateToArbitration{value: 0.1 ether}(challengeId);

        IFraudProofVerifier.Challenge memory challenge = verifier.getChallenge(challengeId);
        uint256 challengerBalBefore = challenger.balance;

        // Arbitrator rules in favor of challenger
        arbitrator.forceRuling(challenge.disputeId, 1);

        assertEq(
            uint256(verifier.getChallengeStatus(challengeId)),
            uint256(IFraudProofVerifier.ChallengeStatus.Accepted)
        );

        // Challenger gets bond back
        assertEq(challenger.balance, challengerBalBefore + CHALLENGE_BOND);
    }

    function test_ArbitratorRuling_SequencerWins() public {
        bytes memory proofData = abi.encode(uint256(100), uint256(200));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.MEVViolation,
            proofData
        );

        vm.prank(challenger);
        verifier.escalateToArbitration{value: 0.1 ether}(challengeId);

        IFraudProofVerifier.Challenge memory challenge = verifier.getChallenge(challengeId);
        uint256 govBalBefore = governance.balance;

        // Arbitrator rules against challenger
        arbitrator.forceRuling(challenge.disputeId, 2);

        assertEq(
            uint256(verifier.getChallengeStatus(challengeId)),
            uint256(IFraudProofVerifier.ChallengeStatus.Rejected)
        );

        // Bond goes to governance
        assertEq(governance.balance, govBalBefore + CHALLENGE_BOND);
    }

    // ============ Auto-Resolution Tests ============

    function test_ResolveChallenge_AutoAcceptsAfterDeadline() public {
        bytes memory proofData = abi.encode(uint256(100), uint256(200));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.TimingViolation,
            proofData
        );

        // Warp past response deadline
        vm.warp(block.timestamp + 25 hours);

        uint256 challengerBalBefore = challenger.balance;

        verifier.resolveChallenge(challengeId);

        assertEq(
            uint256(verifier.getChallengeStatus(challengeId)),
            uint256(IFraudProofVerifier.ChallengeStatus.Accepted)
        );

        assertEq(challenger.balance, challengerBalBefore + CHALLENGE_BOND);
    }

    function test_ResolveChallenge_RevertsIfNotExpired() public {
        bytes memory proofData = abi.encode(uint256(100), uint256(200));

        vm.prank(challenger);
        bytes32 challengeId = verifier.submitChallenge{value: CHALLENGE_BOND}(
            sequencer,
            CHAIN_ID,
            IFraudProofVerifier.ProofType.TimingViolation,
            proofData
        );

        vm.expectRevert(IFraudProofVerifier.InvalidChallengeStatus.selector);
        verifier.resolveChallenge(challengeId);
    }

    // ============ Governance Tests ============

    function test_SetChallengeBond() public {
        vm.prank(governance);
        verifier.setChallengeBond(1 ether);

        assertEq(verifier.challengeBond(), 1 ether);
    }

    function test_SetResponseWindow() public {
        vm.prank(governance);
        verifier.setResponseWindow(48 hours);

        assertEq(verifier.responseWindow(), 48 hours);
    }
}
