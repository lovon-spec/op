# Constitutional L2 - OP Stack with Kleros Governance

A fully decentralized Layer 2 rollup based on the OP Stack (Superchain), with constitutional governance powered by Kleros subjective dispute resolution.

## What is a Constitutional L2?

A Constitutional L2 is an Optimistic Rollup where sequencer operation is governed by a **constitution** - a set of rules that operators must follow, enforced through decentralized dispute resolution rather than code alone.

**Key Features:**
- **Decentralized Sequencer Rotation**: Multiple operators take turns producing blocks
- **Subjective Rule Enforcement**: Operators can be challenged for violating constitutional rules
- **Kleros Dispute Resolution**: Human jurors decide disputes, enabling nuanced enforcement
- **OP Stack Compatible**: Works with standard OP Stack infrastructure (op-geth, op-node, op-batcher)

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
- **L2**: op-geth + op-node (localhost:9545)
- **Governance**: KlerosSequencerManager with mock Kleros registry

### Try the Sequencer Rotation Demo

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

```
                                    CONSTITUTIONAL L2 ARCHITECTURE

    ┌─────────────────────────────────────────────────────────────────────────────────┐
    │                                    L1 (Ethereum)                                 │
    │  ┌──────────────────┐    ┌────────────────────────┐    ┌──────────────────────┐ │
    │  │   Kleros Curate  │───▶│  KlerosSequencerManager│───▶│  OP SystemConfig     │ │
    │  │   (Registry)     │    │  (Governance Bridge)   │    │  (batcherHash)       │ │
    │  └──────────────────┘    └────────────────────────┘    └──────────────────────┘ │
    │         │                          │                            │               │
    │         │ Operators               │ rotateSequencer()          │ Authorizes    │
    │         │ Register/               │ syncAdd/Remove()           │               │
    │         │ Get Challenged          │                            │               │
    └─────────│──────────────────────────│────────────────────────────│───────────────┘
              │                          │                            │
              ▼                          ▼                            ▼
    ┌─────────────────────────────────────────────────────────────────────────────────┐
    │                              Sequencer Operators                                │
    │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                       │
    │  │  Operator A  │    │  Operator B  │    │  Operator C  │    ...                │
    │  │  op-batcher  │    │  op-batcher  │    │  op-batcher  │                       │
    │  └──────────────┘    └──────────────┘    └──────────────┘                       │
    │         │                   │                   │                               │
    │         └───────────────────┴───────────────────┘                               │
    │                             │ Only authorized batcher                           │
    │                             │ can submit valid batches                          │
    │                             ▼                                                   │
    │  ┌──────────────────────────────────────────────────────────────────────────┐  │
    │  │                          L2 Chain (op-geth + op-node)                     │  │
    │  │                                                                           │  │
    │  │   op-node reads batcherHash from SystemConfig                             │  │
    │  │   Only accepts batches from the authorized sequencer                      │  │
    │  │                                                                           │  │
    │  └──────────────────────────────────────────────────────────────────────────┘  │
    └─────────────────────────────────────────────────────────────────────────────────┘
```

### How It Works

1. **Operators Register**: Sequencer operators submit their addresses to Kleros Curate with a deposit
2. **Community Curation**: During the challenge period, anyone can dispute unfit operators
3. **Sync to Manager**: Approved operators are synced to the KlerosSequencerManager
4. **Epoch Rotation**: Each epoch, a keeper rotates to the next operator in round-robin order
5. **Batch Submission**: Only the current operator's batches are accepted by op-node
6. **Constitutional Enforcement**: Misbehaving operators can be challenged and removed

### The Constitution

The constitution defines rules that operators must follow, enforced through Kleros dispute resolution:

```
Example Constitutional Rules:

1. TRANSACTION ORDERING
   - Operators SHALL NOT reorder transactions for personal profit (sandwiching, frontrunning)
   - Transactions MUST be included in submission order within a reasonable time

2. CENSORSHIP RESISTANCE
   - Operators SHALL NOT systematically exclude valid transactions
   - Operators SHALL NOT discriminate based on sender address

3. LIVENESS
   - Operators MUST submit batches within their assigned epoch
   - Operators MUST maintain >99% uptime during their rotation

4. INTEGRITY
   - Operators SHALL NOT submit invalid state roots
   - Operators SHALL NOT collude to harm users
```

