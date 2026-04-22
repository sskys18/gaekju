# Spec / Plans / Blog Alignment Audit vs Path B zkVM Pivot

**Date:** 2026-04-22
**Pivot reference:** `docs/plans/2026-04-22-path-b-zkvm-pivot.md`
**Verdict legend:** KEEP = survives as-is · MINOR-UPDATE = small tweaks · FULL-REWRITE = content replaced · DELETE = remove · contradicts-pivot = assumes on-chain CLOB core.

---

## 1. `docs/specs/2026-04-06-gaekju-design.md` (2240 lines) — contradicts-pivot

The spec is the single most affected artifact. It hard-codes on-chain EVM CLOB + bitmap as the core thesis.

Section-by-section:

- **§1 Overview (L25–52)** — MINOR-UPDATE. "What Gaekju Is / Is Not" bullets still claim "fully on-chain CLOB, bitmap-based." Rewrite to "off-chain Rust matcher with on-chain SP1-proven settlement."
- **§2.1 System Overview (L56–77)** — FULL-REWRITE. Diagram shows `User → OrderBook.sol`. Replace with three-layer diagram (sequencer → prover → Settlement).
- **§2.2 Order Lifecycle (L78–102)** — FULL-REWRITE. Currently describes `placeOrder → match in EVM`. New flow: EIP-712 intent → sequencer ack → batch close → proof → Settlement.applyBatch.
- **§2.3 Liquidation Flow (L103–120)** — MINOR-UPDATE. Keeper → LiquidationEngine path survives; only the "called by OrderBook" cross-references change.
- **§3.1 Libraries (L123–173)** — `BitmapLib`, `PackedOrder`, `TickMath` → DELETE from spec (move to Rust sequencer state machine). `FixedPointMath` → KEEP.
- **§3.2 Vault (L174–211)** — MINOR-UPDATE. Add `applyBatchDelta` entry guarded to Settlement; USDC/18-dec conversion unchanged.
- **§3.3 OracleAdapter (L212–248)** — KEEP. Used by both sequencer (mark input) and settlement.
- **§3.4 OrderBook (L249–360)** — FULL-REWRITE → rename to `Settlement` section. Storage Layout / Place Order Flow / Matching Algorithm / Fee Model / Events all obsolete. Replace with batch schema, state delta encoding, SP1 verifier interface, replay nonce, force-include queue.
- **§3.5 MarginEngine (L361–404)** — KEEP. Called from Settlement instead of OrderBook; wording tweak only.
- **§3.6 PositionManager (L405–495)** — MINOR-UPDATE. New `applyBatchFills(Fill[])` entry; remove `ORDERBOOK_ROLE`-only comments, replace with `SETTLEMENT_ROLE`.
- **§3.7 LiquidationEngine (L496–535)** — KEEP (unchanged by pivot).
- **§3.8 FundingRate (L536–567)** — KEEP (unchanged; design intact).
- **§3.9 MarketFactory (L568–595)** — MINOR-UPDATE. Deploys `Settlement` per market, not `OrderBook`.
- **§3.10 Router (L596–626)** — FULL-REWRITE. Becomes thin deposit/withdraw + `forceInclude(intent)` escape hatch.
- **§3.11 Upgradability (L627–638)** — KEEP.
- **§4 Rust Backend (L639–912)** — FULL-REWRITE of §4.1 workspace to add `gaekju-sequencer`, `gaekju-prover` crates. §4.3 indexer needs MINOR-UPDATE (reads sequencer WS + on-chain). §4.4 API server MINOR-UPDATE. §4.5 keeper KEEP.
- **§5 Docs & Project Structure (L913–1103)** — MINOR-UPDATE. Add ADR entries, add sequencer/prover crate paths.
- **§6 Build Phases (L1104–1366)** — FULL-REWRITE of Phase 1, 3, 4 milestones. Phase 2a/2b KEEP. Phase 5 timeline extends (3–6 mo per pivot plan).
- **§7 ADR Summary (L1367–1382)** — MINOR-UPDATE. Mark ADR-0001, ADR-0003 superseded; append 0012–0015.
- **§8 Formulas & Math (L1383–1475)** — KEEP. All margin/PnL/funding/liquidation math unchanged. Mark-price formula stays (70% oracle + 30% mid; mid now sourced from sequencer state, not on-chain bitmap).
- **§9 Market Configs (L1476–1540)** — KEEP.
- **§10 Security Considerations (L1541–1583)** — MINOR-UPDATE to FULL-REWRITE. §10.1 Smart Contract Risks trims OrderBook reentrancy; add proof-invalid / sequencer-halt / batch-revert subsections. §10.5 Orderbook Integrity → rewrite as "Sequencer Integrity + Proof Validity."
- **§11 Lighter Mirror (L1584–2224)** — MINOR-UPDATE. Mirror still bootstraps liquidity (per pivot "keep Lighter mirror ADR-0010"). §11.6 sync loop targets the sequencer's local book now, not an on-chain contract. Phase integration table updates.
- **Appendix Glossary (L2225+)** — MINOR-UPDATE. Add sequencer/prover/batch terms.

