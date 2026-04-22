# Glossary: Technical Terms in "How Lighter Works"

> Plain-language definitions for every technical term in the deep-dive.
> Organized by section, in the order they appear.

---

## Section 1: What Lighter Actually Is

**CLOB (Central Limit Order Book)**
A list of buy orders and sell orders sorted by price. Buyers and sellers
are matched by price — highest buyer meets lowest seller. "Central" means
one shared book (not fragmented). Every stock exchange and most crypto
exchanges use a CLOB.

**Sequencer**
The single computer that decides the order of transactions. Think of it as
the traffic controller — it decides who goes first. In Lighter, the
sequencer also runs the matching engine. It's centralized (one company
controls it).

**Soft Finality**
When the sequencer says "your trade is done" but it hasn't been proven on
Ethereum yet. It's "soft" because you're trusting the sequencer's word.
"Hard" finality comes when the ZK proof is verified on L1. Like getting a
verbal confirmation vs a signed receipt.

**ZK Proof (Zero-Knowledge Proof)**
A mathematical proof that says "I computed this correctly" without
revealing the full computation. Lighter uses it to prove: "I matched
1000 orders correctly" without Ethereum needing to re-execute all 1000
orders. The "zero-knowledge" part means the proof doesn't leak private
data, but in Lighter's case the primary goal is **succinctness** (small
proof for large computation), not privacy.

**State Root**
A single hash (like a fingerprint) that represents the ENTIRE state of
the exchange — every account balance, every open order, every position.
If even one number changes, the state root changes completely. Ethereum
stores this root, so anyone can verify the exchange's state.

**L1 (Layer 1)**
Ethereum mainnet. The base layer. Slow and expensive but maximally secure.
Lighter posts proofs here.

**L2 (Layer 2)**
A system built on top of L1 that processes transactions faster/cheaper,
then posts summaries or proofs back to L1. Lighter IS an L2.

**Canonical**
The "official" or "accepted" version. "Canonical state root" = the state
root that Ethereum considers the truth.

**TVS (Total Value Secured)**
Total dollar value of assets locked in the protocol's smart contracts.
Lighter has ~$714M TVS.

---

## Section 2: The Sequencer

**REST (Representational State Transfer)**
A way to talk to a server using standard HTTP requests (GET, POST, etc.).
You send a request, get a response. Like sending a letter and getting a
reply. Used for one-off operations like "place this order."

**WebSocket**
A persistent two-way connection between your computer and a server. Unlike
REST (send request → get response → connection closes), a WebSocket stays
open so the server can push updates to you in real-time. Used for live
price feeds, order updates, etc.

**FIFO (First In, First Out)**
Orders are processed in the order they arrive. First order received = first
order processed. Like a queue at a store. Lighter claims FIFO but the
sequencer can secretly reorder.

**EdDSA (Edwards-curve Digital Signature Algorithm)**
A way to digitally sign data (like signing a check, but cryptographic).
Used to prove "I authorized this order." EdDSA is faster and simpler than
ECDSA. Lighter uses EdDSA for L2 transactions because it's cheaper to
verify inside ZK circuits.

**ECDSA (Elliptic Curve Digital Signature Algorithm)**
The standard Ethereum signature scheme. Every Ethereum transaction uses
ECDSA. Lighter uses it for L1 interactions (deposits, key registration)
because that's what Ethereum wallets produce.

**ECgFp5**
A specific elliptic curve designed to be efficient inside Plonky2 circuits.
It lives in a "quintic extension" of the Goldilocks field (math trick to
get a secure curve in a small field). Lighter uses this for L2 signatures
because verifying ECgFp5 signatures in a ZK circuit is much cheaper than
verifying secp256k1 ECDSA.

**secp256k1**
The specific elliptic curve used by Ethereum (and Bitcoin) for signatures.
The "secp" = Standards for Efficient Cryptography, "256" = 256-bit, "k1"
= Koblitz curve variant 1.

**LIT**
Lighter's native token. Used for staking to get better latency and fee
discounts. Not a gas token — Lighter has no gas fees in the traditional
sense.

**Priority Queue**
A special queue on the L1 contract where users can submit emergency
transactions (withdrawals, etc.) directly to Ethereum, bypassing the
sequencer. The sequencer MUST process these within a deadline or the
escape hatch activates.