When an operator violates these rules:
1. Anyone can challenge them in Kleros Curate with evidence
2. The operator's status changes to `ClearingRequested`
3. Anyone calls `syncRemoveSequencer()` to immediately remove them
4. Kleros jurors vote on the dispute
5. If guilty, the operator loses their stake

## Deployment

### Local Development

```bash
# Start local devnet
./start.sh local

# Interact with contracts
cast call <MANAGER> "currentSequencer()(address)" --rpc-url http://localhost:8545
cast call <MANAGER> "getActiveSequencers()(address[])" --rpc-url http://localhost:8545
```

### Sepolia Testnet

1. **Configure Environment**

```bash
cp .env.sepolia.example .env.sepolia
# Edit .env.sepolia with your values:
# - L1_RPC: Your Sepolia RPC endpoint
# - REGISTRY: Kleros Curate address (deploy or use existing)
# - SYSTEM_CONFIG: Your OP Stack SystemConfig address
# - DEPLOYER_PRIVATE_KEY: Funded Sepolia account
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
# Current SystemConfig owner must execute:
cast send $SYSTEM_CONFIG "transferOwnership(address)" $MANAGER_ADDRESS \
  --rpc-url $L1_RPC \
  --private-key $OWNER_PRIVATE_KEY
```

4. **Register Operators in Kleros**

Visit https://curate.kleros.io/ and submit operator addresses to your registry.

5. **Sync Operators**

```bash
cast send $MANAGER_ADDRESS "syncAddSequencer(address)" $OPERATOR_ADDRESS \
  --rpc-url $L1_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY
```

6. **Start L2 Services**

```bash
./start.sh sepolia
```

### Mainnet Deployment

**Prerequisites:**
- Kleros Curate TCR deployed with your constitution
- OP Stack L1 contracts deployed
- Guardian multisig set up
- Keeper infrastructure ready

1. **Configure Environment**

```bash
cp .env.mainnet.example .env.mainnet
# Fill in all values - see comments in file
```

2. **Deploy with Extra Verification**

```bash
source .env.mainnet
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url $L1_RPC \
  --broadcast \
  --verify \
  --slow \
  -vvvv
```

3. **Complete Post-Deployment Steps**

See output from deployment script for:
- SystemConfig ownership transfer
- Operator registration
- Keeper setup

## Smart Contracts

### KlerosSequencerManager

The bridge between Kleros governance and OP Stack execution.

```solidity
// Core state
ICurate public immutable registry;      // Kleros Curate registry
ISystemConfig public immutable systemConfig; // OP Stack SystemConfig
uint256 public immutable epochDuration; // Rotation interval

// Sync functions (anyone can call)
function syncAddSequencer(address seq) external;
function syncRemoveSequencer(address seq) external;

// Rotation (anyone can call, once per epoch)
function rotateSequencer() external;
function poke() external; // Alias for keepers

// Guardian (emergency controls)
function setPaused(bool paused) external;
function setGuardian(address newGuardian) external;

// View functions
function currentSequencer() external view returns (address);
function getActiveSequencers() external view returns (address[] memory);
function activeSequencerCount() external view returns (uint256);
function timeUntilNextRotation() external view returns (uint256);
function isRegisteredInRegistry(address seq) external view returns (bool);
```

### Interfaces

- **ICurate**: Kleros Curate Classic (GeneralizedTCR)
- **ISystemConfig**: OP Stack SystemConfig (setBatcherHash)
- **IArbitrator/IArbitrable**: ERC-792 arbitration standard

## OP Stack Integration

### How batcherHash Works

The OP Stack uses `SystemConfig.batcherHash` to authorize batch submitters:

1. **op-batcher** reads `batcherHash` before submitting batches
2. **op-node** validates that batch transactions come from the authorized address
3. **KlerosSequencerManager** updates `batcherHash` on each rotation

### Batcher Hash Format

The V0 format stores the address as the low 20 bytes of a bytes32:

```solidity
bytes32 batcherHash = bytes32(uint256(uint160(sequencerAddress)));
```

### Running Multiple Batchers

