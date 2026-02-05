//! Bundle validation logic.

use super::types::{CrossChainBundle, ValidationResult};
use crate::config::BundleConfig;

/// Validates cross-chain bundles before sequencing.
#[derive(Debug, Clone)]
pub struct BundleValidator {
    config: BundleConfig,
}

impl BundleValidator {
    pub fn new(config: BundleConfig) -> Self {
        Self { config }
    }

    /// Validate a bundle for correctness and policy compliance.
    pub fn validate(&self, bundle: &CrossChainBundle) -> ValidationResult {
        let mut errors = Vec::new();

        // Check operation count
        if bundle.operations.is_empty() {
            errors.push("Bundle has no operations".to_string());
        }

        if bundle.operations.len() > self.config.max_operations_per_bundle {
            errors.push(format!(
                "Too many operations: {} (max {})",
                bundle.operations.len(),
                self.config.max_operations_per_bundle
            ));
        }

        // Check deadline
        let now = chrono::Utc::now().timestamp() as u64;
        if bundle.deadline <= now + self.config.min_deadline_seconds {
            errors.push(format!(
                "Deadline too soon: must be at least {} seconds from now",
                self.config.min_deadline_seconds
            ));
        }

        if bundle.deadline > now + self.config.max_deadline_seconds {
            errors.push(format!(
                "Deadline too far: must be within {} seconds",
                self.config.max_deadline_seconds
            ));
        }

        // Check chain count
        let target_chains = bundle.extract_target_chains();
        if target_chains.is_empty() {
            errors.push("No target chains in operations".to_string());
        }

        // Check for duplicate tx hashes within same chain
        let mut seen = std::collections::HashSet::new();
        for op in &bundle.operations {
            let key = (op.chain_id, op.tx_hash);
            if !seen.insert(key) {
                errors.push(format!(
                    "Duplicate tx hash {} on chain {}",
                    op.tx_hash, op.chain_id
                ));
            }
        }

        // Check gas limits
        for op in &bundle.operations {
            if op.gas_limit == 0 {
                errors.push(format!(
                    "Zero gas limit for operation on chain {}",
                    op.chain_id
                ));
            }
        }

        // Check ordering indices per chain
        let mut chain_indices: std::collections::HashMap<u64, Vec<u64>> =
            std::collections::HashMap::new();
        for op in &bundle.operations {
            chain_indices
                .entry(op.chain_id)
                .or_default()
                .push(op.index);
        }
        for (chain_id, mut indices) in chain_indices {
            indices.sort();
            for (i, idx) in indices.iter().enumerate() {
                if *idx != i as u64 {
                    errors.push(format!(
                        "Non-contiguous indices on chain {}: expected {}, got {}",
                        chain_id, i, idx
                    ));
                    break;
                }
            }
        }

        ValidationResult {
            valid: errors.is_empty(),
            errors,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundle::types::BundleOperation;
    use alloy_primitives::{Address, B256, U256};

    fn test_config() -> BundleConfig {
        BundleConfig {
            max_pending_bundles: 100,
            max_operations_per_bundle: 64,
            min_deadline_seconds: 30,
            max_deadline_seconds: 3600,
            validation_timeout_ms: 5000,
            hub_address: String::new(),
            bundle_registry_address: String::new(),
        }
    }

    fn make_bundle(ops: Vec<BundleOperation>, deadline_offset: u64) -> CrossChainBundle {
        let now = chrono::Utc::now().timestamp() as u64;
        CrossChainBundle {
            bundle_id: None,
            operations: ops,
            target_chain_ids: vec![],
            deadline: now + deadline_offset,
            tip: U256::ZERO,
            submitter: Address::ZERO,
            status: crate::bundle::types::BundleStatus::Pending,
        }
    }

    #[test]
    fn test_empty_bundle_invalid() {
        let validator = BundleValidator::new(test_config());
        let bundle = make_bundle(vec![], 60);
        let result = validator.validate(&bundle);
        assert!(!result.valid);
        assert!(result.errors.iter().any(|e| e.contains("no operations")));
    }

    #[test]
    fn test_valid_bundle() {
        let validator = BundleValidator::new(test_config());
        let ops = vec![
            BundleOperation {
                chain_id: 10,
                tx_hash: B256::from([1u8; 32]),
                index: 0,
                gas_limit: 100_000,
                raw_tx: vec![],
            },
            BundleOperation {
                chain_id: 42161,
                tx_hash: B256::from([2u8; 32]),
                index: 0,
                gas_limit: 200_000,
                raw_tx: vec![],
            },
        ];
        let bundle = make_bundle(ops, 60);
        let result = validator.validate(&bundle);
        assert!(result.valid, "Errors: {:?}", result.errors);
    }

    #[test]
    fn test_deadline_too_soon() {
        let validator = BundleValidator::new(test_config());
        let ops = vec![BundleOperation {
            chain_id: 10,
            tx_hash: B256::from([1u8; 32]),
            index: 0,
            gas_limit: 100_000,
            raw_tx: vec![],
        }];
        let bundle = make_bundle(ops, 5); // only 5 seconds, needs 30
        let result = validator.validate(&bundle);
        assert!(!result.valid);
        assert!(result.errors.iter().any(|e| e.contains("Deadline too soon")));
    }
}
