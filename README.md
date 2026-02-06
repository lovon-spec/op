# ISOCHRON (Interconnected Sequencing Oracle for Cross-chain Harmonized Reliability, Ordering & Network)

A **universal shared sequencing layer** for multiple rollups, enabling atomic cross-chain execution, unified liquidity, fair MEV distribution, and sovereign chain policies. The core framework is rollup-agnostic with chain-specific adapters (OP Stack, Arbitrum Nitro, Generic EVM), arbitrator-based governance (Kleros default), and a Rust relay for time-sensitive bundle processing.

## What is ISOCHRON?

**ISOCHRON** is a universal shared sequencing layer that manages sequencing authority for multiple rollups from a single Hub contract. It enables **atomic cross-chain bundle execution**, **sovereign per-chain policies**, and **fair MEV distribution** while preserving individual chain sovereignty through opt-in rotation and SLA-based governance.

The default block building mechanism is **MEV-Boost + Flashblocks** (private mempool), but the architecture is fully pluggable - chains can opt into public mempool, encrypted mempool, or custom building mechanisms via the BuilderRegistry.

**Key Features:**
- **Hub-and-Spoke Architecture**: Single Hub manages multiple L2 chains atomically
- **Atomic Cross-Chain Bundles**: Multi-chain transaction bundles with commitment, verification, and escrow
- **Universal Chain Support**: Adapters for OP Stack, Arbitrum Nitro, and any EVM rollup (Cosmos planned)
- **Sovereign Policies**: Each chain declares its own sequencing rules (ordering, MEV, timing, inclusion)
- **Deterministic Fraud Proofs**: On-chain verifiable proofs for timing, ordering, inclusion, and bundle violations
- **Kleros Arbitration**: Subjective criteria (MEV violations) escalated to decentralized arbitration
- **Pluggable Builders**: MEV-Boost + Flashblocks default, upgradeable to any building mechanism
- **Rust Relay**: Time-sensitive bundle processing, validation, and policy enforcement
- **Active Handoff Protocol**: Zero-downtime proposer transitions with grace period
- **Scalable**: Sharded rotation supports thousands of chains
- **No Trusted Setups**: No hardcoded TEEs (chains may opt-in via sovereign policy)

## Policies & SLAs

ISOCHRON governance is anchored by formal policies enforced through an arbitrator (Kleros is the default arbitrator today):

| Policy | Description |
|--------|-------------|
| [Sequencer Policy](./policies/policy_sequencer_registry.md) | Service-level requirements for sequencer operators |
| [Adapter Policy](./policies/policy_adapter_registry.md) | Acceptance criteria for rollup adapters |
| [Chain Registry Policy](./policies/policy_chain_registry.md) | Acceptance/removal criteria for ISOCHRON chain integration |

These policies define:
- **Acceptance Criteria**: Requirements for registration (Sybil resistance, operational readiness)
- **Service-Level Requirements**: Grounds for removal (missed handoffs, liveness failures)
- **Evidence Standards**: How violations are proven

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (for development)

### Start Local Devnet (One Command)

```bash
git clone <repository-url>
cd op
./start.sh
```

This starts L1 with governance contracts:
- **L1**: Local Anvil chain (localhost:8545)
- **Governance**: SharedSequencerHub with mock arbitrator registry
- **Operators**: 3 test operators registered and ready for rotation

### Start Full L2 Stack

To run the complete L2 with op-geth, op-node, and op-batcher:

```bash
./start.sh l2
```

This starts:
| Service | URL | Description |
|---------|-----|-------------|
| L1 RPC | http://localhost:8545 | Anvil (chain ID: 31337) |
| L2 RPC | http://localhost:9545 | op-geth (chain ID: 42069) |
| L2 WS | ws://localhost:9546 | WebSocket endpoint |
| Rollup RPC | http://localhost:9547 | op-node |

### Send a Transaction on L2

```bash
# Check L2 is running
cast chain-id --rpc-url http://localhost:9545

# Send ETH on L2
cast send --rpc-url http://localhost:9545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --value 0.1ether 0x70997970C51812dc3A010C7d01b50e0d17dc79C8

# Check L2 block number
cast block-number --rpc-url http://localhost:9545
```

### Run the Integration Test

```bash
./start.sh test
```

### View Status and Logs

```bash
./start.sh status   # Show L1 and L2 status
./start.sh logs     # Stream logs from all services
./start.sh stop     # Stop all services
./start.sh clean    # Clean all data and start fresh
```

### Development

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install dependencies
forge install

# Build contracts
forge build

# Run all Solidity tests (228 tests across 9 test suites)
forge test

# Build Rust relay
cd relay && cargo build --release

# Run Rust relay tests
cd relay && cargo test
```

## Architecture

### ISOCHRON Hub-and-Spoke Architecture

The ISOCHRON uses a Hub-and-Spoke model anchored by a ProposerRegistry:

```
                        ISOCHRON HUB-AND-SPOKE ARCHITECTURE

  ┌────────────────────────────────────────────────────────────────────────────┐
  │                                L1 (Ethereum)                                │
  │                                                                            │
  │     ┌─────────────────────┐                                                │
  │     │  ProposerRegistry   │                                                │
  │     │  "The Dumb Pipe"    │                                                │
  │     │                     │                                                │
  │     │  - Top-N DPoS       │                                                │
  │     │  - Liveness Focus   │                                                │
  │     └──────────┬──────────┘                                                │
  │                │                                                           │
  │                ▼                                                           │
  │     ┌──────────────────────────────┐                                       │
  │     │    SharedSequencerHub        │                                       │
  │     │    (Central Authority)       │                                       │
  │     │                              │                                       │
  │     │  - rotateNetwork()           │  ◄── Atomic Multichain Rotation        │
  │     │  - connectChain()            │                                       │
  │     │  - rotateShard()             │                                       │
  │     └──────────────┬───────────────┘                                       │
  │                    │                                                      │
  │         ┌──────────┼──────────┐                                           │
  │         │          │          │                                           │
  │         ▼          ▼          ▼                                           │
  │  ┌────────────┐ ┌────────────┐ ┌────────────┐                              │
  │  │ RollupConfig│ │ RollupConfig│ │ RollupConfig│ (Spokes)                    │
  │  │ Chain A     │ │ Chain B     │ │ Chain C     │                              │
  │  └────────────┘ └────────────┘ └────────────┘                              │
  │                                                                            │
  └────────────────────────────────────────────────────────────────────────────┘

                              ATOMIC ROTATION
  ┌────────────────────────────────────────────────────────────────────────────┐
  │                                                                            │
  │   rotateNetwork() updates ALL chains in a single transaction:              │
  │                                                                            │
  │   for (chain in connectedChains) {                                         │
  │       calls = adapter.getRotationCalldata(chain.rollupConfig, rotationData)  │
  │       for (call in calls) { rollupConfig.call(call) }                       │
  │   }                                                                        │
  │                                                                            │
  │   Gas: ~60k per chain | Max: ~450 chains per block at 30M gas limit         │
  │                                                                            │
  └────────────────────────────────────────────────────────────────────────────┘
