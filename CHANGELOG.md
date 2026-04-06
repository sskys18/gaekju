# Changelog

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
