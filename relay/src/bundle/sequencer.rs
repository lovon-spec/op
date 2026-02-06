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
///
/// When an `AtomicExecutorConfig` is provided, the sequencer routes all bundle
/// operations through the `AtomicBundleExecutor` contract on each chain. This
/// ensures that execution outcomes are recorded on-chain via `BundleResult` events,
/// enabling L1 fraud proofs for atomicity violations.
///
/// Atomicity enforcement flow:
/// 1. Sequencer receives bundle with operations for chains A and B
/// 2. Sequencer simulates all operations off-chain
/// 3. If any operation would fail, the ENTIRE bundle is rejected (not included on any chain)
/// 4. If all succeed, operations are wrapped in AtomicBundleExecutor.executeBundle() calls
/// 5. After execution, BundleResult events are monitored for consistency
/// 6. If results diverge (e.g., success on A, failure on B), a fraud proof can be filed
#[derive(Clone)]
pub struct BundleSequencer {
    config: BundleConfig,
    validator: BundleValidator,
    chain_manager: ChainManager,
    policy_engine: PolicyEngine,
    pending_bundles: Arc<RwLock<HashMap<alloy_primitives::B256, CrossChainBundle>>>,
    /// Per-chain execution results from AtomicBundleExecutor (for atomicity monitoring)
    execution_results: Arc<RwLock<HashMap<alloy_primitives::B256, Vec<ChainExecutionResult>>>>,
    /// AtomicBundleExecutor addresses per chain
    executor_config: Option<AtomicExecutorConfig>,
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
            execution_results: Arc::new(RwLock::new(HashMap::new())),
            executor_config: None,
            nonce: Arc::new(RwLock::new(0)),
        }
    }

    /// Create a sequencer with AtomicBundleExecutor support.
    pub fn with_executor_config(
        config: BundleConfig,
        chain_manager: ChainManager,
        policy_engine: PolicyEngine,
        executor_config: AtomicExecutorConfig,
    ) -> Self {
        let validator = BundleValidator::new(config.clone());
        Self {
            config,
            validator,
            chain_manager,
            policy_engine,
            pending_bundles: Arc::new(RwLock::new(HashMap::new())),
            execution_results: Arc::new(RwLock::new(HashMap::new())),
            executor_config: Some(executor_config),
            nonce: Arc::new(RwLock::new(0)),
        }
    }

    /// Get the AtomicBundleExecutor address for a chain.
    pub fn get_executor_address(&self, chain_id: u64) -> Option<&Address> {
        self.executor_config
            .as_ref()
            .and_then(|c| c.executors.get(&chain_id))
    }

    /// Check if AtomicBundleExecutor routing is enabled.
    pub fn is_atomic_execution_enabled(&self) -> bool {
        self.executor_config.is_some()
    }

    /// Record a chain execution result from an AtomicBundleExecutor BundleResult event.
    pub async fn record_execution_result(
        &self,
        bundle_id: &alloy_primitives::B256,
        result: ChainExecutionResult,
    ) {
        let mut results = self.execution_results.write().await;
        let entry = results.entry(*bundle_id).or_insert_with(Vec::new);

        // Check for atomicity violation: if any existing result has a different success status
        let has_mismatch = entry.iter().any(|r| r.success != result.success);
        if has_mismatch {
            warn!(
                bundle_id = %bundle_id,
                chain_id = result.chain_id,
                success = result.success,
                "ATOMICITY VIOLATION DETECTED: mismatched BundleResult across chains"
            );
        }

        entry.push(result);
    }

    /// Get execution results for a bundle (for atomicity monitoring).
    pub async fn get_execution_results(
        &self,
        bundle_id: &alloy_primitives::B256,
    ) -> Option<Vec<ChainExecutionResult>> {
        let results = self.execution_results.read().await;
        results.get(bundle_id).cloned()
    }

    /// Check if a bundle has an atomicity violation (mismatched results across chains).
    pub async fn has_atomicity_violation(
        &self,
        bundle_id: &alloy_primitives::B256,
    ) -> bool {
        let results = self.execution_results.read().await;
        if let Some(chain_results) = results.get(bundle_id) {
            if chain_results.len() < 2 {
                return false;
            }
            let first_status = chain_results[0].success;
            chain_results.iter().any(|r| r.success != first_status)
        } else {
            false
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

    #[error("Atomicity violation: mismatched results across chains for bundle {0}")]
    AtomicityViolation(String),

    #[error("No executor configured for chain {0}")]
    NoExecutorForChain(u64),
}
