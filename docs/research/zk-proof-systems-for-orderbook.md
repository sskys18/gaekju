# ZK Proof Systems for Orderbook Matching Correctness

Research date: 2026-04-07

## Context

Gaekju currently runs a fully on-chain CLOB on an OP Stack L2. This is architecturally honest but fundamentally limited: 2s block times, high gas per match, market makers won't quote tight spreads. Every serious perp DEX has converged on off-chain matching with on-chain settlement. The question is: if Gaekju moves to an off-chain Rust matching engine, which ZK proof system should prove correctness?

The use case: a centralized sequencer matches orders in a Rust engine, then generates ZK proofs that the matching was done correctly. These proofs are verified on-chain (EVM). This is exactly what Lighter.xyz does.

---

## 1. What Exactly Needs to Be Proven

### The State Transition

```
old_state_root + batch_of_operations -> new_state_root
```

Where operations include: order placement, order cancellation, order matching (fills), liquidations, funding rate application, balance updates (deposits/withdrawals).

### What Lighter Proves (confirmed via ZK Security audit + L2Beat + Stanford Blockchain Review)

Lighter's circuits prove:

1. **Execution integrity**: Given a sequence of transactions and oracle inputs, the resulting state is computed correctly according to protocol rules. The prover cannot produce a valid proof for an arbitrary state transition.

2. **Price-time priority**: The circuit verifies that the correct maker (determined by time priority) was selected. Priority is encoded into the Merkle tree leaf index, so within a batch, a friendly market maker cannot be secretly prioritized over an earlier order.

3. **Balance conservation**: The sequencer cannot modify account balances arbitrarily or fabricate positions out of thin air. No funds created from nothing.

4. **Data availability**: Proofs attest that data posted to Ethereum blobs is sufficient to reconstruct user states.

### What Lighter Does NOT Prove

- **Transaction ordering fairness**: The sequencer determines ordering. Proofs verify execution was correct *given* the ordering, not that the ordering was fair. Front-running/MEV remains possible.
- **Inclusion**: If the sequencer doesn't include a user's order in a batch, no proof violation occurs. Censorship is not prevented by ZK proofs.
- **Oracle accuracy**: Circuits verify correct computation using supplied prices but cannot validate that oracle data reflects actual market conditions.

### What Gaekju Would Need to Prove

Identical to Lighter's scope:
- State transition: Merkle root update from old to new state
- Matching correctness: price-time priority respected
- Balance correctness: sum of all balance changes = 0 (conservation)
- Position accounting: entry prices, sizes, PnL calculated correctly
- Margin checks: IMR/MMR respected at order time
- Funding application: correct rates applied to correct positions

---

## 2. Proof System Comparison

### A. Custom Plonky2 Circuits (What Lighter Uses)

**Architecture**: STARK-based inner proofs (Plonky2 over Goldilocks field, FRI polynomial commitment) wrapped in a Gnark PLONK SNARK over BN254 for cheap EVM verification. The STARK layer needs no trusted setup; the SNARK wrapper uses the Aztec Ignition ceremony (BN254 KZG, 176 participants).

**What Lighter built**:
- Custom circuits for every transaction type (internal, L1, L2 transactions)
- Custom bigint/uint arithmetic, ECDSA (secp256k1), EdDSA (ECgFp5), Keccak, Poseidon
- Recursive aggregation: BlockTx circuits process fixed-size transaction blocks (parallelizable), then BlockTxChain circuits aggregate multiple BlockTx proofs
- Desert mode circuits for emergency L1 exits

**Maturity**: Production on Ethereum mainnet. Audited by zkSecurity and Nethermind. Open-sourced at `elliottech/lighter-prover`.

**EVM verification**: ~230k gas via BN254 pairing precompile (ecPairing at 0x08).

**Pros**:
- Maximum performance -- circuits are hand-optimized for the exact operations needed
- Proven in production (Lighter runs this today)
- Plonky2 is MIT/Apache licensed, well-documented

