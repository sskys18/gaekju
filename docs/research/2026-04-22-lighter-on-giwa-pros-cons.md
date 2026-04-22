# Lighter-style Perp CLOB on Giwa Chain — Pros & Cons

**Date:** 2026-04-22
**Inputs:** `giwa-chain-investigation.md`, `lighter-stack-investigation.md`, existing `how-lighter-works.md`, `glossary-lighter-deepdive.md`, `perp-dex-architecture-comparison.md`
**Purpose:** Honest go/no-go analysis before sinking more time into Phase 3 implementation.

---

## TL;DR

What we've been calling "Lighter-style on Giwa" is a **category error**. Lighter is not an on-chain CLOB — it's an off-chain matching engine with zk-proof settlement on its own Plonky2 rollup. Nobody at perp scale runs CLOB matching inside EVM. Our real peer is **Clober / LOBSTER** (spot, Base), not Lighter.

Giwa is a 7-month-old Dunamu testnet with no confirmed Pyth, no native USDC, no CCTP, single Dunamu sequencer, Stage-0 trust, and zero ecosystem TVL. Every infra dependency a perp needs we either self-operate or stub.

The architecture can work for a **testnet-scale flagship demo on Giwa**. It does **not** scale to real HFT perp volume without either (a) moving matching off-chain with zk-settlement (real Lighter), or (b) moving to a non-EVM perp-native L1 (Hyperliquid). Shipping as-is is fine if we're honest about what we're building.

---

## Part 1 — What the design actually is

### Lighter (real)

| Layer | Reality |
|-------|---------|
| L1 | Ethereum |
| Rollup | Own zk-rollup, Plonky2 STARK → gnark PLONK SNARK over BN254, ~230k gas verify |
| Matching | **Off-chain** Rust sequencer, ~5ms soft finality |
| Orderbook state | 80-deep Poseidon2 Merkle tree, price-time priority enforced in-circuit |
| Signatures | EdDSA/Schnorr on ECgFp5 (ZK-friendly, not EVM) |
| Cost | ~$0.19/batch, ~$0.007 amortized/user-op |
| Throughput | Marketing ~500M ops/day, L2Beat-observed ~1.8k user-ops/day |

### Gaekju (what we're building)

| Layer | Reality |
|-------|---------|
| L1 | Ethereum |
| Rollup | Giwa Chain (OP Stack optimistic, Dunamu sequencer) |
| Matching | **On-chain in EVM**, bitmap-indexed price levels |
| Orderbook state | TickBitmap (borrowed from Uniswap V3) + storage-backed queues |
| Signatures | ECDSA secp256k1 / EIP-712 |
| Cost | estimated $0.01–0.05/trade (unverified, no gas-report yet) |
| Throughput | gas-bounded: 60M gas/block ÷ ~200k/tx = ~300 TPS ceiling theoretical, much less real |

**Zero technical overlap in the matching path.** The only genuine Lighter inheritance is the *product shape* (CLOB perp with funding + isolated margin). Every gas-sensitive primitive is ours.

---

## Part 2 — Giwa Chain fitness

### Hard ecosystem gaps
- **No confirmed Pyth deployment.** ADR-0004 assumes Pyth on Giwa. Unverified — we may have to self-host a pull oracle or sign our own.
- **No native USDC / no CCTP.** ADR-0005 collateral model assumes native USDC. Reality: bridged only, with Dunamu-custody trust.
- **No third-party RPC** (Alchemy / QuickNode / Infura absent).
- **No deployed DEXs, ~0 TVL, no PBS / Flashbots infra.**
- **Fault proofs status undisclosed** → effectively Stage-0.
- **Single Dunamu sequencer**, same operator runs Upbit CEX → order-flow visibility risk for any perp book.
- **Mainnet missed Q4 2025 target**, still testnet-only as of 2026-04-22.

### OP Stack positives
- 1s block time (vs OP mainnet 2s) — flashblocks gives ~200ms preconf.
- 60M gas limit, ETH gas token, standard EVM — all tooling works.
- Post-4844 blob costs put expected tx fee ~$0.01–0.05 for 200k-gas trade. Usable.
- Private mempool sequencing removes sandwich MEV (at the cost of trust).

---

## Part 3 — Pros