---

## 2. Phase 1 plan `2026-04-06-phase1-foundation-core-orderbook.md` (3850 lines) — partial contradicts-pivot

Phase 1 is **already executed** (tests green). Status:

- **Tasks 1 (FixedPointMath), 5 (Mocks), 6 (Interfaces partial), 7 (Vault), 8 (OracleAdapter), 9 (MarginEngine), 12 (Rust Types partial), 13 (Deploy), 14 (wrap-up)** → stay valid. Code survives pivot.
- **Task 2 BitmapLib, Task 3 PackedOrder, Task 4 TickMath** → obsolete. Contracts + tests get deleted in Phase 5 execution. Plan should carry a "Superseded" banner but remains historical.
- **Task 10 OrderBook Contract, Task 11 Deposit→Place→Match→Fill integration** → obsolete. Replaced by Settlement + batch-application integration tests.
- Action: add `## Status: Partially superseded by 2026-04-22-path-b-zkvm-pivot.md` header; no content rewrite.

---

## 3. Phase 2 plan `2026-04-06-phase2-positions-liquidation.md` (3256 lines) — mostly KEEP

Phase 2 is executed (131 tests passing).

- **Tasks 0–3 (IPositionManager, PositionManager impl + fuzz), 5 (Position Lifecycle), 6–9 (Liquidation Engine + tests), 10–11 (Rust events + liquidation keeper), 12 (blog drafts)** → stay valid.
- **Task 4 "OrderBook Integration — Connect Fills to PositionManager" (L916–1161)** → contradicts-pivot. Will be replaced by Settlement→PositionManager wiring. Tests rebind from OrderBook caller to Settlement caller.
- Add superseded banner scoped to Task 4 and any test fixtures that mock `IOrderBook`.

---

## 4. Phase 3 plan `2026-04-06-phase3-funding-factory-router.md` (2527 lines) — contradicts-pivot (gutted)

Phase 3 **not yet executed**. Fate per pivot Task 3.x:

- **Task 1–3 FundingRate** → KEEP (unchanged design, only caller guard moves).
- **Task 2 PositionManager wiring** → MINOR-UPDATE (role rename `ORDERBOOK_ROLE` → `SETTLEMENT_ROLE`).
- **Task 4 Vault.depositFor** → KEEP.
- **Task 5 OrderBook IOC/FOK** → DELETE. Handled inside sequencer.
- **Task 6 MarketFactory** → FULL-REWRITE (deploys Settlement, not OrderBook).
- **Task 7 Router** → FULL-REWRITE (deposit/withdraw + forceInclude only).
- **Task 8 tests** → FULL-REWRITE.
- **Task 9 Funding keeper** → KEEP.
- **Task 10 verification** → adapt targets.
- Action: add `## Status: Superseded by 2026-04-22-contracts-v2.md` header (plan to be written in pivot Phase 3).

---

## 5. `2026-04-07-phase3-handoff.md` (161 lines) — stale; mark superseded

Entire handoff assumes the old Phase 3 will execute. Pivot plan explicitly flags it for "mark stale." Add `## Status: Superseded` header, no content rewrite. The "Critical Issues to Fix" section (compile blocker, role grants) still has useful audit signal for whichever contracts survive — preserve as reference.

---

## 6. `2026-04-06-phase3-codex-review.md` (214 lines) — partial KEEP

