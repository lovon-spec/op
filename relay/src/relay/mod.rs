//! HTTP relay server.
//!
//! Provides the API for:
//! - Bundle submission (POST /bundles)
//! - Bundle status (GET /bundles/:id)
//! - Chain info (GET /chains)
//! - Health check (GET /health)
//!
//! The relay integrates with MEV-Boost for block building auctions
//! and Flashblocks for sub-block streaming.

use std::sync::Arc;

use anyhow::Result;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tracing::info;

use crate::bundle::{BundleSequencer, CrossChainBundle};
use crate::config::RelayServerConfig;

/// The relay HTTP server.
pub struct RelayServer {
    config: RelayServerConfig,
    sequencer: BundleSequencer,
}

/// Shared state for handlers.
struct AppState {
    sequencer: BundleSequencer,
}

/// Bundle submission request.
#[derive(Debug, Deserialize)]
struct SubmitBundleRequest {
    bundle: CrossChainBundle,
}

/// Bundle submission response.
#[derive(Debug, Serialize)]
struct SubmitBundleResponse {
    bundle_id: String,
    operations_hash: String,
    deadline: u64,
    status: String,
}

/// Bundle status response.
#[derive(Debug, Serialize)]
struct BundleStatusResponse {
    bundle_id: String,
    status: String,
}

/// Health check response.
#[derive(Debug, Serialize)]
struct HealthResponse {
    status: String,
    version: String,
    pending_bundles: usize,
}

/// Error response.
#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
}

impl RelayServer {
    pub fn new(config: RelayServerConfig, sequencer: BundleSequencer) -> Self {
        Self { config, sequencer }
    }

    pub async fn run(self) -> Result<()> {
        let state = Arc::new(AppState {
            sequencer: self.sequencer,
        });

        let app = Router::new()
            .route("/health", get(health_handler))
            .route("/bundles", post(submit_bundle_handler))
            .route("/bundles/{id}", get(bundle_status_handler))
            .with_state(state);

        let listener = tokio::net::TcpListener::bind(&self.config.listen_addr).await?;
        info!("Relay server listening on {}", self.config.listen_addr);

        axum::serve(listener, app).await?;

        Ok(())
    }
}

async fn health_handler(
    State(state): State<Arc<AppState>>,
) -> Json<HealthResponse> {
    let pending = state.sequencer.pending_count().await;
    Json(HealthResponse {
        status: "ok".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        pending_bundles: pending,
    })
}

async fn submit_bundle_handler(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SubmitBundleRequest>,
) -> Result<Json<SubmitBundleResponse>, (StatusCode, Json<ErrorResponse>)> {
    match state.sequencer.submit_bundle(request.bundle).await {
        Ok(commitment) => Ok(Json(SubmitBundleResponse {
            bundle_id: format!("{}", commitment.bundle_id),
            operations_hash: format!("{}", commitment.operations_hash),
            deadline: commitment.deadline,
            status: "committed".to_string(),
        })),
        Err(e) => Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}

async fn bundle_status_handler(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<BundleStatusResponse>, (StatusCode, Json<ErrorResponse>)> {
    // Parse bundle ID
    let bundle_id = id
        .parse::<alloy_primitives::B256>()
        .map_err(|_| {
            (
                StatusCode::BAD_REQUEST,
                Json(ErrorResponse {
                    error: "Invalid bundle ID".to_string(),
                }),
            )
        })?;

    match state.sequencer.get_bundle_status(&bundle_id).await {
        Some(status) => Ok(Json(BundleStatusResponse {
            bundle_id: id,
            status: format!("{:?}", status),
        })),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ErrorResponse {
                error: "Bundle not found".to_string(),
            }),
        )),
    }
}
