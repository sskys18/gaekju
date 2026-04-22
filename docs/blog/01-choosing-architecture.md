# Choosing a Perp DEX Architecture

> Part 1 of "Building a Perp DEX from Scratch"

---

## The Honest Version

This post has a longer history than most. The first draft of Gaekju's architecture — and the first version of this blog post — argued for a fully on-chain CLOB in the EVM. We implemented that design through Phase 1 and Phase 2. It compiled, it tested (131 green), and then we did the research we should have done first, and pivoted.

This post is the rewrite. Instead of writing a clean post-hoc "we chose X because Y" narrative, it walks through what we thought, what we learned, and where we landed. The relevant decision records are [ADR-0001](../adr/0001-use-lighter-clob.md) (original, now superseded) and [ADR-0012](../adr/0012-zkvm-matcher-pivot.md) (the pivot).

## The Four Models We Started With

Every perpetual DEX falls into one of four models. Each trades speed, trust, and implementation complexity differently.

### Model 1: vAMM / Pool-Based (GMX, Perpetual Protocol)

Traders trade against a liquidity pool. No orderbook. Price comes from an oracle plus a virtual AMM curve.

**Pros**: Simple, fully on-chain, always liquid.
**Cons**: No limit orders, slippage scales with size, LPs carry directional risk, price discovery is limited.

Ruled out early: we wanted a real orderbook experience with limit orders, post-only, IOC, FOK, and reduce-only.

### Model 2: Off-Chain CLOB (Hyperliquid, dYdX v4, Aevo)

A centralized matching engine runs off-chain. Settlement is on-chain or on a dedicated chain.

**Pros**: CEX-grade speed, deep orderbooks, every order type.
**Cons**: Trust the operator on matching — in practice the operator's word is the matching rule.

ADR-0001 specifically rejected this: *"An off-chain matching engine on a testnet L2 defeats the purpose. The goal is trustless execution. If we wanted centralized matching, we would build a CEX."* We held that line for two phases.

### Model 3: Hybrid / Optimistic (Vertex, Drift)

Orders off-chain, batched to an on-chain engine with optimistic settlement.

**Pros**: Faster than pure on-chain, more decentralized than pure off-chain.
**Cons**: Sequencer is still trusted on execution; fraud-proof windows are long.

### Model 4: On-Chain CLOB in EVM (what we picked first)

Entire orderbook lives in smart contracts. Matching happens inside the EVM.

**Pros**: Fully trustless matching, every fill verifiable on-chain.
**Cons**: Limited by block time, gas per order, contract size constraints.

Our original thesis was that L2 gas had dropped far enough that Model 4 was now viable for perps. We cited Lighter.xyz as evidence. That citation turned out to be wrong.

## What We Actually Shipped in Phase 1 and 2

Under ADR-0001 we built:

- `Vault.sol` — USDC deposit/withdraw, order margin, locked margin, insurance fund.
- `PositionManager.sol` — per-market position state, weighted avg entry price, realized/unrealized PnL.
- `MarginEngine.sol` — IMR/MMR checks, margin ratio math.
- `LiquidationEngine.sol` — partial/full liquidation, ADL.
- `OracleAdapter.sol` — Pyth-backed mark price with oracle + mid blend.
- `OrderBook.sol` — limit/market/IOC/FOK/post-only/reduce-only, bitmap price levels.
- Supporting libraries: `BitmapLib`, `TickMath`, `PackedOrder`, `FixedPointMath`.

131 tests passed. The bitmap CLOB compiled under `solc 0.8.28` with 200-run optimization. Phase 3 was scoped to add MarketFactory, Router, and IOC wiring.

Before starting Phase 3 we sat down and did a proper survey of the 2026 perp landscape and Giwa ecosystem. That's where things broke.

## Finding 1: "Lighter-style on EVM" Was a Category Error

