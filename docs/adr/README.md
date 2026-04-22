# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the Gaekju project. ADRs document significant architectural decisions, their context, and consequences.

## Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001](0001-use-lighter-clob.md) | Use Lighter-style On-Chain CLOB | Superseded by 0012 | 2026-04-06 |
| [0002](0002-modular-contracts.md) | Modular Contract Architecture | Accepted | 2026-04-06 |
| [0003](0003-bitmap-orderbook.md) | Bitmap-Based Orderbook | Superseded by 0012 | 2026-04-06 |
| [0004](0004-pyth-oracle.md) | Pyth Network as Oracle | Accepted | 2026-04-06 |
| [0005](0005-usdc-collateral.md) | USDC-Only Collateral | Accepted | 2026-04-06 |
| [0006](0006-isolated-margin.md) | Isolated Margin in v1 | Accepted | 2026-04-06 |
| [0007](0007-rust-backend.md) | Rust for Backend Infrastructure | Accepted | 2026-04-06 |
| [0008](0008-alloy-over-ethers.md) | Alloy over ethers-rs | Accepted | 2026-04-06 |
| [0009](0009-uups-proxy.md) | UUPS Proxy Pattern | Accepted | 2026-04-06 |
| [0010](0010-lighter-mirror.md) | Lighter.xyz as Liquidity Mirror | Accepted | 2026-04-06 |
| [0011](0011-one-hour-funding.md) | 1-Hour Funding Intervals | Accepted | 2026-04-06 |
| [0012](0012-zkvm-matcher-pivot.md) | Pivot to zkVM-Proven Off-Chain Matcher | Accepted | 2026-04-22 |
| [0013](0013-sp1-zkvm-framework.md) | SP1 as the zkVM Framework | Accepted | 2026-04-22 |
| [0014](0014-sequencer-trust-model.md) | Sequencer Trust Model and Force-Inclusion | Accepted | 2026-04-22 |
| [0015](0015-proof-batching-cadence.md) | Proof Batching and Settlement Cadence | Accepted | 2026-04-22 |

## Template

```markdown
# ADR-NNNN: [Title]

## Status
Proposed | Accepted | Deprecated | Superseded by ADR-XXXX

## Date
YYYY-MM-DD

## Context
What is the problem or decision we're facing?

## Decision
What did we decide and why?

## Consequences
### Positive
- What becomes easier?

### Negative
- What becomes harder?

### Neutral
- What stays the same but is worth noting?

## Alternatives Considered
### [Alternative A]
- Pros: ...
- Cons: ...
- Why rejected: ...
```
