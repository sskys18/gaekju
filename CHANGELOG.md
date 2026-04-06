# Changelog

## [0.2.0] - 2026-04-06

### Added
- **PositionManager:** Full position lifecycle — open, increase, decrease, close, flip with weighted avg entry pricing
- **PositionRegistry:** EnumerableSet-based holder tracking per market (for ADL)
- **LiquidationEngine:** Partial and full liquidation with fee distribution
- **Insurance Fund:** Deficit absorption from liquidation shortfalls
- **ADL (Auto-Deleverage):** Force-close most profitable counterparty when insurance fund is depleted
- **OrderBook Integration:** Fills now create/update positions via PositionManager
- **Liquidation Keeper:** Rust keeper bot with position monitoring, tx submission, nonce management
- **Events:** PositionUpdated, PositionClosed, PositionLiquidated, AutoDeleveraged
- **Fuzz tests:** Weighted avg entry price bounded, PnL conservation across partial closes
- **Integration tests:** Full position lifecycle, liquidation flow with ADL
- **Blog #03:** "Margin Systems from Scratch"
- **Blog #04:** "Liquidation: Protecting the Protocol"

### Changed
- **OrderBook._executeFill:** Now delegates to PositionManager for margin conversion (backward-compatible when PositionManager not set)
- **Rust workspace:** Upgraded alloy 0.12 → 1.x (fixes serde compatibility)

### Notes
- Funding settlement is stubbed (no-op) — real FundingRate implementation is Phase 3

---

## [0.1.0] - 2026-04-06

### Added
- **Libraries:** BitmapLib, FixedPointMath, PackedOrder, TickMath
- **Vault:** USDC deposit/withdraw, margin locking (order + position), insurance fund, UUPS proxy
- **OracleAdapter:** Pyth Network integration with staleness + confidence band checks, mark price blending
- **MarginEngine:** Per-market config, initial margin checks, order validation (size, price alignment)
- **OrderBook:** Two-level bitmap CLOB, limit order matching (price-time priority), self-trade prevention, order cancellation, maker/taker fees
- **Integration test:** Full deposit → place → match → fill lifecycle with fee verification
- **Fuzz tests:** FixedPointMath round-trip, PackedOrder pack/unpack, abs symmetry
- **Rust types crate:** Order, Position, Market, Account types with alloy sol! event definitions
- **Deploy script:** Foundry script for full stack deployment behind UUPS proxies
- **CI:** forge test + cargo test + clippy + fmt
- **Project scaffolding:** Foundry + Rust workspace with 7 crates
