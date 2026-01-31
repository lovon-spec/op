# Constitutional L2 - OP Stack with Kleros Governance

A fully decentralized Layer 2 rollup based on the OP Stack (Superchain), with constitutional governance powered by Kleros subjective dispute resolution.

## What is a Constitutional L2?

A Constitutional L2 is an Optimistic Rollup where sequencer operation is governed by a **constitution** - a set of rules that operators must follow, enforced through decentralized dispute resolution rather than code alone.

**Key Features:**
- **Superchain Compliant**: "Green" status with ProxyAdmin to Optimism Security Council
- **Hot-Swappable Adapters**: Survive OP Stack hardforks without contract upgrades
- **Decentralized Sequencer Rotation**: Multiple operators take turns producing blocks
- **Active Handoff Protocol**: Zero-downtime operator transitions with grace period protection
- **Cold Staker / Hot Operator Model**: Separate stake ownership from operational keys
- **Atomic Key Rotation**: Both batcher and unsafe signer keys rotated together
- **Self-Activation Agents**: Operators run local agents that start/stop services based on on-chain state
- **Subjective Rule Enforcement**: Operators can be challenged for violating constitutional rules
- **Kleros Dispute Resolution**: Human jurors decide disputes, enabling nuanced enforcement

## The Constitution

The Constitutional L2 is governed by formal policies enforced through Kleros arbitration:

| Policy | Description |
|--------|-------------|
| [Sequencer Policy](./policies/policy_sequencer_registry.md) | Rules for sequencer operators (censorship, MEV, liveness) |
| [Adapter Policy](./policies/policy_adapter_registry.md) | Acceptance criteria for OP Stack adapters |

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

### Green Adapter Architecture (Superchain Compliant)

The Constitutional L2 achieves **Superchain compliance** ("Green" status) through:

1. **ProxyAdmin → Optimism Security Council**: Standard upgrade path maintained
2. **SystemConfig.owner → KlerosSequencerManager**: Constitutional control of sequencer rotation
3. **Hot-Swappable Adapters**: Survive OP Stack hardforks without changing the manager

```
                      GREEN ADAPTER ARCHITECTURE

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │                              L1 (Ethereum)                                   │
  │                                                                             │
  │  ┌─────────────────┐   ┌─────────────────┐                                  │
  │  │ Operator        │   │ Adapter         │   (Kleros Curate Registries)     │
  │  │ Registry        │   │ Registry        │                                  │
  │  │ (PGTCR Hybrid)  │   │ (Curate)        │                                  │
  │  └────────┬────────┘   └────────┬────────┘                                  │
  │           │                     │                                           │
  │           │   ┌─────────────────┴─────────────────┐                         │
  │           │   │                                   │                         │
  │           ▼   ▼                                   ▼                         │
  │  ┌──────────────────────────────┐    ┌────────────────────┐                 │
  │  │   KlerosSequencerManager     │───▶│  OpStackAdapterV1  │  (delegatecall) │
  │  │                              │    └─────────┬──────────┘                 │
  │  │  - syncAddOperator(itemID)   │              │                            │
  │  │  - rotateOperator()          │              ▼                            │
  │  │  - upgradeAdapter(newAddr)   │    ┌─────────────────┐                    │
  │  │                              │    │  SystemConfig   │                    │
  │  │  Ratchet: v2 > v1 required   │    │  (OP Stack)     │                    │
  │  └──────────────────────────────┘    └─────────────────┘                    │
  │                                                                             │
  └─────────────────────────────────────────────────────────────────────────────┘
```

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

### KlerosSequencerManager

The bridge between Kleros governance and OP Stack execution, with hot-swappable adapter support.

