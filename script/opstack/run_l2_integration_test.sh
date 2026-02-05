#!/bin/bash
# Full OP Stack L2 Integration Test with ISOCHRON Sequencer Rotation (legacy: KlerosSequencerManager)
#
# This script runs a complete integration test showing:
# 1. L1 (Anvil) with the sequencer manager (legacy: KlerosSequencerManager) controlling SystemConfig
# 2. Simulated L2 producing blocks
# 3. Multiple batchers checking authorization
# 4. Live rotation between sequencers
# 5. Real-time visualization of the whole system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FOUNDRY_BIN="$HOME/.foundry/bin"
export PATH="$FOUNDRY_BIN:$PATH"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Anvil accounts
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SEQ1_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
SEQ2_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
SEQ3_KEY="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
GUARDIAN_KEY="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"

SEQUENCER_1="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SEQUENCER_2="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
SEQUENCER_3="0x90F79bf6EB2c4f870365E785982E1f101E93b906"

BATCH_INBOX="0xff00000000000000000000000000000000000000"
EPOCH_DURATION=10

PIDS=()
LOG_DIR="/tmp/op-integration-test-logs"
mkdir -p "$LOG_DIR"

cleanup() {
    echo -e "\n${YELLOW}Shutting down...${NC}"
    for pid in "${PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    pkill -f "batcher_sim.py" 2>/dev/null || true
    pkill -f "l2_simulator.py" 2>/dev/null || true
    echo -e "${GREEN}All processes stopped${NC}"
}

trap cleanup EXIT

advance_time() {
    curl -s -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"evm_increaseTime\",\"params\":[$1],\"id\":1}" \
         -H "Content-Type: application/json" "$RPC_URL" > /dev/null
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id\":1}' \
         -H "Content-Type: application/json" "$RPC_URL" > /dev/null
}

get_contract_address() {
    python3 -c "
import json
with open('$PROJECT_ROOT/broadcast/DeployLocal.s.sol/31337/run-latest.json') as f:
    data = json.load(f)
    for tx in data.get('transactions', []):
        if tx.get('transactionType') == 'CREATE' and tx.get('contractName') == '$1':
            print(tx.get('contractAddress'))
            break
"
}

# Check if Anvil is running
if ! curl -s "$RPC_URL" > /dev/null 2>&1; then
    echo -e "${RED}Error: Anvil not running on $RPC_URL${NC}"
    echo "Please start Anvil first: anvil --port 8545"
    exit 1
fi

clear
echo -e "${MAGENTA}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║     ISOCHRON SEQUENCER MANAGER - FULL OP STACK INTEGRATION TEST║"
echo "║                                                                ║"
echo "║     Decentralized Sequencer Rotation for OP Stack              ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ============================================================
echo -e "${CYAN}[1/6] Deploying L1 Contracts${NC}"
echo "────────────────────────────────────────────────────────────────"

cd "$PROJECT_ROOT"
forge script script/DeployLocal.s.sol:DeployLocal --rpc-url $RPC_URL --broadcast > "$LOG_DIR/deploy.log" 2>&1

CURATE=$(get_contract_address "MockCurate")
SYSTEM_CONFIG=$(get_contract_address "MockSystemConfig")
MANAGER=$(get_contract_address "KlerosSequencerManager")

echo -e "  ${GREEN}✓${NC} MockCurate:            $CURATE"
echo -e "  ${GREEN}✓${NC} MockSystemConfig:      $SYSTEM_CONFIG"
echo -e "  ${GREEN}✓${NC} SequencerManager (legacy: KlerosSequencerManager): $MANAGER"
echo -e "  ${GREEN}✓${NC} BatchInbox:            $BATCH_INBOX"
echo ""

# ============================================================
echo -e "${CYAN}[2/6] Starting Simulated Batchers${NC}"
echo "────────────────────────────────────────────────────────────────"

# Start batchers
python3 "$SCRIPT_DIR/batcher_sim.py" \
    --rpc-url "$RPC_URL" --system-config "$SYSTEM_CONFIG" \
    --private-key "$SEQ1_KEY" --batcher-address "$SEQUENCER_1" \
    --batch-inbox "$BATCH_INBOX" --name "SEQ-1" --interval 2 \
    > "$LOG_DIR/batcher1.log" 2>&1 &
PIDS+=($!)

python3 "$SCRIPT_DIR/batcher_sim.py" \
    --rpc-url "$RPC_URL" --system-config "$SYSTEM_CONFIG" \
    --private-key "$SEQ2_KEY" --batcher-address "$SEQUENCER_2" \
    --batch-inbox "$BATCH_INBOX" --name "SEQ-2" --interval 2 \
    > "$LOG_DIR/batcher2.log" 2>&1 &
PIDS+=($!)

python3 "$SCRIPT_DIR/batcher_sim.py" \
    --rpc-url "$RPC_URL" --system-config "$SYSTEM_CONFIG" \
    --private-key "$SEQ3_KEY" --batcher-address "$SEQUENCER_3" \
    --batch-inbox "$BATCH_INBOX" --name "SEQ-3" --interval 2 \
    > "$LOG_DIR/batcher3.log" 2>&1 &
PIDS+=($!)

echo -e "  ${GREEN}✓${NC} Batcher-1 (SEQ-1): ${SEQUENCER_1:0:10}..."
echo -e "  ${GREEN}✓${NC} Batcher-2 (SEQ-2): ${SEQUENCER_2:0:10}..."
echo -e "  ${GREEN}✓${NC} Batcher-3 (SEQ-3): ${SEQUENCER_3:0:10}..."
echo ""
sleep 2

