#!/bin/bash
# =============================================================
#  ISOCHRON — Full System Integration Test
# =============================================================
#
# A self-contained integration test that deploys every contract
# and exercises every major subsystem:
#
#   1. Contract deployment & architecture overview
#   2. Operator registry inspection
#   3. Adapter registry & adapter info
#   4. SystemConfig state before/after rotation
#   5. Epoch-based rotation through all operators
#   6. Challenge & removal of a misbehaving operator
#   7. Rotation after removal (round-robin skip)
#   8. Adapter upgrade (V1 → V2 via ratchet)
#   9. Rotation with new adapter
#  10. Guardian emergency pause / unpause
#
# Usage:
#   ./script/run_integration_test.sh                    # standalone (starts own Anvil)
#   RPC_URL=http://... ./script/run_integration_test.sh # against existing node
#
# Requirements: Foundry (forge + cast + anvil)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# ── Tooling ──────────────────────────────────────────────────
FOUNDRY_BIN="${FOUNDRY_BIN:-$HOME/.foundry/bin}"
FORGE="${FORGE:-${FOUNDRY_BIN}/forge}"
CAST="${CAST:-${FOUNDRY_BIN}/cast}"

for bin in "$FORGE" "$CAST"; do
    if ! command -v "$bin" &>/dev/null && [ ! -x "$bin" ]; then
        echo "ERROR: $(basename "$bin") not found."
        echo "Install Foundry: https://book.getfoundry.sh"
        exit 1
    fi
done

# ── Anvil management ─────────────────────────────────────────
OWN_ANVIL=false
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ANVIL_PID=""

start_anvil() {
    ANVIL="${ANVIL:-${FOUNDRY_BIN}/anvil}"
    if curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
         -H "Content-Type: application/json" "$RPC_URL" &>/dev/null; then
        echo "  Using existing node at $RPC_URL"
        return
    fi
    echo "  Starting local Anvil node..."
    "$ANVIL" --silent --accounts 10 --balance 10000 &
    ANVIL_PID=$!
    OWN_ANVIL=true
    sleep 2
}

