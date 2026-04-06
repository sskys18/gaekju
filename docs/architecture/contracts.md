# Smart Contract Architecture

## Contract Map

```
MarketFactory
├── OrderBook (one per market)     — Bitmap CLOB, matching engine
├── PositionManager                — Position lifecycle, PnL, registry
├── MarginEngine                   — Margin checks, market configs
├── LiquidationEngine              — Liquidation, insurance fund, ADL
├── FundingRate                    — Hourly funding calculation
├── OracleAdapter                  — Pyth price feeds, mark/index price
├── Vault                          — USDC deposits, collateral accounting
└── Router                         — Multi-step convenience functions

Libraries:
├── BitmapLib.sol                  — Two-level bitmap operations
├── FixedPointMath.sol             — 18-decimal arithmetic
├── PackedOrder.sol                — Order compression (2 storage slots)
└── TickMath.sol                   — Price ↔ tick conversions
```

## Contract Interactions

```
User → Router → OrderBook → MarginEngine (check margin)
                          → PositionManager (update positions)
                          → Vault (lock/unlock margin)
                          → FundingRate (settle before position change)

Keeper → LiquidationEngine → FundingRate (settle first)
                            → PositionManager (reduce position)
                            → Vault (distribute fees)

Keeper → FundingRate → OracleAdapter (get prices)

Mirror → Router → OrderBook (place/cancel mirrored orders)
```

## Upgradability

All contracts use UUPS proxy (EIP-1822):
- 24-hour Timelock for all upgrades
- 3-of-5 multisig (Gnosis Safe) owns the Timelock
- Emergency pause bypasses timelock (pause only, not upgrade)
- Storage gaps (`uint256[50] __gap`) for future expansion

## Key Invariants

- `USDC.balanceOf(vault) * 1e12 >= totalDeposits`
- Sum of long OI == sum of short OI per market
- Every resting order has reserved margin
- `bestBid < bestAsk` always (crossed book = critical failure)
- Position holders tracked in EnumerableSet for ADL

See [Full Design Spec](../specs/2026-04-06-gaekju-design.md) for complete contract specifications.
