# Liquidation: Protecting the Protocol

> Part 04 of "Building a Perp DEX from Scratch"

---

## The Problem Liquidation Solves

Without liquidation, a leveraged trader who loses more than their collateral creates a debt the protocol can't collect. The exchange becomes insolvent. Liquidation is the mechanism that closes undercollateralized positions before they can damage the system.

## When Does Liquidation Trigger?

A position is liquidatable when:

```
marginRatio < maintenanceMarginRate (MMR)
```

For BTC-USD with MMR = 1.2%: if your $60,000 position has less than $720 of effective collateral (collateral + unrealized PnL), you're liquidatable.

Anyone can call `liquidate()` — we incentivize keepers with a fee.

## Partial vs Full Liquidation

### Partial Liquidation

When there's still equity in the position, we don't close everything. Instead, we find the minimum reduction that restores the margin ratio to IMR (the initial margin rate):

```
reduceSize = (IMR * notional - equity) / (markPrice * (IMR - feeRate))
```

After partial liquidation:
- Position is smaller but still open
- Margin ratio is back at IMR
- Fees have been paid to the liquidator and insurance fund

### Full Liquidation

When equity <= 0, or when the remaining position after partial liquidation would be smaller than `minOrderSize`, we close everything.

## Fee Distribution

Each liquidation generates two fees, both proportional to the liquidated notional:

```
liquidatorFee = reduceSize * markPrice * liquidatorFeeRate    (0.5%)
insuranceFee  = reduceSize * markPrice * insuranceFundFeeRate (0.5%)
```

The liquidator (keeper bot) receives their fee as a direct balance credit. The insurance fund fee accrues in the Vault's insurance fund pool.

If the account can't cover the full fees (equity depleted), we take what's available and split proportionally.

## The Insurance Fund

The insurance fund is the protocol's backstop against socialized losses. It accumulates from:
- Liquidation insurance fees (0.5% of each liquidation)
- Any excess collateral from liquidated positions

When a fully liquidated position has negative equity (the loss exceeds the collateral), the insurance fund covers the deficit. This prevents the loss from being passed to counterparties.

## Auto-Deleverage (ADL)

When the insurance fund is depleted and there's still a deficit, we need a last resort: ADL.

ADL force-closes the most profitable position on the opposite side against the bankrupt position. The logic:

1. Get all positions in the market via `PositionRegistry.getPositionHolders()`
2. Filter for opposite-side positions
3. Rank by unrealized PnL (highest first)
4. Force-close the most profitable counterparty at the mark price
5. Both positions closed, deficit absorbed

ADL is undesirable — it takes profits away from successful traders. A well-capitalized insurance fund should make ADL extremely rare. But it must exist as the final safety net.

## The Liquidation Keeper Bot

We built a Rust keeper bot that:
- Polls position holders per market on every new block
- Calls `isLiquidatable()` for each position
- Submits `liquidate()` transactions for positions below MMR
- Manages nonces for rapid sequential transactions
- Resyncs nonce on errors to avoid stuck transactions

The keeper is economically incentivized — the 0.5% liquidator fee covers gas costs and provides profit. On an L2 like Giwa Chain, gas is cheap enough that even small liquidations are profitable.

## Implementation Considerations

### Funding First
Before checking if a position is liquidatable, accumulated funding must be settled. A position might cross the MMR threshold due to funding payments alone. We stub this in Phase 2 (funding is Phase 3) but the settlement hook is already in place.

### Oracle Price for Liquidation
Liquidations execute at the oracle mark price, not at an orderbook price. This prevents manipulation where a liquidator could move the book to trigger liquidation at a favorable price.

### Partial Liquidation Formula Derivation

Starting from the target:
```
(equity - fee) / newNotional = IMR
```

Where:
```
fee = reduceSize * markPrice * feeRate
newNotional = (absSize - reduceSize) * markPrice
```

Expanding:
```
equity - reduceSize * markPrice * feeRate = IMR * (absSize - reduceSize) * markPrice
equity - IMR * absSize * markPrice = reduceSize * markPrice * (feeRate - IMR)
```

Since feeRate < IMR (1% < 2%), the right side is negative, so:
```
reduceSize = (IMR * notional - equity) / (markPrice * (IMR - feeRate))
```

Both numerator and denominator are positive when the position is liquidatable (equity < IMR * notional) and IMR > feeRate.

---

*Next: [How Perp Funding Rates Actually Work](05-funding-rates.md)*

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
