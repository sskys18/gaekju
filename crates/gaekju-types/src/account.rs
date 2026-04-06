use alloy_primitives::{Address, U256};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountBalance {
    pub address: Address,
    pub balance: U256,
    pub locked_margin: U256,
    pub order_margin: U256,
}
