# Phase 3 Session Prompt

Paste this as your opening message in the new session.

---

We're building Gaekju — a perpetual DEX on Giwa Chain (OP Stack L2), Lighter.xyz-style on-chain CLOB. Phase 1 (orderbook, vault, margin) and Phase 2 (PositionManager, LiquidationEngine, Rust keeper) are done and committed.

**Before doing anything else**, read these files in full:

1. `docs/specs/2026-04-06-gaekju-design.md` — the full design spec. Every architectural decision is here. Do not make assumptions that contradict it.
2. `docs/plans/2026-04-06-phase2-handoff.md` — Phase 2 review findings and deferred items. There are two critical bugs (C1, C2) and one minor clippy issue (m1) to fix before Phase 3 work starts.
3. `CLAUDE.md` in project root — coding conventions (fixed-point math, proxy pattern, etc.)

**Two bugs to fix first (separate commit, before Phase 3 plan):**

**C1 — Vault.realizePnl underflow on underwater liquidation:**
`contracts/src/Vault.sol` — when position loss > collateral, `lockedMargin` underflows and panics. Fix: clamp remaining loss at `lockedMargin`, return deficit to caller. Then fix `LiquidationEngine` to use the returned deficit for insurance fund draw (the current `int256(vault.balances(account)) < 0` check can never be true since balances is uint256).

**C2 — Sell-side taker margin over-consumption:**
`contracts/src/OrderBook.sol` `_updatePositions` — taker margin is computed at `fillPrice` but was reserved at `limitPrice`. For ask-side takers, fillPrice ≥ limitPrice, so the computed margin exceeds the reserved amount and `unlockOrderMargin` reverts. Fix: use `takerOrder.price` (limit price) instead of `fillPrice` when computing taker margin in `_updatePositions`.

**m1 — clippy dead-code warnings:**
`crates/gaekju-keeper/src/tx.rs` — `next_nonce` and `wallet` field are unused. CI requires `cargo clippy --all-targets -- -D warnings` clean. Add `#[allow(dead_code)]` with a comment on `next_nonce`, and either remove `wallet` from the struct or prefix it with `_`.

After fixing and verifying (`forge test --summary` all green, `cargo clippy --all-targets -- -D warnings` clean), write the Phase 3 implementation plan.

**Phase 3 scope** (from the design spec, sections 3.8–3.10):

1. **FundingRate.sol** — cumulative funding index per market, per-user settlement (`settleFunding(account, marketId)`), 1-hour funding interval (NOT 8 hours — see CLAUDE.md), crank function callable by keeper
2. **Mark price blend** — currently `OracleAdapter.getMarkPrice` returns pure oracle price. Spec requires 70% oracle + 30% orderbook mid-price. Either extend OracleAdapter with an OrderBook reference or create a MarkPriceOracle contract.
3. **MarketFactory.sol** — deploy markets (OrderBook + configs) behind UUPS proxies; per-market admin
4. **Router.sol** — user-facing entry point: enforce reduce-only flag, add Market/IOC/FOK order types, single-tx deposit+trade
5. **Funding keeper** — extend `gaekju-keeper` with a funding crank loop alongside the liquidation loop

Use the writing-plans skill (`/writing-plans`) to produce a full implementation plan before touching any code. The plan must have complete code for every step — no stubs, no "implement X here" placeholders.
