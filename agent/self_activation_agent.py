#!/usr/bin/env python3
"""
Self-Activation Agent for Constitutional L2 Operators

This agent monitors the on-chain KlerosSequencerManager and automatically
starts/stops the operator's OP Stack services when they become the active
sequencer.

IMPORTANT: Each operator MUST run their own self-activation agent. This ensures:
1. Decentralized control - no central entity can start/stop other operators
2. Constitutional compliance - operators only produce blocks when authorized
3. Clean handoffs - services start/stop based on on-chain state

Usage:
    python self_activation_agent.py --config config.yaml

Configuration (config.yaml):
    l1_rpc: "http://localhost:8545"
    manager_address: "0x..."
    batcher_address: "0x..."          # This operator's batcher address
    unsafe_signer_address: "0x..."    # This operator's unsafe signer address
    poll_interval: 12                  # Seconds between checks (1 L1 block)
    op_node_admin_url: "http://localhost:7545"
    op_batcher_admin_url: "http://localhost:7546"
"""

import argparse
import json
import logging
import sys
import time
from dataclasses import dataclass
from typing import Optional

import requests
import yaml
from web3 import Web3

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# ABI for KlerosSequencerManager (only the functions we need)
MANAGER_ABI = [
    {
        "inputs": [
            {"name": "batcher", "type": "address"},
            {"name": "unsafeSigner", "type": "address"}
        ],
        "name": "isCurrentOperator",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "currentOperator",
        "outputs": [
            {
                "components": [
                    {"name": "batcher", "type": "address"},
                    {"name": "unsafeSigner", "type": "address"}
                ],
                "name": "",
                "type": "tuple"
            }
        ],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "timeUntilNextRotation",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    }
]


@dataclass
class Config:
    """Agent configuration."""
    l1_rpc: str
    manager_address: str
    batcher_address: str
    unsafe_signer_address: str
    poll_interval: int = 12  # Default to ~1 L1 block
    op_node_admin_url: str = "http://localhost:7545"
    op_batcher_admin_url: str = "http://localhost:7546"

    @classmethod
    def from_yaml(cls, path: str) -> 'Config':
        with open(path) as f:
            data = yaml.safe_load(f)
        return cls(**data)


class OPStackController:
    """Controls OP Stack services via their admin APIs."""

    def __init__(self, op_node_url: str, op_batcher_url: str):
        self.op_node_url = op_node_url
        self.op_batcher_url = op_batcher_url
        self._sequencer_active = False
        self._batcher_active = False

    def start_sequencer(self) -> bool:
        """Start the op-node sequencer."""
        if self._sequencer_active:
            logger.debug("Sequencer already active")
            return True

        try:
            response = requests.post(
                self.op_node_url,
                json={
                    "jsonrpc": "2.0",
                    "method": "admin_startSequencer",
                    "params": [],
                    "id": 1
                },
                timeout=10
            )
            result = response.json()
            if "error" in result:
                logger.error(f"Failed to start sequencer: {result['error']}")
                return False

            self._sequencer_active = True
            logger.info("Sequencer STARTED")
            return True

        except Exception as e:
            logger.error(f"Error starting sequencer: {e}")
            return False

    def stop_sequencer(self) -> bool:
        """Stop the op-node sequencer."""
        if not self._sequencer_active:
            logger.debug("Sequencer already stopped")
            return True

        try:
            response = requests.post(
                self.op_node_url,
                json={
                    "jsonrpc": "2.0",
                    "method": "admin_stopSequencer",
                    "params": [],
                    "id": 1
                },
                timeout=10
            )
            result = response.json()
            if "error" in result:
                logger.error(f"Failed to stop sequencer: {result['error']}")
                return False

            self._sequencer_active = False
            logger.info("Sequencer STOPPED")
            return True

        except Exception as e:
            logger.error(f"Error stopping sequencer: {e}")
            return False

    def start_batcher(self) -> bool:
        """Start the op-batcher."""
        if self._batcher_active:
            logger.debug("Batcher already active")
            return True

        try:
            response = requests.post(
                self.op_batcher_url,
                json={
                    "jsonrpc": "2.0",
                    "method": "admin_startBatcher",
                    "params": [],
                    "id": 1
                },
                timeout=10
            )
            result = response.json()
            if "error" in result:
                logger.error(f"Failed to start batcher: {result['error']}")
                return False

            self._batcher_active = True
            logger.info("Batcher STARTED")
            return True

        except Exception as e:
            logger.error(f"Error starting batcher: {e}")
            return False

    def stop_batcher(self) -> bool:
        """Stop the op-batcher."""
        if not self._batcher_active:
            logger.debug("Batcher already stopped")
            return True

        try:
            response = requests.post(
                self.op_batcher_url,
                json={
                    "jsonrpc": "2.0",
                    "method": "admin_stopBatcher",
                    "params": [],
                    "id": 1
                },
                timeout=10
            )
            result = response.json()
            if "error" in result:
                logger.error(f"Failed to stop batcher: {result['error']}")
                return False

            self._batcher_active = False
            logger.info("Batcher STOPPED")
            return True

        except Exception as e:
            logger.error(f"Error stopping batcher: {e}")
            return False

    def activate(self) -> bool:
        """Activate both sequencer and batcher."""
        seq_ok = self.start_sequencer()
        batch_ok = self.start_batcher()
        return seq_ok and batch_ok

    def deactivate(self) -> bool:
        """Deactivate both sequencer and batcher."""
        # Stop batcher first to avoid orphaned batches
        batch_ok = self.stop_batcher()
        seq_ok = self.stop_sequencer()
        return seq_ok and batch_ok