### Product / strategic
1. **Flagship DEX positioning** on a Korea-backed L2 with direct Upbit relationship — distribution advantage if Dunamu promotes it.
2. **Transparency story** — every order/match/fill is an on-chain event, verifiable. Genuine differentiator vs Hyperliquid, dYdX v3, Vertex, Aevo (all off-chain match).
3. **Composability** — other Giwa contracts can margin-vault, copy-trade, auto-hedge against us natively. Lighter/Hyperliquid can't offer this.
4. **Minimum trust surface** — only the L2 sequencer. No separate matching-engine operator, no ZK prover trust, no bridge trust beyond the canonical OP Stack bridge.
5. **Single source of truth** — no off-chain/on-chain sync bugs, no proof staleness windows, no desert-mode emergency exit to design.

### Engineering
6. **Simpler than Lighter.** No ZK prover, no circuit auditing, no Poseidon2 state tree, no custom signature scheme. Standard EVM + Foundry + Pyth.
7. **Reuses mature Ethereum infra** — UUPS proxies, AccessControl, EIP-712, standard ERC-20 collateral.
8. **Testable end-to-end in Foundry.** Lighter's circuit correctness is a separate research project.
9. **Lighter mirror (ADR-0010) as liquidity bootstrap** — we copy Lighter's depth without running their circuit.
10. **Rust backend scope is narrow** — only indexer/API/keeper/mirror. No matching engine = huge scope reduction.

### Giwa-specific
11. **No MEV sandwich** because of private mempool.
12. **Cheap gas** post-4844, making per-order economics viable for market makers quoting ≥1 bps spreads.
13. **First-mover** on Giwa — no competing DEX to fight for liquidity.

---

## Part 4 — Cons

### Architectural / scaling
1. **Matching latency floored at 1s block time.** Lighter is 5ms, Hyperliquid 0.2s. We are **200× slower** than the product we name-check. Kills HFT market makers outright.
2. **Gas-bounded throughput.** Theoretical 300 TPS, realistic <100 under load. Under stress (funding events, liquidation cascades), matching queues up.
3. **Per-order gas cost is a spread floor.** ~$0.01–0.05 per place/cancel makes 1-bps quoting uneconomic for small sizes. Market makers will widen, degrading the product we're selling.
4. **Unbounded matching-loop gas** (the LOBSTER problem). A large taker crossing a deep book can run out of gas. Needs a bounded-cross cap — our Phase 3 plan has no explicit cap yet.
5. **No proof batching** → every order pays full gas. Lighter amortizes $0.007/op; we pay gross.
6. **No published EVM bitmap-CLOB gas benchmarks.** Our numbers are guesses. Need `forge test --gas-report` before any cost claim is defensible.

### Giwa ecosystem
7. **Pyth unconfirmed.** Oracle is a load-bearing dependency; we may need to deploy our own adapter or run a push-signer.
8. **USDC is bridged, not native.** Trust surface expands to Dunamu custody + bridge contract.
9. **Single centralized sequencer** run by the same entity that runs Upbit CEX. Regulatory target. Order-flow visibility risk.
10. **Stage-0 rollup, no fault proofs in production.** Full sequencer trust required.
11. **No mainnet yet.** All our work ships to a testnet. Real liquidity migration is a future problem.
12. **Korean FSC regulatory exposure** for on-chain derivatives run on Dunamu infra. Non-zero shutdown risk.
13. **No third-party infra** (RPC, indexer, explorer — all Dunamu). Operational single point of failure.
14. **Zero ecosystem TVL / no existing integrations.** Cold-start liquidity problem.

### Miscategorization risks
15. **"Lighter-style" framing is misleading.** Anyone technical reading our docs will point this out. We're Clober-style (EVM bitmap CLOB, spot-analogue on Base) with perp features on top. Clober runs spot only — there is no working perp precedent at scale for our exact construction.
16. **Novel territory = unknown failure modes.** No audit shop has reviewed an EVM bitmap-perp CLOB before.
17. **Our spec calls for a bitmap orderbook, but Lighter does not use one.** Bitmap idea is from Uniswap V3 TickBitmap. If our docs imply Lighter heritage, they're wrong (noted in `lighter-stack-investigation.md`).

