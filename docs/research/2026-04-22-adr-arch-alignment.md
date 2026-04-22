# ADR + Architecture Alignment Audit vs Path B zkVM Pivot

Date: 2026-04-22
Baseline: `docs/plans/2026-04-22-path-b-zkvm-pivot.md`
Scope: 11 ADRs, `docs/adr/README.md`, 4 architecture docs.

## Alignment Matrix

| File | Verdict | Contradicts | Compatible / Neutral | Action |
|------|---------|-------------|----------------------|--------|
| ADR-0001 use-lighter-clob | **SUPERSEDE** | Title; §Context "fully on-chain CLOB"; Decision L16–19 ("Lighter.xyz architecture... matching in Solidity", "orderbook state stored entirely on-chain using bitmap"); Positive L23–27 (trust/composability arguments rely on on-chain matching); Alt "Hyperliquid Off-chain" L47–49 rejected for exactly what we now do | Alt "vAMM" and "Diamond" rejections still stand | Add `## Status: Superseded by ADR-0012`; keep body for history (plan §0.2). Depends on: ADR-0012. |
| ADR-0002 modular-contracts | **MINOR EDIT** | L10 lists "order matching" as a concern; L17 lists `OrderBook (one per market)`; "Only the OrderBook can call PositionManager.updatePosition()" (L19) | Separation-of-concerns thesis + UUPS + AccessControl still hold; `Settlement` is a drop-in replacement in the contract list | Replace `OrderBook` → `Settlement` in contract enumeration (L17) and authorization example (L19). Update L10 to say "proof-verified settlement". No status change. Depends on: ADR-0012, contracts-v2 plan. |
| ADR-0003 bitmap-orderbook | **SUPERSEDE** | Entire document. Bitmap storage, two-level encoding, O(1) best-bid lookup — all moot because orderbook state moves off-chain into the Rust sequencer | None | Add `## Status: Superseded by ADR-0012`; keep body (plan §0.3). Depends on: ADR-0012. |
| ADR-0004 pyth-oracle | **NO CHANGE / MICRO EDIT** | None material | Pyth remains oracle for both sequencer mark/index and Settlement margin checks | Optional one-line addition in §Decision noting oracle is consumed by sequencer AND Settlement. Depends on: none. |
| ADR-0005 usdc-collateral | **NO CHANGE** | None | Vault decimal convention survives untouched | None. |
| ADR-0006 isolated-margin | **NO CHANGE** | None | Margin semantics live in MarginEngine/PositionManager, unchanged | None. |
| ADR-0007 rust-backend | **MINOR EDIT** | L10 workspace list omits `sequencer` + `prover`; L17 enumerates 7 crates; L24 "keeper... sub-100ms overhead" framing assumes chain matching | Rust-for-infra thesis, tokio/alloy/axum/sqlx stack — all reinforced (sequencer needs exactly these) | Add `gaekju-sequencer` and `gaekju-prover` to workspace list (L10, L17). Update L12 "never makes matching... decisions" — now sequencer DOES match, but under proof constraint. Consider short note that matching correctness is enforced by zkVM, not trust. Depends on: ADR-0012, rust-sequencer plan. |
| ADR-0008 alloy-over-ethers | **NO CHANGE** | None | Alloy is even more central (sequencer + prover both use it) | None. |
| ADR-0009 uups-proxy | **MICRO EDIT** | L40 "per-call gas overhead ... on a CLOB where every order placement, cancellation, and match is an external call" — argument weakens because orders no longer hit chain | Decision itself (UUPS + Timelock + multisig) stands; Settlement/Vault/Margin/etc still upgradeable | Soften L40 rationale ("matching lives off-chain; settlement batches still benefit from UUPS overhead savings"). No status change. |
| ADR-0010 lighter-mirror | **MINOR EDIT** | L17 "submits on-chain transactions to add/cancel/update orders" — mirrored orders now submit to sequencer, not OrderBook; L32 "consumes block space" argument is stale | Core decision (use Lighter as liquidity source) preserved per pivot plan L54 | Rewrite §Decision L17 to "submits signed intents to the sequencer WS/REST"; drop L32 "block space" con, replace with "sequencer bandwidth" con. Depends on: rust-sequencer plan. |
| ADR-0011 one-hour-funding | **NO CHANGE** | None | FundingRate contract still on-chain, caller guard just moves from PM to Settlement (pivot §3.7) | None. |
| adr/README.md | **MINOR EDIT** | Index rows for 0001/0003 show "Accepted" | — | Flip 0001 and 0003 to "Superseded by 0012"; append rows for 0012/0013/0014/0015 when written (plan §0.4). |
| architecture/overview.md | **REWRITE** (small file) | Diagram L14–22 lists `OrderBook (per mkt)` under on-chain; L35 "matching... happen on Giwa L2"; L42 "On-chain first"; L44 "Mirror, don't simulate" OK | Principles 2 (modular), 4 (Rust everywhere), 5 (document) intact | Rewrite §System Diagram to show 3 layers (sequencer / prover / settlement). Replace §Two Layers with three-layer description. Update principle 1 — contracts remain source of truth for settled state; sequencer is source for pending. Depends on: ADR-0012, contracts-v2 plan. |
| architecture/contracts.md | **REWRITE** (small file) | L7 `OrderBook (one per market) — Bitmap CLOB, matching engine`; L16–20 library list (BitmapLib, PackedOrder, TickMath); L23–38 all interaction arrows routed through OrderBook; L53 invariant `bestBid < bestAsk` | PositionManager/MarginEngine/LiquidationEngine/FundingRate/OracleAdapter/Vault rows stand; UUPS section stands; FixedPointMath library stays; insurance-fund invariant stands | Replace OrderBook row with `Settlement (one per market) — SP1 proof verifier + state delta applier`. Delete BitmapLib/PackedOrder/TickMath library rows. Rewrite Interactions block: sequencer → prover → Settlement → {PM, Vault, Margin, Funding}. Drop `bestBid < bestAsk` invariant (replace with batch nonce monotonicity + proof-valid invariant). Depends on: contracts-v2 plan. |
| architecture/data-flow.md | **REWRITE** | Entire §Order Lifecycle L5–23 (Router→OrderBook path); §Lighter Mirror L42–52 (mirror submits to OrderBook) | §Liquidation Flow L26–39 mostly intact (LiquidationEngine still callable); §Funding Flow L54–67 intact | Rewrite order lifecycle: signed intent → sequencer match (WS ack ms) → batch close → SP1 proof → Settlement.settleBatch → Vault/PM updates → indexer. Rewrite mirror flow to target sequencer. Keep liquidation + funding flows (update caller to Settlement where needed). Depends on: ADR-0012, rust-sequencer/prover plans. |
| architecture/rust-backend.md | **MINOR EDIT** | L6–13 workspace list lacks sequencer/prover; L45–52 data-flow diagram implies indexer sees chain events only | Workspace tooling (alloy/tokio/sqlx/axum/…) unchanged | Add `gaekju-sequencer` and `gaekju-prover` rows with one-line purpose. Extend §Data Flow: sequencer WS → indexer (pending), chain → indexer (settled). Depends on: rust-sequencer / rust-prover plans. |

