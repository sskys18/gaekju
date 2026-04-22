# Path B Pivot Plan — zkVM Matcher Architecture

**Date:** 2026-04-22
**Decision:** Pivot from on-chain EVM CLOB → off-chain Rust matcher + SP1 zkVM proof + on-chain settlement on Giwa.
**Status:** Planning. No code changes until user approves phase-by-phase.

---

## Context

Research (`docs/research/2026-04-22-lighter-on-giwa-pros-cons.md`, `docs/research/2026-perp-dex-landscape.md`) shows:

- On-chain EVM CLOB is novel territory for perps. No working precedent at scale.
- Giwa ecosystem gaps (Pyth, USDC, RPC) make pure-on-chain risky.
- 2026 landscape dominated by: Hyperliquid (own L1), Lighter/Paradex (ZK + off-chain match), Hyperliquid-shape (off-chain match + settle).
- User-chosen direction: **Path B — zkVM matcher (SP1/RISC Zero)**. Preserves "ZK proof of correctness" narrative without custom circuits.

### New architecture

```
User → Rust sequencer (off-chain OrderBook, matches orders deterministically)
     → SP1 zkVM (batches N orders/fills, produces proof of matching correctness)
     → Settlement.sol on Giwa (verifies SP1 proof, applies state delta to Vault/Positions)
     → Margin / Liquidation / Funding / Oracle stay in Solidity
```

### What this pivot changes

| Component | Before (Path A) | After (Path B) |
|-----------|-----------------|----------------|
| `OrderBook.sol` | Full bitmap CLOB, ~20KB | Deleted. Replaced by `Settlement.sol` (proof verifier + state applier) |
| `BitmapLib`, `TickMath`, `PackedOrder` | Core | Deleted (orderbook state lives in Rust) |
| `PositionManager.sol` | Called by OrderBook | Called by Settlement.sol with proven state deltas |
| `Vault.sol` | OK | OK — add `applyBatchDelta` caller guard |
| `MarginEngine.sol` | OK | OK — called during settlement |
| `LiquidationEngine.sol` | Calls PositionManager | Same, unchanged |
| `FundingRate.sol` (Phase 3) | Called by PM | Same, unchanged |
| `OracleAdapter.sol` | OK | OK — used by both sequencer and settlement |
| `MarketFactory.sol` (Phase 3) | Deploys OrderBook | Deploys Settlement (per market) |
| `Router.sol` (Phase 3) | Wraps OrderBook calls | Wraps sequencer API (off-chain) + deposit/withdraw on-chain |
| `crates/gaekju-sequencer/` | N/A | **NEW** — Rust matching engine |
| `crates/gaekju-prover/` | N/A | **NEW** — SP1 prover service |
| `crates/gaekju-keeper/` | OK | Keep (liquidation/funding bots) |
| `crates/gaekju-indexer/` | Indexes on-chain events | Indexes sequencer WS + on-chain settlements |
| `crates/gaekju-api/` | Reads on-chain state | Reads sequencer state + on-chain state |

### What to keep from current work

- All research docs ✓
- Vault / MarginEngine / PositionManager / LiquidationEngine / OracleAdapter (tested, Phase 1+2 work)
- C1 / C2 / m1 bug fixes (already applied)
- FundingRate design (Phase 3 plan, slightly adapted)
- Phase 2 test suite (131 tests — most still apply, OrderBook tests get deprecated)
- Lighter mirror (ADR-0010) — still used for liquidity bootstrap

### What to throw away

- `OrderBook.sol` and interface — matching moves off-chain
- `BitmapLib.sol`, `PackedOrder.sol`, `TickMath.sol` — orderbook state no longer on-chain
- Phase 3 plan's Task 5 (IOC/FOK order types in OrderBook) — handled by sequencer
- Bitmap orderbook blog post — needs rewrite or retraction

---

## Plan Scope

This is a **pivot plan**, not an implementation plan. It enumerates every doc/code file to revise and the order of revision. Each phase gates on user approval.

**Total estimated effort:** 3–6 months engineering (per research).

---

## Execution Phases

### Phase 0 — Doc Freeze & Pivot ADR (this plan, ~1 day)

Goal: Lock in the decision. Supersede obsolete ADRs. Publish pivot ADR.

