//! Configuration for the ISOCHRON relay.

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// Top-level relay configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayConfig {
    pub relay: RelayServerConfig,
    pub bundle: BundleConfig,
    pub chains: Vec<ChainConfig>,
    pub policy: PolicyConfig,
}

/// Relay HTTP server configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayServerConfig {
    /// Address to listen on (e.g., "0.0.0.0:8545")
    pub listen_addr: String,

    /// Maximum request body size in bytes
    pub max_body_size: usize,

    /// MEV-Boost relay endpoint (for block building auctions)
    pub mev_boost_endpoint: Option<String>,

    /// Flashblocks streaming endpoint
    pub flashblocks_endpoint: Option<String>,
}

/// Bundle processing configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleConfig {
    /// Maximum bundles in the pending queue
    pub max_pending_bundles: usize,

    /// Maximum operations per bundle
    pub max_operations_per_bundle: usize,

    /// Minimum deadline duration from now (seconds)
    pub min_deadline_seconds: u64,

    /// Maximum deadline duration from now (seconds)
    pub max_deadline_seconds: u64,

    /// Bundle validation timeout (milliseconds)
    pub validation_timeout_ms: u64,

    /// Hub contract address on L1
    pub hub_address: String,

    /// Bundle registry contract address on L1
    pub bundle_registry_address: String,
}

/// Per-chain configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainConfig {
    /// Chain ID
    pub chain_id: u64,

    /// Chain name (human-readable)
    pub name: String,

    /// RPC endpoint for this chain
    pub rpc_url: String,

    /// WebSocket endpoint (for streaming)
    pub ws_url: Option<String>,

    /// Chain type for adapter selection
    pub chain_type: ChainType,

    /// Builder type preference
    pub builder_type: BuilderType,
}

/// Supported chain types.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ChainType {
    /// OP Stack (Bedrock/Ecotone)
    OpStack,
    /// Arbitrum Nitro
    Arbitrum,
    /// Generic EVM rollup
    GenericEvm,
    /// Cosmos/IBC chain (future)
    Cosmos,
}

/// Builder types.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum BuilderType {
    /// Private mempool (MEV-Boost + Flashblocks)
    PrivateMempool,
    /// Public mempool (traditional PBS)
    PublicMempool,
    /// Encrypted mempool (threshold encryption)
    EncryptedMempool,
    /// Custom builder
    Custom,
}

/// Policy engine configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyConfig {
    /// Whether to enable real-time policy checking
    pub enabled: bool,

    /// Policy manager contract address
    pub policy_manager_address: Option<String>,

    /// Default ordering strategy
    pub default_ordering: OrderingStrategy,
}

/// Ordering strategies (mirrors Solidity enum).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum OrderingStrategy {
    SequencerDiscretion,
    PriorityFee,
    Fcfs,
    Custom,
}

impl RelayConfig {
    /// Load configuration from environment or defaults.
    pub fn from_env() -> Result<Self> {
        // Try loading from ISOCHRON_CONFIG env var, fall back to defaults
        if let Ok(path) = std::env::var("ISOCHRON_CONFIG") {
            let content = std::fs::read_to_string(path)?;
            let config: RelayConfig = toml::from_str(&content)?;
            return Ok(config);
        }

        // Default development configuration
        Ok(Self {
            relay: RelayServerConfig {
                listen_addr: "0.0.0.0:8545".to_string(),
                max_body_size: 10 * 1024 * 1024, // 10MB
                mev_boost_endpoint: None,
                flashblocks_endpoint: None,
            },
            bundle: BundleConfig {
                max_pending_bundles: 1000,
                max_operations_per_bundle: 64,
                min_deadline_seconds: 30,
                max_deadline_seconds: 3600,
                validation_timeout_ms: 5000,
                hub_address: String::new(),
                bundle_registry_address: String::new(),
            },
            chains: vec![],
            policy: PolicyConfig {
                enabled: false,
                policy_manager_address: None,
                default_ordering: OrderingStrategy::SequencerDiscretion,
            },
        })
    }
}
