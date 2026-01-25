# Kleros-Governed Decentralized Sequencer (OP Stack)

A decentralized sequencer management system for OP Stack chains, using Kleros Curate Classic for operator curation and subjective dispute resolution.

## Overview

This architecture decentralizes control of an OP Stack chain operator by separating:

- **Judgment / legitimacy** → **Kleros** (a curated registry with subjective dispute resolution)
- **Execution / enforcement** → **OP Stack L1 governance contract** (`SystemConfig`)

The key insight is that the OP Stack's `SystemConfig.batcherHash` is a privileged identity: it controls which L1 sender is considered the valid batch submitter for the chain's canonical transaction data derivation.

## Architecture

### Contracts

1. **Registry (Kleros Curate Classic)**: Standard Kleros GeneralizedTCR deployed on Ethereum L1
   - Item type: `Address` (operator's L1 address, ABI-encoded)
   - Deposits: configurable (e.g., 32 ETH to deter bad operators)
   - Constitution: text policy document stored on IPFS

2. **Manager (KlerosSequencerManager)**: Custom contract that:
   - Owns the OP Stack `SystemConfig`
   - Maintains a local active set of addresses that are accepted in the registry
   - Rotates the active operator address each epoch
   - Calls `SystemConfig.setBatcherHash(...)` to set the canonical batch submitter

## How It Works

### 1. Registration (Stake/Deposit)

1. Alice submits her L1 operator address to the Kleros TCR with a deposit
2. During the challenge period, the community may challenge if Alice is unfit
3. If no successful challenge occurs, the item becomes **Registered**

### 2. Activation (Sync into Manager)

Anyone calls `syncAddSequencer(alice)`:
- Manager checks the Kleros registry status
- If `Registered`, adds Alice to the local `activeSequencers` set

### 3. Rotation (Scheduled Authority Assignment)

Any keeper/bot calls `rotateSequencer()` once per epoch:
- Manager selects the next valid operator in the active set
- Sets `SystemConfig.batcherHash` to that operator's address (V0 format)
- This makes the selected operator the canonical batch submitter

### 4. Slashing / Boot (Subjective Enforcement)

If an operator misbehaves (MEV extraction, censorship, delays):

1. Someone challenges them in the Kleros TCR with evidence
2. Status changes to `ClearingRequested` (no longer `Registered`)
3. Anyone calls `syncRemoveSequencer(alice)`
4. Manager removes Alice from the active set immediately
5. Kleros resolves the dispute; if guilty, stake is slashed

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd op

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test
```

## Deployment

1. Deploy a Kleros Curate Classic TCR with your constitution parameters
2. Deploy `KlerosSequencerManager`:

```bash
export PRIVATE_KEY=<your-private-key>
export REGISTRY=<kleros-curate-address>
export SYSTEM_CONFIG=<op-stack-system-config-address>
export EPOCH_DURATION=3600  # 1 hour
export GUARDIAN=<guardian-address>

forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

3. Transfer ownership of OP Stack `SystemConfig` to the deployed manager:

```solidity
systemConfig.transferOwnership(managerAddress);
```

4. Add operators:

```solidity
manager.syncAddSequencer(operatorAddress);
```

5. Set up a keeper to call `rotateSequencer()` each epoch

## Key Functions

### Sync Functions

- `syncAddSequencer(address)`: Add a registered sequencer to the active set
- `syncRemoveSequencer(address)`: Remove a no-longer-registered sequencer

### Rotation

- `rotateSequencer()`: Rotate to the next valid sequencer (once per epoch)
- `poke()`: Alias for `rotateSequencer()`

### View Functions

- `activeSequencerCount()`: Number of active sequencers
- `getActiveSequencers()`: Array of all active sequencer addresses
- `currentSequencer()`: Currently selected sequencer
- `isRegisteredInRegistry(address)`: Check if address is registered in Kleros
- `timeUntilNextRotation()`: Seconds until next rotation is allowed

### Guardian Functions

- `setPaused(bool)`: Pause/unpause the contract
- `setGuardian(address)`: Transfer guardian role

## Security Considerations

### Bounded Operations

- All loops are bounded to prevent DoS
- O(1) add/remove using swap-pop pattern
- Safe `currentIndex` handling during removals

### Griefing Mitigation

The "boot-on-challenge" behavior is intentionally conservative. Potential mitigations:
- Higher challenge bond at TCR layer
- Only boot on `ClearingRequested` (current behavior)
- Add review delay or quorum threshold
- Maintain "active" vs "standby" pools

### Liveness

- If active set becomes empty, rotation emits `RotationSkippedNoValidSequencer`
- Contract self-cleans invalid entries during rotation
- Guardian can pause in emergencies

## Constitution Example

The constitution is intentionally subjective and dispute-resolvable via Kleros jurors. Example rules:

- Operator must not reorder transactions for personal profit (e.g., sandwiching)
- Operator must not delay inclusion of transactions with valid fees for >5 minutes
- Operator must not censor specific addresses/categories in a sustained manner
- Operator must not halt or degrade chain operation beyond defined SLA thresholds

## License

MIT
