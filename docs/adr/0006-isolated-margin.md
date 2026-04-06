# ADR-0006: Isolated Margin in v1

## Status
Accepted

## Date
2026-04-06

## Context
Margin mode determines how collateral is shared across a trader's positions. There are two standard approaches in perpetual futures: isolated margin and cross-margin.

In isolated margin, each position has its own dedicated collateral. A BTC-USD long with $1,000 margin and an ETH-USD short with $500 margin are completely independent. If the BTC position is liquidated, only the $1,000 allocated to it is at risk. The ETH position and any free balance in the account are unaffected.

In cross-margin, all positions share a single collateral pool. The same trader's $1,500 total margin backs both positions. Profits from the ETH short can offset losses on the BTC long, reducing liquidation risk. However, if one position blows up badly enough, it can drain the margin from all positions, causing a cascade of liquidations.

Cross-margin is generally preferred by professional traders because it is more capital-efficient: unrealized profits on one position implicitly collateralize other positions. Isolated margin is simpler to implement and easier to reason about from both the protocol and the user perspective.

## Decision
Gaekju v1 implements isolated margin only. Each position in the PositionManager has its own `collateral` field that is independent of other positions. Margin checks, liquidation calculations, and PnL accounting all operate on a per-position basis. A trader's free balance (in the Vault) is separate from any position's collateral.

Cross-margin is planned for v2. The architecture supports this evolution: the MarginEngine's `getMarginRatio` function would be extended to aggregate across positions, and the LiquidationEngine would need to consider portfolio-level margin rather than position-level margin.

## Consequences
### Positive
- Simpler risk model: each position's liquidation price is deterministic and depends only on its own entry price, size, and collateral
- Easier to implement correctly: no cross-position accounting, no portfolio-level margin aggregation
- Easier for traders to understand: "this position has $X margin and liquidation price $Y" with no hidden dependencies
- Liquidation of one position cannot cascade to other positions, protecting traders from correlated losses across markets
- Simpler for the liquidation keeper: each position can be evaluated independently without loading the trader's entire portfolio

### Negative
- Lower capital efficiency: a trader with profitable positions cannot use those profits to margin other positions without manually closing and reallocating
- More active margin management required from traders (must manually add/remove collateral per position)
- Traders familiar with cross-margin from CEXes or Hyperliquid may find isolated margin restrictive
- Some trading strategies (e.g., spread trades, basis trades) are less capital-efficient under isolated margin because the natural hedge between positions is not recognized

### Neutral
- Most perp DEXes launch with isolated margin and add cross-margin later (Hyperliquid, GMX, dYdX all followed this path)
- The Vault already tracks free balance separately from locked margin, so the data model supports migration to cross-margin without restructuring storage
- Isolated margin is the safer default for a testnet: it limits blast radius when parameters are being tuned and edge cases are being discovered

## Alternatives Considered
### Cross-Margin from Day One
- Pros: Better capital efficiency, more professional trading experience, attracts sophisticated traders, matches the experience on CEXes like Binance Futures
- Cons: Significantly more complex margin calculation (must aggregate unrealized PnL across all positions), liquidation becomes portfolio-level (must decide which positions to liquidate first, in what order, and how much), adds an entire class of edge cases (what happens when liquidating one position of a hedged pair?), harder to test exhaustively, and the consequences of bugs are amplified (a margin calculation error can cascade across all positions)
- Why rejected: The implementation complexity is not justified for v1. Cross-margin roughly doubles the surface area of the margin and liquidation systems. Getting isolated margin right first, with full test coverage and production experience, provides a solid foundation for cross-margin in v2.

### Hybrid (Isolated Default, Optional Cross)
- Pros: Users choose per-position, best of both worlds
- Cons: Must implement both systems, plus the logic to handle mixed portfolios (some positions isolated, some cross-margined). UI complexity increases. The cross-margin pool and isolated positions interact during account-level solvency checks. This is strictly more complex than implementing either mode alone.
- Why rejected: Same complexity problem as cross-margin, plus additional mixed-mode logic. If we are going to build cross-margin, we will do it properly in v2, not as an afterthought bolted onto isolated margin.

### Portfolio Margin (SPAN-style)
- Pros: Most capital-efficient, recognizes hedges and correlations between positions, used by professional derivatives exchanges
- Cons: Requires a margin model that understands asset correlations, stress testing scenarios, and option-like risk factors. This is several orders of magnitude more complex than either isolated or cross-margin. No DeFi perp DEX has successfully implemented portfolio margin on-chain.
- Why rejected: Far beyond the scope of Gaekju. This is a research-level problem for on-chain derivatives, not a feature for a v1 perp DEX.
