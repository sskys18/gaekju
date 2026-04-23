# Rust Prover — Implementation Plan

**Date:** 2026-04-22
**Crate:** `crates/gaekju-prover` (new) + shares `crates/gaekju-matching-core`
**Governing ADR:** [ADR-0012](../adr/0012-zkvm-matcher-pivot.md), ADR-0013 (SP1 choice)
**For agentic workers:** REQUIRED SUB-SKILL: `sspower:subagent-driven-development` or `sspower:executing-plans`.

---

## Goal

Take batches produced by the sequencer, re-execute them deterministically inside the SP1 zkVM, and submit the resulting proof + state delta to `Settlement.sol` on Giwa Chain.

The correctness guarantee: the SP1 guest runs byte-for-byte the same matching-core logic the sequencer ran. If the proof verifies on-chain, the sequencer's post-state is the only post-state consistent with `(prev_state_root, accepted_intents_ordered)`.

---

## Tech choices

- **sp1-sdk 3.x** — host-side proving client, supports local ("mock") proofs for dev and network proofs via Succinct.
- **sp1-zkvm** — guest runtime.
- **sp1-build** — build script wiring for the guest ELF.
- **alloy** — Giwa RPC client, Settlement ABI calls.
- **tokio** runtime + `tracing` for the prover service.
- **gaekju-matching-core** imported with `--no-default-features --features zkvm` so it builds for the `riscv32im-succinct-zkvm-elf` target.

---

## Crate layout

```
crates/
  gaekju-prover/
    Cargo.toml                 # host crate — prover service
    build.rs                   # compiles the guest ELF via sp1-build
    program/                   # guest crate
      Cargo.toml
      src/main.rs              # sp1_zkvm::entrypoint!
    src/
      main.rs                  # service entrypoint
      config.rs
      watcher.rs               # watches sequencer's batch inbox
      driver.rs                # runs SP1 prover for a given batch
      submitter.rs             # sends proof to Settlement.applyBatch
      retry.rs                 # backoff + giveup policy
    elf/
      gaekju-program           # generated ELF (gitignored)
      gaekju-program.vkey      # committed — Settlement programVKey
    tests/
      e2e.rs
```

---

## Task list

### Task 1 — Extract shared matching core (sequencer plan Task 1 prerequisite)

Already covered in `2026-04-22-rust-sequencer.md` Task 1. Prover depends on the `zkvm` feature building cleanly for the SP1 target. Re-verify here because the prover crate is the first consumer that actually links it from the guest context:

```
cd crates/gaekju-matching-core
cargo build --target riscv32im-succinct-zkvm-elf --no-default-features --features zkvm
```

If this fails (e.g. a `std` dependency sneaking in via `alloy`), fix at the core crate before proceeding.

### Task 2 — SP1 guest program skeleton

`crates/gaekju-prover/program/src/main.rs`:

```rust
#![no_main]
sp1_zkvm::entrypoint!(main);

use gaekju_matching_core::{
    apply_forced_intent, apply_intent, batch_hash, state_root, Batch, BatchPublicInputs,
    ForcedResolution, State,
};

fn main() {
    // 1. Read inputs committed by the host.
    let prev_state: State = sp1_zkvm::io::read();
    let batch: Batch = sp1_zkvm::io::read();
    let chain_id: u64 = sp1_zkvm::io::read();

    // 2. Verify prev-state commitment.
    assert_eq!(state_root(&prev_state), batch.header.prev_state_root);

    // 3. Re-execute accepted intents in declared order, verifying EIP-712 signatures.
    let mut state = prev_state;
    let mut fills = Vec::new();
    let mut balance_deltas = Vec::new();
    let mut mid_price_updates = Vec::new();
    for (intent, sig) in batch.accepted_intents.iter() {
        let signer = gaekju_matching_core::eip712::recover(intent, sig, chain_id);
        assert_eq!(signer, intent.trader);
        assert!(
            !state.forced_intent_set.contains(&gaekju_matching_core::intent_hash(intent)),
            "acceptedIntents must exclude force-queued intents (spec §15.2 dedupe rule)"
        );
        let (new_fills, new_deltas, touched_markets) = apply_intent(&mut state, intent)
            .expect("accepted intent must apply (sequencer pre-validated)");
        fills.extend(new_fills);
        balance_deltas.extend(new_deltas);
        mid_price_updates.extend(state.capture_mid_price_updates(touched_markets));
    }

    // 4. Resolve force-included intents. Overdue entries MUST appear in forced_outcomes;
    //    non-due entries may stay pending. The cursor only advances over a contiguous
    //    prefix [1..=cursor] of resolved queue ids; gaps are invalid.
    let mut forced_outcomes = Vec::new();
    let mut next_cursor = state.force_cursor;
    for forced in batch.forced_queue_entries.iter() {
        match apply_forced_intent(&mut state, forced, chain_id, batch.header.batch_nonce) {
            ForcedResolution::Resolved(outcome) => {
                if outcome.forced_intent_id == next_cursor + 1 {
                    next_cursor += 1;
                }
                forced_outcomes.push(outcome);
            }
            ForcedResolution::PendingNotDue => {
                assert!(forced.deadline_batch_nonce > batch.header.batch_nonce);
            }
        }
    }
    assert_eq!(next_cursor, state.force_cursor);

    // 5. Post-state checks.
    let post_root = state_root(&state);
    assert_eq!(post_root, batch.header.post_state_root);
    assert_eq!(state.force_cursor, batch.header.force_include_cursor);

    // 6. Commit canonical BatchPublicInputs (matches spec §14.1).
    let public = BatchPublicInputs {
        prev_state_root:       batch.header.prev_state_root,
        post_state_root:       post_root,
        batch_hash:            batch_hash(
            &batch,
            &fills,
            &balance_deltas,
            &mid_price_updates,
            &forced_outcomes,
            &batch.attested_price_ids,
            &batch.attested_price_hashes,
        ),
        batch_nonce:           batch.header.batch_nonce,
        chain_id,
        force_include_cursor:  state.force_cursor,
    };
    sp1_zkvm::io::commit_slice(&public.abi_encode());
}
```

### Task 3 — Public-inputs encoding + vkey publication

- `BatchPublicInputs::abi_encode` = `abi.encode(prevStateRoot, postStateRoot, batchHash, batchNonce, chainId, forceIncludeCursor)` — identical bytes layout to what `Settlement.applyBatch` expects (design spec §14.1 / §15.1). Cross-check via a round-trip test that encodes in Rust, decodes in Solidity, re-encodes, and compares.
- `batch_hash` = `keccak256(abi.encode(BatchBlob))` where `BatchBlob` matches spec §15.2 exactly and in-order: `header`, `acceptedIntents`, `fills`, `balanceDeltas`, `midPriceUpdates`, `forcedOutcomes`, `attestedPriceIds`, `attestedPriceHashes`. Host, guest, `gaekju-types`, and Solidity must share this exact tuple order; inserting `MidPriceUpdate[]` anywhere else changes the hash and breaks proof verification.
- Commit `elf/gaekju-program.vkey` to git. Settlement's `programVKey` storage slot is initialised with this value at deployment. Any matching-core change bumps the vkey — the upgrade flow follows spec §15.5 (storage-backed rotation with pause-and-drain):
  1. `proposeProgramVKey(newVKey)` on Settlement (timelock starts).
  2. Pause sequencer; stop accepting new intents.
  3. Drain in-flight batches (sequencer closes open batch → prover proves it → submitter lands it).
  4. Confirm prover queue empty and no overdue unresolved force-included intents.
  5. `activateProgramVKey(newVKey)` after timelock expires (requires `paused() == true`).
  6. Redeploy the prover service with the new guest ELF whose vkey matches `newVKey`; run `gaekju-prover verify-vkey` against on-chain value.
  7. Unpause sequencer; batch nonce + `prevStateRoot` continuity is preserved across the flip.

  Settlement is **not** redeployed for vkey rotations. Pending force-included intents are carried across; deadlines are batch-nonce based, so they do not silently expire while `batchNonce` is frozen during a pause. If governance decides the carried queue is stale before unpausing, it may use the spec §15.5 deadline-extension helper.

### Task 4 — Host prover driver

`driver.rs`:

