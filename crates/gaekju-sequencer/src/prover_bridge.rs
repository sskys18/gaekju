use tokio::sync::mpsc;
use tracing::info;

use crate::actor::Batch;

pub fn channel() -> (mpsc::Sender<Batch>, mpsc::Receiver<Batch>) {
    mpsc::channel(128)
}

pub async fn run_mock_prover(mut rx: mpsc::Receiver<Batch>) {
    while let Some(batch) = rx.recv().await {
        info!(
            batch_nonce = batch.header.batch_nonce,
            "mock prover queued batch"
        );
    }
}
