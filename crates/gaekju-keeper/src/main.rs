mod liquidator;
mod tx;

use alloy::primitives::{Address, U256};
use eyre::Result;
use std::env;
use std::sync::Arc;
use std::time::Duration;
use tracing_subscriber::EnvFilter;

use crate::liquidator::Liquidator;
use crate::tx::TxManager;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("gaekju_keeper=info".parse()?))
        .init();

    let rpc_url = env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string());
    let private_key = env::var("KEEPER_PRIVATE_KEY").expect("KEEPER_PRIVATE_KEY must be set");
    let le_addr: Address = env::var("LIQUIDATION_ENGINE")
        .expect("LIQUIDATION_ENGINE must be set")
        .parse()?;
    let pm_addr: Address = env::var("POSITION_MANAGER")
        .expect("POSITION_MANAGER must be set")
        .parse()?;

    let poll_ms: u64 = env::var("POLL_INTERVAL_MS")
        .unwrap_or_else(|_| "2000".to_string())
        .parse()?;

    let market_ids: Vec<U256> = env::var("MARKET_IDS")
        .unwrap_or_else(|_| "0".to_string())
        .split(',')
        .map(|s| U256::from(s.trim().parse::<u64>().unwrap_or(0)))
        .collect();

    let tx_manager = Arc::new(TxManager::new(&rpc_url, &private_key).await?);

    let liquidator = Liquidator::new(
        tx_manager,
        le_addr,
        pm_addr,
        market_ids,
        Duration::from_millis(poll_ms),
    );

    liquidator.run().await
}
