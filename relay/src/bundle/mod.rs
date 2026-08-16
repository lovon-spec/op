//! Cross-chain bundle processing module.
//!
//! Handles the full lifecycle of cross-chain bundles:
//! 1. Validation: Verify bundle operations are well-formed
//! 2. Ordering: Sequence operations across chains
//! 3. Commitment: Sign and post commitments on-chain
//! 4. Tracking: Monitor execution across all target chains

mod sequencer;
mod types;
mod validator;

pub use sequencer::BundleSequencer;
pub use types::*;
pub use validator::BundleValidator;
