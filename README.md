# Kleros Shared Sequencer Network (KSSN)

A fully decentralized shared sequencing layer for multiple OP Stack chains, with constitutional governance powered by Kleros subjective dispute resolution.

## What is KSSN?

The **Kleros Shared Sequencer Network** centralizes sequencing authority for multiple OP Stack chains into a single "Hub" contract while preserving their individual sovereignty via a Federalist Policy system. It implements **enshrined Proposer-Builder Separation (ePBS)** for capital efficiency and liability separation.

**Key Features:**
- **Hub-and-Spoke Architecture**: Single Hub manages multiple L2 chains atomically
- **Atomic Multichain Rotation**: Updates ALL connected chains in a single transaction
- **Dual-Registry PBS**: Separate Proposer Registry (liveness) and Builder Registry (policy)
- **Federalist Policy System**: Each chain can require specific compliance (OFAC, KYC, etc.)
- **Sovereignty Matrix**: Builders accumulate policy tags to qualify for specific chains
- **Union Rule**: Cross-chain atomic bundles require ALL policy tags from touched chains
- **Active Handoff Protocol**: Zero-downtime proposer transitions with grace period
- **Superchain Aligned**: Designed to replace Superchain Council multisig with algorithmic governance
- **Scalable**: Sharded rotation supports thousands of chains

## The Constitution

The Constitutional L2 is governed by formal policies enforced through Kleros arbitration:

| Policy | Description |
|--------|-------------|
| [Sequencer Policy](./policies/policy_sequencer_registry.md) | Rules for sequencer operators (censorship, MEV, liveness) |
| [Adapter Policy](./policies/policy_adapter_registry.md) | Acceptance criteria for OP Stack adapters |
| [Chain Registry Policy](./policies/policy_chain_registry.md) | Acceptance/removal criteria for KSSN chain integration |

These policies define:
- **Acceptance Criteria**: Requirements for registration (Sybil resistance, operational readiness)
- **Constitutional Rules**: Grounds for removal (censorship, malicious MEV, liveness failures)
- **Evidence Standards**: How violations are proven (multi-witness, simulation proofs)

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
- **Governance**: KlerosSequencerManager with mock Kleros registry
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

## Architecture

### KSSN Hub-and-Spoke Architecture

The KSSN uses a Hub-and-Spoke model with dual registries for Proposer-Builder Separation (PBS):

```
                        KSSN HUB-AND-SPOKE ARCHITECTURE

  ┌─────────────────────────────────────────────────────────────────────────────────┐
  │                                 L1 (Ethereum)                                    │
  │                                                                                 │
  │     ┌─────────────────────┐                   ┌─────────────────────┐           │
  │     │  ProposerRegistry   │                   │   BuilderRegistry   │           │
  │     │  "The Dumb Pipe"    │                   │  "The Value Engine" │           │
  │     │                     │                   │                     │           │
  │     │  - Top-N DPoS       │                   │  - Policy Tags      │           │
  │     │  - Liveness Focus   │                   │  - High Bonds       │           │
  │     │  - Safe Harbor      │                   │  - Content Liable   │           │
  │     └──────────┬──────────┘                   └──────────┬──────────┘           │
  │                │                                         │                      │
  │                └──────────────────┬──────────────────────┘                      │
  │                                   │                                             │
  │                                   ▼                                             │
  │                    ┌──────────────────────────────┐                             │
  │                    │    SharedSequencerHub        │                             │
  │                    │    (Central Authority)       │                             │
  │                    │                              │                             │
  │                    │  - rotateNetwork()           │  ◄── Atomic Multichain      │
  │                    │  - connectChain()            │      Rotation               │
  │                    │  - rotateShard()             │                             │
  │                    └──────────────┬───────────────┘                             │
  │                                   │                                             │
  │              ┌────────────────────┼────────────────────┐                        │
  │              │                    │                    │                        │
  │              ▼                    ▼                    ▼                        │
  │     ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
  │     │  SystemConfig   │  │  SystemConfig   │  │  SystemConfig   │  (Spokes)    │
  │     │  Chain A        │  │  Chain B        │  │  Chain C        │              │
  │     │  Policy: OFAC   │  │  Policy: KYC    │  │  Policy: NEUTRAL│              │
  │     └─────────────────┘  └─────────────────┘  └─────────────────┘              │
  │                                                                                 │
  └─────────────────────────────────────────────────────────────────────────────────┘

                              ATOMIC ROTATION
  ┌─────────────────────────────────────────────────────────────────────────────────┐
  │                                                                                 │
  │   rotateNetwork() updates ALL chains in a single transaction:                   │
  │                                                                                 │
  │   for (chain in connectedChains) {                                              │
  │       adapter.rotateSequencer(chain.systemConfig, nextProposer, nextProposer)   │
  │   }                                                                             │
  │                                                                                 │
  │   Gas: ~60k per chain | Max: ~450 chains per block at 30M gas limit             │
  │                                                                                 │
  └─────────────────────────────────────────────────────────────────────────────────┘
```

