# ADR-0013: SP1 as the zkVM Framework

## Status
Accepted

## Date
2026-04-22

## Context
ADR-0012 commits Gaekju to a zkVM-proven off-chain matcher. The matching logic is written in Rust, executed by the sequencer for soft-confirm, and re-executed inside a zero-knowledge virtual machine to produce a succinct proof of correct batch execution. Settlement.sol verifies that proof on Giwa Chain before applying the state delta.

The zkVM framework is a load-bearing choice. It determines prover cost per batch, end-to-end proof latency, the gas cost of on-chain verification, the engineering cost of writing and maintaining the circuit program, and the operational risk if the framework's proving infrastructure fails. As of Q2 2026 there are three serious general-purpose Rust-friendly zkVMs: Succinct's SP1, RISC Zero, and a16z's Jolt.

SP1 ships a RISC-V zkVM with a Plonky3-based prover, an open-source Rust toolchain, and a production EVM verifier contract. Succinct operates a managed proving cluster and a proof marketplace; SP1 is the prover Optimism adopted for its fault-proof system, giving it the largest live EVM footprint of any general zkVM in 2026.

RISC Zero is older and more mature as a research artifact. Its proving stack uses Groth16 wrapping for EVM verification and has a larger historical deployment base in zkRollup tooling. Per-cycle prover cost in 2026 is roughly 1.5-2x SP1 for comparable workloads based on Succinct's and community benchmarks.

Jolt (a16z crypto) uses a lookup-argument-heavy design that is faster in theory for some workloads but was still pre-1.0 as of early 2026 with no production EVM verifier deployment and no managed proving infrastructure.

## Decision
We adopt **SP1** as the zkVM for `crates/gaekju-prover`. The matching program is a single Rust binary compiled for SP1's RISC-V target; the same source is compiled natively for the sequencer's hot path. Proving is submitted to Succinct's managed prover network by default, with a local-prover fallback for development and for the censorship-escape case where the managed network is unavailable.

On-chain verification uses SP1's canonical Groth16 EVM verifier contract deployed behind a UUPS proxy so the verifier can be upgraded if Succinct ships a new version (PLONK wrapping, verifier gas reductions, etc.). Settlement.sol calls the verifier, checks the program's verification key against a pinned value, and then decodes the public outputs (prior state root, new state root, batch metadata, force-include cursor).

## Consequences
### Positive
- EVM verifier gas is ~300k per proof in 2026 SP1 releases, amortized across an entire batch of fills. This is the dominant on-chain cost and it is competitive with RISC Zero's Groth16 verifier and dramatically cheaper than verifying raw STARKs on-chain.
- Succinct operates production proving infra used by Optimism fault proofs, which gives us an operational reference and a reason to trust uptime at production scale.
- Rust program reuse is direct: the exact Rust source executed by `gaekju-sequencer` is the source compiled into the zkVM program. No separate circuit DSL, no translation layer.
- Per-proof dollar cost trending down through 2026 as Succinct's prover cluster scales; recent published numbers put a typical SP1 batch proof in the $0.01-$1 range depending on cycle count.
- Upgradability: verifier contract is proxied (ADR-0009), so moving to a newer SP1 version or a hypothetically cheaper wrapper is a parameter change, not a protocol fork.

### Negative
- Dependency on Succinct's managed proving network for production cadence. Running our own prover cluster is possible but meaningfully raises opex.
- Proof latency is 30-60s typical for SP1 on batch sizes we expect (a few hundred fills), which forces the soft-confirm UX layer specified in ADR-0015.
- The Rust program must be deterministic and must compile cleanly against SP1's `std` subset. Some ecosystem crates (especially those that touch time, entropy, or syscalls) will not work inside the zkVM, constraining matcher implementation choices.
- Groth16 verifier requires a trusted setup; SP1 inherits the Groth16 ceremony. This is a known caveat accepted by Optimism and the broader ecosystem.

### Neutral
- SP1 is the newer framework of the three, so ecosystem inertia (tooling, tutorials, stackoverflow hits) is smaller than RISC Zero but larger than Jolt.
- The choice of zkVM does not affect any other ADR: settlement, sequencer model, batching cadence, and force-inclusion are all framework-agnostic.

## Fallback If SP1 Infrastructure Fails
Three failure modes are distinguished:

1. **Succinct proving network outage.** Fallback: self-hosted SP1 prover. Same program, same verifier, higher opex. This is a config flip in `gaekju-prover`.
2. **SP1 framework deprecation / critical bug.** Fallback: port the Rust matching program to RISC Zero. The program is small (matching loop + state transition), so the port is measured in days, not months. The verifier contract swap is a timelocked upgrade.
3. **Verifier contract exploit.** Pause Settlement via the emergency-pause path (ADR-0009), freeze new batches, audit, redeploy verifier behind the existing proxy. In-flight user intents revert to force-inclusion path.

## Alternatives Considered
### RISC Zero
- Pros: older, more production deployments historically, mature tooling.
- Cons: higher prover cost per cycle in 2026 benchmarks, less aggressive EVM verifier gas roadmap, no equivalent to Succinct's Optimism-fault-proof footprint.
- Why rejected: cost and EVM-gas trajectory both favor SP1 as of 2026-04. Retained as a fallback target.

### Jolt
- Pros: theoretically fastest prover for lookup-heavy workloads, novel design.
- Cons: pre-1.0 in early 2026, no production EVM verifier, no managed proving network, no production users at scale.
- Why rejected: too early. Revisit in 2027.

### Custom circuits (Plonky2 STARK → gnark SNARK, Lighter-style)
- Pros: lowest on-chain gas, smallest proofs, Lighter-proven design.
- Cons: 12-18 months of circuit engineering, cryptography specialist headcount, custom signature scheme incompatible with EVM wallets.
- Why rejected: team scale. zkVM trades prover cost for engineering surface reduction. See ADR-0012.

## References
- ADR-0012 — zkVM matcher pivot
- ADR-0014 — sequencer trust model
- ADR-0015 — proof batching cadence
- Research: `docs/research/lighter-stack-investigation.md`, `docs/research/2026-perp-dex-landscape.md`
- Succinct SP1 documentation and Optimism fault-proof deployment notes
