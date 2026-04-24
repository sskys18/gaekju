use alloc::collections::{BTreeMap, VecDeque};
use alloc::vec::Vec;
use core::cmp::Reverse;

use crate::intent::{Price, Qty, Side, TraderId};

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct RestingOrder {
    pub seq_id: u64,
    pub trader: TraderId,
    pub side: Side,
    pub price: Price,
    pub remaining_qty: Qty,
    pub nonce: u64,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Eq, PartialEq, Default)]
pub struct Book {
    pub bids: BTreeMap<Reverse<Price>, VecDeque<RestingOrder>>,
    pub asks: BTreeMap<Price, VecDeque<RestingOrder>>,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Level {
    pub price: Price,
    pub qty: Qty,
}

impl Book {
    pub fn best_bid(&self) -> Option<Price> {
        self.bids.keys().next().map(|price| price.0)
    }

    pub fn best_ask(&self) -> Option<Price> {
        self.asks.keys().next().copied()
    }

    pub fn crosses(&self, side: Side, price: Price) -> bool {
        match side {
            Side::Buy => self.best_ask().is_some_and(|ask| price >= ask),
            Side::Sell => self.best_bid().is_some_and(|bid| price <= bid),
        }
    }

    pub fn add(&mut self, order: RestingOrder) {
        match order.side {
            Side::Buy => self
                .bids
                .entry(Reverse(order.price))
                .or_default()
                .push_back(order),
            Side::Sell => self.asks.entry(order.price).or_default().push_back(order),
        }
    }

    pub fn cancel(&mut self, trader: TraderId, ref_seq_id: u64) -> bool {
        cancel_from_side(&mut self.bids, trader, ref_seq_id)
            || cancel_from_side(&mut self.asks, trader, ref_seq_id)
    }

    pub fn depth(&self, limit: usize) -> (Vec<Level>, Vec<Level>) {
        let bids = self
            .bids
            .iter()
            .take(limit)
            .map(|(price, orders)| Level {
                price: price.0,
                qty: orders.iter().map(|order| order.remaining_qty).sum(),
            })
            .collect();
        let asks = self
            .asks
            .iter()
            .take(limit)
            .map(|(price, orders)| Level {
                price: *price,
                qty: orders.iter().map(|order| order.remaining_qty).sum(),
            })
            .collect();
        (bids, asks)
    }
}

fn cancel_from_side<K: Ord + Copy>(
    side: &mut BTreeMap<K, VecDeque<RestingOrder>>,
    trader: TraderId,
    ref_seq_id: u64,
) -> bool {
    let mut empty_level = None;
    for (price, orders) in side.iter_mut() {
        if let Some(index) = orders
            .iter()
            .position(|order| order.trader == trader && order.seq_id == ref_seq_id)
        {
            orders.remove(index);
            if orders.is_empty() {
                empty_level = Some(*price);
            }
            break;
        }
    }
    if let Some(price) = empty_level {
        side.remove(&price);
        return true;
    }
    false
}
