# How Lighter.xyz Works: A Complete Technical Deep-Dive

> Compiled from: Lighter whitepaper, docs.lighter.xyz, apidocs.lighter.xyz,
> Stanford Blockchain Review #77, zkSecurity audit report, L2Beat scaling +
> ZK catalog, elliottech/lighter-prover GitHub, Etherscan on-chain data,
> and independent technical analyses.
>
> Last updated: 2026-04-07

---

## Table of Contents

1. [What Lighter Actually Is](#1-what-lighter-actually-is)
2. [The Sequencer](#2-the-sequencer)
3. [The Matching Engine](#3-the-matching-engine)
4. [The State Model](#4-the-state-model)
5. [The ZK Proof Pipeline](#5-the-zk-proof-pipeline)
6. [The Prover Codebase](#6-the-prover-codebase)
7. [On-Chain Contracts (Ethereum L1)](#7-on-chain-contracts-ethereum-l1)
8. [Data Availability](#8-data-availability)
9. [The API Layer](#9-the-api-layer)
10. [Security Model](#10-security-model)
11. [Performance Numbers](#11-performance-numbers)
12. [What ZK Proves and What It Doesn't](#12-what-zk-proves-and-what-it-doesnt)

---

## 1. What Lighter Actually Is

Lighter is marketed as an "on-chain CLOB," but that framing is misleading.
Lighter is a **centralized matching engine with ZK-proven execution
integrity**. The sequencer matches orders off-chain in memory, then
generates ZK proofs that the matching was done correctly. These proofs are
verified on Ethereum L1.

The architecture:

```
Trader ──ws/rest──> Sequencer (centralized, off-chain)
                        │
                   match in memory (~5ms soft finality)
                        │
                   send receipt to trader
                        │
                   Witness Generator (transforms execution data)
                        │
                   Lighter Prover (generates ZK proofs)
                        │
                   Proof Aggregation (recursive compression)
                        │
                   Ethereum L1: commitBatch → verifyBatch → executeBatches
                        │
                   Canonical state root updated on-chain
```

There are no smart contracts doing matching. The EVM is used solely for
proof verification, state root anchoring, deposits, withdrawals, and the
escape hatch.

**Key numbers:**
- Soft finality: ~5ms
- User-facing latency: 0-300ms (depends on account tier)
- L1 settlement: every ~2-5 minutes
- TVS: ~$714M
- Daily operations: ~1,860 user operations (L2Beat)
- Throughput claim: ~500M orders+cancellations/day
- L1 cost per batch cycle: ~$0.19

---

## 2. The Sequencer

### Order Reception

Both WebSocket and REST:
- **REST**: `POST https://mainnet.zklighter.elliot.ai/api/v1/sendTx`
  (single) or `/sendTxBatch` (up to 15 txs)
- **WebSocket**: `wss://mainnet.zklighter.elliot.ai/stream`, channels
  `jsonapi/sendtx` and `jsonapi/sendtxbatch`

### Internal Order Flow

1. User signs transaction with API key private key (binary signer, EdDSA
   on ECgFp5 curve for L2 txs, ECDSA secp256k1 for L1 auth)
2. API servers accept the tx (HTTP 200 means syntax valid, NOT execution
   guaranteed)
3. Sequencer receives transaction, executes against in-memory state in FIFO
   order
4. Sequencer provides soft finality (~5ms)
5. Execution data fed to Indexer (for API/WebSocket distribution) and
   Witness Generator (for proof generation)

### FIFO Ordering

The sequencer "coordinates first-in-first-out transaction ordering."
However, **FIFO is a policy, not a cryptographic guarantee**. The
sequencer is a single centralized operator that determines ordering.

> "The proofs verify that execution was correct given the ordering, not
> that the ordering itself was fair."
> — Stanford Blockchain Review #77

The sequencer can front-run, reorder, or selectively delay orders while
still producing perfectly valid proofs.

### Latency Throttling (Standard vs Premium)

Lighter monetizes through artificial latency, not trading fees:

| Account Type | Maker/Cancel | Taker | Trading Fees |
|---|---|---|---|
| Standard (default) | 200ms delay | 300ms delay | 0% / 0% |
| Premium (0 LIT staked) | 0ms | 200ms | 0.002% / 0.02% |
| Premium (500K LIT staked) | 0ms | 140ms | 0.0014% / 0.014% |

Standard accounts pay zero fees but get intentionally delayed execution.
Analysis from Leviathan News: "the hidden cost of slower executions makes
these trades 5-10x more expensive than premium accounts."

Premium tiers based on LIT staking: 0 / 1K / 3K / 10K / 30K / 100K /
300K / 500K LIT, with taker latency improvements from 200ms → 140ms and
fee discounts from 0% → 30%.

Rate limits also scale with staking:
- Builder tier: 240,000 weighted requests/min
- Premium: 24,000 weighted requests/min
- Standard: 60 requests/min
- SendTx: 4,000/min (0 LIT) → 40,000/min (500K LIT)

### Sequencer Failure

Three recovery paths:

1. **Priority Queue**: Users can submit priority requests (withdrawals,
   pool exits, reduce-only IOC orders) directly to Ethereum L1. The
   sequencer MUST process these within the timeframe or face penalties.

2. **Escape Hatch (Desert Mode)**: If the sequencer fails to process
   priority requests within **14 days**, the contract freezes entirely.
   Users can exit via ZK proofs against the frozen state root.

3. **Observed incident**: 4.5 hours of downtime on October 10, 2025, due
   to database growth issues. Users could not trade during this period.

---

## 3. The Matching Engine

### Price-Time Priority

When a taker order arrives, the matching engine finds the highest-priority
maker order (best price, ties broken by oldest order first). Execution at
the maker's price.

Price-time priority is **cryptographically enforced** within batches via
ZK proofs. The orderbook tree encodes priority directly into Merkle tree
leaf indices — traversing the tree naturally encounters orders in
price-time order. Single leaf access for matching operations, O(log N) for
insertion/removal.

> "Most zk-rollup orderbooks only verify that two orders intersected at a
> valid price without enforcing maker selection fairness." Lighter goes
> further — it proves that the best-price, oldest maker was always selected.
> — Stanford Blockchain Review #77

### Order Types

| Code | Type | Description |
|------|------|-------------|
| 0 | LIMIT | Standard limit order |
| 1 | MARKET | Market order (fill at best available) |
| 2 | STOP_LOSS | Triggers market sell when mark price ≤ trigger |
| 3 | STOP_LOSS_LIMIT | Triggers limit order when stop triggered |
| 4 | TAKE_PROFIT | Triggers market sell when mark price ≥ trigger |
| 5 | TAKE_PROFIT_LIMIT | Triggers limit order when TP triggered |
| 6 | TWAP | Time-weighted average price order |
| 7 | TWAPSubOrder | Internal — individual TWAP chunk |
| 8 | LiquidationOrder | Internal — liquidation execution |

### Time-in-Force

| Code | Type | Description |
|------|------|-------------|
| 0 | IMMEDIATE_OR_CANCEL | Fill what you can, cancel the rest |
| 1 | GOOD_TILL_TIME | Rests on book until expiry |
| 2 | POST_ONLY | Maker only — rejected if would cross |

Options: Reduce-Only, Post-Only flags.

### TWAP

Places market orders every 30 seconds. Size per cycle = total /
number_of_orders. Number of orders = (execution_duration / 30s) + 1.

### Self-Trade Prevention

Trades between the same account cancel the resting (maker) order instead
of executing the trade.

### Fat Finger Prevention

Price guards enforced by the sequencer:
- Ask orders: `price >= max(markPrice, bestBid) * 0.95`
- Bid orders: `price <= min(markPrice, bestAsk) * 1.05`
- SL/TP limit orders use triggerPrice instead of markPrice

### Mark Price Formula

```
markPrice = Median(impactPrice_t, price1_t, price2_t)

where:
  impactPrice = (impactBid + impactAsk) / 2
  price1      = index + EMA_8min(clamp(impactPrice - index, -index/200, +index/200))
  price2      = median(CEX prices)

  Impact notional = 500 USDC / Initial Margin Fraction
```

### Partial Fills

Taker orders continue matching until fully filled or no crossing orders
remain. Unfilled limit orders enter the book at the specified price.

---

## 4. The State Model

### The Hypertree (Tree of Trees)

Lighter's entire state is a "hypertree" — a Merkle tree whose leaves are
themselves Merkle trees. The top-level tree hashes together the roots of
6 sub-trees into a single canonical state root.

```
                    State Root
                        │
        ┌───────┬───────┼───────┬───────┬───────┐
        │       │       │       │       │       │
   Account  AcctMeta  AcctOrder  OrderBook  Market  Pool
    Tree     Tree      Tree       Tree      Tree    Tree
```

### The 6 Merkle Trees

| # | Tree | Depth | Max Leaves | Contents |
|---|------|-------|-----------|----------|
| 1 | **Account Tree** | 48 | 2^48 | Asset holdings, position info, public pool shares. Each leaf contains enough info to reconstruct a user's complete state for exit purposes. |
| 2 | **Account Metadata Tree** | 48 | 2^48 | Amounts of assets locked in active orderbook orders. Split from Account Tree so order state updates don't require re-hashing the full account. |
| 3 | **Account Order Tree** | 60 | 2^60 | All active and pending orders per account: conditional orders, orderbook orders, TWAP orders. |
| 4 | **Orderbook Tree** | 80 | 2^80 | Price-time priority encoded in leaf indices (32-bit price + 48-bit nonce). Traversing tree = traversing in priority order. O(log N) for insert/remove, single leaf for matching. |
| 5 | **Market Tree** | 12 | 4,096 | Global market data (funding rates, mark prices, configs). |
| 6 | **Pool/Asset Trees** | 6-8 | 64-256 | Asset configs (6 levels, 64 assets), API keys (8 levels per account), position data (8 levels, 255 markets per account). |

### Hash Function

**Current: Poseidon2** over the Goldilocks field (p = 2^64 - 2^32 + 1).
Hash output is 4 Goldilocks field elements (256 bits total).

**Historical: MiMC** — the original implementation used an insecure
variant of MiMC that was found to have critical vulnerabilities in the
zkSecurity audit (see [Section 10](#10-security-model)). Migrated to
Poseidon2 after the audit.

The outer wrapper layer uses **PoseidonBN128** (Poseidon over BN254 scalar
field, width=4, rate=3, 8 full rounds, 56 partial rounds) to make the
proof SNARK-friendly for EVM verification.

### State Transitions

Each batch of operations transitions the state:

```
old_state_root + [tx_1, tx_2, ..., tx_n] → new_state_root
```

The ZK proof attests that:
1. The transition was computed correctly
2. All Merkle proofs within the batch are valid
3. Balance conservation holds (no funds created from thin air)
4. Matching followed price-time priority
5. Posted state diffs (blobs) are complete and consistent

---

## 5. The ZK Proof Pipeline

### Overview

Lighter uses a **hybrid STARK-to-SNARK pipeline** built on Plonky2:

```
┌─────────────────────────────────────────────────────────────────┐
│ Inner Layer: Plonky2 STARKs                                     │
│ Field: Goldilocks (p = 2^64 - 2^32 + 1)                        │
│ Commitment: FRI (hash-based, no trusted setup)                  │
│ Hash: Poseidon2                                                 │
│ Properties: Transparent, quantum-resistant at proof layer       │
│                                                                 │
│ This is where ALL the computation happens.                      │
│ Transaction proofs, recursion, aggregation — all Plonky2.       │
└────────────────────────────┬────────────────────────────────────┘
                             │
                    SNARK wrapping step
                             │
┌────────────────────────────▼────────────────────────────────────┐
│ Outer Layer: gnark PLONK over BN254                             │
│ Field: BN254 scalar field                                       │
│ Commitment: KZG (trusted setup: Aztec Ignition, 176 participants)│
│ Hash: PoseidonBN128                                             │
│ Properties: Cheap EVM verification via ecPairing precompile     │
│                                                                 │
│ This layer exists ONLY to make the proof EVM-verifiable.        │
│ A raw STARK would cost 2-5M gas. The SNARK wrapper: ~230k gas.  │
└─────────────────────────────────────────────────────────────────┘
```

**Why two layers?**

The Goldilocks field (64-bit elements) allows extremely efficient CPU
arithmetic — ~40x faster proving than 256-bit fields. But EVM only has
precompiles for BN254 curve operations (ecPairing at address 0x08). So the
bulk of the proving happens in the fast Goldilocks field, then a thin
wrapper converts the final proof into a BN254 SNARK that the EVM can
verify cheaply.

### The Full Pipeline

```
1. SEQUENCER executes transactions
   ↓
2. WITNESS GENERATOR transforms execution data into circuit inputs
   ↓
3. TRANSACTION PROOFS (parallel, one per ~5 txs)
   ↓ BlockTxCircuit
4. BLOCK TX CHAINS (sequential within a block)
   ↓ BlockTxChainCircuit
5. BLOCK PROOFS (one per block)
   ↓ BlockCircuit
6. SEGMENT AGGREGATION (cyclic recursion, up to 8 segments per batch)
   ↓ CyclicRecursionCircuit
7. DELTA AGGREGATION (parallel, 225 account deltas per proof)
   ↓ DeltaCircuit → CyclicDeltaCircuit
8. BLOB EVALUATION (EIP-4844 polynomial commitment)
   ↓ BlobEvaluationCircuit
9. INNER WRAPPER (merges: 8 segments + 1 delta chain + 1 blob eval)
   ↓ WrapperInnerCircuit (Poseidon2 hash)
10. OUTER WRAPPER (hash function switch: Poseidon2 → PoseidonBN128)
    ↓ WrapperOuterCircuit
11. SNARK WRAP (gnark: Plonky2 proof → BN254 PLONK SNARK)
    ↓ gnark VerifierCircuit
12. ETHEREUM L1 VERIFICATION (~230k gas)
    ↓ ZkLighterVerifier contract
    → State root updated
```

### Step-by-Step Detail

**Step 3: BlockTxCircuit**

Processes a fixed-size batch of transactions (default: 5 txs per proof).
This is where the heavy lifting happens. The circuit:
- Verifies transaction signatures (ECDSA secp256k1 for L1 txs, EdDSA
  ECgFp5 for L2 txs)
- Applies each transaction to the state tree (Merkle proof updates)
- Verifies matching correctness (price-time priority)
- Checks balance conservation
- Handles all 47 transaction types (order placement, cancellation,
  matching, liquidation, deposit, withdrawal, TWAP, pool operations, etc.)

These proofs are **generated in parallel** across transactions.

**Step 4: BlockTxChainCircuit**

Chains multiple BlockTx proofs sequentially within a single block. Each
step verifies the previous chain proof + a new BlockTx proof, ensuring
state continuity (output state of step N = input state of step N+1).

**Step 5: BlockCircuit**

Combines a BlockPreExecution proof (market state validation, metadata
checks) with a BlockTxChain proof into a single block proof.

**Step 6: CyclicRecursionCircuit**

Aggregates block proofs into "segments" via cyclic recursion. Each step
verifies the previous cyclic proof + a new BlockCircuit proof. Aggregates
batch data: state roots, on-chain operations hash, priority operations
hash, timestamps, market details. Up to 8 segments per batch.

**Step 7: DeltaCircuit + CyclicDeltaCircuit**

Processes 225 account deltas at a time. Verifies Merkle proofs for account
delta leaves, packs state diffs into compressed format, evaluates a
polynomial over the compressed data for blob commitment. The cyclic
variant chains multiple delta proofs.

**Step 8: BlobEvaluationCircuit**

EIP-4844 blob polynomial evaluation. Works over the BLS12-381 scalar
field. Verifies that the KZG versioned hash matches and the polynomial
opening is correct.

**Steps 9-10: Wrapper Circuits**

The inner wrapper verifies up to 8 segment proofs, 1 delta chain proof,
and 1 blob evaluation proof. Computes the batch commitment hash (keccak of
all batch data + blob commitment). Uses Poseidon2 internally.

The outer wrapper re-proves the inner proof, switching from Poseidon2 to
PoseidonBN128, making the proof BN254-friendly for the SNARK wrapping
step.

**Step 11: gnark SNARK Wrapping**

A gnark circuit (`gnark-plonky2-verifier`) verifies the outer Plonky2
proof on BN254. Produces a PLONK SNARK with a single public input: the
256-bit batch commitment. This is what gets verified on Ethereum.

### Recursion Tree (Visual)

```
BlockTx(5 txs) ──> BlockTxChain ──> BlockCircuit (1 block)
                                         │
                              CyclicRecursion (segment)
                              [up to 8 segments per batch]
                                         │
DeltaCircuit(225 accts) ──> CyclicDelta ─┤
                                         │
BlobEvaluation ──────────────────────────┤
                                         │
                              WrapperInner (Poseidon2)
                                         │
                              WrapperOuter (PoseidonBN128)
                                         │
                              gnark VerifierCircuit (BN254 PLONK)
                                         │
                              Solidity Verifier → EVM verification
```

### Cryptographic Primitives Used in Circuits

| Primitive | Purpose | Location |
|-----------|---------|----------|
| Poseidon2 (Goldilocks) | All Merkle trees, state hashing | Inner layer |
| PoseidonBN128 | Outer wrapper hash (EVM-friendly) | Outer wrapper |
| Keccak-256 | Batch commitment, on-chain ops hash | Both layers |
| ECDSA (secp256k1) | L1 transaction signature verification | BlockTxCircuit |
| EdDSA/Schnorr (ECgFp5) | L2 transaction signature verification | BlockTxCircuit |
| BLS12-381 field ops | EIP-4844 blob polynomial evaluation | BlobEvaluation |

**ECgFp5** is a Plonky2-native elliptic curve over GF(p^5), a quintic
extension of the Goldilocks field. It is dramatically cheaper to verify
in-circuit than secp256k1 ECDSA. Lighter uses custom gates
(`QuinticMultiplicationGate`, `QuinticSquaringGate`) for efficient ECgFp5
arithmetic.

### Trusted Setup

The outer SNARK layer uses the **Aztec Ignition ceremony** (2019, 176
publicly open participants) for KZG commitments over BN254. L2Beat rates
this as lowest risk (1-of-N honest assumption).

Verification artifacts: `github.com/AztecProtocol/ignition-verification`

The inner STARK layer requires **no trusted setup** — FRI commitment is
hash-based and transparent.

---

## 6. The Prover Codebase

### Repository: `github.com/elliottech/lighter-prover`

- Language: 99.4% Rust, Go for SNARK wrapper
- 8 commits, single contributor (`lighter-devs`)
- License: not specified

### Structure

```
lighter-prover/
├── Cargo.toml              # Rust workspace (members: circuit, bench)
├── go.mod                  # Go module for gnark SNARK wrapper
├── build_circuits.sh       # Full pipeline build script
├── rust-toolchain          # Rust edition
│
├── circuit/                # Core circuit library + 5 build binaries
│   └── src/
│       ├── bin/            # 5 build binaries:
│       │   ├── build_block_circuit.rs
│       │   ├── build_recursion_circuit.rs
│       │   ├── build_delta_circuit.rs
│       │   ├── build_delta_recursion_circuit.rs
│       │   └── build_wrapper_circuit.rs
│       │
│       ├── bigint/         # BigInt/BigUint arithmetic in-circuit
│       ├── blob/           # EIP-4844 blob evaluation (BLS12-381)
│       ├── delta/          # Account delta tree + cyclic recursion
│       ├── ecdsa/          # secp256k1 ECDSA verification
│       ├── eddsa/          # ECgFp5 Schnorr signatures
│       ├── keccak/         # Keccak-256 in-circuit
│       ├── poseidon2.rs    # Re-exports Plonky2's Poseidon2
│       ├── poseidon_bn128/ # Poseidon over BN254 (outer wrapper)
│       ├── recursion/      # Cyclic recursion + wrapper circuits
│       ├── signed/         # Signed integer arithmetic
│       ├── transactions/   # 47 transaction type constraint modules
│       ├── types/          # Data types, constants, config
│       ├── uint/           # u4, u8, u16, u32, u48 gadgets
│       │
│       ├── block_tx_constraints.rs
│       ├── block_tx_chain_constraints.rs
│       ├── block_pre_execution_constraints.rs
│       └── block_constraints.rs
│
├── bench/                  # Benchmark binary (proves block from JSON)
│   └── bench_test.json
│
└── snark/                  # Go gnark SNARK wrapper
    ├── main.go             # CLI: compile R1CS, Plonk setup, export .sol
    ├── circuit/
    │   └── circuit.go      # gnark VerifierCircuit definition
    └── builder/            # R1CS compilation, SRS helpers
```

### Build Pipeline (`build_circuits.sh`)

Parameters: `TX_PER_PROOF=5`, `DELTA_ACCOUNT_COUNT=225`, `CHAIN_ID=304`

```bash
# Step 1: Build block-level circuits
build_block_circuit
  → block-pre-execution-circuit.bin
  → block-tx-circuit.bin
  → block-tx-chain-circuit.bin
  → block-circuit.bin

# Step 2: Build recursion circuit (takes block-circuit.bin)
build_recursion_circuit
  → cyclic-circuit.bin

# Step 3: Build delta circuit (225 accounts)
build_delta_circuit
  → delta-circuit.bin

# Step 4: Build delta recursion (takes delta-circuit.bin)
build_delta_recursion_circuit
  → cyclic-delta-circuit.bin

# Step 5: Build wrapper circuits (takes cyclic + delta circuits)
build_wrapper_circuit
  → Builds BlobEvaluation, WrapperInner, WrapperOuter
  → Outputs wrapper circuit JSON data

# Step 6: gnark SNARK wrapping (Go)
go run snark/main.go
  → Downloads Aztec Ignition SRS (power 174, ~2^17 constraints)
  → Compiles gnark R1CS over BN254
  → Runs PLONK setup
  → Exports .pk, .vk, and ZkLighterVerifier.sol
```

### Key Dependencies

**Rust:**
- `plonky2` — Elliot's fork (`github.com/elliottech/plonky2`, rev
  `e1c2d35`). Provides Poseidon2GoldilocksConfig, cyclic recursion, FRI,
  all custom gates.
- `ff` — Finite field traits (for BN128 Poseidon)
- `rayon` — Proof parallelism
- `sha2`, `tiny-keccak` — Hashing
- `serde`, `bincode` — Serialization

**Go:**
- `gnark v0.14.0` — PLONK backend
- `gnark-crypto v0.19.0` — BN254 KZG, SRS handling
- `gnark-plonky2-verifier v0.0.7` — Elliot's Plonky2 verifier in gnark
  (`github.com/elliottech/gnark-plonky2-verifier`)

### Hardware Requirements

~100GB RAM for circuit generation (L2Beat ZK Catalog assessment).

---

## 7. On-Chain Contracts (Ethereum L1)

### Contract Map

| Contract | Address | Purpose |
|----------|---------|---------|
| **ZkLighter** (proxy) | `0x3B4D794a66304F130a4Db8F2551B0070dfCf5ca7` | Main L2 contract |
| ZkLighter (impl) | `0xe315cbedc21c5bec186bf478d899e91a604a6bc8` | Implementation (Sol 0.8.25) |
| **ZkLighterVerifier** (proxy) | `0xac3Ce44B6ff4E402858C99D5699ff63131572BaA` | Proof verifier |
| ZkLighterVerifier (impl) | `0xb20De28D78b63bc0c94eef89Db53F6338af17825` | Verified by L2Beat |
| **DesertVerifier** | `0xd4460475F00307845082d3a146f36661354FBc67` | Escape hatch verifier |
| **UpgradeGatekeeper** | `0x94da8A995D0D82Ef0fE7E509C6D76c22603B6f67` | 21-day timelock |
| **Governance** | `0xa464DA0B43f80EE3FfC4795cbbFC78472b5c81A1` | Network governor |
| **Lighter Multisig** | (3/5 threshold) | Can bypass timelock |

### Main Contract Holdings

~$715.2M total:
- USDC: $495M (69.2%)
- LIT: $216M (30.3%)
- ETH: $3.5M (0.5%)
- 54 tokens total

### The Three-Phase Batch Lifecycle

**Phase 1: `commitBatch(CommitBatchInfo, StoredBatchInfo)`**

The sequencer posts:
- New state root
- Blob data with compressed per-account state changes
- Processed priority requests
- Withdrawal messages
- Batch metadata (batchNumber, endBlockNumber, timestamps)

The contract computes and stores the commitment. Cost: ~$0.11 avg
(variable: $0.02-0.37 depending on blob data size).

**Phase 2: `verifyBatch(StoredBatchInfo, bytes proof)`**

The prover submits the SNARK proof for a committed batch. The contract
calls the ZkLighterVerifier to verify the proof against the stored
commitment. Cost: ~$0.06 avg (remarkably consistent — SNARK verification
is constant-cost regardless of batch size).

**Phase 3: `executeBatches(StoredBatchInfo[], bytes[])`**

After verification, executes pending on-chain actions:
- Process withdrawal transfers
- Update canonical state root
- Clear pending priority requests

Cost: ~$0.02 avg.

**Full cycle cost: ~$0.19 per batch.**

### Batch Frequency

From Etherscan observations (April 7, 2026):
- ~67 batch cycles per hour
- ~1,600 L1 transactions per day (recent)
- Historical average: ~3,182 L1 txs/day
- New batch every ~2-5 minutes

With ~1,860 daily user operations (L2Beat), that's ~28 L2 operations per
batch, at ~$0.007 L1 cost per L2 operation.

### Other Key Functions

| Function | Purpose |
|----------|---------|
| `deposit(...)` | L1 → L2 deposit. User approves token → calls deposit → sequencer observes → updates internal state. |
| `withdraw(...)` | L2 → L1 withdrawal. Sequencer processes → state root updated → contract unlocks funds. |
| `changePubKey(...)` | Associates API key with account (L1 auth → L2 key binding). |
| `activateDesertMode()` | Triggers escape hatch when sequencer fails. |
| `performDesert(...)` | Users submit ZK proof of balance to withdraw without sequencer. |
| `revertBatches(...)` | Revert uncommitted batches (admin). |

### Deposits

1. User approves token transfer to ZkLighter contract
2. Calls `deposit()` with amount and account index
3. Sequencer observes L1 deposit event
4. Updates internal state root (credits user's L2 account)
5. User can trade

### Withdrawals

Three paths:

1. **Normal**: Submit via Lighter platform → sequencer processes → included
   in next batch → state root updated → `executeBatches` unlocks funds on
   L1.

2. **Priority Queue**: Submit withdrawal directly to L1 priority queue →
   sequencer MUST process within timeframe → if not processed, triggers
   escape hatch countdown.

3. **Fast Withdrawal**: `POST /api/v1/fastwithdraw` — requires wallet's
   Ethereum private key. Processed faster but requires more trust.

### Verification Key Management

VKs are embedded within the Solidity verifier contract generated by
`build_circuits.sh`. Verifier ID = SHA256 hash of all VK values,
ABI-packed.

---

## 8. Data Availability

### EIP-4844 Blobs

Lighter posts compressed state diffs to Ethereum as EIP-4844 data blobs
alongside each `commitBatch` transaction.

**Blob contents:**
- Per-account collateral changes (delta encoding)
- Position adjustments (entry prices, quantities)
- Order cancellations/placements
- Funding settlements
- Global market info (funding rates, mark prices)

**Key properties:**
- Only data that leads to state changes is posted (state diffs, not full
  transaction history)
- Highly compressed — enables high-scale publishing without third-party DA
- **Proof enforces DA completeness**: a valid proof cannot be generated if
  the blob data is incomplete or inconsistent
- All data needed to reconstruct user state and generate exit proofs is
  available on-chain

### Blob Persistence

Blobs are ephemeral on the Beacon Chain (~18 days). However:
- KZG commitments to blobs remain permanently on L1
- For the escape hatch to work, users must download blob data before
  expiry (or from archival services)
- The 14-day escape hatch window fits within blob availability window

### Blob Costs

From `commitBatch` fee variance:
- Small batches ($0.02): likely no blobs (state diff fits in calldata)
- Large batches ($0.37): 1+ blobs with substantial state diffs
- Average: ~$0.11 per commit

---

## 9. The API Layer

### REST API

Base URL: `https://mainnet.zklighter.elliot.ai`

60+ endpoints organized by category:

**Account:**
`account`, `accountMetadata`, `accountsByL1Address`, `accountLimits`,
`apikeys`, `tokens/*`

**Trading:**
`sendTx`, `sendTxBatch`, `nextNonce`

**Market Data:**
`orderBooks`, `orderBookDetails`, `orderBookOrders`, `candles` (max 500),
`recentTrades`, `trades`, `exchangeStats`, `exchangeMetrics`

**Positions:**
`liquidations`, `positionFunding`, `pnl`

**Deposits/Withdrawals:**
`deposit/history`, `deposit/latest`, `withdraw/history`,
`withdrawalDelay`, `fastwithdraw`, `fastwithdraw/info`

**System:**
`systemConfig`, `tokenlist`, `announcement`, `layer1BasicInfo`,
`executeStats`, `block`, `blocks`, `currentHeight`, `blockTxs`

### WebSocket

URL: `wss://mainnet.zklighter.elliot.ai/stream`

Configuration:
- Keepalive: every 2 minutes
- Compression: `permessage-deflate`
- Read-only mode: append `?readonly=true`
- Max 100 connections/IP, 1000 total subscriptions, 200 messages/min

**Public channels:**
- `order_book/{MARKET_INDEX}` — updates batched every 50ms
- `ticker/{MARKET_INDEX}` — best bid/offer
- `market_stats/{MARKET_INDEX}` or `market_stats/all`
- `trade/{MARKET_INDEX}`
- `height` — block height updates
- `spot_market_stats/{MARKET_INDEX}`

**Authenticated channels:**
- `account_all/{ACCOUNT_ID}`
- `account_market/{MARKET_ID}/{ACCOUNT_ID}`
- `account_tx/{ACCOUNT_ID}`
- `account_all_orders/{ACCOUNT_ID}`
- `account_all_trades/{ACCOUNT_ID}`
- `account_all_positions/{ACCOUNT_ID}`
- `account_all_assets/{ACCOUNT_ID}`
- `notification/{ACCOUNT_ID}`
- `pool_data/{ACCOUNT_ID}`

### Authentication

API keys are private keys (indices 0-254, 0-3 reserved for UI). Auth
token format: `{expiry_unix}:{account_index}:{api_key_index}:{random_hex}`
(max 8hr expiry).

L1 auth: ECDSA (secp256k1) — standard Ethereum signatures.
L2 tx signing: EdDSA on ECgFp5 curve — cheaper to verify in ZK circuits.

### SDKs

- Python: `lighter-sdk` on PyPI
- Go: `lighter-go` on GitHub (includes binary signer)

---

## 10. Security Model

### What ZK Proofs Guarantee

1. **Execution integrity** — every state transition was computed correctly
2. **Price-time priority** — within each batch, the best maker was always
   selected (encoded in orderbook tree leaf indices)
3. **Balance conservation** — no funds created from thin air, all
   transfers net to zero
4. **Data sufficiency** — posted blob data is complete enough to
   reconstruct all user states
5. **Merkle consistency** — all state tree updates produce valid trees

### What ZK Proofs Do NOT Guarantee

1. **Ordering fairness** — the sequencer determines transaction order. It
   can front-run, sandwich, or selectively delay orders while producing
   valid proofs.
2. **Censorship resistance** — the sequencer can drop orders entirely.
   Mitigation: 14-day forced inclusion via L1 priority queue.
3. **Liveness** — if the sequencer goes down, trading stops. Mitigation:
   desert mode after 14 days.
4. **Oracle accuracy** — circuits verify computation with supplied price
   data, not whether the price data is correct.
5. **Privacy** — all state diffs are published on-chain.

### Audits

| Auditor | Scope | Date |
|---------|-------|------|
| zkSecurity | ZK circuits (3 weeks, 2 consultants) | Jan 22, 2024 |
| Nethermind | Lighter Core | Sep 22, 2025 |
| Nethermind | EVM Deposit Bridge | Sep 22, 2025 |
| Block Audit | (unspecified) | Apr 8, 2025 |
| Block and Delta | (unspecified) | Aug 9, 2025 |
| (unnamed) | Wrapper circuits | Oct 10, 2025 |
| (unnamed) | Desert exit circuits | Nov 5, 2025 |
| (unnamed) | Spot circuits | Nov 24, 2025 |

### zkSecurity Findings (January 2024)

**Two CRITICAL findings** related to MiMC hash function:

The original implementation used an "insecure variant of the
Miyaguchi-Preneel construction" for MiMC. The vulnerability:

> "One can find a second preimage with an arbitrary half of the input
> (which is of size 2 in zkLighter), as long as they know the other half
> of the input being used as key (which is always the case in zkLighter)."

Impact: The prover could forge Merkle proofs — fabricating state
transitions that never happened.

Recommendation: Migrate to Poseidon sponge construction. **Fixed** —
Lighter migrated to Poseidon2.

### L2Beat Risk Assessment

| Category | Rating | Detail |
|----------|--------|--------|
| State Validation | Green | SNARKs ensure state correctness |
| Data Availability | Green | All state diffs on-chain (blobs) |
| Sequencer Failure | Green | Force-include via L1; 14-day exit hatch |
| Proposer Failure | Green | Trustless exit via ZK proof |
| **Exit Window** | **Red** | No delay on upgrades (multisig override) |

**Stage: 0** (not Stage 1 or 2)

Missing Stage 1 requirements:
- No 7+ day exit window for upgrades
- Security Council doesn't meet requirements (needs 8+ members, 75%+
  threshold)

### Critical Risks

1. **Instant upgradability**: The Lighter Multisig (3/5) can reduce the
   21-day upgrade delay to **zero seconds**. This means 3 of 5 signers can
   push a malicious upgrade with no exit window for users.

2. **Desert mode verifier unverified**: The DesertVerifier circuit source
   code is not publicly available. L2Beat cannot verify that the escape
   hatch actually works correctly.

3. **Centralized operators**: Three EOAs control batch
   commit/verify/execute. They can extract MEV.

4. **Oracle risk**: External index price oracles (Stork primary) not
   verified on-chain — sequencer is trusted for price data.

5. **TVS concentration**: LIT token = 30.1% of total value secured. LIT
   price collapse could destabilize the protocol.

### Threat Model Summary

| Threat | Severity | Mitigation |
|--------|----------|------------|
| Sequencer front-runs trades | High | None (ZK doesn't prevent this) |
| Sequencer censors users | Medium | Priority queue → 14-day exit |
| Malicious contract upgrade | Critical | None (instant upgrade possible) |
| Oracle manipulation | High | Median of multiple sources |
| Sequencer downtime | Medium | Desert mode after 14 days |
| Prover forge (hash weakness) | Critical | Fixed (MiMC → Poseidon2) |
| Trusted setup compromise | Low | 176 participants, 1-of-N honest |

---

## 11. Performance Numbers

### Throughput

| Metric | Value | Source |
|--------|-------|--------|
| Throughput claim | ~500M orders+cancellations/day | Technical comparison article |
| Implied ops/sec | ~5,787 ops/sec average | Calculated from 500M/day |
| Docs claim | "Tens of thousands of orders and cancels per second" | Lighter docs |
| Observed daily operations | ~1,860 user operations | L2Beat |
| Beta daily volume | Up to $1-2B | Public reports |

The gap between "500M orders/day" capacity and "1,860 daily operations" is
significant. Most of the 500M figure likely includes internal operations
(TWAP sub-orders, liquidation orders, market maker quote refreshes) rather
than unique user trades.

### Latency

| Metric | Value | Source |
|--------|-------|--------|
| Sequencer execution | ~5ms | Stanford Blockchain Review |
| Standard account (maker) | 200ms | API docs |
| Standard account (taker) | 300ms | API docs |
| Premium account (maker) | 0ms | API docs |
| Premium account (taker, max stake) | 140ms | API docs |
| WebSocket order book updates | Every 50ms | API docs |

### On-Chain Costs

| Operation | Avg Cost (USD) | Gas Range |
|-----------|---------------|-----------|
| commitBatch | $0.11 | Variable (blob-dependent) |
| verifyBatch | $0.06 | ~230k-500k gas (consistent) |
| executeBatches | $0.02 | Minimal |
| **Full batch cycle** | **$0.19** | — |
| **Per L2 operation** | **$0.007** | ~28 ops/batch |

### Infrastructure

| Metric | Value |
|--------|-------|
| Prover RAM requirement | ~100GB |
| Batch frequency | Every ~2-5 minutes |
| L1 transactions/day | ~1,600 (recent) to 3,182 (historical avg) |
| Mainnet launch | October 2, 2025 |
| Known downtime | 4.5h on Oct 10, 2025 (DB issues) |

---

## 12. What ZK Proves and What It Doesn't

This is the most important section. Understanding this distinction is
critical for anyone building on or competing with Lighter.

### The Proof Guarantees

When you see a verified batch on Ethereum, you know with mathematical
certainty that:

1. **Every state transition was computed correctly.** If the sequencer said
   Alice's order matched Bob's order at price X, then the circuit verified
   that X was a valid crossing price, Alice had sufficient margin, Bob's
   order was at that price, and the resulting positions/balances are
   correct.

2. **Price-time priority was respected within the batch.** The orderbook
   tree structure enforces this — matching operations traverse leaves in
   priority order. The circuit proves the traversal was done correctly.

3. **No money was created or destroyed.** Every transfer nets to zero. Fees
   are accounted for. Insurance fund flows are proven.

4. **The posted data is sufficient.** You could reconstruct the entire
   state from the blob data. The circuit proves this.

### The Proof Does NOT Guarantee

1. **Fair ordering.** The sequencer chose which transactions to include and
   in what order. It could have front-run Alice's large buy by inserting
   its own buy first. The proof only says "given this ordering, execution
   was correct." The ordering itself is not proven fair.

2. **Timely inclusion.** The sequencer could delay Alice's order by
   300ms (standard accounts) or arbitrarily (by simply not including it).
   The proof doesn't include timestamps of when orders were received.

3. **Correct oracle prices.** The sequencer supplies price data to the
   circuits. If the sequencer feeds manipulated prices, the circuit will
   faithfully prove the wrong liquidation.

4. **Liveness.** If the sequencer stops, no new proofs are generated. The
   14-day exit hatch is the only recourse.

### The Fundamental Tension

Lighter achieves <10ms latency by centralizing the sequencer. The ZK
proofs verify execution correctness but not ordering fairness. This is
the same trust model as a centralized exchange, except:

- You can **verify** that trades were computed correctly (a CEX is a black
  box)
- You can **exit** if the operator misbehaves (a CEX can freeze your
  funds)
- Your funds are **custodied on Ethereum** (a CEX holds your funds)

The ZK proofs make Lighter a **verifiable** centralized exchange, not a
**decentralized** exchange. This is still a meaningful improvement over a
pure CEX, but it is not trustless in the way that, say, Uniswap is
trustless.

---

## Appendix A: Comparison with Gaekju's Current Architecture

| Dimension | Lighter | Gaekju (current) |
|-----------|---------|-------------------|
| Matching | Off-chain sequencer | On-chain (EVM) |
| Latency | ~5ms soft finality | ~2s (block time) |
| State storage | Off-chain Merkle trees | On-chain (EVM storage) |
| Verification | ZK proofs on L1 | Deterministic EVM execution |
| Trust model | Trust sequencer ordering | Trust sequencer ordering |
| Orderbook encoding | Merkle tree (leaf index = priority) | Bitmap (bit = price level active) |
| Proof system | Plonky2 STARK → gnark PLONK SNARK | None (EVM is the proof) |
| Gas per trade | ~$0.007 (amortized over batch) | ~$0.01-0.05 (per tx) |
| L1 settlement | Every ~2-5 min (batch) | Every ~2s (every block) |
| Exit mechanism | Desert mode (14-day delay) | Standard L2 withdrawal |

### What Gaekju Gets Right That Lighter Doesn't

1. **Simpler architecture**: No proof pipeline, no witness generator, no
   prover infrastructure. The EVM IS the verifier.
2. **Immediate finality**: Every match is final in the same block. No
   waiting for batch proofs.
3. **No trusted setup**: No Aztec Ignition ceremony dependency.
4. **Open, verifiable matching**: Anyone can simulate the EVM execution and
   verify matching. No circuit code to audit.

### What Lighter Gets Right That Gaekju Doesn't

1. **Sub-10ms latency**: Orders confirmed in milliseconds, not seconds.
2. **Scalable throughput**: Matching isn't bounded by gas limits.
3. **Cheaper at scale**: Batch amortization makes per-trade costs
   negligible.
4. **Rich order types**: TWAP, conditional orders, etc. — feasible because
   matching isn't gas-constrained.

---

## Appendix B: Key Sources

1. [Lighter Docs: Technical Architecture](https://docs.lighter.xyz/about-lighter/technical-architecture-lighter-core)
2. [Stanford Blockchain Review #77: Shedding the Light(er)](https://review.stanfordblockchain.xyz/p/77-shedding-the-lighter-the-fine)
3. [zkSecurity Audit Report (PDF)](https://blog.zksecurity.xyz/2024-lighter-zklighter-report.pdf)
4. [L2Beat: Lighter Scaling](https://l2beat.com/scaling/projects/lighter)
5. [L2Beat: ZK Catalog — LighterProver](https://l2beat.com/zk-catalog/lighterprover)
6. [GitHub: elliottech/lighter-prover](https://github.com/elliottech/lighter-prover)
7. [GitHub: elliottech/plonky2](https://github.com/elliottech/plonky2) (fork)
8. [Lighter API Docs](https://apidocs.lighter.xyz)
9. [Etherscan: ZkLighter Contract](https://etherscan.io/address/0x3b4d794a66304f130a4db8f2551b0070dfcf5ca7)
10. [Medium: Technical Architecture Comparison](https://medium.com/@gwrx2005/technical-architecture-comparison-hyperliquid-dydx-and-lighter-xyz-2fd005854a7e)
11. [Polygon: Plonky2 Deep Dive](https://polygon.technology/blog/plonky2-a-deep-dive)
12. [Lighter FAQ](https://lighter.xyz/faq)
