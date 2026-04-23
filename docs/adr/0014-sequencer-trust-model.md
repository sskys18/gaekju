# ADR-0014: Sequencer Trust Model and Force-Inclusion

## Status
Accepted

## Date
2026-04-22

## Context
ADR-0012 moves matching off-chain into a Rust sequencer and proves execution with SP1 (ADR-0013). The zk proof establishes that the sequencer ran the canonical matching program deterministically over a specific ordered input set. It does not establish that the ordered input set was itself fair. The sequencer remains the sole decider of which user intents enter a batch and in what order.

This is the same trust boundary Lighter.xyz operates under: Lighter's own documentation is explicit that matching correctness is proven but *ordering* is not in-circuit. Hyperliquid, Vertex, Aevo, Paradex, and every off-chain-match perp DEX in 2026 lives in the same bucket. The question is not whether ordering is a trust axis — it is — but how we bound its blast radius.

The adversarial behaviors this ADR must address:

1. **Censorship.** Sequencer drops a user's intent indefinitely. The user's position cannot be closed, margin cannot be withdrawn, liquidations cannot be triggered.
2. **Reordering for extraction.** Sequencer reorders intents to frontrun, backrun, or sandwich specific users.
3. **Equivocation.** Sequencer commits one state root to L2 and shows users a different state off-chain.

The zk proof solves equivocation by construction: the state root committed on-chain is the one the proof attests to, and the sequencer cannot produce a valid proof over a state it did not actually compute. Censorship and reordering require separate mitigations.

Gaekju v1 deploys with a **single operator** sequencer (Dunamu / the team) because standing up a rotating BFT sequencer set is out of scope for the initial launch and inconsistent with the infra realities of a Stage-0 L2. Every peer at similar stage (Lighter, Paradex, Aevo, Vertex) launched single-operator and only later added rotation or decentralization.

## Decision
We adopt a **single-operator sequencer with on-chain force-inclusion escape hatch**, post-batch state-root commitment, and a documented path to a rotating sequencer set.

Concretely:

1. **Single operator**. One sequencer instance accepts signed EIP-712 intents over REST/WS, runs the matching program, emits batches. The operator identity is pinned in Settlement.sol as `SEQUENCER_ROLE` and rotated via the same timelock + multisig governance as contract upgrades (ADR-0009).

2. **Force-inclusion via `Router.forceInclude(intent)`**. Any user can bypass the sequencer by submitting a signed intent directly on-chain through the Router contract. Router appends the intent to an on-chain **force-include queue** with a deadline expressed as `batchNonce + N`. Settlement.sol's proof verification asserts that every force-included intent whose deadline has passed **has a proved outcome** in the batch's `ForcedOutcome[]` array (accepted-with-fill-hash, or rejected-with-reason-code). Free-form `ForcedAck` entries are not accepted — the prover must run the intent (or its rejection) through the zkVM circuit, so the sequencer cannot falsely claim "resolved." If a deadline-passed queue entry is missing from `ForcedOutcome[]`, the proof is rejected and the batch does not apply. See design spec §15.2 (`ForcedOutcome` layout, `ForcedRejectReason` enum) and §15.3 steps 6-7 for the application order. The sequencer is therefore mechanically compelled to produce a proved accept or proved reject for every force-included intent within N batches.

3. **Censorship bound**. N is a protocol parameter, initial value **N=3 batches** (≈ 15 seconds at a 5-second batch cadence per ADR-0015). A force-included intent that is not processed within N batches after its submission-block deadline triggers sequencer default: `SEQUENCER_ROLE` is revocable by a second, separate guardian role, and Settlement enters a recovery mode where users can exit via on-chain-only operations (deposit / withdraw / close-via-force-include) while governance rotates to a new sequencer.

4. **Post-batch state-root commitment**. Every proven batch commits (`priorRoot`, `newRoot`, `batchNonce`, `forceIncludeCursor`) as Settlement-contract events. The state root is a Merkle root over account states, order book state, and open positions. Any observer can reconstruct the root from published intents + the canonical matching program and detect equivocation. This does not *prevent* reordering but makes reordering attributable and auditable after the fact.