The clearest failure in ADR-0001. We cited Lighter as proof an on-chain CLOB for perps could work. Research into Lighter's actual stack (`docs/research/lighter-stack-investigation.md`) showed:

- Lighter is an **application-specific zk-rollup**, not an EVM app.
- Its matching loop runs in a **Rust sequencer off-chain**.
- Correctness is proven by a **Plonky2 STARK → gnark PLONK SNARK**, settled on Ethereum L1.
- Amortized cost is ~$0.007 per user operation.
- No part of matching runs inside EVM.

Lighter's design is exactly the ZK-off-chain-matcher shape we're now pivoting to. We had cited the right reference, we just hadn't read it carefully enough.

The honest EVM-native precedent for what we were building is **Clober on Base** — also a bitmap CLOB, but spot-only. Nobody has run an EVM bitmap CLOB for perpetuals (with funding, liquidation, and ADL) at production scale. The bucket we were occupying was empty, not because we'd found an edge, but because the economics don't close.

## Finding 2: Giwa Ecosystem Gaps Compromised the Premises

ADR-0001 assumed cheap EVM gas, available oracle infra, native USDC, and third-party RPCs. Research (`docs/research/giwa-chain-investigation.md`) showed, as of 2026-04-22:

- Pyth on Giwa is unconfirmed — no public deployment address.
- USDC is bridged-only via Dunamu custody (so there's a trust axis at the collateral layer already).
- No Alchemy / QuickNode / Infura presence — we'd have to operate our own RPC.
- Giwa mainnet missed its Q4 2025 target.
- Sequencer is operated by Dunamu (Upbit's parent). Running a public perp orderbook on chain means putting it inside a prover that also runs Korea's largest CEX's order flow.

If the chain layer already involves operator trust (Dunamu-operated sequencer, Dunamu-custodied USDC), the marginal security you gain by cramming matching on-chain is smaller than ADR-0001 assumed, and the marginal latency/gas cost is large.

## Finding 3: The 2026 Market Has Decided

Volume leaders in 2026:

- **Hyperliquid** — ~60-75% of on-chain perp share. Own BFT L1.
- **Lighter** — zk-rollup, off-chain match, STARK→SNARK proof.
- **Paradex** — StarkEx rollup.
- **edgeX / ApeX Omni** — off-chain match with proof or optimistic settle.
- **Vertex / Aevo / Drift** — off-chain match, optimistic on-chain settle.

None run matching in EVM. The "EVM-native on-chain matched perp DEX" category is empty at scale. The 1-second block time and ~200k gas per order combine to make market-maker economics unworkable at the spreads that attract volume.

## The Rebuttal to Our Own Past Self

ADR-0001 rejected off-chain matching as "a CEX in a trenchcoat." To pivot, we needed a good answer to our past self. It has three parts:

1. **ZK proof separates logic trust from operator trust.** An unproven off-chain matcher trusts the operator on what happened. A zkVM-proven matcher publishes the matching program as Rust code and proves every batch was the deterministic execution of that program over an ordered input. Operator cannot insert phantom fills, skip cancels, change prices, or selectively match. The matching-logic trust surface is the same as an on-chain contract: the code is the authority.
2. **Only ordering fairness remains as a trust axis.** The sequencer still decides input order. This is mitigated by force-inclusion via the L1-backed Router, by private mempool properties of OP Stack, by post-batch state-root commitments that make reordering observable after the fact, and by a future rotating sequencer set.
3. **"Centralized matching ≈ CEX" was wrong.** A CEX can run any logic, hide state, and censor freely. A ZK-proven off-chain matcher runs exactly one published program, makes every state transition public, and has bounded censorship latency. That is a materially different object.

Full form in ADR-0012, Section "Rebuttal of ADR-0001's anti-off-chain argument."

## What We Ended Up With

```
User (EIP-712 intent)
   │
   ├──▶ Sequencer (Rust, off-chain)
   │      ├─ matches deterministically
   │      ├─ soft-confirms in ~10-50ms
   │      └─ closes batches every few seconds
   │                        │
   │                        ▼
   │                 SP1 Prover (Rust)
   │                   re-executes the
   │                   matching program
   │                   emits SNARK proof
   │                        │
   │                        ▼
   └─────────▶ Giwa Chain: Router / Settlement.sol
                  ├─ SP1 verifier (~300k gas / batch)
                  ├─ decodes state delta
                  └─ calls Vault, PositionManager,
                     MarginEngine, FundingRate,
                     LiquidationEngine

   Escape hatch: Router.forceInclude(intent) if
   sequencer censors. Settlement must process
   force-included intents within N batches.
```

The Phase 1/2 contracts — Vault, MarginEngine, PositionManager, LiquidationEngine, OracleAdapter, FundingRate — all survive. They were written as pure accounting modules with no opinion about who calls them. The only change is `ORDERBOOK_ROLE` becomes `SETTLEMENT_ROLE`.

Deleted:
- `OrderBook.sol`, `IOrderBook.sol`
- `BitmapLib.sol`, `TickMath.sol`, `PackedOrder.sol`
- All OrderBook-touching tests (roughly 30-50 of the 131 green).

Added (in Phase 5):
- `Settlement.sol` — SP1 verifier + state delta applier.
- `Router.sol` with `forceInclude` path.
- `crates/gaekju-sequencer` — Rust matching engine, REST+WS API.
- `crates/gaekju-prover` — SP1 program and proving service.

## Why SP1 and Not RISC Zero or Plonky2

Three alternatives, three rejections:

- **Plonky2 STARK → gnark SNARK (Lighter-exact).** Lowest on-chain gas, smallest proof. Costs ~12-18 months of circuit engineering and dedicated cryptography specialists. Custom signature scheme (ECgFp5 Schnorr) that no EVM wallet speaks. Rejected on team scale.
- **RISC Zero.** Mature, production-grade. Higher prover cost than SP1 in 2026 for our workload. Less EVM-native tooling. Rejected on cost and ecosystem fit — see ADR-0013.
- **No ZK (Vertex / Aevo shape).** Cheap to run but pure operator trust. ZK is cheap enough in 2026 that skipping it is leaving security on the table.

SP1 lets us write the matcher once in Rust, run the same binary in the sequencer and inside the zkVM. Verifier is ~300k gas on any EVM. Succinct operates proving infrastructure so we don't have to run a prover farm from day one. The tradeoff is higher per-batch prover cost than a custom circuit — acceptable for our throughput assumptions.

## What We Got Wrong

A few lessons worth calling out.

- **We cited a reference we hadn't audited.** Lighter looked like an on-chain EVM CLOB from the outside. It isn't. One afternoon of investigation up front would have saved two phases of implementation.
- **"L2 gas is cheap enough" wasn't specific enough.** Cheap-ish at 1 tx per block ≠ cheap at MM-requote-frequency per block. The numbers only close for spot, not for perps at institutional spreads.
- **We underweighted ecosystem risk.** Pyth, USDC, RPC, and sequencer operator are all load-bearing assumptions. Each one has a fallback plan now; ADR-0001 had none.
- **We rejected off-chain matching on a strawman.** The rejection conflated "off-chain" with "unproven." With ZK, those are different things.

Phase 1/2 wasn't wasted. The surviving contracts are the accounting core of any perp DEX architecture. Swapping the matching layer out from under them was exactly the refactor the module boundaries were designed for.

## What's Next

Part 2 is the original bitmap CLOB post, preserved with a retraction banner. The technique is still valid for spot books; it's just no longer part of Gaekju.

Parts 3 and 4 cover margin and liquidation math — unchanged under the pivot, since those modules survive.

---

*Next: [Building a Bitmap Orderbook (retracted)](02-bitmap-orderbook.md)*

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
