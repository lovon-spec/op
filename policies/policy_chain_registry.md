# Chain Registry Policy

## Overview

This policy governs the acceptance and removal of L2 chains from the ISOCHRON Chain Registry. The registry uses a GeneralizedTCR (Token Curated Registry) pattern where community members can challenge invalid applications during the challenge period. ISOCHRON uses configurable arbitration with Kleros Court as the default.

## Court Information

| Parameter | Value |
|-----------|-------|
| Arbitrator | Kleros Court (default) |
| Court ID | 4 (Blockchain Technical) |
| Number of Jurors | 3 (initial round) |
| Appeal Rounds | Standard appeal process for the default arbitrator (Kleros Court today) |

## Acceptance Criteria

A chain registration SHOULD be accepted if ALL of the following criteria are met:

### 1. Valid Rollup Deployment

The submitted chain MUST be a valid rollup deployment:

- **Rollup Config Contract**: The `rollupConfig` address must be a valid configuration contract on L1
- **Ownership**: The rollup configuration contract must be capable of having its ownership transferred to the ISOCHRON Hub
- **Accessibility**: The L1 contracts must be publicly accessible and verifiable
- **Chain ID Uniqueness**: The `chainId` must not already be registered or connected to ISOCHRON

### 2. Operational Capability

The chain team MUST demonstrate operational capability:

- **Infrastructure**: Evidence of running validator/sequencer infrastructure (node configs, monitoring setup)
- **Technical Team**: Contact information or public presence of technical team members
- **Incident Response**: Documented process for handling operational issues
- **Uptime History**: If the chain has been running, evidence of >= 99% uptime

### 3. Sequencer SLA Alignment

The chain team MUST acknowledge and commit to:

- **Sequencer Policy**: Agreement to enforce the [Sequencer Registry Policy](./policy_sequencer_registry.md) for operators
- **ISOCHRON Governance**: Acceptance of ISOCHRON governance decisions regarding the chain

### 4. Valid Metadata

The registration metadata MUST be accurate:

- **Chain Name**: Unique, non-misleading name that doesn't infringe trademarks
- **Metadata URI**: Valid IPFS URI containing accurate chain information
- **Adapter**: Valid rollup adapter that is registered in the Adapter Registry

## Rejection Criteria

A chain registration SHOULD be rejected if ANY of the following are true:

### 1. Technical Invalidity

- Rollup config address is not a valid rollup contract
- Chain ID conflicts with existing registrations
- Adapter is not registered in the Adapter Registry
- L1 contracts are not accessible or verifiable

### 2. Fraud or Misrepresentation

- Metadata contains false claims about the chain's capabilities
- Chain name deliberately mimics existing chains to deceive users
- Team information is fabricated or stolen
- Evidence of previous malicious behavior in blockchain ecosystem

### 3. Obvious Scam Indicators

- No evidence of actual infrastructure or development
- Team is anonymous with no verifiable history
- Project appears to be abandoned or unmaintained
- Smart contracts contain obvious backdoors or malicious code

### 4. Duplicate Registration

- Chain ID is already registered (even if in ClearingRequested state)
- Attempt to re-register a chain that was previously removed for cause

## Removal Criteria

A registered chain MAY be removed (challenged) if:

### 1. SLA or Governance Violations

- Consistent failure to maintain liveness requirements
- Failure to execute rotation handoffs as required by the sequencer SLA
- Refusal to comply with ISOCHRON governance decisions

### 2. Operational Abandonment

- Chain has been non-functional for > 30 days
- Team is unresponsive to operational issues for > 14 days
- Infrastructure has been shut down without notice

### 3. Changed Circumstances

- Chain ownership transferred to entity that doesn't meet acceptance criteria
- Fundamental change to chain's purpose that conflicts with ISOCHRON policies
- Chain requests voluntary removal

### 4. False Registration

- Discovery that original registration contained material misrepresentations
- Evidence emerges that technical requirements were not actually met

## Evidence Standards

### For Registration Challenges

Challengers MUST provide:

1. **Specific Criterion**: Which acceptance criterion is allegedly not met
2. **Supporting Evidence**: Links, screenshots, or other verifiable proof
3. **Explanation**: Clear explanation of why the evidence shows non-compliance

Examples of valid evidence:
- Block explorer links showing rollup config is not a valid contract
- Etherscan verification failure for submitted addresses
- Public records showing trademark infringement
- Historical data showing team's previous fraudulent projects

### For Removal Challenges

Challengers MUST provide:

1. **Specific Violation**: Which policy was violated
2. **Timestamped Evidence**: Evidence with verifiable timestamps
3. **Impact Assessment**: How the violation affects users/network
4. **Pattern Evidence**: For operational issues, evidence of repeated problems

Examples of valid evidence:
- Block production logs showing liveness failures
- Proof of forced rotations after missed handoffs
- Communication records showing team abandonment
- On-chain evidence of repeated SLA violations

## Dispute Resolution Process

### Challenge Period

- **Duration**: 5 days (default, configurable by governance)
- **Challenger Deposit**: Required deposit to prevent frivolous challenges
- **Evidence Submission**: Both parties can submit evidence during challenge period

### Arbitration

1. Dispute is created in the default arbitrator (Kleros Court today, Blockchain Technical)
2. Three jurors are drawn for initial round
3. Both parties present evidence
4. Jurors vote based on this policy
5. Standard default arbitrator appeal process applies (Kleros Court today)

### Ruling Guidelines for Jurors

When evaluating chain registrations:

1. **Benefit of the Doubt**: If evidence is ambiguous, rule in favor of the requester
2. **Proportionality**: Minor issues should not result in rejection if fixable
3. **Technical Verification**: For technical claims, prioritize on-chain evidence
4. **Context Matters**: Consider the overall good faith of the submission

When evaluating removals:

1. **Clear Evidence Required**: Removal requires clear evidence of violation
2. **Remediation Opportunity**: Consider if the issue can be fixed before removal
3. **Severity Assessment**: Minor violations may warrant warning before removal
4. **User Impact**: Prioritize user protection in decision-making

## Appeal Process

1. **First Appeal**: Requires 2x the number of jurors
2. **Subsequent Appeals**: Follow standard default arbitrator escalation (Kleros Court today)
3. **Final Round**: General Court for contentious disputes

## Governance

### Policy Updates

This policy may be updated by ISOCHRON governance through:
- Formal governance proposal
- Community discussion period (minimum 7 days)
- Majority vote by governance token holders

### Parameter Adjustments

The following parameters can be adjusted by governance:
- Challenge period duration
- Required deposit amounts
- Stake multipliers for challengers
- Court selection and juror counts

## Examples

### Example 1: Valid Registration

**Submission:**
- Chain ID: 42001
- RollupConfig: 0x1234... (verified rollup contract)
- Name: "Optimism Fork Alpha"
- Metadata: Valid IPFS URI with team info, infrastructure docs

**Assessment**: ACCEPT - All criteria met

### Example 2: Invalid RollupConfig

**Submission:**
- Chain ID: 42002
- RollupConfig: 0x5678... (regular EOA, not a contract)
- Name: "My L2 Chain"

**Challenge Evidence**: Etherscan shows address is EOA, not contract

**Assessment**: REJECT - Technical requirement not met

### Example 3: Removal for Sustained Liveness Failure

**Registered Chain**: Chain ID 42003

**Challenge Evidence**:
- Block production logs showing repeated 5+ minute outages
- Forced rotations after missed handoffs

**Assessment**: REMOVE - Clear violation of sequencer SLA

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-01 | Initial policy for ISOCHRON chain integration |
