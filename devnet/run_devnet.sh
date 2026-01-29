#!/bin/bash
#
# Full OP Stack Devnet with Kleros Sequencer Manager
#
# This script runs a complete OP Stack devnet:
# - L1: Anvil
# - L2: op-geth + op-node
# - Batcher: op-batcher (3 instances for rotation testing)
# - Sequencer control: KlerosSequencerManager
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVNET_DIR="$SCRIPT_DIR"
CONFIG_DIR="$DEVNET_DIR/config"
DATA_DIR="$DEVNET_DIR/data"
LOG_DIR="$DEVNET_DIR/logs"
FOUNDRY_BIN="$HOME/.foundry/bin"

export PATH="$FOUNDRY_BIN:$PATH"

# Binaries
OP_GETH="$DEVNET_DIR/op-geth/build/bin/geth"
OP_NODE="$DEVNET_DIR/optimism/bin/op-node"
OP_BATCHER="$DEVNET_DIR/optimism/bin/op-batcher"
OP_PROPOSER="$DEVNET_DIR/optimism/bin/op-proposer"

# Network config
L1_RPC="http://127.0.0.1:8545"
L2_RPC="http://127.0.0.1:9545"
L2_WS="ws://127.0.0.1:9546"
L2_ENGINE="http://127.0.0.1:8551"
L2_ENGINE_WS="ws://127.0.0.1:8552"

# Test accounts (Anvil mnemonic)
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

SEQ1_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
SEQ1_ADDR="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

SEQ2_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
SEQ2_ADDR="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

SEQ3_KEY="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
SEQ3_ADDR="0x90F79bf6EB2c4f870365E785982E1f101E93b906"

GUARDIAN_KEY="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
GUARDIAN_ADDR="0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"

PIDS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

cleanup() {
    echo -e "\n${YELLOW}Shutting down devnet...${NC}"
    for pid in "${PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    pkill -f "anvil" 2>/dev/null || true
    pkill -f "op-geth" 2>/dev/null || true
    pkill -f "op-node" 2>/dev/null || true
    pkill -f "op-batcher" 2>/dev/null || true
    echo -e "${GREEN}Devnet stopped${NC}"
}

trap cleanup EXIT

mkdir -p "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"

print_header() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

wait_for_rpc() {
    local url=$1
    local name=$2
    local max_attempts=30
    local attempt=0

    echo -n "  Waiting for $name..."
    while ! curl -s "$url" -X POST -H "Content-Type: application/json" \
           --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo -e " ${RED}FAILED${NC}"
            return 1
        fi
        sleep 1
        echo -n "."
    done
    echo -e " ${GREEN}OK${NC}"
}

# ============================================================
print_header "PHASE 1: Starting L1 (Anvil)"

pkill -f "anvil" 2>/dev/null || true
sleep 1

anvil --port 8545 --chain-id 31337 --block-time 2 \
    > "$LOG_DIR/anvil.log" 2>&1 &
PIDS+=($!)

wait_for_rpc "$L1_RPC" "L1"

echo -e "  ${GREEN}✓${NC} L1 running on $L1_RPC (chain ID: 31337)"

# ============================================================
print_header "PHASE 2: Deploying L1 Contracts"

cd "$PROJECT_ROOT"

echo "  Deploying KlerosSequencerManager and mocks..."
forge script script/DeployLocal.s.sol:DeployLocal \
    --rpc-url "$L1_RPC" \
    --broadcast \
    > "$LOG_DIR/deploy.log" 2>&1

# Extract addresses
get_addr() {
    python3 -c "
import json
with open('broadcast/DeployLocal.s.sol/31337/run-latest.json') as f:
    data = json.load(f)
    for tx in data.get('transactions', []):
        if tx.get('transactionType') == 'CREATE' and tx.get('contractName') == '$1':
            print(tx.get('contractAddress'))
            break
"
}

CURATE=$(get_addr "MockCurate")
SYSTEM_CONFIG=$(get_addr "MockSystemConfig")
MANAGER=$(get_addr "KlerosSequencerManager")

