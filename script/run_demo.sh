#!/bin/bash
# Kleros Sequencer Manager Live Demo
# This script demonstrates the full sequencer rotation lifecycle on Anvil

set -e

FOUNDRY_BIN="$HOME/.foundry/bin"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
CAST="$FOUNDRY_BIN/cast"
FORGE="$FOUNDRY_BIN/forge"

# Use Anvil time manipulation if available (much faster than sleep)
advance_time() {
    local seconds=$1
    # Try Anvil's evm_increaseTime, fall back to sleep
    if curl -s -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"evm_increaseTime\",\"params\":[$seconds],\"id\":1}" -H "Content-Type: application/json" "$RPC_URL" > /dev/null 2>&1; then
        # Also mine a block to commit the time change
        curl -s -X POST --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id":1}' -H "Content-Type: application/json" "$RPC_URL" > /dev/null 2>&1
        echo "  (Advanced time by $seconds seconds via Anvil RPC)"
    else
        echo "  (Waiting $seconds seconds...)"
        sleep $seconds
    fi
}

# Anvil test accounts
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
GUARDIAN_KEY="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
CHALLENGER_KEY="0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"

SEQUENCER_1="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SEQUENCER_2="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
SEQUENCER_3="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
GUARDIAN="0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"

EPOCH_DURATION=10

echo ""
echo "==========================================="
echo "  KLEROS SEQUENCER MANAGER LIVE DEMO"
echo "==========================================="
echo ""

# Step 1: Deploy contracts using DeployLocal script
echo "STEP 1: Deploying contracts..."
echo "-------------------------------------------"
$FORGE script script/DeployLocal.s.sol:DeployLocal --rpc-url $RPC_URL --broadcast 2>&1 | grep -E "(deployed|transferred|Registered)"

# Get deployed contract addresses from the broadcast using Python
get_contract_address() {
    local name=$1
    python3 -c "
import json
with open('broadcast/DeployLocal.s.sol/31337/run-latest.json') as f:
    data = json.load(f)
    for tx in data.get('transactions', []):
        if tx.get('transactionType') == 'CREATE' and tx.get('contractName') == '$name':
            print(tx.get('contractAddress'))
            break
"
}

CURATE=$(get_contract_address "MockCurate")
SYSTEM_CONFIG=$(get_contract_address "MockSystemConfig")
MANAGER=$(get_contract_address "KlerosSequencerManager")

echo ""
echo "  MockCurate: $CURATE"
echo "  MockSystemConfig: $SYSTEM_CONFIG"
echo "  KlerosSequencerManager: $MANAGER"
echo ""

# Step 2: Check current state
echo "STEP 2: Checking initial state..."
echo "-------------------------------------------"
CURRENT_SEQ=$($CAST call $MANAGER "currentSequencer()(address)" --rpc-url $RPC_URL)
BATCHER_HASH=$($CAST call $SYSTEM_CONFIG "batcherHash()(bytes32)" --rpc-url $RPC_URL)
ACTIVE_COUNT=$($CAST call $MANAGER "activeSequencerCount()(uint256)" --rpc-url $RPC_URL)

echo "  Current sequencer: $CURRENT_SEQ"
echo "  Batcher hash: $BATCHER_HASH"
echo "  Active sequencers: $ACTIVE_COUNT"
echo ""

# Step 3: Wait for epoch and rotate
echo "STEP 3: Waiting for epoch ($EPOCH_DURATION seconds) and rotating..."
echo "-------------------------------------------"
advance_time $EPOCH_DURATION

echo "  Sending rotateSequencer() transaction..."
$CAST send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY 2>&1 | grep -E "(transactionHash|status)"

CURRENT_SEQ=$($CAST call $MANAGER "currentSequencer()(address)" --rpc-url $RPC_URL)
BATCHER_HASH=$($CAST call $SYSTEM_CONFIG "batcherHash()(bytes32)" --rpc-url $RPC_URL)
echo "  New current sequencer: $CURRENT_SEQ"
echo "  New batcher hash: $BATCHER_HASH"
echo ""