| Task | File | Action |
|------|------|--------|
| 0.1 | `docs/adr/0012-zkvm-matcher-pivot.md` | **NEW.** Record Path B decision with full rationale, alternatives, consequences |
| 0.2 | `docs/adr/0001-use-lighter-clob.md` | Add `## Status: Superseded by ADR-0012` header; keep body for history |
| 0.3 | `docs/adr/0003-bitmap-orderbook.md` | Same — mark superseded |
| 0.4 | `docs/adr/README.md` | Update index |

**Approval gate:** User reads ADR-0012. If yes → proceed to Phase 1.

---

### Phase 1 — Architecture Rewrite (~2 days)

Goal: Update all architecture docs to reflect new system shape.

| Task | File | Action |
|------|------|--------|
| 1.1 | `docs/architecture/overview.md` | Rewrite system diagram + "two layers" section. Now 3 layers: sequencer (off-chain), prover (off-chain), settlement (on-chain) |
| 1.2 | `docs/architecture/contracts.md` | Remove OrderBook section. Add Settlement section. Document proof verifier interface |
| 1.3 | `docs/architecture/rust-backend.md` | Add sequencer + prover services. Update indexer/API scope |
| 1.4 | `docs/architecture/data-flow.md` | New flow: signed intent → sequencer → match → batch → prove → settle → indexer → client |
| 1.5 | `docs/adr/0013-sp1-zkvm-framework.md` | **NEW.** SP1 vs RISC Zero vs Jolt choice. Document prover cost, latency, Ethereum verifier gas |
| 1.6 | `docs/adr/0014-sequencer-trust-model.md` | **NEW.** Single sequencer, ordering fairness limits, escape hatch, censorship recovery |
| 1.7 | `docs/adr/0015-proof-batching-cadence.md` | **NEW.** Batch size, settlement frequency, soft-confirm UX |

**Approval gate:** User reviews new architecture. If yes → proceed.

---

### Phase 2 — Design Spec Rewrite (~3 days)

Goal: Replace matching/orderbook sections of `2026-04-06-gaekju-design.md`. Keep margin/funding/liquidation/oracle sections mostly intact.

| Task | File | Action |
|------|------|--------|
| 2.1 | `docs/specs/2026-04-06-gaekju-design.md` §Matching | Delete bitmap orderbook spec. Replace with sequencer state machine spec (order struct, matching rules, fill events) |
| 2.2 | Same §Settlement | **NEW.** Batch format, state delta schema, proof verifier contract interface, replay protection |
| 2.3 | Same §Sequencer API | **NEW.** WS protocol, REST endpoints, signed intent format (EIP-712), nonce scheme |
| 2.4 | Same §Proof System | **NEW.** SP1 circuit inputs/outputs, public-inputs commitment, verifier gas target |
| 2.5 | Same §Soft-Confirm UX | **NEW.** User-facing timing: sequencer ack (ms) → batch close (~1-5s) → proof gen (~30s-2min) → on-chain finalize |
| 2.6 | Same §Failure Modes | Add: sequencer halt, prover halt, proof invalid, batch reversion. Remove: gas-limit matching failure |
| 2.7 | Same §Risk Engine | Keep mostly. Update to clarify margin checks run **inside the proven batch**, not per-order |

**Approval gate:** User reviews revised spec. If yes → proceed.

---

### Phase 3 — Contracts Pivot Plan (~2 days)

Goal: Rewrite `2026-04-06-phase3-funding-factory-router.md` for new contract surface.

