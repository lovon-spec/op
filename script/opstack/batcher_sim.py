#!/usr/bin/env python3
"""
Simulated OP Stack Batcher

This script simulates an op-batcher that:
1. Reads the current batcherHash from SystemConfig
2. Checks if it's authorized to submit batches
3. Submits batch data to the BatchInbox if authorized

This demonstrates the integration between the SequencerManager (Kleros default arbitrator) and OP Stack.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

class BatcherSimulator:
    def __init__(self, rpc_url: str, system_config: str, private_key: str,
                 batcher_address: str, batch_inbox: str, name: str):
        self.rpc_url = rpc_url
        self.system_config = system_config
        self.private_key = private_key
        self.batcher_address = batcher_address.lower()
        self.batch_inbox = batch_inbox
        self.name = name
        self.cast_path = str(Path.home() / ".foundry/bin/cast")
        self.l2_block = 0
        self.batches_submitted = 0

    def get_batcher_hash(self) -> str:
        """Get current batcherHash from SystemConfig"""
        result = subprocess.run(
            [self.cast_path, "call", self.system_config,
             "batcherHash()(bytes32)", "--rpc-url", self.rpc_url],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            return None
        return result.stdout.strip().lower()

    def address_to_batcher_hash(self, address: str) -> str:
        """Convert address to V0 batcherHash format"""
        # V0 format: bytes32(uint256(uint160(address)))
        addr = address.lower().replace("0x", "")
        return "0x" + addr.zfill(64)

    def is_authorized(self) -> bool:
        """Check if this batcher is currently authorized"""
        current_hash = self.get_batcher_hash()
        expected_hash = self.address_to_batcher_hash(self.batcher_address)
        return current_hash == expected_hash

    def simulate_l2_blocks(self, count: int = 5):
        """Simulate L2 block production"""
        self.l2_block += count
        return self.l2_block

    def create_batch_data(self) -> str:
        """Create simulated batch data (channel frame)"""
        # Simulated batch data: version byte + channel data
        # In real OP Stack, this would be compressed L2 block data
        import hashlib
        batch_id = hashlib.sha256(f"{self.name}-{time.time()}".encode()).hexdigest()[:16]
        # Frame format: channel_id (16 bytes) + frame_number (2 bytes) + data
        return f"0x00{batch_id}0001{'deadbeef' * 32}"  # ~128 bytes of simulated data

    def submit_batch(self) -> dict:
        """Submit a batch to the BatchInbox"""
        batch_data = self.create_batch_data()

        result = subprocess.run(
            [self.cast_path, "send", self.batch_inbox,
             "--data", batch_data,
             "--rpc-url", self.rpc_url,
             "--private-key", self.private_key,
             "--json"],
            capture_output=True, text=True
        )

        if result.returncode == 0:
            self.batches_submitted += 1
            try:
                return json.loads(result.stdout)
            except:
                return {"status": "success", "raw": result.stdout}
        return {"status": "failed", "error": result.stderr}

    def run_once(self) -> dict:
        """Run one iteration of the batcher loop"""
        is_auth = self.is_authorized()

        status = {
            "batcher": self.name,
            "address": self.batcher_address,
            "authorized": is_auth,
            "l2_block": self.l2_block,
            "batches_submitted": self.batches_submitted
        }

        if is_auth:
            # Simulate L2 blocks and submit batch
            self.simulate_l2_blocks(5)
            result = self.submit_batch()
            status["action"] = "submitted_batch"
            status["tx_result"] = result
        else:
            # Not authorized - just wait
            status["action"] = "waiting_for_authorization"

        return status

    def run_loop(self, interval: float = 2.0):
        """Run the batcher in a continuous loop"""
        print(f"[{self.name}] Starting batcher simulation")
        print(f"[{self.name}] Address: {self.batcher_address}")
        print(f"[{self.name}] SystemConfig: {self.system_config}")
        print(f"[{self.name}] BatchInbox: {self.batch_inbox}")
        print("-" * 60)

        try:
            while True:
                status = self.run_once()

                if status["authorized"]:
                    print(f"[{self.name}] AUTHORIZED - L2 Block: {status['l2_block']}, "
                          f"Batches: {status['batches_submitted']}")
                    if "tx_result" in status and status["tx_result"].get("status") == "failed":
                        print(f"[{self.name}] Warning: Batch submission failed: "
                              f"{status['tx_result'].get('error', 'unknown')}")
                else:
                    print(f"[{self.name}] Not authorized - waiting...")

                time.sleep(interval)

        except KeyboardInterrupt:
            print(f"\n[{self.name}] Shutting down")
            return


def main():
    parser = argparse.ArgumentParser(description="OP Stack Batcher Simulator")
    parser.add_argument("--rpc-url", required=True, help="L1 RPC URL")
    parser.add_argument("--system-config", required=True, help="SystemConfig address")
    parser.add_argument("--private-key", required=True, help="Batcher private key")
    parser.add_argument("--batcher-address", required=True, help="Batcher address")
    parser.add_argument("--batch-inbox", required=True, help="BatchInbox address")
    parser.add_argument("--name", default="Batcher", help="Batcher name for logging")
    parser.add_argument("--once", action="store_true", help="Run once and exit")
    parser.add_argument("--interval", type=float, default=2.0, help="Loop interval")

    args = parser.parse_args()

    batcher = BatcherSimulator(
        rpc_url=args.rpc_url,
        system_config=args.system_config,
        private_key=args.private_key,
        batcher_address=args.batcher_address,
        batch_inbox=args.batch_inbox,
        name=args.name
    )

    if args.once:
        status = batcher.run_once()
        print(json.dumps(status, indent=2))
    else:
        batcher.run_loop(interval=args.interval)


if __name__ == "__main__":
    main()
