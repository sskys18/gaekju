# Session Handoff
> Generated: 2026-04-24 12:23 — after rust-sequencer merge + CI fix

## Task
Path B Phase 5 execution. `contracts-v2` + `rust-sequencer` both merged to main and CI-green. Next: `rust-prover` → `indexer-api` → Phase 5.5 FundingRate miniplan.

## Status

### Completed this session
- Executed `docs/plans/2026-04-22-contracts-v2.md` T1-T10 (minus T8). Merged `pivot/contracts-v2` → `main` as `98baf7c`.
- Executed `docs/plans/2026-04-22-rust-sequencer.md` T1-T10 via codex. Merged `rust/sequencer` → `main` as `6545fcf`.
- Fixed main CI (OZ lib pinning + drop `__Pausable_init` / `__UUPSUpgradeable_init` calls which don't exist in vanilla OZ v5.6.1). Local `contracts/lib/openzeppelin-contracts-upgradeable` was patched to re-add them, masking the break — see `6600cbb`, `56104d4`, `ee30bbd`.
- Last green CI: run `24870314487` (contracts + rust both success).

### In Progress
Nothing mid-flight. Clean worktree on `main`. Branches `pivot/contracts-v2` + `rust/sequencer` remain on origin.

## Resume Here
Pick one of:
1. **Rust prover** — `docs/plans/2026-04-22-rust-prover.md`. Cut `feat/rust-prover`, delegate T1-N via `codex-bridge.mjs implement --write --effort high`. Use the same briefing pattern from the in-session codex calls (see message history for T6+T7 and T1-T10 rust-sequencer prompts — both worked).
2. **Indexer / API / keeper / SDK / CLI updates** — `docs/plans/2026-04-22-indexer-api-updates.md`. Smaller scope; touches existing crates. Independent of prover, can parallel.
3. **FundingRate Phase 5.5** — no plan written yet. Needed before mark-price blend reattaches. Settlement has a `fundingRate` slot but `_dispatchMidPriceUpdates` is a no-op. Write `docs/plans/2026-04-24-funding-rate-phase5p5.md` first via `sspower:writing-plans`, then execute.

Parallel option: run prover + indexer-api in two background codex shots — they don't share files.

## Decisions (don't re-debate)

### Carried over
- Global Settlement, vkey pause-and-drain rotation, on-chain-only liquidation v1, forced-vs-accepted disjoint lists, 5s batch cadence, `FORCE_INCLUDE_N = 3`, Vault sole bucket-writer, PM position-state only.
- Canonical `BatchBlob` field order (spec §15.2, load-bearing for hash): `(header, acceptedIntents, fills, balanceDeltas, midPriceUpdates, forcedOutcomes, attestedPriceIds, attestedPriceHashes)`.

### This session
- **FundingRate deferred to Phase 5.5**. Sequencer emits `MidPriceUpdate[]` entries; Settlement's `_dispatchMidPriceUpdates` is a no-op. Rewire when FundingRate lands.
- **Router model**: thin shim, but Vault gained `ROUTER_ROLE` + `depositFor`/`withdrawTo`/`depositInsuranceFund` and Settlement gained `forceIncludeFor(trader,…)` so end-user identity survives the router hop.
- **v1 intent encoding for Router.forceInclude**: first 32 bytes of intent payload = `marketId`. Placeholder until EIP-712 envelope lands in prover/sequencer cross-check.
- **OZ pin**: CI + local must agree on v5.6.1 of contracts + contracts-upgradeable; local lib had been patched. Any future Upgradeable helper that isn't in vanilla OZ v5.6.1 will break CI again — cross-check against `https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts-upgradeable/v5.6.1/...`.
- **Codex bridge sandbox**: `codex-bridge.mjs implement --write` cannot write `.git/index.lock` in its sandbox. Work lands in the worktree; host commits manually.

## Gotchas
- `BatchPublicInputs` uses `uint64`; Solidity `abi.encode` pads to `uint256`. Rust `abi_encode` must match — round-trip test required (rust-prover T3).
- `PositionManager.applyBatchFills` MUST NOT call `vault.*` inline. `BatchEquivalence.t.sol` gate enforces this. Prover guest must emit matching `BalanceDelta[]` for every fill.
- `BatchEquivalence.t.sol` uses `PNL_SINK = address(0xBEEF)` as counterparty. Not production — real matcher emits maker+taker legs.
- `forge test --root contracts` can panic in codex's macOS sandbox on Foundry's system-configuration path; use `--offline`. Local host fine.
- Previous `docs/handoff.md` (generated 2026-04-24 after contracts-v2 merge) has been superseded by this file. The file before that — `docs/plans/2026-04-22-path-b-handoff.md` — is historical.

## Context
- **Branch**: `main` (pushed, clean). `pivot/contracts-v2` + `rust/sequencer` preserved on `origin`.
- **Tests**:
  - `forge test --root contracts`: 103/103 green.
  - `cargo test --workspace`: 9 suites across matching-core + sequencer + types + existing crates, all green.
  - `cargo clippy --all-targets --all-features -- -D warnings`: clean.
  - `cargo check -p gaekju-matching-core --no-default-features --features zkvm`: clean (SP1 guest compile path).
- **Last commits**: `6545fcf`, `6600cbb`, `56104d4`, `ee30bbd`, `2b57e55`.
- **Governing ADR**: `docs/adr/0012-zkvm-matcher-pivot.md`.
- **Canonical spec**: `docs/specs/2026-04-06-gaekju-design.md` §14-§17.
