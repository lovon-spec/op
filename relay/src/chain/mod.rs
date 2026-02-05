//! Chain adapter module.
//!
//! Provides a unified interface for interacting with different chain types
//! (OP Stack, Arbitrum, generic EVM, Cosmos).

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use tokio::sync::RwLock;

use crate::config::{ChainConfig, ChainType};

/// Manages chain adapters for all connected chains.
#[derive(Clone)]
pub struct ChainManager {
    chains: Arc<RwLock<HashMap<u64, ChainAdapter>>>,
}

/// A chain adapter handles chain-specific operations.
#[derive(Debug, Clone)]
pub struct ChainAdapter {
    pub chain_id: u64,
    pub name: String,
    pub chain_type: ChainType,
    pub rpc_url: String,
    pub ws_url: Option<String>,
}

/// Chain state information.
#[derive(Debug, Clone)]
pub struct ChainState {
    pub chain_id: u64,
    pub latest_block: u64,
    pub latest_block_hash: alloy_primitives::B256,
    pub timestamp: u64,
}

impl ChainManager {
    pub fn new(configs: &[ChainConfig]) -> Result<Self> {
        let mut chains = HashMap::new();

        for config in configs {
            let adapter = ChainAdapter {
                chain_id: config.chain_id,
                name: config.name.clone(),
                chain_type: config.chain_type.clone(),
                rpc_url: config.rpc_url.clone(),
                ws_url: config.ws_url.clone(),
            };
            chains.insert(config.chain_id, adapter);
        }

        Ok(Self {
            chains: Arc::new(RwLock::new(chains)),
        })
    }

    /// Check if a chain is supported.
    pub fn supports_chain(&self, chain_id: u64) -> bool {
        // Use try_read for non-async context
        if let Ok(chains) = self.chains.try_read() {
            chains.contains_key(&chain_id)
        } else {
            false
        }
    }

    /// Get the number of connected chains.
    pub fn chain_count(&self) -> usize {
        if let Ok(chains) = self.chains.try_read() {
            chains.len()
        } else {
            0
        }
    }

    /// Get chain adapter by ID.
    pub async fn get_chain(&self, chain_id: u64) -> Option<ChainAdapter> {
        let chains = self.chains.read().await;
        chains.get(&chain_id).cloned()
    }

    /// Get all chain IDs.
    pub async fn get_chain_ids(&self) -> Vec<u64> {
        let chains = self.chains.read().await;
        chains.keys().copied().collect()
    }

    /// Add a new chain dynamically.
    pub async fn add_chain(&self, config: ChainConfig) {
        let adapter = ChainAdapter {
            chain_id: config.chain_id,
            name: config.name.clone(),
            chain_type: config.chain_type.clone(),
            rpc_url: config.rpc_url.clone(),
            ws_url: config.ws_url.clone(),
        };
        let mut chains = self.chains.write().await;
        chains.insert(config.chain_id, adapter);
    }

    /// Remove a chain.
    pub async fn remove_chain(&self, chain_id: u64) {
        let mut chains = self.chains.write().await;
        chains.remove(&chain_id);
    }
}
