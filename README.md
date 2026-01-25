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

## Local Demo

Run a complete demonstration of the sequencer rotation lifecycle on a local Anvil testnet:

### Quick Start

```bash
# Terminal 1: Start Anvil
anvil --port 8546

# Terminal 2: Run the demo script
./script/run_demo.sh
```

### Manual Demo

```bash
# Start Anvil
anvil --port 8546

# Deploy contracts with test sequencers
forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8546 --broadcast

# Check current sequencer
cast call <MANAGER_ADDRESS> "currentSequencer()(address)" --rpc-url http://127.0.0.1:8546

# Wait for epoch (60 seconds by default) and rotate
cast send <MANAGER_ADDRESS> "rotateSequencer()" --rpc-url http://127.0.0.1:8546 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Simulated Demo (Fast)

Run the complete lifecycle in simulation mode (no waiting for epochs):

```bash
forge script script/Demo.s.sol:Demo --rpc-url http://127.0.0.1:8546 -vvvv
```

This demonstrates:
1. Contract deployment
2. Sequencer registration in Curate
3. Syncing sequencers to manager
4. Epoch-based rotation
5. Challenge and removal of misbehaving sequencer
6. Guardian pause/unpause

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

## OP Stack Integration

The KlerosSequencerManager is designed to integrate with the OP Stack by controlling the `SystemConfig.batcherHash`. Here's how it works with the OP Stack components:

### How It Integrates

1. **op-batcher**: The batch submitter reads `batcherHash` from `SystemConfig` to determine which address is authorized to submit batches. When `KlerosSequencerManager.rotateSequencer()` is called, it updates this hash to point to the new authorized sequencer.

2. **op-node**: The derivation pipeline validates that batch transactions come from the address specified in `batcherHash`. Only batches from the currently authorized sequencer are considered canonical.

3. **No Client Modifications**: This design works with standard OP Stack clients. The `KlerosSequencerManager` only modifies L1 contract state that the clients already read.

### Deployment with OP Stack

1. Deploy your OP Stack chain with standard `SystemConfig`
2. Deploy `KlerosSequencerManager` with the `SystemConfig` address
3. Transfer `SystemConfig` ownership to `KlerosSequencerManager`
4. Configure your op-batcher instances with the sequencer private keys
5. Register each sequencer address in the Kleros Curate registry
6. Set up a keeper to call `rotateSequencer()` each epoch

### Epoch-Based Rotation

Each epoch (configurable, e.g., 1 hour), a keeper calls `rotateSequencer()`:
- The manager selects the next valid sequencer in round-robin order
- Updates `SystemConfig.batcherHash` to the new sequencer's address
- The new sequencer's op-batcher can now submit canonical batches
- Previous sequencer's batches are no longer accepted by derivation

## Constitution Example

The constitution is intentionally subjective and dispute-resolvable via Kleros jurors. Example rules:

- Operator must not reorder transactions for personal profit (e.g., sandwiching)
- Operator must not delay inclusion of transactions with valid fees for >5 minutes
- Operator must not censor specific addresses/categories in a sustained manner
- Operator must not halt or degrade chain operation beyond defined SLA thresholds

## License

MIT
