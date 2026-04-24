# Session Handoff
> Generated: 2026-04-24 — after contracts-v2 merge to main

## Task
Path B Phase 5 execution. `contracts-v2` plan **complete and merged to main** (`98baf7c`). Next: Rust sequencer → Rust prover → indexer/api/keeper/sdk updates. Per handoff-before-this, three parallel plans remain.

## Status

### Completed this session
- Executed `docs/plans/2026-04-22-contracts-v2.md` T1 → T10 on branch `pivot/contracts-v2`.
- Merged `pivot/contracts-v2` → `main` as `98baf7c` (no-ff). Both refs pushed to `origin`.
- Results matrix: `docs/plans/2026-04-22-contracts-v2-results.md`.
- Tests: 103/103 green. OrderBook/BitmapLib/TickMath/PackedOrder/ORDERBOOK_ROLE symbols absent from `contracts/`.

### Commits on main (this session)
```
98baf7c merge pivot/contracts-v2 — Path B contracts rebuild
a566c3b chore(contracts): T10 — forge fmt + results doc + src tidy
0ba8e51 test(contracts): T9b — rewrite LiquidationEngine unit tests (Path B)
5001cfe test(contracts): T9 — end-to-end Settlement batch integration
0c33b6c feat(contracts): T6+T7 — MarketFactory + Router + DeployCore
e084ddc feat(contracts): T3 — ISettlement + Settlement.sol skeleton
8892204 feat(contracts): T4 — Vault/PM batch entry points + equivalence gate
909720a refactor(contracts): T2 — rebind AUTHORIZED_ROLE → SETTLEMENT_ROLE
85ce34a refactor(contracts): T1 — delete bitmap orderbook surface
```

### Deferred from contracts-v2
- **T8 FundingRate** — not built in v1 per B2 scope decision. Phase 5.5 miniplan needed before rust-sequencer consumes funding. Settlement wires a stub `address fundingRate` slot; mid-price updates are a no-op loop in `_dispatchMidPriceUpdates`.
- **ADL placeholder** — LiquidationEngine unit tests omitted ADL path. Track when liquidation cascade design lands.

### In Progress
Nothing mid-flight. Clean worktree on `main`.

## Resume Here — Phase 5 continuation
1. Pick the next plan:
   - `docs/plans/2026-04-22-rust-sequencer.md` — 10 tasks, `gaekju-matching-core` + `gaekju-sequencer` crates (alloy + axum + tokio-tungstenite + sled).
   - `docs/plans/2026-04-22-rust-prover.md` — SP1 guest + public-inputs commit + prover service + Giwa submitter.
   - `docs/plans/2026-04-22-indexer-api-updates.md` — indexer/api/keeper/mirror/sdk/cli.
2. `rust-sequencer` unblocks the other two. Start there.
3. Execution style options:
   - Sequential via `sspower:executing-plans` (this session pattern).
   - Codex delegation via `codex-bridge.mjs implement --write` (this session used that for T6-T10; worked well, sandbox blocks `.git` writes so commits apply locally from the host).
   - Parallel via `sspower:subagent-driven-development` — sequencer + prover share `gaekju-matching-core`, so they are NOT fully independent; sequencer Task 1-2 must land before prover can reuse matching-core.

## Decisions (don't re-debate)

### Carried over from prior handoff
- Global Settlement (one contract, multi-market batches).
- vkey rotation: storage-backed + pause-and-drain (24h normal, 7d + paused-throughout force).
- Liquidation: on-chain only v1; no sequencer-routed `kind=Liquidate`.
- `ProofBundle` public inputs: `(prevStateRoot, postStateRoot, batchHash, batchNonce, chainId, forceIncludeCursor)`.
- Event: `BatchSettled`.
- Forced vs accepted intents: disjoint lists.
- Funding mark source: sequencer mid (60s staleness → pure oracle fallback); `MidPriceUpdate[]` sibling array, Settlement dispatches directly to FundingRate.
- Vault/PM split: Vault sole bucket-writer; PM position-state only.
- Batch cadence: 5s; `FORCE_INCLUDE_N = 3` batches (~15s).

### New this session
- **T8 FundingRate deferred to Phase 5.5.** Settlement ships without FundingRate; mid-price dispatch is a no-op. Rust sequencer should still emit `MidPriceUpdate[]` entries — Settlement accepts them. Rewire when FundingRate lands.
- **Router model.** Router is thin, but Vault grew a `ROUTER_ROLE` (`depositFor`, `withdrawTo`, `depositInsuranceFund`) and Settlement grew `forceIncludeFor(trader, …)` so Router preserves end-user trader identity on force-include without collapsing caller identity to the router address.
- **Intent decoding v1.** `Router.forceInclude` treats first 32 bytes of intent payload as `marketId`. Placeholder until EIP-712 envelope lands in rust-sequencer Task 3.
- **PnL sink for equivalence test.** `BatchEquivalence.t.sol` uses `address(0xBEEF)` as a counterparty to satisfy fills-conservation on one-fill gate batches. Not a production artifact.
- **Sandbox `.git` write.** `codex-bridge.mjs implement --write` cannot create commits in this sandbox (`Operation not permitted` on `.git/index.lock`). Work lands in the working tree; the host commits. Carry this forward.

## Gotchas (still valid)
- `BatchBlob` field order load-bearing for `keccak256(abi.encode(BatchBlob)) == batchHash`. Rust host, SP1 guest, Solidity decoder must agree: `(header, acceptedIntents, fills, balanceDeltas, midPriceUpdates, forcedOutcomes, attestedPriceIds, attestedPriceHashes)`. Spec §15.2.
- `BatchPublicInputs` uses `uint64`; Solidity `abi.encode` pads to `uint256`. Rust `abi_encode` must match; round-trip test required in rust-prover Task 3.
- `PositionManager.applyBatchFills` MUST NOT call `vault.*` inline; BatchEquivalence gate enforces this. Rust matcher must emit the corresponding `BalanceDelta[]` for every fill.
- `forge test --root contracts` can crash in Codex's sandbox on Foundry's macOS system-configuration path; `--offline` works. Local host runs both fine.

## Context
- **Branch**: `main` (pushed, clean).
- **Tests (contracts)**: 103 forge tests green. Rust crates green `cargo check` but Path B crates not yet built.
- **Superseded**: `2026-04-22-path-b-handoff.md` (pre-contracts-v2), prior `docs/handoff.md` (generated 2026-04-23, now replaced by this file).
- **Governing ADR**: `docs/adr/0012-zkvm-matcher-pivot.md`.
- **Canonical spec**: `docs/specs/2026-04-06-gaekju-design.md` §14 (Proof System), §15 (Settlement Contract), §15.3.1 (Vault/PM split), §15.5 (vkey rotation), §16 (Soft-Confirm UX).
