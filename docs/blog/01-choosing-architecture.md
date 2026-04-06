# Choosing a Perp DEX Architecture

> Part 1 of "Building a Perp DEX from Scratch"

---

## The Four Models

Every perp DEX on the market falls into one of four architectural models. Each makes different tradeoffs between speed, decentralization, and complexity.

### Model 1: vAMM / Pool-Based (GMX, Perpetual Protocol)

Traders trade against a liquidity pool. No orderbook. Price comes from an oracle or a virtual AMM curve.

```
Trader → Pool Contract → Position opens
         (no matching needed)
```

**Pros:** Simple. Fully on-chain. Always liquid (pool is always the counterparty).
**Cons:** No limit orders. Slippage scales with size. LPs take directional risk. Limited price discovery.

### Model 2: Off-Chain CLOB (Hyperliquid, dYdX v4, Aevo)

A centralized matching engine runs off-chain. Settlement happens on-chain (or on a custom chain).

```
Trader → API → Off-chain Engine → Match → Settle on chain
```

**Pros:** CEX-like speed (sub-millisecond matching). Deep orderbooks. All order types.
**Cons:** Trust the operator. Single point of failure. Matching is a black box.

### Model 3: Hybrid CLOB (Vertex, Drift)

Orders submitted off-chain, batched and settled on-chain. Middle ground.

```
Trader → Sequencer → Batch → On-chain match
```

**Pros:** Faster than pure on-chain. More decentralized than pure off-chain.
**Cons:** Still trust the sequencer. Complex architecture. Neither fish nor fowl.

### Model 4: On-Chain CLOB (Lighter.xyz) ← We chose this

The entire orderbook lives in smart contracts. Matching happens in the EVM.

```
Trader → Smart Contract → Match in EVM → Position opens
```

**Pros:** Fully trustless. Verifiable matching. No off-chain infra for the core engine.
**Cons:** Limited by block time (~2s). Gas costs per order. Contract size limits.

## Why We Chose Lighter's Model

The key insight: **L2 gas is cheap enough that the "cons" of on-chain orderbooks don't matter anymore.**

On Giwa Chain (OP Stack L2):
- Gas per order: ~200-400k gas = ~$0.01-0.05
- Block time: ~2 seconds
- No mempool (sequencer orders transactions directly)

The 2-second matching latency is the real tradeoff. But for a testnet DEX that mirrors real exchange depth, it's acceptable. Users get fills at real market prices — they just wait 2 seconds instead of 2 milliseconds.

And in exchange, we get something no off-chain engine can offer: **every match is verifiable on-chain.** No trust in an operator. No black box.

## The Bitmap Trick

The reason on-chain CLOBs were impractical before Lighter is gas. A naive orderbook implementation in Solidity is prohibitively expensive — iterating through a linked list to find the best price costs O(n) gas.

Lighter solved this with **bitmap-based price levels**. Each bit in a 256-bit word represents whether orders exist at a given price tick. Finding the best bid/ask is a single `findFirstSet` or `findLastSet` operation — O(1) in practice.

We'll deep-dive into the bitmap orderbook implementation in the next post.

## Decision Record

See [ADR-0001: Use Lighter-style On-Chain CLOB](../adr/0001-use-lighter-clob.md) for the full decision record.

---

*Next: [Building a Bitmap Orderbook](02-bitmap-orderbook.md)*

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
