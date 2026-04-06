# Building a Perp DEX from Scratch

A blog series documenting the design and implementation of Gaekju — a perpetual futures DEX on Giwa Chain (OP Stack L2), following the Lighter.xyz on-chain CLOB architecture.

## Series

| # | Title | Phase | Status |
|---|-------|-------|--------|
| 00 | [Why We're Building Gaekju](00-why-gaekju.md) | Pre | Draft |
| 01 | [Choosing a Perp DEX Architecture](01-choosing-architecture.md) | Pre | Draft |
| 02 | [Building a Bitmap Orderbook](02-bitmap-orderbook.md) | 1 | Planned |
| 03 | [Margin Systems from Scratch](03-margin-from-scratch.md) | 2a | Planned |
| 04 | [Liquidation: Protecting the Protocol](04-liquidation-math.md) | 2b | Planned |
| 05 | [How Perp Funding Rates Actually Work](05-funding-rates.md) | 3 | Planned |
| 06 | [Building an L2 Indexer in Rust](06-rust-indexer.md) | 4 | Planned |
| 07 | [Mirroring Lighter.xyz Liquidity](07-lighter-mirror.md) | 5 | Planned |
| 08 | [Fuzz Testing a DeFi Protocol](08-testing-defi.md) | 5 | Planned |
| 09 | [Deploying to an OP Stack Testnet](09-deploying-op-stack.md) | 5 | Planned |
| 10 | [Lessons from Building a Perp DEX](10-lessons-learned.md) | 5 | Planned |

## Publishing

1. Write draft in this directory
2. Peer review
3. Publish to Mirror.xyz (primary — web3 native, onchain attestation)
4. Cross-post to dev.to and hashnode (developer audience)
5. Twitter/X thread with key takeaways
6. Link from README and CHANGELOG

## Writing Guidelines

- Each post maps to a build phase — write after completing the phase
- Target audience: developers interested in DeFi/DEX engineering
- Include code snippets, diagrams, and gas benchmarks where relevant
- Explain the *why* behind decisions, not just the *what*
- Link to the relevant ADR for architectural decisions
- Keep posts focused: 1500-3000 words each