```

### Universal Sequencing Layer

The universal sequencing layer extends the Hub-and-Spoke model with four interconnected subsystems:

```
                    UNIVERSAL SEQUENCING LAYER

  ┌──────────────────────────────────────────────────────────────────────┐
  │                         SharedSequencerHub                          │
  │                       (Central Nervous System)                      │
  │                                                                     │
  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌──────────┐ │
  │  │   Bundle     │  │   Builder   │  │   Policy     │  │  Fraud   │ │
  │  │  Registry    │  │  Registry   │  │  Manager     │  │  Proof   │ │
  │  │             │  │             │  │              │  │ Verifier │ │
  │  │ Cross-chain │  │ MEV-Boost + │  │ Per-chain    │  │ Timing,  │ │
  │  │ atomic      │  │ Flashblocks │  │ sovereign    │  │ ordering │ │
  │  │ bundles     │  │ (default)   │  │ sequencing   │  │ inclusion│ │
  │  │             │  │             │  │ rules        │  │ proofs   │ │
  │  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘  └────┬─────┘ │
  └─────────┼───────────────┼───────────────┼──────────────┼──────────┘
            │               │               │              │
            ▼               ▼               ▼              ▼
  ┌──────────────┐  ┌──────────────┐ ┌───────────┐  ┌──────────────┐
  │ BundleEscrow │  │ Flashblocks  │ │ Default   │  │   Kleros     │
  │              │  │ Builder      │ │ Policy    │  │  Arbitrator  │
  │ Tips, bonds, │  │              │ │           │  │              │
  │ slashing     │  │ Private      │ │ FCFS +    │  │  Subjective  │
  │ (10% reward) │  │ mempool      │ │ sandwich  │  │  dispute     │
  │              │  │ relay        │ │ protection│  │  resolution  │
  └──────────────┘  └──────────────┘ └───────────┘  └──────────────┘
```

**Subsystem Overview:**

| Subsystem | Contract | Purpose |
|-----------|----------|---------|
| **Bundle Execution** | `CrossChainBundleRegistry` + `BundleEscrow` | Atomic multi-chain bundles with tip/bond escrow |
| **Block Building** | `BuilderRegistry` + `FlashblocksBuilder` | Pluggable builders, MEV-Boost + Flashblocks default |
| **Sovereign Policy** | `SovereignPolicyManager` + `DefaultPolicy` | Per-chain sequencing rules and compliance checking |
| **Fraud Proofs** | `FraudProofVerifier` | Deterministic proofs + Kleros escalation |

### Cross-Chain Bundle Execution

Bundles allow atomic multi-chain transaction execution with economic guarantees:

```
                CROSS-CHAIN BUNDLE LIFECYCLE

  Sequencer                BundleRegistry            BundleEscrow
  ─────────                ──────────────            ────────────
       │                        │                         │
       │  1. commitBundle()     │                         │
       │   + tip + chain IDs    │                         │
       │───────────────────────▶│  2. Escrow tip          │
       │                        │────────────────────────▶│
       │                        │                         │
       │  3. Execute on each chain (off-chain)            │
       │                        │                         │
       │  4. confirmChainExecution(chainId, proof)        │
       │───────────────────────▶│                         │
       │  (repeated per chain)  │                         │
       │                        │                         │
       │  5. completeBundle()   │                         │
       │───────────────────────▶│  6. Release tip         │
       │                        │────────────────────────▶│
       │                        │                         │
       │              FAILURE PATH:                       │
       │                        │                         │
       │  reportViolation()     │  slashBond()            │
       │───────────────────────▶│────────────────────────▶│
       │                        │  10% → reporter         │
       │                        │  90% → governance       │
```

**Bundle States:** `Committed` → `Executed` (success) or `Expired` / `Violated` / `Cancelled` (failure)

**Economic Guarantees:**
- Sequencer posts a bond when committing bundles
- Tips incentivize timely execution
- Violated bundles trigger bond slashing (10% to reporter, 90% to governance treasury)
- Expired bundles can be cleaned up by anyone after deadline

### Sovereign Policy System

Each chain can declare its own sequencing rules that the active sequencer must obey:

```
                    SOVEREIGN POLICY ARCHITECTURE

  Chain A Governance          SovereignPolicyManager        FraudProofVerifier
  ──────────────────          ──────────────────────        ──────────────────
       │                              │                            │
       │  declarePolicy(              │                            │
       │    chainId: A,               │                            │
       │    ordering: FCFS,           │                            │
       │    enforcement: Hybrid,      │                            │
       │    maxBlockTime: 2s,         │                            │
       │    sandwichProtection: true  │                            │
       │  )                           │                            │
       │─────────────────────────────▶│                            │
       │                              │                            │
       │                              │  Policy violation?         │
       │                              │───────────────────────────▶│
       │                              │                            │
       │                              │  Deterministic proof       │
       │                              │  (timing, ordering,        │
       │                              │   inclusion) OR            │
       │                              │  Kleros escalation         │
       │                              │  (MEV, subjective)         │
```

**Ordering Strategies:**
| Strategy | Description |
|----------|-------------|
| `SequencerDiscretion` | Sequencer chooses order freely (default) |
| `PriorityFee` | Order by gas price / priority fee |
| `FCFS` | First-come-first-served ordering |
| `Custom` | Delegated to a custom policy contract |

**Enforcement Types:**
| Type | Description |
|------|-------------|
| `Deterministic` | On-chain verifiable (timing, ordering, inclusion) |
| `Subjective` | Requires human judgment (MEV violations) → Kleros |
| `Hybrid` | Deterministic where possible, Kleros for the rest |

### Fraud Proof Verification

The FraudProofVerifier supports two verification paths:

**Deterministic Proofs** (trustless, on-chain):
| Proof Type | Verification Logic |
|------------|-------------------|
| `TimingViolation` | Block gap exceeds chain's `maxBlockTime` |
| `OrderingViolation` | FCFS misordering (earlier nonce sequenced later) |
| `InclusionViolation` | Transaction censored past `forcedInclusionDeadline` |
| `BundleViolation` | Committed bundle deadline passed without execution |

**Subjective Proofs** (Kleros arbitration):
| Proof Type | Escalation |
|------------|------------|
| `MEVViolation` | Sandwich attacks, front-running when policy prohibits |
| `CustomViolation` | Chain-specific rule violations |
| `UnjustifiedPause` | Circuit breaker pause was not justified (disputed via Kleros) |

**Challenge Flow:**
1. Challenger posts bond (0.5 ETH default) with proof data
2. For deterministic types: `verifyDeterministicProof()` resolves immediately
3. For subjective types: `escalateToArbitration()` creates Kleros dispute
4. If no response within 24h: auto-accepted (challenger wins)
5. Bond returned to winner, slashed from loser

### Chain Adapters

ISOCHRON uses adapters for plug-and-play integration without modifying member chains:

| Adapter | Chain Type | Rotation Mechanism |
|---------|-----------|-------------------|
| `OpStackAdapterV1` | OP Stack (Bedrock/Ecotone) | `setBatcherHash()` + `setUnsafeBlockSigner()` |
| `ArbitrumAdapterV1` | Arbitrum Nitro | `setIsBatchPoster()` on SequencerInbox |
| `GenericAdapterV1` | Any EVM rollup | Arbitrary function calls (single or multi-call) |

The `GenericAdapterV1` supports two modes:
- **Single-call**: `abi.encode(bytes4 selector, bytes callData)` - calls one function
- **Multi-call**: prefix `0xFF` + `abi.encode(bytes4[] selectors, bytes[] callDatas)` - calls multiple functions atomically

### Builder System

The BuilderRegistry manages approved block builders with per-chain overrides:

```
  BuilderRegistry
  ├── defaultBuilder: FlashblocksBuilder (MEV-Boost + Flashblocks)
  ├── chainBuilders:
  │   ├── Chain 10 (OP): FlashblocksBuilder
  │   ├── Chain 42161 (Arb): FlashblocksBuilder
  │   └── Chain 8453 (Base): CustomBuilder (future)
  └── builderTypes:
      ├── PrivateMempool  (Flashblocks, MEV-Boost)
      ├── PublicMempool   (standard building)
      ├── EncryptedMempool (threshold encryption, future)
      └── Custom          (chain-specific)
