use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketConfig {
    pub id: u32,
    pub name: String,
    pub max_leverage: U256,
    pub initial_margin_rate: U256,
    pub maintenance_margin_rate: U256,
    pub tick_size: U256,
    pub lot_size: U256,
    pub max_order_size: U256,
    pub min_order_size: U256,
    pub active: bool,
}