# Step 4: Rotate again
echo "STEP 4: Another rotation after $EPOCH_DURATION seconds..."
echo "-------------------------------------------"
advance_time $EPOCH_DURATION

$CAST send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY 2>&1 | grep -E "(transactionHash|status)"

CURRENT_SEQ=$($CAST call $MANAGER "currentSequencer()(address)" --rpc-url $RPC_URL)
echo "  New current sequencer: $CURRENT_SEQ"
echo ""

# Step 5: Challenge a sequencer
echo "STEP 5: Challenging SEQUENCER_2 for misbehavior..."
echo "-------------------------------------------"

# Get the itemID for SEQUENCER_2
ITEM_ID=$($CAST call $MANAGER "itemIDFor(address)(bytes32)" $SEQUENCER_2 --rpc-url $RPC_URL)
echo "  SEQUENCER_2 itemID: $ITEM_ID"

# Set clearing requested in Curate (simulate challenge)
$CAST send $CURATE "setClearingRequested(bytes32)" $ITEM_ID --rpc-url $RPC_URL --private-key $CHALLENGER_KEY 2>&1 | grep -E "(transactionHash|status)"
echo "  Challenge submitted (ClearingRequested)"

# Remove from manager
$CAST send $MANAGER "syncRemoveSequencer(address)" $SEQUENCER_2 --rpc-url $RPC_URL --private-key $CHALLENGER_KEY 2>&1 | grep -E "(transactionHash|status)"
echo "  SEQUENCER_2 removed from active set"

ACTIVE_COUNT=$($CAST call $MANAGER "activeSequencerCount()(uint256)" --rpc-url $RPC_URL)
echo "  Active sequencers now: $ACTIVE_COUNT"
echo ""

# Step 6: Rotate after removal
echo "STEP 6: Rotation after challenge (skips removed sequencer)..."
echo "-------------------------------------------"
advance_time $EPOCH_DURATION

$CAST send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY 2>&1 | grep -E "(transactionHash|status)"

CURRENT_SEQ=$($CAST call $MANAGER "currentSequencer()(address)" --rpc-url $RPC_URL)
echo "  Current sequencer: $CURRENT_SEQ"
echo "  (After swap-pop removal, rotation continues round-robin through remaining sequencers)"
echo ""

# Step 7: Guardian pause
echo "STEP 7: Guardian pause demonstration..."
echo "-------------------------------------------"

$CAST send $MANAGER "setPaused(bool)" true --rpc-url $RPC_URL --private-key $GUARDIAN_KEY 2>&1 | grep -E "(transactionHash|status)"
echo "  Contract paused by guardian"

# Try to rotate (should fail)
echo "  Attempting rotation while paused..."
if $CAST send $MANAGER "rotateSequencer()" --rpc-url $RPC_URL --private-key $DEPLOYER_KEY 2>&1; then
    echo "  ERROR: Should have reverted!"
else
    echo "  Correctly reverted with ContractPaused"
fi

# Unpause
$CAST send $MANAGER "setPaused(bool)" false --rpc-url $RPC_URL --private-key $GUARDIAN_KEY 2>&1 | grep -E "(transactionHash|status)"
echo "  Contract unpaused"
echo ""

echo "==========================================="
echo "  LIVE DEMO COMPLETE!"
echo "==========================================="
echo ""
echo "Summary:"
echo "  - Deployed and configured KlerosSequencerManager"
echo "  - Registered 3 sequencers via Curate registry"
echo "  - Demonstrated epoch-based rotation"
echo "  - Challenged and removed a misbehaving sequencer"
echo "  - Showed guardian pause/unpause functionality"
echo ""
echo "Contract Addresses:"
echo "  MockCurate: $CURATE"
echo "  MockSystemConfig: $SYSTEM_CONFIG"
echo "  KlerosSequencerManager: $MANAGER"
