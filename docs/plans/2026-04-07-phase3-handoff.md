# Phase 3 Handoff — FundingRate, MarketFactory, Router

**Date:** 2026-04-07
**Commit:** `2ad666c`
**Status:** Bug fixes committed + plan written + Codex adversarial review complete. Implementation not yet started.

---

## What Was Done This Session

### 1. Bug Fixes (commit `062607d`)

All three pre-Phase 3 bugs from the Phase 2 review are fixed and verified (131/131 forge tests, clippy clean).

**C1 — Vault.realizePnl underflow on underwater liquidation**
- `Vault.realizePnl` now clamps loss at `lockedMargin[account]` and returns `uint256 deficit` (uncovered loss)
- `IVault.realizePnl` return type changed from `void` to `uint256 deficit`
- `IPositionManager.liquidatePosition` return type changed to `uint256 deficit`
- `PositionManager._liquidateInternal` captures and returns deficit from `vault.realizePnl`
- `LiquidationEngine.liquidate` uses returned deficit for insurance fund draw (replaces broken `int256(uint256) < 0` check)
- `LiquidationEngine.autoDeleverage` same fix applied
- `totalDeposits` only decremented by amounts actually taken (balance + lockedMargin), not by the full deficit

**C2 — Sell-side taker margin over-consumption**
- `takerLimitPrice` threaded from `_matchAgainstAsks`/`_matchAgainstBids` → `_fillOneAsk`/`_fillOneBid` → `_executeFill` → `_updatePositions`
- `_updatePositions` now uses `takerLimitPrice` (reservation price) for `getRequiredMargin` instead of `fillPrice`
- Prevents `InsufficientOrderMargin` revert when sell taker fills at a higher bid price

**m1 — Clippy dead-code warnings**
- `wallet` → `_wallet` in `TxManager` struct and constructor
- `#[allow(dead_code)]` on `next_nonce`

### 2. Phase 3 Implementation Plan

Full plan with complete code: `docs/plans/2026-04-06-phase3-funding-factory-router.md`

10 tasks covering:
1. `IFundingRate.sol` + `FundingRate.sol` — standalone contract with `userFundingIndex[account][marketId]` tracking
2. Wire FundingRate into PositionManager (ORDERBOOK_ROLE for multi-market) and LiquidationEngine
3. FundingRate unit + integration tests
4. `Vault.depositFor` for atomic deposit+trade via Router
5. OrderBook IOC (orderType 2) / FOK (orderType 3) handling
6. `IMarketFactory.sol` + `MarketFactory.sol` — deploys OrderBook proxies, wires all shared contracts
7. `IRouter.sol` + `Router.sol` — reduce-only, Market/IOC/FOK, depositAndPlaceOrder, cancelOrderFor
8. MarketFactory + Router unit tests
9. `funding.rs` keeper + `main.rs` updated with `tokio::try_join!`
10. Full verification pass

### 3. Codex Adversarial Review

Full review: `docs/plans/2026-04-06-phase3-codex-review.md`

**Codex found 22 issues. They must be addressed before or during execution.**

---

## Critical Issues to Fix Before Execution

### Compile blocker

| ID | Fix |
|----|-----|
| Issue 11 | Add `initMarket(uint256, uint256, int256) external` to `IFundingRate.sol` |
| Issue 7 | Remove duplicate `setFundingRate` from PositionManager plan code |
| Issue 14 | Reconcile `cancelOrder` vs `cancelOrderFor` in Router — use only `cancelOrderFor` |

### Production-revert blockers (missing role grants)

These are all in the `MarketFactory.createMarket` wiring and deployment flow. The plan has them in test `setUp` but not in the production path. Add a deployment checklist task (Task 0) or add to `MarketFactory.initialize`:

| Role | Grantor | Grantee | When |
|------|---------|---------|------|
| `DEFAULT_ADMIN_ROLE` on FundingRate | deploy script | MarketFactory | once at deploy |
| `AUTHORIZED_ROLE` on Vault | deploy script | FundingRate | once at deploy |
| `DEFAULT_ADMIN_ROLE` on Vault | deploy script | MarketFactory | once at deploy |
| `DEFAULT_ADMIN_ROLE` on Router | deploy script | MarketFactory | once at deploy |
| `DEFAULT_ADMIN_ROLE` on MarginEngine | deploy script | MarketFactory | once at deploy |
| `DEFAULT_ADMIN_ROLE` on OracleAdapter | deploy script | MarketFactory | once at deploy |
| `DEFAULT_ADMIN_ROLE` on LiquidationEngine | deploy script | MarketFactory | once at deploy |
| `DEFAULT_ADMIN_ROLE` on PositionManager | deploy script | MarketFactory | once at deploy |
| `ROUTER_ROLE` on each new OrderBook | MarketFactory.createMarket | Router | per market |
| `DEFAULT_ADMIN_ROLE` on each new OrderBook | MarketFactory.createMarket | protocol admin | per market |

### Logic bugs in plan code

