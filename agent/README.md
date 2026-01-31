# Self-Activation Agent

A decentralized agent that monitors on-chain operator status and automatically manages OP Stack services, implementing the **Active Handoff Protocol** for zero-downtime operator transitions.

## Why This Is Required

The Constitutional L2 uses a rotating sequencer model where operators take turns producing blocks. Each operator MUST:

1. **Only produce blocks when authorized** - The on-chain `KlerosSequencerManager` determines who is currently authorized
2. **Actively hand over control at epoch end** - Flush batches and trigger rotation (Active Handoff)
3. **Start automatically when becoming authorized** - To ensure seamless handoffs between operators

This agent watches the on-chain state, controls the local OP Stack services, and **initiates the rotation** when the operator's epoch ends.

## Constitutional Requirement

The L2 constitution includes:

> Operators MUST run a self-activation agent (or equivalent mechanism).
> Operators MUST NOT produce unsafe blocks or attempt batching while unauthorized.
> Operators MUST execute Active Handoff at epoch end (flush batches, trigger rotation).
> Violations are slashable/removable via Kleros enforcement.

## Active Handoff Protocol

The agent implements the **Active Handoff Protocol** to ensure zero-downtime transitions:

```
            ACTIVE HANDOFF SEQUENCE (Outgoing Operator)

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
  │                                                │ Operator()   │         │
  │                                                └──────┬───────┘         │
  │                                                       │                 │
  │                                                       ▼                 │
  │                                               ┌───────────────┐         │
  │                                               │ Handover      │         │
  │                                               │ Complete      │         │
  │                                               └───────────────┘         │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘

            INSTANT ACTIVATION (Incoming Operator)

  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                                                         │
  │  1. LISTEN               2. DETECT               3. ACTIVATE            │
  │  ┌──────────────┐       ┌──────────────┐       ┌──────────────┐        │
  │  │ Watch L1 for │ ────▶ │ OperatorRota │ ────▶ │ Start op-    │        │
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
| **2 - Voluntary** | `epochDuration` → `+GRACE_PERIOD` | Stop sequencing, flush batches, call `rotateOperator()` |
| **3 - Forced** | After Phase 2 | (Fallback) Keepers can force rotation |

**GRACE_PERIOD = 600 seconds (10 minutes)**

The grace period ensures the outgoing operator can flush all pending batches to L1 before triggering rotation, preventing any transaction orphaning.

## How It Works

```
┌───────────────────────────────────────────────────────────────────────────┐
│                         Self-Activation Agent                              │
│                                                                           │
│   STATE: INACTIVE                  STATE: ACTIVE                          │
│  ┌───────────────┐               ┌───────────────────────────────────┐   │
│  │ Watch L1 for  │               │ 1. Produce blocks (op-node)       │   │
│  │ OperatorRota- │               │ 2. Batch to L1 (op-batcher)       │   │
│  │ ted event     │               │ 3. Monitor epoch countdown        │   │
│  └───────┬───────┘               └───────────────┬───────────────────┘   │
│          │                                       │                        │
│          │ Became current operator               │ Epoch ending           │
│          ▼                                       ▼                        │
│  ┌───────────────┐               ┌───────────────────────────────────┐   │
│  │ START op-node │               │ ACTIVE HANDOFF:                   │   │
│  │ START batcher │               │ 1. Stop sequencing                │   │
│  │ Begin signing │               │ 2. Flush batches to L1            │   │
│  └───────────────┘               │ 3. Call rotateOperator()          │   │
│                                  │ 4. Stop services                  │   │
│                                  └───────────────────────────────────┘   │
│                                                                           │
│   Contract Calls:                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐     │
│  │              KlerosSequencerManager                              │     │
│  │  isCurrentOperator(batcher, unsafeSigner) → bool                 │     │
│  │  epochDuration() → uint256                                       │     │
│  │  lastRotationTimestamp() → uint256                               │     │
│  │  rotateOperator() → (callable during grace period)               │     │
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
cp config.example.yaml config.yaml
```

2. Edit `config.yaml` with your operator's details:
```yaml
l1_rpc: "https://mainnet.infura.io/v3/YOUR_KEY"
manager_address: "0x..."
batcher_address: "0x..."           # Your batcher key
unsafe_signer_address: "0x..."     # Your unsafe signer key
poll_interval: 12                  # How often to check L1 state (seconds)
op_node_admin_url: "http://localhost:7545"
op_batcher_admin_url: "http://localhost:7546"

# Active Handoff settings
handoff_lead_time: 60              # Start handoff this many seconds before epoch ends
flush_timeout: 300                 # Max time to wait for batch flush (seconds)
```

## Usage

```bash
# Run the agent
python self_activation_agent.py --config config.yaml

# With debug logging
python self_activation_agent.py --config config.yaml --debug
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
# /etc/systemd/system/op-self-activation.service
[Unit]
Description=Constitutional L2 Self-Activation Agent
After=network.target

[Service]
Type=simple
User=op
WorkingDirectory=/opt/constitutional-l2/agent
ExecStart=/usr/bin/python3 self_activation_agent.py --config /etc/op/agent-config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable op-self-activation
sudo systemctl start op-self-activation
```

## Security Considerations

1. **Keep your keys secure** - The agent needs access to a key that can call `rotateOperator()` (batcher or unsafeSigner)
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
- Verify your `batcher_address` and `unsafe_signer_address` match exactly what's registered in Kleros
- Check that `syncAddOperator()` was called with both addresses

**Handoff failed - rotateOperator() reverted:**
- Ensure you're calling during the grace period (after epoch ends, within 10 minutes)
- Verify the calling address is the current operator's batcher or unsafeSigner
- Check if the grace period has already expired (Phase 3 - anyone can rotate)

**Batch flush taking too long:**
- Increase `flush_timeout` in config
- Check op-batcher logs for L1 transaction issues
- Verify L1 gas prices aren't causing transaction delays

**Missed the grace period:**
- If a keeper forced rotation, your unflushed batches may have been orphaned
- Review logs to understand why handoff didn't complete in time
- Consider increasing `handoff_lead_time` to start the process earlier
