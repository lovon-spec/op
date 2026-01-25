#!/bin/bash
#
# Generate OP Stack L2 configuration files
# This script creates rollup.json and jwt.txt based on deployed L1 contracts
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"

# L1 Configuration
L1_RPC="${L1_RPC:-http://l1:8545}"
L1_CHAIN_ID="${L1_CHAIN_ID:-31337}"

# L2 Configuration
L2_CHAIN_ID="${L2_CHAIN_ID:-42069}"
L2_BLOCK_TIME="${L2_BLOCK_TIME:-2}"

# Contract addresses (these should be set by the deployer)
SYSTEM_CONFIG="${SYSTEM_CONFIG:-}"
OPTIMISM_PORTAL="${OPTIMISM_PORTAL:-}"
L2_OUTPUT_ORACLE="${L2_OUTPUT_ORACLE:-}"

# Batch inbox address (standard format)
BATCH_INBOX="0xff00000000000000000000000000000000042069"

# Generate JWT secret if not exists
JWT_FILE="$OUTPUT_DIR/jwt.txt"
if [ ! -f "$JWT_FILE" ]; then
    echo "Generating JWT secret..."
    openssl rand -hex 32 > "$JWT_FILE"
    echo "JWT secret written to $JWT_FILE"
fi
JWT_SECRET=$(cat "$JWT_FILE")

# Get current L1 block info
echo "Fetching L1 block info from $L1_RPC..."

# Try to get block info, with retries
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    L1_BLOCK=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
        "$L1_RPC" 2>/dev/null | grep -o '"number":"0x[0-9a-fA-F]*"' | head -1 | cut -d'"' -f4)

    if [ -n "$L1_BLOCK" ]; then
        break
    fi

    echo "Waiting for L1 RPC..."
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ -z "$L1_BLOCK" ]; then
    echo "Error: Could not connect to L1 RPC"
    exit 1
fi

# Get block details
BLOCK_INFO=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$L1_BLOCK\",false],\"id\":1}" \
    "$L1_RPC")

L1_BLOCK_HASH=$(echo "$BLOCK_INFO" | grep -o '"hash":"0x[0-9a-fA-F]*"' | head -1 | cut -d'"' -f4)
L1_BLOCK_TIME=$(echo "$BLOCK_INFO" | grep -o '"timestamp":"0x[0-9a-fA-F]*"' | head -1 | cut -d'"' -f4)

# Convert hex to decimal
L1_BLOCK_NUM=$((L1_BLOCK))
L1_TIMESTAMP=$((L1_BLOCK_TIME))

echo "L1 Block: $L1_BLOCK_NUM"
echo "L1 Hash: $L1_BLOCK_HASH"
echo "L1 Timestamp: $L1_TIMESTAMP"

# Create rollup.json
ROLLUP_FILE="$OUTPUT_DIR/rollup.json"
echo "Generating rollup config..."

cat > "$ROLLUP_FILE" << EOF
{
  "genesis": {
    "l1": {
      "hash": "$L1_BLOCK_HASH",
      "number": $L1_BLOCK_NUM
    },
    "l2": {
      "hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
      "number": 0
    },
    "l2_time": $L1_TIMESTAMP,
    "system_config": {
      "batcherAddr": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      "overhead": "0x0000000000000000000000000000000000000000000000000000000000000834",
      "scalar": "0x00000000000000000000000000000000000000000000000000000000000f4240",
      "gasLimit": 30000000
    }
  },
  "block_time": $L2_BLOCK_TIME,
  "max_sequencer_drift": 600,
  "seq_window_size": 3600,
  "channel_timeout": 300,
  "l1_chain_id": $L1_CHAIN_ID,
  "l2_chain_id": $L2_CHAIN_ID,
  "regolith_time": 0,
  "canyon_time": 0,
  "delta_time": 0,
  "ecotone_time": 0,
  "fjord_time": 0,
  "batch_inbox_address": "$BATCH_INBOX",
  "deposit_contract_address": "${OPTIMISM_PORTAL:-0x0000000000000000000000000000000000000000}",
  "l1_system_config_address": "${SYSTEM_CONFIG:-0x0000000000000000000000000000000000000000}",
  "protocol_versions_address": "0x0000000000000000000000000000000000000000"
}
EOF

echo "Rollup config written to $ROLLUP_FILE"

# Copy genesis if needed
if [ ! -f "$OUTPUT_DIR/genesis-l2.json" ]; then
    cp "$SCRIPT_DIR/genesis-l2.json" "$OUTPUT_DIR/genesis-l2.json"
    echo "Genesis copied to $OUTPUT_DIR/genesis-l2.json"
fi

echo ""
echo "=== Configuration Complete ==="
echo "  JWT Secret: $JWT_FILE"
echo "  Rollup Config: $ROLLUP_FILE"
echo "  L2 Genesis: $OUTPUT_DIR/genesis-l2.json"
echo ""
