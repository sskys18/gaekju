# Perpetual DEX Technical Architecture Comparison

> Research date: 2026-04-07
> Purpose: Inform Gaekju architectural decisions with real technical data

---

## Protocol-by-Protocol Analysis

### 1. Lighter.xyz

**Where does matching happen?**
App-specific ZK rollup. A centralized sequencer receives orders, executes matching in FIFO order against an in-memory orderbook, and produces execution traces. A separate Prover generates SNARK proofs for every match and liquidation. Hundreds of thousands of proofs are aggregated into a single batch proof posted to Ethereum L1. The matching itself is NOT in smart contracts -- it runs in the sequencer's off-chain execution environment, with ZK proofs attesting to correctness after the fact.

**User-facing latency:**
Millisecond-level soft finality from the sequencer. True settlement (L1 finality) only after proof verification on Ethereum, which is batched. Users get fast "sequencer finality" but must trust the sequencer until the proof lands on L1.

**Trust model:**
- The sequencer is a single operator (Lighter team). It controls transaction ordering.
- ZK proofs guarantee state transition correctness (matching was done right), but do NOT prevent MEV. The sequencer can front-run, reorder, or selectively delay orders while still producing valid proofs. Stanford Blockchain Review explicitly flagged this: "A sequencer could systematically delay orders from certain addresses... and users would experience poor execution without any protocol-level recourse."
- Forced exit mechanism: if the sequencer censors for >14 days, the rollup freezes and users can exit via L1 Merkle proof against the frozen state root.
- Desert mode (escape hatch) circuit source code was NOT publicly available as of Jan 2026.
- No delay on code upgrades (L2Beat: CRITICAL).
- SNARKs require trusted setup.

**Settlement model:**
Batch proofs + state roots posted to Ethereum L1 with EIP-4844 data blobs. All data needed to reconstruct state is on-chain. This is a genuine ZK rollup with on-chain DA.

**Gas costs per order:**
Zero trading fees for users (no maker/taker fees). Users only pay Ethereum gas for L1 deposits/withdrawals. The sequencer absorbs proof generation and L1 posting costs, amortized across massive batches. This is a subsidy/growth model -- sustainable economics TBD.

**L2Beat stage:** Not formally classified as Stage 1 or 2. Multiple CRITICAL flags (no upgrade delay, unverifiable escape hatch code). Experienced 4.5 hours of downtime from database growth issues.

---

### 2. Hyperliquid

**Where does matching happen?**
Custom L1 blockchain (not an L2). HyperBFT consensus (modified HotStuff BFT). The matching engine ("HyperCore") is baked directly into the L1 node software. Orders are matched deterministically using price-time priority as part of block production. Every validator runs the same matching engine.

**User-facing latency:**
Median ~0.2s, 99th percentile <0.5s. Sub-second finality. No gas fees for placing/canceling orders.

**Trust model:**
This is the critical weakness. Despite the "L1" framing:
- As of early 2026, the Hyper Foundation operates 5 validators holding >50% of staked HYPE. With 2/3 consensus threshold, the Foundation + 1-2 allies = supermajority.
- 81% of staked shares controlled by foundation nodes.
- Validator software is closed-source with no documentation. External validators face frequent jailing and instability.
- The bridge to Arbitrum is managed by only 4 validators (separate from mainnet consensus). L2Beat rates bridge validation as "bad" -- funds can be stolen if the permissioned validator majority signs an invalid withdrawal.
- No economic penalty (slashing) for double signing or malicious state transitions.
- L2Beat equivalent: Stage 0 ("training wheels"). Effectively centralized.
- North Korean actors targeted validator nodes in 2024, exploiting known vulnerabilities. Attack was mitigated but demonstrated the fragility.
- At one point, 67% of all USDC on Arbitrum was parked in Hyperliquid's bridge -- enormous honeypot with minimal security.

**Settlement model:**
Finality is on the Hyperliquid L1 itself. Bridge to Ethereum/Arbitrum is a multisig-style validator bridge, NOT a rollup. No L1 proof verification. You trust the validator set.

**Gas costs per order:**
Zero. No gas for trading. One-time account activation fee.

---

### 3. dYdX v4

**Where does matching happen?**
Cosmos app-chain (sovereign L1). Every validator runs an in-memory orderbook as part of the node software. The orderbook is OFF-CHAIN (not committed to consensus state). The block proposer matches orders and includes the resulting trades in the block. Other validators verify the matches are correct during consensus.

This is a clever hybrid: the orderbook lives in RAM on every validator, gossipped via P2P, but only settled trades hit the on-chain state.

**User-facing latency:**
~1 second block times. Order placement is near-instant (gossipped to validators), but trade confirmation waits for block inclusion.