```

Each builder validates build requests (chain support, gas limits, bundle count, timestamps) and exposes a relay endpoint for discoverability.

### Rust Relay

The `isochron-relay` crate handles time-sensitive components that benefit from Rust's performance:

```
relay/
├── src/
│   ├── main.rs           # Entry point, initializes all components
│   ├── config.rs         # TOML-based relay configuration
│   ├── bundle/
│   │   ├── types.rs      # Bundle, operation, commitment types
│   │   ├── validator.rs  # Bundle validation (ops, deadline, chains, gas)
│   │   └── sequencer.rs  # Bundle lifecycle management
│   ├── chain/
│   │   └── mod.rs        # Chain adapter registration and management
│   ├── policy/
│   │   └── mod.rs        # Real-time policy compliance engine
│   └── relay/
│       └── mod.rs        # HTTP API server (health, bundles)
```

**API Endpoints:**
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check and bundle count |
| `POST` | `/bundles` | Submit a cross-chain bundle |
| `GET` | `/bundles/:id` | Query bundle status |

### Chain Integration Framework

ISOCHRON provides a decentralized onboarding path for new chains via the **ChainRegistry** (GeneralizedTCR):

```
                    CHAIN INTEGRATION FLOW

  Chain Team                    ChainRegistry              SharedSequencerHub
  ───────────                   ─────────────              ──────────────────
       │                              │                            │
       │  1. Deploy rollup chain      │                            │
       │     with config contract     │                            │
       │                              │                            │
       │  2. Register via             │                            │
       │     ChainDeploymentKit       │                            │
       │─────────────────────────────▶│                            │
       │     + deposit + metadata     │                            │
       │                              │                            │
       │                              │  3. Challenge Period       │
       │                              │     (Community curation)   │
       │                              │                            │
       │                              │  4. Status: Registered     │
       │                              │────────────────────────────▶│
       │                              │                            │
       │                              │  5. Hub connects chain     │
       │                              │     connectChainFromRegistry│
       │                              │                            │
       │  6. Chain is now part of ISOCHRON!                            │
       │     Atomic rotation enabled                               │
       │                              │                            │
```

**Key Components:**

| Component | Type | Purpose |
|-----------|------|---------|
| **ChainRegistry** | GeneralizedTCR | Decentralized chain application registry |
| **ChainDeploymentKit** | Helper | Simplified interface for chain teams |

**ChainRegistry vs PermanentGTCR:**

Unlike the operator registries (which use PermanentGTCR with permanent stakes), the ChainRegistry uses a **standard GeneralizedTCR** where:
- Deposits are **returned** after successful registration
- No perpetual stake requirement
- Focus on chain metadata validation, not ongoing operational compliance
- Community can challenge invalid applications during challenge period

**Registration Requirements:**
- Valid rollup deployment with accessible configuration contract (e.g., OP Stack SystemConfig)
- Chain team has operational capability
- No duplicate chain IDs
- Alignment with ISOCHRON sequencer SLA requirements

### Cold Staker / Hot Operator Model

Separating stake ownership from operational keys improves security:

| Role | Description | Registry Field |
|------|-------------|----------------|
| **Staker (Owner)** | Holds governance stake, can update keys | `item.submitter` |
| **Batcher** | Posts batches to L1 (hot key) | `itemKeys[itemID].batcher` |
| **Unsafe Signer** | Signs P2P unsafe blocks (hot key) | `itemKeys[itemID].unsafeSigner` |

**Recommendation**: Use different addresses for Staker vs Operational Keys. If hot keys are compromised, the governance stake remains safe.

### Proposer Key Model (OP Stack PoC)

**CRITICAL**: OP Stack sequencer authority requires TWO keys rotated together:

| Key | Purpose | SystemConfig Function |
|-----|---------|----------------------|
| **Batcher** | Posts batches to L1 | `setBatcherHash()` |
| **Unsafe Signer** | Signs P2P unsafe blocks | `setUnsafeBlockSigner()` |

Both keys are registered with each proposer and rotated atomically across ALL chains by the Hub via adapters.

```
                        PROPOSER ROTATION FLOW (ISOCHRON)

  ┌───────────────────────────────────────────────────────────────────────────┐
  │                              L1 (Ethereum)                                 │
  │                                                                           │
  │     ProposerRegistry                      SharedSequencerHub              │
  │  ┌─────────────────────┐              ┌─────────────────────┐             │
  │  │  DPoS Selection     │              │  Central Authority  │             │
  │  │                     │              │                     │             │
  │  │  Top-N Active Set   │ ◀──────────▶ │  currentProposer    │             │
  │  │  ├─ stake           │              │  currentEpoch       │             │
  │  │  └─ operationalKey  │              │  connectedChains[]  │             │
  │  │                     │              │                     │             │
  │  │  selectNextProposer │              │  rotateNetwork()    │             │
  │  └─────────────────────┘              └──────────┬──────────┘             │
  │                                                  │                        │
  │              ┌───────────────────────────────────┼─────────────────────┐  │
  │              │                                   │                     │  │
  │              ▼                                   ▼                     ▼  │
  │     ┌─────────────────┐              ┌─────────────────┐   ┌─────────────────┐
  │     │  SystemConfig   │              │  SystemConfig   │   │  SystemConfig   │
  │     │  Chain A        │              │  Chain B        │   │  Chain C        │
  │     └─────────────────┘              └─────────────────┘   └─────────────────┘
  │                                                                           │
  └───────────────────────────────────────────────────────────────────────────┘
                                                     │
           ┌─────────────────────────────────────────┼─────────────────────────┐
           │                                         │                         │
           ▼                                         ▼                         ▼
   ┌───────────────────┐                    ┌───────────────────┐    ┌───────────────────┐
   │   Proposer A      │                    │   Proposer B      │    │   Proposer C      │
   │                   │                    │                   │    │                   │
   │ ┌───────────────┐ │                    │ ┌───────────────┐ │    │ ┌───────────────┐ │
   │ │   Proposer    │ │                    │ │   Proposer    │ │    │ │   Proposer    │ │
   │ │    Agent      │ │                    │ │    Agent      │ │    │ │    Agent      │ │
   │ └───────┬───────┘ │                    │ └───────┬───────┘ │    │ └───────┬───────┘ │
   │         │         │                    │         │         │    │         │         │
   │ ┌───────▼───────┐ │                    │ ┌───────▼───────┐ │    │ ┌───────▼───────┐ │
   │ │   op-node     │ │                    │ │   op-node     │ │    │ │   op-node     │ │
   │ │  op-batcher   │ │                    │ │  op-batcher   │ │    │ │  op-batcher   │ │
   │ │  (stopped)    │ │                    │ │  (ACTIVE)     │ │    │ │  (stopped)    │ │
   │ └───────────────┘ │                    │ └───────────────┘ │    │ └───────────────┘ │
   └───────────────────┘                    └───────────────────┘    └───────────────────┘
