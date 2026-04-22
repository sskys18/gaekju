# Indexer / API / Keeper / Mirror / SDK / CLI Updates — Path B

**Date:** 2026-04-22
**Crates touched:** `gaekju-indexer`, `gaekju-api`, `gaekju-keeper`, `gaekju-mirror`, `gaekju-sdk`, `gaekju-cli`
**Governing ADR:** [ADR-0012](../adr/0012-zkvm-matcher-pivot.md)
**For agentic workers:** REQUIRED SUB-SKILL: `sspower:subagent-driven-development` or `sspower:executing-plans`.

---

## Goal

Retarget the existing Rust support crates for the zkVM-proven architecture. The sequencer is the live source of truth; Settlement.sol is the finality source. Each crate grows a second data source (or swaps the first) and surfaces new concepts — batches, proofs, force-include.

ABI bindings for `Settlement` / updated `Vault` / updated `PositionManager` land in `gaekju-types` as part of the contracts-v2 plan. These crates consume those bindings.

---

## Task list

### Task 1 — `gaekju-indexer`: dual-source ingest

**Sources:**

1. **Sequencer WS** (`ws://.../ws/stream`) — subscribes to `book:*`, `trades:*`, `mark:*`. Produces "pre-settlement" rows for live PnL + charts.
2. **Giwa logs** — watches `Settlement.BatchApplied`, `Settlement.ForceIncluded`, plus the existing `Vault.Deposit/Withdraw`, `PositionManager.PositionUpdated`, `LiquidationEngine.Liquidated`, `FundingRate.FundingSettled`.

**Steps:**

1. Add `sources/sequencer_ws.rs` module; reconnect + resume-from-last-seq logic.
2. Delete `sources/orderbook_events.rs` (legacy Phase 1 indexer wiring against `OrderBook` events). Replace with `sources/settlement_events.rs`.
3. Schema migration: new `batches` table (`{ market_id, batch_nonce, prev_root, post_root, tx_hash, applied_at }`), new `fills_pending` vs `fills_final` distinction, new `force_includes` table.
4. Reconciliation job: for every sequencer-reported fill, assert it eventually matches a `BatchApplied` fill (by `(intent_hash, fill_index)`); alert on orphans.

**Verification:** `cargo test -p gaekju-indexer`; an integration test runs sequencer + Anvil + indexer, feeds 20 intents, asserts the indexer DB converges to the on-chain state.

---

### Task 2 — `gaekju-api`: live + final state split

Expose:

- `GET /markets` — metadata (pulls from MarketFactory registry).
- `GET /book/:market` — proxies sequencer REST (live).
- `GET /trades/:market?finalized=true|false` — indexer query; `finalized=true` only includes fills from `BatchApplied`, `false` includes pending sequencer fills.
- `GET /trader/:addr` — merged: sequencer view (open orders, pending fills) + on-chain view (Vault balance, positions, realised funding).
- `GET /batch/:nonce` — mirrors sequencer's batch-status endpoint plus `txHash` + `blockNumber` once on-chain.
- `GET /batch?status=pending` — list of batches in prover or awaiting on-chain finality. Useful for UX pending banners.
- `GET /force-include/:addr` — outstanding force-include requests for a trader.
- `GET /stats` — sequencer lag, prover lag, last settled nonce, insurance fund balance.

Steps:

1. Introduce a `LiveSource` (sequencer REST client) and a `FinalSource` (indexer DB) trait; handlers combine.
2. Add openapi spec; regenerate SDK types (Task 5).
3. Rate limits + caching headers (`Cache-Control: max-age=1` for live endpoints, longer for historical).

**Verification:** `cargo test -p gaekju-api`; contract tests against the openapi schema.

---

### Task 3 — `gaekju-keeper`: retargeted liquidations + unchanged funding

Keeper runs two loops today: funding-poke and liquidation-bot.

**Funding-poke** — unchanged. Calls `FundingRate.poke()` on each market at the 1h boundary. The contract is unchanged by the pivot (ADR-0011 still holds).

**Liquidation-bot:**

- Primary path: submit liquidation intent to the sequencer (same EIP-712 schema as trader intents, with `kind = Liquidate`). Sequencer matches it like any other taker.
- Fallback path: if the sequencer is down (detected via health check / WS disconnect > `sequencer_down_threshold`), submit `Router.forceInclude(liquidationIntent)` directly on-chain. Settlement must then process it within `N` batches or enter `defaultMode`, at which point the keeper can drive liquidations through a separate emergency endpoint that Settlement exposes (design detail in `2026-04-22-contracts-v2.md`, force-include queue).

