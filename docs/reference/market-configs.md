# Market Configurations

All markets are mirrored from Lighter.xyz. Configs follow Lighter's specs with Gaekju-specific adjustments.

## Crypto Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| BTC-USD | 50x | 2% | 1.2% | $0.10 | 0.00001 BTC | 1h |
| ETH-USD | 50x | 2% | 1.2% | $0.01 | 0.0001 ETH | 1h |
| SOL-USD | 25x | 4% | 2.4% | $0.001 | 0.001 SOL | 1h |
| OP-USD | 20x | 5% | 3% | $0.0001 | 0.1 OP | 1h |
| ARB-USD | 20x | 5% | 3% | $0.0001 | 0.1 ARB | 1h |
| DOGE-USD | 20x | 5% | 3% | $0.00001 | 1 DOGE | 1h |

*Plus 50+ additional crypto pairs mirrored from Lighter.*

## Korean Market Perpetuals

All KRW-quoted. Mirrors Lighter's Korean stock perps.

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| KRCOMP (KRX Index) | 10x | 10% | 6% | ₩10 | 0.01 units | 1h |
| SAMSUNG | 10x | 10% | 6% | ₩100 | 0.01 shares | 1h |
| SKHYNIX | 10x | 10% | 6% | ₩100 | 0.01 shares | 1h |
| HYUNDAI | 10x | 10% | 6% | ₩100 | 0.01 shares | 1h |
| HANMI | 10x | 10% | 6% | ₩10 | 0.1 shares | 1h |

## US Equity & Index Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| SPY (S&P 500) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| QQQ (Nasdaq-100) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| DIA (Dow Jones) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| IWM (Russell 2000) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| MAGS (Mag 7 ETF) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| BOTZ (Robotics/AI) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |

## Forex Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| EUR-USD | 25x | 4% | 2.4% | $0.0001 | 100 EUR | 1h |
| USD-KRW | 25x | 4% | 2.4% | ₩0.1 | 1000 USD | 1h |
| USD-JPY | 25x | 4% | 2.4% | ¥0.01 | 1000 USD | 1h |
| GBP-USD | 25x | 4% | 2.4% | $0.0001 | 100 GBP | 1h |
| USD-CHF | 25x | 4% | 2.4% | CHF0.0001 | 1000 USD | 1h |
| NZD-USD | 25x | 4% | 2.4% | $0.0001 | 100 NZD | 1h |

## Commodity Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| XAU (Gold) | 10x | 10% | 6% | $0.01 | 0.01 oz | 1h |
| XAG (Silver) | 10x | 10% | 6% | $0.001 | 1 oz | 1h |
| COPPER | 10x | 10% | 6% | $0.001 | 1 lb | 1h |
| PLATINUM | 10x | 10% | 6% | $0.01 | 0.01 oz | 1h |
| PALLADIUM | 10x | 10% | 6% | $0.01 | 0.01 oz | 1h |
| WTI (Crude Oil) | 10x | 10% | 6% | $0.01 | 0.1 bbl | 1h |
| NATGAS | 10x | 10% | 6% | $0.001 | 1 MMBtu | 1h |
| BRENT | 10x | 10% | 6% | $0.01 | 0.1 bbl | 1h |

## Fee Schedule

| Role | Fee Rate | Description |
|------|----------|-------------|
| Maker | -0.01% (rebate) | Paid TO the maker on fill |
| Taker | +0.05% | Charged FROM the taker on fill |
| Liquidator | +0.50% | Keeper incentive on liquidation |
| Insurance | +0.50% | Insurance fund fee on liquidation |

## Adding New Markets

New markets can be added by:
1. Checking Lighter.xyz for the market's availability and `market_id`
2. Finding the corresponding Pyth price feed ID
3. Adding a config entry to the Mirror Agent's TOML config
4. Calling `MarketFactory.createMarket()` with the parameters above
5. No code changes required
