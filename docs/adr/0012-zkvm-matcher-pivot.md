# ADR-0012: Pivot to zkVM-Proven Off-Chain Matcher

## Status
Accepted — **supersedes ADR-0001 and ADR-0003**

## Date
2026-04-22

## Context

After initial Phase 1 + Phase 2 implementation of the fully-on-chain EVM CLOB specified in ADR-0001, we performed a full research pass on the 2026 perpetual DEX landscape and the specific fitness of Giwa Chain for on-chain matching. Source documents:

- `docs/research/2026-04-22-lighter-on-giwa-pros-cons.md`
- `docs/research/2026-perp-dex-landscape.md`
- `docs/research/giwa-chain-investigation.md`
- `docs/research/lighter-stack-investigation.md`
- `docs/research/2026-04-22-pivot-alignment-summary.md`

Three load-bearing findings changed the decision:

**Finding 1 — The "Lighter-style on EVM" framing is a category error.**
Lighter.xyz does not run its matching loop on the EVM. Lighter is an application-specific zk-rollup with a centralized off-chain Rust sequencer; matching is proven by Plonky2 STARK → gnark PLONK SNARK and settled on Ethereum L1 at ~$0.007 amortized per user op. Our construction is closer to Clober/LOBSTER (EVM bitmap CLOB on Base, spot-only) than to Lighter. No perp DEX runs matching inside EVM at production scale.

**Finding 2 — Giwa Chain has ecosystem gaps that compromise ADR-0001's premises.**
ADR-0001 assumed (a) cheap EVM gas making on-chain matching "economically viable," (b) available oracle infrastructure, (c) native USDC, (d) third-party RPC providers. As of 2026-04-22: Pyth deployment on Giwa is unconfirmed, USDC is bridged-only with Dunamu custody trust, no third-party RPC (Alchemy/QuickNode/Infura) exists, Giwa mainnet missed its Q4 2025 target, and the sequencer is operated by Dunamu (also the Upbit parent, creating order-flow visibility concerns for any on-chain perp book).

**Finding 3 — 2026 perp DEX market has consolidated around non-EVM-matching models.**
Volume leaders (Hyperliquid ~60-75% share, Lighter, Paradex, edgeX, ApeX Omni, Vertex, Aevo, Drift) all use either (a) their own BFT L1, (b) zk-rollup with off-chain match, or (c) off-chain match with optimistic on-chain settle. None run matching in EVM. The bucket we occupied in ADR-0001 is empty at scale for a reason — EVM gas and block time are fundamental constraints for orderbook matching.

### What we also rechecked
ADR-0001 explicitly rejected off-chain matching, stating: *"An off-chain matching engine on a testnet L2 defeats the purpose. The goal is trustless execution. If we wanted centralized matching, we would build a CEX."* This rejection is addressed directly in the Rebuttal section below.

## Decision

We pivot to a **zkVM-proven off-chain matcher** architecture. Concretely:

1. **Matching moves off-chain** into a Rust sequencer service (`crates/gaekju-sequencer`). The sequencer maintains the orderbook state, accepts signed user intents (EIP-712), matches deterministically, and emits fills.
2. **Correctness is proven by SP1 zkVM** (`crates/gaekju-prover`). The sequencer's matching logic is written once in Rust; the SP1 zkVM re-executes the same Rust over a batch of intents and produces a succinct proof of correct execution. SP1 is chosen over RISC Zero / Jolt based on 2026 ecosystem maturity (Optimism fault-proof adoption, Succinct-operated proving infra, production EVM verifier at ~300k gas). See ADR-0013.
3. **Settlement stays on Giwa Chain** via a new `Settlement.sol` contract. Settlement verifies the SP1 proof, decodes the state delta (fills, position updates, margin changes), and applies it to the existing Vault / PositionManager / MarginEngine / FundingRate / LiquidationEngine contracts. Settlement becomes the sole caller of those contracts in place of the old OrderBook.sol.
4. **All Phase 1 + Phase 2 contracts survive** — Vault, MarginEngine, PositionManager, LiquidationEngine, OracleAdapter, FundingRate. Only their caller guard changes (from `ORDERBOOK_ROLE` to `SETTLEMENT_ROLE`).
5. **OrderBook.sol, BitmapLib, TickMath, PackedOrder and their tests are deleted.** The bitmap orderbook is no longer part of the architecture.
6. **Force-inclusion escape hatch** is mandatory. Users can submit an intent directly on-chain via `Router.forceInclude(intent)`; Settlement must process force-included intents within N batches or the sequencer is in default. See ADR-0014.