```

### Proposer Agents

Each proposer MUST run a proposer agent that:
1. Monitors `isCurrentProposer(address)` on SharedSequencerHub
2. Starts local op-node sequencer + op-batcher when becoming active
3. Stops them when no longer active
4. Calls `rotateNetwork()` during grace period

This is an **SLA requirement** - proposers that produce blocks while unauthorized can be challenged and removed.

See [`agent/`](./agent/) for a reference implementation.

### Active Handoff Protocol

The Active Handoff protocol ensures **zero-downtime** operator transitions with no L2 re-orgs. It uses a **3-Phase State Machine**:

```
                    ACTIVE HANDOFF 3-PHASE STATE MACHINE

  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                                                         │
  │   Phase 1: PROTECTED           Phase 2: VOLUNTARY         Phase 3: FORCED
  │   (0 → epochDuration)          (+ GRACE_PERIOD)           (Dead Man's Switch)
  │                                                                         │
  │   ┌─────────────────────┐  ┌───────────────────────┐  ┌───────────────┐ │
  │   │ Nobody can rotate   │  │ ONLY current operator │  │ Anyone can    │ │
  │   │ Standard operation  │  │ can trigger rotation  │  │ force rotate  │ │
  │   │                     │  │                       │  │               │ │
  │   │ Operator produces   │  │ Operator:             │  │ Liveness      │ │
  │   │ blocks normally     │  │ 1. Stops sequencing   │  │ fallback if   │ │
  │   │                     │  │ 2. Flushes batches    │  │ operator is   │ │
  │   │                     │  │ 3. Calls rotate()     │  │ unresponsive  │ │
  │   └─────────────────────┘  └───────────────────────┘  └───────────────┘ │
  │                                                                         │
  │   Time: 0 ─────────────── epochDuration ────────── +GRACE_PERIOD ────▶  │
  │                                (1 hour)              (10 minutes)       │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘
```

**3-Phase Rotation:**

| Phase | Time Window | Who Can Rotate | Purpose |
|-------|-------------|----------------|---------|
| **1 - Protected** | `0` → `epochDuration` | Nobody | Standard operation |
| **2 - Voluntary** | `epochDuration` → `+GRACE_PERIOD` | **Current Operator Only** | Flush batches, then rotate atomically |
| **3 - Forced** | After Phase 2 | Anyone | Dead Man's Switch (liveness fallback) |

The grace period ensures the outgoing operator can flush all pending batches to L1 before triggering rotation, preventing any transaction orphaning.

**Handoff Sequence (Operator Agent):**
1. **Monitor**: Watch for epoch end approaching
2. **Prepare**: Stop accepting new transactions
3. **Flush**: Force `op-batcher` to submit all pending unsafe blocks to L1
4. **Rotate**: Call `rotateNetwork()` (ideally in same tx or immediately after batch confirms)
5. **Handover**: New operator's agent sees L1 state change and immediately starts sequencing

**Constants:**
- `GRACE_PERIOD = 600` (10 minutes)

### How It Works

1. **Proposers Register**: Submit stake to ProposerRegistry with operational keys
2. **DPoS Selection**: Top-N stakers (by own + delegated stake) are in the active set
3. **Chains Register**: Chains apply to ChainRegistry via ChainDeploymentKit
4. **Hub Connects Chains**: After challenge period, governance connects chains to Hub
5. **Epoch Operation**: Current proposer produces blocks for `epochDuration` on ALL chains
6. **Active Handoff**: At epoch end, proposer flushes batches and calls `rotateNetwork()` (grace period protects this)
7. **Atomic Update**: Hub updates each rollup configuration contract on ALL connected chains
8. **Proposer Agent Activation**: New proposer's agent detects the change and immediately starts sequencing
9. **SLA Enforcement**: Misbehaving proposers challenged via the arbitrator (default: Kleros)

### Sequencer SLA (Summary)

The full SLA is defined in [`policies/policy_sequencer_registry.md`](./policies/policy_sequencer_registry.md).

**Key Requirements:**

| Requirement | Violation | Evidence Standard |
|-------------|-----------|-------------------|
| **Authorized Production** | Producing blocks when unauthorized | L1 timestamp vs epoch |
| **Active Handoff** | Missed rotation during grace period | Forced rotation evidence |
| **Liveness** | >5 minute downtime during epoch | Block production gaps |

**Liveness Enforcement:** The Hub reports each outgoing proposer's liveness score to the `ProposerRegistry` during every `rotateNetwork()` / `rotateShard()` call. Proposers who rotate within the grace period receive full liveness credit; forced rotations (past grace period) are penalized proportionally. Liveness scores below 95% trigger automatic slashing. Chains may designate a **circuit breaker** address (e.g., a security council multisig) in their policy that can officially pause sequencing via `setPause()`. Paused chains immunize the sequencer from `TimingViolation` slashing. Unjustified pauses can be disputed via `ProofType.UnjustifiedPause` through Kleros arbitration.

See the [Sequencer Policy](./policies/policy_sequencer_registry.md) for detailed evidence standards.

## Smart Contracts

### SharedSequencerHub (ISOCHRON)

The central nervous system of ISOCHRON - manages atomic rotation across all connected chains.

```solidity
// Chain configuration for each connected Spoke
struct ChainConfig {
    address rollupConfig;   // The rollup configuration contract
    address adapter;        // Adapter for rollup compatibility
    bool isActive;          // Whether this chain is active
    uint256 chainId;        // The L2 chain ID
}

// Core state
address public currentProposer;           // Current active proposer
uint256 public currentEpoch;              // Current epoch number
uint256 public epochDuration;             // Rotation interval (default: 1 hour)
uint256 public gracePeriod;               // Active Handoff window (default: 10 min)
address public proposerRegistry;          // ProposerRegistry contract

// Rotation functions (report outgoing proposer liveness to ProposerRegistry on each rotation)
function rotateNetwork() external;        // Atomic rotation of ALL chains
function rotateShard(uint256 shardIndex); // For scaling beyond 400 chains

// Chain management (governance only)
function connectChain(uint256 chainId, address rollupConfig, address adapter);
function disconnectChain(uint256 chainId);
function updateChainConfig(uint256 chainId, address adapter);

// View functions
function getChainCount() external view returns (uint256);
function getChainConfig(uint256 chainId) external view returns (ChainConfig memory);
function isCurrentProposer(address proposer) external view returns (bool);
function timeUntilNextRotation() external view returns (uint256);
function isRotationWindowOpen() external view returns (bool);

// Guardian (emergency controls)
function pause() external;
function emergencyRotate(address newProposer) external;
```

### ProposerRegistry

"The Dumb Pipe" - manages DPoS-based proposer selection with liveness focus.

```solidity
struct ProposerInfo {
    uint256 stake;              // Own stake
    uint256 delegatedStake;     // Stake delegated by others
    bool isActive;              // In the active set
    bool isRegistered;          // Registered in system
    uint256 livenessScore;      // 0-10000 (100.00%)
    address operationalKey;     // Key for block signing
}

// Configuration
uint256 public minimumStake;        // Default: 32 ETH
uint256 public maxActiveSetSize;    // Default: 100

// Proposer functions
function register(address operationalKey) external payable;
function addStake() external payable;
function withdrawStake(uint256 amount) external;
function updateOperationalKey(address newKey) external;

// Delegation
function delegate(address proposer) external payable;
function undelegate(address proposer, uint256 amount) external;

// Public functions
function rebalance() external;  // Swap low-stake active with high-stake inactive

// Selection & liveness (called by Hub during rotation)
function selectNextProposer(uint256 epoch) external view returns (address);
function reportLiveness(address proposer, uint256 epoch, uint256 blocksProduced, uint256 blocksExpected) external;
function slashForLiveness(address proposer, uint256 basisPoints) external;

// View functions
function getActiveProposers() external view returns (address[] memory);
function getTotalStake(address proposer) external view returns (uint256);
function isActiveProposer(address proposer) external view returns (bool);
```

### ChainRegistry

GeneralizedTCR for decentralized chain onboarding to ISOCHRON:

```solidity
// Chain registration data
struct ChainData {
    uint256 chainId;         // L2 chain ID
    address rollupConfig;    // Rollup configuration contract on L1
    address adapter;         // Rollup adapter
    string name;             // Human-readable name
    string metadataURI;      // IPFS URI with additional info
}

// Item status
enum Status {
    Absent,                  // Not in registry
    RegistrationRequested,   // Pending, in challenge period
    Registered,              // Registered and eligible
    ClearingRequested        // Removal pending
}

// Registration functions
function addChain(
    uint256 chainId,
    address rollupConfig,
    address adapter,
    string name,
    string metadataURI
) external payable returns (bytes32 itemId);

function removeChain(uint256 chainId) external payable;
function challengeRequest(bytes32 itemId, string evidence) external payable;
function executeRequest(bytes32 itemId) external;

// View functions
function isRegistered(uint256 chainId) external view returns (bool);
function getRegisteredChains() external view returns (uint256[] memory);
function getItemByChainId(uint256 chainId) external view returns (Item memory);
```

### ChainDeploymentKit

Helper contract for easy chain integration into ISOCHRON:

```solidity
// Registration status tracking
enum RegistrationStatus {
    NotStarted,     // Chain hasn't been registered
    Pending,        // In challenge period
    Registered,     // Successfully registered
    Connected,      // Connected to ISOCHRON Hub
    Failed          // Registration failed (challenged)
}

// Simple registration
function registerChain(
    uint256 chainId,
    address rollupConfig,
    string name,
    string metadataURI
) external payable returns (bytes32 itemId);

// With custom adapter
function registerChainWithAdapter(
    uint256 chainId,
    address rollupConfig,
    address adapter,
    string name,
    string metadataURI
) external payable returns (bytes32 itemId);

// Finalize after challenge period
function finalizeRegistration(uint256 chainId) external;

// View functions
function getStatus(uint256 chainId) external view returns (RegistrationStatus);
function isReadyForConnection(uint256 chainId) external view returns (bool);
function getChallengeTimeRemaining(uint256 chainId) external view returns (uint256);
function getRequiredDeposit() external view returns (uint256);
```

### ISequencerAdapter

Hot-swappable adapter interface for rollup compatibility:

```solidity
interface ISequencerAdapter {
    // Version for ratchet upgrade logic (v1.0.0 = 1_000_000)
    function version() external view returns (uint256);
    function adapterInfo() external view returns (string memory name, string memory description);

    // Called via regular call from the hub; returns calldata for hub to execute
    function getRotationCalldata(
        address _rollupConfig,
        bytes calldata _rotationData
    ) external view returns (bytes[] memory calls);
}
```

### CrossChainBundleRegistry

Manages atomic cross-chain bundle commitments with escrow integration:

```solidity
// Bundle lifecycle
function commitBundle(
    bytes32 operationsHash,
    uint256[] calldata targetChainIds,
    uint256 deadline
) external payable returns (bytes32 bundleId);

function confirmChainExecution(
    bytes32 bundleId, uint256 chainId, uint256 blockNumber, bytes calldata proof
) external;

function completeBundle(bytes32 bundleId) external;
function cancelBundle(bytes32 bundleId) external;
function expireBundle(bytes32 bundleId) external;
function reportViolation(bytes32 bundleId, bytes calldata proof, string calldata reason) external;

// View functions
function getBundle(bytes32 bundleId) external view returns (BundleCommitment memory);
function getBundleStatus(bytes32 bundleId) external view returns (BundleStatus);
function getPendingBundleCount() external view returns (uint256);
function getSequencerBundles(address sequencer) external view returns (bytes32[] memory);
```

### BundleEscrow

Holds tips and bonds for cross-chain bundles:

```solidity
function depositTip(bytes32 bundleId) external payable;
function postBond(bytes32 bundleId) external payable;
function releaseTip(bytes32 bundleId) external;      // Only by BundleRegistry
function slashBond(bytes32 bundleId, address reporter) external; // 10% reporter, 90% governance
function refundTip(bytes32 bundleId) external;
function returnBond(bytes32 bundleId) external;
```

### SovereignPolicyManager

Per-chain sovereign policy management:

```solidity
// Policy declaration (by chain governance or hub governance)
function declarePolicy(
    uint256 chainId,
    OrderingStrategy ordering,
    EnforcementType enforcement,
    uint256 maxBlockTime,
    uint256 forcedInclusionDeadline,
    bool sandwichProtection,
    bool backrunOnly,
    address customPolicyContract,
    bytes calldata policyData
) external;

// Policy declaration with circuit breaker (sovereign security halt)
function declarePolicyWithCircuitBreaker(
    uint256 chainId,
    OrderingStrategy ordering,
    EnforcementType enforcement,
    uint256 maxBlockTime,
    uint256 forcedInclusionDeadline,
    bool sandwichProtection,
    bool backrunOnly,
    address customPolicyContract,
    bytes calldata policyData,
    address circuitBreaker          // Address authorized to pause sequencing
) external;

// Circuit breaker: pause/unpause sequencing (callable only by circuitBreaker)
// When paused, sequencer is immunized from TimingViolation slashing.
// Unjustified pauses can be disputed via ProofType.UnjustifiedPause (Kleros).
function setPause(uint256 chainId, bool paused) external;
function getChainPauseInfo(uint256 chainId) external view returns (bool isPaused, uint256 pauseTimestamp, uint256 unpauseTimestamp);

function deactivatePolicy(uint256 chainId) external;
function checkCompliance(uint256 chainId, bytes calldata txData) external view returns (ComplianceResult memory);
function getPolicy(uint256 chainId) external view returns (PolicyDeclaration memory);
function getActivePolicyChains() external view returns (uint256[] memory);

// Chain governance
function setChainGovernance(uint256 chainId, address governor) external; // Hub governance only
```

### FraudProofVerifier

Two-path fraud proof verification with Kleros escalation:

```solidity
// Challenge submission
function submitChallenge(
    address sequencer,
    uint256 chainId,
    ProofType proofType,
    bytes calldata proofData
) external payable returns (bytes32 challengeId);

// Verification
function verifyDeterministicProof(bytes32 challengeId) external;
function escalateToArbitration(bytes32 challengeId) external payable;
function resolveChallenge(bytes32 challengeId) external; // Auto-accept after deadline

// View functions
function getChallenge(bytes32 challengeId) external view returns (Challenge memory);
function getChallengeStatus(bytes32 challengeId) external view returns (ChallengeStatus);

// Governance
function setChallengeBond(uint256 newBond) external;
function setResponseWindow(uint256 newWindow) external;
```

### BuilderRegistry

Registry for approved block builders with per-chain overrides:

```solidity
function registerBuilder(address builder) external;      // Governance only
function deactivateBuilder(address builder) external;
function activateBuilder(address builder) external;
function setDefaultBuilder(address builder) external;
function setChainBuilder(uint256 chainId, address builder) external;

function getEffectiveBuilder(uint256 chainId) external view returns (address);
function getActiveBuilders() external view returns (address[] memory);
function getBuilder(address builder) external view returns (BuilderInfo memory);
```

### FlashblocksBuilder

Default MEV-Boost + Flashblocks builder implementation:

```solidity
function builderType() external view returns (BuilderType);  // PrivateMempool
function supportsChain(uint256 chainId) external view returns (bool);
function validateBuildRequest(BuildRequest memory request) external view returns (bool valid, string memory reason);
function relayEndpoint() external view returns (string memory);

function addChainSupport(uint256 chainId) external;    // Governance
function removeChainSupport(uint256 chainId) external;
function setRelayEndpoint(string calldata endpoint) external;
```

### Chain Adapter Interfaces

**ArbitrumAdapterV1** - Arbitrum Nitro integration via SequencerInbox:
```solidity
// Rotation payload: abi.encode(newBatchPoster, oldBatchPoster)
function getRotationCalldata(address sequencerInbox, bytes calldata rotationData) external view returns (bytes[] memory);
```

**GenericAdapterV1** - Any EVM rollup via arbitrary calls:
```solidity
// Single-call: abi.encode(bytes4 selector, bytes callData)
// Multi-call:  0xFF prefix + abi.encode(bytes4[] selectors, bytes[] callDatas)
function getRotationCalldata(address rollupConfig, bytes calldata rotationData) external view returns (bytes[] memory);
```

### OP Stack PoC Interfaces

The OP Stack integration lives in `src/poc/opstack`, including `OpStackAdapterV1` and the `ISystemConfig` interface for Superchain-compliant SystemConfig contracts.

## Deployment

### Local Development

```bash
# Start local devnet
./start.sh local

# Interact with contracts
cast call <HUB> "currentProposer()" --rpc-url http://localhost:8545
cast call <HUB> "isCurrentProposer(address)(bool)" <proposer> --rpc-url http://localhost:8545
```

### Sepolia Testnet

1. **Configure Environment**

```bash
cp .env.sepolia.example .env.sepolia
# Edit with your values
```

2. **Deploy Contracts**

```bash
source .env.sepolia
./start.sh sepolia
# Or manually:
# forge script script/DeployRemote.s.sol:DeployRemote --rpc-url $RPC_URL --broadcast --verify
```

3. **Transfer rollup config ownership (e.g., SystemConfig for OP Stack)**

```bash
cast send $SYSTEM_CONFIG "transferOwnership(address)" $HUB_ADDRESS \
  --rpc-url $L1_RPC \
  --private-key $OWNER_PRIVATE_KEY
```

4. **Register Operators in the arbitrator registry (Kleros Curate by default)**

Visit https://curate.kleros.io/ and submit proposer entries as required by your registry schema.

5. **Deploy ISOCHRON Proposer Agent**

Each proposer must run their own agent:
```bash
cd agent
pip install -r requirements.txt
cp kssn_config.example.yaml kssn_config.yaml
# Edit kssn_config.yaml with proposer's details
python kssn_proposer_agent.py --config kssn_config.yaml
```

### Mainnet Deployment

**Prerequisites:**
- Curate-style TCR deployed with your sequencer policy (Kleros Curate by default)
- TCR item type: tuple (address batcher, address unsafeSigner)
- OP Stack L1 contracts deployed
- Guardian multisig set up
- Keeper infrastructure ready

See `script/DeployRemote.s.sol` for detailed deployment steps.

## ISOCHRON Proposer Agent

Each proposer MUST run a proposer agent. See [`agent/README.md`](./agent/README.md) for:
- Installation instructions
- Configuration options
- Systemd service setup
- Troubleshooting guide

Quick start:
```bash
cd agent
pip install -r requirements.txt
cp kssn_config.example.yaml kssn_config.yaml
# Edit kssn_config.yaml with your proposer details
python kssn_proposer_agent.py --config kssn_config.yaml
```

## Keeper Integration

Keepers serve as a **liveness fallback** (Dead Man's Switch) - they can only force rotation after the grace period expires (Phase 3).

**Important**: Under normal operation, the **current operator** initiates rotation during the grace period (Phase 2). Keepers are only needed if an operator fails to rotate.

### Gelato Web3 Functions

```javascript
Web3Function.onRun(async (context) => {
  const { userArgs, provider } = context;

  const hub = new ethers.Contract(
    userArgs.hubAddress,
    [
      "function epochDuration() view returns (uint256)",
      "function gracePeriod() view returns (uint256)",
      "function epochStartTime() view returns (uint256)",
      "function rotateNetwork()"
    ],
    provider
  );

  const epochDuration = await hub.epochDuration();
  const gracePeriod = await hub.gracePeriod();
  const epochStartTime = await hub.epochStartTime();
  const now = Math.floor(Date.now() / 1000);

  // Keepers can only rotate after epoch + grace period (Phase 3 - Dead Man's Switch)
  const deadMansSwitchTime = epochStartTime.add(epochDuration).add(gracePeriod);

  if (now <= deadMansSwitchTime) {
    const timeLeft = deadMansSwitchTime.sub(now);
    return { canExec: false, message: `${timeLeft}s until Dead Man's Switch` };
  }

  // Phase 3: Force rotation if operator hasn't rotated
  return {
    canExec: true,
    callData: hub.interface.encodeFunctionData("rotateNetwork")
  };
});
```

**Note**: Keepers forcing rotation in Phase 3 may cause L2 re-orgs if the outgoing operator has unflushed batches. This is an acceptable tradeoff for liveness - a stalled chain is worse than a re-org.

## Security Considerations

### Adapter Security
- Adapters are called via regular **call** from the Hub (view functions that return calldata)
- The Hub executes the returned calldata against the rollup config, preserving its role as `msg.sender`
- This eliminates the delegatecall attack vector: adapters cannot modify Hub storage
- Adapters must be registered in the **Adapter Registry** (Kleros Curate by default)
- **Ratchet versioning** prevents rollback attacks (newVersion > currentVersion)
- **Hydra defense** allows multiple submissions to defeat griefing

### Atomic Rotation
- Both `batcherHash` and `unsafeBlockSigner` are set in the same transaction
- Prevents "half-rotated" states where batches and P2P blocks have different authorities

### Cold Staker / Hot Operator
- Governance stake can be held separately from operational keys
- Compromise of hot keys doesn't affect stake ownership
- Owner can update operational keys via `setOperationalKeys()`

### O(1) Validation
- Reverse mapping (`opIdToItemId`) enables O(1) registry verification
- Prevents DoS during rotation with many operators
- Snapshots decouple from registry reads during rotation

### SLA Compliance
- SLA requirements enforced via the arbitrator (Kleros default)
- Proposers can be challenged for producing blocks while unauthorized

### Bounded Operations
- All loops are bounded to prevent DoS
- O(1) add/remove using swap-pop pattern

### Griefing Mitigation
- High deposit requirement in the arbitrator registry (Kleros default) deters frivolous challenges
- Guardian can pause in emergencies
- Hydra defense for adapter submissions

### Bundle Security
- Only the active sequencer (verified via Hub) can commit bundles
- Bundle tips held in escrow until execution is confirmed on ALL target chains
- Bond slashing deters non-delivery (10% reporter reward incentivizes monitoring)
- Minimum deadline duration prevents unreasonably short execution windows

### Fraud Proof Security
- Challenge bonds prevent spam (0.5 ETH default)
- Deterministic proofs are trustless - no oracle or committee required
- Auto-accept after deadline prevents censorship of valid challenges
- Kleros arbitration only for inherently subjective criteria (MEV violations)
- Response window (24h default) balances sequencer defense and challenger protection

### Policy Security
- Only chain governance (or hub governance) can set chain policies
- Custom policy contracts are isolated - compliance checks via staticcall
- Default policy (SequencerDiscretion) is permissive - chains opt into stricter rules
- Policy deactivation doesn't delete state, allowing re-activation

### No Trusted Setups
- Protocol does not require TEEs, threshold encryption, or trusted hardware
- All enforcement is either deterministic (on-chain math) or decentralized (Kleros)
- Chains MAY opt into trusted setups via sovereign policy, but the protocol doesn't mandate them

## File Structure

```
op/
├── src/
│   ├── SharedSequencerHub.sol        # ISOCHRON Hub - atomic multichain rotation
│   ├── ProposerRegistry.sol          # DPoS proposer management
│   ├── ChainRegistry.sol             # GeneralizedTCR for chain onboarding
│   ├── ChainDeploymentKit.sol        # Helper for chain integration
│   │
│   ├── bundle/                       # Cross-chain bundle execution
│   │   ├── CrossChainBundleRegistry.sol  # Atomic multi-chain bundle commitments
│   │   └── BundleEscrow.sol              # Tip/bond escrow with slashing
│   │
│   ├── builder/                      # Universal block building
│   │   ├── BuilderRegistry.sol       # Pluggable builder management
│   │   └── FlashblocksBuilder.sol    # MEV-Boost + Flashblocks (default)
│   │
│   ├── policy/                       # Sovereign chain policies
│   │   ├── SovereignPolicyManager.sol    # Per-chain policy declaration
│   │   └── DefaultPolicy.sol             # Default FCFS + sandwich protection
│   │
│   ├── fraud/                        # Fraud proof verification
│   │   └── FraudProofVerifier.sol    # Deterministic + Kleros arbitration
│   │
│   ├── poc/                          # Chain-specific adapters
│   │   ├── opstack/
│   │   │   ├── OpStackAdapterV1.sol  # OP Stack Bedrock/Ecotone adapter
│   │   │   └── interfaces/
│   │   │       └── ISystemConfig.sol # OP Stack SystemConfig interface
│   │   ├── arbitrum/
│   │   │   ├── ArbitrumAdapterV1.sol # Arbitrum Nitro adapter
│   │   │   └── interfaces/
│   │   │       └── IArbitrumRollup.sol   # SequencerInbox + RollupCore
│   │   └── generic/
│   │       └── GenericAdapterV1.sol  # Any EVM rollup (arbitrary calls)
│   │
│   └── interfaces/
│       ├── ISharedSequencerHub.sol   # Hub interface
│       ├── IProposerRegistry.sol     # Proposer registry interface
│       ├── IChainRegistry.sol        # Chain registry interface
│       ├── ISequencerAdapter.sol     # Adapter interface
│       ├── ICrossChainBundle.sol     # Bundle registry interface
│       ├── IBundleEscrow.sol         # Escrow interface
│       ├── IBuilderRegistry.sol      # Builder registry interface
│       ├── IUniversalBuilder.sol     # Builder interface
│       ├── ISovereignPolicy.sol      # Policy interface
│       ├── IFraudProofVerifier.sol   # Fraud proof interface
│       ├── ICurate.sol               # Kleros Curate interface
│       ├── IArbitrator.sol           # ERC-792 arbitration
│       └── IArbitrable.sol           # ERC-792 arbitrable
│
├── relay/                            # Rust relay (time-sensitive components)
│   ├── Cargo.toml                    # Rust dependencies
│   └── src/
│       ├── main.rs                   # Entry point
│       ├── config.rs                 # TOML configuration
│       ├── bundle/
│       │   ├── types.rs              # Bundle/operation types
│       │   ├── validator.rs          # Bundle validation
│       │   └── sequencer.rs          # Bundle lifecycle
│       ├── chain/
│       │   └── mod.rs                # Chain adapter management
│       ├── policy/
│       │   └── mod.rs                # Policy compliance engine
│       └── relay/
│           └── mod.rs                # HTTP API server
│
├── test/
│   ├── SharedSequencerHub.t.sol      # Hub tests (54 tests)
│   ├── ProposerRegistry.t.sol        # Proposer registry tests (41 tests)
│   ├── ChainRegistry.t.sol           # Chain registry tests (24 tests)
│   ├── CrossChainBundle.t.sol        # Bundle + escrow tests (25 tests)
│   ├── BuilderRegistry.t.sol         # Builder + Flashblocks tests (19 tests)
│   ├── SovereignPolicy.t.sol         # Policy manager tests (18 tests)
│   ├── FraudProofVerifier.t.sol      # Fraud proof tests (15 tests)
│   ├── ChainAdapters.t.sol           # Arbitrum + Generic adapter tests (12 tests)
│   ├── OpStackAdapterV1.t.sol        # OP Stack adapter tests (20 tests)
│   └── mocks/
│       ├── MockProposerRegistry.sol  # Proposer registry mock
│       ├── MockChainRegistry.sol     # Chain registry mock
│       ├── MockRollupConfig.sol      # Generic rollup config mock
│       ├── MockSequencerAdapter.sol  # Generic adapter mock
│       ├── MockSystemConfig.sol      # OP Stack SystemConfig mock
│       ├── MockAdapterV2.sol         # V2 adapter stub
│       ├── MockArbitrator.sol        # Kleros arbitrator mock
│       ├── MockHub.sol               # Hub mock (for bundle tests)
│       └── MockSequencerInbox.sol    # Arbitrum SequencerInbox mock
│
├── script/
│   ├── DeployKSSN.s.sol              # Hub-and-Spoke deployment
│   ├── DeployRemote.s.sol            # Sepolia/Mainnet deployment
│   ├── IntegrationTest.s.sol         # Solidity integration test
│   └── run_integration_test.sh       # Full system integration test
├── policies/
│   ├── policy_sequencer_registry.md  # Sequencer SLA rules
│   ├── policy_adapter_registry.md    # Adapter acceptance criteria
│   └── policy_chain_registry.md      # Chain registry criteria
├── devnet/
│   ├── genesis-l2.json               # L2 genesis configuration
│   └── generate-configs.sh           # Config generation helper
├── docker/
│   └── config/                       # Generated L2 configs
├── agent/
│   ├── kssn_proposer_agent.py        # Proposer agent
│   ├── kssn_config.example.yaml      # Agent config template
│   ├── requirements.txt              # Python dependencies
│   └── README.md                     # Agent documentation
├── docker-compose.yml                # Full OP Stack setup
├── start.sh                          # One-command startup script
├── Makefile                          # Development commands
└── .env.*.example                    # Environment templates
```

## FAQ

### ISOCHRON Architecture

**Q: What is ISOCHRON?**
A: ISOCHRON is a Hub-and-Spoke architecture that manages sequencing for multiple rollups from a single Hub contract. It enables atomic cross-chain composability while preserving chain sovereignty through opt-in rotation and SLA governance.

**Q: How does atomic multichain rotation work?**
A: When `rotateNetwork()` is called, the Hub iterates through ALL connected chains and updates each rollup configuration contract in a single transaction. This costs ~60k gas per chain, supporting ~450 chains per block at 30M gas limit. For larger networks, use `rotateShard()`.

**Q: How is sequencing policy enforced?**
A: ISOCHRON enforces SLA expectations (liveness, authorized production, and clean handoffs) through multiple mechanisms: the Hub reports liveness scores to the `ProposerRegistry` at every epoch rotation, the `FraudProofVerifier` handles deterministic proofs (timing, ordering, inclusion, bundle violations) and subjective proofs via Kleros arbitration (MEV, custom, unjustified pause), and sovereign chains can set circuit breakers to pause sequencing during security incidents without triggering liveness penalties.

**Q: Can the sequencer use Rollup Boost and Flashblocks?**
A: Yes. FlashblocksBuilder is the default builder in the BuilderRegistry, using a private mempool with MEV-Boost integration. The BuilderRegistry supports per-chain overrides, so individual chains can opt into different building mechanisms (public mempool, encrypted mempool, custom) via their sovereign policy.

**Q: How do I connect a new chain to ISOCHRON?**
A: There are two paths:

**Decentralized Path (ChainRegistry):**
1) Deploy your rollup chain with a configuration contract (e.g., SystemConfig)
2) Use ChainDeploymentKit to register in ChainRegistry (GeneralizedTCR)
3) Wait for challenge period (community can dispute invalid chains)
4) After approval, Hub governance calls `connectChainFromRegistry(chainId)`
5) Your chain is now part of the shared sequencer network

**Direct Path (Governance Only):**
1) Deploy your rollup chain with a configuration contract (e.g., SystemConfig)
2) Transfer rollup config ownership to the Hub
3) Call `hub.connectChain(chainId, rollupConfig, adapter)` as governance
4) Your chain is now part of the shared sequencer network

**Q: What happens if a chain's rotation fails?**
A: The Hub continues with other chains and deactivates the failing chain. Individual chain failures don't block the network. The chain can be reactivated after fixing the issue.

### Proposers

**Q: How do I become a proposer?**
A: 1) Call `proposerRegistry.register(operationalKey)` with minimum stake (32 ETH default), 2) Run the ISOCHRON proposer agent, 3) If your stake is in the top-N (100 by default), you'll be in the active set.

### Active Handoff & Rotation

**Q: What is the Active Handoff protocol?**
A: A 3-phase state machine ensuring zero-downtime transitions. During the grace period (10 min default) after epoch ends, only the current proposer can trigger rotation. This allows flushing batches before handover.

**Q: What happens during ISOCHRON rotation?**
A: 1) Current proposer's agent detects epoch end, 2) Agent stops sequencing and flushes batches, 3) Agent calls `rotateNetwork()`, 4) Hub updates ALL connected chains atomically, 5) New proposer's agent detects change and starts.

**Q: What if the proposer doesn't rotate during grace period?**
A: After grace period expires (Phase 3), anyone can force rotation via `rotateNetwork()`. This ensures liveness but may cause re-orgs if the outgoing proposer had unflushed batches.

### Technical Details

**Q: How many chains can ISOCHRON support?**
A: Single `rotateNetwork()` supports ~450 chains at 30M gas limit. For larger networks, use `rotateShard(shardIndex)` which splits rotation into chunks of 200 chains.

**Q: What is a "Superchain Aligned" design?**
A: ISOCHRON is designed to eventually replace the Superchain Council multisig. Instead of a committee updating rollup configuration contracts, the SharedSequencerHub does it algorithmically based on arbitrator governance decisions (Kleros default).

### Cross-Chain Bundles

**Q: What is a cross-chain bundle?**
A: A bundle is an atomic set of operations that must execute across multiple chains. The sequencer commits to a bundle by providing an operations hash, target chain IDs, and a deadline. The bundle is tracked on-chain with economic guarantees - tips incentivize execution, and bonds can be slashed if the sequencer fails to deliver.

**Q: How does bundle escrow work?**
A: Searchers/users deposit tips for their bundles, and sequencers post bonds as economic guarantees. On successful execution, tips are released to the sequencer. On violation, the bond is slashed - 10% goes to the reporter who identified the violation, and 90% goes to the governance treasury.

**Q: What happens if a bundle expires?**
A: Anyone can call `expireBundle()` after the deadline passes. The bundle status changes to `Expired` and escrowed funds can be returned. Sequencers are expected to either execute or cancel bundles before expiry.

### Sovereign Policies

**Q: How do sovereign policies work?**
A: Each chain can declare its own sequencing policy via `SovereignPolicyManager.declarePolicy()`. The policy specifies ordering strategy (FCFS, priority fee, sequencer discretion, or custom), enforcement type (deterministic, subjective, or hybrid), timing constraints (max block time, forced inclusion deadline), and MEV protections (sandwich protection, backrun-only). The active sequencer must obey these policies or face fraud proof challenges.

**Q: Can a chain use a custom policy contract?**
A: Yes. Set `orderingStrategy` to `Custom` and provide a `customPolicyContract` address that implements the `ISovereignPolicy` interface. The `SovereignPolicyManager` will delegate compliance checks to that contract.

**Q: Do chains need TEEs or other trusted setups?**
A: No. ISOCHRON does not hardcode any trusted setups. Deterministic fraud proofs handle timing, ordering, and inclusion violations trustlessly on-chain. Subjective criteria (MEV violations) are resolved via Kleros arbitration. However, a chain MAY opt into TEEs or other mechanisms via its sovereign policy and custom policy contract.

### Fraud Proofs

**Q: What types of fraud can be proven deterministically?**
A: Four types: (1) **Timing violations** - block gap exceeds the chain's `maxBlockTime`; (2) **Ordering violations** - FCFS misordering when the policy requires FCFS; (3) **Inclusion violations** - censorship beyond the `forcedInclusionDeadline`; (4) **Bundle violations** - committed bundle deadline passed without execution.

**Q: How does Kleros arbitration work for subjective violations?**
A: For MEV violations (sandwich attacks, front-running) and custom violations, the challenger escalates to Kleros by paying the arbitration fee. A Kleros court examines the evidence and rules in favor of either the challenger or the sequencer. The bond is then distributed accordingly.

**Q: What if nobody responds to a challenge?**
A: If a challenge remains in `Pending` status for longer than the response window (24 hours default), anyone can call `resolveChallenge()` to auto-accept it. The challenger gets their bond back.

### Chain Adapters

**Q: How do I integrate a non-OP-Stack chain?**
A: Use one of the existing adapters or write a new one:
- **Arbitrum Nitro**: Use `ArbitrumAdapterV1` which calls `setIsBatchPoster()` on the SequencerInbox
- **Any EVM rollup**: Use `GenericAdapterV1` which supports arbitrary function calls (single or multi-call mode)
- **Custom**: Implement the `ISequencerAdapter` interface with your chain's specific rotation logic

**Q: Does integrating with ISOCHRON require changes to my rollup?**
A: No. Adapters are view functions that return calldata for the Hub to execute against your rollup config. Your rollup's existing contracts remain unchanged. You just need to transfer ownership/permissions of the relevant configuration contract (SystemConfig, SequencerInbox, etc.) to the Hub.

### Rust Relay

**Q: Why is there a Rust relay?**
A: The relay handles time-sensitive components that benefit from Rust's performance and safety guarantees: bundle validation, ordering policy enforcement, and the HTTP API for bundle submission. The Solidity contracts provide the settlement and dispute resolution layer, while the relay handles real-time processing.

**Q: How do I run the relay?**
A: Build with `cd relay && cargo build --release`, then configure via `config.toml` (see `relay/src/config.rs` for options). The relay starts an HTTP server with endpoints for health checks, bundle submission, and status queries.

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Submit a pull request

## License

MIT
