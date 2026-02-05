#!/bin/bash
#
# ISOCHRON - Quick Start Script
#
# Usage:
#   ./start.sh              # Start local devnet (L1 only, mocks, no internet needed)
#   ./start.sh local        # Same as above
#   ./start.sh l2           # Start full L2 stack (L1 + op-geth + op-node + op-batcher)
#   ./start.sh stop         # Stop all services
#   ./start.sh logs         # View logs
#   ./start.sh status       # Show status
#   ./start.sh test         # Run integration test
#   ./start.sh clean        # Clean all data and start fresh
#
# Remote deployments (no Docker, requires Foundry + funded wallet):
#   ./start.sh sepolia      # Deploy to Sepolia (requires .env.sepolia)
#   ./start.sh mainnet      # Deploy to Mainnet (requires .env.mainnet)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  ISOCHRON - OP Stack with arbitrator governance (default Kleros Court)${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

print_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Local Commands (Docker, offline-capable):"
    echo "  local     Start L1 devnet and deploy mock contracts (default)"
    echo "  l2        Start full L2 stack (includes op-geth, op-node, op-batcher)"
    echo "  stop      Stop all services"
    echo "  logs      View logs (follow mode)"
    echo "  status    Show current status"
    echo "  test      Run integration test (full system test)"
    echo "  clean     Clean all data and start fresh"
    echo ""
    echo "Remote Commands (no Docker, requires Foundry + RPC):"
    echo "  sepolia   Deploy to Sepolia testnet (requires .env.sepolia)"
    echo "  mainnet   Deploy to Ethereum mainnet (requires .env.mainnet)"
    echo ""
    echo "  help      Show this help message"
    echo ""
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed${NC}"
        echo "Please install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    if ! docker compose version &> /dev/null; then
        echo -e "${RED}Error: Docker Compose is not installed${NC}"
        exit 1
    fi
}

check_foundry() {
    if ! command -v forge &> /dev/null; then
        echo -e "${RED}Error: Foundry (forge) is not installed${NC}"
        echo "Please install Foundry: https://book.getfoundry.sh/getting-started/installation"
        exit 1
    fi
    if ! command -v cast &> /dev/null; then
        echo -e "${RED}Error: Foundry (cast) is not installed${NC}"
        echo "Please install Foundry: https://book.getfoundry.sh/getting-started/installation"
        exit 1
    fi
}

wait_for_deployment() {
    echo -n "Waiting for contract deployment"
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T deployer test -f /app/.deployments/addresses.json 2>/dev/null; then
            echo -e " ${GREEN}done${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo -e " ${RED}timeout${NC}"
    return 1
}

wait_for_l2_config() {
    echo -n "Waiting for L2 configuration"
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if [ -f "docker/config/rollup.json" ] && [ -f "docker/config/genesis-l2.json" ]; then
            echo -e " ${GREEN}done${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo -e " ${RED}timeout${NC}"
    return 1
}

wait_for_l2() {
    echo -n "Waiting for L2 to be ready"
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://localhost:9545 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null | grep -q "0xa455"; then
            echo -e " ${GREEN}done${NC}"
            return 0
        fi
        echo -n "."
        sleep 3
        attempt=$((attempt + 1))
    done

    echo -e " ${RED}timeout${NC}"
    return 1
}

get_address() {
    # Read address from individual .address file (no Python/jq needed)
    docker compose exec -T deployer cat /app/.deployments/"$1".address 2>/dev/null || echo ""
}

# =============================================================
# Local Commands (Docker-based, offline-capable)
# =============================================================

start_local() {
    print_header
    echo -e "${GREEN}Starting ISOCHRON local devnet (L1 only)...${NC}"
    echo ""

    # Start L1 and deployer
    echo "Starting L1 (Anvil) and deploying contracts..."
    docker compose up -d l1 deployer

    # Wait for deployment
    if ! wait_for_deployment; then
        echo -e "${RED}Deployment failed. Check logs with: ./start.sh logs${NC}"
        exit 1
    fi

    # Get addresses
    local MANAGER=$(get_address "KlerosSequencerManager")
    local CURATE=$(get_address "MockCurate")
    local SYSCONFIG=$(get_address "MockSystemConfig")

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  ISOCHRON - L1 is running!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo "Endpoints:"
    echo "  L1 RPC:     http://localhost:8545"
    echo ""
    echo "Contracts:"
    echo "  KlerosSequencerManager: $MANAGER"
    echo "  MockCurate:             $CURATE"
    echo "  MockSystemConfig:       $SYSCONFIG"
    echo ""
    echo "Test accounts (Anvil defaults):"
    echo "  Account 0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (deployer)"
    echo "  Account 1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (batcher 1)"
    echo "  Account 2: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC (batcher 2)"
    echo "  Account 3: 0x90F79bf6EB2c4f870365E785982E1f101E93b906 (batcher 3)"
    echo ""
    echo "Next steps:"
    echo "  ./start.sh l2       - Start full L2 stack"
    echo "  ./start.sh test     - Run integration test"
    echo "  ./start.sh status   - Check service status"
    echo "  ./start.sh logs     - View logs"
    echo "  ./start.sh stop     - Stop all services"
    echo ""
}