**Escape Hatch / Desert Mode**
Emergency exit mechanism. If the sequencer goes offline for 14 days, the
contract freezes and users can prove their balances and withdraw directly
from L1 without any help from the sequencer.

---

## Section 3: The Matching Engine

**Price-Time Priority**
The rule for who gets matched first: best price wins, and if two orders
have the same price, the older one wins. This is how NYSE, NASDAQ, and
most exchanges work.

**Maker**
A trader whose order adds liquidity to the book (their order rests on the
book waiting to be matched). Example: you place a limit buy at $100 when
the current price is $101 — your order sits on the book.

**Taker**
A trader whose order removes liquidity from the book (their order matches
immediately against resting orders). Example: you place a market buy —
it matches instantly against the best resting sell order.

**IOC (Immediate Or Cancel)**
An order that must be filled immediately (fully or partially). Whatever
doesn't fill is cancelled. No resting on the book.

**FOK (Fill Or Kill)**
An order that must be filled completely and immediately, or cancelled
entirely. No partial fills.

**GTC (Good Till Cancel)**
An order that stays on the book until it's either filled or you cancel it.
The default for limit orders.

**Post-Only**
An order that is guaranteed to be a maker order. If it would match
immediately (become a taker), it's rejected instead. Market makers use
this to ensure they always earn the maker rebate.

**Reduce-Only**
An order that can only reduce an existing position, not increase it or
open a new one. Safety feature to prevent accidentally doubling your
position.

**TWAP (Time-Weighted Average Price)**
An order that's split into many small pieces and executed over time. If
you want to buy $1M of BTC without moving the price, a TWAP spreads it
over, say, 30 minutes — one small buy every 30 seconds.

**Self-Trade Prevention**
A rule that prevents you from trading with yourself. If your buy order
would match your own sell order, the resting (maker) order is cancelled
instead of executing. Prevents wash trading.

**Fat Finger Prevention**
Guards against accidental extreme-price orders. If you try to sell at $1
when the market is at $60,000, the system rejects it. Lighter uses 5%
bounds around the current mark price.

**Mark Price**
A fair price estimate used for liquidations and risk calculations. Not
just the last trade price — it's a blend of the orderbook mid-price, an
index price, and CEX prices. Designed to resist manipulation.

**Impact Price**
The average price you'd get if you traded a specific notional amount
(e.g., $500). Used to measure how deep the liquidity is. If the impact
price is far from the mid-price, the book is thin.

**EMA (Exponential Moving Average)**
A type of average that gives more weight to recent data. An "8-minute EMA"
is an average that mostly reflects the last 8 minutes of data, with older
data fading away exponentially.

**Index Price**
A reference price from external sources (usually major CEX spot markets).
Used as an anchor so the perp price doesn't deviate too far from reality.

---

## Section 4: The State Model

**Merkle Tree**
A data structure where every piece of data is hashed, then pairs of hashes
are hashed together, then pairs of those, etc., until you get a single
hash at the top (the "root"). This lets you prove "this specific account
has $X" by providing a short "proof path" from the leaf to the root,
instead of showing the entire database.

```
         Root Hash
        /         \
    Hash(AB)    Hash(CD)
    /    \      /    \
  H(A)  H(B)  H(C)  H(D)   ← leaves (actual data)
```

**Hypertree (Tree of Trees)**
A Merkle tree whose leaves are themselves roots of other Merkle trees.
Lighter has 6 sub-trees, each with its own root. The top-level tree
hashes these 6 roots together into one state root.

**Leaf**
The bottom-most node in a Merkle tree. Contains actual data (an account
balance, an order, etc.).

**Depth**
How many levels deep the tree goes. A depth-48 tree has 2^48 possible
leaves (~281 trillion). More depth = more capacity but longer proof paths.

**Hash Function**
A function that takes any input and produces a fixed-size output
(fingerprint). Good hash functions are: (1) deterministic (same input =
same output), (2) fast, (3) impossible to reverse, (4) collision-resistant
(can't find two inputs with the same output).

**Poseidon2**
A hash function specifically designed to be efficient inside ZK circuits.
Regular hash functions like SHA-256 are expensive in circuits because they
use bitwise operations (XOR, rotation) that are awkward in arithmetic
circuits. Poseidon uses only field additions and multiplications — native
operations for ZK circuits. "Poseidon2" is an improved version.

**MiMC**
An older ZK-friendly hash function. Lighter originally used it but switched
to Poseidon2 after a security audit found critical vulnerabilities.

**PoseidonBN128 / PoseidonBN254**
Poseidon hash computed over the BN254 curve's scalar field (not the
Goldilocks field). Used only in Lighter's outer wrapper to make the proof
compatible with EVM verification. BN128 and BN254 refer to the same curve
(different naming conventions).

