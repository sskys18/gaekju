# Indexer / API / Keeper / Mirror / SDK / CLI Updates — Path B

**Date:** 2026-04-22
**Crates touched:** `gaekju-indexer`, `gaekju-api`, `gaekju-keeper`, `gaekju-mirror`, `gaekju-sdk`, `gaekju-cli`
**Governing ADR:** [ADR-0012](../adr/0012-zkvm-matcher-pivot.md)
**For agentic workers:** REQUIRED SUB-SKILL: `sspower:subagent-driven-development` or `sspower:executing-plans`.

---

## Goal

Retarget the existing Rust support crates for the zkVM-proven architecture. The sequencer is the live source of truth; Settlement.sol is the finality source. Each crate grows a second data source (or swaps the first) and surfaces new concepts — batches, proofs, force-include.

ABI bindings for `Settlement` / updated `Vault` / updated `PositionManager` land in `gaekju-types` as part of the contracts-v2 plan. These crates consume those bindings.
`gaekju-types` must export the canonical Path B structs and event decoders these crates read directly: `BatchPublicInputs`, `ProofBundle`, `BatchBlob`, `BatchHeader`, `Intent` (EIP-712 signed-intent envelope), `Fill`, `BalanceDelta`, `MidPriceUpdate`, `ForcedOutcome`, `BatchSettled`, `ForceIncludeQueued`, and `ForcedIntentResolved`.

---

## Task list

### Task 1 — `gaekju-indexer`: dual-source ingest

**Sources:**

1. **Sequencer WS** (`ws://.../ws/stream`) — subscribes to `book:*`, `trades:*`, `mark:*`. Produces "pre-settlement" rows for live PnL + charts.
2. **Giwa logs** — watches `Settlement.BatchSettled`, `Settlement.ForceIncludeQueued`, `Settlement.ForcedIntentResolved`, plus the existing `Vault.Deposit/Withdraw`, `PositionManager.PositionUpdated`, `LiquidationEngine.Liquidated`, `FundingRate.FundingSettled`.

**Steps:**

1. Add `sources/sequencer_ws.rs` module; reconnect + resume-from-last-seq logic.
2. Delete `sources/orderbook_events.rs` (legacy Phase 1 indexer wiring against `OrderBook` events). Replace with `sources/settlement_events.rs`.
3. Schema migration: new `batches` table (`{ batch_nonce, prev_root, post_root, tx_hash, applied_at, force_include_cursor }`) with **no `market_id` column** because a single global batch can contain fills across many markets. Market attribution lives on child rows (`fills_*`, `mid_price_updates`, `forced_outcomes`), not on the batch header.
4. Reconciliation job: for every sequencer-reported fill, assert it eventually matches a `BatchSettled` fill (by `(intent_hash, fill_index)`); alert on orphans.

**Verification:** `cargo test -p gaekju-indexer`; an integration test runs sequencer + Anvil + indexer, feeds 20 intents, asserts the indexer DB converges to the on-chain state.

---

### Task 2 — `gaekju-api`: live + final state split

Expose:

- `GET /markets` — metadata (pulls from MarketFactory registry).
- `GET /book/:market` — proxies sequencer REST (live).
- `GET /trades/:market?finalized=true|false` — indexer query; `finalized=true` only includes fills from `BatchSettled`, `false` includes pending sequencer fills.
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

### Task 3 — `gaekju-keeper`: on-chain liquidations + unchanged funding

Keeper runs two loops: funding-poke and liquidation-bot. **Liquidation stays fully on-chain under Path B v1** — it is not routed through the sequencer, preserving the outage-safety property claimed in spec §2.5, §10, and §17.1 (existing positions remain liquidatable even if the sequencer is down). Sequencer-routed liquidation was considered and rejected for v1; see spec §3.7 and rejected-alternatives note in ADR-0012. Revisit in a later phase if batch-cadence / MEV pressure justifies adding a `kind = Liquidate` intent path.