class SelfActivationAgent:
    """
    Watches the on-chain manager and activates/deactivates local OP Stack services.

    Constitutional Requirement:
    - Operators MUST run this agent (or equivalent)
    - Operators MUST NOT produce blocks when unauthorized
    - Violations are slashable via Kleros
    """

    def __init__(self, config: Config):
        self.config = config
        self.web3 = Web3(Web3.HTTPProvider(config.l1_rpc))

        if not self.web3.is_connected():
            raise ConnectionError(f"Cannot connect to L1 RPC: {config.l1_rpc}")

        self.manager = self.web3.eth.contract(
            address=Web3.to_checksum_address(config.manager_address),
            abi=MANAGER_ABI
        )

        self.controller = OPStackController(
            config.op_node_admin_url,
            config.op_batcher_admin_url
        )

        self.batcher = Web3.to_checksum_address(config.batcher_address)
        self.signer = Web3.to_checksum_address(config.unsafe_signer_address)

        self._is_active = False

        logger.info(f"Agent initialized for operator:")
        logger.info(f"  Batcher: {self.batcher}")
        logger.info(f"  Unsafe Signer: {self.signer}")
        logger.info(f"  Manager: {config.manager_address}")

    def check_is_current_operator(self) -> bool:
        """Check if this operator is currently selected on-chain."""
        try:
            return self.manager.functions.isCurrentOperator(
                self.batcher,
                self.signer
            ).call()
        except Exception as e:
            logger.error(f"Error checking operator status: {e}")
            return False

    def get_current_operator(self) -> Optional[tuple]:
        """Get the currently selected operator from on-chain."""
        try:
            result = self.manager.functions.currentOperator().call()
            return (result[0], result[1])  # (batcher, unsafeSigner)
        except Exception as e:
            logger.error(f"Error getting current operator: {e}")
            return None

    def get_time_until_rotation(self) -> int:
        """Get seconds until next rotation is possible."""
        try:
            return self.manager.functions.timeUntilNextRotation().call()
        except Exception as e:
            logger.error(f"Error getting time until rotation: {e}")
            return 0

    def run_once(self) -> None:
        """Check on-chain state and update local services accordingly."""
        should_be_active = self.check_is_current_operator()

        if should_be_active and not self._is_active:
            # We just became the active operator
            logger.info("=" * 50)
            logger.info("THIS OPERATOR IS NOW ACTIVE - Starting services")
            logger.info("=" * 50)
            if self.controller.activate():
                self._is_active = True
            else:
                logger.error("Failed to activate services!")

        elif not should_be_active and self._is_active:
            # We are no longer the active operator
            logger.info("=" * 50)
            logger.info("THIS OPERATOR IS NO LONGER ACTIVE - Stopping services")
            logger.info("=" * 50)
            if self.controller.deactivate():
                self._is_active = False
            else:
                logger.error("Failed to deactivate services!")

        else:
            # No change
            current = self.get_current_operator()
            time_until = self.get_time_until_rotation()
            if current:
                if should_be_active:
                    logger.debug(f"Still active. Next rotation possible in {time_until}s")
                else:
                    logger.debug(
                        f"Not active. Current: batcher={current[0][:10]}... "
                        f"Next rotation in {time_until}s"
                    )

    def run(self) -> None:
        """Main loop - poll on-chain state and manage services."""
        logger.info(f"Starting self-activation agent (poll interval: {self.config.poll_interval}s)")

        # Ensure we start in stopped state
        self.controller.deactivate()
        self._is_active = False

        while True:
            try:
                self.run_once()
            except Exception as e:
                logger.error(f"Error in main loop: {e}")

            time.sleep(self.config.poll_interval)


def main():
    parser = argparse.ArgumentParser(
        description="Self-Activation Agent for Constitutional L2 Operators"
    )
    parser.add_argument(
        "--config", "-c",
        required=True,
        help="Path to configuration YAML file"
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging"
    )

    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    try:
        config = Config.from_yaml(args.config)
        agent = SelfActivationAgent(config)
        agent.run()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