For high availability, run one op-batcher per registered operator:

```yaml
# docker-compose.override.yml
services:
  op-batcher-1:
    extends: op-batcher
    environment:
      BATCHER_PRIVATE_KEY: ${OPERATOR_1_KEY}

  op-batcher-2:
    extends: op-batcher
    environment:
      BATCHER_PRIVATE_KEY: ${OPERATOR_2_KEY}
```

Only the currently authorized batcher's submissions will be accepted.

## Keeper Integration

Set up automatic rotation using Gelato, Chainlink Automation, or a custom keeper.

### Gelato Web3 Functions

```javascript
const { ethers } = require("ethers");

Web3Function.onRun(async (context) => {
  const { userArgs, provider } = context;

  const manager = new ethers.Contract(
    userArgs.managerAddress,
    ["function timeUntilNextRotation() view returns (uint256)",
     "function rotateSequencer()"],
    provider
  );

  const timeLeft = await manager.timeUntilNextRotation();
  if (timeLeft > 0) {
    return { canExec: false, message: `${timeLeft}s until rotation` };
  }

  return {
    canExec: true,
    callData: manager.interface.encodeFunctionData("rotateSequencer")
  };
});
```

### Chainlink Automation

```solidity
contract SequencerKeeper is AutomationCompatibleInterface {
    KlerosSequencerManager public manager;

    function checkUpkeep(bytes calldata)
        external view returns (bool upkeepNeeded, bytes memory)
    {
        upkeepNeeded = manager.timeUntilNextRotation() == 0;
    }

    function performUpkeep(bytes calldata) external {
        manager.rotateSequencer();
    }
}
```

## Security Considerations

### Bounded Operations
- All loops are bounded to prevent DoS
- O(1) add/remove using swap-pop pattern
- Safe `currentIndex` handling during removals

### Griefing Mitigation
- High deposit requirement in Kleros deters frivolous challenges
- "Boot on challenge" is conservative - operator removed only when actively challenged
- Guardian can pause in emergencies

### Liveness Guarantees
- If all operators become invalid, rotation emits `RotationSkippedNoValidSequencer`
- Contract self-cleans invalid entries during rotation
- Guardian provides emergency control

## Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test testRotation

# Gas report
forge test --gas-report
```

## File Structure

```
op/
├── src/
│   ├── KlerosSequencerManager.sol    # Main governance contract
│   └── interfaces/
│       ├── ICurate.sol               # Kleros Curate interface
│       ├── ISystemConfig.sol         # OP Stack interface
│       ├── IArbitrator.sol           # ERC-792 arbitration
│       └── IArbitrable.sol           # ERC-792 arbitrable
├── test/
│   ├── KlerosSequencerManager.t.sol  # Comprehensive tests
│   └── mocks/
│       ├── MockCurate.sol            # Test Kleros mock
│       └── MockSystemConfig.sol      # Test SystemConfig mock
├── script/
│   ├── Deploy.s.sol                  # Generic deployment
│   ├── DeployLocal.s.sol             # Local Anvil deployment
│   ├── DeploySepolia.s.sol           # Sepolia deployment
│   └── DeployMainnet.s.sol           # Mainnet deployment
├── docker-compose.yml                # Full OP Stack setup
├── start.sh                          # One-command startup
├── .env.example                      # Environment template
├── .env.sepolia.example              # Sepolia config template
├── .env.mainnet.example              # Mainnet config template
└── foundry.toml                      # Foundry configuration
```

## FAQ

**Q: Can I use this with an existing OP Stack chain?**
A: Yes! Deploy KlerosSequencerManager and transfer SystemConfig ownership to it.

**Q: What if all sequencers go offline?**
A: The last valid batcherHash remains active. The chain continues with that operator until rotation is possible.

**Q: How do I add a new sequencer operator?**
A: 1) Register in Kleros Curate, 2) Wait for challenge period, 3) Call syncAddSequencer().

**Q: Can the guardian rug the chain?**
A: The guardian can only pause operations, not change sequencers or steal funds. It should be a multisig.

**Q: What's the minimum epoch duration?**
A: No hard minimum, but shorter epochs mean more frequent rotation and higher gas costs.

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Submit a pull request

## License

MIT
