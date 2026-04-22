# Gaekju

Perpetual DEX on Giwa Chain (OP Stack L2). ZK-proven off-chain matcher. Rust sequencer matches orders, SP1 zkVM proves correctness, Settlement.sol on Giwa verifies and applies state delta. Per ADR-0012.

## Build Commands

### Contracts (Foundry)
- `cd contracts && forge build` - compile
- `cd contracts && forge test -vvv` - run tests
- `cd contracts && forge fmt` - format
- `cd contracts && forge test --match-contract <Name>` - run specific test file

### Rust
- `cargo check` - typecheck
- `cargo test --all` - run all tests
- `cargo clippy --all-targets -- -D warnings` - lint
- `cargo fmt --all -- --check` - format check

## Architecture
- `contracts/src/libraries/` - pure math/encoding libs (FixedPointMath)
- `contracts/src/interfaces/` - contract interfaces
- `contracts/src/*.sol` - core contracts (Vault, OracleAdapter, MarginEngine, PositionManager, FundingRate, LiquidationEngine, Settlement, Router)
- `contracts/test/` - unit/, integration/, fuzz/, mocks/
- `crates/gaekju-types/` - shared Rust types + ABI bindings
- `crates/gaekju-sequencer/` - off-chain Rust matching engine (accepts EIP-712 intents, emits batches)
- `crates/gaekju-prover/` - SP1 zkVM proving service (re-executes matcher, emits SNARK proof)
- `crates/gaekju-mirror/` - Lighter.xyz liquidity bridge (writes to sequencer, NOT bots)

## Design Spec

Complete specification: `docs/specs/2026-04-06-gaekju-design.md`

Read it before making architectural decisions.

## Conventions
- All internal math uses 18-decimal fixed-point (1e18 = 1.0)
- USDC 6→18 conversion happens ONLY at Vault boundary
- Use `mulFp(a, b)` and `divFp(a, b)` for fixed-point operations
- Contracts use UUPS proxy pattern
- Solidity: 0.8.28, optimizer 200 runs
- Funding intervals: 1 hour (not 8 hours)
- Mark price: 70% oracle + 30% orderbook mid-price
- IMR and MMR are independently configured per market (not auto-derived)
- Tests: unit tests co-located by contract, integration tests in integration/

## Do Not
- Do not use ethers-rs (use alloy)
- Do not use 8-hour funding (use 1 hour)
- Do not create bot/simulation systems (mirror Lighter.xyz instead)
- Do not add cross-margin logic (isolated margin only in v1)
- Do not reintroduce on-chain matching logic — all matching lives in the Rust sequencer. Settlement.sol only verifies SP1 proofs and applies deltas.
