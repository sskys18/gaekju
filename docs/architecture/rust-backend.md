# Rust Backend Architecture

## Workspace

```
crates/
├── gaekju-types/       — Shared types, alloy ABI bindings, canonical batch/intent/fill formats
├── gaekju-sequencer/   — Off-chain matching engine, WS/REST API, EIP-712 verify, batch emitter
├── gaekju-prover/      — SP1 guest program + host prover service, proof submission to Settlement
├── gaekju-indexer/     — Reads sequencer stream + on-chain Settlement events → PostgreSQL
├── gaekju-api/         — REST + WebSocket API (axum); reads sequencer (live) + indexer (historical)
├── gaekju-keeper/      — Liquidation + funding keeper bots; retargets Settlement address
├── gaekju-mirror/      — Lighter.xyz liquidity bridge; writes to sequencer endpoint
├── gaekju-sdk/         — Rust SDK; sequencer WS/REST + on-chain deposit/withdraw
└── gaekju-cli/         — Admin + trading CLI (clap); uses SDK
```

## Crate Roles

### gaekju-sequencer (new)
The matching engine. Authoritative orderbook state lives here.
- WS + REST API for signed EIP-712 intent submission (place, cancel, modify).
- Verifies signature, nonce, and margin availability.
- Deterministic price-time priority matching.
- Emits fills to WS subscribers in ms.
- Seals batches on a time or size trigger: `(prevStateRoot, intents[], fills[], postStateRoot)`.
- Exposes batch stream to `gaekju-prover`.
- The matching state machine is a pure library crate shared with the SP1 guest — one implementation, two call sites.

### gaekju-prover (new)
SP1 guest program + host service.
- Guest: re-executes the sequencer's matching state machine over a batch. Public inputs are the canonical `BatchPublicInputs` struct — `(prevStateRoot, postStateRoot, batchHash, batchNonce, chainId, forceIncludeCursor)` per design spec §14.1. `marketId` is **not** a public input (fills carry their own `marketId`).
- Host: drives proving (local or Succinct prover network), submits a `ProofBundle` to `Settlement.applyBatch` on Giwa (spec §15.1).
- Handles prover retries, proof cache, cost accounting.

### gaekju-types
Single source of truth for cross-crate wire compatibility.
- Alloy bindings for `Settlement`, `Router`, `Vault`, `PositionManager`, `FundingRate`, `LiquidationEngine`, and `MarketFactory`.
- Canonical Rust mirrors of `BatchPublicInputs`, `ProofBundle`, `BatchBlob`, `BatchHeader`, `Fill`, `BalanceDelta`, `MidPriceUpdate`, `ForcedOutcome`, and the signed-intent payload used by both sequencer intake and `Router.forceInclude`.
- Event decoders for `BatchSettled`, `ForceIncludeQueued`, `ForcedIntentResolved`, plus surviving deposit / withdraw / funding / liquidation events.
- Encoding helpers/tests that prove Rust `abi_encode()` matches Solidity tuple order exactly for `ProofBundle` and `BatchBlob`; this is load-bearing for SP1 public-input verification and `keccak256(abi.encode(BatchBlob))`.

### gaekju-indexer
Reads two streams:
- Sequencer WS (live intents, fills, batch seals) → `pending` / `sealed` rows.
- On-chain Settlement events (`BatchSettled`, force-include queue events) → `final` rows.
Reconciles the two so API can serve consistent state at any confirmation level.

### gaekju-api
- Historical queries from PostgreSQL (indexer output).
- Live WS fan-out from sequencer stream.
- `pending / sealed / final` state exposed per order / fill.

### gaekju-keeper
Liquidation and funding bots. Unchanged logic; target address changes from OrderBook to Settlement / LiquidationEngine / FundingRate (core addresses come from the bootstrap deploy output, not from `MarketFactory` market config rows).

### gaekju-mirror
Unchanged purpose, new target. Writes signed EIP-712 intents to the sequencer REST/WS endpoint instead of calling `OrderBook.placeLimitOrder`. Signing, nonce discipline, and rate limiting match a normal trader account.

### gaekju-sdk / gaekju-cli
Endpoint targets updated:
- Trading paths → sequencer WS/REST.
- Deposit / withdraw / forceInclude → Router on Giwa.
- Position / PnL reads → API (backed by indexer).

## Dependency Flow

```
gaekju-types ← used by everything (intent, batch, fill, ABI bindings, event decoders, matching state-machine lib)

gaekju-sequencer ← admits intents, matches, emits batches
gaekju-prover    ← consumes batches from sequencer, produces proofs, submits to Settlement
gaekju-indexer   ← reads sequencer WS + on-chain events, writes PostgreSQL
gaekju-api       ← reads PostgreSQL + sequencer WS, serves clients
gaekju-keeper    ← reads DB + oracle, submits liquidation/funding txs
gaekju-mirror    ← reads Lighter API, submits signed intents to sequencer
gaekju-sdk       ← wraps sequencer API + on-chain calls
gaekju-cli       ← uses SDK
```

## Key Dependencies

| Crate | Purpose |
|-------|---------|
| `alloy` | Ethereum types, providers, contract bindings |
| `sp1-sdk` / `sp1-zkvm` | zkVM guest + host prover |
| `tokio` | Async runtime |
| `axum` | HTTP/WebSocket server (sequencer + api) |
| `sqlx` | PostgreSQL async driver |
| `serde` | Serialization |
| `tracing` | Structured logging |
| `clap` | CLI argument parsing |
| `prometheus` | Metrics |
| `eyre` | Error handling |

## Data Flow

```
Intent (EIP-712)  →  Sequencer  →  Fill stream (WS)                    → Indexer → PostgreSQL → API → Clients
                         │
                         └─ Batch  →  Prover (SP1)  →  Settlement (Giwa) → Indexer (final) →  API

Lighter API → Mirror → Sequencer (signed intents)

PostgreSQL / Oracle → Keeper → Chain (liquidate / fund)
```

See [Full Design Spec](../specs/2026-04-06-gaekju-design.md) for database schema, API endpoints, batch format, and SP1 public-input layout.
