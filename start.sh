#!/bin/bash
#
# Constitutional L2 - Quick Start Script
#
# Usage:
#   ./start.sh              # Start local devnet (default)
#   ./start.sh local        # Start local devnet with Anvil L1
#   ./start.sh stop         # Stop all services
#   ./start.sh logs         # View logs
#   ./start.sh status       # Show status
#   ./start.sh demo         # Run rotation demo
#   ./start.sh clean        # Clean all data and start fresh
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
    echo -e "${CYAN}  Constitutional L2 - OP Stack with Kleros Governance${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

print_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  local     Start local devnet (default)"
    echo "  stop      Stop all services"
    echo "  logs      View logs (follow mode)"
    echo "  status    Show current status"
    echo "  demo      Run sequencer rotation demo"
    echo "  clean     Clean all data and start fresh"
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

get_address() {
    # Read address from individual .address file (no Python/jq needed)
    docker compose exec -T deployer cat /app/.deployments/"$1".address 2>/dev/null || echo ""
}

start_local() {
    print_header
    echo -e "${GREEN}Starting Constitutional L2 local devnet...${NC}"
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
    echo -e "${GREEN}  Constitutional L2 is running!${NC}"
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
    echo "  Account 1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (sequencer 1)"
    echo "  Account 2: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC (sequencer 2)"
    echo "  Account 3: 0x90F79bf6EB2c4f870365E785982E1f101E93b906 (sequencer 3)"
    echo ""
    echo "Commands:"
    echo "  ./start.sh demo     - Run sequencer rotation demo"
    echo "  ./start.sh status   - Check service status"
    echo "  ./start.sh logs     - View logs"
    echo "  ./start.sh stop     - Stop all services"
    echo ""
}

stop_services() {
    echo "Stopping all services..."
    docker compose down
    echo -e "${GREEN}All services stopped${NC}"
}

clean_all() {
    echo "Cleaning all data..."
    docker compose down -v
    rm -rf .deployments docker/config/*.json
    echo -e "${GREEN}All data cleaned${NC}"
}

show_logs() {
    docker compose logs -f
}

show_status() {
    print_header

    echo "Service Status:"
    echo ""
    docker compose ps 2>/dev/null || echo "No services running"

    echo ""
    echo "Contract Addresses:"

    local MANAGER=$(get_address "KlerosSequencerManager")
    if [ -n "$MANAGER" ] && [ "$MANAGER" != "" ]; then
        echo "  KlerosSequencerManager: $MANAGER"
        echo "  MockCurate:             $(get_address 'MockCurate')"
        echo "  MockSystemConfig:       $(get_address 'MockSystemConfig')"

        echo ""
        echo "Current State:"

        # Check if cast is available locally or in container
        if command -v cast &> /dev/null; then
            local L1_RPC="http://localhost:8545"
            local current_seq=$(cast call "$MANAGER" "currentSequencer()(address)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
            local active_count=$(cast call "$MANAGER" "activeSequencerCount()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
            local time_until=$(cast call "$MANAGER" "timeUntilNextRotation()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")

            echo "  Current Sequencer:    $current_seq"
            echo "  Active Sequencers:    $active_count"
            echo "  Time Until Rotation:  ${time_until}s"
        else
            echo "  (install 'cast' from Foundry to view state)"
        fi
    else
        echo "  (contracts not yet deployed)"
    fi

    echo ""
}

run_demo() {
    print_header
    echo -e "${CYAN}Running Sequencer Rotation Demo${NC}"
    echo ""

    # Check if cast is available
    if ! command -v cast &> /dev/null; then
        echo -e "${RED}Error: 'cast' not found${NC}"
        echo "Please install Foundry: https://book.getfoundry.sh/getting-started/installation"
        exit 1
    fi

    # Get manager address
    local MANAGER=$(get_address "KlerosSequencerManager")

    if [ -z "$MANAGER" ] || [ "$MANAGER" = "" ]; then
        echo -e "${RED}Error: Contracts not deployed${NC}"
        echo "Start the devnet first: ./start.sh local"
        exit 1
    fi

    echo "KlerosSequencerManager: $MANAGER"
    echo ""

    local L1_RPC="http://localhost:8545"
    local DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

    show_sequencer() {
        local seq=$(cast call "$MANAGER" "currentSequencer()(address)" --rpc-url "$L1_RPC" 2>/dev/null)
        echo -e "  Current Sequencer: ${GREEN}$seq${NC}"
    }

    advance_time() {
        curl -s -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"evm_increaseTime\",\"params\":[$1],\"id\":1}" \
             -H "Content-Type: application/json" "$L1_RPC" > /dev/null
        curl -s -X POST --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id":1}' \
             -H "Content-Type: application/json" "$L1_RPC" > /dev/null
    }

    echo "Initial state:"
    show_sequencer
    echo ""

    # Show active sequencers
    echo "Active sequencers:"
    local count=$(cast call "$MANAGER" "activeSequencerCount()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null)
    for i in $(seq 0 $((count - 1))); do
        local seq=$(cast call "$MANAGER" "activeSequencers(uint256)(address)" "$i" --rpc-url "$L1_RPC" 2>/dev/null)
        echo "  [$i] $seq"
    done
    echo ""

    # Perform rotations
    for i in 1 2 3; do
        echo -e "${YELLOW}>>> Rotation $i${NC}"
        advance_time 15  # Epoch is 10 seconds

        cast send "$MANAGER" "rotateSequencer()" \
            --rpc-url "$L1_RPC" \
            --private-key "$DEPLOYER_KEY" \
            > /dev/null 2>&1

        show_sequencer
        echo ""
        sleep 1
    done

    echo -e "${GREEN}Demo complete!${NC}"
    echo ""
    echo "The sequencer has rotated through the active set in round-robin order."
    echo "In production, this would be called by a keeper bot each epoch."
    echo ""
    echo "Try more commands:"
    echo "  cast call $MANAGER 'getActiveSequencers()(address[])' --rpc-url $L1_RPC"
    echo "  cast call $MANAGER 'timeUntilNextRotation()(uint256)' --rpc-url $L1_RPC"
    echo ""
}

# Main
check_docker

case "${1:-local}" in
    local|start)
        start_local
        ;;
    stop)
        stop_services
        ;;
    clean)
        clean_all
        ;;
    logs)
        show_logs
        ;;
    status)
        show_status
        ;;
    demo)
        run_demo
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
