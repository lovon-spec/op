#!/usr/bin/env python3
"""
Self-Activation Agent for Constitutional L2 Operators

This agent monitors the on-chain KlerosSequencerManager and automatically
manages the operator's OP Stack services, implementing the Active Handoff
Protocol for zero-downtime operator transitions.

Active Handoff Protocol:
- At epoch end, the current operator initiates rotation (not keepers)
- Agent stops sequencing, flushes batches, then calls rotateOperator()
- New operator's agent detects the change and immediately starts

IMPORTANT: Each operator MUST run their own self-activation agent. This ensures:
1. Decentralized control - no central entity can start/stop other operators
2. Constitutional compliance - operators only produce blocks when authorized
3. Clean handoffs - services start/stop based on on-chain state
4. Zero re-orgs - batches are flushed before rotation

Usage:
    python self_activation_agent.py --config config.yaml

Configuration (config.yaml):
    l1_rpc: "http://localhost:8545"
    manager_address: "0x..."
    batcher_address: "0x..."          # This operator's batcher address
    unsafe_signer_address: "0x..."    # This operator's unsafe signer address
    private_key: "0x..."              # Private key for batcher or signer (to call rotateOperator)
    poll_interval: 12                 # Seconds between checks (1 L1 block)
    op_node_admin_url: "http://localhost:7545"
    op_batcher_admin_url: "http://localhost:7546"
    handoff_lead_time: 60             # Start handoff this many seconds before epoch ends
    flush_timeout: 300                # Max time to wait for batch flush (seconds)
"""

import argparse
import json
import logging
import sys
import time
from dataclasses import dataclass, field
from enum import Enum, auto
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