- Loads the ELF once at startup via `include_bytes!("../elf/gaekju-program")`.
- Per batch: builds `SP1Stdin`, calls `ProverClient::prove(...).compressed()` to get a proof suitable for on-chain EVM verification (groth16 wrapper as SP1 ships in v3).
- Mock mode (`SP1_PROVER=mock`) for CI and local dev — returns a deterministic stub proof that the `MockSP1Verifier` accepts.
- Network mode targets Succinct's prover network — pulls credentials from env.
- Benchmarks: record `proof_ms`, `proof_bytes`, `cycles` in Prometheus.

### Task 5 — Batch watcher

`watcher.rs`:

- Watches the sequencer's outbox (filesystem by default, pluggable to NATS later).
- On new `batch.bincode`: enqueue to a bounded tokio queue; `driver` pops, proves, hands off to `submitter`.
- Ordering: proofs must be submitted to Settlement in strict `batch_nonce` order. Out-of-order completions wait in a reorder buffer.

### Task 6 — Giwa submitter

`submitter.rs`:

- Builds the canonical `applyBatch(ProofBundle)` calldata (spec §15.1) using the alloy-generated `Settlement` ABI from `gaekju-types`. `ProofBundle = { BatchPublicInputs publicInputs, bytes sp1Proof, bytes batchBlob }`. The older four-argument `applyBatch(header, fills, publicValues, proof)` shape is retired; do not use it.
- Signs with the prover operator key (hot wallet, separate from sequencer key).
- Uses `eth_estimateGas` + 20% buffer; retries with replace-by-fee if the tx sits unmined beyond `stuck_timeout`.
- On revert: dump calldata + tx hash to `failures/<nonce>.json`, page the operator, halt further submissions until resolved.

### Task 7 — Failure handling

Enumerated failure modes and responses:

- **Prover halt (crash / OOM)** — systemd/k8s restart. Watcher resumes from last committed batch nonce.
- **Proof generation slower than batch cadence** — backpressure to sequencer via a `max_in_flight_batches` signal; sequencer throttles intent admission when prover lag > threshold.
- **Invalid proof (sequencer bug causing mismatch between live execution and guest replay)** — driver logs the mismatch, halts submissions, pages operator, preserves the offending batch for postmortem.
- **Settlement reverts** (bad nonce, bad prev root, verifier rejects) — submitter stops, does not advance nonce, flags incident.
- **Giwa RPC outage** — exponential backoff; fall back to a secondary RPC; if > `giwa_down_timeout`, switch sequencer into "force-include pending" UX signal.

### Task 8 — End-to-end test

`crates/gaekju-prover/tests/e2e.rs`:

1. Spawn an in-memory sequencer with one market.
2. Feed 50 signed intents.
3. Sequencer produces two batches.
4. Prover in `mock` mode produces proofs.
5. Submitter posts to a deployed-on-Anvil `Settlement` with `MockSP1Verifier` set to accept.
6. Assert: `Settlement.batchNonce() == 2`, `stateRoot == sequencer.state_root()`, traders' Vault balances and PositionManager positions match the sequencer's view.

Run: `cargo test -p gaekju-prover --test e2e -- --nocapture`.

### Task 9 — Operational tooling

- `gaekju-prover prove-batch <path>` CLI subcommand: one-shot proving for forensic replay.
- `gaekju-prover verify-vkey`: re-derives the vkey from the ELF and diffs against the committed `.vkey` file — CI gate.
- Prometheus dashboard JSON checked in under `ops/dashboards/prover.json`.

---

## Verification commands

```
cargo fmt --all -- --check
cargo clippy -p gaekju-prover --all-targets -- -D warnings
cargo test -p gaekju-prover
cd crates/gaekju-prover && cargo prove build   # regenerates the ELF
cd crates/gaekju-prover && cargo run -- verify-vkey
```

Integration: `cargo test -p gaekju-prover --test e2e`.

---

## Definition of done

- Guest ELF builds reproducibly; vkey is committed and matches the Settlement initializer.
- Prover service runs in both mock and network modes against Anvil + Giwa testnet.
- End-to-end test (sequencer → prover → Settlement) green in mock mode.
- Failure runbook documented in `crates/gaekju-prover/RUNBOOK.md`.

---

## Open questions

- **Hosted vs self-hosted proving** — ADR-0013 leaves this open. Default: Succinct network for v1, revisit when batch cadence or cost data warrants self-hosting.
- **Proof aggregation** — not required for v1 (one proof per batch). If batch cadence tightens below ~30s we'll need SP1 proof aggregation to amortise verifier gas.
