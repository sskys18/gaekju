# Rust Sequencer — Implementation Plan

**Date:** 2026-04-22
**Crate:** `crates/gaekju-sequencer` (new)
**Governing ADR:** [ADR-0012](../adr/0012-zkvm-matcher-pivot.md), ADR-0014 (trust model), ADR-0015 (batching cadence)
**For agentic workers:** REQUIRED SUB-SKILL: `sspower:subagent-driven-development` or `sspower:executing-plans`.

---

## Goal

Build the off-chain Rust matcher. It owns the live orderbook, accepts EIP-712 signed intents from traders, matches deterministically, emits fills in real time over WS, and every few seconds finalises a batch that is fed to the prover crate and then to `Settlement.sol`.

Matching logic lives in a shared `gaekju-matching-core` crate so the same code runs in-process (sequencer) and inside the SP1 guest program (prover). That equivalence is what makes the ZK proof meaningful.

---

## Tech choices

- **alloy 0.x** — `alloy-signer`, `alloy-primitives`, `alloy-sol-types` for EIP-712 and ABI decoding. Matches ADR-0008.
- **axum 0.8** — REST server (depth snapshots, batch status, trader history).
- **tokio-tungstenite** — WS server (order stream, trade feed, mark price feed).
- **sled** (default) or **rocksdb** (if sled perf insufficient) — embedded KV for state persistence.
- **serde + bincode** — canonical batch serialization for the prover.
- **tracing** + `tracing-subscriber` — structured logs.
- **metrics + metrics-exporter-prometheus** — operational visibility.
- **tokio** runtime, with a single-threaded global intake/batch coordinator assigning `seqId` and `batchNonce`, plus deterministic per-market book handlers behind it.

No floats. All prices/quantities are `i128` in 1e18 units, same convention as the Solidity side.

---

## Crate layout

```
crates/
  gaekju-matching-core/           # shared — also imported by gaekju-prover
    src/
      lib.rs
      book.rs             # BTreeMap<Price, VecDeque<RestingOrder>>
      state.rs            # State machine (intents → fills + new state root)
      intent.rs           # Intent / Fill / BatchHeader structs + hashing
      eip712.rs           # Typed-data domain + Intent hashing
      state_root.rs       # Keccak-based commitment of (balances, positions, book)
      tests/
  gaekju-sequencer/
    Cargo.toml
    src/
      main.rs             # bootstrap, config, services wire-up
      config.rs
      actor.rs            # Per-market matching actor (owns state)
      ws.rs               # WS server (ingest + broadcast)
      rest.rs             # REST server
      nonce.rs            # Per-trader nonce map + replay protection
      batcher.rs          # Closes batches, writes to prover inbox
      persistence.rs      # sled snapshots + WAL replay
      prover_bridge.rs    # outbound channel to gaekju-prover
    tests/
      integration.rs
```

---

## Task list

### Task 1 — Scaffold `gaekju-matching-core`

- `cargo new --lib crates/gaekju-matching-core`.
- Register in the workspace `Cargo.toml`.
- Define base types (`Price`, `Qty`, `Side`, `TraderId = Address`, `MarketId = u64`, `IntentKind = { Place, Cancel, ModifyTIF }`).
- `Intent` struct mirrors the EIP-712 payload: `{ marketId, trader, nonce, side, price, qty, tif, expiry, flags }`. `Fill` mirrors `Settlement.Fill`.
- `no_std`-compatible behind a feature flag so the same crate compiles inside the SP1 guest (which prefers `no_std` + `sp1-zkvm` allocator).
- Verification: `cargo check -p gaekju-matching-core --no-default-features --features zkvm` and default build.

### Task 2 — Deterministic orderbook + state machine