- Sections on C1, C2, m1 bug fixes → KEEP (bugs already fixed, commit `062607d`).
- Sections reviewing FundingRate, PositionManager → KEEP (design feedback still valid).
- Sections on MarketFactory, Router (L110–158) → obsolete for new plan but useful as "lessons inherited" when drafting contracts-v2. Do not delete; mark "historical context — see new plan."

---

## 7. Blog posts

| File | Verdict | Notes |
|------|---------|-------|
| `00-why-gaekju.md` | FULL-REWRITE | L19 "fully on-chain central limit orderbook (CLOB) with bitmap-based price level encoding" is the thesis sentence. Replace with zkVM-proven matching pitch. |
| `01-choosing-architecture.md` | FULL-REWRITE | Entire post argues for Model 4 (on-chain CLOB) and against Model 2/3. Post-pivot we are Model 3 + ZK proof. Rewrite decision matrix or retract with note pointing to new post. |
| `02-bitmap-orderbook.md` | RETRACT + retain | Pivot plan explicitly says "keep but add retraction note." Technical content still instructive; add banner pointing to Rust sequencer deep-dive once written. |
| `03-margin-from-scratch.md` | MINOR-UPDATE | Margin math unchanged. Update only the "OrderBook calls PositionManager.updatePosition" plumbing paragraph (L71–77) to say "Settlement applies proven batch deltas." |
| `04-liquidation-math.md` | KEEP | Liquidation logic survives pivot verbatim. |
| `05-funding-rates.md` | stub — write post-pivot | Placeholder only. |
| `06-rust-indexer.md` | stub — expand post-pivot | Indexer scope widens (sequencer WS + on-chain). |
| `07-lighter-mirror.md` | stub — write post-pivot | Mirror retained per ADR-0010. |
| `08-testing-defi.md` | stub | Write with Settlement + SP1 program test strategy. |
| `09-deploying-op-stack.md` | stub | KEEP, extend with sequencer/prover ops. |
| `10-lessons-learned.md` | stub | Will naturally absorb the pivot story. |

---

## 8. `docs/reference/formulas.md` — KEEP

Every formula (margin, PnL, mark price, funding, liquidation, fees) survives the pivot unchanged. Mark-price formula still 70% oracle + 30% mid; `bestBid`/`bestAsk` now sourced from sequencer snapshot rather than on-chain bitmap — transparent to readers. No edits required unless a clarifying note about source is desired.

---

## 9. `docs/reference/glossary.md` — MINOR-UPDATE

Add entries: **Sequencer**, **Prover**, **Batch**, **State Delta**, **SP1 / zkVM**, **Soft Confirm**, **Force Include**. The existing **Bitmap** entry (L30) should be marked "legacy / historical — not used in current architecture." **CLOB** entry stays (sequencer is still a CLOB).

---

## 10. `docs/reference/market-configs.md` — KEEP

Market definitions, fee schedule, tick/lot sizes are orthogonal to matching layer. Only L81 step "Calling `MarketFactory.createMarket()`" unchanged in text but now targets Settlement deployment downstream — no user-visible doc change required.

---

## 11. `CLAUDE.md` — MINOR-UPDATE

- Architecture block (L20–26) names only contracts. Add `crates/gaekju-sequencer/` and `crates/gaekju-prover/`.
- "Do Not" block (L39–43): the claim "mirror Lighter.xyz instead" stays; add "Do not reintroduce on-chain matching — matching lives in the Rust sequencer."
- Mention the pivot plan path so future sessions load it.

---

## Summary of effort

- 1 spec (major surgery): §2, §3.4, §3.10, §6, §10 rewrites; §3.1/3.9/4/11 tweaks; §8/9 keep.
- 3 executed plans: add superseded banners only.
- 1 unexecuted plan (Phase 3): fully superseded; contracts-v2 plan replaces.
- 3 blog posts rewrite (00, 01, 02); 1 minor (03); 1 keep (04); 6 stubs write fresh.
- 3 reference docs: 1 keep, 1 minor, 1 keep.
- 1 CLAUDE.md minor.

Files that are pure contradicts-pivot (on-chain EVM matching baked into thesis): design spec §2–§3.4/§3.10/§6, Phase 1 Tasks 2/3/4/10/11, Phase 2 Task 4, all of Phase 3 plan's matching/router scope, blog 00/01/02.
