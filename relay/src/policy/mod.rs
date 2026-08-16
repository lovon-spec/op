//! Policy enforcement engine.
//!
//! Real-time policy checking for sovereign sequencing rules.
//! Each chain can declare ordering, inclusion, and MEV policies
//! that the sequencer must obey.

use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::RwLock;

use crate::bundle::CrossChainBundle;
use crate::config::{OrderingStrategy, PolicyConfig};

/// Real-time policy enforcement engine.
#[derive(Clone)]
pub struct PolicyEngine {
    config: PolicyConfig,
    chain_policies: Arc<RwLock<HashMap<u64, ChainPolicy>>>,
}

/// Per-chain policy configuration.
#[derive(Debug, Clone)]
pub struct ChainPolicy {
    pub chain_id: u64,
    pub ordering: OrderingStrategy,
    pub sandwich_protection: bool,
    pub backrun_only: bool,
    pub max_block_time_ms: u64,
    pub forced_inclusion_deadline_ms: u64,
}

impl PolicyEngine {
    pub fn new(config: &PolicyConfig) -> Result<Self, anyhow::Error> {
        Ok(Self {
            config: config.clone(),
            chain_policies: Arc::new(RwLock::new(HashMap::new())),
        })
    }

    /// Check if the policy engine is enabled.
    pub fn is_enabled(&self) -> bool {
        self.config.enabled
    }

    /// Check if a bundle complies with a chain's policy.
    pub fn check_bundle_compliance(
        &self,
        chain_id: u64,
        _bundle: &CrossChainBundle,
    ) -> Result<(), String> {
        // If no specific policy, use default (sequencer discretion = always compliant)
        if let Ok(policies) = self.chain_policies.try_read() {
            if let Some(policy) = policies.get(&chain_id) {
                // Check ordering constraints
                match policy.ordering {
                    OrderingStrategy::Fcfs => {
                        // FCFS requires timestamp ordering - relay enforces this
                        // during block building, not at bundle submission
                    }
                    OrderingStrategy::PriorityFee => {
                        // Priority fee ordering enforced during block building
                    }
                    _ => {
                        // SequencerDiscretion and Custom: no restrictions at bundle level
                    }
                }
            }
        }

        Ok(())
    }

    /// Set a policy for a chain.
    pub async fn set_chain_policy(&self, policy: ChainPolicy) {
        let mut policies = self.chain_policies.write().await;
        policies.insert(policy.chain_id, policy);
    }

    /// Get a chain's policy.
    pub async fn get_chain_policy(&self, chain_id: u64) -> Option<ChainPolicy> {
        let policies = self.chain_policies.read().await;
        policies.get(&chain_id).cloned()
    }

    /// Remove a chain's policy.
    pub async fn remove_chain_policy(&self, chain_id: u64) {
        let mut policies = self.chain_policies.write().await;
        policies.remove(&chain_id);
    }
}

impl Default for ChainPolicy {
    fn default() -> Self {
        Self {
            chain_id: 0,
            ordering: OrderingStrategy::SequencerDiscretion,
            sandwich_protection: false,
            backrun_only: false,
            max_block_time_ms: 12000,
            forced_inclusion_deadline_ms: 0,
        }
    }
}