### New system diagram

```
                      Ethereum L1 (canonical bridge)
                                │
                    ┌───────────┴───────────┐
                    │    Giwa Chain L2        │
                    │                         │
  Users ─signed─▶  │  Router (deposit/         │
  EIP-712 intent   │   withdraw / forceInclude)│
         │         │                         │
         │         │  Settlement.sol          │
         ▼         │    ├─ SP1 verifier        │
  Rust sequencer ──┼─▶   ├─ applies state delta │
  (matches,        │    │  to contracts below   │
   emits batches)  │    │                       │
         │         │    ├─▶ Vault               │
         ▼         │    ├─▶ PositionManager     │
  SP1 prover       │    ├─▶ MarginEngine        │
  (proves batch    │    ├─▶ FundingRate         │
   Rust execution) │    └─▶ LiquidationEngine   │
         │         │                         │
         └────────▶│  (proof + batch)          │
                    └─────────────────────────┘
```

## Rebuttal of ADR-0001's anti-off-chain argument

ADR-0001 rejected off-chain matching as "centralized matching ≈ CEX, defeats the DEX premise." The rebuttal:

1. **ZK proof separates logic trust from operator trust.** In an unproven off-chain matcher (Hyperliquid, Vertex, Aevo pre-ZK), the operator's word is the matching rule. In a zkVM-proven matcher, the matching rule is Rust code; the proof says "I ran this exact code deterministically over this exact ordered input set." Operator cannot insert a fake fill, cancel without authorization, modify prices, or selectively match. The trust surface for *matching logic* is the same as an on-chain contract — the code is the authority.

2. **Only ordering fairness remains as a trust axis.** Under ZK-proven matching, the sequencer can still reorder the input stream (to frontrun or backrun). This is mitigated by: (a) private mempool on Giwa reduces sandwich opportunities, (b) force-inclusion hatch bounds censorship latency, (c) sequencer commits a *post-batch* state root that makes reordering observable after the fact, (d) future: rotating sequencer set.

3. **This is strictly better than the rejected "CEX" framing.** A CEX can execute any logic it wants, hide state, and censor users. A ZK-proven off-chain matcher can execute only the proven program, publishes all state transitions, and has bounded censorship via force-inclusion. The distance from "CEX" is exactly the distance that ZK provides.

4. **ADR-0001's premise ("gas is cheap on OP Stack, on-chain matching is economically viable") was wrong for Giwa specifically.** Giwa ecosystem gaps (no confirmed Pyth, no native USDC, Stage-0 trust, single operator) reduce the security premium gained by moving matching on-chain. Meanwhile, 1-second block time + ~200k gas per order + ~300 TPS theoretical ceiling makes on-chain matching economically unviable for market makers quoting sub-5bps spreads at any meaningful depth.

5. **Nobody at scale did what ADR-0001 proposed.** Lighter (which ADR-0001 named as the reference) does not do on-chain EVM matching. Clober — the closest honest precedent — is spot-only on Base. Extending an EVM CLOB to perps has no production precedent.

## Consequences

### Positive
- Matching latency drops from 1-second block time to sub-50ms sequencer soft-ack, competitive with Vertex/Aevo and one bucket behind Hyperliquid.
- Throughput decoupled from Giwa gas limits. Sequencer can handle 10k+ ord/sec; only batch settlement consumes Giwa gas.
- Gas cost per user action drops from ~200k-gas-per-order to amortized fraction of one batch-verification (~300k gas shared across N orders).
- Architecture aligns with a documented 2026 bucket (ZK off-chain match, Lighter/Paradex) rather than an empty category.
- Reduces dependence on Giwa-specific infra — proof verification portable to Ethereum L1 or any EVM if Giwa falters.
- Rust matching engine is reusable — same code runs in sequencer and inside SP1 circuit.
- Force-inclusion escape hatch strengthens censorship resistance vs an operator-trust-only system like Vertex.

