# Margin Systems from Scratch

> Part 03 of "Building a Perp DEX from Scratch"

---

## Why Margin Matters

Every perpetual futures exchange needs a margin system. Without it, a trader could open a $1M position with $1 and walk away when it goes south. Margin is the collateral that backs a position — the protocol's guarantee that losses can be covered.

In Gaekju, we implemented isolated margin with per-market configuration. This post walks through the math, the code, and the design decisions.

## The Three Margin Types

### Order Margin
When you place an order on the book, capital is reserved immediately. You can't spend it elsewhere or withdraw it. This prevents a common exploit: placing orders with capital you don't actually have.

```
orderMargin = notional * initialMarginRate
            = size * price * IMR
```

### Position Margin (Locked Margin)
Once your order matches and creates a position, order margin converts to position margin. This is the collateral backing your open position.

### Free Balance
Everything not locked. Available for new orders or withdrawal.

```
accountEquity = freeBalance + lockedMargin + orderMargin
```

## Margin Rates

Two rates govern the system:

**Initial Margin Rate (IMR):** The minimum collateral to open a position. For BTC-USD at 50x leverage, IMR = 2%. A $60,000 BTC position requires at least $1,200 in margin.

**Maintenance Margin Rate (MMR):** The minimum to keep a position open. For BTC-USD, MMR = 1.2%. If your margin ratio drops below MMR, you get liquidated.

IMR > MMR always. The gap between them is the buffer zone — your position can lose value without immediate liquidation, but you can't open a new position that's already in the danger zone.

## The Margin Ratio

```
marginRatio = (collateral + unrealizedPnL) / notionalValue
```

Where:
- `collateral`: your locked margin for this position
- `unrealizedPnL`: `(markPrice - entryPrice) * positionSize` (signed)
- `notionalValue`: `abs(positionSize) * markPrice`

When `marginRatio >= IMR`, the position is healthy.
When `marginRatio < MMR`, the position is liquidatable.
When `marginRatio` is between, the position survives but you can't increase it without adding more margin.

## Weighted Average Entry Price

When you increase an existing position, you don't get two separate entries. Instead, the system computes a weighted average:

```
newEntry = (oldEntry * abs(oldSize) + fillPrice * abs(fillSize)) / (abs(oldSize) + abs(fillSize))
```

This is implemented using 18-decimal fixed-point math (`mulFp` / `divFp`) to avoid precision loss. We fuzz-tested this extensively — the result always falls between the two input prices, within 1 wei of rounding.

## Order Margin to Position Margin Conversion

This is where the plumbing gets interesting. When an order fills:

1. OrderBook calls `PositionManager.updatePosition(account, marketId, sizeDelta, fillPrice, marginDelta)`
2. PositionManager calls `vault.unlockOrderMargin(account, marginDelta)` — releases order reservation
3. PositionManager calls `vault.lockMargin(account, marginDelta)` — locks as position collateral
4. Position struct is updated with new size, entry price, and collateral

The key insight: order margin and position margin are different accounting buckets in the Vault. The conversion happens atomically inside a single transaction.

## PnL on Close

Partial close realizes proportional PnL:

```
pnl = (closePrice - entryPrice) * closeSize * sign(positionSize)
```

For a long position closing at profit: `(62000 - 60000) * 0.5 = +$1000`.
For a short position closing at profit: `(58000 - 60000) * (-0.5) = +$1000`.

The collateral released is proportional to the close ratio, not the PnL. If you close 50% of a position, you get back 50% of the collateral plus whatever PnL you realized.

## Position Flips

A flip happens when a trade reverses your direction — selling 1.5 BTC when you're long 1 BTC. The system handles this as two atomic operations:

1. Close the old position (1 BTC long at entry) — realize PnL, unlock all collateral
2. Open a new position (0.5 BTC short at fill price) — lock new margin at IMR

This avoids any gap where the account has no position but has unrealized capital in limbo.

## Implementation Notes

- All math is 18-decimal fixed-point. USDC (6 decimals) is scaled at the Vault boundary.
- `FixedPointMath.mulFpSigned` handles signed multiplication correctly — the sign of PnL depends on position direction.
- The `EnumerableSet` tracks position holders per market for ADL ranking (next post).
- Funding settlement is stubbed as a no-op — Phase 3 fills that in.

---

*Next: [Liquidation: Protecting the Protocol](04-liquidation-math.md)*

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
