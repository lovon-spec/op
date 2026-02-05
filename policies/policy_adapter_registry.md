# Adapter Registry Policy

## Overview

This document defines the acceptance policy for the **Adapter Registry**, an arbitrator registry (Kleros Curate by default) that governs which rollup adapters can be used by SharedSequencerHub to rotate sequencers.

## Purpose

The adapter pattern enables ISOCHRON to survive rollup upgrades without requiring changes to the core SharedSequencerHub contract. Adapters are hot-swapped via governance updates, which are permissionless but gated by:

1. **Arbitrator Arbitration (default: Kleros)**: Adapter must be registered in the Adapter Registry
2. **Ratchet Versioning**: New adapter version must be strictly greater than current

## Registry Type

- **Registry**: Kleros Curate (GeneralizedTCR, default arbitrator registry)
- **Court**: Blockchain Technical (Court ID: 4)
- **Challenge Period**: Recommended 5-7 days for security

## Item Format

Each item in the registry represents an adapter contract:

```
Adapter Address: 0x...
```

The item ID is computed as: `keccak256(abi.encode(adapterAddress))`

## Acceptance Criteria

An adapter MUST meet ALL of the following criteria to be accepted:

### 1. Implementation Requirements

- [ ] Implements `ISequencerAdapter` interface correctly
- [ ] `getRotationCalldata()` function returns correct calldata for the rollup-specific rotation
- [ ] `version()` returns a unique, monotonically increasing version number
- [ ] `adapterInfo()` returns accurate name and description

### 2. Security Requirements

- [ ] No backdoors or privileged functions beyond rotation logic
- [ ] No self-destruct capability
- [ ] No delegatecall to external contracts
- [ ] No state mutations (adapter functions must be view/pure)
- [ ] No arbitrary storage writes
- [ ] Reverts on invalid inputs (zero addresses)
- [ ] Proper error handling with descriptive revert reasons

### 3. Compatibility Requirements

- [ ] Compatible with the target rollup configuration contract
- [ ] Handles payload encoding/decoding without ambiguity
- [ ] Atomic rotation - all required fields updated or transaction reverts

### 4. Code Quality Requirements

- [ ] Source code verified on Etherscan/Blockscout
- [ ] Matches the deployed bytecode
- [ ] Clear, readable implementation
- [ ] No obfuscation

### 5. Version Requirements

- [ ] Version number follows semver format encoded as: `major * 1_000_000 + minor * 1_000 + patch`
- [ ] Example: v1.2.3 = 1_002_003
- [ ] Version is higher than any previously registered adapter

## Rejection Criteria

An adapter MUST be rejected if ANY of the following apply:

- Contains malicious code or backdoors
- Contains state-modifying functions (adapters must be view/pure)
- Makes external calls to untrusted contracts
- Has unverified source code
- Version number is not greater than existing registered adapters
- Does not properly implement the rotation logic
- Contains upgrade mechanisms that bypass arbitrator governance (default Kleros)

## Removal (Clearing) Criteria

A registered adapter MAY be removed if:

- A critical vulnerability is discovered
- The adapter becomes incompatible with rollup updates
- A superior adapter is available and community consensus supports removal

**Note**: The manager accepts adapters with `ClearingRequested` status to allow emergency upgrades while removal is being processed.

## Hydra Defense

Multiple adapters with the same version MAY be submitted to defeat griefing attacks:

- If an attacker challenges a legitimate adapter submission
- The community can submit an identical adapter at a different address
- First one to pass the challenge period becomes usable
- This prevents adapter upgrade griefing

## Example Submission

When submitting an adapter to the registry:

1. Deploy the adapter contract
2. Verify source code on Etherscan
3. Submit to Adapter Registry with evidence:
   - Contract address
   - Verified source code link
   - Audit report (if available)
   - Changelog from previous version
   - Compatibility notes

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01 | Initial policy |
