# Glossary

Key terms used throughout the Gaekju documentation.

## Trading

| Term | Definition |
|------|-----------|
| **Perpetual Future (Perp)** | A futures contract with no expiry date. Held indefinitely, with periodic funding payments to anchor the price to the spot index. |
| **Long** | A position that profits when the asset price increases. |
| **Short** | A position that profits when the asset price decreases. |
| **Leverage** | Multiplier on position size relative to collateral. 50x leverage means $100 collateral controls a $5,000 position. |
| **Notional Value** | The total value of a position. `abs(positionSize) * markPrice`. |
| **Unrealized PnL** | Profit/loss on an open position that hasn't been closed yet. |
| **Realized PnL** | Profit/loss locked in when a position is partially or fully closed. |

## Orderbook

| Term | Definition |
|------|-----------|
| **CLOB** | Central Limit Order Book. Matching engine using price-time priority. |
| **Bid** | A buy order. Highest bid is the best bid. |
| **Ask** | A sell order. Lowest ask is the best ask. |
| **Spread** | The difference between best ask and best bid. |
| **Tick** | Minimum price increment for a market (e.g., $0.10 for BTC). |
| **Lot** | Minimum size increment for a market (e.g., 0.00001 BTC). |
| **Maker** | A trader whose limit order rests on the book and adds liquidity. |
| **Taker** | A trader whose order matches immediately and removes liquidity. |
| **Fill** | A matched trade between a maker and taker order. |
| **Bitmap** | *(Legacy — removed in Path B pivot, see ADR-0012)* Data structure where each bit represents a price tick's active status. Enabled O(1) best price lookup in the original on-chain CLOB. |
| **TickBitmap** | *(Legacy — removed in Path B pivot, see ADR-0012)* Per-market bitmap tracking occupied price ticks for the on-chain orderbook. |
| **PackedOrder** | *(Legacy — removed in Path B pivot, see ADR-0012)* Bit-packed single-slot order struct (price, size, owner, flags) from the on-chain orderbook. |
| **BitmapLib** | *(Legacy — removed in Path B pivot, see ADR-0012)* Solidity library implementing bitmap traversal (`findFirstSet` / `findLastSet`) for the on-chain orderbook. |

## Order Types

| Term | Definition |
|------|-----------|
| **Limit Order** | Rests on the book at a specified price. Fills when another order crosses it. |
| **Market Order** | Fills immediately at the best available price. Unfilled portion is discarded. |
| **IOC (Immediate-or-Cancel)** | Fills what it can immediately, cancels the rest. |
| **FOK (Fill-or-Kill)** | Fills entirely in one shot or reverts completely. |
| **Post-Only** | Reverts if it would match immediately. Guarantees maker status. |
| **Reduce-Only** | Can only reduce an existing position, not increase or open a new one. |

## Margin & Risk

| Term | Definition |
|------|-----------|
| **Collateral** | USDC deposited as margin for positions. |
| **IMR (Initial Margin Rate)** | Minimum margin ratio required to open a position. `1 / maxLeverage`. |
| **MMR (Maintenance Margin Rate)** | Minimum margin ratio to keep a position open. Below this triggers liquidation. |
| **Margin Ratio** | `(collateral + unrealizedPnL) / notionalValue`. |
| **Isolated Margin** | Each position has its own dedicated collateral. Loss on one position doesn't affect others. |
| **Cross Margin** | All positions share one collateral pool. More capital efficient but riskier. (Planned for v2.) |
| **Liquidation** | Forced closure of a position when margin ratio falls below MMR. |
| **ADL (Auto-Deleverage)** | When insurance fund can't cover a liquidation deficit, profitable positions on the opposite side are force-closed. |
| **Insurance Fund** | Reserve funded by liquidation fees. Covers losses when liquidated positions go bankrupt. |

## Funding

| Term | Definition |
|------|-----------|
| **Funding Rate** | Periodic payment between longs and shorts to anchor perp price to index. Calculated hourly. |
| **Mark Price** | Price used for margin and liquidation calculations. Blend of oracle (70%) and orderbook mid-price (30%). |
| **Index Price** | Spot oracle price from Pyth Network. Used for funding rate calculation. |
| **TWAP** | Time-Weighted Average Price. Smoothed average over a time window. |

## Infrastructure

| Term | Definition |
|------|-----------|
| **Pyth Network** | Pull-based oracle providing real-time price feeds for crypto, forex, equities, and commodities. |
| **UUPS** | Universal Upgradeable Proxy Standard (EIP-1822). Upgrade logic lives in the implementation, not the proxy. |
| **Alloy** | Rust library for Ethereum interaction. Successor to ethers-rs. |
| **Foundry** | Solidity development toolkit (forge, cast, anvil). |
| **OP Stack** | Open-source framework for building L2 rollups. Used by Giwa Chain. |

## zkVM Matcher (Path B)

| Term | Definition |
|------|-----------|
| **Sequencer** | Off-chain Rust matching engine (`crates/gaekju-sequencer`). Accepts signed EIP-712 intents, maintains orderbook state in memory, matches deterministically, emits fills. |
| **Prover** | SP1 zkVM proving service (`crates/gaekju-prover`). Re-executes the Rust matching program over a batch of intents and produces a succinct proof of correct execution. |
| **Batch** | Ordered set of intents matched by the sequencer, proven by the prover, and applied atomically by Settlement. Identified by a strictly monotonic batch nonce. |
| **SP1** | Succinct Labs' zkVM. RISC-V-based, executes plain Rust, emits SNARK proofs verifiable on-chain at ~300k gas. Chosen over RISC Zero and Plonky2 (see ADR-0013). |
| **Proof** | SNARK attestation from SP1 that a batch of intents was processed by the canonical Rust matching program, producing the committed state delta from the committed previous state root. |
| **Settlement** | On-chain contract (`Settlement.sol`) that verifies the SP1 proof, decodes the state delta (fills, position updates, margin changes), and applies it to Vault / PositionManager / MarginEngine / FundingRate / LiquidationEngine. Replaces the legacy OrderBook as the sole caller of those modules. |
| **Force-Include** | User escape hatch via `Router.forceInclude(intent)` on-chain. If the sequencer censors a user, Settlement must process their force-included intent within N batches or the sequencer is in default. See ADR-0014. |
| **Soft-Confirm** | Sequencer-level acknowledgment of an accepted intent, returned in ~10-50ms, before on-chain finality (which waits for batch close + proof generation + Giwa block). |

## Markets

| Term | Definition |
|------|-----------|
| **RWA** | Real-World Assets. Non-crypto assets like stocks, forex, and commodities traded as on-chain perps. |
| **KRX** | Korea Exchange. Main stock exchange in South Korea. |
| **KRCOMP** | Korean composite index tracking all common shares on KRX. |
| **Mirror Agent** | Service that reads Lighter.xyz orderbook and replicates depth on Gaekju's testnet. |