Steps:

1. Refactor `liquidation::target_address` from `OrderBook` to `Sequencer` REST / `Router` ABI.
2. Add health-monitor task (pings sequencer `/healthz`).
3. Add metrics `liquidations_submitted_total{path="sequencer"|"force_include"}`.
4. Update tests + fixtures; no logic change to the liquidation math itself.

**Verification:** `cargo test -p gaekju-keeper`; integration test simulates sequencer outage and asserts fallback path.

---

### Task 4 — `gaekju-mirror`: target Sequencer REST

Per ADR-0010 the Lighter mirror stays. The only change: it writes to the sequencer REST instead of `OrderBook.placeLimitOrder`.

Steps:

1. Swap the alloy on-chain submission path for an axum `reqwest` client hitting the sequencer `POST /v1/intent`.
2. Keep EIP-712 signing (same wallet), but signed intents now target the off-chain endpoint.
3. Update nonce management — sequencer is the nonce authority (trader nonce = per-EOA counter on the sequencer); mirror reads current nonce from `GET /v1/trader/:addr`.
4. Backoff + retry semantics tuned for <10ms ack instead of 1s block time.
5. Update `crates/gaekju-mirror/README.md` to reflect the new architecture.

**Verification:** `cargo test -p gaekju-mirror`; integration test replays recorded Lighter WS fixtures against a local sequencer and asserts mirror latency + fill parity.

---

### Task 5 — `gaekju-sdk`: new endpoints + types

Public-facing Rust SDK consumed by CLI + external integrators.

Steps:

1. Regenerate types from the new API openapi spec.
2. Add `BatchStatus`, `ForceInclude`, `ProverLag`, `SequencerHealth` structs.
3. New helpers:
   - `Client::submit_intent(&signer, intent)` — signs + POSTs to sequencer.
   - `Client::force_include(&signer, intent)` — builds calldata + sends `Router.forceInclude`.
   - `Client::wait_for_batch(nonce, timeout)` — polls until on-chain apply.
4. Deprecate `Client::place_order` / `cancel_order` helpers that targeted `OrderBook`; replace with `Intent`-based equivalents.

**Verification:** `cargo test -p gaekju-sdk`.

---

### Task 6 — `gaekju-cli`: operator + trader ergonomics

Steps:

1. `gaekju deposit <usdc>` / `gaekju withdraw <usdc>` — unchanged semantics, target Router.
2. `gaekju place <market> <side> <price> <qty> [--tif]` — now signs EIP-712 intent and submits to sequencer.
3. `gaekju cancel <intent-hash>` — submits cancel intent to sequencer.
4. `gaekju force-include <intent-file>` — on-chain escape hatch.
5. `gaekju status` — combined health: sequencer, prover, last settled batch.
6. `gaekju batch <nonce>` — prints batch status and, once applied, the tx hash.
7. Remove any flags referencing bitmap tick sizes (now a per-market config served by the API).

**Verification:** `cargo test -p gaekju-cli`; manual smoke against Anvil + mock sequencer.

---

## Cross-cutting verification

After all tasks:

```
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all
```

Plus an end-to-end scenario test (lives in `crates/gaekju-sdk/tests/e2e.rs`): deploy contracts on Anvil → boot sequencer + mock prover → place intents via SDK → observe indexer + API converge → liquidate via keeper → settle → verify all crates agree on final state.

---

## Migration coordination

These crate updates land **after** the contracts-v2 plan ships the new ABI bindings (`gaekju-types` regen) and **after** the sequencer and prover crates exist at least in skeleton form. Ordering:

1. Contracts-v2 Tasks 1-5 land — Settlement ABI bindings published.
2. Sequencer crate Tasks 1-5 land — REST and WS endpoints exist (even if mock-matched).
3. Prover crate Tasks 1-4 land — mock mode works.
4. This plan's Tasks 1-6 run in parallel (6 independent crates).
5. Final cross-cutting verification.

---

## Definition of done

- All six crates compile, clippy clean, tests green.
- No lingering references to `OrderBook`, `BitmapLib`, `PackedOrder`, or `TickMath` anywhere in `crates/`.
- Indexer converges within 5s of on-chain finality in the local E2E test.
- CLI and SDK ship updated READMEs describing the new intent flow.
- Keeper successfully liquidates via both primary and fallback paths in tests.