**State Diff**
Instead of posting the entire state, only post what changed. If Alice's
balance went from $100 to $95, the diff is "-$5 for Alice." Much smaller
than re-posting the entire state.

**Delta Encoding**
A way to represent changes as differences from the previous state. "Alice:
-5, Bob: +5" instead of "Alice: 95, Bob: 105." Compresses well because
most accounts don't change in each batch.

---

## Section 5: The ZK Proof Pipeline

**STARK (Scalable Transparent Argument of Knowledge)**
A type of ZK proof. "Scalable" = proof size grows slowly as computation
grows. "Transparent" = no trusted setup needed (the math is
self-contained). Downside: larger proofs than SNARKs.

**SNARK (Succinct Non-interactive Argument of Knowledge)**
A type of ZK proof. "Succinct" = very small proof size. "Non-interactive"
= prover sends proof, verifier checks it, no back-and-forth.
Downside: usually requires a trusted setup.

**Plonky2**
A proof system created by Polygon. Combines the best of STARKs
(transparent, no trusted setup) with fast proving over small fields
(Goldilocks). Lighter builds all its inner circuits on Plonky2.

**gnark**
A Go library for building SNARK circuits. Lighter uses gnark specifically
for the final wrapping step — converting the Plonky2 proof into a
BN254-friendly SNARK that the EVM can verify cheaply.

**Circuit**
In ZK, a "circuit" is a program expressed as a series of mathematical
constraints (additions and multiplications). The prover must find values
(the "witness") that satisfy ALL constraints simultaneously. If the
constraints encode "correct orderbook matching," then a valid witness =
proof that matching was done correctly.

**Witness**
The actual data that satisfies a circuit's constraints. For Lighter: the
orders, the matches, the state changes. The prover knows the witness; the
verifier only sees the proof (not the witness).

**Witness Generator**
Software that takes raw execution data from the sequencer and transforms
it into the format the circuits expect. Like a translator between the
matching engine's output and the prover's input.

**Recursion / Recursive Proofs**
Proving a proof. Instead of verifying 1000 individual proofs, you create
a new proof that says "I verified these 1000 proofs and they're all
valid." This is how Lighter compresses thousands of transaction proofs
into a single batch proof. Recursion can be applied multiple times
(prove that you proved that you proved...).

**Aggregation**
Combining multiple proofs into one. After recursion, the aggregated proof
is smaller and cheaper to verify than all the individual proofs combined.

**FRI (Fast Reed-Solomon Interactive Oracle Proof)**
The mathematical technique Plonky2 uses to commit to polynomials. It's
hash-based (no elliptic curves needed), which is why Plonky2 STARKs don't
need a trusted setup. Think of it as a way to prove "this polynomial has
degree at most N" using only hashes.

**Goldilocks Field**
A specific prime field where p = 2^64 - 2^32 + 1. Every number in this
field fits in 64 bits (a standard CPU register). This makes arithmetic
~40x faster than in 256-bit fields (like BN254). Called "Goldilocks"
because it's a "just right" balance between security and efficiency.

**BN254 (also called BN128, alt_bn128)**
An elliptic curve that the EVM has built-in support for (precompiled
contracts at addresses 0x06, 0x07, 0x08). Verifying a proof over BN254
is cheap on Ethereum because the hard math is done by native precompiles,
not Solidity.

**Precompile / Precompiled Contract**
A function built directly into the EVM at a fixed address. Much cheaper
than doing the same computation in Solidity. The ecPairing precompile
(address 0x08) verifies BN254 curve pairings — this is what makes SNARK
verification affordable on Ethereum (~230k gas instead of millions).

**ecPairing**
The specific EVM precompile (at address 0x08) that checks BN254 bilinear
pairings. This is the cryptographic primitive that SNARK verifiers use.
One ecPairing call = one proof verification.

**Trusted Setup**
A one-time ceremony that generates the public parameters (proving key,
verification key) for a SNARK system. If ALL participants of the ceremony
collude, they could create fake proofs. But if even ONE participant is
honest and destroys their secret, the system is secure. Lighter uses the
Aztec Ignition ceremony (176 participants, 2019).

