# ADR-0010: Lighter.xyz as Liquidity Mirror Source

## Status
Accepted

## Date
2026-04-06

## Context
Gaekju is a perpetual futures DEX on a testnet (Giwa Chain). Testnet exchanges face a fundamental bootstrapping problem: without liquidity, traders cannot execute meaningful trades; without traders, there is no organic liquidity. Professional market makers will not commit capital or engineering resources to provide liquidity on an unproven testnet with no real economic incentive. Running a testnet with an empty orderbook makes the product unusable for demonstration, testing, and developer onboarding.

The solution is to mirror liquidity from an existing production exchange. The mirror agent reads a live orderbook from a source exchange and places equivalent orders on Gaekju's on-chain book. Testnet traders see real market depth and can execute trades against it. Their orders coexist with mirrored orders on the same on-chain orderbook, creating a realistic trading experience without requiring organic market makers. The mirror agent is a Rust crate (`gaekju-mirror`) that runs alongside the other backend services.

The choice of mirror source determines which markets Gaekju can offer, how the mirrored depth behaves, and what API constraints the mirror agent operates under. The ideal source has broad market coverage (crypto, forex, commodities, equities), a free and unauthenticated API with WebSocket support for real-time updates, sufficient depth to create a realistic orderbook, and architectural similarity to Gaekju so that mirrored orders map naturally to the on-chain format.

## Decision
Gaekju mirrors liquidity from Lighter.xyz. The `gaekju-mirror` crate connects to Lighter's public WebSocket API, subscribes to L2 orderbook snapshots and trade feeds for each configured market, and maintains a local representation of Lighter's book. On each update, it diffs the Lighter state against currently live mirror orders on Gaekju, then submits EIP-712-signed intents to the `gaekju-sequencer` REST/WS endpoint (introduced by ADR-0012) to add, cancel, or update orders so that Gaekju's orderbook tracks Lighter's within approximately 2 seconds. Before ADR-0012 the mirror submitted on-chain transactions calling `OrderBook.placeLimitOrder`; post-pivot it submits signed intents to the off-chain sequencer over HTTP/WebSocket. The EIP-712 signing scheme and Lighter-to-Gaekju market mapping are unchanged. Mirrored orders are placed from a dedicated mirror account with pre-funded USDC collateral and are tagged internally so the system can distinguish them from organic trader orders.

## Consequences
### Positive
- 220+ markets available immediately: crypto perpetuals (BTC, ETH, SOL, and dozens more), Korean stocks (Samsung, Hyundai, SK Hynix, POSCO, etc.), US index futures (S&P 500, Nasdaq, Dow Jones), forex pairs (EUR/USD, GBP/USD, USD/JPY, USD/KRW), and commodities (gold, silver, oil) -- all sourced from a single API
- Lighter's API is free and unauthenticated, requiring no API keys, rate limit negotiations, or commercial agreements
- Architectural alignment: Lighter uses an on-chain CLOB model similar to Gaekju, so order formats, tick sizes, and lot sizes map naturally without lossy conversion
- Real market depth from a production exchange gives testnet traders a realistic experience for testing strategies and validating the trading interface
- The RWA market coverage (Korean stocks, forex, commodities) differentiates Gaekju from crypto-only DEXes and demonstrates the platform's capability to host non-crypto perpetuals
- WebSocket API provides real-time updates, enabling the mirror to track orderbook changes within seconds rather than polling on fixed intervals

### Negative
- Single point of dependency: if Lighter's API goes down or changes its format, Gaekju's testnet orderbooks go stale until the mirror agent is updated
- Mirrored liquidity is not real: traders can take the other side of mirrored orders, but the mirror account's positions accumulate and must be managed (funded with sufficient testnet USDC, periodically reset)
- Latency between Lighter's state change and Gaekju's on-chain reflection is 1-3 seconds due to API propagation, diff computation, and L2 transaction confirmation; fast-moving markets during high volatility may show stale prices briefly
- Mirror load lands on the off-chain sequencer (post ADR-0012) rather than on-chain block space; on peak sequencer load the mirror and organic traders compete for matching queue depth, but no gas is consumed until batch settlement
- Lighter's market parameters (tick sizes, lot sizes) constrain Gaekju's market configuration; deviating would require conversion logic in the mirror agent

## Alternatives Considered
### Hyperliquid
- Pros: Deep liquidity for crypto markets, well-known in crypto perp DEX space, good API documentation, large number of crypto perpetual markets
- Cons: Hyperliquid's market catalog is crypto-only, which does not cover Korean stocks, forex, or commodities. Their architecture is different (off-chain matching with on-chain settlement), creating impedance mismatch in order format mapping. Previously used as Gaekju's mirror source but replaced due to limited market coverage.
- Why rejected: The lack of RWA and non-crypto markets was the primary factor. Gaekju's value proposition includes Korean stocks, forex, and commodities as perpetual markets. Lighter provides all of these from a single source. Hyperliquid would require a second data source for non-crypto markets, adding complexity without benefit.

### Synthetic Market-Making Bots
- Pros: Full control over spread, depth, and behavior; no external dependency; can simulate any market conditions including stress scenarios
- Cons: Liquidity is entirely fabricated with no connection to real market prices beyond oracle feeds. The orderbook depth would be synthetic and would not reflect real market microstructure (natural clustering at round numbers, depth asymmetry around significant levels). Traders testing strategies against synthetic liquidity learn nothing about real execution quality. Building a realistic market-making bot is itself a significant engineering effort.
- Why rejected: Synthetic liquidity defeats the purpose of providing a realistic testnet experience. Traders need to see real depth, real spreads, and real price movements to validate their strategies. A bot-generated orderbook would be immediately recognizable as fake by any experienced trader.

### No Liquidity Mirror (Organic Only)
- Pros: Simplest architecture, no mirror agent to maintain, no external dependency, organic price discovery from day one
- Cons: The orderbook would be empty until organic market makers arrive, which requires the exchange to already be functional and attractive. This is a chicken-and-egg problem that has killed numerous testnet DEXes. An empty orderbook makes the product impossible to demo, test, or onboard developers against.
- Why rejected: The cold start problem is real and unsolved without external liquidity seeding. Every successful perp DEX testnet has used some form of liquidity bootstrapping. Mirroring a production exchange is the most honest approach because the depth is real, just sourced externally.
