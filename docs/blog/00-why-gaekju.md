# Why We're Building Gaekju

> Part 0 of "Building a Perp DEX from Scratch"

---

## The Problem

Perpetual futures are the most traded instrument in crypto. In 2026, daily volume across centralized and decentralized venues routinely clears $150B. The on-chain share has grown, but the "where does matching actually happen" question has split the landscape into three camps:

- **Own L1**: Hyperliquid runs its own BFT chain with sub-100ms matching. Best latency, but you're buying into a bespoke consensus layer and the associated trust and integration cost.
- **Own zk-rollup**: Lighter.xyz runs a Rust sequencer off-chain and settles via Plonky2 STARK → gnark SNARK on Ethereum L1. Deep books, CEX-adjacent UX, matching provably correct but operationally closed-source.
- **Generic L2 + off-chain match (no proof)**: Vertex, Aevo, Drift batch orders off-chain and settle on an L2, trusting the operator on execution.

All three ship volume. What none of them do — despite a common misconception — is run matching inside EVM at scale. The in-EVM CLOB bucket is empty for a reason: ~1-2s block time and ~200k gas per order put the economics underwater for market makers quoting tight spreads.

When we started Gaekju we thought we'd be the exception. We were wrong, and this series documents that. What follows is the thesis we landed on after doing the research.

## What Gaekju Is (now)

Gaekju is a perpetual futures DEX on **Giwa Chain**, an OP Stack L2. Matching runs **off-chain in a Rust sequencer**. Correctness is **proven by an SP1 zkVM**. Settlement is **on-chain on Giwa**, where a `Settlement.sol` contract verifies the SP1 proof and applies the resulting state delta to the existing Vault / MarginEngine / PositionManager / FundingRate / LiquidationEngine contracts.

The slogan: **the sequencer gives you CEX-speed matching, the proof gives you CLOB-grade trust, and Giwa gives you cheap EVM settlement.**

Concretely:

1. User signs an EIP-712 intent (place/cancel/modify) and posts it to the sequencer.
2. Sequencer accepts, matches deterministically against its in-memory book, returns a soft-confirm in ~10-50ms.
3. Batches of intents close every few seconds. A Rust matching program — the same code the sequencer ran — is re-executed inside the SP1 zkVM. SP1 emits a SNARK proof.
4. Giwa's `Settlement.sol` verifies the proof (~300k gas, shared across N intents in the batch), decodes the state delta, and calls into Vault / PositionManager / MarginEngine / FundingRate / LiquidationEngine to apply it.
5. If the sequencer censors a user, the user calls `Router.forceInclude(intent)` on Giwa directly. Settlement is obligated to process force-included intents within N batches or the sequencer is in default.

What this buys:

- **Matching latency**: 10-50ms soft-confirm, down from the 1s block time of the on-chain design we started with.
- **Throughput**: sequencer is gas-free for matching, so 10k+ orders/sec is plausible. Only batch settlement consumes Giwa gas.
- **Trust surface**: matching *logic* is a Rust program — anyone can read it, SP1 proves it ran. Operator can't insert phantom fills, change prices, or selectively match. Only remaining trust axis is ordering of the input stream, mitigated by force-inclusion.
- **Portability**: SP1 verifier is ~300k gas on any EVM. If Giwa falters, Settlement moves to Ethereum L1 or any OP Stack chain with no circuit rewrite.

## Why Giwa Chain?

Giwa is an OP Stack L2 operated by Dunamu (Upbit's parent). We picked it for three reasons and accepted three caveats.

Reasons:
- Cheap EVM settlement — batch verification amortizes to pennies per user action.
- EVM compatibility — Vault/Margin/Position contracts are plain Solidity; every EVM wallet works.
- L1 canonical bridge gives a native escape hatch independent of the sequencer.

Caveats the research surfaced (see ADR-0012):
- Pyth deployment on Giwa is unconfirmed — we design Oracle as a swappable adapter.
- USDC is bridged-only (Dunamu custody trust). Documented in ADR-0005.
- No third-party RPC yet — we ship our own indexer.

These caveats pushed us harder toward the ZK design, because if you're going to trust one operator at the chain layer you want the application layer to be maximally transparent.

## Why not just build it on-chain in the EVM?

Because we tried. Phase 1 and Phase 2 shipped a working bitmap-based CLOB in Solidity with 131 green tests. The code was clean. The math was right. The gas wasn't.

What killed the on-chain design:

1. **Lighter.xyz — our original reference — does not run on EVM.** We learned this the expensive way while reverse-engineering Lighter's stack. Lighter is a dedicated zk-rollup with Rust matching and SNARK settlement. Nothing we could port.
2. **The closest honest precedent (Clober on Base) is spot-only.** Extending EVM bitmap CLOB to perpetuals — with funding, liquidation, mark-price mixing, and ADL — has no production example.
3. **Gas math for MMs at tight spreads.** At ~200k gas per order and 1s blocks, a market maker quoting sub-5bps spreads on BTC-USD loses money on every requote before a fill.
4. **The 2026 market has decided.** Every scaled perp DEX uses own-L1, zk-rollup, or off-chain-with-optimistic-settle. Empty buckets are usually empty for a reason.

So we pivoted. ADR-0012 has the full story. The TL;DR is that Phase 1/2's Vault, MarginEngine, PositionManager, LiquidationEngine, OracleAdapter, and FundingRate all **survive** — they were written as pure accounting modules, oblivious to who called them. The only caller changes from `OrderBook.sol` to `Settlement.sol`. The bitmap orderbook (`BitmapLib`, `TickMath`, `PackedOrder`, `OrderBook.sol`) gets deleted.

## What makes Gaekju different from Lighter, then?

Three things.

First, **we run on a public OP Stack L2, not our own rollup**. That means wallets, bridges, explorers, and indexers work the day Giwa ships. No custom signature scheme (Lighter uses ECgFp5 Schnorr which no EVM wallet speaks). No custom Merkle tree (Lighter uses Poseidon2 over ECgFp5). EIP-712 end to end.

Second, **we use SP1 zkVM instead of a hand-rolled Plonky2 circuit**. Lighter's circuits are a 12-18 month engineering effort requiring cryptography specialists. SP1 lets us write the matcher in plain Rust and prove it — we trade some prover cost for an order-of-magnitude reduction in engineering surface. ADR-0013 has the comparison.

Third, **we're transparent**. The matching program is open source. The research that pushed us to pivot is in `docs/research/`. The ADRs — including the one that admits the original design was wrong — are checked in. This blog series logs every decision.

## Why "Gaekju"?

객주 (gaekju) were merchant brokers in Joseon-era Korea who facilitated trade at marketplaces. They matched supply with demand, managed inventory, and took risk — essentially the original market makers. Fitting name for an exchange.

## What's Next

Part 1 covers the architecture journey — what we built first, why it didn't hold up to research, and how the zkVM-matcher design fell out. It's a long post and honest about what we got wrong.

Part 2 is preserved as a retraction: the original bitmap CLOB writeup. The technique is still valid for spot books on EVM (cf. Clober on Base) but it's no longer Gaekju.

---

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