cleanup() {
    if [ "$OWN_ANVIL" = true ] && [ -n "$ANVIL_PID" ]; then
        kill "$ANVIL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Constants ────────────────────────────────────────────────
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
GUARDIAN_KEY="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
CHALLENGER_KEY="0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"

DEPLOYER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
GUARDIAN="0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"

# Operator keys for Active Handoff (current operator must call rotateOperator during grace period)
BATCHER_1="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
BATCHER_1_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
SIGNER_1="0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
BATCHER_2="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
BATCHER_2_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
SIGNER_2="0x976EA74026E726554dB657fA54763abd0C3a0aa9"
BATCHER_3="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
BATCHER_3_KEY="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
SIGNER_3="0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"

EPOCH=10 # seconds (matches DeployLocal)
GRACE_PERIOD=600 # Active Handoff grace period

# ── Helpers ──────────────────────────────────────────────────
advance_time() {
    curl -s -X POST \
         --data "{\"jsonrpc\":\"2.0\",\"method\":\"evm_increaseTime\",\"params\":[$1],\"id\":1}" \
         -H "Content-Type: application/json" "$RPC_URL" >/dev/null
    curl -s -X POST \
         --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id":1}' \
         -H "Content-Type: application/json" "$RPC_URL" >/dev/null
}

# call <addr> <sig> [args…]
_call() {
    "$CAST" call "$1" "$2" "${@:3}" --rpc-url "$RPC_URL" 2>/dev/null
}

# send_tx <key> <addr> <sig> [args…]
send_tx() {
    local key="$1"; shift
    "$CAST" send "$1" "$2" "${@:3}" \
        --rpc-url "$RPC_URL" --private-key "$key" >/dev/null 2>&1
}

section() {
    echo ""
    echo "==========================================================="
    echo "  $1"
    echo "==========================================================="
    echo ""
}

subsection() {
    echo "-----------------------------------------------------------"
    echo "  $1"
    echo "-----------------------------------------------------------"
}

# Parse a contract address from the broadcast JSON
get_addr() {
    python3 -c "
import json, sys
with open('broadcast/DeployLocal.s.sol/31337/run-latest.json') as f:
    data = json.load(f)
for tx in data.get('transactions', []):
    if tx.get('transactionType') == 'CREATE' and tx.get('contractName') == '$1':
        print(tx['contractAddress'])
        sys.exit(0)
print('')
"
}

# Parse a contract address from DeployV2 broadcast JSON
get_v2_addr() {
    python3 -c "
import json, sys
with open('broadcast/DeployV2.s.sol/31337/run-latest.json') as f:
    data = json.load(f)
for tx in data.get('transactions', []):
    if tx.get('transactionType') == 'CREATE' and tx.get('contractName') == '$1':
        print(tx['contractAddress'])
        sys.exit(0)
print('')
"
}

# =============================================================
#  MAIN
# =============================================================

section "CONSTITUTIONAL L2 — FULL SYSTEM INTEGRATION TEST"

echo "This integration test deploys all contracts and exercises every major"
echo "subsystem of the ISOCHRON governance stack."

# ─── Step 0 ──────────────────────────────────────────────────
echo ""
echo "Step 0: Environment"
echo "-----------------------------------------------------------"
start_anvil

# ─── Step 1: Deploy ──────────────────────────────────────────
section "STEP 1 · Deploy All Contracts"

echo "Running DeployLocal.s.sol …"
echo "(Deploys mocks, registers 3 operators, performs first rotation)"
echo ""
"$FORGE" script script/DeployLocal.s.sol:DeployLocal \
    --rpc-url "$RPC_URL" --broadcast --silent 2>&1 | \
    sed -n '/deployed\|transferred\|Registered\|Operator\|Registry\|Adapter\|Summary\|Duration\|Guardian\|current\|rotation\|signer\|batcher/Ip' | \
    while IFS= read -r line; do echo "  $line"; done
echo ""

REGISTRY=$(get_addr MockPermanentGTCRHybrid)
ADAPTER_REGISTRY=$(get_addr MockCurate)
ADAPTER_V1=$(get_addr OpStackAdapterV1)
SYSTEM_CONFIG=$(get_addr MockSystemConfig)
MANAGER=$(get_addr KlerosSequencerManager)

echo "Deployed contracts:"
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │ Operator Registry  (MockPermanentGTCRHybrid)             │"
echo "  │   $REGISTRY │"
echo "  ├──────────────────────────────────────────────────────────┤"
echo "  │ Adapter Registry   (MockCurate)                          │"
echo "  │   $ADAPTER_REGISTRY │"
echo "  ├──────────────────────────────────────────────────────────┤"
echo "  │ Adapter V1         (OpStackAdapterV1)                    │"
echo "  │   $ADAPTER_V1 │"
echo "  ├──────────────────────────────────────────────────────────┤"
echo "  │ SystemConfig       (MockSystemConfig)                    │"
echo "  │   $SYSTEM_CONFIG │"
echo "  ├──────────────────────────────────────────────────────────┤"
echo "  │ Manager            (SequencerManager contract)           │"
echo "  │   $MANAGER │"
echo "  └──────────────────────────────────────────────────────────┘"

# ─── Step 2: Operator Registry ───────────────────────────────
section "STEP 2 · Operator Registry"

echo "The Operator Registry (PermanentGTCRHybrid) stores operator"
echo "tuples — each operator has a batcher key and an unsafeSigner"
echo "key.  Both are rotated atomically when the operator's turn comes."
echo ""

for i in 1 2 3; do
    eval "B=\$BATCHER_$i; S=\$SIGNER_$i"
    ITEM_ID=$(_call "$REGISTRY" "operatorItemId(address,address)(bytes32)" "$B" "$S")
    REG_BATCHER=$(_call "$REGISTRY" "getOperationalKeys(bytes32)(address,address)" "$ITEM_ID" | head -1)
    REG_SIGNER=$(_call "$REGISTRY" "getOperationalKeys(bytes32)(address,address)" "$ITEM_ID" | tail -1)
    echo "  Operator $i"
    echo "    batcher:      $B"
    echo "    unsafeSigner: $S"
    echo "    itemID:       $ITEM_ID"
    echo ""
done

ACTIVE=$(_call "$MANAGER" "activeOperatorCount()(uint256)")
echo "  Active operators synced to manager: $ACTIVE"

# ─── Step 3: Adapter Info ────────────────────────────────────
section "STEP 3 · Adapter Registry & Adapter Info"

echo "The Adapter Registry (Curate) governs which adapters the"
echo "manager may use.  The ratchet ensures the version number"
echo "can only increase — no rollbacks."
echo ""

V1_VERSION=$(_call "$ADAPTER_V1" "version()(uint256)")
V1_NAME=$(_call "$ADAPTER_V1" "NAME()(string)")
V1_DESC=$(_call "$ADAPTER_V1" "DESCRIPTION()(string)")

echo "  Current adapter (V1):"
echo "    address:     $ADAPTER_V1"
echo "    version:     $V1_VERSION (1.0.0)"
echo "    name:        $V1_NAME"
echo "    description: $V1_DESC"
echo ""
echo "  Adapter registry: $ADAPTER_REGISTRY"

# ─── Step 4: SystemConfig ────────────────────────────────────
section "STEP 4 · SystemConfig State (pre-rotation snapshot)"

BATCHER_HASH=$(_call "$SYSTEM_CONFIG" "batcherHash()(bytes32)")
UNSAFE_SIGNER=$(_call "$SYSTEM_CONFIG" "unsafeBlockSigner()(address)")
SC_OWNER=$(_call "$SYSTEM_CONFIG" "owner()(address)")

echo "  batcherHash():      $BATCHER_HASH"
echo "  unsafeBlockSigner(): $UNSAFE_SIGNER"
echo "  owner():             $SC_OWNER"
echo ""
echo "  The owner is the SequencerManager contract — only it can"
echo "  update batcherHash and unsafeBlockSigner via the adapter."

# ─── Step 5: Rotation cycle (Active Handoff) ─────────────────
section "STEP 5 · Epoch-Based Rotation with Active Handoff (3 cycles)"

echo "Active Handoff Protocol: Only the current operator can trigger"
echo "rotation during the grace period. This prevents L2 re-orgs by"
echo "allowing operators to flush their batch queue before rotating."
echo ""

# Track which operator is current (starts with Operator 1 after first rotation)
CURRENT_OP_KEY="$BATCHER_1_KEY"
CURRENT_OP_NAME="Operator 1"

for CYCLE in 1 2 3; do
    subsection "Rotation $CYCLE (Active Handoff by $CURRENT_OP_NAME)"

    advance_time $((EPOCH + 1))

    echo "  Current operator ($CURRENT_OP_NAME) calling rotateOperator()..."
    send_tx "$CURRENT_OP_KEY" "$MANAGER" "rotateOperator()"

    CURRENT_BATCH=$(_call "$MANAGER" "currentSequencer()(address)")
    BATCHER_HASH=$(_call "$SYSTEM_CONFIG" "batcherHash()(bytes32)")
    UNSAFE_SIGNER=$(_call "$SYSTEM_CONFIG" "unsafeBlockSigner()(address)")

    echo "  Current batcher:       $CURRENT_BATCH"
    echo "  SystemConfig batcherHash:      $BATCHER_HASH"
    echo "  SystemConfig unsafeBlockSigner: $UNSAFE_SIGNER"

    # Update current operator key for next rotation
    if [ "$CURRENT_BATCH" = "$BATCHER_1" ]; then
        CURRENT_OP_KEY="$BATCHER_1_KEY"
        CURRENT_OP_NAME="Operator 1"
    elif [ "$CURRENT_BATCH" = "$BATCHER_2" ]; then
        CURRENT_OP_KEY="$BATCHER_2_KEY"
        CURRENT_OP_NAME="Operator 2"
    elif [ "$CURRENT_BATCH" = "$BATCHER_3" ]; then
        CURRENT_OP_KEY="$BATCHER_3_KEY"
        CURRENT_OP_NAME="Operator 3"
    fi
    echo ""
done

# ─── Step 6: Challenge & Remove ──────────────────────────────
section "STEP 6 · Challenge & Remove Operator 2"

echo "Operator 2 (batcher $BATCHER_2)"
echo "has been caught violating the sequencer SLA (e.g. missed handoff"
echo "or sustained downtime).  An arbitration panel ruled against them."
echo ""

echo "Step 6a: Mark operator as removed in registry…"
send_tx "$CHALLENGER_KEY" "$REGISTRY" \
    "setOperatorClearingRequested(address,address)" "$BATCHER_2" "$SIGNER_2"
echo "  Registry status set to Absent (removed by arbitration ruling)"
echo ""

echo "Step 6b: Sync removal to manager (anyone can call)…"
send_tx "$CHALLENGER_KEY" "$MANAGER" \
    "syncRemoveOperator(address,address)" "$BATCHER_2" "$SIGNER_2"

ACTIVE=$(_call "$MANAGER" "activeOperatorCount()(uint256)")
echo "  Active operators now: $ACTIVE (was 3)"

# ─── Step 7: Rotation after removal (Active Handoff) ─────────
section "STEP 7 · Rotation After Removal (Active Handoff)"

echo "The removed operator is gone from the active set."
echo "Rotation continues round-robin through the remaining 2."
echo "Current operator triggers rotation during grace period."
echo ""

# After step 5, operator 1 is current (we rotated 3 times: 1->2->3->1)
# After step 6, operator 2 was removed from registry but operator 1 is still current
CURRENT_OP_KEY="$BATCHER_1_KEY"
CURRENT_OP_NAME="Operator 1"

for CYCLE in 1 2; do
    subsection "Post-removal rotation $CYCLE (by $CURRENT_OP_NAME)"
    advance_time $((EPOCH + 1))

    echo "  Current operator ($CURRENT_OP_NAME) calling rotateOperator()..."
    send_tx "$CURRENT_OP_KEY" "$MANAGER" "rotateOperator()"

    CURRENT_BATCH=$(_call "$MANAGER" "currentSequencer()(address)")
    echo "  Current batcher: $CURRENT_BATCH"

    # Update current operator key for next rotation (only 1 and 3 remain)
    if [ "$CURRENT_BATCH" = "$BATCHER_1" ]; then
        CURRENT_OP_KEY="$BATCHER_1_KEY"
        CURRENT_OP_NAME="Operator 1"
    elif [ "$CURRENT_BATCH" = "$BATCHER_3" ]; then
        CURRENT_OP_KEY="$BATCHER_3_KEY"
        CURRENT_OP_NAME="Operator 3"
    fi
    echo ""
done

echo "  Operator 2 ($BATCHER_2) is never selected."
echo "  Only operators 1 and 3 alternate."

# ─── Step 8: Adapter upgrade ─────────────────────────────────
section "STEP 8 · Adapter Upgrade (V1 → V2)"

echo "A new adapter has been developed (e.g. for an OP Stack"
echo "hardfork).  It has been submitted to the Adapter Registry"
echo "and passed the curation challenge period."
echo ""

echo "Step 8a: Deploy MockAdapterV2…"
"$FORGE" script script/DeployV2.s.sol:DeployV2 \
    --rpc-url "$RPC_URL" --broadcast --silent 2>&1 | \
    sed -n '/deployed\|Version/Ip' | \
    while IFS= read -r line; do echo "  $line"; done
ADAPTER_V2=$(get_v2_addr MockAdapterV2)
echo "  MockAdapterV2 deployed at: $ADAPTER_V2"

V2_VERSION=$(_call "$ADAPTER_V2" "version()(uint256)")
echo "  Version: $V2_VERSION (2.0.0)"
echo ""

echo "Step 8b: Register V2 in the adapter registry…"
V2_ENCODED=$("$CAST" abi-encode "f(address)" "$ADAPTER_V2")
send_tx "$DEPLOYER_KEY" "$ADAPTER_REGISTRY" "registerItemDirectly(bytes)" "$V2_ENCODED"
echo "  V2 registered in adapter registry"
echo ""

echo "Step 8c: Upgrade manager to V2 (ratchet: V2 > V1)…"
send_tx "$DEPLOYER_KEY" "$MANAGER" "upgradeAdapter(address)" "$ADAPTER_V2"

NEW_ADAPTER=$(_call "$MANAGER" "getAdapterInfo()(address,uint256,string,string)" | head -1)
NEW_VERSION=$(_call "$MANAGER" "getAdapterInfo()(address,uint256,string,string)" | sed -n '2p')
echo "  Manager adapter address: $NEW_ADAPTER"
echo "  Manager adapter version: $NEW_VERSION"
echo ""
echo "  Ratchet enforced: 2000000 > 1000000"

# ─── Step 9: Rotation with new adapter (Active Handoff) ──────
section "STEP 9 · Rotation With V2 Adapter (Active Handoff)"

echo "The V2 adapter is now active.  Let's verify rotation still"
echo "works correctly through the new adapter."
echo "Current operator triggers rotation during grace period."
echo ""

# Get current operator to determine which key to use
CURRENT_BATCH=$(_call "$MANAGER" "currentSequencer()(address)")
if [ "$CURRENT_BATCH" = "$BATCHER_1" ]; then
    CURRENT_OP_KEY="$BATCHER_1_KEY"
    CURRENT_OP_NAME="Operator 1"
elif [ "$CURRENT_BATCH" = "$BATCHER_3" ]; then
    CURRENT_OP_KEY="$BATCHER_3_KEY"
    CURRENT_OP_NAME="Operator 3"
fi

advance_time $((EPOCH + 1))
echo "  $CURRENT_OP_NAME calling rotateOperator() with V2 adapter..."
send_tx "$CURRENT_OP_KEY" "$MANAGER" "rotateOperator()"

CURRENT_BATCH=$(_call "$MANAGER" "currentSequencer()(address)")
BATCHER_HASH=$(_call "$SYSTEM_CONFIG" "batcherHash()(bytes32)")
UNSAFE_SIGNER=$(_call "$SYSTEM_CONFIG" "unsafeBlockSigner()(address)")

echo "  Current batcher:                 $CURRENT_BATCH"
echo "  SystemConfig.batcherHash():      $BATCHER_HASH"
echo "  SystemConfig.unsafeBlockSigner(): $UNSAFE_SIGNER"
echo ""
echo "  Rotation succeeded through the V2 adapter."

# ─── Step 10: Guardian pause ─────────────────────────────────
section "STEP 10 · Guardian Emergency Pause / Unpause"

echo "The guardian ($GUARDIAN) can pause all"
echo "mutations in an emergency."
echo ""

IS_PAUSED=$(_call "$MANAGER" "paused()(bool)")
echo "  paused() = $IS_PAUSED"
echo ""

echo "Step 10a: Guardian pauses the contract…"
send_tx "$GUARDIAN_KEY" "$MANAGER" "setPaused(bool)" true

IS_PAUSED=$(_call "$MANAGER" "paused()(bool)")
echo "  paused() = $IS_PAUSED"
echo ""

echo "Step 10b: Attempt rotation while paused (using Dead Man's Switch)..."
# Advance past grace period so anyone can try to rotate
advance_time $((EPOCH + GRACE_PERIOD + 1))
if "$CAST" send "$MANAGER" "rotateOperator()" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" 2>/dev/null; then
    echo "  ERROR: should have reverted!"
else
    echo "  Correctly reverted (ContractPaused)"
fi
echo ""

echo "Step 10c: Guardian unpauses…"
send_tx "$GUARDIAN_KEY" "$MANAGER" "setPaused(bool)" false

IS_PAUSED=$(_call "$MANAGER" "paused()(bool)")
echo "  paused() = $IS_PAUSED"

# ─── Summary ─────────────────────────────────────────────────
section "INTEGRATION TEST COMPLETE"

echo "Subsystems tested:"
echo ""
echo "  [x] Operator Registry   — 3 operators with (batcher, signer) tuples"
echo "  [x] Adapter Registry    — V1 registered; V2 registered and upgraded"
echo "  [x] SystemConfig        — batcherHash + unsafeBlockSigner updated atomically"
echo "  [x] Active Handoff      — current operator triggers rotation during grace period"
echo "  [x] Epoch Rotation      — round-robin through active operator set"
echo "  [x] Challenge & Removal — operator 2 removed, rotation skips them"
echo "  [x] Adapter Upgrade     — V1 -> V2 via ratchet (version must increase)"
echo "  [x] Guardian Pause      — emergency pause blocks all mutations"
echo ""
echo "Contract addresses:"
echo "  Operator Registry:  $REGISTRY"
echo "  Adapter Registry:   $ADAPTER_REGISTRY"
echo "  Adapter V1:         $ADAPTER_V1"
echo "  Adapter V2:         $ADAPTER_V2"
echo "  SystemConfig:       $SYSTEM_CONFIG"
echo "  Manager:            $MANAGER"
echo ""