# ============================================================
echo -e "${CYAN}[3/6] Starting L2 Block Production${NC}"
echo "────────────────────────────────────────────────────────────────"

python3 "$SCRIPT_DIR/l2_simulator.py" \
    --rpc-url "$RPC_URL" --system-config "$SYSTEM_CONFIG" \
    --manager "$MANAGER" --duration 120 --block-time 2 \
    > "$LOG_DIR/l2.log" 2>&1 &
L2_PID=$!
PIDS+=($L2_PID)

echo -e "  ${GREEN}✓${NC} L2 simulator started (block time: 2s)"
echo ""
sleep 3

# ============================================================
echo -e "${CYAN}[4/6] Live System Status${NC}"
echo "────────────────────────────────────────────────────────────────"

show_status() {
    local current_seq=$(cast call $MANAGER "currentSequencer()(address)" --rpc-url $RPC_URL 2>/dev/null)
    local active_count=$(cast call $MANAGER "activeSequencerCount()(uint256)" --rpc-url $RPC_URL 2>/dev/null)
    local batcher_hash=$(cast call $SYSTEM_CONFIG "batcherHash()(bytes32)" --rpc-url $RPC_URL 2>/dev/null)

    echo ""
    echo -e "${BLUE}┌─ Current State ─────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} Active Sequencers: $active_count                                      ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Current Sequencer: ${current_seq:0:20}...    ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Batcher Hash:      ${batcher_hash:0:20}...    ${BLUE}│${NC}"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"

    # Show which batcher is active
    if [[ "$current_seq" == *"70997970"* ]]; then
        echo -e "  ${GREEN}► SEQ-1 is ACTIVE (submitting batches)${NC}"
        echo -e "    SEQ-2 waiting..."
        echo -e "    SEQ-3 waiting..."
    elif [[ "$current_seq" == *"3C44CdDd"* ]]; then
        echo -e "    SEQ-1 waiting..."
        echo -e "  ${GREEN}► SEQ-2 is ACTIVE (submitting batches)${NC}"
        echo -e "    SEQ-3 waiting..."
    elif [[ "$current_seq" == *"90F79bf6"* ]]; then
        echo -e "    SEQ-1 waiting..."
        echo -e "    SEQ-2 waiting..."
        echo -e "  ${GREEN}► SEQ-3 is ACTIVE (submitting batches)${NC}"
    fi
}

show_status

# ============================================================
echo ""
echo -e "${CYAN}[5/6] Demonstrating Sequencer Rotation${NC}"
echo "────────────────────────────────────────────────────────────────"

echo -e "\n${YELLOW}>>> Rotation 1: Waiting for epoch...${NC}"
sleep 2
advance_time $EPOCH_DURATION
cast send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY > /dev/null 2>&1
echo -e "${GREEN}>>> Rotation complete!${NC}"
show_status
sleep 3

echo -e "\n${YELLOW}>>> Rotation 2: Waiting for epoch...${NC}"
sleep 2
advance_time $EPOCH_DURATION
cast send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY > /dev/null 2>&1
echo -e "${GREEN}>>> Rotation complete!${NC}"
show_status
sleep 3

echo -e "\n${YELLOW}>>> Rotation 3: Back to first sequencer...${NC}"
sleep 2
advance_time $EPOCH_DURATION
cast send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY > /dev/null 2>&1
echo -e "${GREEN}>>> Rotation complete!${NC}"
show_status

# ============================================================
echo ""
echo -e "${CYAN}[6/6] Challenge and Remove Misbehaving Sequencer${NC}"
echo "────────────────────────────────────────────────────────────────"

echo -e "\n${RED}>>> SEQ-2 detected extracting MEV! Challenging...${NC}"
sleep 1

ITEM_ID=$(cast call $MANAGER "itemIDFor(address)(bytes32)" $SEQUENCER_2 --rpc-url $RPC_URL)
cast send $CURATE "setClearingRequested(bytes32)" $ITEM_ID --rpc-url $RPC_URL --private-key $DEPLOYER_KEY > /dev/null 2>&1
echo -e "  Challenge submitted to arbitrator TCR (default: Kleros)"

cast send $MANAGER "syncRemoveSequencer(address)" $SEQUENCER_2 --rpc-url $RPC_URL --private-key $DEPLOYER_KEY > /dev/null 2>&1
echo -e "  ${RED}SEQ-2 removed from active set${NC}"

show_status

echo -e "\n${YELLOW}>>> Rotating after removal...${NC}"
advance_time $EPOCH_DURATION
cast send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY > /dev/null 2>&1
echo -e "${GREEN}>>> Rotation skips removed SEQ-2${NC}"
show_status

# ============================================================
echo ""
echo -e "${MAGENTA}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                 INTEGRATION TEST COMPLETE                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo "Summary:"
echo "  • L1 contracts deployed and configured"
echo "  • 3 batchers started, competing for sequencer role"
echo "  • L2 blocks produced and batched"
echo "  • Sequencer rotation demonstrated (3 rotations)"
echo "  • Misbehaving sequencer challenged and removed"
echo ""
echo "Log files available at: $LOG_DIR/"
echo ""
echo -e "${YELLOW}Press Enter to stop the integration test and cleanup...${NC}"
read

echo "Stopping..."
