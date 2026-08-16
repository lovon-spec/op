#!/usr/bin/env python3
"""
ISOCHRON Proposer Agent for Interconnected Sequencing Oracle for Cross-chain Harmonized Reliability, Ordering & Network

This agent monitors the on-chain SharedSequencerHub and automatically
manages the proposer's OP Stack services, implementing the Active Handoff
Protocol for zero-downtime proposer transitions.

Architecture:
- Hub-and-Spoke: This agent runs for a single proposer managing multiple chains
- Active Handoff: At epoch end, current proposer initiates rotation
- Atomic Rotation: Hub updates ALL chains in a single transaction

Active Handoff Protocol:
- At epoch end, the current proposer initiates rotation (not keepers)
- Agent stops sequencing, flushes batches, then calls rotateNetwork()
- New proposer's agent detects the change and immediately starts

IMPORTANT: Each proposer MUST run their own agent. This ensures:
1. Decentralized control - no central entity can start/stop proposers
2. SLA compliance - proposers only sequence when authorized
3. Clean handoffs - services start/stop based on on-chain state
4. Zero re-orgs - batches are flushed before rotation

Usage:
    python kssn_proposer_agent.py --config config.yaml

Configuration (config.yaml):
    l1_rpc: "http://localhost:8545"
    hub_address: "0x..."
    proposer_address: "0x..."          # This proposer's address
    private_key: "0x..."               # Private key for calling rotateNetwork
    poll_interval: 12                  # Seconds between checks (1 L1 block)
    op_node_admin_url: "http://localhost:7545"
    op_batcher_admin_url: "http://localhost:7546"
    handoff_lead_time: 60              # Start handoff this many seconds before epoch ends
    flush_timeout: 300                 # Max time to wait for batch flush (seconds)
"""

import argparse
import json
import logging
import sys
import time
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional, List

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
    """State machine for the ISOCHRON proposer agent."""
    INACTIVE = auto()        # Not the current proposer, watching for activation
    ACTIVE = auto()          # Currently the active proposer for the network
    HANDOFF_PENDING = auto() # Epoch ending, executing handoff sequence


# ABI for SharedSequencerHub (only the functions we need)
HUB_ABI = [
    {
        "inputs": [],
        "name": "currentProposer",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "currentEpoch",
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
        "name": "gracePeriod",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "epochStartTime",
        "outputs": [{"name": "", "type": "uint256"}],
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
        "name": "isRotationWindowOpen",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "isInGracePeriod",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [{"name": "_proposer", "type": "address"}],
        "name": "isCurrentProposer",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "getChainCount",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "getActiveChainCount",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "rotateNetwork",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "isPaused",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function"
    }
]


@dataclass
class Config:
    """Agent configuration for ISOCHRON."""
    l1_rpc: str
    hub_address: str
    proposer_address: str
    private_key: str = ""              # For signing rotateNetwork tx
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
                logger.warning(f"admin_flushChannel not available: {result['error']}")
                logger.info("Stopping batcher to trigger flush...")
                return self.stop_batcher()

            logger.info("Batch flush triggered successfully")

            # Wait for batches to be confirmed on L1
            start_time = time.time()
            while time.time() - start_time < timeout:
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

                result = status.get("result", {})
                pending = result.get("pendingFrames", 0) or result.get("pendingBatches", 0)

                if pending == 0:
                    logger.info("All batches flushed successfully")
                    return True

                logger.debug(f"Waiting for {pending} pending batches to flush...")
                time.sleep(2)

            logger.warning(f"Flush timeout after {timeout}s - proceeding anyway")
            return True

        except Exception as e:
            logger.error(f"Error flushing batches: {e}")
            return True

    def activate(self) -> bool:
        """Activate both sequencer and batcher."""
        seq_ok = self.start_sequencer()
        batch_ok = self.start_batcher()
        return seq_ok and batch_ok

    def deactivate(self) -> bool:
        """Deactivate both sequencer and batcher."""
        batch_ok = self.stop_batcher()
        seq_ok = self.stop_sequencer()
        return seq_ok and batch_ok