```solidity
// Operator struct
struct Operator {
    address batcher;       // Posts batches to L1
    address unsafeSigner;  // Signs P2P unsafe blocks
}

// Core state (immutable)
IPermanentGTCRHybrid public immutable registry;     // Operator registry (Hybrid PGTCR)
ISystemConfig public immutable systemConfig;        // OP Stack SystemConfig
ICurate public immutable adapterRegistry;           // Adapter registry (Curate)
uint256 public immutable epochDuration;             // Rotation interval

// Constants
uint256 public constant GRACE_PERIOD = 600;         // 10 min grace period for Active Handoff

// Adapter state
IOpStackAdapter public opAdapter;                   // Current adapter

// Sync functions (anyone can call)
function syncAddOperator(bytes32 itemID) external;  // Preferred: by registry item ID
function syncUpdateOperator(bytes32 itemID) external; // Update keys after owner change
function syncRemoveOperator(bytes32 itemID) external;

// Rotation (anyone can call, once per epoch)
function rotateOperator() external;  // Uses adapter via delegatecall
function poke() external;            // Alias for keepers

// Adapter upgrade (anyone can call, gated by registry)
function upgradeAdapter(address _newAdapter) external; // Ratchet: newVersion > currentVersion
function getAdapterInfo() external view returns (address, uint256, string memory, string memory);

// View functions
function currentOperator() external view returns (Operator memory);
function getActiveOperators() external view returns (Operator[] memory);
function isCurrentOperator(address batcher, address unsafeSigner) external view returns (bool);
function isRegisteredInRegistry(address batcher, address unsafeSigner) external view returns (bool);

// Guardian (emergency controls)
function setPaused(bool paused) external;
function setGuardian(address newGuardian) external;
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
│   ├── KlerosSequencerManager.sol    # Main governance contract (adapter pattern)
│   ├── PermanentGTCRHybrid.sol       # Hybrid PGTCR (based on Kleros PGTCR)
│   ├── adapters/
│   │   └── OpStackAdapterV1.sol      # OP Stack Bedrock/Ecotone adapter
│   └── interfaces/
│       ├── IOpStackAdapter.sol       # Adapter interface
│       ├── IPermanentGTCRHybrid.sol  # Hybrid PGTCR interface
│       ├── ICurate.sol               # Kleros Curate interface
│       ├── ISystemConfig.sol         # OP Stack interface (batcher + signer)
│       ├── IArbitrator.sol           # ERC-792 arbitration
│       └── IArbitrable.sol           # ERC-792 arbitrable
├── test/
│   ├── KlerosSequencerManager.t.sol  # Comprehensive tests
│   └── mocks/
│       ├── MockCurate.sol            # Test Kleros Curate mock
│       ├── MockPermanentGTCRHybrid.sol # Test Hybrid PGTCR mock
│       ├── MockSystemConfig.sol      # Test SystemConfig mock
│       └── MockAdapterV2.sol         # V2 adapter stub (for testing)
├── script/
│   ├── DeployLocal.s.sol             # Local Anvil deployment (mocks, offline)
│   ├── DeployRemote.s.sol            # Sepolia/Mainnet deployment (env-configured)
│   ├── IntegrationTest.s.sol         # Solidity integration test (forge script)
│   └── run_integration_test.sh       # Full system integration test (10 scenarios)
├── policies/
│   ├── policy_sequencer_registry.md  # Sequencer constitutional rules
│   └── policy_adapter_registry.md    # Adapter acceptance criteria
├── devnet/
│   ├── genesis-l2.json               # L2 genesis configuration
│   └── generate-configs.sh           # Config generation helper
├── docker/
│   └── config/                       # Generated L2 configs (jwt, rollup.json)
├── agent/
│   ├── self_activation_agent.py      # Reference agent implementation
│   ├── config.example.yaml           # Agent configuration template
│   ├── requirements.txt              # Python dependencies
│   └── README.md                     # Agent documentation
├── docker-compose.yml                # Full OP Stack setup (L1 + L2)
├── start.sh                          # One-command startup script
├── Makefile                          # Development commands
├── .env.example                      # Environment template
├── .env.sepolia.example              # Sepolia config template
└── .env.mainnet.example              # Mainnet config template
```

## FAQ

**Q: Why are operators tuples instead of single addresses?**
A: OP Stack has two separate authorizations: batcherHash (for batch posting) and unsafeBlockSigner (for P2P block signing). Both must be rotated together to avoid half-rotated states.

**Q: What is the Cold Staker / Hot Operator model?**
A: The staker (who deposits governance stake) can delegate operational keys (batcher, unsafeSigner) to different addresses. If the hot operational keys are compromised, the governance stake remains safe. Use `setOperationalKeys(itemID, batcher, signer)` after registration.

**Q: What happens during an OP Stack hardfork?**
A: The adapter pattern allows hot-swapping adapters without changing the manager. Submit a new adapter to the Adapter Registry, wait for the challenge period, then call `upgradeAdapter(newAdapterAddress)`. The ratchet ensures `newVersion > currentVersion`.

**Q: What is the "Hydra" defense?**
A: If someone griefs adapter submissions by challenging them, multiple identical adapters can be submitted in parallel. First one to pass becomes usable, defeating the griefing attack.

**Q: What if an operator doesn't run a self-activation agent?**
A: They can be challenged in Kleros for producing blocks while unauthorized (if they continue running) or for failing to produce blocks during their epoch (if they never start).

**Q: Can I use the same key for batcher and unsafeSigner?**
A: Technically yes, but it's not recommended for security. The Cold Staker model allows separating stake from operational keys.

**Q: How do I add a new operator?**
A: 1) Register in Hybrid PGTCR with Constitutional Declaration, 2) Optionally set operational keys, 3) Wait for challenge period, 4) Call `syncAddOperator(itemID)`, 5) Deploy self-activation agent.

**Q: What happens during rotation?**
A: 1) Current operator's agent detects epoch end, 2) Agent stops sequencing and flushes batches to L1, 3) Agent calls `rotateOperator()`, 4) Manager validates and calls adapter via delegatecall, 5) Adapter sets batcherHash and unsafeBlockSigner in SystemConfig, 6) New operator's agent detects the change and starts sequencing.

**Q: What is the Active Handoff protocol?**
A: Active Handoff is a 3-phase state machine that ensures zero-downtime operator transitions. During the "grace period" after epoch ends, only the current operator can trigger rotation. This prevents L2 re-orgs by allowing the outgoing operator to flush their batch queue before handing over control.

**Q: Why can't keepers immediately rotate after epoch ends?**
A: To prevent L2 re-orgs. If a keeper forces rotation while the outgoing operator has unflushed "unsafe" blocks, those blocks would be orphaned. The grace period (10 minutes) gives the operator time to flush batches and trigger rotation themselves.

**Q: What if the current operator doesn't rotate during the grace period?**
A: After the grace period expires (Phase 3 - Dead Man's Switch), anyone can force rotation. This ensures liveness even if an operator is unresponsive, though it may cause a re-org if they had unflushed batches.

**Q: What is a "Superchain Green" chain?**
A: A chain that maintains Optimism Security Council oversight via ProxyAdmin while allowing custom governance (like Kleros) for operational aspects. This ensures coordinated upgrades remain possible.

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Submit a pull request

## License

MIT