### Dual-Registry PBS (Proposer-Builder Separation)

| Registry | Role | Focus | Liability |
|----------|------|-------|-----------|
| **ProposerRegistry** | Node Operators | Liveness | Liveness + Registry Compliance |
| **BuilderRegistry** | MEV Searchers | Policy | Content + Data Availability |

**Proposer Registry ("The Dumb Pipe")**
- Top-N Delegated Proof of Stake (default: top 100)
- Public `rebalance()` swaps low-stake active with high-stake inactive
- **Safe Harbor**: Immune to content-based slashing if signing registered Builder headers
- Round-robin selection algorithm

**Builder Registry ("The Value Engine")**
- High bonds (default: 500 ETH) for "Bad Block" damages
- Policy Tags: `OFAC`, `KYC`, `NO_MEV`, `NO_GAMBLING`, `NEUTRAL`
- **Union Rule**: For atomic cross-chain bundles, builder needs ALL required policy tags

### Chain Integration Framework

KSSN provides a decentralized onboarding path for new chains via the **ChainRegistry** (GeneralizedTCR):

```
                    CHAIN INTEGRATION FLOW

  Chain Team                    ChainRegistry              SharedSequencerHub
  ───────────                   ─────────────              ──────────────────
       │                              │                            │
       │  1. Deploy OP Stack chain    │                            │
       │     with SystemConfig        │                            │
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
       │  6. Chain is now part of KSSN!                            │
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
- Valid OP Stack deployment with accessible SystemConfig
- Chain team has operational capability
- No duplicate chain IDs
- Compliance with KSSN constitutional requirements

### The Sovereignty Matrix

Each connected chain specifies a `policyId` requirement:

```
              SOVEREIGNTY MATRIX

  Builder     │ OFAC │ KYC │ NO_MEV │ NEUTRAL │
  ────────────┼──────┼─────┼────────┼─────────┤
  Builder A   │  ✓   │  ✓  │   ✗    │    ✓    │
  Builder B   │  ✓   │  ✗  │   ✓    │    ✓    │
  Builder C   │  ✗   │  ✗  │   ✗    │    ✓    │

  Chain Eligibility:
  - Chain with POLICY_OFAC: Builders A, B
  - Chain with POLICY_KYC: Builder A only
  - Chain with POLICY_NEUTRAL: All builders
