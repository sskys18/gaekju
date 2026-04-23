# Smart Contract Architecture

Matching lives off-chain in the Rust sequencer; on-chain contracts verify SP1 proofs and apply state deltas. See [ADR-0012](../adr/0012-zkvm-matcher-pivot.md).

## Contract Map

```
MarketFactory (config-only, no contract deploys per market)
Settlement         (global, single instance)  — SP1 proof verifier, multi-market batch decoder, state applier
├── PositionManager                    — Position lifecycle, PnL, registry (all markets)
├── MarginEngine                       — Margin checks, market configs
├── LiquidationEngine                  — Liquidation, insurance fund, ADL
├── FundingRate                        — Hourly funding calculation (per-market state, single contract)
├── OracleAdapter                      — Pyth price feeds, mark/index price
├── Vault                              — USDC deposits, collateral accounting
└── Router                             — deposit / withdraw / forceInclude

Libraries:
└── FixedPointMath.sol                 — 18-decimal arithmetic
```

`OrderBook.sol`, `BitmapLib.sol`, `TickMath.sol`, `PackedOrder.sol` are deleted — orderbook state lives in the Rust sequencer.

## Settlement.sol

**Global singleton** — one contract instance for the entire exchange. A single batch can contain fills across any number of markets; each `Fill` carries its own `marketId`. There is no per-market Settlement proxy. Settlement is the sole caller of Vault / PositionManager / MarginEngine / FundingRate (via `SETTLEMENT_ROLE`). Rationale: one sequencer, one proven state machine, one batch chain, one force-include queue. Per-market settlement would fragment the nonce chain, the force-include queue, and the proof cadence for no safety gain.

**Responsibilities:**
- Verify the SP1 proof against canonical `BatchPublicInputs` — `(prevStateRoot, postStateRoot, batchHash, batchNonce, chainId, forceIncludeCursor)`. See design spec §14.1 for the canonical struct; there is no `marketId` in public inputs (batches can contain fills across multiple markets; `marketId` lives per-`Fill` inside the blob).
- Enforce batch nonce strictly monotonic (`nonce[n+1] == nonce[n] + 1`, no gaps, no replays) and `chainId == block.chainid` (prevents cross-chain/fork replay).
- Anchor `prevStateRoot` to the previously accepted `postStateRoot` so batches chain.
- Decode the state delta: accepted intents, fills, balance deltas, `ForcedOutcome[]` (accepted-with-fill OR rejected-with-reason-code — the sequencer cannot claim "resolved" without the prover running the intent through the circuit).
- Dispatch deltas to Vault (all collateral / margin / PnL / funding-payment moves — Vault is the single owner under Path B) and PositionManager (position state only, no inline `vault.*` mutations). See design spec §15.3.1 for the Vault/PositionManager split rationale + equivalence test gate.
- Enforce force-inclusion SLA: for every queue entry whose `deadlineBatchNonce <= batchNonce`, the batch must contain a proved `ForcedOutcome`. Else `applyBatch` reverts with `ForcedIntentOverdue` — Settlement refuses further batches until governance clears the queue (ADR-0014, design spec §15.3).
- Support `programVKey` rotation via pause-and-drain procedure (spec §15.5) — `proposeProgramVKey` + timelock + `activateProgramVKey` (requires `paused() == true` and prover queue drained). Rejected alternatives: immutable vkey + Settlement redeploy; dual-vkey grace window.

## Contract Interactions

```
User → Router.deposit / withdraw → Vault
User → Router.forceInclude(intent) → Settlement (queued for next batch)

Sequencer → Prover → Settlement.applyBatch(ProofBundle)
                      ├─ SP1 verify + chainId + nonce/prevRoot
                      ├─ ForcedOutcome liveness check (queue deadlines)
                      ├─ Vault.applyBatchDelta(...)            — sole writer of vault buckets
                      ├─ PositionManager.applyBatchFills(...)  — position state only
                      ├─ MarginEngine.check(...)               — invariant asserts
                      └─ emit BatchSettled(nonce, prevRoot, postRoot, batchHash, cursor)

Keeper → LiquidationEngine.liquidate()
           ├─ FundingRate.settleFunding()
           ├─ PositionManager.updatePosition()
           └─ Vault (distribute fees / insurance)

Keeper → FundingRate.applyFunding() → OracleAdapter (get prices)
```

## Upgradability

All contracts use UUPS proxy (EIP-1822):
- 24-hour Timelock for all upgrades
- 3-of-5 multisig (Gnosis Safe) owns the Timelock
- Emergency pause bypasses timelock (pause only, not upgrade)
- Storage gaps (`uint256[50] __gap`) for future expansion

## Key Invariants

- `USDC.balanceOf(vault) * 1e12 >= totalDeposits`
- Sum of long OI == sum of short OI per market
- Batch nonce strictly monotonic; no gaps, no replays
- `postStateRoot = f(prevStateRoot, batch)` proven by SP1; submitted `prevStateRoot` equals previously accepted `postStateRoot`
- Fills sum conservation: `Σ(taker collateral Δ) + Σ(maker collateral Δ) + insuranceΔ + feeΔ = 0` per batch
- Force-included intents processed within N batches (global `FORCE_INCLUDE_N`, default 3; configurable via timelocked governance — not per-market)
- Position holders tracked in EnumerableSet for ADL
- Only `SETTLEMENT_ROLE` may mutate Vault / PositionManager / MarginEngine / FundingRate state deltas

(Removed: `bestBid < bestAsk` — no orderbook on-chain.)

## MarketFactory

Config-only registry under the global Settlement model. `MarketFactory.createMarket(params)` registers a `marketId` + `MarketParams` (tick, lot, IMR, MMR, funding interval, Pyth price id, caps, fees) into on-chain storage read by Settlement during `applyBatch`. No per-market contract deployment — Settlement, Vault, PositionManager, MarginEngine, LiquidationEngine, FundingRate, OracleAdapter are deployed once at bootstrap. Markets can be paused individually by flipping `marketActive[marketId]`.

## Router

Thin contract. Surface:
- `deposit(uint256 usdcAmount)` → Vault
- `withdraw(uint256 usdcAmount)` → Vault (subject to MarginEngine free-collateral check)
- `forceInclude(SignedIntent calldata intent)` → queues an intent for the next batch; Settlement must consume it within N batches

No order placement path — traders submit EIP-712 intents directly to the sequencer over WS/REST.

See [Full Design Spec](../specs/2026-04-06-gaekju-design.md) for complete contract specifications.
