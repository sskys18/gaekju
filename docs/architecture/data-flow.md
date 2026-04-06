# Data Flow

## Order Lifecycle

```
Trader                      Giwa L2                              Rust Backend
  │                           │                                      │
  │── deposit USDC ──────────▶│ Vault.deposit()                      │
  │                           │   └─ credit balance (6→18 dec)       │
  │                           │                                      │
  │── place limit order ────▶│ Router.placeOrder()                   │
  │                           │   ├─ MarginEngine.check()            │
  │                           │   ├─ OrderBook.insert()              │
  │                           │   └─ emit OrderPlaced           ───▶│ index event
  │                           │                                      │ push WS update
  │                           │                                      │
  │                           │ (match occurs)                       │
  │                           │   ├─ OrderBook.match()               │
  │                           │   ├─ Vault.unlockOrderMargin()       │
  │                           │   ├─ PositionManager.updatePosition()│
  │                           │   └─ emit Fill, OrderMatched    ───▶│ index events
  │◀── position update ──────│                                      │ push WS
```

## Liquidation Flow

```
Keeper (Rust)               Giwa L2
  │                           │
  │── isLiquidatable? ──────▶│ LiquidationEngine.isLiquidatable()
  │◀── true ─────────────────│
  │                           │
  │── liquidate() ──────────▶│ LiquidationEngine.liquidate()
  │                           │   ├─ FundingRate.settleFunding()
  │                           │   ├─ calculate liquidation size
  │                           │   ├─ PositionManager.updatePosition()
  │                           │   ├─ fee → keeper + insurance fund
  │                           │   └─ emit PositionLiquidated
```

## Lighter Mirror Flow

```
Lighter.xyz                 Mirror Agent (Rust)          Giwa L2
  │                           │                            │
  │── L2 book snapshot ─────▶│                            │
  │   (every ~50ms)           │── diff vs live orders     │
  │                           │── batch place/cancel ────▶│ OrderBook
  │                           │                            │ (mirrored depth)
  │                           │                            │
  │── trade feed ───────────▶│── relay to API ──────────▶│ (trade feed)
```

## Funding Flow

```
Keeper (Rust)               Giwa L2
  │                           │
  │── (every hour per market) │
  │── updatePrice() ────────▶│ OracleAdapter (Pyth)
  │── applyFunding() ───────▶│ FundingRate.applyFunding()
  │                           │   ├─ markPrice from oracle + orderbook
  │                           │   ├─ indexPrice from oracle
  │                           │   ├─ rate = clamp((mark-index)/index)
  │                           │   ├─ cumulativeFunding += rate
  │                           │   └─ emit FundingApplied
```
