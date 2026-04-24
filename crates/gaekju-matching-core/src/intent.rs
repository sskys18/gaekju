use alloy_primitives::Address;

pub type Price = i128;
pub type Qty = i128;
pub type MarketId = u64;
pub type TraderId = Address;

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Copy, Clone, Eq, PartialEq, Ord, PartialOrd, Hash)]
#[repr(u8)]
pub enum Side {
    Buy = 0,
    Sell = 1,
}

impl Side {
    pub const fn opposite(self) -> Self {
        match self {
            Self::Buy => Self::Sell,
            Self::Sell => Self::Buy,
        }
    }

    pub const fn sign(self) -> i128 {
        match self {
            Self::Buy => 1,
            Self::Sell => -1,
        }
    }
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Copy, Clone, Eq, PartialEq, Ord, PartialOrd, Hash)]
#[repr(u8)]
pub enum TimeInForce {
    Gtc = 0,
    Ioc = 1,
    Fok = 2,
    PostOnly = 3,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Copy, Clone, Eq, PartialEq, Ord, PartialOrd, Hash)]
#[repr(u8)]
pub enum IntentKind {
    Place = 0,
    Cancel = 1,
    ModifyTif = 2,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Intent {
    pub market_id: MarketId,
    pub trader: TraderId,
    pub nonce: u64,
    pub side: Side,
    pub price: Price,
    pub qty: Qty,
    pub tif: TimeInForce,
    pub expiry: u64,
    pub flags: u64,
    pub kind: IntentKind,
    pub ref_seq_id: u64,
}

impl Intent {
    pub const REDUCE_ONLY: u64 = 1;

    pub const fn reduce_only(&self) -> bool {
        self.flags & Self::REDUCE_ONLY != 0
    }
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Fill {
    pub maker: TraderId,
    pub taker: TraderId,
    pub market_id: MarketId,
    pub price: Price,
    pub qty: Qty,
    pub taker_side: Side,
    pub maker_seq_id: u64,
    pub taker_seq_id: u64,
}

impl Fill {
    pub fn base_delta_for(&self, trader: TraderId) -> Qty {
        if trader == self.taker {
            self.qty * self.taker_side.sign()
        } else if trader == self.maker {
            -(self.qty * self.taker_side.sign())
        } else {
            0
        }
    }
}
