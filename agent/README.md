# KSSN Proposer Agent

Decentralized agent that monitors on-chain state and automatically manages OP Stack services, implementing the **Active Handoff Protocol** for zero-downtime proposer transitions.

## Overview

The KSSN Proposer Agent monitors the `SharedSequencerHub` contract and manages OP Stack services for **all connected chains** in the Kleros Shared Sequencer Network.

```
  ChainRegistry         SharedSequencerHub           ProposerAgent
  ─────────────         ──────────────────           ─────────────
       │                        │                         │
       │  Chain Registered      │                         │
       │───────────────────────▶│                         │
       │                        │                         │
       │                        │  rotateNetwork()        │
       │                        │◀────────────────────────│
       │                        │                         │
       │                        │  Updates ALL chains     │
       │                        │  atomically             │
       │                        │                         │
```

## Features

- Monitors `SharedSequencerHub` for proposer status
- Manages OP Stack services for **all connected chains**
- Implements Active Handoff with atomic `rotateNetwork()` call
- Supports hub pause detection

## Why This Is Required

The KSSN uses a rotating proposer model where proposers take turns producing blocks across all connected chains. Each proposer MUST:

1. **Only produce blocks when authorized** - The on-chain Hub determines who is currently authorized
2. **Actively hand over control at epoch end** - Flush batches and trigger rotation (Active Handoff)
3. **Start automatically when becoming authorized** - To ensure seamless handoffs between proposers

This agent watches the on-chain state, controls the local OP Stack services, and **initiates the rotation** when the proposer's epoch ends.

## Constitutional Requirement

The KSSN constitution includes:

> Proposers MUST run a proposer agent (or equivalent mechanism).
> Proposers MUST NOT produce unsafe blocks or attempt batching while unauthorized.
> Proposers MUST execute Active Handoff at epoch end (flush batches, trigger rotation).
> Violations are slashable/removable via Kleros enforcement.

## Active Handoff Protocol

The agent implements the **Active Handoff Protocol** to ensure zero-downtime transitions:

```
            ACTIVE HANDOFF SEQUENCE (Outgoing Proposer)

  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                                                         │
  │  1. MONITOR              2. PREPARE              3. EXECUTE             │
  │  ┌──────────────┐       ┌──────────────┐       ┌──────────────┐        │
  │  │ Watch epoch  │ ────▶ │ Stop taking  │ ────▶ │ Flush batch  │        │
  │  │ end approach │       │ new txs      │       │ queue to L1  │        │
  │  └──────────────┘       └──────────────┘       └──────┬───────┘        │
  │                                                       │                 │
  │                                                       ▼                 │
  │                                                ┌──────────────┐         │
  │                                                │ Call rotate  │         │
  │                                                │ Network()    │         │
  │                                                └──────┬───────┘         │
  │                                                       │                 │
  │                                                       ▼                 │
  │                                               ┌───────────────┐         │
  │                                               │ Handover      │         │
  │                                               │ Complete      │         │
  │                                               └───────────────┘         │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘

            INSTANT ACTIVATION (Incoming Proposer)

  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                                                         │
  │  1. LISTEN               2. DETECT               3. ACTIVATE            │
  │  ┌──────────────┐       ┌──────────────┐       ┌──────────────┐        │
  │  │ Watch L1 for │ ────▶ │ NetworkRota  │ ────▶ │ Start op-    │        │
  │  │ rotation tx  │       │ ted event    │       │ node/batcher │        │
  │  └──────────────┘       └──────────────┘       └──────────────┘        │
  │                                                       │                 │
  │                                                       ▼                 │
  │                                               ┌───────────────┐         │
  │                                               │ Begin signing │         │
  │                                               │ unsafe blocks │         │
  │                                               └───────────────┘         │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘
```

### The 3-Phase State Machine

| Phase | Time Window | Agent Behavior |
|-------|-------------|----------------|
| **1 - Protected** | `0` → `epochDuration` | Produce blocks normally |
| **2 - Voluntary** | `epochDuration` → `+GRACE_PERIOD` | Stop sequencing, flush batches, call `rotateNetwork()` |
| **3 - Forced** | After Phase 2 | (Fallback) Keepers can force rotation |

**GRACE_PERIOD = 600 seconds (10 minutes)**

The grace period ensures the outgoing proposer can flush all pending batches to L1 before triggering rotation, preventing any transaction orphaning.

## How It Works

