use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::time::{SystemTime, UNIX_EPOCH};

use alloy_primitives::{keccak256, Address};
use gaekju_matching_core::{
    intent_digest, state_root, verify_intent, Eip712Domain, Fill, Intent, Reject, SignatureBytes,
    State,
};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc, oneshot};

use crate::config::Config;
use crate::persistence::Wal;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedIntent {
    pub intent: Intent,
    pub sig: SignatureBytes,
    pub seq_id: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BalanceDelta {
    pub account: Address,
    pub free_delta: i128,
    pub locked_margin_delta: i128,
    pub order_margin_delta: i128,
    pub realized_pnl_delta: i128,
    pub insurance_fund_delta: i128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PositionFill {
    pub account: Address,
    pub market_id: u64,
    pub new_size: i128,
    pub new_entry_price: i128,
    pub new_collateral: i128,
    pub new_cumulative_funding: i128,
    pub size_delta: i128,
    pub fill_price: i128,
    pub realized_pnl: i128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MidPriceUpdate {
    pub market_id: u64,
    pub mid: i128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForcedOutcome {
    pub forced_intent_id: u64,
    pub outcome: u8,
    pub reject_reason: u8,
    pub result_hash: [u8; 32],
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchHeader {
    pub batch_nonce: u64,
    pub prev_state_root: [u8; 32],
    pub timestamp: u64,
    pub intent_count: u32,
    pub fill_count: u32,
    pub forced_count: u32,
    pub force_include_cursor: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Batch {
    pub header: BatchHeader,
    pub accepted_intents: Vec<SignedIntent>,
    pub fills: Vec<Fill>,
    pub position_fills: Vec<PositionFill>,
    pub balance_deltas: Vec<BalanceDelta>,
    pub mid_price_updates: Vec<MidPriceUpdate>,
    pub forced_outcomes: Vec<ForcedOutcome>,
    pub attested_price_ids: Vec<[u8; 32]>,
    pub attested_price_hashes: Vec<[u8; 32]>,
    pub post_state_root: [u8; 32],
    pub batch_hash: [u8; 32],
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Ack {
    pub seq_id: u64,
    pub fills: Vec<Fill>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookSnapshot {
    pub bids: Vec<gaekju_matching_core::Level>,
    pub asks: Vec<gaekju_matching_core::Level>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraderSnapshot {
    pub balance: i128,
    pub positions: BTreeMap<u64, gaekju_matching_core::Position>,
    pub nonce: u64,
    pub open_orders: Vec<gaekju_matching_core::RestingOrder>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchStatus {
    pub sequencer: &'static str,
    pub prover: &'static str,
    pub onchain: &'static str,
    pub tx_hash: Option<String>,
}

pub enum Command {
    SubmitIntent {
        intent: Intent,
        sig: SignatureBytes,
        reply: oneshot::Sender<Result<Ack, Reject>>,
    },
    CloseBatch {
        reply: oneshot::Sender<Batch>,
    },
    SnapshotBook {
        market_id: u64,
        depth: usize,
        reply: oneshot::Sender<BookSnapshot>,
    },
    SnapshotTrader {
        trader: Address,
        reply: oneshot::Sender<TraderSnapshot>,
    },
    RecentTrades {
        market_id: u64,
        since: usize,
        reply: oneshot::Sender<Vec<Fill>>,
    },
    BatchStatus {
        nonce: u64,
        reply: oneshot::Sender<Option<BatchStatus>>,
    },
    MirrorForced {
        forced_intent_id: u64,
        trader: Address,
        intent_hash: [u8; 32],
        deadline_batch_nonce: u64,
    },
    Shutdown {
        reply: oneshot::Sender<Option<Batch>>,
    },
}

#[derive(Clone)]
pub struct SequencerHandle {
    tx: mpsc::Sender<Command>,
    events: broadcast::Sender<Event>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Event {
    Accepted { seq_id: u64, intent: Intent },
    Trade { fill: Fill },
    BatchClosed { nonce: u64, state_root: [u8; 32] },
}

impl SequencerHandle {
    pub fn new(config: Config, wal: Option<Wal>) -> Self {
        let (tx, rx) = mpsc::channel(8192);
        let (events, _) = broadcast::channel(8192);
        let actor = Coordinator::new(config, rx, events.clone(), wal);
        tokio::spawn(actor.run());
        Self { tx, events }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    pub async fn submit_intent(&self, intent: Intent, sig: SignatureBytes) -> Result<Ack, Reject> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Command::SubmitIntent { intent, sig, reply })
            .await
            .map_err(|_| Reject::InsufficientMargin)?;
        rx.await.map_err(|_| Reject::InsufficientMargin)?
    }

    pub async fn close_batch(&self) -> Option<Batch> {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::CloseBatch { reply }).await.ok()?;
        rx.await.ok()
    }

    pub async fn book(&self, market_id: u64, depth: usize) -> Option<BookSnapshot> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Command::SnapshotBook {
                market_id,
                depth,
                reply,
            })
            .await
            .ok()?;
        rx.await.ok()
    }

    pub async fn trader(&self, trader: Address) -> Option<TraderSnapshot> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Command::SnapshotTrader { trader, reply })
            .await
            .ok()?;
        rx.await.ok()
    }

    pub async fn recent_trades(&self, market_id: u64, since: usize) -> Option<Vec<Fill>> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Command::RecentTrades {
                market_id,
                since,
                reply,
            })
            .await
            .ok()?;
        rx.await.ok()
    }

    pub async fn batch_status(&self, nonce: u64) -> Option<Option<BatchStatus>> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Command::BatchStatus { nonce, reply })
            .await
            .ok()?;
        rx.await.ok()
    }

    pub async fn mirror_forced(
        &self,
        forced_intent_id: u64,
        trader: Address,
        intent_hash: [u8; 32],
        deadline_batch_nonce: u64,
    ) {
        let _ = self
            .tx
            .send(Command::MirrorForced {
                forced_intent_id,
                trader,
                intent_hash,
                deadline_batch_nonce,
            })
            .await;
    }

    pub async fn shutdown(&self) -> Option<Batch> {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::Shutdown { reply }).await.ok()?;
        rx.await.ok().flatten()
    }
}

