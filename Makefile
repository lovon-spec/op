# ISOCHRON - Makefile
#
# Common commands for development, testing, and deployment

.PHONY: all build test clean install deploy-local integration-test help

# Default target
all: build test

# =============================================================
# Setup
# =============================================================

install:
	forge install

# =============================================================
# Building
# =============================================================

build:
	forge build

clean:
	forge clean
	rm -rf docker/config/*.json

# =============================================================
# Testing
# =============================================================

test:
	forge test

test-v:
	forge test -vvv

test-gas:
	forge test --gas-report

coverage:
	forge coverage

# =============================================================
# Local Development
# =============================================================

# Start Anvil in the background
anvil:
	anvil --port 8545 --block-time 2

# Deploy ISOCHRON architecture to local Anvil
deploy-kssn:
	forge script script/DeployKSSN.s.sol:DeployKSSN \
		--rpc-url http://127.0.0.1:8545 \
		--broadcast

# Run the integration test script
integration-test:
	forge script script/IntegrationTest.s.sol:IntegrationTest \
		--rpc-url http://127.0.0.1:8545 \
		--broadcast \
		-vvvv

# =============================================================
# Docker (Full OP Stack)
# =============================================================

docker-up:
	./start.sh local

docker-down:
	./start.sh stop

docker-logs:
	./start.sh logs

docker-status:
	./start.sh status

docker-demo:
	./start.sh demo

# =============================================================
# Deployment
# =============================================================

deploy-sepolia:
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "Error: PRIVATE_KEY not set"; \
		echo "Run: source .env.sepolia"; \
		exit 1; \
	fi
	forge script script/DeployRemote.s.sol:DeployRemote \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--verify

deploy-mainnet:
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "Error: PRIVATE_KEY not set"; \
		echo "Run: source .env.mainnet"; \
		exit 1; \
	fi
	@echo "WARNING: Deploying to mainnet!"
	@read -p "Press Enter to continue or Ctrl+C to abort..."
	forge script script/DeployRemote.s.sol:DeployRemote \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--verify \
		--slow

# =============================================================
# Utilities
# =============================================================

# Format code
fmt:
	forge fmt

# Check formatting
fmt-check:
	forge fmt --check

# Update dependencies
update:
	forge update

# Show contract sizes
sizes:
	forge build --sizes

# =============================================================
# Help
# =============================================================

help:
	@echo "ISOCHRON - Development Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make install      - Install dependencies"
	@echo ""
	@echo "Building:"
	@echo "  make build        - Build contracts"
	@echo "  make clean        - Clean build artifacts"
	@echo ""
	@echo "Testing:"
	@echo "  make test         - Run all tests"
	@echo "  make test-v       - Run tests with verbose output"
	@echo "  make test-gas     - Run tests with gas report"
	@echo "  make coverage     - Generate coverage report"
	@echo ""
	@echo "Local Development:"
	@echo "  make anvil            - Start local Anvil node"
	@echo "  make deploy-kssn      - Deploy ISOCHRON Hub-and-Spoke to local Anvil"
	@echo "  make integration-test - Run ISOCHRON integration test"
	@echo ""
	@echo "Docker (Full OP Stack):"
	@echo "  make docker-up    - Start all services"
	@echo "  make docker-down  - Stop all services"
	@echo "  make docker-logs  - View logs"
	@echo "  make docker-demo  - Run rotation demo"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy-sepolia - Deploy to Sepolia"
	@echo "  make deploy-mainnet - Deploy to mainnet"
	@echo ""
	@echo "Utilities:"
	@echo "  make fmt          - Format code"
	@echo "  make sizes        - Show contract sizes"