echo -e "  ${GREEN}✓${NC} MockCurate: $CURATE"
echo -e "  ${GREEN}✓${NC} MockSystemConfig: $SYSTEM_CONFIG"
echo -e "  ${GREEN}✓${NC} KlerosSequencerManager: $MANAGER"

# Get current sequencer
CURRENT_SEQ=$(cast call "$MANAGER" "currentSequencer()(address)" --rpc-url "$L1_RPC")
BATCHER_HASH=$(cast call "$SYSTEM_CONFIG" "batcherHash()(bytes32)" --rpc-url "$L1_RPC")
echo ""
echo -e "  Current Sequencer: ${GREEN}$CURRENT_SEQ${NC}"
echo -e "  Batcher Hash: $BATCHER_HASH"

# ============================================================
print_header "PHASE 3: Generating L2 Genesis"

# Generate JWT secret for engine API
JWT_SECRET=$(openssl rand -hex 32)
echo "$JWT_SECRET" > "$DATA_DIR/jwt.txt"

# Get L1 block info for timestamp alignment
L1_BLOCK=$(cast block latest --rpc-url "$L1_RPC" --json 2>/dev/null)
L1_HASH=$(echo "$L1_BLOCK" | python3 -c "import sys,json; print(json.load(sys.stdin)['hash'])")
L1_NUMBER=$(echo "$L1_BLOCK" | python3 -c "import sys,json; print(int(json.load(sys.stdin)['number'], 16))")
L1_TIMESTAMP=$(echo "$L1_BLOCK" | python3 -c "import sys,json; print(int(json.load(sys.stdin)['timestamp'], 16))")
L1_TIMESTAMP_HEX=$(printf "0x%x" $L1_TIMESTAMP)

# Create L2 genesis with full OP Stack config
# Note: ecotone/fjord/granite disabled as they require a beacon node for blob support
cat > "$CONFIG_DIR/genesis-l2.json" << GENESIS
{
  "config": {
    "chainId": 42069,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "muirGlacierBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "arrowGlacierBlock": 0,
    "grayGlacierBlock": 0,
    "mergeNetsplitBlock": 0,
    "shanghaiTime": 0,
    "terminalTotalDifficulty": 0,
    "bedrockBlock": 0,
    "regolithTime": 0,
    "canyonTime": 0,
    "optimism": {
      "eip1559Elasticity": 6,
      "eip1559Denominator": 50,
      "eip1559DenominatorCanyon": 250
    }
  },
  "nonce": "0x0",
  "timestamp": "$L1_TIMESTAMP_HEX",
  "extraData": "0x",
  "gasLimit": "0x1c9c380",
  "difficulty": "0x0",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "coinbase": "0x0000000000000000000000000000000000000000",
  "alloc": {
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266": {
      "balance": "0x21e19e0c9bab2400000"
    },
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8": {
      "balance": "0x21e19e0c9bab2400000"
    },
    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC": {
      "balance": "0x21e19e0c9bab2400000"
    },
    "0x90F79bf6EB2c4f870365E785982E1f101E93b906": {
      "balance": "0x21e19e0c9bab2400000"
    }
  },
  "baseFeePerGas": "0x3b9aca00"
}
GENESIS

echo -e "  ${GREEN}✓${NC} L2 genesis created"
echo -e "  ${GREEN}✓${NC} JWT secret generated"

# ============================================================
print_header "PHASE 4: Starting L2 Execution (op-geth)"

# Initialize op-geth datadir
rm -rf "$DATA_DIR/geth"
mkdir -p "$DATA_DIR/geth"

$OP_GETH init \
    --datadir "$DATA_DIR/geth" \
    "$CONFIG_DIR/genesis-l2.json" \
    > "$LOG_DIR/geth-init.log" 2>&1

echo -e "  ${GREEN}✓${NC} op-geth initialized"

