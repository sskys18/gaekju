use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use alloy_primitives::Address;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use gaekju_matching_core::{Intent, Reject, SignatureBytes};
use serde::{Deserialize, Serialize};

use crate::actor::{Ack, BatchStatus, BookSnapshot, SequencerHandle, TraderSnapshot};
use crate::config::Config;

static INTENTS_ACCEPTED: AtomicU64 = AtomicU64::new(0);
static INTENTS_REJECTED: AtomicU64 = AtomicU64::new(0);
static BATCHES_EMITTED: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
pub struct AppState {
    pub sequencer: SequencerHandle,
    pub started: Instant,
    pub limiter: Arc<Mutex<BTreeMap<Address, (Instant, u32)>>>,
    pub per_eoa_limit: u32,
}

#[derive(Debug, Deserialize)]
pub struct IntentRequest {
    pub intent: Intent,
    pub sig: SignatureBytes,
}

#[derive(Debug, Serialize)]
pub struct IntentResponse {
    pub status: &'static str,
    pub fills: Vec<gaekju_matching_core::Fill>,
    pub seq_id: Option<u64>,
    pub reason: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DepthQuery {
    pub depth: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct TradesQuery {
    pub since: Option<usize>,
}

#[derive(Debug, Serialize)]
pub struct Status {
    pub healthy: bool,
    pub uptime_secs: u64,
    pub last_batch: Option<BatchStatus>,
    pub prover_lag: u64,
}

pub fn router(config: &Config, sequencer: SequencerHandle) -> Router {
    let state = AppState {
        sequencer,
        started: Instant::now(),
        limiter: Arc::new(Mutex::new(BTreeMap::new())),
        per_eoa_limit: config.rest_rate_limit_per_eoa,
    };
    Router::new()
        .route("/v1/intent", post(post_intent))
        .route("/v1/book/{market}", get(get_book))
        .route("/v1/trades/{market}", get(get_trades))
        .route("/v1/trader/{addr}", get(get_trader))
        .route("/v1/batch/{nonce}", get(get_batch))
        .route("/v1/status", get(get_status))
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/metrics", get(metrics))
        .route("/openapi.json", get(openapi))
        .with_state(state)
}

async fn post_intent(
    State(state): State<AppState>,
    Json(req): Json<IntentRequest>,
) -> (StatusCode, Json<IntentResponse>) {
    if !allow(&state, req.intent.trader) {
        INTENTS_REJECTED.fetch_add(1, Ordering::Relaxed);
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(IntentResponse {
                status: "rejected",
                fills: Vec::new(),
                seq_id: None,
                reason: Some("RateLimited".to_owned()),
            }),
        );
    }
    match state.sequencer.submit_intent(req.intent, req.sig).await {
        Ok(Ack { seq_id, fills }) => {
            INTENTS_ACCEPTED.fetch_add(1, Ordering::Relaxed);
            (
                StatusCode::OK,
                Json(IntentResponse {
                    status: "accepted",
                    fills,
                    seq_id: Some(seq_id),
                    reason: None,
                }),
            )
        }
        Err(err) => {
            INTENTS_REJECTED.fetch_add(1, Ordering::Relaxed);
            (
                StatusCode::BAD_REQUEST,
                Json(IntentResponse {
                    status: "rejected",
                    fills: Vec::new(),
                    seq_id: None,
                    reason: Some(reject_label(err).to_owned()),
                }),
            )
        }
    }
}

async fn get_book(
    State(state): State<AppState>,
    Path(market): Path<u64>,
    Query(query): Query<DepthQuery>,
) -> Json<BookSnapshot> {
    Json(
        state
            .sequencer
            .book(market, query.depth.unwrap_or(20).min(200))
            .await
            .unwrap_or(BookSnapshot {
                bids: Vec::new(),
                asks: Vec::new(),
            }),
    )
}

async fn get_trades(
    State(state): State<AppState>,
    Path(market): Path<u64>,
    Query(query): Query<TradesQuery>,
) -> Json<Vec<gaekju_matching_core::Fill>> {
    Json(
        state
            .sequencer
            .recent_trades(market, query.since.unwrap_or_default())
            .await
            .unwrap_or_default(),
    )
}

async fn get_trader(
    State(state): State<AppState>,
    Path(addr): Path<Address>,
) -> Result<Json<TraderSnapshot>, StatusCode> {
    state
        .sequencer
        .trader(addr)
        .await
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

async fn get_batch(
    State(state): State<AppState>,
    Path(nonce): Path<u64>,
) -> Result<Json<BatchStatus>, StatusCode> {
    state
        .sequencer
        .batch_status(nonce)
        .await
        .flatten()
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

async fn get_status(State(state): State<AppState>) -> Json<Status> {
    Json(Status {
        healthy: true,
        uptime_secs: state.started.elapsed().as_secs(),
        last_batch: state.sequencer.batch_status(u64::MAX).await.flatten(),
        prover_lag: 0,
    })
}

async fn healthz() -> &'static str {
    "ok\n"
}

async fn readyz() -> &'static str {
    "ready\n"
}

async fn metrics() -> String {
    format!(
        concat!(
            "intents_accepted_total {}\n",
            "intents_rejected_total {}\n",
            "batches_emitted_total {}\n",
            "actor_queue_depth 0\n",
            "match_latency_ms 0\n"
        ),
        INTENTS_ACCEPTED.load(Ordering::Relaxed),
        INTENTS_REJECTED.load(Ordering::Relaxed),
        BATCHES_EMITTED.load(Ordering::Relaxed),
    )
}

async fn openapi() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "openapi": "3.1.0",
        "info": {"title": "Gaekju Sequencer", "version": "0.1.0"},
        "paths": {
            "/v1/intent": {"post": {"summary": "Submit signed intent"}},
            "/v1/book/{market}": {"get": {"summary": "Depth snapshot"}},
            "/v1/trades/{market}": {"get": {"summary": "Recent fills"}},
            "/v1/trader/{addr}": {"get": {"summary": "Trader state"}},
            "/v1/batch/{nonce}": {"get": {"summary": "Batch status"}},
            "/v1/status": {"get": {"summary": "Sequencer status"}}
        }
    }))
}

fn allow(state: &AppState, trader: Address) -> bool {
    let mut limiter = state.limiter.lock().expect("rate limiter lock");
    let now = Instant::now();
    let entry = limiter.entry(trader).or_insert((now, 0));
    if now.duration_since(entry.0) >= Duration::from_secs(1) {
        *entry = (now, 0);
    }
    if entry.1 >= state.per_eoa_limit {
        return false;
    }
    entry.1 += 1;
    true
}

fn reject_label(reject: Reject) -> &'static str {
    match reject {
        Reject::DuplicateOfForced => "DuplicateOfForced",
        Reject::Expired => "Expired",
        Reject::InvalidQuantity => "InvalidQuantity",
        Reject::InvalidPrice => "InvalidPrice",
        Reject::NonceNotMonotonic => "NonceNotMonotonic",
        Reject::PostOnlyWouldCross => "PostOnlyWouldCross",
        Reject::FokWouldNotFill => "FokWouldNotFill",
        Reject::ReduceOnlyWouldIncrease => "ReduceOnlyWouldIncrease",
        Reject::InsufficientMargin => "InsufficientMargin",
        Reject::UnknownOrder => "UnknownOrder",
    }
}