start_l2() {
    print_header
    echo -e "${GREEN}Starting ISOCHRON full stack...${NC}"
    echo ""

    # First make sure L1 is running and contracts are deployed
    echo "Step 1/3: Starting L1 and deploying contracts..."
    docker compose up -d l1 deployer

    if ! wait_for_deployment; then
        echo -e "${RED}Deployment failed. Check logs with: ./start.sh logs${NC}"
        exit 1
    fi

    # Wait for L2 config to be generated
    echo "Step 2/3: Waiting for L2 configuration..."
    if ! wait_for_l2_config; then
        echo -e "${RED}L2 config generation failed. Check logs with: ./start.sh logs${NC}"
        exit 1
    fi

    # Start L2 services
    echo "Step 3/3: Starting L2 services (op-geth, op-node, op-batcher)..."
    docker compose --profile l2 up -d

    # Wait for L2 to be ready
    if ! wait_for_l2; then
        echo -e "${YELLOW}L2 may still be starting. Check logs with: ./start.sh logs${NC}"
    fi

    # Get addresses
    local MANAGER=$(get_address "KlerosSequencerManager")
    local CURATE=$(get_address "MockCurate")
    local SYSCONFIG=$(get_address "MockSystemConfig")

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  ISOCHRON - Full Stack is running!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo "Endpoints:"
    echo "  L1 RPC:     http://localhost:8545  (Anvil, chain ID: 31337)"
    echo "  L2 RPC:     http://localhost:9545  (op-geth, chain ID: 42069)"
    echo "  L2 WS:      ws://localhost:9546"
    echo "  Rollup RPC: http://localhost:9547  (op-node)"
    echo ""
    echo "Governance Contracts (on L1):"
    echo "  KlerosSequencerManager: $MANAGER"
    echo "  MockCurate:             $CURATE"
    echo "  MockSystemConfig:       $SYSCONFIG"
    echo ""
    echo "L2 Services:"
    echo "  op-geth:    Execution layer (EVM)"
    echo "  op-node:    Consensus layer (derives blocks from L1)"
    echo "  op-batcher: Submits L2 batches to L1"
    echo ""
    echo "Try sending a transaction on L2:"
    echo "  cast send --rpc-url http://localhost:9545 \\"
    echo "    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \\"
    echo "    --value 0.1ether 0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    echo ""
    echo "Commands:"
    echo "  ./start.sh test     - Run integration test"
    echo "  ./start.sh status   - Check service status"
    echo "  ./start.sh logs     - View logs"
    echo "  ./start.sh stop     - Stop all services"
    echo ""
}

stop_services() {
    echo "Stopping all services..."
    docker compose --profile l2 down
    echo -e "${GREEN}All services stopped${NC}"
}