**Aztec Ignition**
A specific trusted setup ceremony conducted in 2019 by Aztec Protocol.
176 participants contributed randomness. Each participant's contribution
makes the system more secure (1-of-N honest assumption). Used by many
projects including Lighter.

**KZG (Kate-Zaverucha-Goldberg)**
A polynomial commitment scheme. Lets you commit to a polynomial and later
prove "the polynomial evaluates to Y at point X" with a tiny proof.
Named after its three inventors. Used in EIP-4844 for blob commitments
and in Lighter's SNARK wrapping.

**R1CS (Rank-1 Constraint System)**
A way to express a computation as a system of equations that a SNARK prover
can work with. gnark compiles circuits into R1CS format before proving.

**SRS (Structured Reference String)**
The public parameters generated by a trusted setup. Contains the "toxic
waste" from the ceremony in encrypted form. The SRS is needed by both
the prover (to create proofs) and the verifier (to check proofs).

**BLS12-381**
Another elliptic curve, used by Ethereum for EIP-4844 blob commitments.
Different from BN254. Lighter's blob evaluation circuit works over this
field to be compatible with Ethereum's blob format.

---

## Section 6: The Prover Codebase

**Gadget**
A reusable building block inside a ZK circuit. Like a function in
programming. Example: "uint32 addition gadget" = a set of constraints
that prove two 32-bit numbers were added correctly.

**Gate**
The lowest-level operation in a ZK circuit. Each gate takes some inputs,
applies constraints, and produces outputs. Custom gates (like
`QuinticMultiplicationGate`) are optimized operations that would be
expensive to express with generic gates.

**Quintic Extension / GF(p^5)**
A mathematical construction that extends the Goldilocks field to be 5x
larger (5 field elements instead of 1). Needed to build elliptic curves
(ECgFp5) that are secure enough for cryptographic signatures while still
being efficient inside Plonky2 circuits.

**Binary / Build Binary**
An executable program. The lighter-prover has 5 build binaries — programs
that, when run, generate the circuit data needed for proving.

---

## Section 7: On-Chain Contracts

**EIP-1967**
A standard for transparent proxy contracts. Defines where the
implementation address is stored in contract storage, so block explorers
and tools can find it.

**Proxy Contract**
A contract that forwards all calls to another contract (the
"implementation"). This allows upgrading the logic without changing the
address users interact with. The proxy holds the state; the implementation
holds the code.

**UUPS (Universal Upgradeable Proxy Standard)**
A proxy pattern where the upgrade logic lives in the implementation
contract, not the proxy. Lighter uses a transparent proxy instead, but
Gaekju uses UUPS.

**Multisig**
A wallet that requires multiple signatures (e.g., 3 of 5 people must
approve) before executing a transaction. Lighter's multisig controls
contract upgrades.

**Timelock**
A delay mechanism. "21-day timelock" means after proposing an upgrade, you
must wait 21 days before executing it. Gives users time to exit if they
disagree with the upgrade. Lighter's problem: the multisig can bypass the
timelock entirely.

**EOA (Externally Owned Account)**
A regular Ethereum account controlled by a private key (not a smart
contract). Three EOAs control Lighter's batch operations.

---

## Section 8: Data Availability

**Data Availability (DA)**
The guarantee that the data needed to reconstruct the L2 state is actually
available to everyone. If DA fails, users can't prove their balances and
can't exit. This is why Lighter posts state diffs to Ethereum — so the
data is always available.

**EIP-4844**
An Ethereum upgrade that added "blobs" — cheap temporary data storage.
~10x cheaper than regular calldata. Blobs are available for ~18 days, then
pruned. The KZG commitment (fingerprint) stays forever on L1.

**Blob**
A Binary Large Object. In EIP-4844 context: a chunk of data (~128 KB)
attached to an Ethereum transaction. Cheaper than calldata because nodes
only need to store it for ~18 days.

**Calldata**
Data attached to an Ethereum transaction that's stored permanently on-chain.
More expensive than blobs but permanent. Before EIP-4844, all L2 data
went in calldata.

---

## Section 9: The API Layer

**Auth Token**
A temporary credential that proves your identity. Lighter's format:
`{expiry}:{account}:{key_index}:{random}`. Expires after max 8 hours.