struct ForcedIntent {
    id: u64,
    trader: Address,
    intent_hash: [u8; 32],
    deadline_batch_nonce: u64,
}

struct Coordinator {
    config: Config,
    state: State,
    rx: mpsc::Receiver<Command>,
    events: broadcast::Sender<Event>,
    current: Vec<SignedIntent>,
    current_fills: Vec<Fill>,
    recent_trades: VecDeque<Fill>,
    forced_hashes: BTreeSet<[u8; 32]>,
    forced_queue: VecDeque<ForcedIntent>,
    batch_nonce: u64,
    force_include_cursor: u64,
    last_closed: Option<Batch>,
    statuses: BTreeMap<u64, BatchStatus>,
    wal: Option<Wal>,
}

impl Coordinator {
    fn new(
        config: Config,
        rx: mpsc::Receiver<Command>,
        events: broadcast::Sender<Event>,
        wal: Option<Wal>,
    ) -> Self {
        let (state, current, current_fills) = replay_wal(wal.as_ref());
        Self {
            config,
            state,
            rx,
            events,
            current,
            current_fills,
            recent_trades: VecDeque::with_capacity(8192),
            forced_hashes: BTreeSet::new(),
            forced_queue: VecDeque::new(),
            batch_nonce: 0,
            force_include_cursor: 0,
            last_closed: None,
            statuses: BTreeMap::new(),
            wal,
        }
    }

    async fn run(mut self) {
        while let Some(command) = self.rx.recv().await {
            match command {
                Command::SubmitIntent { intent, sig, reply } => {
                    let result = self.submit(intent, sig);
                    let _ = reply.send(result);
                }
                Command::CloseBatch { reply } => {
                    let batch = self.close_batch();
                    let _ = reply.send(batch);
                }
                Command::SnapshotBook {
                    market_id,
                    depth,
                    reply,
                } => {
                    let snapshot = self.book_snapshot(market_id, depth);
                    let _ = reply.send(snapshot);
                }
                Command::SnapshotTrader { trader, reply } => {
                    let _ = reply.send(self.trader_snapshot(trader));
                }
                Command::RecentTrades {
                    market_id,
                    since,
                    reply,
                } => {
                    let trades = self
                        .recent_trades
                        .iter()
                        .skip(since)
                        .filter(|fill| fill.market_id == market_id)
                        .cloned()
                        .collect();
                    let _ = reply.send(trades);
                }
                Command::BatchStatus { nonce, reply } => {
                    let _ = reply.send(self.statuses.get(&nonce).cloned());
                }
                Command::MirrorForced {
                    forced_intent_id,
                    trader,
                    intent_hash,
                    deadline_batch_nonce,
                } => {
                    self.forced_hashes.insert(intent_hash);
                    self.forced_queue.push_back(ForcedIntent {
                        id: forced_intent_id,
                        trader,
                        intent_hash,
                        deadline_batch_nonce,
                    });
                }
                Command::Shutdown { reply } => {
                    let batch = if self.current.is_empty() && self.current_fills.is_empty() {
                        None
                    } else {
                        Some(self.close_batch())
                    };
                    let _ = reply.send(batch);
                    break;
                }
            }
        }
    }