clean_all() {
    echo "Cleaning all data..."
    docker compose --profile l2 down -v
    rm -rf .deployments docker/config/*.json docker/config/jwt.txt
    echo -e "${GREEN}All data cleaned${NC}"
}

show_logs() {
    docker compose --profile l2 logs -f
}

show_status() {
    print_header

    echo "Service Status:"
    echo ""
    docker compose --profile l2 ps 2>/dev/null || echo "No services running"

    echo ""
    echo "Contract Addresses:"

    local MANAGER=$(get_address "KlerosSequencerManager")
    if [ -n "$MANAGER" ] && [ "$MANAGER" != "" ]; then
        echo "  KlerosSequencerManager: $MANAGER"
        echo "  MockCurate:             $(get_address 'MockCurate')"
        echo "  MockSystemConfig:       $(get_address 'MockSystemConfig')"

        echo ""
        echo "L1 State:"

        # Check if cast is available locally or in container
        if command -v cast &> /dev/null; then
            local L1_RPC="http://localhost:8545"
            local current_seq=$(cast call "$MANAGER" "currentSequencer()(address)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
            local active_count=$(cast call "$MANAGER" "activeSequencerCount()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
            local time_until=$(cast call "$MANAGER" "timeUntilNextRotation()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")

            echo "  Current Batcher:      $current_seq"
            echo "  Active Operators:     $active_count"
            echo "  Time Until Rotation:  ${time_until}s"
        else
            echo "  (install 'cast' from Foundry to view state)"
        fi

        # Check L2 status
        echo ""
        echo "L2 Status:"
        if curl -s http://localhost:9545 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | grep -q "result"; then
            local l2_block=$(curl -s http://localhost:9545 -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | \
                grep -o '"result":"0x[0-9a-fA-F]*"' | cut -d'"' -f4)
            local l2_block_dec=$((l2_block))
            echo -e "  L2 Chain:             ${GREEN}Running${NC} (block $l2_block_dec)"
        else
            echo -e "  L2 Chain:             ${YELLOW}Not running${NC}"
        fi
    else
        echo "  (contracts not yet deployed)"
    fi

    echo ""
}

run_test() {
    print_header
    echo -e "${CYAN}Running Full System Integration Test${NC}"
    echo ""
    echo "This runs a comprehensive, self-contained integration test that exercises"
    echo "every subsystem: operator registry, adapter registry, rotation,"
    echo "challenge/removal, adapter upgrade, and guardian pause."
    echo ""

    check_foundry

    # The integration test script is self-contained (starts its own Anvil if needed)
    exec bash script/run_integration_test.sh
}

# =============================================================
# Remote Deployment Commands (no Docker)
# =============================================================

deploy_remote() {
    local MODE="$1"        # "sepolia" or "mainnet"
    local ENV_FILE=".env.${MODE}"

    print_header
    check_foundry

    # Check for env file
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Error: ${ENV_FILE} not found${NC}"
        echo ""
        echo "Create it from the example:"
        echo "  cp ${ENV_FILE}.example ${ENV_FILE}"
        echo "  # Edit ${ENV_FILE} with your values"
        echo ""
        exit 1
    fi

    # Source the env file
    set -a
    source "$ENV_FILE"
    set +a

    # Validate required variables
    if [ -z "$RPC_URL" ]; then
        echo -e "${RED}Error: RPC_URL not set in ${ENV_FILE}${NC}"
        exit 1
    fi
    if [ -z "$ARBITRATOR_ADDRESS" ]; then
        echo -e "${RED}Error: ARBITRATOR_ADDRESS not set in ${ENV_FILE}${NC}"
        exit 1
    fi
    if [ -z "$WETH" ]; then
        echo -e "${RED}Error: WETH not set in ${ENV_FILE}${NC}"
        exit 1
    fi
    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}Error: PRIVATE_KEY not set in ${ENV_FILE}${NC}"
        exit 1
    fi

    echo -e "${GREEN}Deploying ISOCHRON to ${MODE}...${NC}"
    echo ""
    echo "Configuration:"
    echo "  RPC URL:      $RPC_URL"
    echo "  Arbitrator: $ARBITRATOR_ADDRESS"
    echo "  WETH:         $WETH"
    echo "  Production:   ${PRODUCTION:-false}"
    echo ""

    # Mainnet safety warning
    if [ "$MODE" = "mainnet" ]; then
        echo -e "${RED}================================================================${NC}"
        echo -e "${RED}  WARNING: MAINNET DEPLOYMENT - REAL VALUE AT STAKE!${NC}"
        echo -e "${RED}================================================================${NC}"
        echo ""
        echo "This will deploy contracts to Ethereum Mainnet."
        echo "Press Ctrl+C to cancel, or wait 10 seconds to continue..."
        sleep 10
    fi

    # Build first
    echo "Building contracts..."
    forge build

    # Build forge script command
    local FORGE_CMD="forge script script/DeployRemote.s.sol:DeployRemote"
    FORGE_CMD="$FORGE_CMD --rpc-url $RPC_URL"
    FORGE_CMD="$FORGE_CMD --broadcast"

    # Add verification if etherscan key is available
    if [ -n "$ETHERSCAN_API_KEY" ]; then
        FORGE_CMD="$FORGE_CMD --verify"
        echo "Contract verification enabled (Etherscan)"
    fi

    # Use --slow for mainnet to avoid rate limits
    if [ "$MODE" = "mainnet" ]; then
        FORGE_CMD="$FORGE_CMD --slow"
    fi

    echo ""
    echo "Running deployment..."
    echo "  $FORGE_CMD"
    echo ""

    # Execute deployment
    eval "$FORGE_CMD"

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  Deployment to ${MODE} complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo "Check the broadcast/ directory for deployment artifacts."
    echo ""

    if [ "$PRODUCTION" != "true" ]; then
        echo "Test mode: Operators were pre-registered in Phase 1."
        echo "To complete setup, run Phase 2 and Phase 3 manually."
        echo ""
    else
        echo "Production mode: Register operators through the arbitrator-backed registry (default Kleros Curate)."
        echo "See the deployment summary above for contract addresses."
        echo ""
    fi
}

# =============================================================
# Main
# =============================================================

case "${1:-local}" in
    local|start)
        check_docker
        start_local
        ;;
    l2|full)
        check_docker
        start_l2
        ;;
    stop)
        check_docker
        stop_services
        ;;
    clean)
        check_docker
        clean_all
        ;;
    logs)
        check_docker
        show_logs
        ;;
    status)
        check_docker
        show_status
        ;;
    test)
        check_docker
        run_test
        ;;
    # Remote deployment commands
    sepolia)
        deploy_remote sepolia
        ;;
    mainnet)
        deploy_remote mainnet
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        print_usage
        exit 1
        ;;
esac
