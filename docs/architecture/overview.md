# Architecture Overview

Gaekju is a perpetual futures DEX with an off-chain Rust matching engine, SP1 zkVM proof of matching correctness, and on-chain settlement on Giwa Chain (OP Stack L2). See [ADR-0012](../adr/0012-zkvm-matcher-pivot.md).

## System Diagram

```
                                                       Giwa Chain (OP Stack L2)
                                                       ┌──────────────────────────┐
  Traders ──signed EIP-712 intent──▶  ┌───────────┐    │  Router                  │
  (WS / REST)                          │ Sequencer │    │   ├─ deposit / withdraw │
                                       │  (Rust)   │    │   └─ forceInclude      │
                                       │           │    │                          │
                                       │ matches,  │    │  Settlement (per mkt)    │
                                       │ emits     │    │   ├─ SP1 verifier        │
                                       │ batches   │    │   ├─ batch decode        │
                                       └─────┬─────┘    │   └─ state delta apply   │
                                             │          │          │                │
                                             ▼          │          ▼                │
                                       ┌───────────┐    │  Vault (USDC)             │
                                       │  Prover   │    │  PositionManager          │
                                       │   (SP1)   │    │  MarginEngine             │
                                       │           │    │  FundingRate              │
                                       │ proves    │    │  LiquidationEngine        │
                                       │ batch     │    │  OracleAdapter (Pyth)     │
                                       │ Rust exec │    └──────────────────────────┘
                                       └─────┬─────┘                ▲
                                             │ proof + batch         │
                                             └───────────────────────┘

  Lighter.xyz ──WS depth──▶ gaekju-mirror ──sequencer submit──▶ (mirrored depth)
```

## Three Layers

### Sequencer (off-chain, Rust)
The matching engine. Accepts signed EIP-712 intents over WS/REST, maintains the orderbook state, runs deterministic price-time priority matching, and emits batches of (prev state root, intents, fills, post state root). Sub-50ms soft-ack. Single operator in v1; force-inclusion hatch bounds censorship. See [rust-backend.md](rust-backend.md).

### Prover (off-chain, Rust)
SP1 zkVM re-executes the same Rust matching program over each batch and produces a succinct proof. Proof plus batch is submitted to Settlement on Giwa. Prover cost and latency dominate end-to-end finality (~30s-2min per batch).

### Settlement (on-chain, Solidity)
`Settlement.sol` (per market) verifies the SP1 proof, checks batch nonce monotonicity, decodes the state delta, and applies it to the surviving contracts — Vault, PositionManager, MarginEngine, FundingRate, LiquidationEngine, OracleAdapter. Settlement is the sole privileged caller (`SETTLEMENT_ROLE`) of those contracts in place of the deleted OrderBook. See [contracts.md](contracts.md).

## Key Design Principles

1. **ZK-proven off-chain match** — the Rust matching program is the authority; the proof says "this exact code ran deterministically over this exact ordered input." Operator cannot forge fills, prices, or cancels.
2. **Modular** — each concern in its own upgradeable contract; Settlement is a thin proof-verifier + dispatcher.
3. **Mirror, don't simulate** — real liquidity from Lighter, written to the sequencer endpoint.
4. **Rust everywhere** — one language for sequencer, prover, indexer, API, keeper, mirror, SDK, CLI. Sequencer binary and SP1 guest share the matching-state-machine code.
5. **Document everything** — ADRs, blog posts, specs for every decision.

## Further Reading

- [Smart Contract Architecture](contracts.md)
- [Rust Backend Architecture](rust-backend.md)
- [Order Lifecycle & Data Flow](data-flow.md)
- [ADR-0012 — zkVM Matcher Pivot](../adr/0012-zkvm-matcher-pivot.md)
- [Full Design Spec](../specs/2026-04-06-gaekju-design.md)
- [Architecture Decision Records](../adr/README.md)