| Task | File | Action |
|------|------|--------|
| 3.1 | `docs/plans/2026-04-22-contracts-v2.md` | **NEW** plan. Enumerate contract changes. Supersedes existing Phase 3 plan |
| 3.2 | Plan item: Delete `OrderBook.sol`, `BitmapLib.sol`, `TickMath.sol`, `PackedOrder.sol`, `IOrderBook.sol`. Delete associated tests. | — |
| 3.3 | Plan item: New `Settlement.sol` + `ISettlement.sol` — verifies SP1 proof, decodes state delta, calls Vault/PositionManager | — |
| 3.4 | Plan item: New `SP1Verifier.sol` (or reuse Succinct's deployed verifier contract on Giwa if available; fallback inline) | — |
| 3.5 | Plan item: Adapt `PositionManager.sol` — add `applyBatchFills(Fill[] calldata)` entry callable only by Settlement. Remove OrderBook caller path | — |
| 3.6 | Plan item: Adapt `Vault.sol` — add `applyBatchDelta` callable only by Settlement | — |
| 3.7 | Plan item: `FundingRate.sol` — unchanged from Phase 3 design except caller guard moves from PM to Settlement | — |
| 3.8 | Plan item: `MarketFactory.sol` — deploys Settlement per market instead of OrderBook | — |
| 3.9 | Plan item: `Router.sol` — thin contract, only deposit/withdraw + `forceInclude(intent)` escape hatch |
| 3.10 | Plan item: Mark previously-planned Phase 3 tasks obsolete: Task 5 (IOC/FOK in OrderBook) |
| 3.11 | Mark old Phase 3 plan: add `## Status: Superseded by 2026-04-22-contracts-v2.md` |

**Approval gate:** User reviews contracts-v2 plan. If yes → proceed.

---

### Phase 4 — Rust Services Plan (~2 days)

Goal: Plan for new sequencer + prover crates.

| Task | File | Action |
|------|------|--------|
| 4.1 | `docs/plans/2026-04-22-rust-sequencer.md` | **NEW** plan. `crates/gaekju-sequencer/` — orderbook state machine, WS/REST API, EIP-712 verify, batch emitter |
| 4.2 | `docs/plans/2026-04-22-rust-prover.md` | **NEW** plan. `crates/gaekju-prover/` — SP1 program, prover service, proof submission to Settlement |
| 4.3 | `docs/plans/2026-04-22-indexer-api-updates.md` | **NEW** plan. Update `gaekju-indexer` / `gaekju-api` to read sequencer + on-chain state |
| 4.4 | Plan item: Shared types crate `gaekju-types` — batch format, intent format, fill format, keep ABI bindings updated | — |
| 4.5 | Plan item: `gaekju-keeper` — unchanged logic, update targets (Settlement address for liquidations) | — |

**Approval gate:** User reviews Rust plans. If yes → proceed to execution.

---

### Phase 5 — Execution (months, not in this plan)

Once all planning docs are approved and consistent:
1. Execute `contracts-v2` plan via `sspower:subagent-driven-development`
2. Parallel: execute sequencer crate
3. Execute prover crate (depends on sequencer batch format)
4. Update indexer/api
5. Integration tests end-to-end
6. Testnet deploy

Not scoped here. Decide after Phase 0-4 land.

---

## File Inventory

### New files (created in Phases 0-4)

Docs (~14 files):
- `docs/adr/0012-zkvm-matcher-pivot.md`
- `docs/adr/0013-sp1-zkvm-framework.md`
- `docs/adr/0014-sequencer-trust-model.md`
- `docs/adr/0015-proof-batching-cadence.md`
- `docs/plans/2026-04-22-contracts-v2.md`
- `docs/plans/2026-04-22-rust-sequencer.md`
- `docs/plans/2026-04-22-rust-prover.md`
- `docs/plans/2026-04-22-indexer-api-updates.md`

### Modified files

- `docs/adr/0001-use-lighter-clob.md` (mark superseded)
- `docs/adr/0003-bitmap-orderbook.md` (mark superseded)
- `docs/adr/README.md`
- `docs/architecture/overview.md`
- `docs/architecture/contracts.md`
- `docs/architecture/rust-backend.md`
- `docs/architecture/data-flow.md`
- `docs/specs/2026-04-06-gaekju-design.md` (major rewrite of matching sections)
- `docs/plans/2026-04-06-phase3-funding-factory-router.md` (mark superseded)
- `docs/plans/2026-04-07-phase3-handoff.md` (mark stale)
- `CLAUDE.md` (update architecture summary)

### Files to delete (Phase 5, not now)

- `contracts/src/OrderBook.sol`
- `contracts/src/IOrderBook.sol`
- `contracts/src/libraries/BitmapLib.sol`
- `contracts/src/libraries/TickMath.sol`
- `contracts/src/libraries/PackedOrder.sol`
- `contracts/test/unit/OrderBook*.t.sol`
- `contracts/test/integration/*OrderBook*.t.sol`
- `contracts/test/fuzz/Bitmap*.t.sol`
- `docs/blog/*bitmap-orderbook*.md` (keep but add retraction note)

---

## Decisions (finalized 2026-04-22)

All previously-open items resolved. Values captured in the ADRs listed; this section is the consolidated index.

| # | Decision | Value | ADR |
|---|----------|-------|-----|
| 1 | zkVM framework | **SP1** (Succinct). Fallback: self-hosted SP1 prover if managed network fails. | ADR-0013 |
| 2 | Settlement chain | **Giwa Chain** (stay). Ethereum L1 is explicit fallback only if Giwa proves unviable for ZK verifier gas or uptime. | ADR-0012 |
| 3 | Batch window | **5 seconds** fixed, tunable via governance. | ADR-0015 |
| 4 | Proof generation target | **30-60 seconds** under normal load. | ADR-0015 |
| 5 | On-chain settlement | Next Giwa block after proof arrival (~1s). | ADR-0015 |
| 6 | Sequencer operator | **Single operator** in v1. Future: rotating set under `SEQUENCER_ROLE`. | ADR-0014 |
| 7 | Force-include bound | **N = 3 batches** (~15 seconds worst-case). Settlement refuses new batches if a force-included intent is older than N batches without being processed. | ADR-0014 |
| 8 | Ordering fairness | Proven only over accepted set (price-time priority per the sequencer's input ordering). Stream-level ordering is NOT proven in-circuit — same as Lighter. Reordering observable via post-batch state-root commitment. | ADR-0014 |
| 9 | Proving infra | **Succinct-hosted prover network** for v1. Self-hosted SP1 prover as fallback. | ADR-0013 |
| 10 | Surviving Phase 1+2 contracts | Keep: Vault, MarginEngine, PositionManager, LiquidationEngine, OracleAdapter. Rebind caller role `ORDERBOOK_ROLE → SETTLEMENT_ROLE`. | ADR-0012 |
| 11 | Sequencer mid-price for funding | Sequencer emits current mid-price as part of each batch's state delta. Settlement writes it to a public storage slot that FundingRate reads during `applyFunding()`. Mark price blend (70% oracle / 30% sequencer-mid) continues to hold. | §3.8 design spec + §15 |
| 12 | Force-include enforcement | Settlement tracks `forceIncludeDeadline[intent]` = batchNonce at submission + 3. Any submitted batch that does not include a deadline-passed force-include intent reverts. | ADR-0014 |

## Phase 5 execution order (finalized)

- **Stream A (contracts-v2):** sequential. Delete bitmap/OrderBook → write Settlement → rebind caller guards → E2E Foundry tests.
- **Stream B (rust-sequencer + rust-prover):** start in parallel with Stream A once `gaekju-matching-core` crate exists (shared by sequencer + SP1 guest).
- **Stream C (indexer/api/keeper/mirror/sdk/cli updates):** gated on Stream A interfaces + Stream B WS schema.

Integration gate: all three streams must pass a common E2E test (submit intent → sequencer match → SP1 prove → Giwa settle → indexer event → API query) before testnet deploy.

Recommended dispatch: `sspower:subagent-driven-development` with 3 worktrees (A, B, C), single integration branch merged at end.

---

## Risk Register

| Risk | Mitigation |
|------|------------|
| SP1 prover cost unexpectedly high at batch scale | Benchmark with 10/100/1000-order batches early (Phase 5 day-1 task) |
| Giwa ZK-verify gas prohibitive | Test Succinct's deployed verifier on Giwa; fallback to L1 settlement |
| Sequencer downtime | Force-inclusion path + clear UX for "sequencer offline" mode |
| Proof invalid (bug in SP1 program) | Formal review + shadow-match against previous matching impl; kill switch in Settlement |
| Batch revert on-chain | Idempotent state deltas; replay protection via batch nonce |
| Migration from Phase 2 test suite | Keep PositionManager/Vault/MarginEngine/LiquidationEngine tests intact; write new Settlement integration tests |
| Team skill gap on SP1 | Budget 2 weeks ramp-up; start with SP1 tutorial fork |

---

## Status

All Phase 0-4 doc work complete as of 2026-04-22. All decisions above finalized and reflected in ADRs 0012-0015, design spec §13-§17, and the four Phase 5 plans (contracts-v2, rust-sequencer, rust-prover, indexer-api-updates).

Phase 5 is the next gate. Not yet executed.

See `docs/plans/2026-04-22-path-b-handoff.md` for execution handoff.
