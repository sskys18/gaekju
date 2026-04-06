# ADR-0011: 1-Hour Funding Intervals

## Status
Accepted

## Date
2026-04-06

## Context
Funding rates are the mechanism that keeps a perpetual future's price anchored to the underlying spot index price. When the perp trades above the index (positive premium), longs pay shorts, incentivizing short positions and pushing the perp price down toward the index. When the perp trades below the index (negative premium), shorts pay longs, creating the opposite pressure. The funding rate is calculated and applied at regular intervals, and the choice of interval length has direct consequences for price tracking accuracy, trader experience, and operational overhead.

The industry standard, established by BitMEX and adopted by Binance, Bybit, and most centralized exchanges, is 8-hour funding intervals (3 settlements per day). Some newer protocols have moved to shorter intervals: Lighter.xyz uses 1-hour intervals, and Drift Protocol on Solana also uses 1-hour funding. dYdX v4 and Hyperliquid remain on 8-hour cycles. The 8-hour standard was set in an era when on-chain transaction costs made frequent settlements expensive; on modern L2s with sub-cent gas costs, this constraint no longer applies.

Gaekju operates on Giwa Chain (OP Stack L2) where gas costs are negligible and block times are ~2 seconds. The funding keeper bot triggers `applyFunding()` on the FundingRate contract once per interval for each active market. Since Gaekju mirrors Lighter.xyz's orderbook and market parameters, the funding interval choice also affects parameter compatibility with the mirror source. Lighter's funding rates are calibrated for 1-hour intervals, meaning their `maxFundingRate` cap (0.1% per interval) assumes hourly settlement. Using a different interval would require recalibrating these parameters.

## Decision
Gaekju uses 1-hour funding intervals, matching Lighter.xyz's specification. The FundingRate contract's `fundingInterval` is set to 3600 seconds per market. The funding keeper triggers `applyFunding()` once per hour for each active market. The maximum funding rate per interval is capped at 0.1% (1e15 in 18-decimal fixed point), which annualizes to approximately 876% in the extreme case where the cap is hit every interval. The funding rate formula is: `rate = clamp((markPrice - indexPrice) / indexPrice, -maxRate, +maxRate)`. If the keeper misses an interval due to downtime, the next `applyFunding()` call processes each missed interval sequentially using the current price, with no catch-up multiplier.

## Consequences
### Positive
- Faster convergence of perp price to index price: premium/discount corrections happen 8x more frequently than the 8-hour standard, keeping the orderbook mid-price tightly anchored to the Pyth oracle
- Smaller funding payments per interval reduce the impact of any single funding settlement on position PnL, avoiding "funding payment shock" where a large accumulated premium triggers unexpected margin pressure
- More responsive to intraday market conditions: a sudden premium spike from a large market order is corrected within 1 hour rather than persisting for up to 8 hours
- Matches Lighter.xyz's specification exactly, maintaining parameter compatibility with the mirror source and ensuring mirrored market behavior is consistent
- Reduced arbitrage opportunities from funding-related price dislocations, since the window for the premium to accumulate is shorter

### Negative
- 24 funding settlements per day per market (vs. 3 with 8-hour intervals) means 8x more keeper transactions and gas expenditure on funding operations across all active markets
- Traders familiar with 8-hour funding from Binance, Bybit, and other CEXes may find the more frequent settlements unfamiliar; the per-interval rate appears smaller (0.001% vs. 0.008%) which can cause confusion about the true cost of carry
- The keeper bot must maintain higher uptime: missing a 1-hour window is proportionally more impactful than missing one of three 8-hour windows, and accumulated missed intervals are processed sequentially at current prices rather than at the prices that would have applied at each missed timestamp
- Higher frequency creates more funding rate history entries in the database and more events for the indexer to process, increasing storage and indexing load

## Alternatives Considered
### 8-Hour Funding (Industry Standard)
- Pros: Familiar to traders from Binance, Bybit, dYdX, and most centralized exchanges. Lower keeper operational overhead (3 transactions per day per market vs. 24). Well-understood by traders who factor funding costs into position sizing. More time for premium to accumulate creates clearer signals for funding rate arbitrageurs.
- Cons: Slower convergence means the perp price can deviate from the index for hours before correction. Large accumulated premiums create funding payment spikes that can push positions closer to liquidation unexpectedly. Incompatible with Lighter's parameter calibration, requiring recalculation of maxFundingRate and other risk parameters.
- Why rejected: The slower convergence is a meaningful UX degradation for a CLOB-based DEX where the orderbook mid-price directly influences the mark price. 8-hour intervals allow sustained price dislocations that reduce the effectiveness of the funding mechanism. Additionally, Lighter's parameters are calibrated for 1-hour intervals; adopting 8-hour would require independent parameter derivation and testing rather than using Lighter's battle-tested values.

### Continuous Funding (Per-Block)
- Pros: Theoretical ideal where funding accrues continuously, eliminating all discrete settlement artifacts. No funding payment shock at any point. The tightest possible price convergence between perp and index.
- Cons: Requires updating every position's cumulative funding index on every block (every 2 seconds on Giwa Chain), which is 43,200 updates per day per market. Even with lazy settlement (only computing funding when a position is accessed), the cumulative funding index must be updated globally per-block, requiring a keeper transaction every 2 seconds per market. On a testnet with 80+ markets, this is 40+ transactions per second dedicated solely to funding. The gas cost, while individually cheap, becomes a meaningful fraction of block space.
- Why rejected: The operational overhead is disproportionate to the benefit. The difference between 1-hour and continuous funding is marginal for price convergence purposes, but the infrastructure cost is orders of magnitude higher. 1-hour intervals provide 96% of the convergence benefit of continuous funding at 0.1% of the operational cost.

### 4-Hour Funding
- Pros: A middle ground between 1-hour and 8-hour. Reduces keeper overhead to 6 settlements per day per market while still improving convergence over the 8-hour standard.
- Cons: Does not match Lighter's specification, requiring recalibration of maxFundingRate and other parameters. Not an established standard at any major exchange, so no familiarity benefit for traders. Still allows 4-hour premium accumulation windows, which on a CLOB with direct mark price influence is long enough for meaningful dislocations.
- Why rejected: 4-hour is a compromise without a strong rationale. It saves only 18 keeper transactions per day per market compared to 1-hour (negligible on an L2), while sacrificing parameter compatibility with Lighter and providing weaker convergence. The gas cost argument for 4-hour over 1-hour does not hold on a chain with sub-cent transaction fees.