## Rollup

- **Full supersede** (2): ADR-0001, ADR-0003. Header-only change per pivot plan §0.2–0.3.
- **Minor edit** (5): ADR-0002, ADR-0007, ADR-0009, ADR-0010, adr/README.md.
- **Micro / no-op** (4): ADR-0004, ADR-0005, ADR-0006, ADR-0008, ADR-0011.
- **Architecture rewrites** (3 files, all small): overview.md (diagram + two-layers), contracts.md (contract map + interactions + invariants), data-flow.md (order lifecycle + mirror flow). rust-backend.md is a minor edit (add two crates).

## Cross-file dependency graph (who must land first)

1. ADR-0012 (pivot ADR) — gates everything; referenced by ADR-0001, ADR-0003 supersede headers and all three architecture rewrites.
2. ADR-0013 (SP1 framework) — referenced by architecture/overview + contracts rewrites and by design-spec §Proof System.
3. ADR-0014 (sequencer trust) — referenced by rust-backend.md edits (explaining why sequencer is acceptable) and data-flow rewrite (force-inclusion path).
4. ADR-0015 (batch cadence) — referenced by data-flow rewrite (soft-confirm UX timings).
5. contracts-v2 plan — feeds architecture/contracts.md rewrite.
6. rust-sequencer + rust-prover plans — feed rust-backend.md edits and data-flow rewrite.

## Risk flags found during audit

- ADR-0001's "Hyperliquid Off-chain" rejection paragraph (L47–49) argues the pivoted architecture "defeats the purpose." Pivot rationale (proof-verified matching) must explicitly rebut this in ADR-0012 or readers hitting the superseded doc will see an unanswered objection.
- architecture/contracts.md invariant `bestBid < bestAsk always` becomes unverifiable on-chain; Settlement needs a new invariant vocabulary (batch nonce monotonic, prev-state-root commitment match).
- ADR-0010 still justifies mirror behavior with "order formats... map naturally" to Lighter — true for sequencer intent format too, but needs restatement so readers do not infer on-chain order mapping.