**Nonce**
A counter that increments with each transaction. Prevents replay attacks
(someone re-submitting your old transaction). Each API key has its own
nonce.

**Permessage-deflate**
A WebSocket compression extension. Compresses each message before sending
to reduce bandwidth. Useful for high-frequency data like order book
updates.

---

## Section 10: Security Model

**Front-Running**
Seeing someone's pending order and placing your own order ahead of it to
profit. Example: you see a large buy coming, buy first, then sell to the
large buyer at a higher price. Lighter's sequencer CAN do this because it
sees all orders before processing them.

**Sandwich Attack**
A specific type of front-running: buy before the victim's buy (pushing
price up), let the victim buy at the higher price, then sell (taking
profit from the price increase you caused).

**Censorship**
Refusing to include someone's transaction. The sequencer could simply
ignore your orders. The mitigation: priority queue on L1 forces the
sequencer to process your request within 14 days.

**MEV (Maximal Extractable Value)**
Profit that can be extracted by anyone who controls transaction ordering.
On Ethereum L1, MEV is extracted by block builders and searchers. On
Lighter, the sequencer has monopoly on MEV extraction.

**Wash Trading**
Trading with yourself to fake volume. Self-trade prevention is designed
to stop this.

**1-of-N Honest Assumption**
A security assumption that says: as long as at least 1 out of N
participants in a ceremony was honest (didn't collude), the system is
secure. For trusted setups, this means if even 1 of 176 participants
destroyed their secret, the setup is safe.

**Second Preimage Attack**
Finding a different input that produces the same hash output as a known
input. In Lighter's MiMC bug: an attacker could forge Merkle tree proofs
by finding alternative inputs that hash to the same value, potentially
faking account balances.

---

## Section 11: Performance Numbers

**Amortized Cost**
The per-unit cost when spreading a fixed cost across many units. If one
batch proof costs $0.19 and covers 28 trades, the amortized cost per
trade is $0.007. The more trades per batch, the cheaper each one gets.

**Throughput**
How many operations per second a system can handle. Measured in ops/sec
or TPS (transactions per second).

---

## General Terms (used throughout)

**Deterministic**
Given the same inputs, always produces the same outputs. EVM execution is
deterministic — anyone can re-run a transaction and get the same result.
This is what makes on-chain matching "verifiable" even without ZK proofs.

**Trustless**
No need to trust any single party. Uniswap is trustless — the smart
contract enforces the rules. Lighter is NOT trustless — you trust the
sequencer for ordering fairness.

**Composability**
The ability for smart contracts to interact with each other. "Money legos"
— you can plug protocols together. On-chain matching is composable; off-
chain matching is not (you can't call Lighter's sequencer from a smart
contract).

**Gas**
The unit of computation on Ethereum. Every operation costs gas. More
complex operations = more gas = more expensive. Gas price fluctuates with
network demand.

**Gas Limit**
The maximum amount of gas a block can contain. Limits how much computation
can happen per block. On OP Stack L2s, this determines how many orders
can be matched per block.

**Rollup**
An L2 that posts transaction data back to L1. "Rolling up" many
transactions into batches. Two types:
- **Optimistic rollup**: assumes transactions are valid, allows fraud
  proofs to challenge. (OP Stack, Arbitrum)
- **ZK rollup**: proves transaction validity with ZK proofs, no challenge
  period needed. (Lighter, zkSync, Scroll)

**OP Stack**
The open-source framework that powers Optimism and many other L2s (Base,
Giwa Chain, etc.). An optimistic rollup with a centralized sequencer and
fraud proof system.

**App-Specific Rollup / App-Chain**
A blockchain built for one specific application. Lighter is an app-chain —
it's a rollup that exists solely to run the Lighter exchange. Contrast
with general-purpose L2s (Base, Arbitrum) that run any application.

**Fraud Proof**
A proof that someone cheated. In optimistic rollups, anyone can submit a
fraud proof to challenge an invalid state transition. If the challenge
succeeds, the invalid state is rolled back.

**Validity Proof**
A ZK proof that a state transition is valid. Unlike fraud proofs (reactive
— prove something is wrong), validity proofs are proactive (prove
everything is right before accepting). Lighter uses validity proofs.

**State Transition Function (STF)**
The function that takes the current state + a transaction and produces
the new state. `STF(state, tx) → new_state`. Lighter's circuits prove
that the STF was computed correctly for every transaction in a batch.
