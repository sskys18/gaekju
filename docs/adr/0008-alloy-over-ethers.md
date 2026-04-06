# ADR-0008: Alloy over ethers-rs

## Status
Accepted

## Date
2026-04-06

## Context
Gaekju's Rust backend (see ADR-0007) requires an Ethereum library for all on-chain interaction: reading contract state, submitting transactions, decoding event logs, managing providers and signers, and generating type-safe bindings from Solidity ABIs. Every crate in the workspace depends on this library. The indexer uses it to subscribe to and decode events. The keeper uses it to call `isLiquidatable()` and submit `liquidate()` transactions. The SDK wraps it for trader-facing contract calls. The mirror agent uses it to place and cancel orders on-chain. The choice of Ethereum library is a foundational dependency that touches every crate.

The two candidates in the Rust ecosystem are ethers-rs and alloy. ethers-rs was the original Rust Ethereum library, modeled after ethers.js, and was the standard choice for Rust web3 projects from 2021 through 2023. However, the ethers-rs maintainers (Georgios Konstantopoulos and the Paradigm team) officially deprecated it in favor of alloy, which they built as its successor. The ethers-rs repository has been archived and receives no updates, including security patches. alloy is under active development by the same team, with regular releases, and is the library used by Foundry, Reth, and other modern Rust Ethereum tooling.

A key technical differentiator is ABI binding generation. ethers-rs uses the `abigen!` macro which generates Rust structs and functions from ABI JSON at compile time, but the generated code has known rough edges (inconsistent naming, limited tuple support, awkward handling of overloaded functions). alloy's `sol!` macro takes a different approach: it accepts Solidity type syntax directly and generates idiomatic Rust types that mirror the Solidity source. This means Gaekju's ABI bindings can be generated directly from the Solidity interface definitions, producing types that are immediately recognizable to anyone reading both the contracts and the Rust code.

## Decision
Gaekju uses alloy (version 0.12+) as its sole Ethereum library across all Rust crates. ABI bindings are generated using alloy's `sol!` macro from Foundry build artifacts and placed in the `gaekju-types/src/bindings/` module for workspace-wide sharing. All provider management, transaction construction, signing, event log decoding, and type conversions use alloy primitives (`Address`, `U256`, `B256`, `FixedBytes`, etc.) rather than ethers-rs equivalents.

## Consequences
### Positive
- Actively maintained with regular releases, bug fixes, and security patches; the team behind it (Paradigm/Alloy Labs) is the same team that built ethers-rs and made the deliberate decision to replace it
- `sol!` macro produces cleaner, more idiomatic Rust types than ethers-rs `abigen!`; generated types match Solidity naming conventions, making cross-referencing between contracts and Rust code straightforward
- First-class support for modern EIPs (EIP-4844 blob transactions, EIP-7702 account abstraction) that ethers-rs will never support
- Used by Foundry and Reth, so the library is battle-tested against real Ethereum infrastructure at scale
- Consistent type system: alloy's primitive types (`Address`, `U256`) are used throughout the ecosystem, eliminating conversion boilerplate between different libraries
- Better async support and provider abstractions, including built-in retry logic, transport layer abstraction, and WebSocket subscription management

### Negative
- alloy is pre-1.0 (version 0.12), so breaking changes between minor versions are possible and have occurred historically
- Documentation is thinner than ethers-rs, which had years of community-written guides and Stack Overflow answers
- Some niche features from ethers-rs (specific middleware patterns, certain provider wrappers) may not have alloy equivalents yet
- The `sol!` procedural macro increases compile times, particularly for large ABI surfaces (Gaekju has 10+ contracts with complex structs), adding 30-60 seconds to clean builds

## Alternatives Considered
### ethers-rs
- Pros: More mature with years of production usage, extensive documentation and community examples, familiar to developers who have used ethers.js, stable API surface (no more breaking changes because it is frozen)
- Cons: Officially deprecated and archived by its maintainers, no security patches or bug fixes, no support for EIPs after mid-2023, `abigen!` macro has known issues with complex Solidity types (nested structs, function overloads), the maintainers explicitly recommend migrating to alloy
- Why rejected: Using a deprecated library as a foundational dependency is untenable. Every unpatched vulnerability in ethers-rs would be a vulnerability in Gaekju's keeper bots, which hold signing keys and submit value-bearing transactions. The migration cost from ethers-rs to alloy only grows over time, so starting on alloy eliminates a future forced migration.

### Raw JSON-RPC (no library)
- Pros: Zero external dependency, full control over request/response handling, no library upgrade burden
- Cons: Must implement provider logic (retries, WebSocket reconnection, nonce management), ABI encoding/decoding, type conversions, and transaction signing from scratch. This is thousands of lines of infrastructure code that alloy provides and maintains. Every edge case (EIP-155 signing, access list encoding, log bloom filtering) must be handled manually.
- Why rejected: Reimplementing Ethereum client logic is not a productive use of development time. alloy exists precisely to encapsulate this complexity, and it is maintained by experts who understand the edge cases better than any single project team.
