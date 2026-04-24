use alloc::collections::BTreeMap;
use alloc::vec::Vec;

use crate::book::{Book, RestingOrder};
use crate::intent::{Fill, Intent, IntentKind, MarketId, Price, Qty, Side, TimeInForce, TraderId};

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Copy, Clone, Eq, PartialEq, Default)]
pub struct Position {
    pub size: Qty,
    pub entry_price: Price,
    pub collateral: i128,
    pub last_cumulative_funding: i128,
}

#[derive(Debug, Copy, Clone, Eq, PartialEq, thiserror::Error)]
pub enum Reject {
    #[error("duplicate of forced intent")]
    DuplicateOfForced,
    #[error("expired intent")]
    Expired,
    #[error("invalid quantity")]
    InvalidQuantity,
    #[error("invalid price")]
    InvalidPrice,
    #[error("nonce not monotonic")]
    NonceNotMonotonic,
    #[error("post-only crosses book")]
    PostOnlyWouldCross,
    #[error("fill-or-kill could not fully fill")]
    FokWouldNotFill,
    #[error("reduce-only would increase exposure")]
    ReduceOnlyWouldIncrease,
    #[error("margin check failed")]
    InsufficientMargin,
    #[error("unknown referenced order")]
    UnknownOrder,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Eq, PartialEq, Default)]
pub struct State {
    pub books: BTreeMap<MarketId, Book>,
    pub balances: BTreeMap<TraderId, i128>,
    pub positions: BTreeMap<(TraderId, MarketId), Position>,
    pub nonces: BTreeMap<TraderId, u64>,
    pub next_seq_id: u64,
}

impl State {
    pub fn apply_intent(&mut self, intent: &Intent) -> Result<Vec<Fill>, Reject> {
        self.apply_intent_with_margin(intent, |_, _| true)
    }

    pub fn apply_intent_with_margin<F>(
        &mut self,
        intent: &Intent,
        margin_check: F,
    ) -> Result<Vec<Fill>, Reject>
    where
        F: FnOnce(&State, TraderId) -> bool,
    {
        let expected_nonce = self
            .nonces
            .get(&intent.trader)
            .copied()
            .unwrap_or_default()
            .saturating_add(1);
        if intent.nonce != expected_nonce {
            return Err(Reject::NonceNotMonotonic);
        }
        if intent.qty <= 0 {
            return Err(Reject::InvalidQuantity);
        }

        match intent.kind {
            IntentKind::Cancel => {
                let book = self.books.entry(intent.market_id).or_default();
                if !book.cancel(intent.trader, intent.ref_seq_id) {
                    return Err(Reject::UnknownOrder);
                }
                self.nonces.insert(intent.trader, intent.nonce);
                self.next_seq_id = self.next_seq_id.saturating_add(1);
                Ok(Vec::new())
            }
            IntentKind::ModifyTif | IntentKind::Place => {
                if intent.price <= 0 {
                    return Err(Reject::InvalidPrice);
                }
                if intent.reduce_only() && self.reduce_only_would_increase(intent) {
                    return Err(Reject::ReduceOnlyWouldIncrease);
                }
                if !margin_check(self, intent.trader) {
                    return Err(Reject::InsufficientMargin);
                }

                let seq_id = self.next_seq_id.saturating_add(1);
                let fills = {
                    let book = self.books.entry(intent.market_id).or_default();
                    if intent.tif == TimeInForce::PostOnly
                        && book.crosses(intent.side, intent.price)
                    {
                        return Err(Reject::PostOnlyWouldCross);
                    }
                    if intent.tif == TimeInForce::Fok && fillable_qty(book, intent) < intent.qty {
                        return Err(Reject::FokWouldNotFill);
                    }

                    let (fills, remaining) = match intent.side {
                        Side::Buy => match_against_asks(book, intent, seq_id),
                        Side::Sell => match_against_bids(book, intent, seq_id),
                    };

                    if remaining > 0
                        && matches!(intent.tif, TimeInForce::Gtc | TimeInForce::PostOnly)
                    {
                        book.add(RestingOrder {
                            seq_id,
                            trader: intent.trader,
                            side: intent.side,
                            price: intent.price,
                            remaining_qty: remaining,
                            nonce: intent.nonce,
                        });
                    }
                    fills
                };

                for fill in &fills {
                    self.apply_fill(fill);
                }

                self.nonces.insert(intent.trader, intent.nonce);
                self.next_seq_id = seq_id;
                Ok(fills)
            }
        }
    }

