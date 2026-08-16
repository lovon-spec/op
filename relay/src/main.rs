//! ISOCHRON Universal Sequencing Relay
//!
//! Time-sensitive component for cross-chain bundle processing, MEV-Boost relay
//! integration, and Flashblocks streaming. This is the off-chain counterpart
//! to the on-chain ISOCHRON contracts.
//!
//! Architecture:
//! - Bundle Sequencer: Validates, orders, and commits cross-chain bundles
//! - MEV-Boost Relay: Integrates with MEV-Boost for block building auctions
//! - Chain Adapters: Per-chain state tracking and transaction submission
//! - Policy Engine: Enforces sovereign sequencing policies in real-time

mod bundle;
mod chain;
mod config;
mod policy;
mod relay;

use anyhow::Result;
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    info!("Starting ISOCHRON Universal Sequencing Relay v{}", env!("CARGO_PKG_VERSION"));

    // Load configuration
    let config = config::RelayConfig::from_env()?;
    info!("Loaded configuration for {} chains", config.chains.len());

    // Initialize chain adapters
    let chain_manager = chain::ChainManager::new(&config.chains)?;
    info!("Initialized {} chain adapters", chain_manager.chain_count());

    // Initialize policy engine
    let policy_engine = policy::PolicyEngine::new(&config.policy)?;
    info!("Policy engine initialized");

    // Initialize bundle sequencer
    let bundle_sequencer = bundle::BundleSequencer::new(
        config.bundle.clone(),
        chain_manager.clone(),
        policy_engine.clone(),
    );
    info!("Bundle sequencer initialized");

    // Start relay server
    let server = relay::RelayServer::new(config.relay.clone(), bundle_sequencer);
    info!("Starting relay server on {}", config.relay.listen_addr);

    server.run().await?;

    Ok(())
}
