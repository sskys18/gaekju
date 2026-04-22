# ADR-0015: Proof Batching and Settlement Cadence

## Status
Accepted

## Date
2026-04-22

## Context
ADR-0012 separates three layers of confirmation for any user action:

1. **Sequencer ack** — matcher has accepted the intent, matched it, and told the user the fill price. This is off-chain, milliseconds.
2. **Batch close** — sequencer stops accepting new intents for this batch and hands the input list to the prover. Seconds.
3. **On-chain finality** — SP1 proof is verified on Giwa Chain, Settlement applies the state delta, Vault/PositionManager storage updates. Tens of seconds, worst case a couple of minutes.

The cadence of (2) and (3) is a product and infra decision. Too short and proof cost dominates — each proof has a fixed overhead, so tiny batches are wasteful. Too long and on-chain finality lags enough that force-inclusion deadlines (ADR-0014) become too loose and the UX of "your trade is final on-chain" degrades. Concretely, the batch window interacts with SP1 prover latency (ADR-0013), Giwa block time, the force-include N-batch censorship bound, and the user-facing pending-state design.

## Decision
We adopt the following cadence parameters for v1. All are protocol parameters governed by the same timelock + multisig as other upgrades.

- **Batch window: 5 seconds** (default, tunable).
- **Proof generation target: 30-60 seconds** per batch under normal load (managed SP1 prover, batch size up to a few hundred fills).
- **On-chain settlement: next Giwa block after proof arrival**, so finality is `batch_window + proof_time + 1 Giwa block` ≈ 40-70 seconds typical, 2 minutes worst case under prover backlog.
- **Batch nonce**: strictly monotonic, enforced by Settlement.sol. Proof verification rejects any `batchNonce != priorBatchNonce + 1` (see ADR-0014).
- **Force-include deadline**: N = 3 batches = ~15 seconds of sequencer discretion before a force-included intent *must* appear in a batch input list.

### Soft-confirmation UX layers

The three cadence layers are surfaced to users as three distinct pending states in the frontend and SDK:

| Layer | Latency | UX label | Finality meaning |
|-------|---------|----------|------------------|
| Sequencer ack | < 100ms | "filled" | Matcher has committed the fill. Reversible only if the sequencer goes into default. |
| Batch closed | 5s | "sealed" | Intent is inside a batch whose input list is frozen. Sequencer cannot silently drop or reorder this intent relative to its batch mates. |
| On-chain settled | 40-70s | "final" | Proof verified on Giwa, state delta applied. User's Vault / PositionManager storage reflects the fill. Cannot be reverted short of governance recovery. |

Clients should optimistically render "filled" state for UX smoothness and visibly advance to "sealed" and "final" as confirmations arrive. Withdrawals require "final" — Vault.withdraw only acts on state that has been settled on-chain.

### Batch nonce monotonicity
Settlement.sol tracks `lastBatchNonce`. Every accepted proof must reference `priorBatchNonce = lastBatchNonce` and output `newBatchNonce = lastBatchNonce + 1`. This:
- prevents the sequencer from submitting parallel forks of the batch chain,
- prevents replay of an old proof,
- gives the indexer (ADR-0007) a simple linear view of history.

If a proof for batch N is missing (prover halt, infra failure), batch N+1's proof cannot apply because its `priorRoot` would not match Settlement's stored root. The system halts new settlements until the gap is filled or governance intervenes. During the halt, force-include intents accumulate on-chain and the N-batch censorship deadline progresses — the protocol falls into the sequencer-default path in ADR-0014 if the halt exceeds the force-include window.

## Consequences
### Positive
- 5-second batch window is short enough that force-include latency (~15s worst case) is well inside what users tolerate for position management.
- Per-batch proof overhead amortizes over a realistic number of fills (assuming even 10 fills/sec, a 5s batch carries ~50 fills, and verification gas ~300k / 50 = ~6k gas per fill — cheaper than any on-chain matcher).
- Three-layer UX (filled/sealed/final) is honest about the trust gradient and gives power users the information to decide when to take dependent actions (e.g., withdrawal).
- Monotonic batch nonce makes indexer logic trivial and audit trails linear.

### Negative
- Withdrawal UX is gated on "final," which is 40-70s. For users coming from CEX instant-withdrawal expectations this is a downgrade; mitigated by clear pending-state surfacing.
- A prover halt stalls on-chain finality even while the sequencer is healthy. Sealed-but-not-final backlog is bounded by force-include deadline before governance intervention triggers.
- 5s window is a guess based on expected v1 volume. If real volume is much lower, we waste proof overhead on tiny batches; if much higher, we hit prover saturation. Tunable via governance.

### Neutral
- Cadence numbers are all protocol parameters, not hardcoded assumptions in contracts. Tuning does not require redeploys.
- Giwa Chain's 1-second block time means on-chain settlement latency is dominated by proof time, not L2 finality.

## Alternatives Considered
### 1-second batches
- Pros: lower sealed latency.
- Cons: proof overhead dominates; small batches mean per-fill gas goes up 5x. Prover backlog risk on any volume spike.
- Why rejected: optimizes the wrong layer. Sequencer ack is already <100ms.

### 30-second batches
- Pros: fewest proofs, cheapest per-fill gas.
- Cons: force-include deadline balloons to ~90s, which is too loose for a system holding leveraged positions during volatility.
- Why rejected: worsens the censorship bound that is our main live safety property.

### Event-driven batch close (close on N intents OR T seconds)
- Pros: adapts to volume automatically.
- Cons: variable batch close time makes force-include deadline computation harder and complicates force-include queue expiry logic.
- Why rejected: considered for v1.1. v1 uses simple fixed time windows.

## References
- ADR-0012 — zkVM matcher pivot
- ADR-0013 — SP1 zkVM framework (proof latency)
- ADR-0014 — sequencer trust model (force-include deadline)
