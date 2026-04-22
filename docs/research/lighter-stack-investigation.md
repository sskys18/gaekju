# Lighter Stack Investigation — Verifying Our Assumptions

> Purpose: Cross-check what `docs/research/how-lighter-works.md` and
> `glossary-lighter-deepdive.md` say against current (April 2026) public
> sources, and evaluate what of Lighter's design actually ports to a
> generic OP Stack L2 like Giwa Chain.

---

## 1. What Lighter is (verified)

- Lighter is **not** an OP Stack L2 and is **not** a zkSync derivative.
  It is an **application-specific zk-rollup** ("zkLighter") settling to
  Ethereum L1. The prover stack is custom, built on **Plonky2** (Polygon's
  Goldilocks-field STARK system), wrapped in a **gnark PLONK SNARK** over
  BN254 for EVM verification.
- Matching happens **off-chain in a centralized sequencer** (~5 ms soft
  finality). There is no EVM contract executing matching. The L1
  contracts do: `commitBatch` (post state root + EIP-4844 blob diffs),
  `verifyBatch` (call SNARK verifier, ~230k gas), `executeBatches`
  (process withdrawals). Full cycle ≈ $0.19.
- Price–time priority is **cryptographically enforced within a batch**:
  priority is encoded directly in Merkle leaf indices (32-bit price +
  48-bit nonce) of an 80-deep orderbook tree. The circuit proves the
  traversal picked the best-price, oldest maker.
- Ordering across the stream is **not** proven fair — the sequencer still
  chooses which txs to include and in what order. ZK proves "given this
  ordering, execution is correct," nothing more.

Sources: L2Beat ZK Catalog – LighterProver; Stanford Blockchain Review
#77; docs.lighter.xyz; elliottech/lighter-prover README.

## 2. Is matching inside an EVM contract?

**No.** Matching runs in a Rust sequencer, off-chain. The EVM verifier
contract `ZkLighterVerifier` only checks a PLONK proof over BN254 via the
`ecPairing` precompile. State is represented by a **hypertree of 6 Merkle
trees** (Poseidon2 over Goldilocks) — not EVM storage slots. You cannot
port this to a pure-EVM chain without giving up ZK verification.

## 3. Signature scheme

- **L1 auth** (deposits, key binding): standard **ECDSA secp256k1**.
- **L2 tx signing**: **EdDSA/Schnorr over ECgFp5** — a Plonky2-native curve
  on a quintic extension of Goldilocks. Chosen because verifying
  secp256k1 ECDSA in-circuit is ~10–100× more expensive than ECgFp5.
- This is a **Lighter-specific choice**, driven entirely by circuit cost.
  On EVM (no circuit), there is no benefit — use plain secp256k1 ECDSA or
  EIP-712 typed data.

## 4. Bitmap orderbook — ours, not Lighter's

- **Lighter does not use a bitmap.** It uses a deep Merkle tree whose
  leaf indices encode (price, nonce) price-time priority. That's a
  completely different data structure.
- The bitmap-at-tick idea comes from **Uniswap V3's `TickBitmap`**
  (`Uniswap/v3-core/contracts/libraries/TickBitmap.sol`), which packs
  "is-this-tick-initialized" flags into uint256 words so the next active
  tick can be found with a single SLOAD + bit scan.
- **Clober / LOBSTER** (on Base, Monad) is the closest published pure-EVM
  CLOB using tick-based storage; it uses a **segment tree** rather than a
  flat bitmap, specifically to keep taker-match cost sublinear. Their
  writeup explicitly calls out that naive iteration gives unbounded gas
  per taker — the same risk we have.
- So our "bitmap orderbook" is a Gaekju design, inspired by V3 tick
  bitmaps, not copied from Lighter. Our `how-lighter-works.md` Appendix A
  table already implies this (Lighter row says "Merkle tree", Gaekju row
  says "Bitmap") — correct.

## 5. Throughput / latency numbers (verified, lightly revised)

- Hyperliquid (for comparison): **~200k orders/sec, ~0.2 s finality** on
  HyperCore (own L1 with HyperBFT consensus, not an L2). Source:
  zealynx.io, cleansky.io architecture writeups.
- Lighter: sequencer ~5 ms soft, 140–300 ms user-visible (tier-gated),
  L1 settlement every 2–5 min. Marketing claim ~500 M ops/day, L2Beat
  observes ~1.8k user ops/day on mainnet.