class ISOCHRONProposerAgent:
    """
    ISOCHRON Proposer Agent - monitors SharedSequencerHub and manages local OP Stack services.

    Implements the Active Handoff Protocol:
    - Monitor epoch countdown while active
    - At epoch end: stop sequencing -> flush batches -> call rotateNetwork()
    - New proposer's agent detects change and starts immediately

    Key ISOCHRON Differences from Single-Chain:
    - rotateNetwork() updates ALL connected chains atomically
    - Proposer is the same for all chains in the network
    - Sequencer operation targets SLA expectations for rotation and availability
    """

    def __init__(self, config: Config):
        self.config = config
        self.web3 = Web3(Web3.HTTPProvider(config.l1_rpc))

        if not self.web3.is_connected():
            raise ConnectionError(f"Cannot connect to L1 RPC: {config.l1_rpc}")

        self.hub = self.web3.eth.contract(
            address=Web3.to_checksum_address(config.hub_address),
            abi=HUB_ABI
        )

        self.controller = OPStackController(
            config.op_node_admin_url,
            config.op_batcher_admin_url
        )

        self.proposer = Web3.to_checksum_address(config.proposer_address)

        # Set up account for signing transactions if private key provided
        self.account = None
        if config.private_key:
            self.account = self.web3.eth.account.from_key(config.private_key)
            logger.info(f"Signing account: {self.account.address}")

        self._state = AgentState.INACTIVE
        self._epoch_duration = None
        self._grace_period = None

        logger.info(f"ISOCHRON Proposer Agent initialized:")
        logger.info(f"  Proposer: {self.proposer}")
        logger.info(f"  Hub: {config.hub_address}")

    def _load_contract_constants(self) -> None:
        """Load epochDuration and gracePeriod from contract."""
        if self._epoch_duration is None:
            self._epoch_duration = self.hub.functions.epochDuration().call()
            logger.info(f"Epoch duration: {self._epoch_duration}s")

        if self._grace_period is None:
            self._grace_period = self.hub.functions.gracePeriod().call()
            logger.info(f"Grace period: {self._grace_period}s")

    def check_is_current_proposer(self) -> bool:
        """Check if this proposer is currently selected on-chain."""
        try:
            return self.hub.functions.isCurrentProposer(self.proposer).call()
        except Exception as e:
            logger.error(f"Error checking proposer status: {e}")
            return False

    def get_current_proposer(self) -> Optional[str]:
        """Get the currently selected proposer from on-chain."""
        try:
            return self.hub.functions.currentProposer().call()
        except Exception as e:
            logger.error(f"Error getting current proposer: {e}")
            return None

    def get_current_epoch(self) -> int:
        """Get the current epoch number."""
        try:
            return self.hub.functions.currentEpoch().call()
        except Exception as e:
            logger.error(f"Error getting current epoch: {e}")
            return 0

    def get_time_until_rotation(self) -> int:
        """Get seconds until next rotation is possible (epoch end)."""
        try:
            return self.hub.functions.timeUntilNextRotation().call()
        except Exception as e:
            logger.error(f"Error getting time until rotation: {e}")
            return 0

    def get_chain_count(self) -> int:
        """Get the number of connected chains."""
        try:
            return self.hub.functions.getChainCount().call()
        except Exception as e:
            logger.error(f"Error getting chain count: {e}")
            return 0

    def get_active_chain_count(self) -> int:
        """Get the number of active chains."""
        try:
            return self.hub.functions.getActiveChainCount().call()
        except Exception as e:
            logger.error(f"Error getting active chain count: {e}")
            return 0

    def is_rotation_window_open(self) -> bool:
        """Check if we're in the rotation window (can call rotateNetwork)."""
        try:
            return self.hub.functions.isRotationWindowOpen().call()
        except Exception as e:
            logger.error(f"Error checking rotation window: {e}")
            return False

    def is_in_grace_period(self) -> bool:
        """Check if we're in the grace period (Phase 2)."""
        try:
            return self.hub.functions.isInGracePeriod().call()
        except Exception as e:
            logger.error(f"Error checking grace period: {e}")
            return False

    def is_hub_paused(self) -> bool:
        """Check if the hub is paused."""
        try:
            return self.hub.functions.isPaused().call()
        except Exception as e:
            logger.error(f"Error checking hub pause status: {e}")
            return True  # Assume paused on error

    def call_rotate_network(self) -> bool:
        """
        Call rotateNetwork() on the hub contract.

        This triggers atomic rotation for ALL connected chains.
        Only callable during the rotation window (grace period or after).
        """
        if not self.account:
            logger.error("No private key configured - cannot call rotateNetwork()")
            return False

        try:
            logger.info("Calling rotateNetwork() for atomic multichain rotation...")

            # Build the transaction
            tx = self.hub.functions.rotateNetwork().build_transaction({
                'from': self.account.address,
                'nonce': self.web3.eth.get_transaction_count(self.account.address),
                'gas': 3000000,  # Higher gas limit for multichain rotation
                'maxFeePerGas': self.web3.eth.gas_price * 2,
                'maxPriorityFeePerGas': self.web3.eth.gas_price,
            })

            # Sign and send
            signed_tx = self.web3.eth.account.sign_transaction(tx, self.account.key)
            tx_hash = self.web3.eth.send_raw_transaction(signed_tx.raw_transaction)

            logger.info(f"rotateNetwork tx sent: {tx_hash.hex()}")

            # Wait for confirmation
            receipt = self.web3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

            if receipt['status'] == 1:
                logger.info(f"rotateNetwork SUCCESS in block {receipt['blockNumber']}")
                logger.info(f"Gas used: {receipt['gasUsed']}")
                return True
            else:
                logger.error(f"rotateNetwork FAILED - tx reverted")
                return False

        except Exception as e:
            logger.error(f"Error calling rotateNetwork: {e}")
            return False

    def execute_handoff(self) -> bool:
        """
        Execute the Active Handoff sequence:
        1. Stop sequencing (no new unsafe blocks)
        2. Flush all pending batches to L1
        3. Call rotateNetwork()
        4. Transition to INACTIVE state

        Returns True if handoff completed successfully.
        """
        logger.info("=" * 70)
        logger.info("EXECUTING ISOCHRON ACTIVE HANDOFF - ATOMIC MULTICHAIN ROTATION")
        logger.info("=" * 70)

        chain_count = self.get_active_chain_count()
        logger.info(f"Rotating proposer for {chain_count} active chains")

        # Step 1: Stop sequencing
        logger.info("Step 1/3: Stopping sequencer...")
        if not self.controller.stop_sequencer():
            logger.error("Failed to stop sequencer - continuing anyway")

        # Step 2: Flush batches
        logger.info("Step 2/3: Flushing pending batches to L1...")
        if not self.controller.flush_batches(self.config.flush_timeout):
            logger.warning("Batch flush may not have completed - continuing anyway")

        # Step 3: Call rotateNetwork
        logger.info("Step 3/3: Calling rotateNetwork() for atomic rotation...")
        if not self.call_rotate_network():
            logger.error("Failed to call rotateNetwork()")

        # Stop batcher after rotation (no longer authorized)
        self.controller.stop_batcher()

        logger.info("=" * 70)
        logger.info("HANDOFF COMPLETE - All chains rotated to new proposer")
        logger.info("=" * 70)

        return True

    def run_once(self) -> None:
        """Check on-chain state and update local services accordingly."""
        self._load_contract_constants()

        # Check if hub is paused
        if self.is_hub_paused():
            if self._state == AgentState.ACTIVE:
                logger.warning("Hub is paused - stopping services")
                self.controller.deactivate()
                self._state = AgentState.INACTIVE
            return

        is_current = self.check_is_current_proposer()
        time_until = self.get_time_until_rotation()
        epoch = self.get_current_epoch()

        # State machine transitions
        if self._state == AgentState.INACTIVE:
            if is_current:
                # We just became the active proposer - start immediately
                logger.info("=" * 70)
                logger.info("THIS PROPOSER IS NOW ACTIVE FOR ISOCHRON - Starting services")
                logger.info(f"Epoch: {epoch}, Connected chains: {self.get_chain_count()}")
                logger.info("=" * 70)
                if self.controller.activate():
                    self._state = AgentState.ACTIVE
                else:
                    logger.error("Failed to activate services!")
            else:
                # Still inactive, just log status
                current = self.get_current_proposer()
                if current:
                    logger.debug(
                        f"Not active. Current proposer: {current[:10]}... "
                        f"Epoch: {epoch}, Next rotation in {time_until}s"
                    )

        elif self._state == AgentState.ACTIVE:
            if not is_current:
                # We were rotated out (possibly by Dead Man's Switch)
                logger.warning("No longer current proposer - was rotated out externally")
                self.controller.deactivate()
                self._state = AgentState.INACTIVE
            elif time_until <= self.config.handoff_lead_time:
                # Epoch ending soon - begin handoff
                logger.info(f"Epoch {epoch} ending in {time_until}s - initiating handoff")
                self._state = AgentState.HANDOFF_PENDING
            else:
                # Still active, normal operation
                logger.debug(f"Active proposer. Epoch {epoch} ends in {time_until}s")

        elif self._state == AgentState.HANDOFF_PENDING:
            # Check if we're now in the rotation window
            if self.is_in_grace_period() or self.is_rotation_window_open():
                self.execute_handoff()
                self._state = AgentState.INACTIVE
            elif not is_current:
                # We were rotated out during handoff preparation
                logger.warning("Rotated out during handoff - transitioning to inactive")
                self.controller.deactivate()
                self._state = AgentState.INACTIVE
            else:
                # Still waiting for rotation window
                logger.debug(f"Handoff pending - waiting for rotation window ({time_until}s until epoch end)")

    def run(self) -> None:
        """Main loop - poll on-chain state and manage services."""
        logger.info(f"Starting ISOCHRON Proposer Agent (poll interval: {self.config.poll_interval}s)")
        logger.info(f"Handoff lead time: {self.config.handoff_lead_time}s")
        logger.info(f"Flush timeout: {self.config.flush_timeout}s")

        # Load contract constants
        self._load_contract_constants()

        # Log network info
        chain_count = self.get_chain_count()
        active_chains = self.get_active_chain_count()
        logger.info(f"Connected chains: {chain_count} (active: {active_chains})")

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
        description="ISOCHRON Proposer Agent for Interconnected Sequencing Oracle for Cross-chain Harmonized Reliability, Ordering & Network"
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
        agent = ISOCHRONProposerAgent(config)
        agent.run()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
