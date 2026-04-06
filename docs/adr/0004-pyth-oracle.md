# ADR-0004: Pyth Network as Oracle

## Status
Accepted

## Date
2026-04-06

## Context
Gaekju needs reliable price feeds for two purposes: mark price calculation (used for margin checks, liquidation, and PnL) and index price (used for funding rate calculation). The mark price is a blend of 70% oracle price + 30% orderbook mid-price, while the index price is the pure oracle spot price. When these diverge, funding rates push the perp price back toward the index.

Oracle requirements for a perp DEX are strict. Prices must update frequently (at least once per funding interval, ideally sub-second), must cover all supported markets (crypto, Korean stocks, US indices, forex, commodities), must be available on OP Stack L2s, and must have confidence/quality metrics to detect stale or manipulated prices.

The two dominant oracle networks in DeFi are Chainlink (push-based, updates on deviation or heartbeat) and Pyth (pull-based, continuous off-chain updates that consumers pull on-demand). There is also the option of running a custom oracle, aggregating from multiple CEX APIs.

## Decision
We use Pyth Network as the sole oracle provider. Pyth's pull-based model fits our architecture: keepers fetch the latest price update data off-chain and submit it as calldata when triggering funding rate updates or when prices need refreshing for liquidation checks. The OracleAdapter contract wraps Pyth's interface and adds staleness checks (configurable per market), confidence band validation (revert if confidence/price > 1%), and the mark price blending formula.

Pyth provides price feeds for all our target markets: crypto pairs, forex (EUR/USD, USD/KRW, USD/JPY, etc.), commodities (XAU, XAG, WTI, etc.), and equity indices. This single provider covers our entire market catalog without needing to integrate multiple oracle systems.

## Consequences
### Positive
- Pull-based updates mean we only pay gas for price updates when we actually need them (during funding, liquidation, or when a trader triggers a price refresh), not on every heartbeat
- Sub-second update latency from Pyth's off-chain price service means fresh prices are always available when needed
- Native support for OP Stack L2s through Pyth's cross-chain deployment
- Confidence interval data allows the protocol to reject prices with unusually wide spreads, protecting against oracle manipulation
- Single integration covers 80+ markets across all asset classes (crypto, forex, commodities, equities)

### Negative
- Single oracle dependency: if Pyth goes down or delivers incorrect prices, the entire protocol is affected
- Pull-based model requires keepers to actively submit price updates, adding operational dependency on the keeper infrastructure
- Pyth's price feeds for less liquid assets (some Korean stocks, exotic commodities) may have wider confidence intervals, requiring more conservative staleness thresholds
- No on-chain price history from Pyth itself, the indexer must store historical prices independently

### Neutral
- The OracleAdapter contract abstracts Pyth behind an interface, so switching to a different oracle (or adding a fallback) requires changing only the adapter implementation, not the consuming contracts
- Pyth's fee model on L2s is minimal (small gas cost for the price update verification), not a meaningful cost factor
- The 70/30 oracle/orderbook mark price blend reduces pure oracle dependency for mark price, though index price remains 100% oracle

## Alternatives Considered
### Chainlink
- Pros: Most battle-tested oracle in DeFi, push-based (no keeper dependency for price updates), extensive security track record, wide adoption means more eyes on potential issues
- Cons: Push-based updates on deviation thresholds (typically 0.5-1%) mean prices can be stale between updates, heartbeat intervals (often 1 hour on L2s) are too slow for a perp DEX with 1-hour funding. Limited coverage for non-crypto assets on L2s, particularly Korean stocks and exotic forex pairs. Higher latency for price propagation to L2s.
- Why rejected: The push-based update model with deviation thresholds is fundamentally misaligned with a perp DEX that needs fresh prices every funding interval. A price that has not moved 0.5% might still produce significant funding rate errors. Additionally, Chainlink does not cover our full market catalog on OP Stack L2s.

### Custom Oracle (Multi-CEX Aggregation)
- Pros: Full control over price sources, update frequency, and aggregation logic. Can source from Binance, Upbit, Bithumb, and other exchanges for optimal coverage of Korean markets.
- Cons: Massive operational burden (need to run price aggregation infrastructure, handle source failures, detect manipulation). Introduces a centralized trust point that undermines the protocol's trustless design. Requires bonding/staking mechanisms or multisig attestation to provide any on-chain guarantee of correctness.
- Why rejected: Building a reliable oracle is a protocol-scale project in itself. The operational complexity and centralization risk are not justified when Pyth covers our needs. If Pyth's coverage proves insufficient for specific markets, a custom oracle can be added as a secondary source behind the OracleAdapter abstraction.

### Dual Oracle (Chainlink + Pyth)
- Pros: Redundancy, cross-validation between sources, can use median or min of the two to reduce manipulation risk
- Cons: Doubles integration complexity, need a conflict resolution strategy when the two disagree, Chainlink's limited L2 coverage still does not solve the market catalog problem, adds gas cost for reading two oracles on every price check
- Why rejected: The complexity of conflict resolution (which oracle do you trust when they disagree by 2%?) outweighs the redundancy benefit for a testnet deployment. The OracleAdapter interface allows adding a second oracle source in v2 if needed.