- `Book` = per-side `BTreeMap<Price, VecDeque<RestingOrder>>`. No bitmap; off-chain code pays no gas.
- `State` = `{ books: HashMap<MarketId, Book>, balances: HashMap<Trader, i128>, positions: HashMap<(Trader, MarketId), Position>, nonces: HashMap<Trader, u64> }`.
- `apply_intent(&mut State, &Intent) -> Result<Vec<Fill>, Reject>` — pure, deterministic, no I/O, no time.
- Matching rules (mirror the old Solidity spec):
  - Price-time priority, FIFO inside a level.
  - Taker reduces through opposite side until `qty == 0` or crosses the book's far edge.
  - TIF: GTC (rest), IOC (no rest, fill what's possible), FOK (fill all or none), POST_ONLY (reject if crosses).
  - Reduce-only flag checked against trader's current position.
  - Margin check is a callback (`fn<F: FnOnce(&State, Trader) -> bool>`) so we can swap the live margin oracle for the in-circuit version.
- `state_root(&State) -> [u8; 32]` — keccak over canonical encoding. Must be byte-identical between host and guest.
- Property tests via `proptest`: no-float invariants, conservation (Σ baseDelta = 0 per fill pair), no negative resting qty, nonce strictly monotonic.

### Task 3 — EIP-712 intent verification

- Domain: `EIP712Domain(name="Gaekju", version="1", chainId=<Giwa>, verifyingContract=<Settlement>)`.
- Typed struct must match exactly what `Settlement.forceInclude` expects for the on-chain path — single source of truth shared with the Solidity side.
- `verify_intent(intent, sig) -> Result<Address, Error>`; reject if `signer != intent.trader` or `nonce <= last_nonce`.
- Test vectors cross-checked against a Foundry snapshot (`forge script` that signs with a known key and prints hash + sig; the Rust test matches).

### Task 4 — Sequencer crate bootstrap + per-market actor

- `gaekju-sequencer/main.rs` reads config (markets, RPC URLs, Settlement address, proofer address, batch cadence).
- Keep one global coordinator that owns exchange-wide sequencing state (`seqId`, force-include queue mirror, global `batchNonce`) and routes intents into per-market books. Per-market matching tasks are fine for isolation, but they do **not** own the batch chain or assign independent batch nonces.
- `Command = { SubmitIntent(Intent, Sig, oneshot::Sender<Result<Ack, Reject>>), CloseBatch(oneshot::Sender<Batch>), Snapshot(...) }`.
- Soft-ack latency target < 10ms p50 on the actor loop.

### Task 5 — REST endpoints (axum)

- `POST /v1/intent` — body `{ intent, sig }`; returns `{ status: "accepted"|"rejected", fills: [...] }`.
  - Validation must reject a sequencer-path submission whose `hash(intent)` is already present in the mirrored on-chain force-include queue. Return `DuplicateOfForced`; the intent must execute through the forced path only (spec §15.2 disjoint-list rule).
- `GET /v1/book/:market` — depth snapshot (top N levels).
- `GET /v1/trades/:market?since=...` — recent fills.
- `GET /v1/trader/:addr` — balance, position, open orders, nonce.
- `GET /v1/batch/:nonce` — batch status `{ sequencer: closed|open, prover: queued|proving|done, onchain: pending|applied, txHash }`.
- `GET /v1/status` — sequencer health, last batch, prover lag.
- OpenAPI via `utoipa` — lets SDK/CLI generate clients.

### Task 6 — WS endpoints (tokio-tungstenite)

- `/ws/stream` multiplexed by subscription topics:
  - `book:<market>` — L2 diffs.
  - `trades:<market>` — fills.
  - `mark:<market>` — 70/30 mark price ticks from OracleAdapter reader + local mid.
  - `user:<addr>` — auth via EIP-712 challenge; pushes own fills, liquidations, position updates.
- Backpressure: per-client bounded ring buffer; on overflow, disconnect and let the client resubscribe.

### Task 7 — Batcher + prover bridge

- `batcher` task runs every `batch_ms` (**default 5000** — matches ADR-0015 protocol cadence; must stay consistent with the force-include N=3-batches ≈ 15s bound) or when `max_intents_per_batch` hits.
- On close: snapshot the canonical global `BatchBlob` inputs — `header`, `accepted_intents`, `fills`, `balance_deltas`, `mid_price_updates`, force-include queue entries selected for resolution in this batch, and attested Pyth data — into the `Batch` struct, write bincode to `prover/inbox/<nonce>.batch`, notify the prover via an `mpsc` channel or a filesystem watch.
- `batch_nonce` is a single exchange-wide counter, not per market.
- Intent ordering inside a batch is receive-order under the global `seqId` assigned by the coordinator. Forced intents are executed through the separate forced path in `forcedIntentId` order; if a queued forced intent is not yet due and is not voluntarily resolved in this batch, it is omitted from `forcedOutcomes` and the contiguous cursor does not advance past it.

### Task 8 — Persistence + crash recovery

- Snapshot every `snapshot_interval` (default 60s) to sled: serialized `State` + last applied `batch_nonce`.
- Between snapshots, append each accepted `(Intent, Sig)` to a WAL (sled tree or flat file with fsync).
- Boot: load snapshot, replay WAL past it, resume.
- Verify: kill -9 the process mid-flight in a test harness, restart, confirm the state root matches the one the sequencer would have produced end-to-end.

### Task 9 — Integration harness with prover

- `crates/gaekju-sequencer/tests/integration.rs` spins up:
  - sequencer actor for a single synthetic market,
  - mock prover (reads batches, returns fake proofs after a delay),
  - mock Settlement (an in-memory contract shim via `alloy-provider`'s test harness).
- Scenario: 100 signed intents → batches → proofs → settlement. Assert final state root matches what the sequencer produced.
- Later, replace the mock prover with the real `gaekju-prover` crate running SP1 in `--mock` mode (prover plan Task 5).

### Task 10 — Ops + observability

- Prometheus metrics: `intents_accepted_total`, `intents_rejected_total{reason}`, `batches_emitted_total`, `actor_queue_depth`, `match_latency_ms`.
- `/healthz`, `/readyz` endpoints.
- Graceful shutdown: stop accepting new intents, close current batch, flush WAL, exit.
- Rate limit: per-EOA req/s cap on REST + WS to mitigate spam.

---

## Verification commands

```
cargo fmt --all -- --check
cargo clippy -p gaekju-matching-core -p gaekju-sequencer --all-targets -- -D warnings
cargo test -p gaekju-matching-core
cargo test -p gaekju-sequencer
cargo check -p gaekju-matching-core --no-default-features --features zkvm
```

Integration scenario: `cargo test -p gaekju-sequencer --test integration -- --nocapture`.

---

## Definition of done

- `gaekju-matching-core` builds both native and with the `zkvm` feature (for the SP1 guest).
- Sequencer can run locally against Anvil + mock Settlement, accept signed intents, match, and emit batches.
- Integration harness proves state-root parity between the sequencer's post-state and a replay of the same batch inside the matching core.
- Docs in `crates/gaekju-sequencer/README.md` describe config, endpoints, running locally.

---

## Open questions (defer to ADR-0014/0015)

- Sequencer HA / failover strategy — single operator for v1, rotating set later.
- Fair ordering scheme — current plan is receive-order; revisit if front-running becomes a user complaint.
- Prover inbox transport — filesystem for v1, gRPC or NATS later if we split hosts.
