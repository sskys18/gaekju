# Data Flow

## Order Lifecycle

```
Trader              Sequencer (Rust)         Prover (SP1)       Giwa L2 (Settlement)     Indexer / API
  │                      │                        │                    │                      │
  │─ deposit USDC ──────┼────────────────────────┼───────────────────▶│ Vault.deposit()      │
  │                      │                        │                    │   credit (6→18)  ───▶│ index
  │                      │                        │                    │                      │
  │─ sign EIP-712 ──────▶│ verify sig + nonce     │                    │                      │
  │  intent (WS/REST)    │ admit to book           │                    │                      │
  │◀─ soft-ack (ms) ─────│ match against book      │                    │                      │
  │                      │ emit fills to WS  ──────┼────────────────────┼──────────────────────▶ push live
  │                      │                        │                    │                      │
  │                      │ (batch window closes)   │                    │                      │
  │                      │ seal batch:             │                    │                      │
  │                      │   prevStateRoot,        │                    │                      │
  │                      │   intents[], fills[],   │                    │                      │
  │                      │   postStateRoot  ──────▶│ SP1 execute+prove  │                      │
  │                      │                        │ (30s-2min)         │                      │
  │                      │                        │ ProofBundle ──────▶│ Settlement.applyBatch │
  │                      │                        │                    │   ├─ verify SP1 + chainId
  │                      │                        │                    │   ├─ nonce + prevRoot check
  │                      │                        │                    │   ├─ forcedOutcome check
  │                      │                        │                    │   ├─ Vault.applyBatchDelta
  │                      │                        │                    │   ├─ PM.applyBatchFills
  │                      │                        │                    │   └─ emit BatchSettled ▶ index
  │◀─ finality ─────────────────────────────────────────────────────────────────────────────────│
```

## Soft-Confirm Timing

| Stage | Latency |
|-------|---------|
| Sequencer ack (WS, sig + nonce + match) | < 50 ms |
| Batch window close | **5 s (protocol default, ADR-0015);** tunable via timelocked governance. The force-include bound `N * batch_window` is computed off the active value — do not quote `~15s` as invariant; quote `N=3 batches` and derive. |
| SP1 proof generation | 30 s – 2 min (batch size and prover infra dependent) |
| Giwa block inclusion + Settlement verify | ~1–5 s |
| **End-to-end on-chain finality** | ~35 s – 3 min worst case |

UI shows three states: `pending` (sequencer ack), `sealed` (batch closed, proving), `final` (Settlement accepted). Only `final` is durable — `pending` and `sealed` can be rewound under prover failure or verifier revert (design spec §16, §17).

## Liquidation Flow

```
Keeper (Rust)               Giwa L2
  │                           │
  │─ isLiquidatable? ───────▶│ LiquidationEngine.isLiquidatable()
  │◀─ true ──────────────────│
  │                           │
  │─ liquidate() ──────────▶│ LiquidationEngine.liquidate()
  │                           │   ├─ FundingRate.settleFunding()
  │                           │   ├─ calculate liquidation size
  │                           │   ├─ PositionManager.updatePosition()
  │                           │   ├─ fee → keeper + insurance fund
  │                           │   └─ emit PositionLiquidated
```

Liquidation stays on-chain — it reads oracle + position state directly and does not require matcher participation.

## Lighter Mirror Flow

```
Lighter.xyz               Mirror Agent (Rust)          Sequencer (Rust)
  │                           │                            │
  │─ L2 book snapshot ──────▶│                            │
  │  (every ~50ms)            │─ diff vs mirrored orders   │
  │                           │─ signed EIP-712 place/    │
  │                           │  cancel batch  ──────────▶│ admit → book
  │                           │                            │ emit fills (via WS)
  │─ trade feed ────────────▶│─ relay to API ────────────▶│ (trade feed)
```

Mirror retargets from `OrderBook.placeLimitOrder` to the sequencer's signed-intent endpoint. EIP-712 signing and nonce discipline are the same as a normal trader.

## Funding Flow

```
Keeper (Rust)               Giwa L2
  │                           │
  │─ (every hour per market) │
  │─ updatePrice() ────────▶│ OracleAdapter (Pyth)
  │─ applyFunding() ───────▶│ FundingRate.applyFunding()
  │                           │   ├─ if (now - sequencerMidTimestamp) ≤ 60s: markPrice = sequencerMid
  │                           │   ├─ else: markPrice = oracle.getMarkPrice() (emit FundingFellBackToOracle)
  │                           │   ├─ indexPrice from oracle
  │                           │   ├─ rate = clamp((mark-index)/index)
  │                           │   ├─ cumulativeFunding += rate
  │                           │   └─ emit FundingApplied(marketId, rate, source)
```

Sequencer mid-price is pushed on-chain inside every batch's dedicated `MidPriceUpdate[] midPriceUpdates` array. Settlement loops that sibling array after `Vault.applyBatchDelta(...)` and calls `FundingRate.updateSequencerMid(marketId, mid)` directly; `MidPriceUpdate` is not a `BalanceDelta` variant and Vault does not forward it. Both FundingRate (funding input) and OracleAdapter mark-price (70/30 blend for margin/liquidation, spec §3.3) read the same slot with the same 60s staleness window, so a sequencer halt degrades both consumers to pure oracle simultaneously with no source divergence.

## Failure Paths

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Sequencer halt | No batch progress; no WS acks | Users submit via `Router.forceInclude`; after N batches with no progress, Settlement refuses further batches and a fallback operator can be activated via governance |
| Prover halt | Batch sealed but no proof submitted within SLA | Prover infra failover; unbounded halt = same recovery as sequencer halt (force-inclusion SLA breach → default) |
| Invalid proof | Settlement verify reverts | Batch rejected; sequencer must re-seal the same intent set and re-prove; no state change on-chain |
| Batch revert (nonce or root mismatch) | Settlement revert | Sequencer re-derives from last accepted `postStateRoot`; replay protection via nonce prevents double-apply |
| Force-include SLA breach | On-chain counter exceeds N | Settlement enters default; governance rotates sequencer |
| Oracle stale | OracleAdapter staleness check | Liquidation and funding pause; matching continues against last good mark |
