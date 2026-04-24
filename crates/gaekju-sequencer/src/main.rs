use gaekju_sequencer::batcher;
use gaekju_sequencer::config::Config;
use gaekju_sequencer::persistence::Wal;
use gaekju_sequencer::prover_bridge;
use gaekju_sequencer::rest;
use gaekju_sequencer::ws;
use gaekju_sequencer::SequencerHandle;
use tokio::net::TcpListener;
use tracing::info;

#[tokio::main]
async fn main() -> eyre::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let config = Config::from_env();
    let wal = Wal::open(&config.data_dir).ok();
    let sequencer = SequencerHandle::new(config.clone(), wal);
    let (prover_tx, prover_rx) = prover_bridge::channel();

    tokio::spawn(prover_bridge::run_mock_prover(prover_rx));
    tokio::spawn(batcher::run_batcher(
        config.clone(),
        sequencer.clone(),
        prover_tx,
    ));
    tokio::spawn(ws::run_ws(config.ws_bind, sequencer.clone()));

    let app = rest::router(&config, sequencer.clone());
    let listener = TcpListener::bind(config.bind).await?;
    info!(addr = %config.bind, "sequencer REST listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal(sequencer))
        .await?;
    Ok(())
}

async fn shutdown_signal(sequencer: SequencerHandle) {
    let _ = tokio::signal::ctrl_c().await;
    let _ = sequencer.shutdown().await;
}
