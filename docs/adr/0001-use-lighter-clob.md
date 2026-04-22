# ADR-0001: Use Lighter-style On-Chain CLOB

## Status
Superseded by ADR-0012 (2026-04-22)

Historical context only. The Lighter-style on-chain EVM CLOB decision is reversed. See ADR-0012 for rationale.

## Date
2026-04-06

## Context
Gaekju is a perpetual futures DEX deployed on Giwa Chain, an OP Stack L2 testnet. The fundamental architectural decision is the trade execution model: how orders are matched and how prices are discovered.

Perpetual DEX designs fall into a few categories. AMM/vAMM designs (GMX, Perpetual Protocol v1) use liquidity pools and virtual pricing curves to provide synthetic exposure. Off-chain matching engines (Hyperliquid, dYdX v3) run a centralized orderbook and settle on-chain. Hybrid models (Vertex, dYdX v4) combine an off-chain sequencer with on-chain settlement. Fully on-chain CLOBs (Lighter.xyz) run the entire matching engine in smart contracts.

The choice is constrained by two factors. First, Giwa Chain is an OP Stack L2 where gas costs are orders of magnitude lower than L1 Ethereum, making on-chain matching economically viable. Second, Gaekju is designed as a trustless, transparent protocol where all matching logic is verifiable on-chain without relying on off-chain infrastructure or trust assumptions beyond the L2 sequencer itself.

## Decision
We adopt the Lighter.xyz architecture: a fully on-chain central limit orderbook (CLOB) with bitmap-based price level encoding. All order matching, position management, and risk calculations happen in smart contracts. The Rust backend serves as read infrastructure (indexing, API, keepers) and never makes matching or risk decisions.

This means every trade is a transaction on Giwa Chain. Price-time priority matching runs in Solidity. The orderbook state (bids, asks, price levels) is stored entirely on-chain using bitmap encoding for gas efficiency. Traders interact with the protocol through standard EVM transactions.

## Consequences
### Positive
- Full transparency: every order, match, and fill is an on-chain event that anyone can verify
- No trust assumptions beyond the L2 sequencer, which is the minimal trust surface for any L2 application
- Composability with other on-chain protocols (margin vaults, strategy contracts, etc.)
- Single source of truth for orderbook state eliminates synchronization bugs between off-chain and on-chain components
- Simpler overall architecture since there is no off-chain matching engine to build, deploy, and keep in sync

### Negative
- Latency is bounded by L2 block time (~2 seconds on OP Stack), making this unsuitable for HFT strategies that require sub-millisecond execution
- Throughput is bounded by L2 gas limits, which may become a bottleneck under extreme market conditions
- Every order placement, cancellation, and modification costs gas, which creates a cost floor for market makers quoting tight spreads
- Matching algorithm complexity is constrained by EVM gas limits, requiring careful optimization

### Neutral
- The Rust backend still handles indexing, API serving, keeper bots, and the Lighter mirror, so a significant portion of the codebase is off-chain infrastructure regardless
- OP Stack L2 block times and gas costs are expected to improve over time (e.g., EIP-4844 blob data, Bedrock optimizations), which will improve the on-chain CLOB experience without architectural changes
- This architecture is directly aligned with Lighter.xyz, which serves as both an architectural reference and a liquidity source via mirroring

## Alternatives Considered
### GMX-style vAMM
- Pros: No orderbook complexity, deep liquidity from LP pools, simple UX for traders, proven model with billions in TVL
- Cons: LPs take the opposite side of every trade creating adverse selection, price impact scales with trade size, no true price discovery, funding mechanism is less responsive
- Why rejected: vAMMs are fundamentally a different product. They provide synthetic exposure priced by an oracle, not a real market with price discovery. Gaekju aims to be a real exchange with a proper orderbook.

### Hyperliquid Off-chain Engine
- Pros: Sub-millisecond matching, no gas costs for orders, can handle institutional-grade throughput, battle-tested at scale
- Cons: Requires trusting the off-chain sequencer for fair ordering, introduces a centralization point that undermines the "DEX" premise, significantly more complex to build and operate (need to run a matching engine + consensus)
- Why rejected: An off-chain matching engine on a testnet L2 defeats the purpose. The goal is trustless execution. If we wanted centralized matching, we would build a CEX.

### Vertex Hybrid Model
- Pros: Best of both worlds in theory, off-chain speed with on-chain settlement guarantees, can handle high throughput while maintaining verifiability
- Cons: Massive implementation complexity (need both an off-chain sequencer and on-chain verification), introduces trust in the sequencer for ordering fairness, harder to reason about correctness when state lives in two places
- Why rejected: The complexity is not justified for a testnet deployment. The hybrid model solves a scaling problem we do not have on a low-traffic L2 testnet.

### Diamond Proxy (EIP-2535) Monolith
- Pros: Single contract address for the entire protocol, shared storage between facets, unlimited contract size via facets
- Cons: Shared storage introduces coupling between facets, upgrade of one facet can break another, debugging is harder with delegatecall chains, tooling support is weaker than standard proxies
- Why rejected: Diamond proxy solves contract size limits but introduces storage coupling that undermines modularity. We achieve the same goals with separate contracts behind individual UUPS proxies (see ADR-0002, ADR-0009).