### Negative
- **Added trust axis: sequencer ordering.** Fixed by ADR-0014 (force-inclusion + post-batch state root commit) but non-zero.
- **New infra: SP1 prover.** Prover service must run, costs per-batch (~$0.01-1 current, trending down). Failure modes: prover halt, prover-infra cost spike.
- **Soft-confirm UX.** User sees sequencer ack in ms, but on-chain finality waits for batch close (~5s) + proof gen (~30s-2min) + Giwa block. Requires UX design for pending states.
- **Larger total surface area.** Off-chain matcher, zkVM program, settlement contract, verifier contract, force-inclusion path. More to audit than a single on-chain CLOB.
- **Phase 1 + Phase 2 OrderBook implementation and tests are discarded.** Vault / PositionManager / MarginEngine / LiquidationEngine / OracleAdapter survive.
- **No production precedent on OP Stack** for zkVM-proven matching. We are second to Lighter (own rollup) and ahead of most peers.

### Neutral
- Pyth integration unchanged — used by both sequencer (mark price) and Settlement (liquidation validation).
- Isolated margin, 1h funding, USDC collateral decisions unchanged.
- Lighter mirror (ADR-0010) retargets: mirror writes to sequencer REST/WS instead of OrderBook.placeLimitOrder.
- Rust-first backend decision (ADR-0007) is reinforced, not changed — sequencer is Rust, prover is Rust.

## Alternatives Considered

### Stay on Path A (fully on-chain EVM CLOB)
- Pros: simpler system, already partially built, pure transparency.
- Cons: testnet-only viable, ~100 TPS realistic ceiling, MM uneconomic at tight spreads, no scale precedent.
- Why rejected: Giwa ecosystem gaps + 2026 market consolidation make this a dead-end architecture beyond testnet demo.

### Hyperliquid-shape (own L1 with BFT consensus)
- Pros: sub-100ms match, no proof latency, no prover cost, full transparency.
- Cons: requires building and operating a new L1. Out of team scope.
- Why rejected: 10x the engineering budget. Not considered.

### Vertex/Aevo-shape (optimistic off-chain match + on-chain settle, no ZK)
- Pros: simpler than ZK, proven in production, cheaper to run.
- Cons: pure operator trust, no correctness proof, fraud-proof window or nothing. Worse than Lighter on security.
- Why rejected: ZK proof is cheap enough in 2026 (SP1 amortizes well) that skipping it is leaving security on the table.

### Custom ZK circuits (Lighter-exact: Plonky2 STARK → gnark SNARK, Poseidon2 Merkle state tree)
- Pros: lowest on-chain gas, smallest proof, fastest prover per op.
- Cons: 12-18 month circuit engineering effort, requires cryptography specialists, audit cost $200k+, custom signature scheme (ECgFp5 Schnorr, incompatible with EVM wallets).
- Why rejected: team scale and timeline. zkVM (SP1) trades prover cost for an order-of-magnitude reduction in engineering surface.

### RISC Zero instead of SP1
- Pros: mature, production-grade, general-purpose.
- Cons: higher prover cost as of 2026, less EVM-native tooling.
- Why rejected: SP1 equivalent or cheaper for our workload, better EVM verifier integration. See ADR-0013 for full comparison.

## Implementation Path

See `docs/plans/2026-04-22-path-b-zkvm-pivot.md` for phased doc-and-code rollout. High level:

- **Phase 0–4 (docs):** Align all ADRs, architecture docs, design spec, plans, blogs, reference.
- **Phase 5 (code):** Build `Settlement.sol`, `crates/gaekju-sequencer`, `crates/gaekju-prover`; delete `OrderBook.sol` and bitmap libs; rebind caller guards on surviving contracts; update indexer/API/keeper; integration test; testnet deploy.

This ADR commits us to Phases 0–4. Phase 5 re-plans at the end of Phase 4 when all docs are aligned.

## References
- ADR-0001 (superseded) — original on-chain CLOB decision
- ADR-0003 (superseded) — bitmap orderbook
- ADR-0013 — SP1 zkVM framework choice (follow-up)
- ADR-0014 — sequencer trust model + force-inclusion (follow-up)
- ADR-0015 — proof batching and settlement cadence (follow-up)
- Research: `docs/research/2026-perp-dex-landscape.md`, `docs/research/lighter-stack-investigation.md`, `docs/research/giwa-chain-investigation.md`, `docs/research/2026-04-22-lighter-on-giwa-pros-cons.md`, `docs/research/2026-04-22-pivot-alignment-summary.md`
