# Constitutional L2 - OP Stack with Kleros Governance

A fully decentralized Layer 2 rollup based on the OP Stack (Superchain), with constitutional governance powered by Kleros subjective dispute resolution.

## What is a Constitutional L2?

A Constitutional L2 is an Optimistic Rollup where sequencer operation is governed by a **constitution** - a set of rules that operators must follow, enforced through decentralized dispute resolution rather than code alone.

**Key Features:**
- **Decentralized Sequencer Rotation**: Multiple operators take turns producing blocks
- **Operator Tuples**: Each operator registers both a batcher key AND an unsafe signer key
- **Atomic Key Rotation**: Both keys are rotated together to prevent half-rotated states
- **Self-Activation Agents**: Operators run local agents that start/stop services based on on-chain state
- **Subjective Rule Enforcement**: Operators can be challenged for violating constitutional rules
- **Kleros Dispute Resolution**: Human jurors decide disputes, enabling nuanced enforcement

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

This starts a complete constitutional L2:
- **L1**: Local Anvil chain (localhost:8545)
- **Governance**: KlerosSequencerManager with mock Kleros registry
- **Operators**: 3 test operators registered and ready for rotation

### Try the Operator Rotation Demo

```bash
./start.sh demo
```

### View Status and Logs

```bash
./start.sh status   # Show service status
./start.sh logs     # Stream logs
./start.sh stop     # Stop all services
```

## Architecture

### Operator Tuple Model

**CRITICAL**: OP Stack sequencer authority requires TWO keys rotated together:

| Key | Purpose | SystemConfig Function |
|-----|---------|----------------------|
| **Batcher** | Posts batches to L1 | `setBatcherHash()` |
| **Unsafe Signer** | Signs P2P unsafe blocks | `setUnsafeBlockSigner()` |

Both keys are registered as a tuple in Kleros Curate and rotated atomically by the manager.

```
                        CONSTITUTIONAL L2 ARCHITECTURE

  ┌──────────────────────────────────────────────────────────────────────────┐
  │                              L1 (Ethereum)                                │
  │                                                                          │
  │  ┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────┐  │
  │  │  Kleros Curate  │───▶│ KlerosSequencerMgr   │───▶│  SystemConfig   │  │
  │  │                 │    │                      │    │                 │  │
  │  │ Operator Tuples │    │ rotateOperator()     │    │ batcherHash     │  │
  │  │ (batcher,signer)│    │ syncAddOperator()    │    │ unsafeBlockSign │  │
  │  └─────────────────┘    └──────────────────────┘    └─────────────────┘  │
  │                                   │                                      │
  └───────────────────────────────────│──────────────────────────────────────┘
                                      │
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
          ▼                           ▼                           ▼
  ┌───────────────────┐     ┌───────────────────┐     ┌───────────────────┐
  │   Operator A      │     │   Operator B      │     │   Operator C      │
  │                   │     │                   │     │                   │
  │ ┌───────────────┐ │     │ ┌───────────────┐ │     │ ┌───────────────┐ │
  │ │Self-Activation│ │     │ │Self-Activation│ │     │ │Self-Activation│ │
  │ │    Agent      │ │     │ │    Agent      │ │     │ │    Agent      │ │
  │ └───────┬───────┘ │     │ └───────┬───────┘ │     │ └───────┬───────┘ │
  │         │         │     │         │         │     │         │         │
  │ ┌───────▼───────┐ │     │ ┌───────▼───────┐ │     │ ┌───────▼───────┐ │
  │ │   op-node     │ │     │ │   op-node     │ │     │ │   op-node     │ │
  │ │  op-batcher   │ │     │ │  op-batcher   │ │     │ │  op-batcher   │ │
  │ │  (stopped)    │ │     │ │  (ACTIVE)     │ │     │ │  (stopped)    │ │
  │ └───────────────┘ │     │ └───────────────┘ │     │ └───────────────┘ │
  └───────────────────┘     └───────────────────┘     └───────────────────┘
```

### Self-Activation Agents

Each operator MUST run a self-activation agent that:
1. Monitors `isCurrentOperator(batcher, unsafeSigner)` on-chain
2. Starts local op-node sequencer + op-batcher when becoming active
3. Stops them when no longer active

This is a **constitutional requirement** - operators that produce blocks while unauthorized can be challenged and removed.

See [`agent/`](./agent/) for a reference implementation.

### How It Works

1. **Operators Register**: Submit (batcher, unsafeSigner) tuple to Kleros Curate with deposit
2. **Community Curation**: Challenge period allows disputing unfit operators
3. **Sync to Manager**: Call `syncAddOperator(batcher, unsafeSigner)` to add approved operators
4. **Epoch Rotation**: Keeper calls `rotateOperator()` each epoch
5. **Atomic Update**: Manager sets BOTH `batcherHash` AND `unsafeBlockSigner` in SystemConfig
6. **Self-Activation**: Operator agents detect the change and start/stop services
7. **Constitutional Enforcement**: Misbehaving operators challenged via Kleros

### The Constitution

The constitution defines rules that operators must follow:

```
Example Constitutional Rules:

1. TRANSACTION ORDERING
   - Operators SHALL NOT reorder transactions for MEV extraction
   - Transactions MUST be included in submission order within reasonable time

2. CENSORSHIP RESISTANCE
   - Operators SHALL NOT systematically exclude valid transactions
   - Operators SHALL NOT discriminate based on sender address

3. LIVENESS
   - Operators MUST submit batches within their assigned epoch
   - Operators MUST maintain >99% uptime during their rotation

4. SELF-ACTIVATION COMPLIANCE
   - Operators MUST run a self-activation agent
   - Operators MUST NOT produce blocks while unauthorized
   - Operators MUST stop services promptly when rotated out

5. INTEGRITY
   - Operators SHALL NOT submit invalid state roots
   - Operators SHALL NOT collude to harm users
```

## Smart Contracts

### KlerosSequencerManager

The bridge between Kleros governance and OP Stack execution.

```solidity
// Operator struct
struct Operator {
    address batcher;       // Posts batches to L1
    address unsafeSigner;  // Signs P2P unsafe blocks
}

// Core state
ICurate public immutable registry;      // Kleros Curate registry
ISystemConfig public immutable systemConfig; // OP Stack SystemConfig
uint256 public immutable epochDuration; // Rotation interval

// Sync functions (anyone can call)
function syncAddOperator(address batcher, address unsafeSigner) external;
function syncRemoveOperator(address batcher, address unsafeSigner) external;

// Rotation (anyone can call, once per epoch)
function rotateOperator() external;  // Sets BOTH batcherHash AND unsafeBlockSigner
function poke() external;            // Alias for keepers

// View functions
function currentOperator() external view returns (Operator memory);
function getActiveOperators() external view returns (Operator[] memory);
function activeOperatorCount() external view returns (uint256);
function isCurrentOperator(address batcher, address unsafeSigner) external view returns (bool);
function timeUntilNextRotation() external view returns (uint256);

// Guardian (emergency controls)
function setPaused(bool paused) external;
function setGuardian(address newGuardian) external;
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
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url $L1_RPC \
  --broadcast \
  --verify
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

See `script/DeployMainnet.s.sol` for detailed deployment steps.

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

Set up automatic rotation using Gelato, Chainlink Automation, or a custom keeper.

### Gelato Web3 Functions

```javascript
Web3Function.onRun(async (context) => {
  const { userArgs, provider } = context;

  const manager = new ethers.Contract(
    userArgs.managerAddress,
    ["function timeUntilNextRotation() view returns (uint256)",
     "function rotateOperator()"],
    provider
  );

  const timeLeft = await manager.timeUntilNextRotation();
  if (timeLeft > 0) {
    return { canExec: false, message: `${timeLeft}s until rotation` };
  }

  return {
    canExec: true,
    callData: manager.interface.encodeFunctionData("rotateOperator")
  };
});
```

## Security Considerations

### Atomic Rotation
- Both `batcherHash` and `unsafeBlockSigner` are set in the same transaction
- Prevents "half-rotated" states where batches and P2P blocks have different authorities

### Self-Activation Compliance
- Constitutional requirement enforced via Kleros
- Operators can be challenged for producing blocks while unauthorized

### Bounded Operations
- All loops are bounded to prevent DoS
- O(1) add/remove using swap-pop pattern

### Griefing Mitigation
- High deposit requirement in Kleros deters frivolous challenges
- Guardian can pause in emergencies

## File Structure

```
op/
├── src/
│   ├── KlerosSequencerManager.sol    # Main governance contract
│   └── interfaces/
│       ├── ICurate.sol               # Kleros Curate interface
│       ├── ISystemConfig.sol         # OP Stack interface (batcher + signer)
│       ├── IArbitrator.sol           # ERC-792 arbitration
│       └── IArbitrable.sol           # ERC-792 arbitrable
├── test/
│   ├── KlerosSequencerManager.t.sol  # Comprehensive tests
│   └── mocks/
│       ├── MockCurate.sol            # Test Kleros mock
│       └── MockSystemConfig.sol      # Test SystemConfig mock
├── script/
│   ├── DeployLocal.s.sol             # Local Anvil deployment
│   ├── DeploySepolia.s.sol           # Sepolia deployment
│   └── DeployMainnet.s.sol           # Mainnet deployment
├── agent/
│   ├── self_activation_agent.py      # Reference agent implementation
│   ├── config.example.yaml           # Agent configuration template
│   ├── requirements.txt              # Python dependencies
│   └── README.md                     # Agent documentation
├── docker-compose.yml                # Full OP Stack setup
├── start.sh                          # One-command startup
├── Makefile                          # Development commands
├── .env.example                      # Environment template
├── .env.sepolia.example              # Sepolia config template
└── .env.mainnet.example              # Mainnet config template
```

## FAQ

**Q: Why are operators tuples instead of single addresses?**
A: OP Stack has two separate authorizations: batcherHash (for batch posting) and unsafeBlockSigner (for P2P block signing). Both must be rotated together to avoid half-rotated states.

**Q: What if an operator doesn't run a self-activation agent?**
A: They can be challenged in Kleros for producing blocks while unauthorized (if they continue running) or for failing to produce blocks during their epoch (if they never start).

**Q: Can I use the same key for batcher and unsafeSigner?**
A: Technically yes, but it's not recommended for security. The contract allows it but logs a warning.

**Q: How do I add a new operator?**
A: 1) Register tuple in Kleros Curate, 2) Wait for challenge period, 3) Call `syncAddOperator(batcher, unsafeSigner)`, 4) Deploy self-activation agent.

**Q: What happens during rotation?**
A: 1) Keeper calls `rotateOperator()`, 2) Manager sets both batcherHash and unsafeBlockSigner in SystemConfig, 3) Self-activation agents detect the change and start/stop services.

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Submit a pull request

## License

MIT