# Start op-geth
$OP_GETH \
    --datadir "$DATA_DIR/geth" \
    --http \
    --http.addr "0.0.0.0" \
    --http.port 9545 \
    --http.corsdomain "*" \
    --http.vhosts "*" \
    --http.api "web3,debug,eth,txpool,net,engine,miner" \
    --ws \
    --ws.addr "0.0.0.0" \
    --ws.port 9546 \
    --ws.origins "*" \
    --ws.api "debug,eth,txpool,net,engine,miner" \
    --authrpc.addr "0.0.0.0" \
    --authrpc.port 8551 \
    --authrpc.vhosts "*" \
    --authrpc.jwtsecret "$DATA_DIR/jwt.txt" \
    --syncmode full \
    --nodiscover \
    --maxpeers 0 \
    --networkid 42069 \
    --gcmode archive \
    --rollup.disabletxpoolgossip \
    > "$LOG_DIR/geth.log" 2>&1 &
PIDS+=($!)

wait_for_rpc "$L2_RPC" "L2 (op-geth)"
echo -e "  ${GREEN}✓${NC} op-geth running on $L2_RPC"

# ============================================================
print_header "PHASE 5: Starting L2 Consensus (op-node)"

# Get the L2 genesis hash from the initialized op-geth
L2_GENESIS_HASH=$($OP_GETH --datadir "$DATA_DIR/geth" --exec 'eth.getBlock(0).hash' console 2>/dev/null | tr -d '"')
echo "  L2 genesis hash: $L2_GENESIS_HASH"

# Create rollup config
# Note: ecotone/fjord disabled as they require a beacon node for blob support
cat > "$CONFIG_DIR/rollup.json" << ROLLUP
{
  "genesis": {
    "l1": {
      "hash": "$L1_HASH",
      "number": $L1_NUMBER
    },
    "l2": {
      "hash": "$L2_GENESIS_HASH",
      "number": 0
    },
    "l2_time": $L1_TIMESTAMP,
    "system_config": {
      "batcherAddr": "$SEQ1_ADDR",
      "overhead": "0x0000000000000000000000000000000000000000000000000000000000000834",
      "scalar": "0x00000000000000000000000000000000000000000000000000000000000f4240",
      "gasLimit": 30000000
    }
  },
  "block_time": 2,
  "max_sequencer_drift": 600,
  "seq_window_size": 3600,
  "channel_timeout": 300,
  "l1_chain_id": 31337,
  "l2_chain_id": 42069,
  "regolith_time": 0,
  "canyon_time": 0,
  "delta_time": 0,
  "batch_inbox_address": "0xff00000000000000000000000000000000042069",
  "deposit_contract_address": "0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF",
  "l1_system_config_address": "$SYSTEM_CONFIG",
  "chain_op_config": {
    "eip1559Elasticity": 6,
    "eip1559Denominator": 50,
    "eip1559DenominatorCanyon": 250
  }
}
ROLLUP

echo -e "  ${GREEN}✓${NC} Rollup config created"
echo "  L1 genesis block: $L1_NUMBER ($L1_HASH)"

# Create L1 chain config for Anvil (required for unknown chain IDs)
# Must be wrapped in "config" object and use correct field names
cat > "$CONFIG_DIR/l1-chain-config.json" << 'L1CONFIG'
{
  "config": {
    "chainId": 31337,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "muirGlacierBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "arrowGlacierBlock": 0,
    "grayGlacierBlock": 0,
    "mergeNetsplitBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "terminalTotalDifficulty": 0,
    "blobSchedule": {
      "cancun": {
        "target": 3,
        "max": 6,
        "baseFeeUpdateFraction": 3338477
      }
    }
  }
}
L1CONFIG
echo -e "  ${GREEN}✓${NC} L1 chain config created"

# Start op-node in sequencer mode
$OP_NODE \
    --l1 "$L1_RPC" \
    --l2 "$L2_ENGINE" \
    --l2.jwt-secret "$DATA_DIR/jwt.txt" \
    --rollup.config "$CONFIG_DIR/rollup.json" \
    --rollup.l1-chain-config "$CONFIG_DIR/l1-chain-config.json" \
    --sequencer.enabled \
    --sequencer.l1-confs 0 \
    --p2p.disable \
    --rpc.addr "0.0.0.0" \
    --rpc.port 9547 \
    --log.level info \
    > "$LOG_DIR/op-node.log" 2>&1 &