**Trust model:**
- 60 validators with delegated PoS. Significantly more decentralized than Hyperliquid.
- The block proposer CAN front-run -- they see all pending orders and choose block contents. This is acknowledged by the team.
- MEV mitigation: Skip protocol's orderbook discrepancy dashboard monitors validators. Social slashing via governance (MsgSlashValidator) can punish MEV-extracting validators.
- Open-source validator software (unlike Hyperliquid).
- No rollup security -- this is a sovereign chain. Security = staked DYDX value.

**Settlement model:**
Finality on the dYdX Chain (Cosmos fast finality via CometBFT). Bridge to Ethereum is IBC-based. No L1 proof verification.

**Gas costs per order:**
Minimal. Cosmos chains have low fees. Order placement/cancellation doesn't hit on-chain state, so effectively free. Trades settle on-chain with standard Cosmos gas.

---

### 4. Vertex

**Where does matching happen?**
Off-chain sequencer run by the Vertex team. Orders are matched off-chain with 5-15ms latency, then settled on Arbitrum smart contracts.

**User-facing latency:**
5-15ms for order matching (sequencer confirmation). On-chain settlement follows asynchronously on Arbitrum.

**Trust model:**
- Single centralized sequencer (Vertex team). Can reorder, front-run, censor.
- On-chain clearinghouse handles settlement, collateral, and liquidations -- so the sequencer cannot steal funds directly.
- "Slo-Mo Mode" fallback: if the sequencer goes down, the protocol falls back to on-chain AMM only. Trading continues but without the orderbook.
- No ZK proofs or fraud proofs for sequencer behavior.

**Settlement model:**
Arbitrum L2 smart contracts. Inherits Arbitrum's security model (optimistic rollup on Ethereum).

**Gas costs per order:**
Arbitrum gas for settlement (~$0.01-0.10 per tx). Off-chain matching is free. Users pay gas for on-chain settlement.

**Note:** Vertex announced migration under Ink Foundation and multi-phase shutdown of DEX operations starting July 2025.

---

### 5. GMX v2

**Where does matching happen?**
There is NO orderbook. GMX is pool-based (oracle-priced). Traders trade against GM liquidity pools at Chainlink Data Stream oracle prices. No matching engine exists -- every trade is against the pool.

**User-facing latency:**
Arbitrum block time (~0.25s). Two-step execution: user submits order, then a keeper executes it in the next block. Total ~1-2 seconds.

**Trust model:**
- No sequencer trust issue (no orderbook).
- Oracle trust: relies on Chainlink Data Streams. If the oracle is wrong, liquidations and trades execute at wrong prices.
- Keeper network (Gelato) executes orders. Keepers can't front-run because price is oracle-determined.
- Smart contracts are the entire execution layer -- fully on-chain, auditable.
- Gasless trading added in 2025 via gas abstraction (keepers pay gas, recouped from fees).

**Settlement model:**
Arbitrum (optimistic rollup on Ethereum). All logic is in smart contracts.

**Gas costs per order:**
~$0.10-0.20 on Arbitrum per execution. With gas abstraction (2025), users don't pay gas directly -- it's embedded in trading fees.

---

### 6. Drift

**Where does matching happen?**
Hybrid model on Solana:
1. Orders are stored ON-CHAIN in Solana accounts
2. The DLOB (Decentralized Limit Order Book) is an OFF-CHAIN aggregation of on-chain orders, maintained by Keeper bots
3. Keepers match orders by submitting fill transactions on-chain
4. A vAMM provides backstop liquidity
5. JIT (Just-in-Time) auctions let market makers compete to fill large orders

So: order storage is on-chain, order matching is off-chain (keepers), settlement is on-chain.

**User-facing latency:**
Solana block time (~400ms). JIT auction adds a brief window. Total ~1-2 seconds for market orders.

**Trust model:**
- Keeper network is permissionless -- anyone can run a keeper.
- If all keepers go down, orders remain valid on-chain but won't be matched until keepers return.
- The DLOB is read-only and doesn't modify on-chain state. It's a convenience layer.
- vAMM guarantees baseline liquidity even without keepers.
- Relatively decentralized compared to sequencer models.

**Settlement model:**
Solana L1. No rollup. Security = Solana validator set.

**Gas costs per order:**
Solana transaction fees: ~$0.001-0.01. Negligible. Some protocols subsidize this entirely.

---

### 7. Aevo

**Where does matching happen?**
Off-chain orderbook with on-chain settlement on Aevo L2 (OP Stack rollup). Matching is centralized, similar to Vertex.

**User-facing latency:**
Sub-second matching. Claims >5,000 TPS.

