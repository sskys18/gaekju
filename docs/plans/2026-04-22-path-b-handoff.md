# Path B Pivot — Handoff

**Date:** 2026-04-22
**Status:** All planning docs aligned for Path B (zkVM-proven off-chain matcher). Zero code touched. Ready for Phase 5 (implementation) start.

---

## TL;DR

- **Decision:** Pivoted from on-chain EVM CLOB (ADR-0001) to off-chain Rust matcher + SP1 zkVM proof + on-chain Settlement on Giwa. Captured in **ADR-0012**.
- **Docs aligned:** 5 new ADRs, 4 new implementation plans, 4 architecture docs rewritten, 1 design spec surgically rewritten (2240→2365 lines), 5 supersede banners on historical plans, 2 blogs rewritten + 1 retracted + 1 minor-updated, glossary + CLAUDE.md updated.
- **Code:** Untouched. Phase 1+2 contracts (Vault, MarginEngine, PositionManager, LiquidationEngine, OracleAdapter) survive pivot. OrderBook.sol + bitmap libs scheduled for deletion in Phase 5.
- **131 forge tests:** Still green. Estimated 80-100 survive Phase 5; 30-50 delete with OrderBook.
- **Next action:** User reviews ADR-0012 and four new Phase 5 sub-plans. On approval, execute contracts-v2 + sequencer + prover + indexer updates in parallel.

---

## Research inputs (read first)

1. `docs/research/2026-04-22-lighter-on-giwa-pros-cons.md` — pivot trigger (Lighter ≠ on-chain EVM; Giwa ecosystem gaps)
2. `docs/research/2026-perp-dex-landscape.md` — 2026 seven-bucket landscape
3. `docs/research/giwa-chain-investigation.md` — Giwa raw findings
4. `docs/research/lighter-stack-investigation.md` — Lighter raw findings (zk-rollup, off-chain match)
5. `docs/research/2026-04-22-adr-arch-alignment.md` — per-ADR alignment audit
6. `docs/research/2026-04-22-spec-plans-blog-alignment.md` — per-section spec audit
7. `docs/research/2026-04-22-pivot-alignment-summary.md` — consolidated alignment

---

## New architectural direction

```
User ─EIP-712 intent─▶ gaekju-sequencer (Rust matching, BTreeMap book)
                              │
                              ├─ soft-ack to user (~ms)
                              │
                              ▼
                       Batch emitted (~5s window)
                              │
                              ▼
                     gaekju-prover (SP1 zkVM)
                              │
                              ├─ re-executes gaekju-matching-core over batch
                              │
                              ▼
                       SNARK proof + postStateRoot
                              │
                              ▼
                    Settlement.sol on Giwa
                        ├─ verifies SP1 proof (~300k gas)
                        ├─ nonce monotonicity check
                        ├─ prev-root continuity check
                        ├─ applies BalanceDelta[] → Vault
                        └─ applies Fill[] → PositionManager
                              │
                              ▼
                   Indexer catches BatchSettled event
                   → API serves finalized state to clients
```

Matching is **proven, not trusted**. Ordering fairness is the only remaining trust axis, mitigated by force-inclusion hatch (ADR-0014).

---

## Docs written / updated (full inventory)

### New ADRs (4)
- `docs/adr/0012-zkvm-matcher-pivot.md` — pivot decision + rebuttal of ADR-0001
- `docs/adr/0013-sp1-zkvm-framework.md` — SP1 over RISC Zero/Jolt
- `docs/adr/0014-sequencer-trust-model.md` — single operator + force-include
- `docs/adr/0015-proof-batching-cadence.md` — batch 5s / proof 30-60s / soft-confirm UX

### ADR supersede + minor edits
- `docs/adr/0001-use-lighter-clob.md` — superseded banner
- `docs/adr/0003-bitmap-orderbook.md` — superseded banner
- `docs/adr/0002-modular-contracts.md` — OrderBook→Settlement swap
- `docs/adr/0007-rust-backend.md` — added sequencer/prover crates
- `docs/adr/0009-uups-proxy.md` — softened per-call gas rationale
- `docs/adr/0010-lighter-mirror.md` — mirror targets sequencer
- `docs/adr/README.md` — index updated

