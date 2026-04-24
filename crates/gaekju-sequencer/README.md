# gaekju-sequencer

Off-chain Rust matcher for the Path B perp DEX. It accepts EIP-712 signed intents, runs deterministic matching through `gaekju-matching-core`, broadcasts live events, and seals exchange-wide batches for the prover inbox.

## Configuration

Environment variables:

- `GAEKJU_BIND` REST bind address, default `127.0.0.1:8080`
- `GAEKJU_WS_BIND` WS bind address, default `127.0.0.1:8081`
- `GAEKJU_CHAIN_ID` EIP-712 domain chain id, default `31337`
- `GAEKJU_SETTLEMENT` EIP-712 verifying contract address
- `GAEKJU_MARKETS` comma-separated market ids, default `1`
- `GAEKJU_BATCH_MS` batch cadence, default `5000`
- `GAEKJU_PROVER_INBOX` local prover inbox, default `prover/inbox`
- `GAEKJU_DATA_DIR` WAL/snapshot directory, default `.gaekju-sequencer`

## REST

- `POST /v1/intent` with `{ "intent": ..., "sig": [u8;65] }`
- `GET /v1/book/:market?depth=20`
- `GET /v1/trades/:market?since=0`
- `GET /v1/trader/:addr`
- `GET /v1/batch/:nonce`
- `GET /v1/status`
- `GET /healthz`
- `GET /readyz`
- `GET /metrics`
- `GET /openapi.json`

`POST /v1/intent` rejects sequencer-path duplicates of mirrored force-included hashes with `DuplicateOfForced`; those intents must execute through the forced path.

## WebSocket

Connect to `/ws/stream` on the WS bind port and send a text subscription containing one or more topics:

- `book:<market>`
- `trades:<market>`
- `mark:<market>`
- `user:<addr>`

Clients that lag the bounded broadcast buffer are disconnected and can resubscribe.

## Local Run

```sh
GAEKJU_SETTLEMENT=0x0000000000000000000000000000000000000000 cargo run -p gaekju-sequencer
```

Batches close every 5 seconds by default and are written as bincode to `prover/inbox/<nonce>.batch`. The on-chain batch hash is computed separately from the canonical Alloy ABI encoding of `BatchBlob`.
