use alloy_primitives::{Address, U256};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Side {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum OrderType {
    Market = 0,
    Limit = 1,
    Ioc = 2,
    Fok = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum OrderStatus {
    Open = 0,
    Filled = 1,
    Cancelled = 2,
    PartiallyFilled = 3,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub order_id: u64,
    pub market_id: u32,
    pub trader: Address,
    pub side: Side,
    pub price: U256,
    pub size: U256,
    pub original_size: U256,
    pub order_type: OrderType,
    pub status: OrderStatus,
    pub reduce_only: bool,
    pub created_at: u64,
    pub updated_at: u64,
}