- dYdX v3: off-chain matching, **StarkEx + Cairo + STARK prover**,
  validity-rollup mode on Ethereum. Not OP Stack, not EVM matching.
- dYdX v4: moved off Ethereum entirely to a **sovereign Cosmos-SDK L1**
  with in-protocol orderbook.
- Vertex: Arbitrum, **off-chain sequencer, on-chain settlement + AMM
  fallback**. ~15k TPS sequencer, 10–30 ms latency. Pure-EVM fallback
  means orders can always bypass the sequencer.
- Aevo: **OP Stack L2 + Celestia DA**, **off-chain orderbook, on-chain
  settlement only**. Same hybrid shape as Vertex. ~5k TPS claim.

## 6. What breaks when you try to run Lighter's loop on plain EVM

- **No Goldilocks field, no ECgFp5, no Poseidon2 precompile.** Doing any
  of the inner-proof primitives in Solidity is prohibitive. EVM only has
  BN254 precompiles (0x06/0x07/0x08) and BLS12-381 (post-EIP-2537).
- **No Merkle-tree state as first-class.** EVM storage is a flat 2^256
  map. You can simulate a Poseidon Merkle tree, but each update is dozens
  of SLOADs/SSTOREs. Lighter's 80-deep orderbook tree would cost
  multiple hundreds of k gas per leaf update — not competitive with a
  V3-style bitmap (one SLOAD + one SSTORE per tick flip).
- **Matching-loop gas is unbounded.** Without an off-chain sequencer,
  a single taker crossing many resting makers pays O(n) SSTOREs. This is
  exactly LOBSTER's motivating problem. Our bitmap + linked-list at tick
  approach needs the same bounded-crossing guarantee (cap fills per tx,
  or segment-tree-style aggregate state).
- **No sub-second finality.** Giwa/OP Stack block time is ~2 s, and the
  sequencer is single-operator upstream. You cannot replicate Lighter's
  ~5 ms soft finality under an OP Stack sequencer.
- **No batched proof amortization.** Every match pays its full gas cost,
  every block. Lighter's ~$0.007/op is only achievable because 28+ ops
  share one SNARK verification.

## 7. Alternative EVM/OP-Stack CLOBs — summary

| DEX | Matching | Settlement | Chain | Notes |
|-----|----------|-----------|-------|-------|
| **Lighter** | Off-chain Rust sequencer | ZK proof on Ethereum | Own zk-rollup | Not EVM; Plonky2+gnark |
| **dYdX v3** | Off-chain | StarkEx STARK on Ethereum | StarkEx validium | Cairo, not EVM |
| **dYdX v4** | In-protocol orderbook in every validator's mempool | Native | Own Cosmos L1 | Not EVM |
| **Vertex** | Off-chain sequencer + on-chain AMM fallback | On-chain (Solidity) | Arbitrum | Hybrid; on-chain is AMM, not CLOB matching |
| **Aevo** | Off-chain orderbook | On-chain settlement | Own OP Stack L2 + Celestia | Matching is not on-chain |
| **Hyperliquid** | On-chain CLOB in consensus | Native | Own L1 (HyperBFT) | Rust VM, not EVM matching |
| **Clober (LOBSTER)** | **Fully on-chain** | On-chain | Base / EVM | Segment tree; closest pure-EVM CLOB |
| **Gaekju (us)** | **Fully on-chain EVM** | On-chain | Giwa (OP Stack) | Bitmap + tick linked lists |

Takeaway: **nobody successful at scale runs CLOB matching inside EVM
contracts.** Every production perp DEX either (a) has its own non-EVM
execution (Hyperliquid, dYdX v4, Lighter, StarkEx), or (b) matches
off-chain and only settles on EVM (Vertex, Aevo). The only pure-EVM CLOBs
live on cheap L2s (Clober on Base) and have not proven out at perp
volumes.

## 8. Published gas benchmarks for a bitmap CLOB on EVM

- **No rigorous public benchmark** for a bitmap perp orderbook on EVM
  exists in our searches. Clober/LOBSTER's blog discusses the shape of
  the problem (unbounded taker gas) but does not publish per-op gas
  numbers in the results we retrieved.
