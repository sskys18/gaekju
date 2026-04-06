use alloy_primitives::{Address, I256, U256};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Position {
    pub account: Address,
    pub market_id: u32,
    pub size: I256,
    pub entry_price: U256,
    pub collateral: U256,
    pub last_cumulative_funding: I256,
    pub last_updated: u64,
}