| ID | Severity | Description | Fix |
|----|----------|-------------|-----|
| C1-1 | CRITICAL | Insurance fund `realizePnl(account, +deficit)` gives bankrupt user withdrawable balance | Don't re-credit bankrupt account. Either deduct from insurance fund without re-crediting (absorb the loss), or add a non-withdrawable `socializedDebt` tracker |
| C1-2 | HIGH | Insurance draw is all-or-nothing | Use `min(fundBalance, deficit)` |
| C1-3 | HIGH | autoDeleverage discards counterparty deficit | Capture `uint256 targetDeficit` and handle |
| C2-1 | HIGH | Sell-side takers open under-collateralized shorts (limitPrice < fillPrice) | Reserve margin at mark price for sell orders, OR top up collateral from free balance at fill time |
| Issue 5 | MEDIUM | `applyFunding` with `fundingInterval == 0` runs every block | Add `require(s.fundingInterval > 0)` guard |
| Issue 12 | HIGH | OrderBook admin stays with factory | Grant `DEFAULT_ADMIN_ROLE` to protocol admin in `createMarket` |
| Issue 15 | HIGH | `closePositionMarket` fails for fully margined users — demands fresh order margin while collateral is locked | Either bypass order margin reservation for close-only paths, or unlock position margin first |
| Issue 17 | HIGH | reduce-only doesn't clamp size — users can flip direction | Add `if (size > absSize) size = absSize` in `_validateReduceOnly` |
| Issue 18 | HIGH | Shared nonce counter unused — duplicate nonces between liquidation and funding loops | Use `next_nonce()` explicitly in transaction builders, or serialize sends through a mutex |
| Issue 20 | HIGH | autoDeleverage skips `fundingRate.settleFunding` | Add settlement call before ADL liquidation |
| Issue 21 | HIGH | createMarket never grants ROUTER_ROLE on new OrderBook | Add `IOrderBook(ob).grantRouterRole(router)` to createMarket |

---

## What Was NOT Changed

- No Phase 3 implementation code written — only the plan
- OracleAdapter already implements 70/30 blend (was done in Phase 1+2)
- Existing 131 tests untouched — all pass on the bug fix commit

---

## Architecture Decisions Made

**FundingRate keeps its own user tracking (`userFundingIndex`):**
FundingRate is called by PositionManager (which has `nonReentrant`). If FundingRate wrote back to PositionManager, it would create a circular call under the reentrancy guard. Solution: FundingRate owns `userFundingIndex[account][marketId]`, and PositionManager syncs `pos.lastCumulativeFunding` after FundingRate returns (for off-chain indexing only).

**PositionManager ORDERBOOK_ROLE (multi-market support):**
Current `address public orderBook` blocks multi-market support. Changed to `ORDERBOOK_ROLE` via AccessControl. `setOrderBook` now grants the role — backward compatible with existing tests.

**Router handles Market orders as IOC at best price:**
Market buy → get `bestAskTick`, use as limit price with orderType IOC. Avoids needing extreme limit prices or special OrderBook paths.

**userFundingIndex always checkpoints (even when pos.size == 0):**
Prevents stale index carrying over when a new position opens. Without this, the first settlement after opening would compute a massive delta from the entire history.

---

## File Map (with Phase 3 additions planned)

```
contracts/src/
  Vault.sol                    — C1 fix applied ✓
  OracleAdapter.sol            — 70/30 blend already present
  MarginEngine.sol
  OrderBook.sol                — C2 fix applied ✓, IOC/FOK planned
  PositionManager.sol          — deficit return ✓, ORDERBOOK_ROLE + fundingRate planned
  LiquidationEngine.sol        — deficit handling ✓, fundingRate wiring planned
  FundingRate.sol              — NEW (planned)
  MarketFactory.sol            — NEW (planned)
  Router.sol                   — NEW (planned)
  interfaces/
    IVault.sol                 — deficit return ✓, depositFor planned
    IPositionManager.sol       — deficit return ✓
    IFundingRate.sol           — NEW (planned)
    IMarketFactory.sol         — NEW (planned)
    IRouter.sol                — NEW (planned)

crates/
  gaekju-keeper/src/
    tx.rs                      — m1 fix ✓
    liquidator.rs
    funding.rs                 — NEW (planned)
    main.rs                    — funding loop planned
```

---

## Next Session Instructions

1. **Read this handoff** and `docs/plans/2026-04-06-phase3-codex-review.md`
2. **Fix the Codex-identified issues in the plan** before executing. The compile blockers and production-revert blockers are non-negotiable. The logic bugs (C1-1, C2-1, Issue 15, Issue 17) require design decisions — propose solutions to the user before implementing.
3. **Execute the corrected plan** task by task using `sspower:subagent-driven-development` or `sspower:executing-plans`. Tasks 1–3 (FundingRate) must land first. Tasks 4–6 (Vault.depositFor, OrderBook IOC/FOK, MarketFactory) and Tasks 7–9 (Router, tests, keeper) can be parallelized.
4. **Run full verification** after all tasks: `forge test --summary` (expect 131 existing + ~40 new tests), `cargo clippy --all-targets -- -D warnings`.
