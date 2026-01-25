# Self-Activation Agent

A decentralized agent that monitors on-chain operator status and automatically starts/stops OP Stack services.

## Why This Is Required

The Constitutional L2 uses a rotating sequencer model where operators take turns producing blocks. Each operator MUST:

1. **Only produce blocks when authorized** - The on-chain `KlerosSequencerManager` determines who is currently authorized
2. **Stop producing when no longer authorized** - To avoid competing unsafe heads and wasted resources
3. **Start automatically when becoming authorized** - To ensure smooth handoffs between operators

This agent watches the on-chain state and controls the local OP Stack services accordingly.

## Constitutional Requirement

The L2 constitution includes:

> Operators MUST run a self-activation agent (or equivalent mechanism).
> Operators MUST NOT produce unsafe blocks or attempt batching while unauthorized.
> Violations are slashable/removable via Kleros enforcement.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                     Self-Activation Agent                        │
│                                                                  │
│  ┌──────────────┐     ┌────────────────┐     ┌───────────────┐  │
│  │   L1 RPC     │────▶│ isCurrentOp()  │────▶│ Start/Stop    │  │
│  │  (watch)     │     │ Check          │     │ OP Services   │  │
│  └──────────────┘     └────────────────┘     └───────────────┘  │
│         │                    │                       │          │
│         │                    │                       ▼          │
│         │                    │              ┌───────────────┐   │
│         │                    │              │  op-node      │   │
│         │                    │              │  op-batcher   │   │
│         │                    │              └───────────────┘   │
│         ▼                    ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              KlerosSequencerManager                      │    │
│  │  isCurrentOperator(batcher, unsafeSigner) → bool         │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
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
poll_interval: 12
op_node_admin_url: "http://localhost:7545"
op_batcher_admin_url: "http://localhost:7546"
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

1. **Keep your keys secure** - The agent only needs to READ on-chain state, it does not need access to private keys
2. **Restrict admin API access** - Only expose op-node/op-batcher admin APIs to localhost
3. **Monitor agent health** - Set up alerts if the agent fails to start/stop services
4. **Constitutional compliance** - Failure to run this agent is a constitutional violation

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