    fn apply_fill(&mut self, fill: &Fill) {
        let taker_delta = fill.qty * fill.taker_side.sign();
        let maker_delta = -taker_delta;
        apply_position(
            self.positions
                .entry((fill.taker, fill.market_id))
                .or_default(),
            taker_delta,
            fill.price,
        );
        apply_position(
            self.positions
                .entry((fill.maker, fill.market_id))
                .or_default(),
            maker_delta,
            fill.price,
        );
    }

    fn reduce_only_would_increase(&self, intent: &Intent) -> bool {
        let current = self
            .positions
            .get(&(intent.trader, intent.market_id))
            .map(|position| position.size)
            .unwrap_or_default();
        let delta = intent.qty * intent.side.sign();
        current == 0 || current.signum() == delta.signum()
    }
}

fn apply_position(position: &mut Position, delta: Qty, price: Price) {
    let old = position.size;
    let new = old + delta;
    if old == 0 || old.signum() == delta.signum() {
        let old_notional = old.abs().saturating_mul(position.entry_price);
        let add_notional = delta.abs().saturating_mul(price);
        let denom = new.abs();
        position.entry_price = if denom == 0 {
            0
        } else {
            (old_notional + add_notional) / denom
        };
    } else if new == 0 || new.signum() != old.signum() {
        position.entry_price = if new == 0 { 0 } else { price };
    }
    position.size = new;
}

fn crosses(side: Side, limit: Price, price: Price) -> bool {
    match side {
        Side::Buy => limit >= price,
        Side::Sell => limit <= price,
    }
}

fn fillable_qty(book: &Book, intent: &Intent) -> Qty {
    match intent.side {
        Side::Buy => book
            .asks
            .iter()
            .take_while(|(price, _)| crosses(intent.side, intent.price, **price))
            .flat_map(|(_, orders)| orders.iter())
            .map(|order| order.remaining_qty)
            .sum(),
        Side::Sell => book
            .bids
            .iter()
            .take_while(|(price, _)| crosses(intent.side, intent.price, price.0))
            .flat_map(|(_, orders)| orders.iter())
            .map(|order| order.remaining_qty)
            .sum(),
    }
}

fn match_against_asks(book: &mut Book, intent: &Intent, taker_seq_id: u64) -> (Vec<Fill>, Qty) {
    let mut remaining = intent.qty;
    let mut fills = Vec::new();
    while remaining > 0 {
        let Some((&price, _)) = book.asks.iter().next() else {
            break;
        };
        if !crosses(intent.side, intent.price, price) {
            break;
        }
        let mut remove_level = false;
        {
            let orders = book.asks.get_mut(&price).expect("level exists");
            while remaining > 0 {
                let Some(maker) = orders.front_mut() else {
                    remove_level = true;
                    break;
                };
                let qty = remaining.min(maker.remaining_qty);
                remaining -= qty;
                maker.remaining_qty -= qty;
                fills.push(Fill {
                    maker: maker.trader,
                    taker: intent.trader,
                    market_id: intent.market_id,
                    price,
                    qty,
                    taker_side: intent.side,
                    maker_seq_id: maker.seq_id,
                    taker_seq_id,
                });
                if maker.remaining_qty == 0 {
                    orders.pop_front();
                }
                if orders.is_empty() {
                    remove_level = true;
                    break;
                }
            }
        }
        if remove_level {
            book.asks.remove(&price);
        }
    }
    (fills, remaining)
}

fn match_against_bids(book: &mut Book, intent: &Intent, taker_seq_id: u64) -> (Vec<Fill>, Qty) {
    let mut remaining = intent.qty;
    let mut fills = Vec::new();
    while remaining > 0 {
        let Some((&price, _)) = book.bids.iter().next() else {
            break;
        };
        if !crosses(intent.side, intent.price, price.0) {
            break;
        }
        let mut remove_level = false;
        {
            let orders = book.bids.get_mut(&price).expect("level exists");
            while remaining > 0 {
                let Some(maker) = orders.front_mut() else {
                    remove_level = true;
                    break;
                };
                let qty = remaining.min(maker.remaining_qty);
                remaining -= qty;
                maker.remaining_qty -= qty;
                fills.push(Fill {
                    maker: maker.trader,
                    taker: intent.trader,
                    market_id: intent.market_id,
                    price: price.0,
                    qty,
                    taker_side: intent.side,
                    maker_seq_id: maker.seq_id,
                    taker_seq_id,
                });
                if maker.remaining_qty == 0 {
                    orders.pop_front();
                }
                if orders.is_empty() {
                    remove_level = true;
                    break;
                }
            }
        }
        if remove_level {
            book.bids.remove(&price);
        }
    }
    (fills, remaining)
}