- Uniswap V3 `TickBitmap` operations are ~2–5k gas for a flip + next-tick
  scan within a word; cross-word scans add SLOADs. Applied to an
  orderbook, every level-activation/deactivation is at least one SSTORE
  (~22k gas cold, ~5k warm). Each resting order is at minimum one
  SSTORE. A taker crossing N makers pays ≥ N × (5–20k) gas just for the
  SSTOREs, before any fixed-point math.
- Rough envelope for Gaekju: place = ~80–150k gas, cancel = ~40–80k,
  match-per-crossed-maker = ~30–60k. These need to be measured in
  `forge test --gas-report` once Phase 3 matching lands; treat as
  assumption until then.

## 9. Where our existing docs need fixes / flags

1. `how-lighter-works.md` Appendix A is correct that Lighter uses a
   Merkle tree and Gaekju uses a bitmap — **no change needed**.
2. Claim "Gaekju gas per trade: $0.01–0.05" (Appendix A) is a guess. Flag
   as speculative until gas reports exist.
3. Glossary entry "EdDSA on ECgFp5" is correct. Flag for readers: this
   does **not** apply to Gaekju — we should use plain ECDSA/EIP-712.
4. Throughput claim "500M orders+cancellations/day" is Lighter marketing;
   L2Beat observes ~1.8k user ops/day. Flag the gap.
5. Nothing in current docs says Lighter is zkSync-derivative — good. The
   user's question implied that may be a common misconception; confirm
   it's not in our notes.
6. `glossary-lighter-deepdive.md` "OP Stack" entry is slightly off: OP
   Stack currently has **no fraud proof system in production** on most
   chains (Optimism enabled permissioned fault proofs 2024, Base not yet
   permissionless as of 2026-Q1). Worth a footnote.

## 10. Bottom-line verdict for Gaekju on Giwa

- **We cannot port Lighter's architecture.** Their performance depends on
  (a) custom non-EVM execution, (b) ZK-friendly primitives (Goldilocks,
  ECgFp5, Poseidon2), and (c) batched proof amortization. None of those
  are available on Giwa (OP Stack EVM) out of the box.
- **The only pure-EVM reference design that has shipped** a CLOB is
  Clober/LOBSTER on Base, and it is spot, not perps, with modest volume.
- **Our realistic peers on OP Stack are Aevo and Vertex**, both of which
  moved matching off-chain. If we want fully on-chain matching on Giwa
  as a principle, we are doing something **nobody else in production has
  done for perps**. That's not a reason to stop, but the design margin
  for gas/latency has to be taken seriously in Phase 3+.

## Sources

- [L2Beat: ZK Catalog – LighterProver](https://l2beat.com/zk-catalog/lighterprover)
- [Stanford Blockchain Review #77: Shedding the Light(er)](https://review.stanfordblockchain.xyz/p/77-shedding-the-lighter-the-fine)
- [Lighter whitepaper](https://assets.lighter.xyz/whitepaper.pdf)
- [GitHub: elliottech/lighter-prover](https://github.com/elliottech/lighter-prover)
- [Hyperliquid architecture – zealynx](https://www.zealynx.io/blogs/Understanding-Hyperliquid-Architecture-HyperBFT-HyperCore-HyperEVM-Part1)
- [Hyperliquid architecture – cleansky](https://cleansky.io/blog/hyperliquid-architecture-hypercore-hyperevm-2026/)
- [Vertex technical architecture](https://docs.vertexprotocol.com/basics/technical-architecture)
- [Aevo off-chain orderbook docs](https://docs.aevo.xyz/aevo-exchange/technical-architecture/off-chain-orderbook-and-risk-engine)
- [dYdX v3 L2Beat page](https://l2beat.com/scaling/projects/dydx)
- [dYdX v4 architecture (Medium, Jung-Hua Liu)](https://medium.com/@gwrx2005/dydx-v4-architectural-and-protocol-evolution-from-v3-6c312f51f7b7)
- [Uniswap V3 TickBitmap source](https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickBitmap.sol)
- [Uniswap V3 Development Book: Tick Bitmap Index](https://uniswapv3book.com/milestone_2/tick-bitmap-index.html)
- [Monad: Understanding LOBSTER (Clober)](https://blog.monad.xyz/blog/understanding-lobster)
- [Clober limit orders docs](https://docs.clober.io/concepts/limit-order)