**Funding-poke** — unchanged. Calls `FundingRate.applyFunding(marketId)` on each market at the 1h boundary. Mark-price source is the sequencer mid-price written on-chain per batch with 60s staleness fallback to pure oracle (spec §3.8).

**Liquidation-bot:**

- **Single on-chain path.** Keeper reads finalized state from Settlement + indexer, runs `LiquidationEngine.isLiquidatable(account, marketId)`, and calls `LiquidationEngine.liquidate(account, marketId)` directly on Giwa. No sequencer involvement; no force-include fallback needed. The sequencer observes on-chain liquidation events and reconciles its in-memory position view for the affected account before accepting new intents.

Steps:

1. Refactor `liquidation::target_address` off the deleted `OrderBook` path; target `LiquidationEngine` directly via alloy-generated ABI from `gaekju-types`.
2. Read mark price from `OracleAdapter` (unchanged) for local liquidation-candidate scanning.
3. After each on-chain `PositionLiquidated` event, poke the sequencer via `POST /v1/reconcile/:account/:market` so its book drops any resting orders of the liquidated account. Sequencer treats this as an advisory; on next batch it must anyway verify state against on-chain.
4. Add metrics `liquidations_submitted_total` (single path, no labels).
5. Update tests + fixtures; no logic change to the liquidation math.

**Verification:** `cargo test -p gaekju-keeper`; integration test drives a position underwater via price feed, asserts keeper liquidates on-chain even with the sequencer intentionally stopped.

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

### Breaking-change migration note (external consumers)

Path B ships a breaking change to the on-chain event surface. Publish this in the `v0.6.0` release notes / SDK CHANGELOG / dashboards runbook the moment contracts-v2 merges:

| Retired (Path A)                    | Replacement (Path B)                                   | Notes |
|-------------------------------------|--------------------------------------------------------|-------|
| `OrderBook.OrderPlaced`             | (none — no on-chain orderbook)                         | Orders are EIP-712 intents submitted to the sequencer REST/WS. Use `GET /v1/trader/:addr` for open orders. |
| `OrderBook.OrderCanceled`           | (none)                                                 | Same. |
| `OrderBook.Traded`                  | `Settlement.BatchSettled` (aggregate) + indexer `fills_final` rows | Per-fill data lives in the batch blob, not individual events. |
| `Settlement.BatchApplied` (draft)   | `Settlement.BatchSettled`                              | Schema: `(uint64 batchNonce, bytes32 prevStateRoot, bytes32 postStateRoot, bytes32 batchHash, uint64 forceIncludeCursor)`. |
| `Settlement.BatchFinalized` (draft) | `Settlement.BatchSettled`                              | Same event. Older drafts mis-named it; do not filter on the old name. |
| `Settlement.IntentForced` (draft)   | `Settlement.ForceIncludeQueued`                        | Schema: `(uint256 forcedIntentId, address trader, bytes32 intentHash, uint64 deadlineBatchNonce)`. |
| `Settlement.IntentForcedResolved` (draft) | `Settlement.ForcedIntentResolved`                | Schema: `(uint256 forcedIntentId, uint8 outcome, uint8 rejectReason, bytes32 resultHash)`. |
| `applyBatch(header, fills, publicValues, proof)` (4-arg) | `applyBatch(ProofBundle)` (1-arg)          | `ProofBundle = (BatchPublicInputs, bytes sp1Proof, bytes batchBlob)`. |

External dashboards (Dune, Grafana pulling from RPC, Tenderly alerts) MUST update their event filters to `BatchSettled` / `ForceIncludeQueued` / `ForcedIntentResolved` at the release cutover. There is no dual-emit compatibility period — the old event names are never emitted by the shipped Settlement.

---

## Definition of done

- All six crates compile, clippy clean, tests green.
- No lingering references to `OrderBook`, `BitmapLib`, `PackedOrder`, or `TickMath` anywhere in `crates/`.
- Indexer converges within 5s of on-chain finality in the local E2E test.
- CLI and SDK ship updated READMEs describing the new intent flow.
- Keeper successfully liquidates on-chain in tests (including sequencer-down scenario).
