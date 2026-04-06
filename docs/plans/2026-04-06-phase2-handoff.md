# Phase 2 Handoff — Positions, Liquidation, Keeper

**Date:** 2026-04-06
**Commit:** `eab5024`
**Status:** Complete — 131 Solidity tests pass, Rust compiles clean

---

## What Was Built

### Contracts
- **PositionManager.sol** — full position lifecycle: new, increase, partial close, full close, flip; weighted average entry pricing; EnumerableSet holder tracking per market for ADL
- **LiquidationEngine.sol** — partial liquidation (minimum-reduce formula), full liquidation, insurance fund, ADL (force-close most profitable counterparty)
- **OrderBook.sol** — fills now delegate to PositionManager; backward-compatible (`positionManager == address(0)` falls through to legacy path); fixed Yul IR stack-too-deep via `_fillOneAsk`/`_fillOneBid` helpers
- **Interfaces** — IPositionManager, ILiquidationEngine, IMarginEngine.getConfig, IOrderBook.setPositionManager

### Rust
- **gaekju-keeper** — TxManager (DynProvider, AtomicU64 nonce), Liquidator (polling loop, isLiquidatable, liquidate), main (env var config)
- **gaekju-types** — PositionUpdated, PositionClosed, PositionLiquidated, AutoDeleveraged sol! events + GaekjuEvent variants
- **Workspace** — upgraded alloy 0.12 → 1.x (fixes `serde::__private` compat)

### Tests
- Unit: PositionManager (20), LiquidationEngine (11)
- Fuzz: weighted avg entry price bounded, PnL conservation across partial closes
- Integration: position lifecycle (4), liquidation flow with ADL (2)

---

## Bugs to Fix Before Phase 3

These are pre-existing bugs found in the Phase 2 review. Fix them as a separate commit before starting Phase 3 to keep Phase 3 diff clean.

### CRITICAL — C1: Vault underflow on underwater liquidation

**File:** `contracts/src/Vault.sol` (realizePnl)

When a position's loss exceeds its collateral, `vault.realizePnl` tries to debit `lockedMargin[account]` which is already 0 after `unlockMargin`. This panics (Solidity 0.8 underflow).

**Fix:** In `Vault.realizePnl`, clamp `remaining` at `lockedMargin[account]` and return the uncovered deficit:
```solidity
function realizePnl(address account, int256 amount) external onlyRole(POSITION_MANAGER_ROLE) returns (uint256 deficit) {
    if (amount >= 0) {
        balances[account] += uint256(amount);
        return 0;
    }
    uint256 loss = uint256(-amount);
    if (loss <= balances[account]) {
        balances[account] -= loss;
        return 0;
    }
    loss -= balances[account];
    balances[account] = 0;
    uint256 fromLocked = loss > lockedMargin[account] ? lockedMargin[account] : loss;
    lockedMargin[account] -= fromLocked;
    return loss - fromLocked; // deficit caller must cover from insurance fund
}
```
LiquidationEngine must use the returned deficit to draw from insurance fund, replacing the current broken `int256(vault.balances(account)) < 0` check (which can never be true for `uint256`).

### CRITICAL — C2: Sell-side taker fill margin over-consumption

**File:** `contracts/src/OrderBook.sol` (`_updatePositions`)

Ask-side takers fill at the bid price (≥ limit price). `getRequiredMargin(marketId, size, fillPrice)` computes more margin than was reserved at `limitPrice`. `vault.unlockOrderMargin` then reverts with `InsufficientOrderMargin`.

**Fix:** Compute taker margin at `limitPrice`, not `fillPrice`:
```solidity
// in _updatePositions, for taker:
uint256 takerMarginForFill = marginEngine.getRequiredMargin(
    takerOrder.marketId,
    fillSize,
    takerOrder.price  // use reserved price, not fill price
);
```

### MINOR — m1: Clippy dead-code warnings break `-D warnings`

**File:** `crates/gaekju-keeper/src/tx.rs`

`next_nonce` and `wallet` are unused. CI requires `cargo clippy --all-targets -- -D warnings` to pass.

**Fix:**
```rust
#[allow(dead_code)] // used in Phase 3 for rapid sequential nonce management
pub fn next_nonce(&self) -> u64 { ... }

// wallet field: prefix or remove
_wallet: EthereumWallet,
```

---

## Explicitly Deferred to Phase 3

All stub call sites are marked with `// Phase 3:` comments in code.

| Item | Location | Status |
|------|----------|--------|
| `FundingRate.settleFunding` | PositionManager, LiquidationEngine | Stub no-op |
| Mark price blend (70% oracle + 30% mid) | OracleAdapter / MarkPriceOracle | Pure oracle price used |
| Reduce-only flag enforcement | OrderBook.placeOrder | Hardcoded false |
| Market / IOC / FOK order types | OrderBook.placeOrder | Silently ignored |
| MarketFactory.sol | — | Not started |
| `gaekju-indexer` DB setup | — | Not started |

---

## Architecture Decisions Made in Phase 2

**Vault unlock ordering:** `vault.unlockMargin` MUST be called before `vault.realizePnl` on any close path. If PnL loss is debited first, it can consume locked margin, leaving nothing to unlock. This is a non-obvious invariant — all future close paths must follow it.

**Stack-too-deep fix:** Inner matching loop bodies extracted into `_fillOneAsk`/`_fillOneBid` helpers. Do not inline them back — the Yul IR compiler cannot handle the combined stack depth.

**alloy 1.x call() return:** `call()` returns values directly for single-return Solidity functions. No `._0` field access needed (that was alloy 0.x behaviour).

**DynProvider:** `Arc<dyn Provider + Send + Sync>` is not `Sized` in alloy 1.x. Use `DynProvider` from `alloy::providers` + `.erased()` on the provider builder.

---

## Phase 3 Starting Point

Read the design spec: `docs/specs/2026-04-06-gaekju-design.md` sections 3.8 (FundingRate), 3.9 (MarketFactory), 3.10 (Router).

Fix C1 and C2 first (separate commit). Then Phase 3 scope:

1. `FundingRate.sol` — cumulative index, per-market rate, `settleFunding(account, marketId)`, hourly crank
2. `MarkPriceOracle` or extend `OracleAdapter` — 70/30 blend requires OrderBook mid-price reference
3. `MarketFactory.sol` — deploy markets behind proxy, configure engines
4. `Router.sol` — user-facing entry point, reduce-only enforcement, market/IOC/FOK orders
5. Phase 3 keeper additions — funding crank bot, mark price publisher

---

## File Map (Phase 2 additions highlighted)

```
contracts/src/
  Vault.sol                    — phase 1, C1 fix needed
  OracleAdapter.sol            — phase 1
  MarginEngine.sol             — phase 1
  OrderBook.sol                — phase 1+2 (C2 fix needed)
  PositionManager.sol          — phase 2 ✓
  LiquidationEngine.sol        — phase 2 ✓
  interfaces/
    IVault.sol                 — phase 1
    IOracleAdapter.sol         — phase 1
    IMarginEngine.sol          — phase 1+2 ✓
    IOrderBook.sol             — phase 1+2 ✓
    IPositionManager.sol       — phase 2 ✓
    ILiquidationEngine.sol     — phase 2 ✓

crates/
  gaekju-types/src/events.rs  — phase 1+2 ✓
  gaekju-keeper/src/
    main.rs                    — phase 2 ✓
    tx.rs                      — phase 2 ✓ (m1 fix needed)
    liquidator.rs              — phase 2 ✓
```