**Trust model (per L2Beat):**
Multiple CRITICAL flags:
- Uses EigenDA for data availability, but the DACert Verifier is not used. The sequencer can publish unavailable commitments. "Funds can be lost if the sequencer posts an unavailable transaction root."
- Fault proof system is deployed but NOT FUNCTIONAL. The chain ID is not in the op-program superchain registry, causing the dispute game to panic during execution.
- Security relies ENTIRELY on the permissioned proposer and challengers.
- Users can bypass censorship by submitting directly to L1 smart contracts.
- Effectively: a centralized exchange with an L1 escape hatch that may or may not work.

**Settlement model:**
OP Stack optimistic rollup, theoretically settling to Ethereum. But with non-functional fault proofs, it's trust-based.

**Gas costs per order:**
Off-chain matching is free. Settlement costs are L2 gas (minimal).

---

## The Big Question: Has Anyone Done Fully On-Chain CLOB Matching on EVM?

### Short answer: Sort of, but not at scale, and not for perps.

**Clober** (clober.io) built a fully on-chain orderbook for EVM spot trading. It exists and works, but operates on low-volume pairs. The gas cost of on-chain matching (insertions, deletions, traversals of price levels) makes it uncompetitive for high-frequency trading on Ethereum mainnet.

**Serum** (Solana, now OpenBook) was the canonical "on-chain CLOB" -- but Solana's architecture (parallel execution, cheap compute) makes this feasible in ways EVM cannot replicate. And even Serum relied on cranking (off-chain bots to trigger matching).

**Econia** (Aptos) leveraged Move's parallelism for on-chain matching. Similar to Serum's approach -- possible because of the chain's native parallelism, not because of clever EVM tricks.

**On EVM specifically:** Nobody has built a production-scale perpetual futures CLOB with on-chain matching on a general-purpose EVM chain. The reasons are fundamental:

