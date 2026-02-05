//! Bundle sequencing engine.
//!
//! The sequencer is the core component that:
//! 1. Accepts bundles from searchers/users
//! 2. Validates and orders them
//! 3. Creates commitments
//! 4. Tracks execution across chains

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{info, warn};

use super::types::*;
use super::validator::BundleValidator;
use crate::chain::ChainManager;
use crate::config::BundleConfig;
use crate::policy::PolicyEngine;

/// The bundle sequencer processes cross-chain bundles.
#[derive(Clone)]
pub struct BundleSequencer {
    config: BundleConfig,
    validator: BundleValidator,
    chain_manager: ChainManager,
    policy_engine: PolicyEngine,
    pending_bundles: Arc<RwLock<HashMap<alloy_primitives::B256, CrossChainBundle>>>,
    nonce: Arc<RwLock<u64>>,
}

impl BundleSequencer {
    pub fn new(
        config: BundleConfig,
        chain_manager: ChainManager,
        policy_engine: PolicyEngine,
    ) -> Self {
        let validator = BundleValidator::new(config.clone());
        Self {
            config,
            validator,
            chain_manager,
            policy_engine,
            pending_bundles: Arc::new(RwLock::new(HashMap::new())),
            nonce: Arc::new(RwLock::new(0)),
        }
    }

    /// Submit a new cross-chain bundle for sequencing.
    pub async fn submit_bundle(
        &self,
        mut bundle: CrossChainBundle,
    ) -> Result<BundleCommitment, BundleError> {
        // 1. Validate bundle
        let validation = self.validator.validate(&bundle);
        if !validation.valid {
            return Err(BundleError::ValidationFailed(validation.errors.join("; ")));
        }

        // 2. Check chain support
        let target_chains = bundle.extract_target_chains();
        for chain_id in &target_chains {
            if !self.chain_manager.supports_chain(*chain_id) {
                return Err(BundleError::UnsupportedChain(*chain_id));
            }
        }

        // 3. Check policy compliance
        if self.policy_engine.is_enabled() {
            for chain_id in &target_chains {
                if let Err(e) = self.policy_engine.check_bundle_compliance(*chain_id, &bundle) {
                    return Err(BundleError::PolicyViolation(format!(
                        "Chain {}: {}",
                        chain_id, e
                    )));
                }
            }
        }

        // 4. Check pending queue capacity
        let pending = self.pending_bundles.read().await;
        if pending.len() >= self.config.max_pending_bundles {
            return Err(BundleError::QueueFull);
        }
        drop(pending);

        // 5. Generate bundle ID and commitment
        let mut nonce = self.nonce.write().await;
        let bundle_id = self.generate_bundle_id(&bundle, *nonce);
        *nonce += 1;
        drop(nonce);

        bundle.bundle_id = Some(bundle_id);
        bundle.target_chain_ids = target_chains.clone();
        bundle.status = BundleStatus::Committed;

        let operations_hash = bundle.compute_operations_hash();

        // 6. Create commitment
        let commitment = BundleCommitment {
            bundle_id,
            operations_hash,
            target_chain_ids: target_chains,
            deadline: bundle.deadline,
            signature: vec![], // Signing handled by the sequencer's key manager
        };

        // 7. Store in pending queue
        let mut pending = self.pending_bundles.write().await;
        pending.insert(bundle_id, bundle);

        info!(
            bundle_id = %bundle_id,
            chain_count = commitment.target_chain_ids.len(),
            "Bundle committed"
        );

        Ok(commitment)
    }

    /// Get the status of a bundle.
    pub async fn get_bundle_status(&self, bundle_id: &alloy_primitives::B256) -> Option<BundleStatus> {
        let pending = self.pending_bundles.read().await;
        pending.get(bundle_id).map(|b| b.status)
    }

    /// Confirm execution on a specific chain.
    pub async fn confirm_chain_execution(
        &self,
        bundle_id: &alloy_primitives::B256,
        confirmation: ChainExecutionConfirmation,
    ) -> Result<(), BundleError> {
        let mut pending = self.pending_bundles.write().await;
        let bundle = pending
            .get_mut(bundle_id)
            .ok_or(BundleError::NotFound)?;

        if bundle.status != BundleStatus::Committed {
            return Err(BundleError::InvalidStatus);
        }

        info!(
            bundle_id = %bundle_id,
            chain_id = confirmation.chain_id,
            block = confirmation.block_number,
            "Chain execution confirmed"
        );

        // Check if all chains are confirmed (simplified)
        // In production, this would track per-chain confirmations
        Ok(())
    }

    /// Get pending bundle count.
    pub async fn pending_count(&self) -> usize {
        self.pending_bundles.read().await.len()
    }

    /// Clean expired bundles.
    pub async fn clean_expired(&self) {
        let now = chrono::Utc::now().timestamp() as u64;
        let mut pending = self.pending_bundles.write().await;
        let expired: Vec<alloy_primitives::B256> = pending
            .iter()
            .filter(|(_, b)| b.deadline < now && b.status == BundleStatus::Committed)
            .map(|(id, _)| *id)
            .collect();

        for id in &expired {
            if let Some(bundle) = pending.get_mut(id) {
                bundle.status = BundleStatus::Expired;
                warn!(bundle_id = %id, "Bundle expired");
            }
        }
    }

    fn generate_bundle_id(&self, bundle: &CrossChainBundle, nonce: u64) -> alloy_primitives::B256 {
        use sha3::{Digest, Keccak256};

        let mut hasher = Keccak256::new();
        hasher.update(bundle.compute_operations_hash().as_slice());
        hasher.update(bundle.submitter.as_slice());
        hasher.update(nonce.to_be_bytes());
        hasher.update(bundle.deadline.to_be_bytes());

        alloy_primitives::B256::from_slice(&hasher.finalize())
    }
}

/// Bundle processing errors.
#[derive(Debug, thiserror::Error)]
pub enum BundleError {
    #[error("Bundle validation failed: {0}")]
    ValidationFailed(String),

    #[error("Unsupported chain: {0}")]
    UnsupportedChain(u64),

    #[error("Policy violation: {0}")]
    PolicyViolation(String),

    #[error("Pending queue is full")]
    QueueFull,

    #[error("Bundle not found")]
    NotFound,

    #[error("Invalid bundle status")]
    InvalidStatus,
}
