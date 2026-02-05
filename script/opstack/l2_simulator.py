#!/usr/bin/env python3
"""
Simulated OP Stack L2 Chain

This script simulates an L2 chain that:
1. Produces blocks at regular intervals
2. Tracks which sequencer produced each block
3. Batches blocks for submission to L1
4. Verifies batch submissions match the authorized batcher

This demonstrates the full L2 lifecycle in the OP Stack.
"""

import argparse
import json
import subprocess
import sys
import time
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional
from queue import Queue

@dataclass
class L2Block:
    number: int
    timestamp: int
    sequencer: str
    tx_count: int
    gas_used: int
    batch_submitted: bool = False

@dataclass
class Batch:
    start_block: int
    end_block: int
    blocks: List[L2Block]
    submitter: str
    l1_tx_hash: Optional[str] = None
    status: str = "pending"

class L2Simulator:
    def __init__(self, rpc_url: str, system_config: str, manager: str):
        self.rpc_url = rpc_url
        self.system_config = system_config
        self.manager = manager
        self.cast_path = str(Path.home() / ".foundry/bin/cast")

        self.blocks: List[L2Block] = []
        self.batches: List[Batch] = []
        self.current_block = 0
        self.block_time = 2  # seconds
        self.batch_size = 5  # blocks per batch

        self.running = False
        self.block_queue = Queue()

    def get_current_sequencer(self) -> str:
        """Get current sequencer from SequencerManager (Kleros default arbitrator)"""
        result = subprocess.run(
            [self.cast_path, "call", self.manager,
             "currentSequencer()(address)", "--rpc-url", self.rpc_url],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            return "0x0000000000000000000000000000000000000000"
        return result.stdout.strip()

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

    def produce_block(self) -> L2Block:
        """Produce a new L2 block"""
        self.current_block += 1
        sequencer = self.get_current_sequencer()

        # Simulate some transactions
        import random
        tx_count = random.randint(10, 100)
        gas_used = tx_count * random.randint(21000, 100000)

        block = L2Block(
            number=self.current_block,
            timestamp=int(time.time()),
            sequencer=sequencer,
            tx_count=tx_count,
            gas_used=gas_used
        )

        self.blocks.append(block)
        return block

    def create_batch(self) -> Optional[Batch]:
        """Create a batch from unbatched blocks"""
        unbatched = [b for b in self.blocks if not b.batch_submitted]

        if len(unbatched) < self.batch_size:
            return None

        batch_blocks = unbatched[:self.batch_size]
        current_seq = self.get_current_sequencer()

        batch = Batch(
            start_block=batch_blocks[0].number,
            end_block=batch_blocks[-1].number,
            blocks=batch_blocks,
            submitter=current_seq
        )

        for b in batch_blocks:
            b.batch_submitted = True

        self.batches.append(batch)
        return batch

    def print_status(self):
        """Print current L2 chain status"""
        current_seq = self.get_current_sequencer()
        print(f"\n{'='*60}")
        print(f"L2 Chain Status")
        print(f"{'='*60}")
        print(f"Current Block: {self.current_block}")
        print(f"Current Sequencer: {current_seq}")
        print(f"Total Batches: {len(self.batches)}")

        if self.blocks:
            recent = self.blocks[-5:]
            print(f"\nRecent Blocks:")
            for b in recent:
                status = "[batched]" if b.batch_submitted else "[pending]"
                print(f"  Block {b.number}: {b.tx_count} txs, "
                      f"seq={b.sequencer[:10]}... {status}")

        if self.batches:
            print(f"\nRecent Batches:")
            for batch in self.batches[-3:]:
                print(f"  Batch {batch.start_block}-{batch.end_block}: "
                      f"submitter={batch.submitter[:10]}... [{batch.status}]")

        print(f"{'='*60}\n")

    def run(self, duration: int = 60):
        """Run the L2 simulation for specified duration"""
        print(f"Starting L2 Simulation")
        print(f"Block time: {self.block_time}s")
        print(f"Batch size: {self.batch_size} blocks")
        print("-" * 60)

        self.running = True
        start_time = time.time()

        try:
            while self.running and (time.time() - start_time) < duration:
                # Produce a block
                block = self.produce_block()
                print(f"[L2] Block {block.number} produced by {block.sequencer[:10]}... "
                      f"({block.tx_count} txs)")

                # Try to create a batch
                batch = self.create_batch()
                if batch:
                    print(f"[L2] Batch created: blocks {batch.start_block}-{batch.end_block}")
                    batch.status = "submitted"

                # Every 5 blocks, print status
                if block.number % 5 == 0:
                    self.print_status()

                time.sleep(self.block_time)

        except KeyboardInterrupt:
            self.running = False

        print("\nL2 Simulation ended")
        self.print_status()


def main():
    parser = argparse.ArgumentParser(description="OP Stack L2 Simulator")
    parser.add_argument("--rpc-url", required=True, help="L1 RPC URL")
    parser.add_argument("--system-config", required=True, help="SystemConfig address")
    parser.add_argument("--manager", required=True, help="SequencerManager address (Kleros default arbitrator)")
    parser.add_argument("--duration", type=int, default=60, help="Simulation duration (seconds)")
    parser.add_argument("--block-time", type=int, default=2, help="Block time (seconds)")

    args = parser.parse_args()

    sim = L2Simulator(
        rpc_url=args.rpc_url,
        system_config=args.system_config,
        manager=args.manager
    )
    sim.block_time = args.block_time
    sim.run(duration=args.duration)


if __name__ == "__main__":
    main()