    fn submit(&mut self, intent: Intent, sig: SignatureBytes) -> Result<Ack, Reject> {
        let domain = Eip712Domain {
            chain_id: self.config.chain_id,
            verifying_contract: self.config.settlement,
        };
        let hash = intent_digest(domain, &intent).0;
        if self.forced_hashes.contains(&hash)
            || self.forced_hashes.contains(&keccak256_intent(&intent))
        {
            return Err(Reject::DuplicateOfForced);
        }
        let last_nonce = self
            .state
            .nonces
            .get(&intent.trader)
            .copied()
            .unwrap_or_default();
        verify_intent(domain, &intent, &sig, last_nonce).map_err(|err| match err {
            gaekju_matching_core::eip712::VerifyError::NonceNotMonotonic => {
                Reject::NonceNotMonotonic
            }
            gaekju_matching_core::eip712::VerifyError::InvalidSignature
            | gaekju_matching_core::eip712::VerifyError::WrongSigner => Reject::InsufficientMargin,
        })?;

        if let Some(wal) = &self.wal {
            let _ = wal.append(&SignedIntent {
                intent: intent.clone(),
                sig: sig.clone(),
                seq_id: self.state.next_seq_id.saturating_add(1),
            });
        }

        let fills = self.state.apply_intent(&intent)?;
        let seq_id = self.state.next_seq_id;
        let signed = SignedIntent {
            intent: intent.clone(),
            sig,
            seq_id,
        };
        self.current.push(signed);
        self.current_fills.extend(fills.clone());
        for fill in &fills {
            self.recent_trades.push_back(fill.clone());
            if self.recent_trades.len() > 8192 {
                self.recent_trades.pop_front();
            }
            let _ = self.events.send(Event::Trade { fill: fill.clone() });
        }
        let _ = self.events.send(Event::Accepted { seq_id, intent });
        Ok(Ack { seq_id, fills })
    }

    fn close_batch(&mut self) -> Batch {
        let prev = self
            .last_closed
            .as_ref()
            .map(|batch| batch.post_state_root)
            .unwrap_or_else(|| [0u8; 32]);
        let post = state_root(&self.state);
        self.batch_nonce = self.batch_nonce.saturating_add(1);
        let forced_outcomes = self.resolve_forced();
        let mid_price_updates = self.mid_prices();
        let position_fills = position_rows(&self.state, &self.current_fills);
        let balance_deltas = balance_rows(&self.current_fills);
        let header = BatchHeader {
            batch_nonce: self.batch_nonce,
            prev_state_root: prev,
            timestamp: now(),
            intent_count: self.current.len() as u32,
            fill_count: self.current_fills.len() as u32,
            forced_count: forced_outcomes.len() as u32,
            force_include_cursor: self.force_include_cursor,
        };
        let mut batch = Batch {
            header,
            accepted_intents: std::mem::take(&mut self.current),
            fills: std::mem::take(&mut self.current_fills),
            position_fills,
            balance_deltas,
            mid_price_updates,
            forced_outcomes,
            attested_price_ids: Vec::new(),
            attested_price_hashes: Vec::new(),
            post_state_root: post,
            batch_hash: [0u8; 32],
        };
        batch.batch_hash = crate::batcher::canonical_batch_hash(&batch);
        self.statuses.insert(
            batch.header.batch_nonce,
            BatchStatus {
                sequencer: "closed",
                prover: "queued",
                onchain: "pending",
                tx_hash: None,
            },
        );
        let _ = self.events.send(Event::BatchClosed {
            nonce: batch.header.batch_nonce,
            state_root: batch.post_state_root,
        });
        self.last_closed = Some(batch.clone());
        batch
    }

