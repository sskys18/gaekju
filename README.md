# Gaekju (객주)

Perpetual futures DEX on [Giwa Chain](https://giwa.chain) (OP Stack L2), following the [Lighter.xyz](https://lighter.xyz) on-chain CLOB architecture.

```
  Lighter.xyz ──WebSocket──▶ Mirror Agent ──tx──▶ Giwa L2 Orderbook ◀── Traders
  (real depth)                  (Rust)             (Solidity CLOB)       (testnet)
```

## Features

- **On-chain CLOB** — bitmap-based orderbook with price-time priority matching, all in smart contracts
- **80+ markets** — crypto, Korean stocks (Samsung, SK Hynix, KRCOMP), US indices (SPY, QQQ), forex, commodities
- **Lighter mirror** — real market depth from Lighter.xyz's 220+ perp markets
- **Rust backend** — indexer, API server, keeper bots, mirror agent, SDK, CLI
- **Production-grade** — margin engine, liquidations, insurance fund, ADL, 1-hour funding

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh) (forge, cast, anvil)
- [Rust](https://rustup.rs) (stable toolchain)
- PostgreSQL 15+

### Build

```bash
# Contracts
cd contracts && forge build

# Rust
cargo build --all
```

### Test

```bash
# Contracts
cd contracts && forge test -vvv

# Rust
cargo test --all
```

### Lint

```bash
cd contracts && forge fmt
cargo clippy --all-targets -- -D warnings
cargo fmt --all
```

## Project Structure

```
contracts/          Solidity smart contracts (Foundry)
crates/             Rust workspace (7 crates)
  gaekju-types/     Shared types + ABI bindings
  gaekju-indexer/   Chain event indexer → PostgreSQL
  gaekju-api/       REST + WebSocket API (axum)
  gaekju-keeper/    Liquidation + funding keeper bots
  gaekju-mirror/    Lighter.xyz liquidity bridge
  gaekju-sdk/       Rust trading SDK
  gaekju-cli/       Admin + trading CLI
docs/               Documentation
  specs/            Design specification
  adr/              Architecture decision records
  blog/             "Building a Perp DEX from Scratch" series
  architecture/     System architecture docs
  api/              API reference + OpenAPI spec
  reference/        Glossary, formulas, market configs
```

## Documentation

- [Design Specification](docs/specs/2026-04-06-gaekju-design.md)
- [Architecture Overview](docs/architecture/overview.md)
- [Architecture Decision Records](docs/adr/README.md)
- [Market Configurations](docs/reference/market-configs.md)
- [Formulas Reference](docs/reference/formulas.md)
- [Glossary](docs/reference/glossary.md)

## Blog Series

"Building a Perp DEX from Scratch" — documenting every decision:

- [#00: Why We're Building Gaekju](docs/blog/00-why-gaekju.md)
- [#01: Choosing a Perp DEX Architecture](docs/blog/01-choosing-architecture.md)
- [Full series](docs/blog/README.md)

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

[MIT](LICENSE)