```

**The Union Rule for Atomicity:**
For a Builder to construct an atomic bundle touching Chain A (Policy X) and Chain B (Policy Y), the Builder must possess BOTH Tag X AND Tag Y.

### Cold Staker / Hot Operator Model

Separating stake ownership from operational keys improves security:

| Role | Description | Registry Field |
|------|-------------|----------------|
| **Staker (Owner)** | Holds governance stake, can update keys | `item.submitter` |
| **Batcher** | Posts batches to L1 (hot key) | `itemKeys[itemID].batcher` |
| **Unsafe Signer** | Signs P2P unsafe blocks (hot key) | `itemKeys[itemID].unsafeSigner` |

**Recommendation**: Use different addresses for Staker vs Operational Keys. If hot keys are compromised, the governance stake remains safe.

### Operator Tuple Model

**CRITICAL**: OP Stack sequencer authority requires TWO keys rotated together:

| Key | Purpose | SystemConfig Function |
|-----|---------|----------------------|
| **Batcher** | Posts batches to L1 | `setBatcherHash()` |
| **Unsafe Signer** | Signs P2P unsafe blocks | `setUnsafeBlockSigner()` |

Both keys are registered in the Hybrid PGTCR registry and rotated atomically by the manager via the adapter.

```
                        OPERATOR ROTATION FLOW

  ┌───────────────────────────────────────────────────────────────────────────┐
  │                              L1 (Ethereum)                                 │
  │                                                                           │
  │     Operator Registry                    KlerosSequencerManager           │
  │  ┌─────────────────────┐              ┌─────────────────────┐             │
  │  │  PGTCR Hybrid       │              │  Snapshot + Reverse │             │
  │  │                     │   sync       │  Mapping            │             │
  │  │  itemKeys[itemID]   │ ──────────▶  │                     │             │
  │  │  ├─ batcher         │              │  opIdToItemId[opId] │             │
  │  │  └─ unsafeSigner    │              │  itemIdToOpId[item] │             │
  │  │                     │              │                     │             │
  │  │  setOperationalKeys │              │  O(1) validation    │             │
  │  └─────────────────────┘              └─────────────────────┘             │
  │                                                  │                        │
  └──────────────────────────────────────────────────│────────────────────────┘
                                                     │
           ┌─────────────────────────────────────────┼─────────────────────────┐
           │                                         │                         │
           ▼                                         ▼                         ▼
   ┌───────────────────┐                    ┌───────────────────┐    ┌───────────────────┐
   │   Operator A      │                    │   Operator B      │    │   Operator C      │
   │                   │                    │                   │    │                   │
   │ ┌───────────────┐ │                    │ ┌───────────────┐ │    │ ┌───────────────┐ │
   │ │Self-Activation│ │                    │ │Self-Activation│ │    │ │Self-Activation│ │
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

### Self-Activation Agents

Each operator MUST run a self-activation agent that:
1. Monitors `isCurrentOperator(batcher, unsafeSigner)` on-chain
2. Starts local op-node sequencer + op-batcher when becoming active
3. Stops them when no longer active

This is a **constitutional requirement** - operators that produce blocks while unauthorized can be challenged and removed.

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
4. **Rotate**: Call `rotateOperator()` (ideally in same tx or immediately after batch confirms)
5. **Handover**: New operator's agent sees L1 state change and immediately starts sequencing

**Constants:**
- `GRACE_PERIOD = 600` (10 minutes)

### How It Works

1. **Operators Register**: Submit operational keys to Hybrid PGTCR with deposit + Constitutional Declaration
2. **Community Curation**: Challenge period allows disputing unfit operators (Sybil, unqualified)
3. **Sync to Manager**: Call `syncAddOperator(itemID)` to snapshot keys and create reverse mapping
4. **Epoch Operation**: Operator produces blocks for `epochDuration`
5. **Active Handoff**: At epoch end, operator flushes batches and calls `rotateOperator()` (grace period protects this)
6. **Adapter Execution**: Manager delegates to adapter via delegatecall for OP Stack compatibility
7. **Atomic Update**: Adapter sets BOTH `batcherHash` AND `unsafeBlockSigner` in SystemConfig
8. **Self-Activation**: New operator's agent detects the change and immediately starts sequencing
9. **Constitutional Enforcement**: Misbehaving operators challenged via Kleros

### Constitutional Rules (Summary)