    fn book_snapshot(&self, market_id: u64, depth: usize) -> BookSnapshot {
        let (bids, asks) = self
            .state
            .books
            .get(&market_id)
            .map(|book| book.depth(depth))
            .unwrap_or_default();
        BookSnapshot { bids, asks }
    }

    fn trader_snapshot(&self, trader: Address) -> TraderSnapshot {
        let positions = self
            .state
            .positions
            .iter()
            .filter_map(|((account, market), position)| {
                (*account == trader).then_some((*market, *position))
            })
            .collect();
        let open_orders = self
            .state
            .books
            .values()
            .flat_map(|book| book.bids.values().chain(book.asks.values()))
            .flat_map(|orders| orders.iter())
            .filter(|order| order.trader == trader)
            .cloned()
            .collect();
        TraderSnapshot {
            balance: self
                .state
                .balances
                .get(&trader)
                .copied()
                .unwrap_or_default(),
            positions,
            nonce: self.state.nonces.get(&trader).copied().unwrap_or_default(),
            open_orders,
        }
    }

    fn resolve_forced(&mut self) -> Vec<ForcedOutcome> {
        let mut outcomes = Vec::new();
        while self
            .forced_queue
            .front()
            .is_some_and(|entry| entry.deadline_batch_nonce <= self.batch_nonce)
        {
            let entry = self.forced_queue.pop_front().expect("front checked");
            self.forced_hashes.remove(&entry.intent_hash);
            self.force_include_cursor = entry.id;
            outcomes.push(ForcedOutcome {
                forced_intent_id: entry.id,
                outcome: 2,
                reject_reason: 1,
                result_hash: keccak256(
                    [entry.intent_hash.as_slice(), entry.trader.as_slice()].concat(),
                )
                .0,
            });
        }
        outcomes
    }

    fn mid_prices(&self) -> Vec<MidPriceUpdate> {
        self.state
            .books
            .iter()
            .filter_map(|(market_id, book)| {
                let bid = book.best_bid()?;
                let ask = book.best_ask()?;
                Some(MidPriceUpdate {
                    market_id: *market_id,
                    mid: (bid + ask) / 2,
                })
            })
            .collect()
    }
}

fn replay_wal(wal: Option<&Wal>) -> (State, Vec<SignedIntent>, Vec<Fill>) {
    let mut state = State::default();
    let mut current = Vec::new();
    let mut fills = Vec::new();
    let Some(wal) = wal else {
        return (state, current, fills);
    };
    let Ok(entries) = wal.replay() else {
        return (state, current, fills);
    };
    for signed in entries {
        if let Ok(mut replayed) = state.apply_intent(&signed.intent) {
            fills.append(&mut replayed);
            current.push(signed);
        }
    }
    (state, current, fills)
}

fn position_rows(state: &State, fills: &[Fill]) -> Vec<PositionFill> {
    let mut rows = Vec::with_capacity(fills.len() * 2);
    for fill in fills {
        for account in [fill.taker, fill.maker] {
            let position = state
                .positions
                .get(&(account, fill.market_id))
                .copied()
                .unwrap_or_default();
            let size_delta = fill.base_delta_for(account);
            rows.push(PositionFill {
                account,
                market_id: fill.market_id,
                new_size: position.size,
                new_entry_price: position.entry_price,
                new_collateral: position.collateral,
                new_cumulative_funding: position.last_cumulative_funding,
                size_delta,
                fill_price: fill.price,
                realized_pnl: 0,
            });
        }
    }
    rows
}

fn balance_rows(fills: &[Fill]) -> Vec<BalanceDelta> {
    let mut rows = Vec::with_capacity(fills.len() * 2);
    for fill in fills {
        let notional = fill.qty.saturating_mul(fill.price);
        rows.push(BalanceDelta {
            account: fill.taker,
            free_delta: -notional,
            locked_margin_delta: 0,
            order_margin_delta: 0,
            realized_pnl_delta: 0,
            insurance_fund_delta: 0,
        });
        rows.push(BalanceDelta {
            account: fill.maker,
            free_delta: notional,
            locked_margin_delta: 0,
            order_margin_delta: 0,
            realized_pnl_delta: 0,
            insurance_fund_delta: 0,
        });
    }
    rows
}

fn keccak256_intent(intent: &Intent) -> [u8; 32] {
    keccak256(serde_json::to_vec(intent).unwrap_or_default()).0
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
