use alloy::primitives::{Address, U256};
use alloy::sol;
use eyre::Result;
use std::sync::Arc;
use std::time::Duration;
use tracing::{error, info, warn};

use crate::tx::TxManager;

sol! {
    #[sol(rpc)]
    interface ILiquidationEngine {
        function isLiquidatable(address account, uint256 marketId) external view returns (bool);
        function liquidate(address account, uint256 marketId) external;
    }

    #[sol(rpc)]
    interface IPositionManager {
        function getPositionHolders(uint256 marketId) external view returns (address[] memory);
        function getPositionCount(uint256 marketId) external view returns (uint256);
    }
}

pub struct Liquidator {
    tx_manager: Arc<TxManager>,
    liquidation_engine: Address,
    position_manager: Address,
    market_ids: Vec<U256>,
    poll_interval: Duration,
}

impl Liquidator {
    pub fn new(
        tx_manager: Arc<TxManager>,
        liquidation_engine: Address,
        position_manager: Address,
        market_ids: Vec<U256>,
        poll_interval: Duration,
    ) -> Self {
        Self {
            tx_manager,
            liquidation_engine,
            position_manager,
            market_ids,
            poll_interval,
        }
    }

    pub async fn run(&self) -> Result<()> {
        info!("liquidation keeper started");
        info!(
            markets = ?self.market_ids,
            engine = ?self.liquidation_engine,
            "monitoring {} markets",
            self.market_ids.len()
        );

        loop {
            if let Err(e) = self.check_and_liquidate().await {
                error!(error = %e, "liquidation check failed");
                if let Err(sync_err) = self.tx_manager.sync_nonce().await {
                    error!(error = %sync_err, "nonce resync failed");
                }
            }
            tokio::time::sleep(self.poll_interval).await;
        }
    }

    async fn check_and_liquidate(&self) -> Result<()> {
        let le = ILiquidationEngine::new(self.liquidation_engine, self.tx_manager.provider.clone());
        let pm = IPositionManager::new(self.position_manager, self.tx_manager.provider.clone());

        for market_id in &self.market_ids {
            let count = pm.getPositionCount(*market_id).call().await?;

            if count.is_zero() {
                continue;
            }

            let holders = pm.getPositionHolders(*market_id).call().await?;

            for account in holders {
                let liquidatable = le.isLiquidatable(account, *market_id).call().await?;

                if liquidatable {
                    info!(
                        account = ?account,
                        market_id = %market_id,
                        "position liquidatable — submitting tx"
                    );

                    match le.liquidate(account, *market_id).send().await {
                        Ok(pending) => match pending.get_receipt().await {
                            Ok(receipt) => {
                                info!(
                                    tx_hash = ?receipt.transaction_hash,
                                    account = ?account,
                                    "liquidation confirmed"
                                );
                            }
                            Err(e) => {
                                warn!(error = %e, account = ?account, "receipt fetch failed");
                            }
                        },
                        Err(e) => {
                            warn!(
                                error = %e,
                                account = ?account,
                                "liquidation tx failed"
                            );
                        }
                    }
                }
            }
        }

        Ok(())
    }
}