```
┌───────────────────────────────────────────────────────────────────────────┐
│                         KSSN Proposer Agent                               │
│                                                                           │
│   STATE: INACTIVE                  STATE: ACTIVE                          │
│  ┌───────────────┐               ┌───────────────────────────────────┐   │
│  │ Watch L1 for  │               │ 1. Produce blocks (op-node)       │   │
│  │ NetworkRota-  │               │ 2. Batch to L1 (op-batcher)       │   │
│  │ ted event     │               │ 3. Monitor epoch countdown        │   │
│  └───────┬───────┘               └───────────────┬───────────────────┘   │
│          │                                       │                        │
│          │ Became current proposer               │ Epoch ending           │
│          ▼                                       ▼                        │
│  ┌───────────────┐               ┌───────────────────────────────────┐   │
│  │ START op-node │               │ ACTIVE HANDOFF:                   │   │
│  │ START batcher │               │ 1. Stop sequencing                │   │
│  │ Begin signing │               │ 2. Flush batches to L1            │   │
│  └───────────────┘               │ 3. Call rotateNetwork()           │   │
│                                  │ 4. Stop services                  │   │
│                                  └───────────────────────────────────┘   │
│                                                                           │
│   Contract Calls:                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐     │
│  │              SharedSequencerHub                                  │     │
│  │  isCurrentProposer(address) → bool                               │     │
│  │  epochDuration() → uint256                                       │     │
│  │  lastRotationTimestamp() → uint256                               │     │
│  │  rotateNetwork() → (callable during grace period)                │     │
│  └─────────────────────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────────────────────┘
```

## Installation

```bash
cd agent
pip install -r requirements.txt
```

## Configuration

1. Copy the example configuration:
```bash
cp kssn_config.example.yaml kssn_config.yaml
```

2. Edit `kssn_config.yaml` with your proposer's details:
```yaml
l1_rpc: "https://mainnet.infura.io/v3/YOUR_KEY"
hub_address: "0x..."                    # SharedSequencerHub address
proposer_address: "0x..."               # Your registered proposer address
private_key: "0x..."                    # Key for calling rotateNetwork()
poll_interval: 12                       # Seconds between L1 checks
op_node_admin_url: "http://localhost:7545"
op_batcher_admin_url: "http://localhost:7546"
handoff_lead_time: 60                   # Start handoff this early (seconds)
flush_timeout: 300                      # Max flush wait time (seconds)
```

## Usage

```bash
# Run the agent
python kssn_proposer_agent.py --config kssn_config.yaml

# With debug logging
python kssn_proposer_agent.py --config kssn_config.yaml --debug
```

## OP Stack Service Configuration

Your OP Stack services must be configured to start in "stopped" mode and expose admin APIs:

### op-node
```bash
op-node \
  --sequencer.enabled=true \
  --sequencer.stopped=true \
  --rpc.admin-addr=0.0.0.0 \
  --rpc.admin-port=7545 \
  ...
```

### op-batcher
```bash
op-batcher \
  --stopped=true \
  --rpc.admin-addr=0.0.0.0 \
  --rpc.admin-port=7546 \
  ...
```

## Running as a Service

For production, run the agent as a systemd service:

```ini
# /etc/systemd/system/kssn-proposer.service
[Unit]
Description=KSSN Proposer Agent
After=network.target

[Service]
Type=simple
User=op
WorkingDirectory=/opt/kssn/agent
ExecStart=/usr/bin/python3 kssn_proposer_agent.py --config /etc/kssn/agent-config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable kssn-proposer
sudo systemctl start kssn-proposer
```

## Security Considerations

1. **Keep your keys secure** - The agent needs access to a key that can call `rotateNetwork()`
2. **Restrict admin API access** - Only expose op-node/op-batcher admin APIs to localhost
3. **Monitor agent health** - Set up alerts if the agent fails to start/stop services or execute handoff
4. **Constitutional compliance** - Failure to run this agent or execute Active Handoff is a constitutional violation
5. **Handoff timing** - Ensure reliable L1 connectivity during epoch transitions to avoid missing the grace period

## Troubleshooting

**Agent cannot connect to L1 RPC:**
- Check your `l1_rpc` URL
- Ensure your RPC endpoint is accessible

**Agent cannot control op-node/op-batcher:**
- Verify the admin URLs are correct
- Check that services are running with `--sequencer.stopped=true` (op-node) or `--stopped=true` (op-batcher)
- Ensure admin RPC is enabled with `--rpc.admin-addr` and `--rpc.admin-port`

**Agent shows "not active" but should be:**
- Verify your `proposer_address` matches exactly what's registered in ProposerRegistry
- Check that you're in the active proposer set (top-N by stake)

**Handoff failed - rotateNetwork() reverted:**
- Ensure you're calling during the grace period (after epoch ends, within 10 minutes)
- Verify you are the current proposer
- Check if the grace period has already expired (Phase 3 - anyone can rotate)

**Batch flush taking too long:**
- Increase `flush_timeout` in config
- Check op-batcher logs for L1 transaction issues
- Verify L1 gas prices aren't causing transaction delays

**Missed the grace period:**
- If a keeper forced rotation, your unflushed batches may have been orphaned
- Review logs to understand why handoff didn't complete in time
- Consider increasing `handoff_lead_time` to start the process earlier
