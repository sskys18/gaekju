# Why We're Building Gaekju

> Part 0 of "Building a Perp DEX from Scratch"

---

## The Problem

Perpetual futures are the most traded instrument in crypto — over $100B in daily volume across centralized exchanges. But on-chain perp DEXes face a fundamental tradeoff:

- **AMM-based DEXes** (GMX, Perpetual Protocol) are simple but limited: no real orderbook, slippage on large trades, and limited order types.
- **Off-chain orderbook DEXes** (Hyperliquid, dYdX) are fast but centralized: you trust the operator to match orders fairly.
- **On-chain orderbook DEXes** (Lighter.xyz) get the best of both: real orderbooks, on-chain execution, no trust assumptions beyond the chain itself. The tradeoff is latency — you're bound by block time.

With L2s bringing block times to ~2 seconds and gas to fractions of a cent, the latency tradeoff is shrinking fast.

## What Gaekju Is

Gaekju is a perpetual futures DEX on **Giwa Chain**, an OP Stack L2 testnet. It follows the **Lighter.xyz architecture**: a fully on-chain central limit orderbook (CLOB) with bitmap-based price level encoding for gas efficiency.

What makes it interesting:

1. **On-chain CLOB** — real orderbook with price-time priority matching, all in smart contracts
2. **Lighter liquidity mirror** — real market depth from Lighter.xyz's 220+ markets appears on Gaekju's testnet orderbook
3. **Multi-asset** — crypto perps, Korean stocks (Samsung, SK Hynix, KRCOMP index), US indices (SPY, QQQ), forex, and commodities
4. **Rust backend** — indexer, API, keeper bots, and SDK all in Rust
5. **Built in public** — this blog series documents every decision

## Why Giwa Chain?

Giwa is an OP Stack L2 testnet. OP Stack gives us:

- ~2 second block times (fast enough for an orderbook)
- Cheap gas (fractions of a cent per transaction)
- EVM compatibility (Solidity contracts work out of the box)
- Forced transaction inclusion via L1 (censorship resistance)
- A growing ecosystem of tooling and infra

## Why "Gaekju"?

객주 (gaekju) were merchant brokers in Joseon-era Korea who facilitated trade between buyers and sellers at marketplaces. They matched supply with demand, managed inventory, and took risk — essentially the original market makers. Fitting name for an exchange.

## What's Next

In the next post, we'll compare the major perp DEX architectures and explain why we chose Lighter's on-chain CLOB model over AMMs, off-chain engines, and hybrid approaches.

---

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
