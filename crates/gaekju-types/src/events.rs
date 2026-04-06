use alloy_primitives::{Address, U256};
use alloy_sol_types::sol;
use serde::{Deserialize, Serialize};

sol! {
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint256 indexed marketId,
        bool side,
        uint256 price,
        uint256 size,
        uint8 orderType
    );

    event OrderMatched(
        uint256 indexed marketId,
        uint256 makerOrderId,
        uint256 takerOrderId,
        uint256 price,
        uint256 size
    );

    event OrderCancelled(uint256 indexed orderId, address indexed trader);

    event Fill(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 price,
        uint256 size,
        bool takerSide
    );

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event MarginLocked(address indexed account, uint256 amount);
    event MarginUnlocked(address indexed account, uint256 amount);
    event PnlRealized(address indexed account, int256 amount);
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GaekjuEvent {
    OrderPlaced {
        order_id: U256,
        trader: Address,
        market_id: U256,
        side: bool,
        price: U256,
        size: U256,
        order_type: u8,
    },
    OrderMatched {
        market_id: U256,
        maker_order_id: U256,
        taker_order_id: U256,
        price: U256,
        size: U256,
    },
    OrderCancelled {
        order_id: U256,
        trader: Address,
    },
    Fill {
        market_id: U256,
        maker: Address,
        taker: Address,
        price: U256,
        size: U256,
        taker_side: bool,
    },
    Deposited {
        account: Address,
        amount: U256,
    },
    Withdrawn {
        account: Address,
        amount: U256,
    },
}