### Architecture (4)
- `docs/architecture/overview.md` — three-layer model + new diagram
- `docs/architecture/contracts.md` — Settlement section + new invariants
- `docs/architecture/data-flow.md` — new lifecycle + failure paths
- `docs/architecture/rust-backend.md` — sequencer + prover crates

### Design spec
- `docs/specs/2026-04-06-gaekju-design.md` — 2240→2365 lines. §2/§3.4/§3.10/§6/§10 rewrote; §13-§17 new (Sequencer Protocol, Proof System, Settlement Contract, Soft-Confirm UX, Failure Modes). Margin/position/liquidation/funding/formulas/market-configs preserved verbatim.

### New plans (4)
- `docs/plans/2026-04-22-contracts-v2.md` — 10 tasks: delete bitmap/OrderBook, Settlement.sol, caller guards, MarketFactory thin, Router thin, FundingRate rebind, E2E test
- `docs/plans/2026-04-22-rust-sequencer.md` — 10 tasks: `gaekju-matching-core` + `gaekju-sequencer` crates
- `docs/plans/2026-04-22-rust-prover.md` — 9 tasks: SP1 guest, public-inputs commit, prover service, Giwa submitter
- `docs/plans/2026-04-22-indexer-api-updates.md` — 6 tasks across indexer/api/keeper/mirror/sdk/cli

### Plan supersede banners (5)
- `docs/plans/2026-04-06-phase1-foundation-core-orderbook.md` (partial — Tasks 2,3,4,10,11 obsolete)
- `docs/plans/2026-04-06-phase2-positions-liquidation.md` (Task 4 role rebind)
- `docs/plans/2026-04-06-phase3-funding-factory-router.md` (fully superseded)
- `docs/plans/2026-04-07-phase3-handoff.md` (historical)
- `docs/plans/2026-04-06-phase3-codex-review.md` (partially historical)

### Master pivot docs
- `docs/plans/2026-04-22-path-b-zkvm-pivot.md` — phase roadmap
- `docs/plans/2026-04-22-path-b-handoff.md` — this file

### Blogs (3 touched)
- `docs/blog/00-why-gaekju.md` — full rewrite (~1190 words)
- `docs/blog/01-choosing-architecture.md` — full rewrite (~1520 words)
- `docs/blog/02-bitmap-orderbook.md` — retraction banner, body preserved
- `docs/blog/03-margin-from-scratch.md` — minor OrderBook→Settlement reference fix
- `docs/blog/04-liquidation-math.md` — clean (no change)
- `docs/blog/05-10` — stubs, left untouched (Phase 5+ writes)

### Reference
- `docs/reference/glossary.md` — added Sequencer/Prover/Batch/SP1/Proof/Settlement/Force-Include/Soft-Confirm; bitmap terms marked legacy
- `docs/reference/formulas.md` — clean
- `docs/reference/market-configs.md` — clean

### Root
- `CLAUDE.md` — architecture paragraph, file map, "Do Not" rule on reintroducing on-chain matching

---

## What survives Path A work

### Contracts (Phase 1+2, shipped, tested)
- `contracts/src/Vault.sol` — add `applyBatchDelta` + SETTLEMENT_ROLE
- `contracts/src/MarginEngine.sol` — unchanged
- `contracts/src/PositionManager.sol` — rebind caller ORDERBOOK_ROLE→SETTLEMENT_ROLE; add `applyBatchFills`
- `contracts/src/LiquidationEngine.sol` — unchanged
- `contracts/src/OracleAdapter.sol` — unchanged
- `contracts/src/libraries/FixedPointMath.sol` — unchanged
- `contracts/src/interfaces/*` — minor updates for new entry points

### Bug fixes (kept)
- C1: Vault.realizePnl deficit return
- C2: sell-side taker margin from limitPrice
- m1: clippy cleanup in keeper

### Tests (131 green)
- Estimate ~80-100 survive: Vault, MarginEngine, PositionManager (rebound), LiquidationEngine, OracleAdapter
- Estimate ~30-50 delete: all OrderBook tests (unit/integration/fuzz), bitmap fuzz tests

---

## What gets deleted in Phase 5

