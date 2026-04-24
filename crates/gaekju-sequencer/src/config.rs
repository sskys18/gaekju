use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use alloy_primitives::Address;

#[derive(Debug, Clone)]
pub struct Config {
    pub bind: SocketAddr,
    pub ws_bind: SocketAddr,
    pub chain_id: u64,
    pub settlement: Address,
    pub markets: Vec<u64>,
    pub batch_ms: u64,
    pub max_intents_per_batch: usize,
    pub prover_inbox: PathBuf,
    pub data_dir: PathBuf,
    pub snapshot_interval: Duration,
    pub rest_rate_limit_per_eoa: u32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bind: "127.0.0.1:8080".parse().expect("valid default bind"),
            ws_bind: "127.0.0.1:8081".parse().expect("valid default ws bind"),
            chain_id: 31337,
            settlement: Address::ZERO,
            markets: vec![1],
            batch_ms: 5_000,
            max_intents_per_batch: 4096,
            prover_inbox: PathBuf::from("prover/inbox"),
            data_dir: PathBuf::from(".gaekju-sequencer"),
            snapshot_interval: Duration::from_secs(60),
            rest_rate_limit_per_eoa: 20,
        }
    }
}

impl Config {
    pub fn from_env() -> Self {
        let mut config = Self::default();
        if let Ok(bind) = std::env::var("GAEKJU_BIND") {
            config.bind = bind.parse().expect("GAEKJU_BIND must be host:port");
        }
        if let Ok(ws_bind) = std::env::var("GAEKJU_WS_BIND") {
            config.ws_bind = ws_bind.parse().expect("GAEKJU_WS_BIND must be host:port");
        }
        if let Ok(chain_id) = std::env::var("GAEKJU_CHAIN_ID") {
            config.chain_id = chain_id.parse().expect("GAEKJU_CHAIN_ID must be u64");
        }
        if let Ok(settlement) = std::env::var("GAEKJU_SETTLEMENT") {
            config.settlement = settlement
                .parse()
                .expect("GAEKJU_SETTLEMENT must be address");
        }
        if let Ok(markets) = std::env::var("GAEKJU_MARKETS") {
            config.markets = markets
                .split(',')
                .filter(|part| !part.is_empty())
                .map(|part| part.parse().expect("GAEKJU_MARKETS entries must be u64"))
                .collect();
        }
        if let Ok(batch_ms) = std::env::var("GAEKJU_BATCH_MS") {
            config.batch_ms = batch_ms.parse().expect("GAEKJU_BATCH_MS must be u64");
        }
        if let Ok(inbox) = std::env::var("GAEKJU_PROVER_INBOX") {
            config.prover_inbox = PathBuf::from(inbox);
        }
        if let Ok(data_dir) = std::env::var("GAEKJU_DATA_DIR") {
            config.data_dir = PathBuf::from(data_dir);
        }
        config
    }
}
