# Smart Contract Architecture

Matching lives off-chain in the Rust sequencer; on-chain contracts verify SP1 proofs and apply state deltas. See [ADR-0012](../adr/0012-zkvm-matcher-pivot.md).

## Contract Map

```
MarketFactory
├── Settlement (one per market)       — SP1 proof verifier, batch decoder, state applier
├── PositionManager                    — Position lifecycle, PnL, registry
├── MarginEngine                       — Margin checks, market configs
├── LiquidationEngine                  — Liquidation, insurance fund, ADL
├── FundingRate                        — Hourly funding calculation
├── OracleAdapter                      — Pyth price feeds, mark/index price
├── Vault                              — USDC deposits, collateral accounting
└── Router                             — deposit / withdraw / forceInclude

Libraries:
└── FixedPointMath.sol                 — 18-decimal arithmetic
```

`OrderBook.sol`, `BitmapLib.sol`, `TickMath.sol`, `PackedOrder.sol` are deleted — orderbook state lives in the Rust sequencer.

## Settlement.sol

Per-market contract, sole caller of Vault / PositionManager / MarginEngine / FundingRate (via `SETTLEMENT_ROLE`).

**Responsibilities:**
- Verify the SP1 proof against the committed public inputs (`prevStateRoot`, `postStateRoot`, batch commitment, market id, chain id).
- Enforce batch nonce strictly monotonic (`nonce[n+1] == nonce[n] + 1`, no gaps, no replays).
- Anchor `prevStateRoot` to the previously accepted `postStateRoot` so batches chain.
- Decode the state delta: accepted intents, rejected intents, fills (taker/maker, price, size), position updates, margin unlocks, funding settlements.
- Dispatch deltas to Vault (collateral moves), PositionManager (position mutations), MarginEngine (invariant checks), FundingRate (cumulative funding index advances).
- Enforce force-inclusion SLA: intents accepted via `Router.forceInclude` must be processed (filled or rejected) within N batches; otherwise the sequencer is in default and Settlement refuses further batches until the queue clears.

## Contract Interactions

```
User → Router.deposit / withdraw → Vault
User → Router.forceInclude(intent) → Settlement (queued for next batch)

Sequencer → Prover → Settlement.submitBatch(batch, proof)
                      ├─ SP1 verify
                      ├─ PositionManager.applyBatchFills(...)
                      ├─ Vault.applyBatchDelta(...)
                      ├─ MarginEngine.check(...)
                      └─ FundingRate.advance(...)

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
- Force-included intents processed within N batches (default configurable per market)
- Position holders tracked in EnumerableSet for ADL
- Only `SETTLEMENT_ROLE` may mutate Vault / PositionManager / MarginEngine / FundingRate state deltas

(Removed: `bestBid < bestAsk` — no orderbook on-chain.)

## MarketFactory

Deploys one Settlement proxy per market, wires the Settlement address into the shared Vault / PositionManager / MarginEngine / FundingRate as an authorized caller. No OrderBook deployment.

## Router

Thin contract. Surface:
- `deposit(uint256 usdcAmount)` → Vault
- `withdraw(uint256 usdcAmount)` → Vault (subject to MarginEngine free-collateral check)
- `forceInclude(SignedIntent calldata intent)` → queues an intent for the next batch; Settlement must consume it within N batches

No order placement path — traders submit EIP-712 intents directly to the sequencer over WS/REST.

See [Full Design Spec](../specs/2026-04-06-gaekju-design.md) for complete contract specifications.