The full constitution is defined in [`policies/policy_sequencer_registry.md`](./policies/policy_sequencer_registry.md).

**Key Rules:**

| Rule | Violation | Evidence Standard |
|------|-----------|-------------------|
| **Censorship Resistance** | Excluding valid tx for >5 minutes | Provider logs + simulation trace |
| **No Malicious MEV** | Sandwiching, front-running | Simulation proof of user harm |
| **Self-Activation** | Producing blocks when unauthorized | L1 timestamp vs epoch |
| **Liveness** | >5 minute downtime during epoch | Block production gaps |

See the [Sequencer Policy](./policies/policy_sequencer_registry.md) for detailed evidence standards.

## Smart Contracts

### SharedSequencerHub (KSSN)

The central nervous system of KSSN - manages atomic rotation across all connected chains.

```solidity
// Chain configuration for each connected Spoke
struct ChainConfig {
    address systemConfig;   // The OP Stack SystemConfig contract
    bytes32 policyId;       // The Policy ID this chain requires
    address adapter;        // Adapter for version compatibility
    bool isActive;          // Whether this chain is active
    uint256 chainId;        // The L2 chain ID
}

// Core state
address public currentProposer;           // Current active proposer
uint256 public currentEpoch;              // Current epoch number
uint256 public epochDuration;             // Rotation interval (default: 1 hour)
uint256 public gracePeriod;               // Active Handoff window (default: 10 min)
address public proposerRegistry;          // ProposerRegistry contract
address public builderRegistry;           // BuilderRegistry contract

// Rotation functions
function rotateNetwork() external;        // Atomic rotation of ALL chains
function rotateShard(uint256 shardIndex); // For scaling beyond 400 chains

// Chain management (governance only)
function connectChain(uint256 chainId, address systemConfig, bytes32 policyId, address adapter);
function disconnectChain(uint256 chainId);
function updateChainConfig(uint256 chainId, bytes32 policyId, address adapter);

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

// Selection (called by Hub)
function selectNextProposer(uint256 epoch) external view returns (address);

// View functions
function getActiveProposers() external view returns (address[] memory);
function getTotalStake(address proposer) external view returns (uint256);
function isActiveProposer(address proposer) external view returns (bool);
```

### BuilderRegistry

"The Value Engine" - manages policy-based builder eligibility with sovereignty matrix.

```solidity
struct BuilderInfo {
    uint256 bond;               // ETH bond for damages
    bool isActive;              // Currently active
    uint256 slashCount;         // Times slashed
    uint256 lastSlashTime;      // For cooldown tracking
}

struct PolicyTagStatus {
    bool isGranted;             // Has this tag
    uint256 expiresAt;          // 0 = never expires
    uint256 revokedAt;          // 0 = not revoked
}

// Policy constants
bytes32 public constant POLICY_OFAC;
bytes32 public constant POLICY_KYC;
bytes32 public constant POLICY_NO_MEV;
bytes32 public constant POLICY_NO_GAMBLING;
bytes32 public constant POLICY_NEUTRAL;

// Configuration
uint256 public minimumBond;     // Default: 500 ETH

// Builder functions
function register() external payable;
function addBond() external payable;
function withdrawBond(uint256 amount) external;

// Eligibility (called by Proposer clients)
function isBuilderEligible(address builder, bytes32 policyId) external view returns (bool);
function isBuilderEligibleForBundle(address builder, bytes32[] policyIds) external view returns (bool);

// Policy management (governance/Kleros)
function grantPolicyTag(address builder, bytes32 policyId, uint256 expiresAt) external;
function revokePolicyTag(address builder, bytes32 policyId, string reason) external;
function slash(address builder, uint256 amount, bytes32 policyId, string reason) external;
```

### ChainRegistry

GeneralizedTCR for decentralized chain onboarding to KSSN:

