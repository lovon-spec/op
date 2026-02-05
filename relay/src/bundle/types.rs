//! Bundle type definitions.

use alloy_primitives::{Address, B256, U256};
use serde::{Deserialize, Serialize};

/// A single operation within a cross-chain bundle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleOperation {
    /// Target chain ID
    pub chain_id: u64,

    /// Transaction hash
    pub tx_hash: B256,

    /// Ordering index within the bundle for this chain
    pub index: u64,

    /// Gas limit for this operation
    pub gas_limit: u64,

    /// Raw signed transaction bytes
    pub raw_tx: Vec<u8>,
}

/// A cross-chain bundle submitted by a searcher/user.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrossChainBundle {
    /// Unique bundle identifier
    pub bundle_id: Option<B256>,

    /// Ordered operations across chains
    pub operations: Vec<BundleOperation>,

    /// Target chain IDs (deduplicated)
    pub target_chain_ids: Vec<u64>,

    /// Execution deadline (unix timestamp)
    pub deadline: u64,

    /// Tip amount in wei
    pub tip: U256,

    /// Submitter address
    pub submitter: Address,

    /// Bundle status
    pub status: BundleStatus,
}

/// Bundle execution status (mirrors on-chain enum).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum BundleStatus {
    Pending,
    Committed,
    Executed,
    Violated,
    Expired,
    Cancelled,
}

/// Result of bundle validation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationResult {
    pub valid: bool,
    pub errors: Vec<String>,
}

/// Bundle commitment signed by the sequencer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleCommitment {
    /// Bundle ID
    pub bundle_id: B256,

    /// Merkle root of operations
    pub operations_hash: B256,

    /// Target chain IDs
    pub target_chain_ids: Vec<u64>,

    /// Deadline
    pub deadline: u64,

    /// Sequencer signature
    pub signature: Vec<u8>,
}

/// Per-chain execution confirmation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainExecutionConfirmation {
    pub chain_id: u64,
    pub block_number: u64,
    pub tx_inclusion_proof: Vec<u8>,
}

impl CrossChainBundle {
    /// Compute the operations hash (merkle root of operations).
    pub fn compute_operations_hash(&self) -> B256 {
        use sha3::{Digest, Keccak256};

        let mut hasher = Keccak256::new();
        for op in &self.operations {
            hasher.update(op.chain_id.to_be_bytes());
            hasher.update(op.tx_hash.as_slice());
            hasher.update(op.index.to_be_bytes());
            hasher.update(op.gas_limit.to_be_bytes());
        }

        B256::from_slice(&hasher.finalize())
    }

    /// Get unique target chain IDs from operations.
    pub fn extract_target_chains(&self) -> Vec<u64> {
        let mut chains: Vec<u64> = self.operations.iter().map(|op| op.chain_id).collect();
        chains.sort();
        chains.dedup();
        chains
    }
}