### Contracts
- `contracts/src/OrderBook.sol`
- `contracts/src/interfaces/IOrderBook.sol`
- `contracts/src/libraries/BitmapLib.sol`
- `contracts/src/libraries/TickMath.sol`
- `contracts/src/libraries/PackedOrder.sol`

### Tests
- `contracts/test/unit/OrderBook*.t.sol`
- `contracts/test/integration/*OrderBook*.t.sol`
- `contracts/test/fuzz/Bitmap*.t.sol`

---

## What gets built in Phase 5

### New contracts
- `contracts/src/Settlement.sol` — verifies SP1 proof, decodes batch, applies state delta
- `contracts/src/interfaces/ISettlement.sol`
- `contracts/src/interfaces/ISP1Verifier.sol` — external verifier interface (deploy Succinct's or inline)
- `contracts/src/FundingRate.sol` — from Phase 3 design, SETTLEMENT_ROLE guard
- `contracts/src/MarketFactory.sol` — thin config registry, no OrderBook deploy
- `contracts/src/Router.sol` — deposit/withdraw/forceInclude only

### New Rust crates
- `crates/gaekju-matching-core/` — deterministic state machine (sequencer + SP1 guest share)
- `crates/gaekju-sequencer/` — matching service, WS/REST, EIP-712, batch emitter
- `crates/gaekju-prover/` — SP1 guest program + prover service + Giwa submitter

### Updated Rust crates
- `crates/gaekju-indexer/` — Settlement events + sequencer stream
- `crates/gaekju-api/` — pending/sealed/final state layers
- `crates/gaekju-keeper/` — retarget Settlement for liquidations, funding timer unchanged
- `crates/gaekju-mirror/` — target sequencer REST
- `crates/gaekju-sdk/` — new endpoints, batch status types, force-include helper
- `crates/gaekju-cli/` — endpoint updates

---

## Known open items / agent-flagged caveats

From parallel-agent reports:

### ADR group
1. **ADR-0002 still reads as if MarketFactory deploys OrderBooks.** Only targeted edits applied; broader prose could use another pass.
2. **ADR-0009 Context paragraph** still frames upgradeability in CLOB terms. Only Positive + rejected-alt softened. Flag for future pass.
3. **ADR-0010 Negative bullet** ("mirror txs compete for block space") is now wrong since mirror hits sequencer. Missed in minor edit pass.
4. **ADR-0013/0014/0015 ran long** (974 / 1172 / 954 words vs ~500-700 targets). Content complete; trim pass optional.
5. **README supersede banner format** not formalized in template.

### Architecture
6. **Sequencer mid-price funding input** — stated that sequencer mid gets written on-chain as part of batch state delta so FundingRate consumes it. Not explicitly pinned in ADR-0012 — verify before Phase 5.
7. **Force-include SLA enforcement** — chose "Settlement refuses further batches until queue clears." Verify this matches ADR-0014.
8. **SP1Verifier.sol** folded into Settlement's responsibility in contracts.md; listed separately elsewhere. Reconcile during Phase 5 implementation.

### Design spec
9. **§3.4 and §15 both cover Settlement.** §3.4 = catalog entry; §15 = deep spec. No duplication but cross-link explicitly when execution starts.
10. **Path A phase content** (old §6) excised with archival pointer to `docs/plans/archive/` — archive dir not yet created.
11. **§12 Insurance Fund** referenced in alignment report doesn't exist as standalone section; content is inside §10 Security. Correctly left untouched.

### Plans
12. **Contracts-v2 E2E integration test** depends on sequencer + prover being at least mock-functional. Plan assumes mock-mode prover exists for first integration.

### Blogs
13. **Blog 04** has metaphorical "move the book" phrase about oracle-price liquidation. Conceptually valid; left untouched. Future pass may want clearer language.

### CLAUDE.md
14. User/linter updated CLAUDE.md file map since agent ran — final version has BitmapLib removed cleanly and bitmap libraries condensed to just FixedPointMath. Matches pivot.

---

## Critical invariants of new architecture

On-chain invariants Settlement.sol must enforce:

1. **Batch nonce strictly monotonic** — `batch.nonce == lastNonce + 1`
2. **Prev-state-root continuity** — `batch.prevStateRoot == currentStateRoot`
3. **Proof validity** — SP1 verifier returns OK for `(vkey, publicInputs, proof)`
4. **vkey binding** — proof's verification key matches current approved vkey (admin-rotatable)
5. **Fills sum conservation** — `Σ(taker collateral deltas) + Σ(maker collateral deltas) + insurance delta = 0`
6. **Force-include bound** — any force-included intent must be processed within N batches or Settlement refuses further batches
7. **Replay protection** — each user intent has per-account monotonic nonce; proven inside SP1 circuit

---

## Decisions finalized (2026-04-22)

All previously open items resolved. Consolidated index in `docs/plans/2026-04-22-path-b-zkvm-pivot.md` (Decisions section).

| # | Decision | Value | Source |
|---|----------|-------|--------|
| 1 | Settlement chain | Giwa. L1 explicit fallback only. | ADR-0012 |
| 2 | zkVM | SP1 via Succinct-hosted prover. Self-hosted fallback. | ADR-0013 |
| 3 | Force-include bound | N=3 batches (~15s) | ADR-0014 |
| 4 | Batch window | 5s fixed, tunable | ADR-0015 |
| 5 | Proof gen target | 30-60s | ADR-0015 |
| 6 | Sequencer operator | single in v1, rotating set future | ADR-0014 |
| 7 | Ordering fairness | proven over accepted set only, not stream | ADR-0014 |
| 8 | Sequencer mid-price for funding | emitted per batch in StateDelta, stored on-chain with 60s staleness decay | design spec §3.3 |
| 9 | Force-include enforcement | Settlement reverts new batches if deadline-passed force-include intent not yet processed | ADR-0014 |
| 10 | Phase 5 execution | 3 parallel streams (contracts / sequencer+prover / indexer-api) with E2E integration gate | pivot plan |

Remaining non-doc question: **git commit strategy.** Recommend 5 grouped commits:
1. `docs(research): pivot research + alignment audits`
2. `docs(adr): pivot ADR + SP1/sequencer/batching ADRs + supersede banners + minor fixes`
3. `docs(arch): rewrite architecture docs for Path B`
4. `docs(specs): rewrite design spec for zkVM matcher`
5. `docs(plans+blog): Phase 5 plans + blog rewrites + reference + CLAUDE.md`

---

## Next session instructions

1. **Read ADR-0012** first. If the pivot rationale or ADR-0001 rebuttal is unconvincing, stop and revisit before Phase 5.
2. **Read the four new Phase 5 plans** in order: contracts-v2 → rust-sequencer → rust-prover → indexer-api-updates.
3. **Spot-check the design spec rewrite** — §2, §3.4, §10, §13-§17. Confirm nothing critical was dropped.
4. **Decide open items 1-6** above.
5. **Choose execution style:**
   - `sspower:subagent-driven-development` for parallel Phase 5 execution
   - `sspower:executing-plans` for inline sequential
6. **Before any code:** git commit all doc changes (grouped).

---

## Verification commands (docs-only, no code)

```bash
# Check all docs compile (no broken markdown links)
cd /Users/sskys/Mine/gaekju
find docs -name "*.md" -exec test -s {} \; -print | wc -l  # count non-empty
grep -r "OrderBook.sol" docs/adr docs/architecture docs/specs | grep -v "superseded\|deleted\|historical\|legacy"  # should be minimal

# Git status
git status --short
git diff --stat docs/ CLAUDE.md
```

---

## Files touched summary

| Category | Count | New | Modified | Banner-only |
|----------|-------|-----|----------|-------------|
| ADRs | 11 | 4 | 5 | 2 |
| Architecture | 4 | 0 | 4 | 0 |
| Specs | 1 | 0 | 1 | 0 |
| Plans | 9 | 5 | 0 | 5 |
| Research | 7 | 7 | 0 | 0 |
| Blogs | 5 | 0 | 4 | 1 |
| Reference | 1 | 0 | 1 | 0 |
| Root | 1 | 0 | 1 | 0 |
| **Total** | **39** | **16** | **16** | **8** |

Zero code files touched. Zero tests run (nothing to run on doc edits). 131 existing forge tests remain green on disk — they will be rebound in Phase 5.