PIDS+=($!)

sleep 3
echo -e "  ${GREEN}✓${NC} op-node running (sequencer mode)"

# ============================================================
print_header "PHASE 6: Starting Batcher (op-batcher)"

# Start op-batcher for the current sequencer
# Throttle disabled (0 limits) to avoid miner API issues with Anvil
$OP_BATCHER \
    --l1-eth-rpc "$L1_RPC" \
    --l2-eth-rpc "$L2_RPC" \
    --rollup-rpc "http://127.0.0.1:9547" \
    --poll-interval 1s \
    --sub-safety-margin 4 \
    --num-confirmations 1 \
    --safe-abort-nonce-too-low-count 3 \
    --private-key "$SEQ1_KEY" \
    --throttle.block-size-lower-limit 0 \
    --throttle.block-size-upper-limit 0 \
    --log.level info \
    > "$LOG_DIR/op-batcher.log" 2>&1 &
PIDS+=($!)

sleep 2
echo -e "  ${GREEN}✓${NC} op-batcher running (using SEQ-1 key)"

# ============================================================
print_header "PHASE 7: Verifying L2 is Producing Blocks"

echo "  Waiting for L2 blocks..."
sleep 5

L2_BLOCK=$(cast block latest --rpc-url "$L2_RPC" 2>/dev/null)
L2_NUMBER=$(echo "$L2_BLOCK" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])" 2>/dev/null || echo "0")

echo -e "  ${GREEN}✓${NC} L2 block height: $L2_NUMBER"

# ============================================================
print_header "DEVNET STATUS"

echo "L1 (Anvil):"
echo "  RPC: $L1_RPC"
echo "  Chain ID: 31337"
echo ""
echo "L2 (OP Stack):"
echo "  RPC: $L2_RPC"
echo "  WS: $L2_WS"
echo "  Chain ID: 42069"
echo ""
echo "Contracts:"
echo "  MockCurate: $CURATE"
echo "  MockSystemConfig: $SYSTEM_CONFIG"
echo "  KlerosSequencerManager: $MANAGER"
echo ""
echo "Current Sequencer: $CURRENT_SEQ"
echo ""
echo "Logs: $LOG_DIR/"
echo ""

# ============================================================
print_header "TEST: Sequencer Rotation"

echo "Testing sequencer rotation via KlerosSequencerManager..."
echo ""

advance_time() {
    curl -s -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"evm_increaseTime\",\"params\":[$1],\"id\":1}" \
         -H "Content-Type: application/json" "$L1_RPC" > /dev/null
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id":1}' \
         -H "Content-Type: application/json" "$L1_RPC" > /dev/null
}

show_status() {
    local seq=$(cast call "$MANAGER" "currentSequencer()(address)" --rpc-url "$L1_RPC" 2>/dev/null)
    local hash=$(cast call "$SYSTEM_CONFIG" "batcherHash()(bytes32)" --rpc-url "$L1_RPC" 2>/dev/null)
    echo -e "  Sequencer: ${GREEN}$seq${NC}"
    echo "  BatcherHash: $hash"
}

echo "Initial state:"
show_status
echo ""

for i in 1 2 3; do
    echo -e "${YELLOW}>>> Rotation $i${NC}"
    advance_time 15  # Epoch is 10 seconds
    cast send "$MANAGER" "rotateSequencer()" \
        --rpc-url "$L1_RPC" \
        --private-key "$DEPLOYER_KEY" \
        > /dev/null 2>&1
    show_status
    echo ""
    sleep 2
done

# ============================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  DEVNET RUNNING - Press Enter to stop${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "You can interact with the devnet:"
echo "  L1: cast call $MANAGER 'currentSequencer()' --rpc-url $L1_RPC"
echo "  L2: cast block latest --rpc-url $L2_RPC"
echo ""

read -p "Press Enter to shut down..."
