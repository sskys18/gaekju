# Path B Pivot — Consolidated Doc Alignment

**Date:** 2026-04-22
**Source reports:** `2026-04-22-adr-arch-alignment.md`, `2026-04-22-spec-plans-blog-alignment.md`
**Purpose:** One-page status before approving Phase 0.

---

## Totals

| Category | Files | Full rewrite / supersede | Minor edit | No change |
|----------|-------|-------------------------|------------|-----------|
| ADRs | 11 + README | 2 (0001, 0003) | 5 (0002, 0007, 0009, 0010, README) | 5 (0004, 0005, 0006, 0008, 0011) |
| Architecture | 4 | 2 (overview, contracts) | 2 (data-flow, rust-backend) | 0 |
| Design spec | 1 | Major (5 sections) | Several | ~40% keeps |
| Plans | 6 | Phase 3 main plan | Phase 1, Phase 2 (superseded banner only) | Handoff/codex-review history only |
| Blogs | 11 | 00, 01 | 03 | 04 keep; 05-10 stubs; 02 retract-and-retain |
| Reference | 3 | — | glossary.md | formulas.md, market-configs.md |
| Root | 1 | — | CLAUDE.md | — |
| **Total** | **~35 active docs** | **~7 full rewrites** | **~12 minor edits** | **~16 untouched** |

---

## What survives the pivot (load-bearing, unchanged)

- **ADR-0004 Pyth oracle** — valid, adapter still used by both sequencer and Settlement
- **ADR-0005 USDC collateral** — unchanged
- **ADR-0006 Isolated margin** — unchanged
- **ADR-0008 Alloy over ethers** — unchanged
- **ADR-0011 1h funding interval** — unchanged
- **Vault / MarginEngine / PositionManager / LiquidationEngine / OracleAdapter** — all keep
- **Phase 1+2 contracts + tests (131 green)** — keep, rebind caller guards
- **Funding / liquidation / margin math in design spec §3.5-3.8, §8** — keep
- **Formulas reference doc** — keep verbatim
- **Lighter mirror (ADR-0010)** — target changes from OrderBook → Sequencer, otherwise keeps
- **C1 / C2 / m1 bug fixes** — keep

---

## What fully contradicts the pivot (full rewrite / supersede)

### Docs
1. **ADR-0001** — "on-chain CLOB" is the thesis. Supersede. Body retained for history.
2. **ADR-0003** — bitmap orderbook. Supersede.
3. **Design spec §2** (Architecture) — "two layers" model must become three-layer.
4. **Design spec §3.4** (OrderBook contract) — delete. Replace with Settlement.
5. **Design spec §3.10** (Router) — thin router with force-include escape hatch.
6. **Design spec §6** (Build Phases) — rewrite phase list.
7. **Design spec §10** (Security) — new invariants (batch nonce monotonicity, prev-state-root commitment); drop `bestBid < bestAsk` on-chain invariant.
8. **Blog 00 (why-gaekju)** — pitch currently "on-chain CLOB".
9. **Blog 01 (choosing-architecture)** — explicit on-chain decision narrative.
10. **Phase 3 plan** (`2026-04-06-phase3-funding-factory-router.md`) — MarketFactory/Router/OrderBook-IOC tasks obsolete; FundingRate section keeps.

### Code (Phase 5, not yet)
- `OrderBook.sol`, `IOrderBook.sol`
- `BitmapLib.sol`, `TickMath.sol`, `PackedOrder.sol`
- All OrderBook-touching tests (unit/integration/fuzz)

---

## What needs minor edits

- **ADR-0002** Modular contracts — swap `OrderBook` → `Settlement` in contract list
- **ADR-0007** Rust backend — add `gaekju-sequencer` and `gaekju-prover` crates
- **ADR-0009** UUPS proxy — soften per-call gas argument (now off-chain)
- **ADR-0010** Lighter mirror — redirect mirror target from OrderBook to Sequencer
- **ADR-README** — status flips, new entries (0012-0015)
- **architecture/overview.md** — 3-layer diagram, sequencer/prover in rust layer
- **architecture/contracts.md** — remove BitmapLib/PackedOrder/TickMath rows; add Settlement invariants
- **architecture/data-flow.md** — new order lifecycle (intent → sequencer → batch → prove → settle)
- **architecture/rust-backend.md** — minor; new crate blurbs
- **Design spec §3.1** — delete libraries subsections for bitmap/packed/tick
- **Design spec §11** Lighter mirror — note mirror target changed
- **Blog 02 (bitmap-orderbook)** — retract-and-retain with banner
- **Blog 03 (margin-math)** — keep math, minor wording
- **reference/glossary.md** — add Sequencer / Prover / Batch / SP1 / Proof / Settlement; mark Bitmap legacy
- **CLAUDE.md** — add sequencer/prover crates, "no on-chain matching" rule