```solidity
// Chain registration data
struct ChainData {
    uint256 chainId;         // L2 chain ID
    address systemConfig;    // SystemConfig contract on L1
    address adapter;         // OP Stack adapter
    bytes32 policyId;        // Required policy (OFAC, KYC, NEUTRAL)
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
    address systemConfig,
    address adapter,
    bytes32 policyId,
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

Helper contract for easy chain integration into KSSN:

```solidity
// Registration status tracking
enum RegistrationStatus {
    NotStarted,     // Chain hasn't been registered
    Pending,        // In challenge period
    Registered,     // Successfully registered
    Connected,      // Connected to KSSN Hub
    Failed          // Registration failed (challenged)
}

// Simple registration
function registerChain(
    uint256 chainId,
    address systemConfig,
    bytes32 policyId,
    string name,
    string metadataURI
) external payable returns (bytes32 itemId);

// With custom adapter
function registerChainWithAdapter(
    uint256 chainId,
    address systemConfig,
    address adapter,
    bytes32 policyId,
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

### Standalone Mode: KlerosSequencerManager

For single-chain deployments or chains preparing for KSSN integration, `KlerosSequencerManager` provides a complete standalone sequencer rotation system. Chains can start in standalone mode and later integrate into KSSN via the ChainRegistry.

```solidity
// Operator struct
struct Operator {
    address batcher;       // Posts batches to L1
    address unsafeSigner;  // Signs P2P unsafe blocks
}

// Core functions
function syncAddOperator(bytes32 itemID) external;
function rotateOperator() external;
function upgradeAdapter(address newAdapter) external;
function currentOperator() external view returns (Operator memory);
function isCurrentOperator(address batcher, address unsafeSigner) external view returns (bool);
```

### IOpStackAdapter

Hot-swappable adapter interface for OP Stack compatibility:

```solidity
interface IOpStackAdapter {
    // Version for ratchet upgrade logic (v1.0.0 = 1_000_000)
    function version() external view returns (uint256);
    function adapterInfo() external view returns (string memory name, string memory description);

    // Called via delegatecall from manager
    function rotateSequencer(
        address _systemConfig,
        address _batcher,
        address _unsafeSigner
    ) external;
}
```

### ISystemConfig

OP Stack SystemConfig interface with both authorization functions:

```solidity
interface ISystemConfig {
    function setBatcherHash(bytes32 _batcherHash) external;
    function batcherHash() external view returns (bytes32);

    function setUnsafeBlockSigner(address _unsafeBlockSigner) external;
    function unsafeBlockSigner() external view returns (address);

    function owner() external view returns (address);
}
```

## Deployment

### Local Development

```bash
# Start local devnet
./start.sh local

# Interact with contracts
cast call <MANAGER> "currentOperator()" --rpc-url http://localhost:8545
cast call <MANAGER> "isCurrentOperator(address,address)(bool)" <batcher> <signer> --rpc-url http://localhost:8545
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

3. **Transfer SystemConfig Ownership**

```bash
cast send $SYSTEM_CONFIG "transferOwnership(address)" $MANAGER_ADDRESS \
  --rpc-url $L1_RPC \
  --private-key $OWNER_PRIVATE_KEY
```

4. **Register Operators in Kleros**

Visit https://curate.kleros.io/ and submit operator tuples: `abi.encode(batcher, unsafeSigner)`

5. **Sync Operators**

```bash
cast send $MANAGER_ADDRESS "syncAddOperator(address,address)" $BATCHER $UNSAFE_SIGNER \
  --rpc-url $L1_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY
```

6. **Deploy Self-Activation Agent**

Each operator must run their own agent:
```bash
cd agent
pip install -r requirements.txt
cp config.example.yaml config.yaml
# Edit config.yaml with operator's keys
python self_activation_agent.py --config config.yaml
```

### Mainnet Deployment

**Prerequisites:**
- Kleros Curate TCR deployed with your constitution
- TCR item type: tuple (address batcher, address unsafeSigner)
- OP Stack L1 contracts deployed
- Guardian multisig set up
- Keeper infrastructure ready

See `script/DeployRemote.s.sol` for detailed deployment steps.

## Self-Activation Agent

Each operator MUST run a self-activation agent. See [`agent/README.md`](./agent/README.md) for:
- Installation instructions
- Configuration options
- Systemd service setup
- Troubleshooting guide

Quick start:
```bash
cd agent
pip install -r requirements.txt
cp config.example.yaml config.yaml
# Edit config.yaml
python self_activation_agent.py --config config.yaml
```

## Keeper Integration

Keepers serve as a **liveness fallback** (Dead Man's Switch) - they can only force rotation after the grace period expires (Phase 3).

**Important**: Under normal operation, the **current operator** initiates rotation during the grace period (Phase 2). Keepers are only needed if an operator fails to rotate.

### Gelato Web3 Functions

```javascript
Web3Function.onRun(async (context) => {
  const { userArgs, provider } = context;

  const manager = new ethers.Contract(
    userArgs.managerAddress,
    [
      "function epochDuration() view returns (uint256)",
      "function GRACE_PERIOD() view returns (uint256)",
      "function lastRotationTimestamp() view returns (uint256)",
      "function rotateOperator()"
    ],
    provider
  );

  const epochDuration = await manager.epochDuration();
  const gracePeriod = await manager.GRACE_PERIOD();
  const lastRotation = await manager.lastRotationTimestamp();
  const now = Math.floor(Date.now() / 1000);

  // Keepers can only rotate after epoch + grace period (Phase 3 - Dead Man's Switch)
  const deadMansSwitchTime = lastRotation.add(epochDuration).add(gracePeriod);

  if (now <= deadMansSwitchTime) {
    const timeLeft = deadMansSwitchTime.sub(now);
    return { canExec: false, message: `${timeLeft}s until Dead Man's Switch` };
  }

  // Phase 3: Force rotation if operator hasn't rotated
  return {
    canExec: true,
    callData: manager.interface.encodeFunctionData("rotateOperator")
  };
});
```

**Note**: Keepers forcing rotation in Phase 3 may cause L2 re-orgs if the outgoing operator has unflushed batches. This is an acceptable tradeoff for liveness - a stalled chain is worse than a re-org.

## Security Considerations

### Adapter Security
- Adapters are called via **delegatecall** from the manager
- Adapters must be registered in the **Adapter Registry** (Kleros Curate)
- **Ratchet versioning** prevents rollback attacks (newVersion > currentVersion)
- **Hydra defense** allows multiple submissions to defeat griefing
- Adapters should only interact with SystemConfig, no arbitrary storage writes

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

### Self-Activation Compliance
- Constitutional requirement enforced via Kleros
- Operators can be challenged for producing blocks while unauthorized

### Bounded Operations
- All loops are bounded to prevent DoS
- O(1) add/remove using swap-pop pattern

### Griefing Mitigation
- High deposit requirement in Kleros deters frivolous challenges
- Guardian can pause in emergencies
- Hydra defense for adapter submissions

## File Structure

```
op/
├── src/
│   ├── SharedSequencerHub.sol        # KSSN Hub - atomic multichain rotation
│   ├── ProposerRegistry.sol          # KSSN DPoS proposer management
│   ├── BuilderRegistry.sol           # KSSN policy-based builder management
│   ├── ChainRegistry.sol             # GeneralizedTCR for chain onboarding
│   ├── ChainDeploymentKit.sol        # Helper for chain integration
│   ├── KlerosSequencerManager.sol    # Standalone/integration framework
│   ├── PermanentGTCRHybrid.sol       # Hybrid PGTCR (based on Kleros PGTCR)
│   ├── adapters/
│   │   └── OpStackAdapterV1.sol      # OP Stack Bedrock/Ecotone adapter
│   └── interfaces/
│       ├── ISharedSequencerHub.sol   # KSSN Hub interface
│       ├── IProposerRegistry.sol     # KSSN Proposer registry interface
│       ├── IBuilderRegistry.sol      # KSSN Builder registry interface
│       ├── IChainRegistry.sol        # Chain registry interface
│       ├── IOpStackAdapter.sol       # Adapter interface
│       ├── IPermanentGTCRHybrid.sol  # Hybrid PGTCR interface
│       ├── ICurate.sol               # Kleros Curate interface
│       ├── ISystemConfig.sol         # OP Stack interface (batcher + signer)
│       ├── IArbitrator.sol           # ERC-792 arbitration
│       └── IArbitrable.sol           # ERC-792 arbitrable
├── test/
│   ├── SharedSequencerHub.t.sol      # KSSN Hub tests (with registry integration)
│   ├── ProposerRegistry.t.sol        # KSSN Proposer registry tests
│   ├── BuilderRegistry.t.sol         # KSSN Builder registry tests
│   ├── ChainRegistry.t.sol           # Chain registry tests
│   ├── KlerosSequencerManager.t.sol  # Standalone manager tests
│   └── mocks/
│       ├── MockProposerRegistry.sol  # KSSN proposer registry mock
│       ├── MockBuilderRegistry.sol   # KSSN builder registry mock
│       ├── MockChainRegistry.sol     # Chain registry mock
│       ├── MockCurate.sol            # Test Kleros Curate mock
│       ├── MockPermanentGTCRHybrid.sol # Test Hybrid PGTCR mock
│       ├── MockSystemConfig.sol      # Test SystemConfig mock
│       └── MockAdapterV2.sol         # V2 adapter stub (for testing)
├── script/
│   ├── DeployKSSN.s.sol              # KSSN Hub-and-Spoke deployment
│   ├── DeployLocal.s.sol             # Standalone single-chain deployment
│   ├── DeployRemote.s.sol            # Sepolia/Mainnet deployment
│   ├── IntegrationTest.s.sol         # Solidity integration test
│   └── run_integration_test.sh       # Full system integration test
├── policies/
│   ├── policy_sequencer_registry.md  # Sequencer constitutional rules
│   └── policy_adapter_registry.md    # Adapter acceptance criteria
├── devnet/
│   ├── genesis-l2.json               # L2 genesis configuration
│   └── generate-configs.sh           # Config generation helper
├── docker/
│   └── config/                       # Generated L2 configs
├── agent/
│   ├── kssn_proposer_agent.py        # KSSN proposer agent
│   ├── kssn_config.example.yaml      # KSSN agent config template
│   ├── self_activation_agent.py      # Standalone single-chain agent
│   ├── config.example.yaml           # Standalone agent config template
│   ├── requirements.txt              # Python dependencies
│   └── README.md                     # Agent documentation
├── docker-compose.yml                # Full OP Stack setup
├── start.sh                          # One-command startup script
├── Makefile                          # Development commands
└── .env.*.example                    # Environment templates
```

## FAQ

### KSSN Architecture

**Q: What is KSSN?**
A: The Kleros Shared Sequencer Network - a Hub-and-Spoke architecture that manages sequencing for multiple OP Stack chains from a single Hub contract. It enables atomic cross-chain composability while preserving chain sovereignty through the Federalist Policy system.

**Q: How does atomic multichain rotation work?**
A: When `rotateNetwork()` is called, the Hub iterates through ALL connected chains and updates each SystemConfig in a single transaction. This costs ~60k gas per chain, supporting ~450 chains per block at 30M gas limit. For larger networks, use `rotateShard()`.

**Q: What is Proposer-Builder Separation (PBS)?**
A: KSSN separates infrastructure providers (Proposers) from transaction content providers (Builders). Proposers focus on liveness and are immune to content-based slashing ("Safe Harbor") if they sign headers from registered Builders. Builders are liable for policy compliance.

**Q: What is the Sovereignty Matrix?**
A: A mapping of builders to their policy compliance status. Each chain specifies a required policy (OFAC, KYC, NEUTRAL, etc.), and only builders with the matching policy tag can build for that chain.

**Q: What is the Union Rule?**
A: For atomic bundles spanning multiple chains, a builder must have ALL policy tags required by those chains. E.g., to build an atomic bundle for Chain A (OFAC) and Chain B (KYC), the builder needs both OFAC and KYC tags.

**Q: How do I connect a new chain to KSSN?**
A: There are two paths:

**Decentralized Path (ChainRegistry):**
1) Deploy your OP Stack chain with SystemConfig
2) Use ChainDeploymentKit to register in ChainRegistry (GeneralizedTCR)
3) Wait for challenge period (community can dispute invalid chains)
4) After approval, Hub governance calls `connectChainFromRegistry(chainId)`
5) Your chain is now part of the shared sequencer network

**Direct Path (Governance Only):**
1) Deploy your OP Stack chain with SystemConfig
2) Transfer SystemConfig ownership to the Hub
3) Call `hub.connectChain(chainId, systemConfig, policyId, adapter)` as governance
4) Your chain is now part of the shared sequencer network

**Q: What happens if a chain's rotation fails?**
A: The Hub continues with other chains and deactivates the failing chain. Individual chain failures don't block the network. The chain can be reactivated after fixing the issue.

### Proposer & Builder

**Q: How do I become a proposer?**
A: 1) Call `proposerRegistry.register(operationalKey)` with minimum stake (32 ETH default), 2) Run the KSSN proposer agent, 3) If your stake is in the top-N (100 by default), you'll be in the active set.

**Q: How do I become a builder?**
A: 1) Call `builderRegistry.register()` with minimum bond (500 ETH default), 2) You automatically get the NEUTRAL policy tag, 3) Apply for additional policy tags through governance/Kleros.

**Q: What is the "Safe Harbor" for proposers?**
A: Proposers are immune to content-based slashing if they sign headers from registered Builders. Their liability is strictly limited to liveness and registry compliance.

**Q: What happens if I'm slashed as a builder?**
A: Your bond is reduced, you enter a cooldown period (7 days default), and you're ineligible during that period. After 3 slashes, you're automatically deactivated.

### Active Handoff & Rotation

**Q: What is the Active Handoff protocol?**
A: A 3-phase state machine ensuring zero-downtime transitions. During the grace period (10 min default) after epoch ends, only the current proposer can trigger rotation. This allows flushing batches before handover.

**Q: What happens during KSSN rotation?**
A: 1) Current proposer's agent detects epoch end, 2) Agent stops sequencing and flushes batches, 3) Agent calls `rotateNetwork()`, 4) Hub updates ALL connected chains atomically, 5) New proposer's agent detects change and starts.

**Q: What if the proposer doesn't rotate during grace period?**
A: After grace period expires (Phase 3), anyone can force rotation via `rotateNetwork()`. This ensures liveness but may cause re-orgs if the outgoing proposer had unflushed batches.

### Standalone Mode & Integration

**Q: What is standalone mode?**
A: Chains can run `KlerosSequencerManager` independently before joining KSSN. This provides decentralized sequencer rotation for a single chain with the same constitutional enforcement.

**Q: How do I migrate from standalone to KSSN?**
A: 1) Register your chain in ChainRegistry via ChainDeploymentKit, 2) Wait for challenge period, 3) Hub governance calls `connectChainFromRegistry()`, 4) Your chain is now part of KSSN with atomic multichain rotation.

### Technical Details

**Q: How many chains can KSSN support?**
A: Single `rotateNetwork()` supports ~450 chains at 30M gas limit. For larger networks, use `rotateShard(shardIndex)` which splits rotation into chunks of 200 chains.

**Q: What is a "Superchain Aligned" design?**
A: KSSN is designed to eventually replace the Superchain Council multisig. Instead of a committee updating SystemConfigs, the SharedSequencerHub does it algorithmically based on Kleros governance decisions.

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Submit a pull request

## License

MIT
