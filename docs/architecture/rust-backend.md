# Rust Backend Architecture

## Workspace

```
crates/
├── gaekju-types/       — Shared types, ABI bindings (alloy)
├── gaekju-indexer/      — Event indexer → PostgreSQL
├── gaekju-api/          — REST + WebSocket API (axum)
├── gaekju-keeper/       — Liquidation + funding keeper bots
├── gaekju-mirror/       — Lighter.xyz liquidity bridge
├── gaekju-sdk/          — Rust SDK for programmatic trading
└── gaekju-cli/          — Admin + trading CLI (clap)
```

## Dependency Flow

```
gaekju-types ← used by everything

gaekju-indexer ← reads chain events, writes to PostgreSQL
gaekju-api ← reads from PostgreSQL + indexer state, serves clients
gaekju-keeper ← reads from DB, submits txs to chain
gaekju-mirror ← reads Lighter API, submits txs to chain
gaekju-sdk ← wraps contract calls + API, used by keeper/mirror/cli
gaekju-cli ← uses SDK for all operations
```

## Key Dependencies

| Crate | Purpose |
|-------|---------|
| `alloy` | Ethereum types, providers, contract bindings |
| `tokio` | Async runtime |
| `axum` | HTTP/WebSocket server |
| `sqlx` | PostgreSQL async driver |
| `serde` | Serialization |
| `tracing` | Structured logging |
| `clap` | CLI argument parsing |
| `prometheus` | Metrics |
| `eyre` | Error handling |

## Data Flow

```
Chain Events → Indexer → PostgreSQL → API → Frontend/Traders
                                         → WebSocket streams

Lighter API → Mirror Agent → Chain (place/cancel orders)

PostgreSQL → Keeper → Chain (liquidate/fund)
```

See [Full Design Spec](../specs/2026-04-06-gaekju-design.md) for database schema, API endpoints, and keeper loop details.