---

## What gets superseded banner only (history preserved)

- **Phase 1 plan** — executed, some tasks now obsolete (Tasks 2,3,4,10,11); rest keeps
- **Phase 2 plan** — executed, 131 tests green, Task 4 wiring rebinds caller
- **Phase 3 handoff** — historical
- **Phase 3 codex review** — partial keep (bug-fix review stays; Factory/Router review historical)

---

## Critical risks flagged by audit

### 1. ADR-0001's own rejection of off-chain matching argues against the pivot
The current ADR-0001 rejects Hyperliquid-style off-chain matching with: *"An off-chain matching engine on a testnet L2 defeats the purpose. The goal is trustless execution. If we wanted centralized matching, we would build a CEX."*

**ADR-0012 must rebut this explicitly.** Rebuttal: ZK-proof of matching correctness preserves trustless execution for *logic*. Ordering fairness is the only remaining trust axis, mitigated by force-inclusion escape hatch + single-sequencer transparency. Not equivalent to a CEX.

### 2. On-chain invariants change vocabulary
`bestBid < bestAsk`, `orderId → owner`, `TickBitmap.bestBid ≤ bestAsk` — all unverifiable on-chain once matching moves off-chain.

**Replace with:**
- Batch nonce strictly monotonic
- `postStateRoot = f(prevStateRoot, batch)` proven by SP1
- Per-batch commitment of (accepted intents, rejected intents) hash
- Fills sum conservation: Σ(taker fills) + Σ(maker fills) + insurance delta = 0 collateral-invariant

### 3. Lighter mirror rebind
Mirror currently targets OrderBook.placeLimitOrder. New target: sequencer REST/WS submit endpoint. Auth changes (EOA signing via EIP-712 remains, but endpoint and nonce scheme differ).

### 4. 131 existing tests — which survive
- Vault: all keep (caller guard from `ORDERBOOK_ROLE` to `SETTLEMENT_ROLE`)
- MarginEngine: all keep
- PositionManager: caller guard rebind; tests mostly keep
- LiquidationEngine: all keep
- OracleAdapter: all keep
- OrderBook: **all delete** when OrderBook.sol deletes
- Integration tests that instantiate OrderBook: rewrite against Settlement harness

Estimate: ~80-100 of 131 survive; ~30-50 delete.

---

## Rewritten Phase 0 scope

Given audit, Phase 0 should produce (before Phase 1 starts):

### Phase 0a — Pivot ADR (this is the commit gate)
- [ ] `docs/adr/0012-zkvm-matcher-pivot.md` — with explicit rebuttal of ADR-0001's anti-off-chain argument

### Phase 0b — Supersede banners
- [ ] ADR-0001 header banner
- [ ] ADR-0003 header banner
- [ ] Phase 1 plan banner (partial obsolete)
- [ ] Phase 2 plan banner (Task 4 rebind note)
- [ ] Phase 3 plan banner (superseded)
- [ ] Phase 3 handoff banner (historical)
- [ ] Phase 3 codex review banner (partial historical)
- [ ] Blog 02 retraction banner

### Phase 0c — ADR index update
- [ ] `docs/adr/README.md` — reflect new statuses, stub future 0012-0015

Phase 0 total: **~11 doc edits**, all header-level or banner-level except ADR-0012 which is a new full ADR.

---

## Decision for the user

**Approve revised Phase 0?** Three sub-phases, all reversible, all documentation-only, no code touched.

Order:
1. Write ADR-0012 (pivot rationale + ADR-0001 rebuttal). **This is the commit point.**
2. If ADR-0012 approved → apply all supersede/retraction banners (0b).
3. Update ADR README index (0c).

Then Phase 1 (architecture rewrite + ADR-0013/0014/0015).

No action without user "go" per phase.