5. **Batch nonce monotonicity**. Settlement rejects any proof whose `batchNonce` is not exactly `priorBatchNonce + 1`. This prevents the sequencer from replaying, skipping, or forking the batch sequence.

6. **Mempool privacy**. The sequencer's intent-submission endpoint does not expose pending intents to third parties before inclusion. This reduces sandwich opportunities vs. a public mempool but is not a cryptographic guarantee — it is operational best-effort, the same posture as every off-chain-match peer in 2026.

7. **Future: rotating sequencer set**. Post-v1, `SEQUENCER_ROLE` becomes multi-holder with round-robin or stake-weighted rotation. Proofs and force-inclusion remain unchanged; the only change is which identity signs each batch. This is an upgrade path, not a v1 commitment.

## Ordering Fairness Is Not Proven In-Circuit
We want to be explicit: the SP1 proof says the sequencer ran the canonical matching program over the exact input list it submitted. It does **not** say the input list is the fairest possible ordering of the intents the sequencer received. This is the same limitation Lighter.xyz, Paradex, Aevo, and every 2026-era zk-proven DEX operates under.

Mitigations:
- **Private intent submission** reduces frontrunnable information leakage.
- **Force-include** bounds worst-case censorship latency to N batches.
- **Post-batch commit + public input stream** makes systematic reordering statistically detectable.
- **Future rotation** removes single-operator long-term alignment risk.

We explicitly accept this as the known residual risk of single-operator zk matching. It is strictly better than unproven off-chain matching (Hyperliquid pre-ZK) because matching *logic* cannot deviate, and strictly better than on-chain matching for UX because the sequencer can match in milliseconds while settling in seconds.

## Consequences
### Positive
- Censorship is bounded and economically punishable. A sequencer that ignores a valid force-included intent forfeits its role.
- Equivocation is eliminated by construction (proof + state-root commit).
- Users who never care about force-inclusion pay zero gas for the hot path — sequencer ack is a REST response, not a transaction.
- Sequencer role is upgradeable, so rotation is a future governance change, not a redeploy.

### Negative
- Reordering within a batch is not prevented, only attributable after the fact. A misbehaving sequencer can extract value between batches until detected.
- Force-include adds a code path in Settlement that must always work even when the sequencer is adversarial. Extra audit surface.
- N-batch censorship bound still means a user could be delayed ~15s. Fine for position management, potentially painful during high volatility.

### Neutral
- Mirror bot (ADR-0010) submits intents through the normal sequencer path, not force-include. Operator trust of the mirror is a separate axis.
- Force-include does not depend on SP1 specifically; any zkVM swap (ADR-0013 fallback) inherits the same force-include machinery.

## Alternatives Considered
### Fully-decentralized BFT sequencer set from day 1
- Pros: no single-operator trust, no force-include needed in theory.
- Cons: 6-12 months of consensus engineering, operational complexity, and stake/slashing machinery.
- Why rejected: out of v1 scope. Every 2026 peer launched single-operator.

### Encrypted mempool / threshold decryption
- Pros: cryptographic guarantee against frontrunning.
- Cons: no production-grade EVM-compatible implementation in 2026, latency overhead, extra trust in threshold committee.
- Why rejected: too early. Revisit when Shutter-style stacks mature.

### No force-include, only off-chain reputation
- Pros: simplest system.
- Cons: censorship is unbounded. A user whose position the sequencer dislikes can be frozen indefinitely.
- Why rejected: not an acceptable posture for a system holding user margin.

## References
- ADR-0012 — zkVM matcher pivot
- ADR-0013 — SP1 zkVM framework
- ADR-0015 — proof batching cadence
- Research: `docs/research/lighter-stack-investigation.md` (Lighter's own sequencer trust posture)
- Research: `docs/research/2026-perp-dex-landscape.md` (peer comparison)
