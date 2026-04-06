# ADR-0007: Rust for Backend Infrastructure

## Status
Accepted

## Date
2026-04-06

## Context
Gaekju's backend infrastructure encompasses six distinct services: an event indexer that processes every block on Giwa Chain into PostgreSQL, a REST/WebSocket API server (axum-based), keeper bots for liquidation, funding rate triggers, and oracle price updates, a Rust SDK for programmatic traders, a CLI tool for operator tasks, and a Lighter.xyz liquidity mirror agent. These components share fundamental requirements: they are latency-sensitive (keepers must detect and liquidate undercollateralized positions within seconds before positions go bankrupt), data-intensive (the indexer must decode and persist every contract event across all markets), and long-running (bots operate 24/7 without restarts).

The language choice has outsized impact because all six services share types: order structs, position structs, market configs, ABI bindings, and error types. If these are defined once in a shared crate, changes propagate at compile time. If services use different languages, type definitions are duplicated across language boundaries with serialization mismatches as an ongoing operational risk. A margin calculation mismatch between a TypeScript API and a Rust keeper, for example, could cause the API to display a position as healthy while the keeper attempts liquidation.

The primary candidates were TypeScript (dominant in web3 frontend and tooling), Go (proven for blockchain infrastructure via Geth and Prysm), Rust (growing ecosystem via Reth, Foundry, and alloy), and Python (rapid prototyping but unsuitable for production infrastructure). The decision needed to account for the alloy library (see ADR-0008), which provides compile-time type-safe Ethereum contract bindings exclusively in Rust, and the Cargo workspace model which enables a monorepo of related crates with unified build, test, and lint pipelines.

## Decision
All backend infrastructure is written in Rust, organized as a Cargo workspace with shared crates. The workspace contains: `gaekju-types` (shared types and auto-generated ABI bindings from Foundry artifacts), `gaekju-indexer`, `gaekju-api`, `gaekju-keeper`, `gaekju-sdk`, `gaekju-cli`, and `gaekju-mirror`. Key dependencies are tokio (async runtime), alloy (Ethereum interaction), axum (HTTP/WebSocket), sqlx (PostgreSQL with compile-time query checking), serde (serialization), clap (CLI parsing), and tracing (structured logging). ABI bindings are generated once from Foundry build artifacts via alloy's `sol!` macro and shared across all crates through `gaekju-types`.

## Consequences
### Positive
- Types defined once in `gaekju-types` and shared across all six crates; a struct change is a compile error everywhere it matters
- Rust's ownership model prevents data races in concurrent keeper loops and the async indexer pipeline without garbage collection pauses
- alloy provides first-class Rust support for Ethereum types, providers, and contract interaction with compile-time ABI type checking
- The indexer can process blocks faster than Giwa Chain produces them (2-second block time); keepers submit liquidation transactions with sub-100ms overhead
- Cargo workspace provides unified `cargo build`, `cargo test`, `cargo clippy`, and `cargo fmt` across the entire backend
- Strong error handling with `Result<T, E>` and the `eyre` crate prevents silent failures in long-running services that would go unnoticed in dynamically typed languages
- Memory safety without GC means keeper bots can run for weeks without memory leak concerns that plague long-running Node.js processes

### Negative
- Steeper learning curve for contributors compared to TypeScript or Go, potentially limiting community contributions during early development
- Longer compilation times, especially for the full workspace with alloy's procedural macros for ABI generation (clean builds exceed 2 minutes)
- Smaller pool of web3 Rust developers compared to TypeScript/Solidity developers
- Some web3 tooling (The Graph subgraphs, frontend libraries) assumes TypeScript, requiring a TypeScript wrapper or code generation for frontend integration
- Async Rust ergonomics (Pin, lifetimes in async contexts, trait object limitations) add friction to rapid prototyping

## Alternatives Considered
### TypeScript (Node.js)
- Pros: Largest web3 developer community, fastest prototyping velocity, ethers.js/viem are mature and well-documented, shared language with a potential frontend, easy to hire contributors
- Cons: Runtime types are erased (TypeScript compiles away), performance ceiling is lower for data-intensive indexing, single-threaded event loop requires careful orchestration for keepers doing CPU-bound margin calculations alongside I/O, long-running Node processes leak memory without disciplined manual management, no compile-time ABI type safety equivalent to alloy's `sol!` macro
- Why rejected: For infrastructure-heavy workloads (indexers processing every block, keepers scanning hundreds of positions per cycle, bots running 24/7), TypeScript's runtime characteristics introduce operational risk that Rust eliminates at compile time. The keeper bot must process all open positions per block and submit liquidation transactions with deterministic latency; Node.js can do this but with more operational fragility.

### Go
- Pros: Excellent concurrency primitives (goroutines, channels), fast compilation, simple language with gentle learning curve, proven in production Ethereum clients (Geth, Prysm), strong HTTP server ecosystem (net/http, gin, fiber)
- Cons: No equivalent to alloy's type-safe ABI bindings (go-ethereum's ABI handling is manual and stringly-typed), error handling is verbose without sum types or Result patterns, generics support is recent and limited, no workspace-level dependency sharing as ergonomic as Cargo workspace, interface-based polymorphism is less expressive than Rust's trait system for complex domain types
- Why rejected: Go is a strong candidate for infrastructure services, but the absence of an alloy equivalent is decisive. Building six crates with shared ABI-derived types is a natural fit for Cargo workspace. Go modules can share code but with more boilerplate and less compile-time safety at the Ethereum type boundary.

### Python
- Pros: Fastest prototyping speed, excellent for data analysis and one-off scripts, web3.py is mature, large developer community
- Cons: GIL prevents true parallelism, runtime performance is orders of magnitude slower than compiled languages for tight loops (indexer event decoding, keeper margin calculations), type hints are advisory only and not enforced, no compile-time ABI type safety, dependency management (pip, poetry, conda) is fragile for production deployment
- Why rejected: Python is unsuitable for latency-sensitive, long-running infrastructure. The indexer must decode and persist events at block production speed; the keeper must scan all positions and submit transactions within seconds. Python's performance characteristics make these workloads unreliable under load. Useful for scripts and analysis but not for the core backend.