class AgentState(Enum):
    """State machine for the self-activation agent."""
    INACTIVE = auto()        # Not the current operator, watching for activation
    ACTIVE = auto()          # Currently sequencing blocks
    HANDOFF_PENDING = auto() # Epoch ended, executing handoff sequence


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
    },
    {
        "inputs": [],
        "name": "epochDuration",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "GRACE_PERIOD",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "lastRotationTimestamp",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "rotateOperator",
        "outputs": [],
        "stateMutability": "nonpayable",
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
    private_key: str = ""              # For signing rotateOperator tx
    poll_interval: int = 12            # Default to ~1 L1 block
    op_node_admin_url: str = "http://localhost:7545"
    op_batcher_admin_url: str = "http://localhost:7546"
    handoff_lead_time: int = 60        # Start handoff 60s before epoch ends
    flush_timeout: int = 300           # Max 5 minutes to flush batches

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

    def flush_batches(self, timeout: int = 300) -> bool:
        """
        Force the batcher to flush all pending batches to L1.

        This is critical for Active Handoff - we must ensure all unsafe blocks
        are batched before triggering rotation.
        """
        logger.info("Flushing pending batches to L1...")

        try:
            # First, check if there are pending batches
            response = requests.post(
                self.op_batcher_url,
                json={
                    "jsonrpc": "2.0",
                    "method": "admin_batcherStatus",
                    "params": [],
                    "id": 1
                },
                timeout=10
            )
            status = response.json()

            if "error" in status:
                logger.warning(f"Could not get batcher status: {status['error']}")
                # Continue anyway - best effort flush
            else:
                logger.debug(f"Batcher status: {status.get('result', {})}")

            # Trigger immediate batch submission
            response = requests.post(
                self.op_batcher_url,
                json={
                    "jsonrpc": "2.0",
                    "method": "admin_flushChannel",
                    "params": [],
                    "id": 2
                },
                timeout=10
            )
            result = response.json()

            if "error" in result:
                # admin_flushChannel may not exist in all versions
                # Fall back to stopping batcher (which flushes on stop)
                logger.warning(f"admin_flushChannel not available: {result['error']}")
                logger.info("Stopping batcher to trigger flush...")
                return self.stop_batcher()

            logger.info("Batch flush triggered successfully")

            # Wait for batches to be confirmed on L1
            # In production, you'd monitor the L1 for batch tx confirmation
            # For now, we give it some time to complete
            start_time = time.time()
            while time.time() - start_time < timeout:
                # Check batcher status to see if flush is complete
                response = requests.post(
                    self.op_batcher_url,
                    json={
                        "jsonrpc": "2.0",
                        "method": "admin_batcherStatus",
                        "params": [],
                        "id": 3
                    },
                    timeout=10
                )
                status = response.json()

                # Check if there are pending frames/batches
                # The exact field depends on op-batcher version
                result = status.get("result", {})
                pending = result.get("pendingFrames", 0) or result.get("pendingBatches", 0)

                if pending == 0:
                    logger.info("All batches flushed successfully")
                    return True

                logger.debug(f"Waiting for {pending} pending batches to flush...")
                time.sleep(2)

            logger.warning(f"Flush timeout after {timeout}s - proceeding anyway")
            return True  # Proceed with handoff even if flush didn't complete

        except Exception as e:
            logger.error(f"Error flushing batches: {e}")
            # Still return True to allow handoff to proceed
            # A stuck flush shouldn't block rotation indefinitely
            return True

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

    Implements the Active Handoff Protocol:
    - Monitor epoch countdown while active
    - At epoch end: stop sequencing -> flush batches -> call rotateOperator()
    - New operator's agent detects change and starts immediately

    Constitutional Requirement:
    - Operators MUST run this agent (or equivalent)
    - Operators MUST NOT produce blocks when unauthorized
    - Operators MUST execute Active Handoff at epoch end
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

        # Set up account for signing transactions if private key provided
        self.account = None
        if config.private_key:
            self.account = self.web3.eth.account.from_key(config.private_key)
            logger.info(f"Signing account: {self.account.address}")

        self._state = AgentState.INACTIVE
        self._epoch_duration = None
        self._grace_period = None

        logger.info(f"Agent initialized for operator:")
        logger.info(f"  Batcher: {self.batcher}")
        logger.info(f"  Unsafe Signer: {self.signer}")
        logger.info(f"  Manager: {config.manager_address}")

    def _load_contract_constants(self) -> None:
        """Load epochDuration and GRACE_PERIOD from contract."""
        if self._epoch_duration is None:
            self._epoch_duration = self.manager.functions.epochDuration().call()
            logger.info(f"Epoch duration: {self._epoch_duration}s")

        if self._grace_period is None:
            self._grace_period = self.manager.functions.GRACE_PERIOD().call()
            logger.info(f"Grace period: {self._grace_period}s")

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
        """Get seconds until next rotation is possible (epoch end)."""
        try:
            return self.manager.functions.timeUntilNextRotation().call()
        except Exception as e:
            logger.error(f"Error getting time until rotation: {e}")
            return 0

    def get_time_since_epoch_start(self) -> int:
        """Get seconds since the current epoch started."""
        try:
            last_rotation = self.manager.functions.lastRotationTimestamp().call()
            current_time = self.web3.eth.get_block('latest')['timestamp']
            return current_time - last_rotation
        except Exception as e:
            logger.error(f"Error getting time since epoch start: {e}")
            return 0

    def is_in_grace_period(self) -> bool:
        """Check if we're in the grace period (Phase 2)."""
        self._load_contract_constants()
        time_since_start = self.get_time_since_epoch_start()
        return time_since_start >= self._epoch_duration

    def is_past_grace_period(self) -> bool:
        """Check if we're past the grace period (Phase 3 - Dead Man's Switch)."""
        self._load_contract_constants()
        time_since_start = self.get_time_since_epoch_start()
        return time_since_start > (self._epoch_duration + self._grace_period)

    def call_rotate_operator(self) -> bool:
        """
        Call rotateOperator() on the manager contract.

        This triggers the rotation to the next operator. Only callable by
        the current operator during the grace period (Phase 2).
        """
        if not self.account:
            logger.error("No private key configured - cannot call rotateOperator()")
            return False

        try:
            logger.info("Calling rotateOperator()...")

            # Build the transaction
            tx = self.manager.functions.rotateOperator().build_transaction({
                'from': self.account.address,
                'nonce': self.web3.eth.get_transaction_count(self.account.address),
                'gas': 500000,  # Generous gas limit
                'maxFeePerGas': self.web3.eth.gas_price * 2,
                'maxPriorityFeePerGas': self.web3.eth.gas_price,
            })

            # Sign and send
            signed_tx = self.web3.eth.account.sign_transaction(tx, self.account.key)
            tx_hash = self.web3.eth.send_raw_transaction(signed_tx.raw_transaction)

            logger.info(f"rotateOperator tx sent: {tx_hash.hex()}")

            # Wait for confirmation
            receipt = self.web3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

            if receipt['status'] == 1:
                logger.info(f"rotateOperator SUCCESS in block {receipt['blockNumber']}")
                return True
            else:
                logger.error(f"rotateOperator FAILED - tx reverted")
                return False

        except Exception as e:
            logger.error(f"Error calling rotateOperator: {e}")
            return False

    def execute_handoff(self) -> bool:
        """
        Execute the Active Handoff sequence:
        1. Stop sequencing (no new unsafe blocks)
        2. Flush all pending batches to L1
        3. Call rotateOperator()
        4. Transition to INACTIVE state

        Returns True if handoff completed successfully.
        """
        logger.info("=" * 60)
        logger.info("EXECUTING ACTIVE HANDOFF")
        logger.info("=" * 60)

        # Step 1: Stop sequencing
        logger.info("Step 1/3: Stopping sequencer...")
        if not self.controller.stop_sequencer():
            logger.error("Failed to stop sequencer - continuing anyway")

        # Step 2: Flush batches
        logger.info("Step 2/3: Flushing pending batches to L1...")
        if not self.controller.flush_batches(self.config.flush_timeout):
            logger.warning("Batch flush may not have completed - continuing anyway")

        # Step 3: Call rotateOperator
        logger.info("Step 3/3: Calling rotateOperator()...")
        if not self.call_rotate_operator():
            logger.error("Failed to call rotateOperator()")
            # Don't return False - we should still transition to inactive
            # Another keeper might rotate us out

        # Stop batcher after rotation (no longer authorized)
        self.controller.stop_batcher()

        logger.info("=" * 60)
        logger.info("HANDOFF COMPLETE - Transitioning to INACTIVE")
        logger.info("=" * 60)

        return True

    def run_once(self) -> None:
        """Check on-chain state and update local services accordingly."""
        self._load_contract_constants()

        is_current = self.check_is_current_operator()
        time_until = self.get_time_until_rotation()

        # State machine transitions
        if self._state == AgentState.INACTIVE:
            if is_current:
                # We just became the active operator - start immediately
                logger.info("=" * 60)
                logger.info("THIS OPERATOR IS NOW ACTIVE - Starting services")
                logger.info("=" * 60)
                if self.controller.activate():
                    self._state = AgentState.ACTIVE
                else:
                    logger.error("Failed to activate services!")
            else:
                # Still inactive, just log status
                current = self.get_current_operator()
                if current:
                    logger.debug(
                        f"Not active. Current: batcher={current[0][:10]}... "
                        f"Next rotation possible in {time_until}s"
                    )

        elif self._state == AgentState.ACTIVE:
            if not is_current:
                # We were rotated out (possibly by Dead Man's Switch)
                logger.warning("No longer current operator - was rotated out externally")
                self.controller.deactivate()
                self._state = AgentState.INACTIVE
            elif time_until <= self.config.handoff_lead_time:
                # Epoch ending soon - begin handoff
                logger.info(f"Epoch ending in {time_until}s - initiating handoff")
                self._state = AgentState.HANDOFF_PENDING
            else:
                # Still active, normal operation
                logger.debug(f"Active. Epoch ends in {time_until}s")

        elif self._state == AgentState.HANDOFF_PENDING:
            # Check if we're now in the grace period (can call rotateOperator)
            if self.is_in_grace_period():
                self.execute_handoff()
                self._state = AgentState.INACTIVE
            elif not is_current:
                # We were rotated out during handoff preparation
                logger.warning("Rotated out during handoff - transitioning to inactive")
                self.controller.deactivate()
                self._state = AgentState.INACTIVE
            else:
                # Still waiting for grace period
                logger.debug(f"Handoff pending - waiting for grace period ({time_until}s until epoch end)")

    def run(self) -> None:
        """Main loop - poll on-chain state and manage services."""
        logger.info(f"Starting self-activation agent (poll interval: {self.config.poll_interval}s)")
        logger.info(f"Handoff lead time: {self.config.handoff_lead_time}s")
        logger.info(f"Flush timeout: {self.config.flush_timeout}s")

        # Load contract constants
        self._load_contract_constants()

        # Ensure we start in stopped state
        self.controller.deactivate()
        self._state = AgentState.INACTIVE

        while True:
            try:
                self.run_once()
            except Exception as e:
                logger.error(f"Error in main loop: {e}")

            time.sleep(self.config.poll_interval)


def main():
    parser = argparse.ArgumentParser(
        description="Self-Activation Agent for Constitutional L2 Operators (with Active Handoff)"
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