### Operational
18. **Keeper infra is our problem.** Liquidation / funding / ADL bots must be reliable or the product breaks. Lighter and Hyperliquid internalize this.
19. **Order cancels cost gas.** In volatile markets, makers cancel constantly. This is a UX and cost problem.
20. **Front-running by sequencer** is possible in principle (private mempool hides it, doesn't prevent it).

---

## Part 5 — Alternatives weighed

| Option | Matching | Settlement | Verdict for us |
|--------|----------|------------|----------------|
| **Lighter-style real** (own zk-rollup) | Off-chain | zk-proof to L1 | Out of scope — 12+ months, circuit audits, prover infra |
| **Hyperliquid-style** (own L1, HyperBFT) | In-node | Native L1 | Out of scope — requires building an L1 |
| **Vertex / Aevo** (off-chain match, on-chain settle) | Off-chain | EVM settle | Better latency, loses transparency story. Realistic if we drop the "fully on-chain" pitch |
| **StarkEx / Cairo** (dYdX v3 shape) | Off-chain | STARK verify | Heavy engineering, no Giwa support |
| **Clober on Base** (EVM bitmap CLOB) | On-chain | Same chain | Spot only, exists — closest honest precedent. We extend to perps |
| **Current plan (Gaekju on Giwa)** | On-chain EVM | Same chain | Novel for perps. Works for testnet-scale demo. |

---

## Part 6 — Recommendations

### If we keep current direction
1. **Fix framing.** Rename "Lighter-style" → "on-chain EVM CLOB (Clober-lineage)". Update ADR-0001, blog #02, design spec. Keep Lighter as *liquidity mirror source* only (ADR-0010).
2. **Gas-benchmark now.** Run `forge test --gas-report` on `OrderBook.placeLimitOrder`, `cancelOrder`, and a matching loop against 1/10/50 crossed makers. Publish real numbers before claiming "$0.01–0.05/trade".
3. **Bound the matching loop.** Add explicit `maxFills` or `maxGas` cap in OrderBook matching. LOBSTER-style.
4. **Verify Giwa infra dependencies.** Confirm Pyth deployment, USDC bridge path, RPC availability. If Pyth is absent, design a fallback push-signed oracle now, not later.
5. **Write a "what we are not" doc.** Explicit about: not Lighter, not HFT-capable, testnet-scale, single-sequencer trust. Set expectations.
6. **Finish Phase 3** (Funding / MarketFactory / Router) — architecturally sound regardless of the above, and doesn't commit us further.

### If we rethink
- **Pivot to Vertex/Aevo shape** (off-chain match, on-chain settle) if HFT-caliber latency is a must-have. Large engineering cost; loses transparency narrative.
- **Pivot chain** to Base / Arbitrum / OP Mainnet if Giwa infra gaps prove blocking — same contracts port over, better ecosystem. Lose Dunamu distribution.
- **Pivot product** to spot-only first (match Clober's actual scope). Perps are much harder to operate safely on this stack.

### What NOT to do
- Do not claim Lighter heritage in public-facing material. Technical readers will call it.
- Do not ship without a gas-report. Cost claims without data are a credibility risk.
- Do not treat keeper reliability as an afterthought. Our risk engine is only as good as the bot that runs it.

---

## Open questions for the user

1. Is the goal "Dunamu flagship DEX on Giwa" (distribution play) or "best-in-class on-chain perp" (technical play)? The two have different optimal architectures.
2. Is HFT / 1bps-spread market making a target use-case? If yes, fully-on-chain EVM does not support it.
3. Do we have a Giwa / Dunamu contact to confirm Pyth, USDC, RPC roadmap? Several load-bearing assumptions in existing ADRs need direct verification.
4. How much runway before Giwa mainnet? Affects whether we stabilize on testnet or aim for mainnet-day launch.

---

## Source files
- `docs/research/giwa-chain-investigation.md` — Giwa raw findings
- `docs/research/lighter-stack-investigation.md` — Lighter raw findings
- `docs/research/how-lighter-works.md` — earlier writeup (some entries now flagged stale)
- `docs/research/glossary-lighter-deepdive.md` — earlier glossary
- `docs/research/perp-dex-architecture-comparison.md` — earlier comparison
