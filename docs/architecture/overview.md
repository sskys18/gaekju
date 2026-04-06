# Architecture Overview

Gaekju is a perpetual futures DEX on Giwa Chain (OP Stack L2) following the Lighter.xyz on-chain CLOB model.

## System Diagram

```
                         ┌─────────────────────────────┐
                         │      Giwa Chain (OP Stack)    │
                         │                               │
  Traders ──WebSocket──▶ │  ┌─────────────────────────┐ │
  & REST API             │  │    Smart Contracts        │ │
                         │  │                           │ │
  ┌────────────────┐     │  │  MarketFactory            │ │
  │  Rust Backend   │◀───│  │  ├─ OrderBook (per mkt)  │ │
  │                 │    │  │  ├─ PositionManager       │ │
  │  gaekju-indexer │    │  │  ├─ MarginEngine          │ │
  │  gaekju-api     │───▶│  │  ├─ LiquidationEngine    │ │
  │  gaekju-keeper  │    │  │  ├─ FundingRate           │ │
  │  gaekju-mirror  │    │  │  ├─ OracleAdapter (Pyth)  │ │
  │  gaekju-sdk     │    │  │  ├─ Vault (USDC)          │ │
  │  gaekju-cli     │    │  │  └─ Router                │ │
  └────────────────┘     │  └─────────────────────────┘ │
                         └─────────────────────────────┘
        ▲
        │ WebSocket
  ┌─────┴──────┐
  │ Lighter.xyz │  ← Real liquidity source (220+ markets)
  └────────────┘
```

## Two Layers

### On-Chain (Solidity)
The smart contracts ARE the exchange. All matching, position management, margin checks, and liquidation happen on Giwa L2. See [contracts.md](contracts.md).

### Off-Chain (Rust)
The Rust backend is infrastructure — it does not make trading decisions. It indexes events, serves APIs, runs keeper bots, and mirrors Lighter depth. See [rust-backend.md](rust-backend.md).

## Key Design Principles

1. **On-chain first** — contracts are the source of truth
2. **Modular** — each concern in its own upgradeable contract
3. **Mirror, don't simulate** — real liquidity from Lighter, not fake bots
4. **Rust everywhere** — one language for all backend services
5. **Document everything** — ADRs, blog posts, specs for every decision

## Further Reading

- [Smart Contract Architecture](contracts.md)
- [Rust Backend Architecture](rust-backend.md)
- [Order Lifecycle & Data Flow](data-flow.md)
- [Full Design Spec](../specs/2026-04-06-gaekju-design.md)
- [Architecture Decision Records](../adr/README.md)