1. **Storage costs:** Each order insertion/cancellation/update is an SSTORE (~20,000 gas for new slots, ~5,000 for updates). A single limit order placement with matching could easily cost 200,000-500,000 gas.
2. **Matching complexity:** Traversing price levels to fill a market order is O(n) in the worst case. Each price level hit is additional storage reads.
3. **Bitmap optimization** (what Lighter's old on-chain version and Gaekju use) reduces this significantly by packing price levels into bitmaps, but it still costs 50,000-150,000 gas per order on an L2.
4. **Block time bottleneck:** EVM block times (even on L2s: 2s on OP Stack, 0.25s on Arbitrum) are too slow for competitive market making.

### What "fully on-chain" actually means in practice:

| Protocol | Matching | Orderbook State | Settlement | Proofs |
|----------|----------|----------------|------------|--------|
| Lighter | Off-chain sequencer | Off-chain | L1 (ZK proof) | ZK-SNARK |
| Hyperliquid | In consensus (L1 nodes) | In-memory per validator | L1 (own chain) | None |
| dYdX v4 | In-memory per validator | In-memory (off consensus) | On-chain (Cosmos) | None |
| Vertex | Off-chain sequencer | Off-chain | L2 (Arbitrum) | None |
| GMX v2 | No orderbook (pool) | N/A | L2 (Arbitrum) | None |
| Drift | Off-chain keepers | On-chain (Solana) | On-chain (Solana) | None |
| Aevo | Off-chain sequencer | Off-chain | L2 (OP Stack) | None (broken fraud proofs) |
| **Gaekju** | **On-chain (EVM)** | **On-chain (bitmap CLOB)** | **L2 (OP Stack)** | **None** |

### The honest assessment for Gaekju:

Gaekju's "fully on-chain CLOB" approach is genuinely rare. Almost nobody does this because:
- It's expensive (gas per order on OP Stack L2 will be ~50,000-200,000 gas depending on matching depth)
- It's slow (2s block times on OP Stack vs millisecond sequencer matching)
- Market makers won't quote tight spreads with 2s execution risk

The tradeoff Gaekju gets in return:
- **Maximum transparency:** Every order, match, and cancel is verifiable on-chain
- **No sequencer trust:** The OP Stack sequencer orders transactions but cannot fake matches (EVM execution is deterministic)
- **Censorship resistance:** Inherited from the L2's forced inclusion mechanism
- **Simplicity:** No ZK circuits, no custom consensus, no off-chain components to maintain

This is a legitimate architectural choice for a testnet/educational project or low-frequency markets (RWA perps, less liquid pairs). It is NOT competitive with Hyperliquid/Lighter for BTC/ETH perp trading where latency and throughput matter.

---

## Trust Model Summary (Ranked by Decentralization)

| Protocol | Can operator front-run? | Can operator censor? | Can operator steal funds? | Escape hatch? |
|----------|------------------------|---------------------|--------------------------|---------------|
| GMX v2 | No (oracle-priced) | No (on-chain) | No | Full on-chain |
| Drift | Keepers compete (limited) | Temporarily (keepers down) | No | On-chain orders persist |
| dYdX v4 | Yes (block proposer) | Yes (proposer) | No (consensus required) | Sovereign chain |
| Lighter | Yes (sequencer) | Yes (sequencer) | No (ZK proofs + L1 exit) | 14-day freeze + L1 exit |
| Gaekju | Limited (L2 sequencer) | Limited (L2 sequencer) | No (on-chain matching) | OP Stack forced inclusion |
| Vertex | Yes (sequencer) | Yes (sequencer) | No (on-chain settlement) | Slo-Mo AMM fallback |
| Aevo | Yes (sequencer) | Yes (sequencer) | Possibly (broken fault proofs) | Theoretically via L1 |
| Hyperliquid | Yes (validators) | Yes (validators) | Yes (bridge multisig) | No real escape hatch |

---

## Key Takeaway for Gaekju

The perp DEX landscape has converged on a common pattern: **off-chain matching with on-chain settlement**. Everyone does this because it's the only way to get competitive latency. The differentiation is in the trust model:

- **ZK proofs** (Lighter): Prove matching was correct, but don't prevent MEV
- **Consensus matching** (Hyperliquid, dYdX): Multiple parties agree on matches, but validators can still extract MEV
- **Pool-based** (GMX): Eliminate matching entirely, but constrain the product to oracle-priced trades

Gaekju's on-chain CLOB is architecturally honest -- what you see is what you get. The sequencer can reorder transactions (standard L2 risk) but cannot fabricate matches. For a testnet demonstrating how a perp DEX works end-to-end, this is the right call. For competing on mainnet with Hyperliquid's 200ms fills, it would need to evolve toward a sequencer-assisted model.

---

## Sources

- [Stanford Blockchain Review: Shedding the Light(er): Fine Prints of ZK](https://review.stanfordblockchain.xyz/p/77-shedding-the-lighter-the-fine)
- [Lighter Docs: Technical Architecture](https://docs.lighter.xyz/about-lighter/technical-architecture-lighter-core)
- [Lighter Whitepaper](https://assets.lighter.xyz/whitepaper.pdf)
- [ZK Security: Public Report of Lighter ZK Circuits](https://blog.zksecurity.xyz/posts/lighter-xyz/)
- [Lighter L2Beat Page](https://l2beat.com/scaling/projects/lighter)
- [Hyperliquid Docs](https://hyperliquid.gitbook.io/hyperliquid-docs)
- [Hyperliquid Wiki: HyperBFT](https://hyperliquid-co.gitbook.io/wiki/architecture/hyperbft)
- [ChainArgos: Centralized Control in Hyperliquid](https://medium.com/chainargos/centralized-control-in-hyperliquid-3e9f7dd0d706)
- [Mefai: Hyperliquid Critical Infrastructure Risk Assessment (Feb 2026)](https://mefai.medium.com/hyperliquid-hype-critical-infrastructure-risk-assessment-subtitle-independent-technical-report-4ce3516f3df7)
- [dYdX: v4 Technical Architecture Overview](https://www.dydx.xyz/blog/v4-technical-architecture-overview)
- [dYdX: Architecture to Mitigate MEV](https://www.dydx.xyz/blog/architecture-to-mitigate-mev)
- [dYdX Docs: Architecture Overview](https://docs.dydx.xyz/concepts/architecture/overview)
- [Vertex Docs: Technical Architecture](https://docs.vertexprotocol.com/basics/technical-architecture)
- [GMX Docs](https://docs.gmx.io/docs/intro/)
- [Arbitrum Blog: GMX In-Depth Look](https://blog.arbitrum.io/gmx-an-in-depth-look-at-arbitrums-leading-permissionless-exchange-for-on-chain-leverage-trading/)
- [Drift Docs: Orderbook and Matching](https://docs.drift.trade/developers/market-makers/orderbook-and-matching)
- [Inside Drift: Architecting a High-Performance Orderbook on Solana](https://extremelysunnyyk.medium.com/inside-drift-architecting-a-high-performance-orderbook-on-solana-612a98b8ac17)
- [Aevo L2Beat Page](https://l2beat.com/scaling/projects/aevo)
- [Clober: Fully On-chain Order Book](https://www.clober.io/)
- [Conduit: Onchain Order Books Guide](https://www.conduit.xyz/blog/onchain-order-books-guide/)
- [Technical Architecture Comparison: Hyperliquid, dYdX, and Lighter.xyz](https://medium.com/@gwrx2005/technical-architecture-comparison-hyperliquid-dydx-and-lighter-xyz-2fd005854a7e)