**Cons**:
- Enormous engineering effort. Lighter's circuits are thousands of lines of custom constraint code
- Every protocol change requires circuit changes (new order types, new margin rules = new circuits)
- Requires deep ZK cryptography expertise to build and maintain
- Plonky2 is effectively superseded by Plonky3 (Polygon's next gen, also production-ready and used by SP1)
- Desert mode circuit source was NOT publicly available until late 2025 (transparency concern)

**Estimated effort**: 6-12 months for a team with ZK experience. Not viable for a small team.

### B. SP1 (Succinct) -- zkVM Approach

**Architecture**: Write your program in normal Rust, compile to RISC-V, SP1 proves correct execution. Uses Plonky3 internally. Outputs STARK proofs that are recursively compressed into a Groth16 or PLONK SNARK for EVM verification.

**Current performance (SP1 Hypercube, late 2025/2026)**:
- Proves 99.7% of Ethereum L1 blocks in under 12s on 16 NVIDIA RTX 5090 GPUs
- Proves 95.4% of blocks under 10s on same hardware
- Single-machine throughput: 900 KHz to several MHz (cycles/second)
- Cost per average Ethereum transaction: ~0.1 cents
- Ethereum block = ~30M+ cycles. An orderbook batch of 100 operations would be dramatically smaller.

**EVM verification**: ~300k gas for Groth16 proof, ~300k for PLONK proof. Production verifier contracts deployed on all major chains (`succinctlabs/sp1-contracts`). Verifier gateway auto-routes to correct version.

**GPU acceleration**: Native GPU support. 16x RTX 5090 for real-time Ethereum proving. FPGA acceleration planned Q2 2026 (20x improvement claimed).

**Pros**:
- Write matching logic in normal Rust. No circuit expertise needed.
- Same Rust matching engine code runs both in production and inside the zkVM
- Mature ecosystem: production verifier contracts, prover network (SPN), extensive docs
- Plonky3-based (latest generation proving system)
- Active development, Succinct is well-funded
- Precompile system accelerates crypto operations (secp256k1, keccak, sha256) by 5-10x

**Cons**:
- Overhead vs custom circuits: general-purpose zkVM adds ~10-100x overhead compared to hand-written circuits for the same computation
- Requires GPU infrastructure for reasonable proving times
- Trusted setup for the Groth16 wrapper (BN254)
- You're dependent on Succinct's toolchain and proving infrastructure

**Estimated effort**: 2-4 weeks to wrap existing Rust matching engine in SP1. The matching logic IS the program -- you just prove its execution.

### C. RISC Zero -- zkVM Approach

**Architecture**: Similar to SP1. Write Rust, compile to RISC-V, prove execution. Uses custom STARK system. R0VM 2.0 (April 2025) was a major performance leap.

**Current performance (R0VM 2.0)**:
- Ethereum block proof: reduced from 35 minutes to 44 seconds
- Target: under 12 seconds by July 2025 (unclear if achieved)
- Peak throughput on Boundless network: 25.93 MHz
- Tested up to 167 million RISC-V cycles in a single proof
- Cost per proof on Base (batch of 25 blocks): $0.27/block

**EVM verification**: ~300k gas (same as SP1, uses similar Groth16/SNARK wrapping).

**Unique feature**: Boundless -- a decentralized proof marketplace. You submit a program + inputs, provers compete to generate the proof. Mainnet beta launched July 2025.

**Pros**:
- Same developer experience as SP1 (write Rust, prove it)
- Boundless marketplace means you don't need to run your own GPU infrastructure
- 3GB user memory (R0VM 2.0) supports complex state
- Strong on general-purpose computation
- Open source

**Cons**:
- Higher memory overhead than SP1 (paging costs ~1,130 cycles per page-in/page-out)
- SP1 generally outperforms on blockchain-specific workloads (crypto operations)
- Smaller ecosystem than SP1 for DeFi-specific use cases
- RISC Zero was 7x cheaper on some benchmarks, SP1 10x cheaper on others -- workload dependent

**Estimated effort**: 2-4 weeks, same as SP1.

### D. Halo2 (PSE/Scroll)

**Architecture**: PLONK-based proof system. Used by Scroll (zkEVM), Axiom, and others. Rust implementation.

**Current status**: PSE-Halo2 entered **maintenance mode** January 2025. No new features, only bug fixes. Axiom's fork (`halo2-lib`) is the active development branch.

**EVM verification**: Uses KZG commitments, verification via BN254 pairing precompile. ~300-600k gas depending on circuit complexity.

**Pros**:
- Battle-tested in production (Scroll zkEVM)
- No trusted setup for the proof system itself (uses IPA), though KZG variant needs setup
- Mature Rust tooling

**Cons**:
- Requires writing custom circuits (not a zkVM)
- PSE version in maintenance mode
- Steeper learning curve than zkVM approaches
- Less suited for "prove arbitrary Rust program" use case
- Scroll is migrating toward different proving stacks

**Estimated effort**: 4-8 months with circuit expertise.

---

## 3. Proof Generation Time Estimates for Orderbook Batches

### Estimating cycle count for a 100-operation batch

A single order match in the matching engine involves:
- Merkle tree lookups and updates (2-4 state reads/writes)
- Fixed-point arithmetic (price comparison, quantity calculation, balance updates)
- Comparison operations (price-time priority)

Rough estimate: 50,000-200,000 RISC-V cycles per order operation in a zkVM. A batch of 100 operations: **5M-20M cycles**.

For context: an average Ethereum block is ~30M+ cycles and SP1 proves it in ~10s on 16 GPUs.

### Estimated proving times

| System | 100-op batch (est.) | Hardware | Notes |
|--------|-------------------|----------|-------|
| SP1 Hypercube | 2-8 seconds | 4-8 GPUs (RTX 4090/5090) | Extrapolated from Ethereum block benchmarks |
| SP1 (single machine) | 10-30 seconds | 1 GPU | At ~1 MHz throughput for 10-20M cycles |
| RISC Zero R0VM 2.0 | 5-15 seconds | GPU cluster | Extrapolated from block proof times |
| RISC Zero Boundless | Variable | Marketplace | Depends on prover competition/availability |
| Custom Plonky2 | Sub-second to 2s | CPU/GPU | Hand-optimized circuits, much tighter |
| Custom Plonky2 + aggregation | <1s per batch, amortized | Parallel provers | What Lighter does in production |

### Is this fast enough?

For a batch-based system (like Lighter): **Yes, easily.** Lighter batches thousands of operations and posts proofs periodically. A 2-10 second proving time for 100 operations is fine when you batch every few seconds or every block.

For real-time per-order proving: **No.** You need batching. Individual order proving would add seconds of latency per order, which defeats the purpose of off-chain matching.

The practical architecture is:
1. Sequencer matches orders with millisecond latency (users get soft confirmation)
2. Prover generates batch proofs in parallel (every N seconds or N operations)
3. Batch proofs posted to L1/L2 for finality

---

## 4. zkVM (SP1/RISC Zero) vs Custom Circuits

### The Overhead Question

zkVM overhead vs custom circuits is typically **10-100x** in cycle count. This sounds devastating but consider:

1. **The absolute numbers still work.** 10M cycles at 1 MHz = 10 seconds. For batch proofs posted every 30-60 seconds, this is fine.
2. **GPU parallelism covers the gap.** SP1 Hypercube on 16 GPUs proves an entire Ethereum block (which is far more complex than 100 order matches) in under 12 seconds.
3. **Developer velocity matters more.** Custom circuits take 6-12 months to build. SP1 wrapping takes 2-4 weeks. You can iterate on protocol rules without rewriting circuits.
4. **Precompiles narrow the gap.** SP1's precompiles for common crypto operations (hashing, signature verification) run at near-native circuit speed, reducing the effective overhead for crypto-heavy workloads.

### When Custom Circuits Win

- **Extreme throughput requirements**: If you need to prove 100,000+ operations per second
- **Minimal hardware budget**: Custom circuits can prove on CPU; zkVMs practically require GPUs
- **Competitive advantage**: Lighter's custom circuits are part of their moat

### When zkVM Wins

- **Small team**: You don't have ZK cryptographers on staff
- **Rapid iteration**: Protocol rules change frequently in early stages
- **Time to market**: Weeks vs months
- **Sufficient throughput**: Batch proving every few seconds is acceptable

### Projects Using zkVM for Financial State Transitions

- **Bullet (formerly Zeta Markets)**: RISC-V zkVM for order matching on Solana
- **Paradex**: ZK rollup-based DEX using sequencer + validity proofs
- Various ZKSync-based order books using coordinator pattern
- SP1's own `zk-exchange` framework example

---

## 5. EVM Verification Costs

| Proof System | On-chain Verification Gas | Notes |
|-------------|--------------------------|-------|
| Groth16 (BN254) | ~200-300k gas | Uses ecPairing precompile (0x08). Formula: 34,000*k + 45,000 for k pairings (k=4 for Groth16 = 181k base + public input costs) |
| PLONK (BN254) | ~300k gas | SP1's PLONK mode, slightly larger proof |
| Plonky2 + Gnark wrapper | ~230k gas | What Lighter uses (STARK->SNARK wrapping) |
| Raw STARK (FRI) | ~2-5M gas | Not practical for direct on-chain verification. Always wrap in SNARK. |
| SP1 Groth16 | ~300k gas | Production contracts deployed on all major chains |
| RISC Zero Groth16 | ~300k gas | Similar wrapping approach |

### Key EVM Precompiles

- **ecPairing (0x08)**: BN254 pairing check. Essential for Groth16/PLONK verification. Available on all EVM chains.
- **ecAdd (0x06)** and **ecMul (0x07)**: BN254 point operations. Used in proof verification.
- **RIP-7212**: secp256r1 verification (not directly relevant but shows precompile trend)
- **Proposed BLS12-381 precompiles**: Would enable more efficient verification for some proof systems. Not yet deployed.

### Cost in USD

At 300k gas and ~0.01 gwei gas price on OP Stack L2: effectively free (<$0.001). On Ethereum L1 at 30 gwei: ~$2-3. On L2, verification cost is negligible.

---

## 6. Recommendation for Gaekju

### Short answer: SP1

**Rationale:**

1. **Gaekju already has the matching engine in Rust.** SP1's value proposition is exactly this: write the logic in Rust, prove it. The existing `contracts/src/` orderbook logic would need to be reimplemented as a Rust matching engine (which Gaekju would need regardless of proof system), and then SP1 proves that engine's execution.

2. **Team size.** Custom Plonky2 circuits require dedicated ZK engineers. SP1 requires Rust engineers (which you are).

3. **Maturity.** SP1 has production EVM verifier contracts deployed on all major chains. The Succinct Prover Network handles proof generation as a service if you don't want to run GPUs.

4. **Performance is sufficient.** A 100-operation batch would prove in seconds on modest GPU hardware. Lighter-scale throughput (thousands of ops/batch) is achievable with a small GPU cluster.

5. **Iteration speed.** When you change margin rules, add new order types, or modify funding calculation, you change Rust code -- not circuits.

### Migration Path

```
Phase 1 (current): Fully on-chain CLOB on OP Stack L2
  - Educational, transparent, works for low-frequency markets
  
Phase 2 (future): Off-chain Rust matching engine + SP1 proofs
  - Rust matching engine mirrors on-chain logic
  - SP1 proves each batch of operations  
  - EVM verifier contract checks proof + updates state root
  - Users get millisecond soft finality, batch proof finality every N seconds
  
Phase 3 (aspirational): Optimized circuits if throughput demands it
  - Only if SP1 overhead becomes a bottleneck at scale
  - Can selectively replace hot paths with custom Plonky3 circuits
```

### What NOT to Do

- Don't build custom Plonky2 circuits from scratch. The effort/reward ratio is terrible for a small team.
- Don't use Halo2 -- it's in maintenance mode and requires circuit expertise.
- Don't try to prove every individual order. Batch proving is the only practical approach.
- Don't skip the on-chain phase. The current architecture is correct for testnet and educational purposes.

---

## Sources

- [Stanford Blockchain Review: Shedding the Light(er)](https://review.stanfordblockchain.xyz/p/77-shedding-the-lighter-the-fine)
- [ZK Security: Public Report of Lighter ZK Circuits](https://blog.zksecurity.xyz/posts/lighter-xyz/)
- [ZK Security: Lighter Circuit Audit PDF](https://blog.zksecurity.xyz/2024-lighter-zklighter-report.pdf)
- [L2Beat: Lighter ZK Catalog](https://l2beat.com/zk-catalog/lighterprover)
- [SP1 Hypercube: Real-Time Proving](https://blog.succinct.xyz/sp1-hypercube/)
- [SP1 Hypercube: 16 GPUs](https://blog.succinct.xyz/real-time-proving-16-gpus/)
- [SP1 Contracts (GitHub)](https://github.com/succinctlabs/sp1-contracts)
- [SP1 Verifier Contract Addresses](https://docs.succinct.xyz/docs/sp1/verification/contract-addresses)
- [SP1 Proof Types](https://docs.succinct.xyz/docs/sp1/generating-proofs/proof-types)
- [SP1 Benchmarks 8/6/24](https://blog.succinct.xyz/sp1-benchmarks-8-6-24/)
- [SP1 Turbo](https://blog.succinct.xyz/sp1-turbo/)
- [RISC Zero: Introducing R0VM 2.0](https://risczero.com/blog/introducing-R0VM-2.0)
- [RISC Zero Benchmarks](https://dev.risczero.com/api/zkvm/benchmarks)
- [RISC Zero: Designing High-Performance zkVMs](https://risczero.com/blog/designing-high-performance-zkVMs)
- [Comparative Analysis: SP1 vs RISC Zero](https://medium.com/@gwrx2005/comparative-analysis-of-sp1-and-risc-zero-zero-knowledge-virtual-machines-4abf806daa70)
- [Polygon Plonky3 Production Ready](https://polygon.technology/blog/polygon-plonky3-the-next-generation-of-zk-proving-systems-is-production-ready)
- [Plonky3 GitHub](https://github.com/Plonky3/Plonky3)
- [Halo2 PSE GitHub](https://github.com/privacy-scaling-explorations/halo2)
- [Axiom Halo2-lib](https://github.com/axiom-crypto/halo2-lib)
- [Horizen Labs: True Cost of ZK Verification](https://medium.com/horizen-labs/how-much-does-it-cost-to-verify-a-zero-knowledge-proof-on-chain-and-what-does-it-mean-exactly-2cefd68cf204)
- [Lighter Whitepaper](https://assets.lighter.xyz/whitepaper.pdf)
- [Lighter Open-Sources ZK Circuits](https://blockonomi.com/lighter-open-sources-zero-knowledge-proof-circuits-following-security-audits)
- [Lighter Prover (GitHub)](https://github.com/elliottech/lighter-prover)
