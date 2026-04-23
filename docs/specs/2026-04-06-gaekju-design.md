# Gaekju — Perpetual DEX Design Specification

> **Status:** Revised for Path B pivot (zkVM-proven off-chain matcher)
> **Date:** 2026-04-06 (original) / 2026-04-22 (Path B revision)
> **Chain:** Giwa Chain (OP Stack L2 Testnet)
> **License:** MIT

> **2026-04-22 NOTE:** This spec reflects the Path B pivot (ADR-0012). Sections related to on-chain matching (previously OrderBook.sol, bitmap libs) have been rewritten for the off-chain Rust matcher + SP1 zkVM + Settlement.sol architecture. Margin / position / liquidation / funding / oracle sections are unchanged from Phase 1+2 work.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Smart Contracts](#3-smart-contracts)
4. [Rust Backend](#4-rust-backend)
5. [Documentation & Project Structure](#5-documentation--project-structure)
6. [Build Phases](#6-build-phases)
7. [Technical Decisions (ADR Summary)](#7-technical-decisions)
8. [Formulas & Math](#8-formulas--math)
9. [Market Configurations](#9-market-configurations)
10. [Security Considerations](#10-security-considerations)
11. [Lighter Mirror + Testnet Traders](#11-live-market-operations--lighter-mirror--testnet-traders)
12. [Sequencer Protocol](#13-sequencer-protocol)
13. [Proof System](#14-proof-system)
14. [Settlement Contract](#15-settlement-contract)
15. [Soft-Confirm UX](#16-soft-confirm-ux)
16. [Failure Modes](#17-failure-modes)

---

## 1. Overview

Gaekju is a **production-grade perpetual futures DEX** deployed on Giwa Chain, an OP Stack L2 testnet. It follows the **Lighter.xyz architecture family**: a central limit orderbook (CLOB) with matching executed by an off-chain Rust sequencer and correctness proven by an SP1 zkVM circuit. Settlement, collateral custody, position accounting, funding, and liquidation remain fully on-chain. See ADR-0012.

### Design Principles

- **Proven off-chain matching:** Matching runs in a deterministic Rust sequencer. An SP1 zkVM re-executes the same Rust over each batch and produces a succinct proof. The Settlement contract verifies the proof before applying the state delta. Logic trust reduces to on-chain contract trust; only ordering fairness is a residual trust axis (mitigated by force-inclusion and post-batch state-root commits).
- **Modular on-chain contracts:** Each settlement concern (vault, margin, position, liquidation, funding, oracle) lives in its own upgradeable contract. Settlement is the sole caller.
- **Rust as primary engine:** The matching engine, prover program, indexer, API, keeper, SDK, CLI, and Lighter mirror are all Rust. The sequencer and the SP1 guest share the same Rust crate.
- **Documentation as a product:** Every phase produces ADRs, specs, changelog entries, and a blog post. The project is a tutorial as much as a product.

### What Gaekju Is

- A zkVM-proven perpetual futures exchange on an OP Stack L2
- Off-chain Rust matcher + SP1 proof + on-chain settlement (Lighter architectural family)
- Supports crypto perpetuals (BTC, ETH, SOL, etc.) and RWA perpetuals (EUR/USD, XAU/USD)
- USDC-only collateral with isolated margin
- Per-market configurable leverage (up to 50x crypto, 10x RWA)
- Pyth Network oracle integration
- Force-inclusion escape hatch: any user can submit an intent on-chain that the sequencer must process within N batches or be in default

### What Gaekju Is Not

- Not an AMM or vAMM — this is a proper orderbook
- Not a fully on-chain EVM matching engine — matching is off-chain, proven, settled on-chain. See ADR-0012 rebuttal of ADR-0001
- Not an optimistic/trust-me off-chain matcher — correctness is ZK-proven, not operator-asserted
- Not cross-margin (in v1) — isolated margin only
- Not a token launch — no governance token in scope

---

## 2. Architecture

Gaekju is a three-layer system. Matching is off-chain (Layer 2, Rust sequencer). Correctness is proven (Layer 3, SP1 zkVM). Custody, position state, funding, and liquidation are on-chain (Layer 1, Giwa contracts). The Settlement contract is the bridge: it verifies SP1 proofs and applies matched-batch state deltas to the on-chain contracts.

### 2.1 System Overview

```
           Layer 1 — Giwa Chain (OP Stack L2)
           ┌────────────────────────────────────────────────┐
           │  Router (deposit / withdraw / forceInclude)    │
           │  Settlement.sol (SP1 verifier + delta applier) │
           │    ├─▶ Vault (USDC custody, 6↔18 dec)          │
           │    ├─▶ PositionManager                          │
           │    ├─▶ MarginEngine                             │
           │    ├─▶ FundingRate                              │
           │    ├─▶ LiquidationEngine                        │
           │    └─▶ OracleAdapter (Pyth)                     │
           └────────────────────────────────────────────────┘
                      ▲                            ▲
                      │ submit(batch, proof)       │ keeper tx
                      │                            │ (liquidate,
                      │                            │  applyFunding,
                      │                            │  Pyth update)
           ┌──────────┴──────────┐        ┌────────┴─────────┐
           │ Layer 2 — Sequencer │        │   Rust Keepers    │
           │  gaekju-sequencer   │        │ gaekju-keeper     │
           │  (Rust, stateful)   │        └──────────────────┘
           │  • EIP-712 intake   │
           │  • Deterministic    │
           │    matcher          │
           │  • Emits batch blob │──────┐
           │    + state delta    │      │ batch
           └─────────────────────┘      │
                      ▲                 ▼
                      │ WS/REST    ┌─────────────────────┐
                Signed│ intents    │ Layer 3 — Prover     │
                      │            │  gaekju-prover       │
           ┌──────────┴──────────┐ │  (Rust, SP1 zkVM)    │
           │      Traders        │ │  • Re-runs matcher   │
           │ (EIP-712 signer)    │ │    inside zkVM guest │
           └─────────────────────┘ │  • Outputs SP1 proof │
                                    │  • Public inputs:    │
                                    │    prevRoot, batch,  │
                                    │    postRoot          │
                                    └──────────────────────┘

Indexer/API/Frontend read events & pending state from both Settlement
(finalized) and Sequencer (soft).
```

### 2.2 Layer Responsibilities

**Layer 1 — Giwa contracts (canonical state).**
Vault custodies USDC. PositionManager owns positions. MarginEngine checks IMR/MMR. FundingRate accumulates per-interval premium. LiquidationEngine liquidates undermargined positions on-chain using Pyth mark price. OracleAdapter wraps Pyth. Settlement is the only authorized caller that can mutate positions / balances on behalf of user trading. Router exposes deposit/withdraw and a `forceInclude(intent)` escape hatch.

**Layer 2 — Rust sequencer (`crates/gaekju-sequencer`).**
Stateful service. Holds the authoritative pending orderbook in memory. Accepts EIP-712 signed intents over WS and REST. Enforces per-account monotonic nonces. Matches deterministically using price-time priority. Emits fills, position deltas, and margin deltas. Bundles a batch (ordered accepted intents + resulting fills + rejected intents + force-included intents observed on-chain) and hands it to the prover. Soft-acknowledges intents to users in <50ms.

**Layer 3 — SP1 prover (`crates/gaekju-prover`).**
Runs the same matching Rust crate inside the SP1 zkVM guest. Inputs: previous state root, batch blob, Pyth price attestations consumed by the batch. Outputs: new state root + succinct SP1 proof. Public inputs committed: `(prevStateRoot, batchHash, postStateRoot, batchNonce)`. Proof is posted to Settlement along with the batch blob.

### 2.3 Data Flow: Order Lifecycle

```
Trader                 Sequencer (Rust)       Prover (SP1)        Settlement (Giwa)
  │                         │                     │                     │
  │── EIP-712 signed ─────▶│                      │                     │
  │    intent (place)       │ verify sig + nonce  │                     │
  │◀──── soft ack ────────│ match against book   │                     │
  │  (fillHint, seqId)      │ emit pending fills  │                     │
  │                         │                     │                     │
  │                         │ close batch on      │                     │
  │                         │ tick / size /       │                     │
  │                         │ timeout             │                     │
  │                         │──── batch + prevRoot ──▶                   │
  │                         │                     │ re-execute in zkVM  │
  │                         │                     │ produce SP1 proof   │
  │                         │                     │── proof + blob ──▶ │
  │                         │                     │                     │ verify SP1
  │                         │                     │                     │ check nonce
  │                         │                     │                     │ apply delta:
  │                         │                     │                     │  Vault.applyBatchDelta
  │                         │                     │                     │  PositionManager.applyBatchFills
  │                         │                     │                     │ emit BatchSettled
  │◀──── finalized ───────│◀────────────────────│◀──────────────────│
```

Deposits and withdrawals go directly to Router → Vault and do not transit the sequencer. They update free balance, which the sequencer reads via on-chain state before accepting new intents.

### 2.4 Data Flow: Force-Include (censorship escape)

```
Trader                  Router (Giwa)          Sequencer           Settlement
  │                         │                      │                    │
  │── forceInclude(intent) │                      │                    │
  │── (on-chain tx) ──────▶│ emit ForceIncludeQueued                    │
  │                         │  (intent, deadline)  │                    │
  │                         │                      │ observes event     │
  │                         │                      │ includes in next   │
  │                         │                      │ N batches          │
  │                         │                      │                    │
  │                         │                      │ if not included    │
  │                         │                      │ before deadline:   │
  │                         │                      │                    │ sequencer in default
  │                         │                      │                    │ → pauseMatching / switchover
```

See ADR-0014 for force-inclusion deadline parameterization.

### 2.5 Data Flow: Liquidation

Liquidation runs entirely on-chain against the finalized state and Pyth mark price. It does not require a sequencer batch.

```
Keeper (Rust)             Giwa L2
  │                         │
  │── isLiquidatable? ────▶│ LiquidationEngine.isLiquidatable()
  │◀── true ───────────────│   └─ marginRatio < MMR (finalized state)
  │                         │
  │── liquidate() ────────▶│ LiquidationEngine.liquidate()
  │                         │   ├─ FundingRate.settleFunding()
  │                         │   ├─ calculate liquidation size
  │                         │   ├─ PositionManager.updatePosition()
  │                         │   ├─ fee → keeper + insurance fund
  │                         │   └─ emit PositionLiquidated
```

The sequencer observes on-chain liquidation events and reconciles its in-memory position view before accepting new intents for the affected account.

---

## 3. Smart Contracts

### 3.1 Libraries

Only on-chain math libraries remain. Bitmap / packed-order / tick libraries are removed — orderbook state no longer lives on-chain. Tick arithmetic and order encoding move to the Rust matcher crate (`crates/gaekju-matcher`) which is shared between sequencer and SP1 guest.

#### FixedPointMath.sol
18-decimal fixed-point arithmetic. All prices, sizes, and rates use `uint256` with 18 decimals (1e18 = 1.0).

- `mulFp(a, b) → a * b / 1e18`
- `divFp(a, b) → a * 1e18 / b`
- `mulDiv(a, b, c) → a * b / c` (full precision, no overflow)
- Uses OpenZeppelin's `Math.mulDiv` for overflow-safe multiplication.

### 3.2 Vault

The Vault holds all USDC collateral and tracks per-account balances.

```solidity
// State
mapping(address => uint256) public balances;        // free balance (not locked in margin)
mapping(address => uint256) public lockedMargin;     // margin locked for positions
mapping(address => uint256) public orderMargin;      // margin reserved for open orders
uint256 public insuranceFund;                        // accumulated from liquidation fees
uint256 public totalDeposits;                        // total USDC in vault

// External functions
function deposit(uint256 amount) external;
function withdraw(uint256 amount) external;

// Internal functions (called by other contracts)
function lockMargin(address account, uint256 amount) external onlyAuthorized;
function unlockMargin(address account, uint256 amount) external onlyAuthorized;
function lockOrderMargin(address account, uint256 amount) external onlyAuthorized;
function unlockOrderMargin(address account, uint256 amount) external onlyAuthorized;
function transferToInsuranceFund(uint256 amount) external onlyAuthorized;
function drawFromInsuranceFund(uint256 amount) external onlyAuthorized;
function realizePnl(address account, int256 pnl) external onlyAuthorized;

// Batch settlement entry (Path B)
// Applies a set of balance/margin deltas produced by a proven matching batch.
// Caller guard: onlyRole(SETTLEMENT_ROLE). Settlement is the sole caller.
// Idempotent within a batch: revert if batchNonce <= lastAppliedNonce.
function applyBatchDelta(
    uint256 batchNonce,
    BalanceDelta[] calldata deltas
) external onlyRole(SETTLEMENT_ROLE);
// BalanceDelta { account, freeDelta, lockedMarginDelta, orderMarginDelta, realizedPnlDelta, insuranceFundDelta }
// Sum of all deltas across a batch must satisfy fills-conservation invariant (§10).
```

**USDC Decimal Conversion:**
USDC uses 6 decimals, but all internal accounting uses 18-decimal fixed-point. Conversion happens at the Vault boundary only:
- On deposit: `internalAmount = usdcAmount * 1e12` (6 → 18 decimals)
- On withdraw: `usdcAmount = internalAmount / 1e12` (18 → 6 decimals)
- All other contracts work exclusively in 18-decimal space.

Key invariants:
- `balances[account] + lockedMargin[account] + orderMargin[account] == accountEquity[account]`
- `totalDeposits = Σ(balances) + Σ(lockedMargin) + Σ(orderMargin) + insuranceFund + Σ(unrealizedPnL adjustments)`
- `USDC.balanceOf(vault) * 1e12 >= totalDeposits` (insuranceFund is part of totalDeposits, not additive)
- Withdrawals revert if `amount > balances[account]` (free balance only)

### 3.3 OracleAdapter

Wraps Pyth Network for price feeds.

```solidity
// State
mapping(uint256 => bytes32) public marketPythIds;    // marketId → Pyth price feed ID
mapping(uint256 => uint256) public stalenessThreshold; // max price age in seconds
IPyth public pyth;                                    // Pyth contract on Giwa

// Functions
function getMarkPrice(uint256 marketId) external view returns (uint256);
function getIndexPrice(uint256 marketId) external view returns (uint256);
function updatePrice(uint256 marketId, bytes[] calldata priceUpdateData) external payable;

// Internal
function _validatePrice(PythStructs.Price memory price, uint256 marketId) internal view;
  // Reverts if:
  //   - price.publishTime < block.timestamp - stalenessThreshold
  //   - price.conf / price.price > MAX_CONFIDENCE_RATIO (1%)
  //   - price.price <= 0
```

Mark price = weighted combination of oracle price and orderbook mid-price (used for margin calculations, liquidation checks).
Index price = Pyth spot oracle price (used for funding rate calculation).

**Mark price calculation (v1):**
```
oraclePrice = pyth.getPrice(marketId)
midPrice = sequencerMidPrice[marketId]   // published by each batch's state delta, 0 if batch carried no fills
if midPrice == 0:
    markPrice = oraclePrice
else:
    markPrice = oraclePrice * 0.7 + midPrice * 0.3  // oracle-weighted blend
```

**Sequencer mid-price pipeline (single source of truth).** The orderbook lives off-chain in the sequencer. Each `BatchBlob` carries a dedicated `MidPriceUpdate[] midPriceUpdates` top-level array — one entry per market touched by the batch — with `mid = (bestBid + bestAsk) / 2` at the instant the batch sealed. `MidPriceUpdate` is **not** part of `BalanceDelta[]`; it is a sibling array in the blob because it mutates FundingRate state, not Vault state. Inside `applyBatch` (§15.3 step 9b) Settlement itself calls `FundingRate.updateSequencerMid(marketId, mid)` for each entry — Settlement holds `SETTLEMENT_ROLE` on FundingRate, Vault does not need FundingRate access. This writes `sequencerMid[marketId]` + `sequencerMidTimestamp[marketId] = block.timestamp`. Two consumers read this slot:

1. **OracleAdapter mark price (above):** if `block.timestamp - sequencerMidTimestamp <= 60s`, use the fresh mid in the 70/30 blend; otherwise collapse to pure oracle.
2. **FundingRate.applyFunding** (§3.8): same 60s staleness rule, pure-oracle fallback, emits `FundingFellBackToOracle` on fallback.

The 60s staleness window is the single governance parameter (`SEQUENCER_MID_STALENESS`) shared across both consumers. If the sequencer is halted, both mark-for-margin and funding converge to pure oracle after 60s — no silent staleness, no dual-path divergence.

This ensures mark price and index price diverge when live trading drives the sequencer book away from oracle, producing non-zero funding rates. In v2, mark price uses a TWAP of this blend for smoothing.

### 3.4 Settlement

**Global singleton.** Single on-chain contract that receives proven matching batches for **all markets** and applies them to Vault / PositionManager / MarginEngine / FundingRate. A single batch can span any number of markets; each `Fill` and each `BalanceDelta` carries its own `marketId`. One batch-nonce chain, one force-include queue, one `programVKey` for the whole exchange. Replaces the old per-market OrderBook family. See §15 for the deeper spec.

Catalog entry — full spec in §15. Canonical types: §14.1 (`BatchPublicInputs`) and §15.2 (`BatchBlob`).

```solidity
contract Settlement {
    ISP1Verifier public verifier;        // upgradable via UUPS
    bytes32      public programVKey;     // storage slot, rotated via pause+drain (§15.5)
    bytes32      public stateRoot;
    uint64       public batchNonce;
    uint64       public forceIncludeCursor;

    function applyBatch(ProofBundle calldata bundle) external;

    function forceIncludedIntents(uint256 intentId)
        external view returns (ForcedIntent memory);

    // Governance (timelock + multisig)
    function pauseMatching(string calldata reason) external;
    function unpauseMatching() external;
    function rotateSequencer(address next) external;
    function proposeProgramVKey(bytes32 next) external;
    function activateProgramVKey(bytes32 next) external;  // paused + drained only
}
```

**applyBatch flow (high level — full version §15.3):**
1. Decode `bundle.batchBlob` → `blob`; check `keccak256(blob) == bundle.publicInputs.batchHash` + `chainId == block.chainid`.
2. `bundle.publicInputs.batchNonce == batchNonce + 1` and `prevStateRoot == stateRoot`.
3. SP1 verify `(programVKey, abi.encode(BatchPublicInputs), sp1Proof)`.
4. For every overdue entry in the force-include queue, require a proved `ForcedOutcome`; else revert.
5. Store `ForcedOutcome` data into each queue entry; emit `ForcedIntentResolved`.
6. `Vault.applyBatchDelta(nonce, blob.balanceDeltas)` — sole writer of vault buckets.
7. `PositionManager.applyBatchFills(nonce, blob.fills)` — position state only.
8. `stateRoot = postStateRoot; batchNonce = newNonce; forceIncludeCursor = newCursor;`.
9. Emit `BatchSettled(...)`.

**Invariants enforced here (see §10):** batch-nonce monotonicity, prev-state-root continuity, chain-id binding, proof validity, force-inclusion deadline via proved outcomes, fills conservation (decoded deltas sum to zero modulo insurance + fees).

**Fees** are computed off-chain by the matcher and appear as `BalanceDelta` entries. Maker rebate and taker fee rates are part of the proven program — changing them requires a `programVKey` rotation (§15.5).

**Events (canonical, no aliases):**

```solidity
event BatchSettled(
    uint64  indexed batchNonce,
    bytes32         prevStateRoot,
    bytes32         postStateRoot,
    bytes32         batchHash,
    uint64          forceIncludeCursor
);
event ForceIncludeQueued(
    uint256 indexed forcedIntentId,
    address indexed trader,
    bytes32         intentHash,
    uint64          deadlineBatchNonce
);
event ForcedIntentResolved(
    uint256 indexed forcedIntentId,
    uint8           outcome,       // 1 = accepted, 2 = rejected
    uint8           rejectReason,
    bytes32         resultHash
);
event SequencerRotated(address indexed next);
event ProgramVKeyProposed(bytes32 indexed vkey, uint64 timelockExpiresAt);
event ProgramVKeyRotated(bytes32 indexed oldVKey, bytes32 indexed newVKey);
event MatchingPaused(string reason);
event MatchingUnpaused();
```

Older names (`BatchApplied`, `BatchFinalized`, `IntentForced`, `IntentForcedResolved`) are retracted — use the above exclusively.

### 3.5 MarginEngine

Handles all margin calculations and checks.

```solidity
// Market configuration
struct MarketConfig {
    uint256 maxLeverage;        // e.g., 50e18 = 50x
    uint256 initialMarginRate;  // e.g., 20e15 = 2% (1/50)
    uint256 maintenanceMarginRate; // e.g., 10e15 = 1% (1/100)
    uint256 tickSize;           // minimum price increment
    uint256 lotSize;            // minimum size increment
    uint256 maxOrderSize;       // maximum single order size
    uint256 minOrderSize;       // minimum single order size
}

mapping(uint256 => MarketConfig) public configs;

// Functions
function checkInitialMargin(
    address account,
    uint256 marketId,
    uint256 orderSize,
    uint256 price
) external view returns (bool);

function getAvailableMargin(address account) external view returns (uint256);
// = vault.balance(account) - vault.lockedMargin(account) - vault.orderMargin(account)

function getMarginRatio(
    address account,
    uint256 marketId
) external view returns (uint256);
// = (collateral + unrealizedPnl) / notionalValue
// Returns type(uint256).max when notionalValue == 0 (no position)

function getRequiredMargin(
    uint256 marketId,
    uint256 size,
    uint256 price
) external view returns (uint256);
// = size * price / maxLeverage = size * price * initialMarginRate
```

### 3.6 PositionManager

Tracks all open positions.

```solidity
struct Position {
    int256 size;              // positive = long, negative = short
    uint256 entryPrice;       // weighted average entry price (18 dec)
    uint256 collateral;       // margin allocated to this position
    int256 lastCumulativeFunding; // funding index at last settlement
    uint256 lastUpdated;      // timestamp
}

mapping(address => mapping(uint256 => Position)) public positions;
// account => marketId => Position

// Iterable position registry (required for ADL ranking)
// EnumerableSet of accounts with open positions per market
mapping(uint256 => EnumerableSet.AddressSet) private _positionHolders;
// marketId => set of accounts with open positions

function getPositionHolders(uint256 marketId) external view returns (address[] memory);
function getPositionCount(uint256 marketId) external view returns (uint256);
// Updated automatically: added on position open, removed on position close

// Called by Settlement on proven batch (Path B)
// Role rebind: ORDERBOOK_ROLE → SETTLEMENT_ROLE. Semantics otherwise unchanged.
function updatePosition(
    address account,
    uint256 marketId,
    int256 sizeDelta,     // positive = buy, negative = sell
    uint256 fillPrice,
    uint256 marginDelta
) external onlyRole(SETTLEMENT_ROLE);

// Batch entry — applies many fills atomically with one caller check.
// Each Fill is { account, marketId, sizeDelta, fillPrice, marginDelta, realizedPnl,
// settledFunding }. Applied in order; funding is settled inline using the oracle
// price snapshot committed by the batch's public inputs.
function applyBatchFills(
    uint256 batchNonce,
    Fill[] calldata fills
) external onlyRole(SETTLEMENT_ROLE);

// View functions
function getPosition(address account, uint256 marketId) external view returns (Position memory);
function getUnrealizedPnl(address account, uint256 marketId) external view returns (int256);
function getPositionValue(address account, uint256 marketId) external view returns (uint256);
```

**Position update logic (runs inside the zkVM matcher, not on-chain).** Under Path B, this pseudocode describes the deterministic Rust state machine that the sequencer executes for soft-confirm and the SP1 guest re-executes for the proof. It lives in `crates/gaekju-matching-core`. Each call emits (a) one or more `Fill` records for `PositionManager.applyBatchFills`, and (b) a set of `BalanceDelta` records (order-margin release, position-margin lock, realized-PnL credit/debit, funding payment) that the prover packs into `blob.balanceDeltas` and `Vault.applyBatchDelta` applies. Settlement's `PositionManager.applyBatchFills` on-chain only writes position state (§15.3.1); it does **not** call `vault.*` methods inline.

```
// Runs inside matching-core (Rust). NOT an on-chain function under Path B.
applyFill(state, account, market, sizeDelta, fillPrice, orderMarginForThisFill):
  pos = state.positions[account][market]
  settleFunding(state, account, market)   // emits BalanceDelta for funding payment

  if pos.size == 0:
    pos.size, pos.entryPrice, pos.collateral = sizeDelta, fillPrice, orderMarginForThisFill
    state.balanceDeltas.push(UnlockOrderMargin(account, orderMarginForThisFill))
    state.balanceDeltas.push(LockPositionMargin(account, orderMarginForThisFill))

  else if sameDirection(pos.size, sizeDelta):
    newSize = pos.size + sizeDelta
    pos.entryPrice = (mulFp(pos.entryPrice, abs(pos.size)) + mulFp(fillPrice, abs(sizeDelta))) * 1e18 / abs(newSize)
    pos.size = newSize
    pos.collateral += orderMarginForThisFill
    state.balanceDeltas.push(UnlockOrderMargin(account, orderMarginForThisFill))
    state.balanceDeltas.push(LockPositionMargin(account, orderMarginForThisFill))

  else if abs(sizeDelta) < abs(pos.size):
    // Partial close — realize PnL
    pnl = mulFp(fillPrice - pos.entryPrice, abs(sizeDelta)) * sign(pos.size)
    state.balanceDeltas.push(RealizePnl(account, pnl))
    pos.size += sizeDelta
    proportionalCollateral = pos.collateral * abs(sizeDelta) / abs(pos.size_before)
    pos.collateral -= proportionalCollateral
    state.balanceDeltas.push(UnlockPositionMargin(account, proportionalCollateral))

  else if abs(sizeDelta) == abs(pos.size):
    pnl = mulFp(fillPrice - pos.entryPrice, abs(pos.size)) * sign(pos.size)
    state.balanceDeltas.push(RealizePnl(account, pnl))
    state.balanceDeltas.push(UnlockPositionMargin(account, pos.collateral))
    delete state.positions[account][market]

  else:
    // Flip — close old + open new in opposite direction
    closePnl = mulFp(fillPrice - pos.entryPrice, abs(pos.size)) * sign(pos.size)
    state.balanceDeltas.push(RealizePnl(account, closePnl))
    state.balanceDeltas.push(UnlockPositionMargin(account, pos.collateral))
    remainingSize = sizeDelta + pos.size
    newMargin = mulFp(abs(remainingSize), fillPrice) * IMR
    state.balanceDeltas.push(LockPositionMargin(account, newMargin))
    pos.size, pos.entryPrice, pos.collateral = remainingSize, fillPrice, newMargin

  state.fills.push(Fill { account, market, sizeDelta, fillPrice, ... })
```

On-chain, `PositionManager.applyBatchFills(fills)` walks `fills` and writes only `(size, entryPrice, collateral, lastCumulativeFunding)` + the `_positionHolders` set. It reads `vault.*` only for invariant assertions (MMR check on decrease-into-loss, IMR check on open/increase) — **never** to mutate. See §15.3.1.

### 3.7 LiquidationEngine

```solidity
struct LiquidationConfig {
    uint256 liquidatorFeeRate;    // e.g., 5e15 = 0.5%
    uint256 insuranceFundFeeRate; // e.g., 5e15 = 0.5%
}

function isLiquidatable(address account, uint256 marketId) external view returns (bool);
// marginRatio < maintenanceMarginRate

function liquidate(address account, uint256 marketId) external;
// 1. Verify isLiquidatable
// 2. Settle accumulated funding first (FundingRate.settleFunding)
// 3. Re-check isLiquidatable after funding settlement
// 4. Calculate liquidation size:
//    - totalFee = liquidationSize * markPrice * (liquidatorFeeRate + insuranceFundFeeRate)
//    - Partial: solve for reduceSize where POST-FEE marginRatio = IMR
//      reduceSize = (IMR * notional - equity) / (IMR * markPrice - markPrice + totalFeeRate * markPrice)
//    - Full: if position too small (< minOrderSize) or equity <= 0
// 5. Execute liquidation at mark price (oracle) via PositionManager.updatePosition()
// 6. Distribute fees:
//    - liquidatorFee → msg.sender (keeper incentive)
//    - insuranceFee → insurance fund
// 7. If remaining collateral < 0:
//    - Draw deficit from insurance fund
//    - If insurance fund insufficient: flag position for ADL
// 8. Emit PositionLiquidated

function autoDeleverage(uint256 marketId, address bankruptAccount) external;
// Triggered when insurance fund cannot cover a bankruptcy
// Uses PositionRegistry (see below) for iterable position set
// 1. Verify: bankruptAccount has negative equity after liquidation attempt
// 2. Get opposite-side positions from PositionRegistry.getPositionsByMarket(marketId)
// 3. Rank by unrealized PnL (highest first) — ADL priority
// 4. Force-close the most profitable position against the bankrupt one
// 5. Both positions closed at the bankruptcy price
// 6. Emit AutoDeleveraged
```

### 3.8 FundingRate

Per Path B, the **mark price used for funding is the sequencer orderbook mid-price**, written on-chain by Settlement during each batch via a dedicated `MidPriceUpdate[]` array in the `BatchBlob` (sibling to `balanceDeltas`, see §15.2). Settlement itself calls `FundingRate.updateSequencerMid(marketId, mid)` — the call is `onlyRole(SETTLEMENT_ROLE)`, granted once at bootstrap. Rationale for using sequencer mid: funding should track perpetual trading price, not purely oracle price, matching Lighter / Hyperliquid convention. The oracle remains authoritative for margin / liquidation (§3.5, §3.7).

```solidity
struct FundingState {
    int256  cumulativeFundingRate;  // accumulated funding rate (18 dec)
    uint64  lastFundingTime;        // last update timestamp
    uint64  fundingInterval;        // 1 hour = 3600 seconds (matches Lighter)
    int256  maxFundingRate;         // e.g., 1e15 = 0.1%
    uint256 sequencerMid;           // last mark price written by Settlement (18 dec)
    uint64  sequencerMidTimestamp;  // when sequencer wrote it
}

uint64 public constant SEQUENCER_MID_STALENESS = 60;  // seconds

mapping(uint256 => FundingState) public fundingStates;

// Called by Settlement inside applyBatch — one entry per active market whose batch
// touched the book. SETTLEMENT_ROLE only.
function updateSequencerMid(uint256 marketId, uint256 mid) external onlyRole(SETTLEMENT_ROLE);
// 1. sequencerMid[marketId] = mid
// 2. sequencerMidTimestamp[marketId] = block.timestamp
// 3. emit SequencerMidUpdated(marketId, mid)

// Keeper poke — unchanged cadence (1h), changed mark-price source.
function applyFunding(uint256 marketId) external;
// 1. require(block.timestamp >= lastFundingTime + fundingInterval)
// 2. Pick mark price with fallback:
//    if block.timestamp - sequencerMidTimestamp <= SEQUENCER_MID_STALENESS:
//        markPrice = sequencerMid
//    else:
//        markPrice = oracle.getMarkPrice(marketId)   // fallback: pure oracle
//        emit FundingFellBackToOracle(marketId, block.timestamp - sequencerMidTimestamp)
// 3. indexPrice = oracle.getIndexPrice(marketId)
// 4. rate = clamp((markPrice - indexPrice) * 1e18 / indexPrice, -maxRate, +maxRate)
// 5. cumulativeFundingRate += rate
// 6. lastFundingTime = block.timestamp
// 7. Emit FundingApplied(marketId, rate, cumulativeFundingRate, markPriceSource)

function settleFunding(address account, uint256 marketId) internal;
// Called by PositionManager on every position update AND by LiquidationEngine before liquidation
// Funding rate is dimensionless (premium ratio), so multiply by markPrice to get USDC payment:
// fundingDelta = currentCumFunding - position.lastCumFunding
// payment = mulFp(mulFp(position.size, fundingDelta), markPrice)
//   = position.size * fundingDelta * markPrice / 1e18 / 1e18
// if payment > 0: longs pay (deduct from collateral), shorts receive
// if payment < 0: shorts pay, longs receive
// Update position.lastCumulativeFunding = currentCumFunding
```

### 3.9 MarketFactory

Thin config registry. Under Path B it no longer deploys per-market OrderBook proxies (there is no on-chain orderbook). It owns market metadata and pause flags. The sequencer reads this state to validate intents; Settlement reads it to reject batches that reference paused markets. Any change to tick/lot/leverage/IMR/MMR must be coordinated with a sequencer restart and prover vkey update if the matcher semantics depend on it.

```solidity
struct MarketParams {
    string name;              // "BTC-USD"
    bytes32 pythPriceId;      // Pyth price feed ID
    uint256 tickSize;         // minimum price increment
    uint256 lotSize;          // minimum size increment
    uint256 maxLeverage;      // maximum leverage (18 dec)
    uint256 imr;              // initial margin rate
    uint256 mmr;              // maintenance margin rate
    uint256 fundingInterval;  // funding period in seconds
    int256 maxFundingRate;    // max funding rate per interval
    uint256 minOrderSize;     // minimum order size
    uint256 maxOrderSize;     // maximum order size
}

uint256 public nextMarketId;
mapping(uint256 => MarketParams) public marketParams;
mapping(uint256 => bool) public marketActive;

function createMarket(MarketParams calldata params) external onlyAdmin returns (uint256 marketId);
function pauseMarket(uint256 marketId) external onlyAdmin;
function resumeMarket(uint256 marketId) external onlyAdmin;
function updateMarketConfig(uint256 marketId, MarketParams calldata params) external onlyAdmin;
```

### 3.10 Router

Thin on-chain entry. Under Path B, users send signed intents (place/cancel/modify) off-chain to the sequencer. The Router only exposes operations that must live on-chain:

```solidity
// Deposit — 6→18 decimal conversion happens inside Vault.
function deposit(uint256 usdcAmount) external;

// Withdraw — limited to free (not locked / not order-reserved) balance.
// May be delayed by pendingBatches: withdraw reverts until the sequencer has
// committed a batch that acknowledges the user's intent freeze, to prevent
// double-spend of in-flight margin.
function withdraw(uint256 usdcAmount) external;

// Force-include escape hatch. Any user can submit a signed intent on-chain
// if they suspect sequencer censorship. Settlement must include the intent
// in one of the next N batches (ADR-0014 parameter) or the sequencer is in
// default and matching is paused.
function forceInclude(Intent calldata intent, bytes calldata signature) external;
// Emits ForceIncludeQueued(forcedIntentId, trader, intentHash, deadlineBatchNonce = batchNonce + N).

// Cancel a force-included intent before it is consumed (e.g. user changed mind).
function cancelForcedInclude(uint256 intentId) external;
```

Everything else — placeOrder, cancelOrder, modifyOrder, batch orders, post-only, reduce-only, IOC/FOK — is an off-chain signed intent, not a Router entry point.

### 3.11 Upgradability

All contracts use UUPS proxy pattern (EIP-1822):
- Each contract has a proxy deployed in front of it
- Upgrades go through a 24-hour Timelock contract owned by a 3-of-5 multisig
- `upgradeTo(newImpl)` can only be called by the Timelock after the delay
- Emergency pause (no timelock needed) can only pause, not upgrade
- Initializer pattern instead of constructors
- Storage gaps (`uint256[50] private __gap`) for future storage expansion

---

## 4. Rust Backend

### 4.1 Workspace Structure

```
crates/
├── gaekju-types/       # Shared types and ABI bindings
│   ├── src/
│   │   ├── lib.rs
│   │   ├── order.rs        # Order, OrderType, Side
│   │   ├── position.rs     # Position, PositionUpdate
│   │   ├── market.rs       # MarketConfig, MarketInfo
│   │   ├── account.rs      # AccountBalance, MarginInfo
│   │   ├── events.rs       # Decoded contract events
│   │   └── bindings/       # Auto-generated from Foundry ABIs (alloy)
│   └── Cargo.toml
│
├── gaekju-indexer/     # On-chain event indexer
│   ├── src/
│   │   ├── main.rs
│   │   ├── indexer.rs      # Core indexing loop
│   │   ├── decoder.rs      # Event log decoding
│   │   ├── db.rs           # PostgreSQL operations
│   │   ├── reorg.rs        # Chain reorganization handling
│   │   └── state.rs        # In-memory orderbook state
│   └── Cargo.toml
│
├── gaekju-api/         # REST + WebSocket API
│   ├── src/
│   │   ├── main.rs
│   │   ├── server.rs       # Axum server setup
│   │   ├── routes/
│   │   │   ├── mod.rs
│   │   │   ├── markets.rs  # GET /v1/markets, /v1/markets/{id}/*
│   │   │   ├── account.rs  # GET /v1/account/{addr}/*
│   │   │   └── health.rs   # GET /health
│   │   ├── ws/
│   │   │   ├── mod.rs
│   │   │   ├── handler.rs  # WebSocket connection handler
│   │   │   └── streams.rs  # orderbook, trades, positions streams
│   │   └── state.rs        # Shared app state (DB pool, indexer state)
│   └── Cargo.toml
│
├── gaekju-keeper/      # Liquidation + funding keeper bots
│   ├── src/
│   │   ├── main.rs
│   │   ├── liquidator.rs   # Monitor & liquidate positions
│   │   ├── funding.rs      # Trigger funding rate updates
│   │   ├── oracle.rs       # Keep Pyth prices fresh
│   │   └── tx.rs           # Transaction submission, nonce mgmt
│   └── Cargo.toml
│
├── gaekju-sdk/         # Rust SDK for traders
│   ├── src/
│   │   ├── lib.rs
│   │   ├── client.rs       # GaekjuClient: REST + contract calls
│   │   ├── ws.rs           # WebSocket subscription client
│   │   ├── signer.rs       # Transaction signing
│   │   └── builder.rs      # Order builder helpers
│   └── Cargo.toml
│
└── gaekju-cli/         # Admin + trading CLI
    ├── src/
    │   ├── main.rs
    │   ├── commands/
    │   │   ├── mod.rs
    │   │   ├── admin.rs    # deploy, create-market, pause
    │   │   ├── trade.rs    # deposit, buy, sell, cancel
    │   │   └── info.rs     # orderbook, positions, markets
    │   └── config.rs       # CLI config (RPC URL, keys, etc.)
    └── Cargo.toml
```

### 4.2 Key Dependencies

```toml
# Workspace Cargo.toml
[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
alloy = { version = "0.12" }           # Ethereum types, providers, contracts
axum = "0.8"                            # HTTP/WS framework
sqlx = { version = "0.8", features = ["postgres", "runtime-tokio"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tracing = "0.1"
tracing-subscriber = "0.3"
clap = { version = "4", features = ["derive"] }
eyre = "0.6"                            # Error handling
tokio-tungstenite = "0.24"              # WebSocket client
tower = "0.5"                           # Middleware (rate limiting, etc.)
tower-http = { version = "0.6", features = ["cors", "compression"] }
prometheus = "0.13"                     # Metrics
```

### 4.3 Indexer Detail

The indexer maintains a real-time mirror of on-chain state in PostgreSQL.

**Database schema:**

```sql
-- Markets
CREATE TABLE markets (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    tick_size   NUMERIC NOT NULL,
    lot_size    NUMERIC NOT NULL,
    max_leverage NUMERIC NOT NULL,
    active      BOOLEAN DEFAULT true,
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- Orders (current state)
CREATE TABLE orders (
    order_id    BIGINT PRIMARY KEY,
    market_id   INTEGER REFERENCES markets(id),
    trader      BYTEA NOT NULL,         -- address
    side        BOOLEAN NOT NULL,        -- true=buy
    price       NUMERIC NOT NULL,
    size        NUMERIC NOT NULL,        -- remaining size
    original_size NUMERIC NOT NULL,
    order_type  SMALLINT NOT NULL,
    status      SMALLINT NOT NULL,       -- open, filled, cancelled
    created_at  TIMESTAMPTZ NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL
);

-- Trades (immutable history)
CREATE TABLE trades (
    id          BIGSERIAL PRIMARY KEY,
    market_id   INTEGER REFERENCES markets(id),
    maker       BYTEA NOT NULL,
    taker       BYTEA NOT NULL,
    price       NUMERIC NOT NULL,
    size        NUMERIC NOT NULL,
    taker_side  BOOLEAN NOT NULL,
    tx_hash     BYTEA NOT NULL,
    block_number BIGINT NOT NULL,
    timestamp   TIMESTAMPTZ NOT NULL
);

-- Positions (current state)
CREATE TABLE positions (
    account     BYTEA NOT NULL,
    market_id   INTEGER NOT NULL,
    size        NUMERIC NOT NULL,        -- signed: positive=long, negative=short
    entry_price NUMERIC NOT NULL,
    collateral  NUMERIC NOT NULL,
    last_funding_index NUMERIC NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (account, market_id)
);

-- Funding rate history
CREATE TABLE funding_rates (
    id          BIGSERIAL PRIMARY KEY,
    market_id   INTEGER REFERENCES markets(id),
    rate        NUMERIC NOT NULL,
    cumulative  NUMERIC NOT NULL,
    timestamp   TIMESTAMPTZ NOT NULL
);

-- Account balances (current state)
CREATE TABLE accounts (
    address     BYTEA PRIMARY KEY,
    balance     NUMERIC NOT NULL DEFAULT 0,
    locked_margin NUMERIC NOT NULL DEFAULT 0,
    order_margin NUMERIC NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL
);

-- Indexer state (for resuming after restart)
CREATE TABLE indexer_state (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL
);
-- Stores: last_indexed_block, last_confirmed_block

CREATE INDEX idx_orders_market_status ON orders(market_id, status);
CREATE INDEX idx_orders_trader ON orders(trader);
CREATE INDEX idx_trades_market_time ON trades(market_id, timestamp DESC);
CREATE INDEX idx_trades_maker ON trades(maker);
CREATE INDEX idx_trades_taker ON trades(taker);
CREATE INDEX idx_positions_market ON positions(market_id);
CREATE INDEX idx_funding_market_time ON funding_rates(market_id, timestamp DESC);
```

**Reorg handling:**
- Keep a rolling window of N blocks of raw event logs
- On reorg: delete events from reorged blocks, re-index from fork point
- OP Stack has soft finality at ~2 minutes, use 10-block confirmation depth

### 4.4 API Server Detail

**REST endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/markets` | List all markets with configs |
| GET | `/v1/markets/{id}` | Single market info |
| GET | `/v1/markets/{id}/orderbook?depth=N` | Orderbook snapshot (bids/asks) |
| GET | `/v1/markets/{id}/trades?limit=N` | Recent trades |
| GET | `/v1/markets/{id}/funding` | Current and historical funding rates |
| GET | `/v1/markets/{id}/stats` | 24h volume, open interest, etc. |
| GET | `/v1/account/{addr}` | Account overview (balance + positions) |
| GET | `/v1/account/{addr}/positions` | All open positions |
| GET | `/v1/account/{addr}/orders` | All open orders |
| GET | `/v1/account/{addr}/trades?limit=N` | Trade history |
| GET | `/v1/account/{addr}/funding` | Funding payment history |
| GET | `/health` | Health check |
| GET | `/metrics` | Prometheus metrics |

**WebSocket streams:**

```
Connect: ws://api.gaekju.xyz/ws

Subscribe:
  {"method": "subscribe", "channel": "orderbook", "market": 0}
  {"method": "subscribe", "channel": "trades", "market": 0}
  {"method": "subscribe", "channel": "positions", "account": "0x..."}
  {"method": "subscribe", "channel": "orders", "account": "0x..."}

Messages:
  {"channel": "orderbook", "market": 0, "data": {"bids": [...], "asks": [...], "seq": 123}}
  {"channel": "trades", "market": 0, "data": {"price": "60000.5", "size": "0.1", ...}}
  {"channel": "positions", "data": {"market": 0, "size": "0.5", "entryPrice": "60000", ...}}
```

### 4.5 Keeper Bot Detail

**Liquidation keeper loop:**
```rust
loop {
    let block = provider.get_block_number().await?;
    for market in active_markets {
        let positions = db.get_open_positions(market.id).await?;
        for pos in positions {
            let liquidatable = liquidation_engine
                .isLiquidatable(pos.account, market.id)
                .call().await?;
            if liquidatable {
                let tx = liquidation_engine
                    .liquidate(pos.account, market.id)
                    .send().await?;
                tracing::info!(?tx, account = ?pos.account, "liquidation submitted");
            }
        }
    }
    // Wait for next block
    provider.subscribe_blocks().await?.next().await;
}
```

**Funding keeper:**
```rust
loop {
    for market in active_markets {
        let state = funding_rate.fundingStates(market.id).call().await?;
        let next_funding = state.lastFundingTime + state.fundingInterval;
        if now() >= next_funding {
            // Update Pyth price first
            let price_data = pyth_client.get_latest_price_feeds(&[market.pyth_id]).await?;
            oracle_adapter.updatePrice(market.id, price_data).send().await?;
            // Then apply funding
            funding_rate.applyFunding(market.id).send().await?;
        }
    }
    tokio::time::sleep(Duration::from_secs(60)).await;
}
```

---

## 5. Documentation & Project Structure

### 5.1 Full Project Layout

```
gaekju/
├── contracts/                    # Foundry project
│   ├── src/
│   │   ├── Settlement.sol          # verifies SP1 proof, applies batch delta
│   │   ├── PositionManager.sol
│   │   ├── MarginEngine.sol
│   │   ├── LiquidationEngine.sol
│   │   ├── FundingRate.sol
│   │   ├── OracleAdapter.sol
│   │   ├── Vault.sol
│   │   ├── MarketFactory.sol       # thin config registry
│   │   ├── Router.sol              # deposit / withdraw / forceInclude
│   │   ├── interfaces/
│   │   │   ├── ISettlement.sol
│   │   │   ├── IPositionManager.sol
│   │   │   ├── IMarginEngine.sol
│   │   │   ├── ILiquidationEngine.sol
│   │   │   ├── IFundingRate.sol
│   │   │   ├── IOracleAdapter.sol
│   │   │   ├── IVault.sol
│   │   │   └── IRouter.sol
│   │   └── libraries/
│   │       └── FixedPointMath.sol
│   ├── test/
│   │   ├── unit/
│   │   ├── integration/
│   │   ├── fuzz/
│   │   └── invariant/
│   ├── script/
│   │   ├── Deploy.s.sol
│   │   ├── CreateMarket.s.sol
│   │   └── SeedLiquidity.s.sol
│   └── foundry.toml
│
├── crates/                       # Rust workspace
│   ├── gaekju-types/
│   ├── gaekju-matcher/             # deterministic matcher (shared with SP1 guest)
│   ├── gaekju-sequencer/           # off-chain stateful matcher service
│   ├── gaekju-prover/              # SP1 host + guest program
│   ├── gaekju-indexer/
│   ├── gaekju-api/
│   ├── gaekju-keeper/
│   ├── gaekju-sdk/
│   ├── gaekju-cli/
│   └── gaekju-mirror/              # Lighter liquidity mirror (targets sequencer)
│
├── docs/
│   ├── specs/
│   │   └── 2026-04-06-gaekju-design.md   # This document
│   ├── adr/
│   │   ├── README.md
│   │   ├── 0001-use-lighter-clob.md
│   │   ├── 0002-modular-contracts.md
│   │   ├── 0003-bitmap-orderbook.md
│   │   ├── 0004-pyth-oracle.md
│   │   ├── 0005-usdc-collateral.md
│   │   ├── 0006-isolated-margin.md
│   │   ├── 0007-rust-backend.md
│   │   ├── 0008-alloy-over-ethers.md
│   │   └── 0009-uups-proxy.md
│   ├── guides/
│   │   ├── getting-started.md
│   │   ├── local-development.md
│   │   ├── deploying.md
│   │   ├── adding-a-market.md
│   │   ├── running-keepers.md
│   │   └── market-making.md
│   ├── api/
│   │   ├── rest-api.md
│   │   ├── websocket-api.md
│   │   ├── error-codes.md
│   │   └── openapi.yaml
│   ├── architecture/
│   │   ├── overview.md
│   │   ├── contracts.md
│   │   ├── rust-backend.md
│   │   └── data-flow.md
│   ├── blog/
│   │   ├── README.md
│   │   ├── 00-why-gaekju.md
│   │   ├── 01-choosing-architecture.md
│   │   ├── 02-bitmap-orderbook.md
│   │   ├── 03-margin-from-scratch.md
│   │   ├── 04-liquidation-math.md
│   │   ├── 05-funding-rates.md
│   │   ├── 06-rust-indexer.md
│   │   ├── 07-keeper-bots.md
│   │   ├── 08-testing-defi.md
│   │   ├── 09-deploying-op-stack.md
│   │   └── 10-lessons-learned.md
│   └── reference/
│       ├── glossary.md
│       ├── formulas.md
│       └── market-configs.md
│
├── .github/
│   ├── CONTRIBUTING.md
│   ├── CODE_OF_CONDUCT.md
│   ├── SECURITY.md
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   ├── feature_request.md
│   │   └── market_listing.md
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── workflows/
│       ├── ci.yml
│       ├── slither.yml
│       └── release.yml
│
├── docker/
│   ├── Dockerfile.indexer
│   ├── Dockerfile.api
│   ├── Dockerfile.keeper
│   └── docker-compose.yml        # Full stack: DB + indexer + API + keeper
│
├── Cargo.toml                    # Rust workspace root
├── foundry.toml                  # → contracts/foundry.toml symlink
├── CHANGELOG.md
├── LICENSE                       # MIT
├── README.md
└── CLAUDE.md
```

### 5.2 ADR Template

Each ADR follows this format:
```markdown
# ADR-NNNN: [Title]

## Status
Proposed | Accepted | Deprecated | Superseded by ADR-XXXX

## Date
YYYY-MM-DD

## Context
What is the problem or decision we're facing?

## Decision
What did we decide and why?

## Consequences
### Positive
- What becomes easier?

### Negative
- What becomes harder?

### Neutral
- What stays the same but is worth noting?

## Alternatives Considered
### [Alternative A]
- Pros: ...
- Cons: ...
- Why rejected: ...
```

### 5.3 Blog Series: "Building a Perp DEX from Scratch"

Each blog post maps to a build phase:

| # | Title | Phase | Key Topics |
|---|-------|-------|------------|
| 00 | Why We're Building Gaekju | Pre | Motivation, Giwa Chain, market gap |
| 01 | Choosing a Perp DEX Architecture | Pre | CLOB vs AMM vs hybrid, why Lighter model |
| 02 | Building a Bitmap Orderbook | 1 | How bitmap CLOBs work, gas analysis, code walkthrough |
| 03 | Margin Systems from Scratch | 1 | IMR/MMR, isolated vs cross, leverage math |
| 04 | Liquidation: Protecting the Protocol | 2 | Partial liquidation, insurance fund, ADL |
| 05 | How Perp Funding Rates Actually Work | 3 | Funding math, TWAP, implementation details |
| 06 | Building an L2 Indexer in Rust | 4 | Event processing, reorg handling, async Rust patterns |
| 07 | Keeper Bots: The Unseen Infrastructure | 4 | Liquidation bots, gas management, MEV |
| 08 | Fuzz Testing a DeFi Protocol | All | Foundry fuzz, invariant testing, what we caught |
| 09 | Deploying to an OP Stack Testnet | 5 | CREATE2, verification, monitoring setup |
| 10 | Lessons from Building a Perp DEX | 5 | What worked, what didn't, what's next |

Blog publishing flow:
1. Write draft in `docs/blog/`
2. Peer review
3. Publish to Mirror.xyz (primary — web3 native, onchain attestation)
4. Cross-post to dev.to and hashnode (developer audience)
5. Twitter/X thread with key takeaways
6. Link from README and CHANGELOG

---

## 6. Build Phases (Final Detailed Version)

Phases 1–4 ran under Path A. They delivered Vault, OracleAdapter, MarginEngine, PositionManager, LiquidationEngine, and an on-chain OrderBook with 131 green tests. Under ADR-0012 the on-chain OrderBook, bitmap libs, and Phase 3 MarketFactory/Router/Advanced-Orders work are deleted. All other Phase 1–2 contracts survive with caller-guard rebind (ORDERBOOK_ROLE → SETTLEMENT_ROLE).

The active forward plan is Phases 5–10 below. The historical Path A phase content is preserved in `docs/plans/archive/` for reference and is not reproduced here.

### Phase 5 — Contracts v2 (weeks 1–3 of pivot)

Goal: on-chain contracts ready to receive proven batches.

- [ ] Delete `OrderBook.sol`, `IOrderBook.sol`, `BitmapLib.sol`, `TickMath.sol`, `PackedOrder.sol` and all OrderBook-coupled tests
- [ ] Rebind caller guard on Vault, PositionManager, MarginEngine from `ORDERBOOK_ROLE` to `SETTLEMENT_ROLE`; update all surviving tests
- [ ] Vault: add `applyBatchDelta(uint256 nonce, BalanceDelta[])`; unit + invariant tests
- [ ] PositionManager: add `applyBatchFills(uint256 nonce, Fill[])`; retain per-fill path for liquidation; unit tests
- [ ] Implement `Settlement.sol`: stateRoot, batchNonce monotonicity, SP1 verifier binding, programVKey commit, batch-blob decoder, force-include deadline check
- [ ] Integrate a mock SP1 verifier for local testing (`MockSp1Verifier`) that accepts any proof
- [ ] Update `Router.sol`: strip all order-placement entries; implement deposit/withdraw/forceInclude/cancelForcedInclude
- [ ] MarketFactory: strip per-market OrderBook deployment; retain params registry + pause flags
- [ ] Integration test: happy-path applyBatch with mock verifier drives Vault + PositionManager state correctly
- [ ] Integration test: force-include deadline expiry pauses matching
- [ ] Integration test: replay attempt (same nonce twice) reverts
- [ ] Phase 5 wrap-up: blog post "Rewiring Gaekju for Proven Matching", tag v0.6.0

### Phase 6 — Sequencer (weeks 4–6)

Goal: standalone Rust service accepts signed intents and emits deterministic batches.

- [ ] `crates/gaekju-matcher`: pure `no_std`-compatible Rust matcher — price-time priority, post-only/IOC/FOK/reduce-only, self-trade prevention, tick/lot enforcement, deterministic tie-break
- [ ] Property tests on matcher (order-of-operations invariance under equivalent event sequences, no negative sizes, fills-conservation)
- [ ] `crates/gaekju-sequencer`:
  - [ ] EIP-712 intent type + verifier
  - [ ] REST: POST /v1/intents, GET /v1/orderbook/{market}, GET /v1/account/{addr}/open
  - [ ] WS: subscribe `orderbook`, `trades`, `user:{addr}` soft-ack stream
  - [ ] Per-account monotonic nonce store (in-memory + WAL to disk)
  - [ ] Batch builder: closes on max-intents / max-fills / max-time (parameterized)
  - [ ] On-chain observer for forced-include intents; auto-injects into batch within deadline
  - [ ] On-chain observer for liquidations / deposits / withdrawals; reconciles in-memory state
- [ ] Integration test (in-memory chain via Anvil): sequencer accepts EIP-712 intent → emits batch → Settlement with mock verifier applies delta
- [ ] Phase 6 wrap-up: blog post "Building a Deterministic Rust Matcher", tag v0.7.0

### Phase 7 — Prover (weeks 7–9)

Goal: real SP1 proofs of matcher execution over batch blobs.

- [ ] `crates/gaekju-prover`:
  - [ ] SP1 guest program wrapping `gaekju-matcher` — reads prevStateRoot, batch blob, Pyth attestations; writes postStateRoot
  - [ ] Host runner: dispatches proof generation (local dev via `sp1-sdk` cpu, remote via Succinct Prover Network)
  - [ ] Public inputs commitment: `keccak256(abi.encode(BatchPublicInputs))` — `(prevStateRoot, postStateRoot, batchHash, batchNonce, chainId, forceIncludeCursor)` per §14.1
  - [ ] Vkey export for Settlement bootstrap
- [ ] Wire real SP1 verifier in `Settlement.sol` (swap out MockSp1Verifier)
- [ ] Gas benchmark: real EVM verification target ≤ 350k gas per batch
- [ ] End-to-end test: sequencer → prover → Settlement on local Anvil with real verifier
- [ ] Phase 7 wrap-up: blog post "Proving the Matcher with SP1", tag v0.8.0

### Phase 8 — Indexer, API, Keeper (weeks 10–11)

Goal: external surface for users and ops.

- [ ] Indexer: add `BatchSettled`, `ForceIncludeQueued`, `ForcedIntentResolved`, `SequencerRotated` event decoding; split pending (from sequencer WS) vs finalized (from Settlement events) state; reorg-safe
- [ ] API: REST + WS as before, plus `GET /v1/batches/:nonce`, `GET /v1/proofs/:nonce`, `pending` vs `finalized` tags on all position/order views
- [ ] Keeper: unchanged liquidation logic; add a watchdog that emits a metric when a force-included intent is approaching its deadline
- [ ] SDK / CLI: user operations submit EIP-712 intents to the sequencer; only deposit/withdraw/forceInclude hit the chain directly
- [ ] Phase 8 wrap-up: blog post "Soft-Confirm UX: Pending vs Finalized", tag v0.9.0

### Phase 9 — Integration & hardening (weeks 12–13)

- [ ] End-to-end load test: 500 intents/sec for 1 hour, measure batch cadence, proof latency, gas burn
- [ ] Chaos: sequencer kill / restart, prover kill / restart, Giwa reorgs, Pyth stale feeds
- [ ] Force-inclusion drill: simulate censorship, verify deadline triggers pause
- [ ] Security review: Slither on contracts, `cargo audit` + `cargo deny` on crates, invariant campaign (§10)
- [ ] Phase 9 wrap-up: tag v0.9.5

### Phase 10 — Testnet launch (weeks 14–16)

- [ ] Deploy Settlement + surviving contracts to Giwa testnet with real SP1 verifier
- [ ] Deploy sequencer + prover on VPS; configure Succinct Prover Network endpoints
- [ ] Deploy indexer/API/keeper
- [ ] Seed markets via MarketFactory; spin up Lighter mirror pointed at sequencer
- [ ] Faucet USDC; onboard first external traders
- [ ] Phase 10 wrap-up: v1.0.0-testnet

### Historical Phases 1–5 (archived — Path A)

Phase 1 (Foundation & OrderBook), Phase 2a (Position Mgmt), Phase 2b (Liquidation), Phase 3 (Funding/Factory/Router/Advanced Orders), Phase 4 (Rust infra), Phase 5 (Testnet) as originally scoped are preserved in `docs/plans/archive/` and `docs/plans/2026-04-*-phase*.md` with pivot banners. Under ADR-0012 only the survivors listed above (Vault, OracleAdapter, MarginEngine, PositionManager, LiquidationEngine, FundingRate math) carry forward.

---

## 7. Technical Decisions (ADR Summary)

| ADR | Decision | Key Rationale |
|-----|----------|---------------|
| 0001 | ~~On-chain CLOB (Lighter model)~~ — **superseded by 0012** | EVM matching not economically viable for perp CLOB at scale |
| 0002 | Modular contracts | Independent upgrades, clean testing, contract size limits |
| 0003 | ~~Bitmap orderbook~~ — **superseded by 0012** | Orderbook state moves off-chain |
| 0004 | Pyth Network oracle | Pull-based, sub-second updates, L2 native |
| 0005 | USDC-only collateral | Simplifies accounting, no haircut calculations |
| 0006 | Isolated margin (v1) | Simpler risk model, cross-margin in v2 |
| 0007 | Rust for backend + matcher | Same crate runs in sequencer and SP1 guest |
| 0008 | Alloy over ethers-rs | Actively maintained, better type generation |
| 0009 | UUPS proxy pattern | Clean upgrade path (gas argument no longer load-bearing) |
| 0010 | Lighter mirror | Live depth for testnet; retargeted to sequencer endpoint |
| 0011 | 1-hour funding interval | Matches Lighter; more responsive than 8h |
| 0012 | zkVM-proven off-chain matcher | Three-layer architecture; supersedes 0001/0003 |
| 0013 | SP1 zkVM framework | EVM verifier ~300k gas, Rust guest, Succinct prover network |
| 0014 | Sequencer trust model + force-include | Bounded censorship latency; post-batch root commit |
| 0015 | Proof batching and settlement cadence | Batch close on size/time; one proof per batch |

---

## 8. Formulas & Math

All values use 18-decimal fixed-point (`1e18 = 1.0`). All multiplications use `mulFp(a, b) = a * b / 1e18`. All divisions use `divFp(a, b) = a * 1e18 / b`. USDC amounts are converted from 6-decimal to 18-decimal at the Vault boundary.

### Margin

```
initialMarginRate (IMR):    per-market config, e.g., 2e16 = 2% for 50x
maintenanceMarginRate (MMR): per-market config, e.g., 1e16 = 1%
  // IMR and MMR are independently configured per market (not auto-derived)

notionalValue = mulFp(abs(positionSize), markPrice)
  // = abs(positionSize) * markPrice / 1e18

requiredMargin = mulFp(notionalValue, IMR)
  // = notionalValue * IMR / 1e18

marginRatio = divFp(collateral + unrealizedPnL, notionalValue)
  // = (collateral + unrealizedPnL) * 1e18 / notionalValue
  // Returns type(uint256).max when notionalValue == 0
```

### PnL

```
// All in 18-decimal fixed-point
unrealizedPnL = mulFp(markPrice - entryPrice, positionSize)
  // = (markPrice - entryPrice) * positionSize / 1e18
  // positionSize is positive for long, negative for short
  // Result is int256: positive = profit, negative = loss

// For explicit long/short:
unrealizedPnL (long)  = mulFp(markPrice - entryPrice, positionSize)   // size > 0
unrealizedPnL (short) = mulFp(markPrice - entryPrice, positionSize)   // size < 0, auto-negates
```

### Weighted Average Entry Price

```
newEntryPrice = divFp(
    mulFp(oldEntryPrice, abs(oldSize)) + mulFp(fillPrice, abs(fillSize)),
    abs(oldSize) + abs(fillSize)
)
// = (oldEntryPrice * oldSize / 1e18 + fillPrice * fillSize / 1e18) * 1e18 / (oldSize + fillSize)
```

### Liquidation

```
isLiquidatable = marginRatio < MMR

// Partial liquidation — solve for reduceSize where POST-FEE marginRatio = IMR
// Let equity = collateral + unrealizedPnL
// Let feeRate = liquidatorFeeRate + insuranceFundFeeRate
// After reducing by reduceSize at markPrice:
//   newEquity = equity - mulFp(mulFp(reduceSize, markPrice), feeRate)
//   newNotional = mulFp(abs(pos.size) - reduceSize, markPrice)
//   target: newEquity / newNotional = IMR
// Solving:
reduceSize = divFp(
    mulFp(IMR, notionalValue) - equity,
    mulFp(markPrice, IMR + feeRate - 1e18)
)
// If reduceSize > position.size or equity <= 0: full liquidation

liquidationFee = mulFp(mulFp(reduceSize, markPrice), feeRate)
  // = reduceSize * markPrice * feeRate / 1e18 / 1e18
```

### Funding Rate

```
// fundingRate is a dimensionless premium ratio (18-decimal)
fundingRate = clamp(
    divFp(markPrice - indexPrice, indexPrice),
    -maxFundingRate,
    +maxFundingRate
)
// Note: markPrice uses oracle+orderbook blend, indexPrice is pure oracle
// These diverge when orderbook trades away from oracle, producing non-zero funding

// Funding payment is USDC-denominated (multiply by markPrice to convert from base units)
fundingDelta = currentCumulativeFunding - positionLastCumulativeFunding
fundingPayment = mulFp(mulFp(positionSize, fundingDelta), markPrice)
  // = positionSize * fundingDelta * markPrice / 1e18 / 1e18
  // Positive payment = longs pay, negative = shorts pay (when funding is positive)

// Missed funding intervals: if >1 interval has elapsed, keeper applies each
// sequentially. No catch-up multiplier — each interval calculates independently.
```

---

## 9. Market Configurations

All markets are mirrored from Lighter.xyz. Leverage and margin configs follow Lighter's specs with Gaekju-specific adjustments.

### Crypto Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| BTC-USD | 50x | 2% | 1.2% | $0.10 | 0.00001 BTC | 1h |
| ETH-USD | 50x | 2% | 1.2% | $0.01 | 0.0001 ETH | 1h |
| SOL-USD | 25x | 4% | 2.4% | $0.001 | 0.001 SOL | 1h |
| OP-USD | 20x | 5% | 3% | $0.0001 | 0.1 OP | 1h |
| ARB-USD | 20x | 5% | 3% | $0.0001 | 0.1 ARB | 1h |
| DOGE-USD | 20x | 5% | 3% | $0.00001 | 1 DOGE | 1h |
| + 50 more crypto pairs | varies | varies | varies | varies | varies | 1h |

### Korean Market Perpetuals (KRW-quoted)

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| KRCOMP (KRX Index) | 10x | 10% | 6% | ₩10 | 0.01 units | 1h |
| SAMSUNG | 10x | 10% | 6% | ₩100 | 0.01 shares | 1h |
| SKHYNIX | 10x | 10% | 6% | ₩100 | 0.01 shares | 1h |
| HYUNDAI | 10x | 10% | 6% | ₩100 | 0.01 shares | 1h |
| HANMI | 10x | 10% | 6% | ₩10 | 0.1 shares | 1h |

### US Equity & Index Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| SPY (S&P 500) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| QQQ (Nasdaq-100) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| DIA (Dow Jones) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| IWM (Russell 2000) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| MAGS (Mag 7 ETF) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |
| BOTZ (Robotics/AI) | 10x | 10% | 6% | $0.01 | 0.01 units | 1h |

### Forex Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| EUR-USD | 25x | 4% | 2.4% | $0.0001 | 100 EUR | 1h |
| USD-KRW | 25x | 4% | 2.4% | ₩0.1 | 1000 USD | 1h |
| USD-JPY | 25x | 4% | 2.4% | ¥0.01 | 1000 USD | 1h |
| GBP-USD | 25x | 4% | 2.4% | $0.0001 | 100 GBP | 1h |
| USD-CHF | 25x | 4% | 2.4% | CHF0.0001 | 1000 USD | 1h |
| NZD-USD | 25x | 4% | 2.4% | $0.0001 | 100 NZD | 1h |

### Commodity Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Funding |
|--------|-------------|-----|-----|-----------|----------|---------|
| XAU (Gold) | 10x | 10% | 6% | $0.01 | 0.01 oz | 1h |
| XAG (Silver) | 10x | 10% | 6% | $0.001 | 1 oz | 1h |
| COPPER | 10x | 10% | 6% | $0.001 | 1 lb | 1h |
| PLATINUM | 10x | 10% | 6% | $0.01 | 0.01 oz | 1h |
| PALLADIUM | 10x | 10% | 6% | $0.01 | 0.01 oz | 1h |
| WTI (Crude Oil) | 10x | 10% | 6% | $0.01 | 0.1 bbl | 1h |
| NATGAS | 10x | 10% | 6% | $0.001 | 1 MMBtu | 1h |
| BRENT | 10x | 10% | 6% | $0.01 | 0.1 bbl | 1h |

**Total: ~80+ markets at launch** (all mirrored from Lighter, more added by config)

---

## 10. Security Considerations

### Smart Contract Risks
- **Reentrancy:** All state changes before external calls. Use ReentrancyGuard on Vault, Router, and all multi-contract flows (LiquidationEngine, OrderBook matching). CEI (Checks-Effects-Interactions) pattern everywhere.
- **Oracle manipulation:** Staleness checks, confidence band validation, max price deviation between consecutive updates (e.g., max 10% move per update to detect oracle manipulation).
- **Integer overflow:** Solidity 0.8+ default checked arithmetic. Use unchecked blocks only for proven-safe loops.
- **Access control:** Role-based (OpenZeppelin AccessControl). Only authorized contracts call internal functions.
- **Front-running:** On OP Stack, sequencer orders transactions. Post-Only orders protect makers from sandwich attacks. Self-trade prevention: orders from the same account cannot match each other.
- **Flash loan attacks:** Margin checks prevent zero-capital position opening. Deposits require actual USDC transfer (not flash-loanable within same tx as trading). Oracle prices are external, not manipulable via flash loans on the DEX itself.
- **Dust positions:** Minimum position size enforced. Positions below minOrderSize after partial close are fully closed. Orders below minOrderSize after partial fill are cancelled.

### Upgrade & Admin Security
- **Timelock:** All admin operations (upgrade, market config changes, pause) go through a 24-hour timelock contract. Emergency pause bypasses timelock but can only pause, not upgrade.
- **Multisig:** Admin is a 3-of-5 multisig (Gnosis Safe). No single key can upgrade contracts.
- **Emergency mode:** Admin can pause individual markets or the entire protocol. Paused state: no new orders, no new positions, but withdrawals and position closes still work.

### Insurance Fund & Loss Waterfall
- **Per-market insurance fund:** Each market has its own insurance sub-fund to prevent cross-market contagion. Global insurance fund exists as a backstop.
- **Loss waterfall:**
  1. Liquidation fees cover the loss
  2. Per-market insurance fund covers the deficit
  3. Global insurance fund covers remaining deficit
  4. ADL: auto-deleverage profitable traders on the opposite side
  5. If all above exhausted: socialized loss across all position holders in that market (proportional to position size)

### Degraded Mode Operations
- **Oracle stale:** Market enters cancel-only mode. No new orders, no new positions. Existing orders can be cancelled. Withdrawals allowed if not margin-locked. Liquidations paused (cannot liquidate on stale price).
- **Sequencer downtime:** Forced inclusion via L1 (standard OP Stack). On sequencer recovery, keepers catch up on missed liquidations and funding intervals.
- **Missed funding intervals:** Keeper applies each missed interval sequentially. No catch-up multiplier — each uses the price at application time.

### Proven-Batch Integrity (Path B)

The on-chain `bestBid < bestAsk` / `orderId → owner` / `TickBitmap` invariants of Path A are gone — there is no on-chain book to check. Settlement enforces a narrower set of invariants sufficient to make matching correctness equivalent to on-chain execution.

- **Batch nonce strictly monotonic:** `applyBatch` requires `bundle.publicInputs.batchNonce == batchNonce + 1`. Enforced atomically with state-root update. No replay, no gaps, no reorder.
- **Prev-state-root continuity:** `BatchPublicInputs.prevStateRoot` must equal the stored `stateRoot`. Guarantees linear history.
- **Proof validity + vkey binding:** `verifier.verifyProof(programVKey, abi.encode(BatchPublicInputs), sp1Proof)` must pass. `programVKey` is a storage slot rotated via pause-and-drain (§15.5); any change requires timelock + sequencer drain. Prevents "valid proof of wrong program."
- **Chain-id binding:** `BatchPublicInputs.chainId == block.chainid`. Prevents proof replay on a sibling chain or testnet fork.
- **Public-inputs commitment:** `BatchPublicInputs` = `(prevStateRoot, postStateRoot, batchHash, batchNonce, chainId, forceIncludeCursor)`. `batchHash == keccak256(abi.encode(BatchBlob))` binds every decoded delta to the proof.
- **Fills conservation:** for any batch, `Σ(balanceDelta.freeDelta) + Σ(lockedMarginDelta) + Σ(orderMarginDelta) + Σ(realizedPnlDelta) + insuranceFundDelta + feeDelta == 0`. Checked by Settlement after decoding. Any deviation rejects the batch.
- **Force-inclusion bound:** every `pendingForcedIntent` whose `deadlineBatchNonce <= bundle.publicInputs.batchNonce` must have a proved outcome in `BatchBlob.forcedOutcomes` (accepted-with-fill or rejected-with-reason code — see §15.2). Else `applyBatch` reverts with `ForcedIntentOverdue`, halting new batches until governance clears the queue. The sequencer cannot falsely mark "resolved" because outcomes are proved inside the zkVM.
- **Force-include cursor monotonicity:** `bundle.publicInputs.forceIncludeCursor >= stored forceIncludeCursor`.
- **Self-trade prevention:** enforced inside the proven matcher program; a sequencer that produced a self-trade would fail to prove.
- **Per-account nonce monotonicity:** each intent carries a monotonic per-account nonce; the matcher rejects stale or duplicate nonces, and the proof commits to this.
- **Pyth attestation binding:** any mark-price or index-price used by matcher (e.g., reduce-only checks against oracle, or sequencer mid emission) is committed by its Pyth attestation inside the batch blob (`attestedPriceIds` + `attestedPriceHashes`).

### Testing Requirements
- 100% branch coverage on all contracts
- Fuzz testing on all math functions (minimum 10,000 runs)
- Invariant testing on system-wide properties
- Slither + Mythril static analysis with zero high/medium findings

---

## 11. Live Market Operations — Lighter Mirror + Testnet Traders

> **Path B note (2026-04-22):** The mirror design below is unchanged in intent but retargeted. Under ADR-0012 there is no on-chain OrderBook. The mirror agent now submits EIP-712 signed intents to the Rust sequencer's `POST /v1/intents` endpoint (same EOA signing, different nonce scheme — per-account monotonic instead of chain nonce). All references below to "Gaekju on-chain orderbook", "Router.batchPlaceOrders", "batch_cancel" contracts, and "tx inclusion" should be read as "sequencer intents, soft-acked in <50ms, finalized on batch proof." The Lighter mirror's behavior (diff + scale + submit) is otherwise identical and remains in Phase 10 (testnet launch) of the revised plan.

Gaekju connects to **Lighter.xyz** as its liquidity source. Lighter has 220+ perpetual markets including crypto, forex, and commodities — all with free unauthenticated API access. Real Lighter orderbook depth is mirrored onto Gaekju. Testnet users trade against this real-world depth through the sequencer, and their intents coexist with the mirrored intents in the same matching book.

**Why Lighter as the mirror source:**
- Gaekju follows Lighter's architecture family — **off-chain Rust matcher + zk-proven batches + on-chain settlement**. Lighter uses custom STARK→SNARK circuits; Gaekju uses SP1 zkVM (ADR-0013). The live-market model (deterministic matching, bounded ordering-fairness trust, on-chain finality) is shared.
- 220+ perp markets including RWA (EUR/USD, XAU/USD) — covers ALL Gaekju markets
- Free, unauthenticated public API for orderbook + trade data
- WebSocket with 50ms update frequency
- Already has the exact market types we need (crypto + forex + commodities)

### 11.1 System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Gaekju Live Market System                     │
│                                                                       │
│   Lighter.xyz                    Gaekju (Giwa L2)                    │
│   ┌──────────────┐              ┌──────────────────────────────┐    │
│   │ 220+ perp    │  WebSocket   │        On-Chain Orderbook     │    │
│   │ markets      │────────────▶│                                │    │
│   │ BTC, ETH,    │              │  ┌────────────────────────┐  │    │
│   │ SOL, EUR,    │              │  │  Mirrored Depth        │  │    │
│   │ XAU, ...     │   Mirror     │  │  (from Lighter)        │  │    │
│   └──────────────┘   Agent      │  ├────────────────────────┤  │    │
│                        (Rust)   │  │  Testnet User Orders   │  │    │
│   ┌──────────────┐      │      │  │  (from real users)     │  │    │
│   │ Real trades  │──────┘      │  └────────────────────────┘  │    │
│   │ (trade feed) │              │            │                  │    │
│   └──────────────┘              │     Matching Engine           │    │
│                                  │     (same rules for all)     │    │
│   ┌──────────────┐              │            │                  │    │
│   │ Pyth Oracle  │─────────────▶│     Oracle Adapter            │    │
│   │ (real prices)│              │     (mark + index price)      │    │
│   └──────────────┘              └──────────────────────────────┘    │
│                                          │                            │
│                                  ┌───────┴───────┐                   │
│                                  │  Testnet Users │                   │
│                                  │  trade against │                   │
│                                  │  real depth    │                   │
│                                  └───────────────┘                   │
└─────────────────────────────────────────────────────────────────────┘
```

### 11.2 The Mirror Agent (`gaekju-mirror`)

The Mirror Agent is the bridge between Lighter and Gaekju. It reads Lighter's live orderbook and trade feed, then places equivalent orders on Gaekju's on-chain orderbook.

#### How It Works

```
Lighter WebSocket API (info.hyperliquid.xyz/ws):
  - L2 orderbook snapshots (top N levels, pushed every 100ms)
  - Trade feed (every fill on Lighter, real-time)
  - Market info (funding rates, open interest, etc.)

Mirror Agent reads this data and translates it to Gaekju on-chain orders.
```

#### Orderbook Mirroring (Depth)

```
Every ~2 seconds (one Giwa block), the Mirror Agent:

  1. READ: Fetch Lighter BTC-PERP L2 orderbook (top 20 levels)

     Lighter book (real):
     ASK $60,010  2.50 BTC
     ASK $60,005  1.20 BTC
     ASK $60,003  0.80 BTC
     ASK $60,001  0.30 BTC
     ─── spread ───
     BID $59,999  0.25 BTC
     BID $59,997  0.90 BTC
     BID $59,995  1.50 BTC
     BID $59,990  3.00 BTC

  2. SCALE: Apply a depth multiplier (e.g., 0.1x = show 10% of real depth)
     This makes the book proportional to what Gaekju can handle.

     Scaled for Gaekju:
     ASK $60,010  0.25 BTC
     ASK $60,005  0.12 BTC
     ASK $60,003  0.08 BTC
     ASK $60,001  0.03 BTC
     ─── spread ───
     BID $59,999  0.025 BTC
     BID $59,997  0.09 BTC
     BID $59,995  0.15 BTC
     BID $59,990  0.30 BTC

  3. DIFF: Compare with currently live mirror orders on Gaekju
     - New levels to add? → Place limit orders
     - Levels that changed size? → Cancel + replace
     - Levels that disappeared? → Cancel
     - Levels that didn't change? → Leave alone (save gas)

  4. SUBMIT: Send batch transaction to Gaekju
     Router.batchPlaceOrders([...new/updated orders])
     Router.batchCancel([...stale orderIds])

  Result: Gaekju's orderbook tracks Lighter's within ~2 seconds.
```

#### Trade Mirroring (Activity)

```
When a real trade happens on Lighter:

  Lighter trade: BTC-PERP, 0.5 BTC @ $60,001, buyer aggressive

  Mirror Agent:
    1. Receives trade via WebSocket
    2. Records it for the Gaekju trade feed (via indexer/API)
    3. The mirrored orderbook already reflects this:
       - The ask at $60,001 that got filled on Lighter
         also gets removed from Gaekju's mirror on next refresh
       - Price movement is naturally reflected

  Trade feed on Gaekju shows TWO types of trades:
    a) Mirrored trades: real Lighter trades, displayed in the feed
       (tagged as "external" in the API, shown on the chart)
    b) Testnet trades: actual on-chain fills between testnet users
       and mirror orders (tagged as "local")

  Both appear on the same chart. Price movement comes from real markets.
```

#### Mirror Agent Account

```
The Mirror Agent operates a single on-chain account on Gaekju:

  Account: 0xMIRROR (dedicated address)
  Funded:  Unlimited testnet USDC (minted at deployment)
  Role:    Places and cancels orders that mirror Lighter depth

  This account:
  - Has special minting rights for testnet USDC (admin-granted)
  - Places real on-chain limit orders (Post-Only to avoid self-matching)
  - Can accumulate positions when testnet users fill against it
  - Positions are irrelevant (testnet USDC is free) — no risk management needed
  - Is publicly labeled: "Lighter Mirror" in API/frontend

  The account does NOT:
  - Execute any trading strategy
  - Make directional bets
  - Need inventory management (unlimited capital on testnet)
```

### 11.3 How Testnet Users Trade Against Real Depth

```
Scenario: Alice (testnet user) wants to long 0.1 BTC

  The Gaekju orderbook right now:
  ┌──────────────────────────────────────────────────┐
  │  ASK $60,010  0.25  [Mirror]                      │
  │  ASK $60,005  0.12  [Mirror]                      │
  │  ASK $60,003  0.08  [Mirror]                      │
  │  ASK $60,001  0.03  [Mirror] + 0.02 [Bob testnet] │ ← best ask
  │  ─── spread ───                                    │
  │  BID $59,999  0.025 [Mirror] + 0.05 [Carol testnet]│ ← best bid
  │  BID $59,997  0.09  [Mirror]                      │
  │  BID $59,995  0.15  [Mirror]                      │
  │  BIDS                                              │
  └──────────────────────────────────────────────────┘

  Alice submits: Market Buy 0.1 BTC

  Matching engine walks the ask side (no special treatment):
    Fill 1: 0.02 BTC @ $60,001 from Bob (testnet user)
    Fill 2: 0.03 BTC @ $60,001 from Mirror
    Fill 3: 0.05 BTC @ $60,003 from Mirror

  Results:
    Alice: LONG 0.1 BTC, avg entry $60,002.00
    Bob:   SHORT 0.02 BTC (his limit order got filled by Alice)
    Mirror: accumulates 0.08 BTC short position (doesn't matter — testnet)

  What makes this feel real:
  ✓ Alice got filled at a realistic price (tracks Lighter within 2s)
  ✓ The slippage was realistic (0.08 BTC ate through 3 price levels)
  ✓ Bob (another real testnet user) was on the other side of part of the fill
  ✓ The orderbook updates immediately on-chain
  ✓ Funding rates reflect real market conditions (via Pyth oracle)
```

### 11.4 Lighter API Integration

```
Lighter provides free, unauthenticated public API:

  REST Base URL:  https://mainnet.zklighter.elliot.ai/api/v1/
  WebSocket URL:  wss://mainnet.zklighter.elliot.ai/stream

  ── REST: Get all available markets ──
  GET /api/v1/orderBooks?filter=perp

  Response:
  {
    "order_books": [
      {
        "market_id": 1,
        "symbol": "BTC-PERP",
        "base_asset_id": 1,
        "quote_asset_id": 0,
        "taker_fee": "0.0005",
        "maker_fee": "0.0002",
        "min_base_amount": "0.00001",
        "price_decimals": 1,
        "amount_decimals": 5
      },
      ...  // 220+ perpetual markets
    ]
  }

  ── REST: Get orderbook depth ──
  GET /api/v1/orderBookOrders?market_id=1&limit=50

  Response:
  {
    "asks": [
      {"order_index": 42, "price": "60001.0", "remaining_base_amount": "0.30", "owner_account_index": 123},
      {"order_index": 43, "price": "60003.0", "remaining_base_amount": "0.80", "owner_account_index": 456},
      ...
    ],
    "bids": [
      {"order_index": 44, "price": "59999.0", "remaining_base_amount": "0.25", "owner_account_index": 789},
      ...
    ],
    "total_asks": 150,
    "total_bids": 180
  }

  ── REST: Get recent trades ──
  GET /api/v1/recentTrades?market_id=1&limit=100

  Response:
  {
    "trades": [
      {
        "price": "60001.0",
        "base_amount": "0.50",
        "side": "long",
        "taker_fee": "0.15",
        "maker_fee": "0.06",
        "timestamp": 1712419200456
      },
      ...
    ]
  }

  ── WebSocket: Real-time orderbook updates ──
  Connect: wss://mainnet.zklighter.elliot.ai/stream

  Subscribe to orderbook (updates every ~50ms):
    Subscribe to market data channels for order books, trades, BBO tickers

  Rate limits (unauthenticated):
    - 100 connections per IP
    - 1,000 total subscriptions
    - Keep-alive: 1 frame every 2 minutes
    - Auto-disconnect after 24 hours
```

#### Market Mapping — ALL Markets Mirrored

```
Lighter has 220+ perp markets. Gaekju mirrors ALL of them.
No market lacks a mirror source. Every Gaekju market has real Lighter depth.

  Lighter Market     →    Gaekju Market         Leverage
  ─────────────────────────────────────────────────────────
  Crypto:
  BTC-PERP (id:1)    →    BTC-USD (id: 0)       50x
  ETH-PERP (id:2)    →    ETH-USD (id: 1)       50x
  SOL-PERP (id:3)    →    SOL-USD (id: 2)       25x
  ARB-PERP           →    ARB-USD (id: 3)       20x
  OP-PERP            →    OP-USD  (id: 4)       20x
  DOGE-PERP          →    DOGE-USD (id: 5)      10x

  RWA (Lighter has these!):
  EUR/USD-PERP       →    EUR-USD (id: 6)       25x (Lighter) → 10x (Gaekju)
  GBP/USD-PERP       →    GBP-USD (id: 7)       25x → 10x
  PAXG-PERP          →    XAU-USD (id: 8)       8x → 10x
  SPX-PERP (if avail)→    SPX-USD (id: 10)      5x

  + Any other Lighter market can be added to Gaekju by config.
  The Mirror Agent auto-discovers new Lighter markets via /api/v1/orderBooks.

  Key advantage over Lighter: Lighter already has forex and commodity
  markets, so ALL Gaekju markets have real depth mirrored. No market
  is left with "oracle price only, no depth."
```

#### Market Auto-Discovery

```
On startup, the Mirror Agent:
  1. Calls GET /api/v1/orderBooks?filter=perp
  2. Gets list of ALL 220+ Lighter perp markets
  3. Matches against Gaekju's configured markets (by symbol)
  4. For each match: start mirroring depth + trade feed
  5. New markets on Lighter can be added to Gaekju by just updating config
     (no code change needed, just add a market_id mapping)

This means Gaekju can scale to 100+ markets trivially —
each new market is one config line + one MarketFactory.createMarket() call.
```

### 11.5 Mirror Agent Crate

```
crates/
└── gaekju-mirror/              # Lighter ↔ Gaekju liquidity bridge
    ├── src/
    │   ├── main.rs              # Entry point, config loading
    │   ├── config.rs            # Mirror config (markets, depth scale, etc.)
    │   │
    │   ├── lighter/
    │   │   ├── mod.rs
    │   │   ├── rest.rs          # REST client for /api/v1/* endpoints
    │   │   ├── ws.rs            # WebSocket connection to Lighter stream
    │   │   ├── types.rs         # OrderBook, Trade, MarketInfo types
    │   │   ├── parser.rs        # Parse Lighter JSON responses
    │   │   └── discovery.rs     # Auto-discover markets from /orderBooks
    │   │
    │   ├── mirror/
    │   │   ├── mod.rs
    │   │   ├── book_sync.rs     # Diff Lighter book vs Gaekju orders
    │   │   ├── order_manager.rs # Track which on-chain orders are ours
    │   │   ├── trade_relay.rs   # Relay Lighter trades to Gaekju API
    │   │   └── scaler.rs        # Scale depth (e.g., 10% of real book)
    │   │
    │   ├── chain/
    │   │   ├── mod.rs
    │   │   ├── submitter.rs     # Batch order submission to Gaekju contracts
    │   │   ├── nonce.rs         # Nonce management for rapid txs
    │   │   └── gas.rs           # Gas estimation
    │   │
    │   └── monitoring/
    │       ├── mod.rs
    │       ├── metrics.rs       # Prometheus: sync lag, order count, gas spent
    │       └── health.rs        # Alert if Lighter WS disconnects
    │
    └── Cargo.toml
```

#### Config

```toml
# gaekju-mirror config
[lighter]
rest_url = "https://mainnet.zklighter.elliot.ai/api/v1"
ws_url = "wss://mainnet.zklighter.elliot.ai/stream"
reconnect_interval_ms = 5000
auto_discover_markets = true   # Fetch market list from /orderBooks on startup

[mirror]
depth_scale = 0.1          # Show 10% of Lighter's real depth
max_levels = 20            # Mirror top 20 price levels per side
refresh_interval_ms = 2000 # Sync every Giwa block (~2s)
min_order_size = "0.001"   # Don't mirror tiny levels
order_book_limit = 50      # Fetch top 50 levels from Lighter (scale down to 20)

# Explicit market mappings (lighter_market_id → gaekju_market_id)
# Auto-discovery fills in any that match by symbol
[[mirror.markets]]
lighter_market_id = 1
gaekju_market_id = 0
symbol = "BTC-USD"
enabled = true
depth_scale_override = 0.05  # BTC has huge depth, show less

[[mirror.markets]]
lighter_market_id = 2
gaekju_market_id = 1
symbol = "ETH-USD"
enabled = true

[[mirror.markets]]
lighter_market_id = 3
gaekju_market_id = 2
symbol = "SOL-USD"
enabled = true

# RWA markets — mirrored from Lighter's forex/commodity perps
[[mirror.markets]]
symbol = "EUR-USD"
enabled = true
# lighter_market_id auto-discovered from /orderBooks

[[mirror.markets]]
symbol = "XAU-USD"
enabled = true

# Add more markets by just adding entries here.
# No code change needed.

[chain]
rpc_url = "https://rpc.giwa.chain"
mirror_account_key = "0x..."   # Private key for mirror account
max_gas_per_tx = 2000000
batch_size = 50                # Max orders per batch tx

[monitoring]
prometheus_port = 9092
```

### 11.6 The Sync Loop (Core Algorithm)

```rust
// Simplified pseudocode for the mirror sync loop

struct MirrorState {
    // Currently live mirror orders on Gaekju, keyed by (market, side, tick)
    live_orders: HashMap<(MarketId, Side, Tick), OrderId>,
}

async fn sync_loop(lighter_ws: LighterClient, chain: GaekjuChain, config: Config) {
    let mut state = MirrorState::new();

    loop {
        // 1. Get latest Lighter book for all markets
        let lighter_books = lighter_ws.get_latest_books().await;

        for (coin, lighter_book) in lighter_books {
            let market_id = config.market_mapping[&coin];
            let scale = config.depth_scale;  // e.g., 0.1

            // 2. Build target book state (what Gaekju should look like)
            let mut target_orders: Vec<(Side, Price, Size)> = vec![];
            for (price, size, _) in lighter_book.asks.iter().take(config.max_levels) {
                let scaled = size * scale;
                if scaled >= config.min_order_size {
                    target_orders.push((ASK, price, scaled));
                }
            }
            for (price, size, _) in lighter_book.bids.iter().take(config.max_levels) {
                let scaled = size * scale;
                if scaled >= config.min_order_size {
                    target_orders.push((BID, price, scaled));
                }
            }

            // 3. Diff against current live orders
            let mut to_place: Vec<Order> = vec![];
            let mut to_cancel: Vec<OrderId> = vec![];

            // Cancel orders at levels that no longer exist or changed significantly
            for ((m, side, tick), order_id) in &state.live_orders {
                if *m != market_id { continue; }
                let still_exists = target_orders.iter().any(|(s, p, _)|
                    *s == *side && price_to_tick(*p) == *tick
                );
                if !still_exists {
                    to_cancel.push(*order_id);
                }
                // Also cancel if size changed >20% (requote)
            }

            // Place orders at new or changed levels
            for (side, price, size) in &target_orders {
                let tick = price_to_tick(*price);
                if !state.live_orders.contains_key(&(market_id, *side, tick)) {
                    to_place.push(Order {
                        market_id, side: *side, price: *price, size: *size,
                        order_type: POST_ONLY,  // never aggress
                    });
                }
            }

            // 4. Submit batch to chain
            if !to_cancel.is_empty() {
                chain.batch_cancel(market_id, &to_cancel).await?;
            }
            if !to_place.is_empty() {
                let order_ids = chain.batch_place(market_id, &to_place).await?;
                // Update state with new order IDs
                for (order, id) in to_place.iter().zip(order_ids) {
                    let tick = price_to_tick(order.price);
                    state.live_orders.insert((market_id, order.side, tick), id);
                }
            }

            // Clean up cancelled orders from state
            for id in &to_cancel {
                state.live_orders.retain(|_, v| v != id);
            }
        }

        // 5. Wait for next block
        chain.wait_next_block().await;
    }
}
```

### 11.7 Trade Feed Integration

Lighter's real trades appear in Gaekju's trade feed alongside testnet trades:

```
Gaekju API trade feed (WebSocket):

  // Real Lighter trade (relayed, informational)
  {
    "channel": "trades",
    "market": 0,
    "data": {
      "price": "60001.0",
      "size": "0.50",
      "side": "buy",
      "source": "hyperliquid",    // tagged as external
      "time": 1712419200456
    }
  }

  // Testnet user trade (actual on-chain fill)
  {
    "channel": "trades",
    "market": 0,
    "data": {
      "price": "60001.0",
      "size": "0.10",
      "side": "buy",
      "source": "gaekju",         // tagged as local
      "txHash": "0xabc...",
      "maker": "0x...",
      "taker": "0x...",
      "time": 1712419202000
    }
  }

Frontend chart shows BOTH — the price line moves with real market data.
Testnet user fills appear as distinct markers on the chart.
```

### 11.8 What This Means for Testnet Users

```
From the testnet user's perspective:

  1. Open Gaekju → see BTC-USD at $60,001 (real price, same as Binance)
  2. See deep orderbook with realistic spreads and depth
  3. See trade feed with trades happening in real-time
  4. Claim 10,000 testnet USDC from faucet
  5. Place a market long 0.1 BTC → fills instantly at ~$60,001
     (against mirror orders that reflect real Lighter depth)
  6. Watch position PnL move with real BTC price
  7. Get liquidated if they use high leverage and BTC drops (real risk feel)
  8. Pay/receive funding rates based on real market premium
  9. Can also trade against OTHER testnet users' orders

  What's real:
  ✓ Prices (Pyth oracle = real aggregated price)
  ✓ Orderbook depth shape (mirrors Lighter)
  ✓ Trade flow (Lighter trades appear in feed)
  ✓ Funding rates (calculated from real mark vs index)
  ✓ Liquidation mechanics (fully functional)
  ✓ Smart contract execution (everything is on-chain)

  What's testnet:
  ✗ USDC is not real money (free from faucet)
  ✗ Mirror agent has unlimited capital (no real risk)
  ✗ Mirror agent doesn't hedge on Lighter (one-way bridge)
  ✗ RWA markets have no depth mirror (oracle price only)
```

### 11.9 Full Market Coverage

Unlike Hyperliquid (crypto-only), Lighter already lists forex and commodity perps. This means **every Gaekju market has a Lighter mirror source**:

```
Coverage:

  Crypto (BTC, ETH, SOL, ARB, OP, DOGE, ...): ✅ Lighter has all
  Forex (EUR/USD, GBP/USD):                    ✅ Lighter has forex perps (25x)
  Commodities (XAU via PAXG):                  ✅ Lighter has PAXG-PERP (8x)
  Indices (SPX):                               ⚠️  Check Lighter listing

  Result: No market is left without depth. All Gaekju markets
  show real orderbook depth mirrored from Lighter's live markets.

  If Lighter adds new markets, Gaekju can mirror them by adding
  one config entry. The auto-discovery feature detects new Lighter
  markets and suggests config additions.
```

### 11.10 Latency & Sync Quality

```
Sync chain:
  Lighter updates book → ~100ms
  Mirror Agent receives WS  → ~50ms network
  Mirror Agent diffs + submits tx → ~100ms compute
  Giwa L2 block inclusion → ~2s
  ─────────────────────────────
  Total lag: ~2.5 seconds behind Lighter

  In practice this means:
  - Slow price moves (normal trading): book tracks perfectly
  - Fast price moves (>1% in 2s): mirror lags, testnet users
    could fill at stale prices. This is acceptable on testnet.
  - Flash crashes: mirror may show depth that doesn't exist anymore.
    Mitigated by the Oracle staleness check (won't liquidate on stale data).

  Sync metrics (target):
  ├─ Book update latency: <3s (Lighter → Gaekju visible)
  ├─ Price accuracy: within 5 bps of Lighter mid-price
  ├─ Uptime: >99% (reconnect on WS drop)
  └─ Gas efficiency: <500k gas per sync cycle per market
```

### 11.11 Build Phase Integration

```
Mirror Agent is part of Phase 5 (testnet launch):

  - [ ] gaekju-mirror crate: Lighter REST + WebSocket client
  - [ ] Market auto-discovery from /api/v1/orderBooks
  - [ ] L2 book parser and depth scaler
  - [ ] Book diff algorithm (minimize on-chain order churn)
  - [ ] Batch order submission with nonce management
  - [ ] Trade relay to Gaekju API (external trade feed)
  - [ ] Market mapping config (Lighter coin → Gaekju marketId)
  - [ ] Monitoring: sync lag, order count, gas usage, WS health
  - [ ] Mirror account deployment + testnet USDC minting
  - [ ] Integration test: start mirror → verify book matches HL within 5s
  - [ ] Resilience: auto-reconnect, graceful degradation on Lighter downtime
  - [ ] Blog post: "Mirroring Lighter.xyz Liquidity onto a Testnet DEX"

Fee system tasks (added to Phase 3):
  - [ ] Implement maker-taker fee model in OrderBook
  - [ ] Maker rebate: -0.01% (paid to maker on fill)
  - [ ] Taker fee: +0.05% (charged to taker on fill)
  - [ ] Protocol revenue accumulation
```

---

## 13. Sequencer Protocol

The sequencer (`crates/gaekju-sequencer`) is a stateful Rust service. It accepts signed intents, matches them against its in-memory book, soft-acknowledges users in <50ms, and bundles ordered batches for the prover.

### 13.1 Transport

**REST** (for one-off intents, admin, health):
- `POST /v1/intents` — body: `{ intent, signature }`. Returns `{ seqId, softAck | rejection }`.
- `GET /v1/orderbook/:marketId?depth=N` — current pending book (not yet finalized).
- `GET /v1/account/:addr` — pending + finalized balances, open intents, nonces.
- `GET /v1/batches?from=nonce&limit=N` — batch metadata (status: building / proving / submitted / finalized).
- `GET /health`, `GET /metrics`.

**WebSocket** (for low-latency trader flow):
- `ws://sequencer.gaekju/ws`
- Client sends `{ method: "submit", intent, signature }` — server responds with `{ seqId, softAck }`.
- Server streams channels on subscribe: `orderbook:{market}`, `trades:{market}`, `user:{addr}` (pending fills, finalizations), `batches` (batch open/close/prove/submit events).

### 13.2 Intent format (EIP-712)

```
Domain:
  name            = "Gaekju"
  version         = "1"
  chainId         = <giwa chain id>
  verifyingContract = <Settlement address>

Types:
  Intent = {
    kind:        uint8,      // 0=place, 1=cancel, 2=modify
    trader:      address,
    marketId:    uint256,
    side:        uint8,      // 0=buy, 1=sell  (placement only)
    orderType:   uint8,      // 0=limit,1=market,2=ioc,3=fok,4=postOnly
    reduceOnly:  bool,
    price:       uint128,    // 18-dec (0 for market)
    size:        uint128,    // 18-dec
    refSeqId:    uint128,    // cancel/modify target
    nonce:       uint64,     // per-account monotonic
    expiry:      uint64,     // unix seconds
  }
```

The trader signs `Intent` with their EOA key. Sequencer verifies the signature and per-account nonce before accepting.

### 13.3 Nonce scheme

Per-account monotonic: `intent.nonce == account.lastAcceptedNonce + 1`. Gaps are rejected. The sequencer persists accepted nonces to a write-ahead log before replying with a soft-ack; on crash-restart it replays the WAL to rebuild state.

Per-account nonces are independent of Giwa chain nonces (used for deposit/withdraw/forceInclude).

### 13.4 Ordering semantics

- FIFO inside a single market at the same price; no reordering.
- Across markets, intents are stamped with a global `seqId` (u64 monotonic) assigned on acceptance.
- Matching is deterministic: price-time priority using `seqId` as the time tiebreaker.
- The sequencer commits to NOT reordering user intents inside a batch. This is a trust assumption, bounded by:
  - force-inclusion deadline (ADR-0014)
  - post-batch state-root commitment makes reordering observable after the fact
  - rotating sequencer set (future work)

### 13.5 Batch lifecycle

A batch closes when any of:
- `batch.intentCount >= MAX_INTENTS_PER_BATCH` (default 4096)
- `batch.fillCount  >= MAX_FILLS_PER_BATCH` (default 8192)
- `now() - batch.openedAt >= MAX_BATCH_AGE` (default 5s)
- A queued force-included intent has `deadlineBatchNonce - nextBatchNonce <= SAFETY_BATCHES` (default 1) — force a close on the current batch to include it before it goes overdue

On close: sequencer hands the batch blob + prevStateRoot + Pyth attestations to the prover. Sequencer continues accepting intents into the next batch in parallel.

---

## 14. Proof System

The prover (`crates/gaekju-prover`) re-executes the matcher crate inside SP1 zkVM (ADR-0013) and emits a succinct proof.

### 14.1 Circuit inputs

**Private (witness):**
- Full prev-state snapshot sufficient to recompute the state root (positions, balances, open-intent book, force-include cursor).
- Pyth price attestations referenced by the batch (verified against their signers inside the zkVM).
- The batch blob (ordered accepted intents + force-included intent outcomes).

**Public (committed) — canonical `BatchPublicInputs`:**

```solidity
struct BatchPublicInputs {
    bytes32 prevStateRoot;       // state root the batch applies to
    bytes32 postStateRoot;       // state root after batch
    bytes32 batchHash;           // keccak256(canonical BatchBlob encoding)
    uint64  batchNonce;          // strictly monotonic
    uint64  chainId;             // replay protection across chains/testnets
    uint64  forceIncludeCursor;  // highest force-include queue id resolved in this batch
}
```

Every field is load-bearing:
- `prevStateRoot` / `postStateRoot` / `batchNonce` — chain continuity (§15.3).
- `batchHash` — binds the off-chain batch blob to the proof.
- `chainId` — prevents replay of a proof on a fork or sibling testnet.
- `forceIncludeCursor` — strictly contiguous resolution cursor: the id of the **highest force-include queue entry** such that `[1..=forceIncludeCursor]` are all resolved. Gaps are forbidden. If queue entries 1-5 are resolved, `forceIncludeCursor == 5`. A batch that resolves entry 7 but leaves 6 pending is invalid — the prover cannot produce such a batch because the matching-core state machine advances the cursor only when the next contiguous id resolves. Settlement asserts `bundle.publicInputs.forceIncludeCursor >= stored.forceIncludeCursor` (monotonic — non-decreasing, can stay equal if no forced intents were due) and `<= latestQueuedId` (spec §15.3).

`marketId` is **not** a public input — a single batch may contain fills across multiple markets; each `Fill` carries its own `marketId` inside the blob.

### 14.2 Public inputs commitment

Settlement computes `expectedPublicHash = keccak256(abi.encode(BatchPublicInputs{...}))` from its own state + caller-supplied batch header. The SP1 verifier checks this commitment against the proof's public outputs. Any mismatch rejects.

### 14.3 Output format

The prover host outputs:
```solidity
struct ProofBundle {
    BatchPublicInputs publicInputs;
    bytes sp1Proof;       // ~260 bytes Groth16 or ~1KB PLONK
    bytes batchBlob;      // canonical BatchBlob (§15.2); keccak256 == publicInputs.batchHash
}
```

`Settlement.applyBatch(ProofBundle calldata bundle)` is the single entry point (§15.1). No separate `postStateRoot` / `publicInputsHash` parameters — everything is inside `publicInputs`.

### 14.4 EVM verifier gas target

Target: **≤ 350k gas** per `applyBatch` end-to-end (proof verify + delta decode + contract calls). SP1 Groth16 verifier is ~230k gas; decode + apply is the remaining budget. Benchmarked in Phase 7.

### 14.5 Prover infrastructure

- **Local dev:** `sp1-sdk` CPU prover.
- **Testnet:** Succinct Prover Network (hosted). Cost ~$0.01–$1 per batch in 2026, trending down.
- **Failure modes:** see §17.

---

## 15. Settlement Contract

Deeper spec for the contract summarized in §3.4.

### 15.1 Interface

```solidity
interface ISettlement {
    function applyBatch(ProofBundle calldata bundle) external;

    function stateRoot() external view returns (bytes32);
    function batchNonce() external view returns (uint64);
    function programVKey() external view returns (bytes32);
    function forceIncludeCursor() external view returns (uint64);

    // Force-include view
    function pendingForcedIntent(uint256 intentId) external view returns (
        address trader,
        bytes32 intentDigest,
        uint64 deadlineBatchNonce,
        bool resolved,
        uint8 outcome,          // 0 = unresolved, 1 = accepted, 2 = rejected
        uint8 rejectReason      // ForcedRejectReason code (0 if accepted/unresolved)
    );

    // Governance
    function pauseMatching(string calldata reason) external;
    function unpauseMatching() external;
    function rotateSequencer(address next) external;
    function proposeProgramVKey(bytes32 next) external;    // timelocked
    function activateProgramVKey(bytes32 next) external;   // requires paused + drained
}
```

### 15.2 Batch blob encoding

Canonical layout — `keccak256(BatchBlob) == publicInputs.batchHash`:

```solidity
struct BatchBlob {
    BatchHeader       header;
    Intent[]          acceptedIntents;     // replayed for pending-state clients
    Fill[]            fills;                // applied via PositionManager.applyBatchFills
    BalanceDelta[]    balanceDeltas;        // applied via Vault.applyBatchDelta
    MidPriceUpdate[]  midPriceUpdates;      // applied by Settlement → FundingRate.updateSequencerMid
    ForcedOutcome[]   forcedOutcomes;       // proved outcome for every queue entry resolved in this batch
    bytes32[]         attestedPriceIds;     // pyth price ids referenced
    bytes32[]         attestedPriceHashes;  // commitment to Pyth VAAs used
}

struct MidPriceUpdate {
    uint256 marketId;
    uint256 mid;       // 18-dec
}

struct BatchHeader {
    uint64  batchNonce;
    bytes32 prevStateRoot;
    uint64  timestamp;
    uint32  intentCount;
    uint32  fillCount;
    uint32  forcedCount;
    uint64  forceIncludeCursor;  // must equal publicInputs.forceIncludeCursor
}

// Proved outcome for every force-included intent resolved in this batch.
// The prover commits (forcedOutcomes) into state inside the zkVM; Settlement
// does NOT accept free-form ForcedAck[]. The sequencer cannot claim "resolved"
// without the prover running the intent (or its rejection) through the circuit.
struct ForcedOutcome {
    uint256 forcedIntentId;  // id from Router.forceInclude on-chain queue
    uint8   outcome;         // 1 = accepted (matched or resting), 2 = rejected
    uint8   rejectReason;    // ForcedRejectReason; 0 for accepted
    bytes32 resultHash;      // accepted: fill/intent hash. rejected: hash(intent, reason)
}

// Dedupe rule: `acceptedIntents` and `forcedOutcomes` are disjoint execution lists.
// An intent that arrived via Router.forceInclude is ALWAYS executed through the
// forced path (its `forcedIntentId` drives ordering by on-chain queue position).
// The matcher inside matching-core MUST:
//   1. Before appending to `acceptedIntents`, check `forcedIntentSet.contains(hash(intent))`
//      — if present, reject the sequencer-path submission with `DuplicateOfForced`.
//   2. Execute `acceptedIntents` first (in seqId order), then `forcedOutcomes`
//      (in `forcedIntentId` order).
//   3. Per-account nonce advances once per intent regardless of path.
// Rationale: forced-path execution is on-chain-observable (queue id, deadline),
// so operators and users can audit it; reusing the normal path would let a
// sequencer swallow a forced intent under the normal-path label and bypass the
// force-include liveness check. Disjoint lists make the audit trivial.

enum ForcedRejectReason {
    NONE,                   // 0 — for accepted outcomes
    EXPIRED,                // intent expiry past
    BAD_NONCE,              // per-account nonce mismatch
    INSUFFICIENT_MARGIN,    // IMR check failed
    MARKET_PAUSED,
    INVALID_SIGNATURE,
    REDUCE_ONLY_VIOLATION,
    UNKNOWN_MARKET
}
```

### 15.3 State delta application

Order of operations inside `applyBatch(bundle)` (UUPS, `whenNotPaused`):

1. Decode `bundle.batchBlob` → `blob`. Assert `keccak256(bundle.batchBlob) == bundle.publicInputs.batchHash` and `bundle.publicInputs.chainId == block.chainid`.
2. Assert `bundle.publicInputs.batchNonce == batchNonce + 1`.
3. Assert `bundle.publicInputs.prevStateRoot == stateRoot`.
4. Assert `blob.header.forceIncludeCursor == bundle.publicInputs.forceIncludeCursor`, `>= forceIncludeCursor` (monotonic, non-decreasing), `<= latestQueuedId`, and contiguous: all queue ids in `[1..=newCursor]` have `resolved == true` after step 7 below. Contiguity is the invariant — gaps are disallowed.
5. SP1 verify: `verifier.verifyProof(programVKey, abi.encode(bundle.publicInputs), bundle.sp1Proof)`.
6. **Force-include liveness check.** For every `pendingForcedIntent` with `deadlineBatchNonce <= bundle.publicInputs.batchNonce` and not yet resolved, there must be a matching entry in `blob.forcedOutcomes`. Else revert (`ForcedIntentOverdue`).
7. **Force-include outcome application.** For every entry in `blob.forcedOutcomes`, copy `outcome` + `rejectReason` + `resultHash` into `pendingForcedIntent[id]` and set `resolved=true`. (The prover already proved these inside the circuit; Settlement only stores them for on-chain readers.)
8. Decode `blob.balanceDeltas`; compute `Σ` and assert fills-conservation (§10, §15.3.1).
9. **Market-pause check.** For every entry in `blob.fills` and every entry in `blob.midPriceUpdates`, assert `MarketFactory.marketActive(marketId) == true`; else revert `MarketPaused(marketId)`. Pause is governance-controlled and enforced at runtime by Settlement — **not** baked into the vkey — so a market can be paused without a vkey rotation.
10. Apply Vault state — see §15.3.1 for the Vault/PositionManager split: `Vault.applyBatchDelta(bundle.publicInputs.batchNonce, blob.balanceDeltas)`.
11. Apply mid-price updates — loop `blob.midPriceUpdates` and call `FundingRate.updateSequencerMid(marketId, mid)` directly from Settlement (not via Vault). This keeps `SETTLEMENT_ROLE` as the only role mutating FundingRate state.
12. `PositionManager.applyBatchFills(bundle.publicInputs.batchNonce, blob.fills)`.
13. Update `stateRoot = bundle.publicInputs.postStateRoot`, `batchNonce = bundle.publicInputs.batchNonce`, `forceIncludeCursor = bundle.publicInputs.forceIncludeCursor`.
14. Emit `BatchSettled(batchNonce, prevStateRoot, postStateRoot, batchHash, forceIncludeCursor)`.

**Canonical event (single source of truth):**

```solidity
event BatchSettled(
    uint64  indexed batchNonce,
    bytes32         prevStateRoot,
    bytes32         postStateRoot,
    bytes32         batchHash,
    uint64          forceIncludeCursor
);
event ForcedIntentResolved(
    uint256 indexed forcedIntentId,
    uint8           outcome,
    uint8           rejectReason,
    bytes32         resultHash
);
```

No other event names (`BatchApplied`, `BatchFinalized`) are emitted — references in older drafts are obsolete.

### 15.3.1 Vault vs PositionManager responsibility split

**One owner per state field.** The ambiguity in earlier drafts (both `BalanceDelta[]` and `PositionManager` mutating the same `Vault` buckets on a fill) is resolved as follows:

| Vault bucket                                | Owner (sole writer in Settlement flow) |
|----------------------------------------------|---------------------------------------|
| Free collateral (deposit / withdraw / PnL)   | **Vault** via `applyBatchDelta`       |
| Order margin (locked on place, unlocked on fill/cancel) | **Vault** via `applyBatchDelta` |
| Position margin (locked on open, unlocked on close) | **Vault** via `applyBatchDelta`   |
| Realized PnL credit/debit on fill             | **Vault** via `applyBatchDelta`       |
| Funding payment on settle                     | **Vault** via `applyBatchDelta`       |
| `Position.size / entryPrice / collateral`     | **PositionManager** via `applyBatchFills` |
| `Position.lastCumulativeFunding`              | **PositionManager** via `applyBatchFills` |
| `_positionHolders` set membership             | **PositionManager** via `applyBatchFills` |

`PositionManager.applyBatchFills` is **position-only** under Path B. It does **not** call `vault.unlockOrderMargin`, `vault.unlockMargin`, `vault.lockMargin`, or `vault.realizePnl` inline. All vault-side effects of every fill (order-margin release, position-margin lock, realized PnL, flip margin delta, funding payment) are pre-computed inside the zkVM and emitted as entries in `blob.balanceDeltas`. Settlement applies `balanceDeltas` first, then `fills` — the order matters because PositionManager reads `vault.freeCollateral` only for invariant assertions, never to mutate.

**Equivalence test (`contracts-v2` Task 4):** for every scenario in the Phase 2 `PositionManager.t.sol` (open, increase, partial close, full close, flip with funding settle), construct a batch of one fill + the equivalent `BalanceDelta[]` computed off-chain, run `applyBatch`, and assert final `(Position, Vault.freeCollateral, Vault.lockedOrderMargin, Vault.lockedPositionMargin)` equals the sequential-path result. This is a gate for merging contracts-v2.

### 15.4 Caller guards on downstream contracts

Every downstream contract (`Vault`, `PositionManager`) gates its batch entry point with `onlyRole(SETTLEMENT_ROLE)`. The role is assigned at deploy time to the Settlement proxy address and changed only via Timelock governance. `ORDERBOOK_ROLE` is removed.

LiquidationEngine retains its own role (`LIQUIDATOR_ROLE` held by keeper EOAs) and runs **fully on-chain** against finalized state — it is not routed through the sequencer in v1 (see §3.7, §2.5). MarginEngine, FundingRate, OracleAdapter expose only view + keeper paths to external callers.

### 15.5 Program vkey rotation — storage-backed + drain flow

`programVKey` is a storage slot on Settlement, rotated via a **pause-and-drain** procedure. The prior draft that mixed "immutable" with "atomic timelock flip" is retracted — it can strand in-flight batches (old-key proof mid-flight, nonce/root continuity breaks when the next batch uses the new key).

Rotation procedure (on-chain runbook):

1. **Propose** `proposeProgramVKey(newVKey)` — records pending vkey + starts `VKEY_TIMELOCK` (24h per ADR-0009).
2. **Pause sequencer** (off-chain). Sequencer stops accepting new intents; UI surfaces "matching paused for upgrade".
3. **Drain in-flight batches.** Sequencer finishes any batch already opened, hands it to the prover, prover finishes any already-enqueued proof, submitter lands all drained proofs on Settlement. The chain is now at a clean finalization boundary (`stateRoot` == last proved `postStateRoot`, prover queue empty).
4. **Force-include drain.** If `forceIncludeQueue` has unresolved entries with non-past deadlines, operator must wait for the prover run above to resolve them OR extend deadlines via a separate timelock proposal before vkey flip. No rotation proceeds with overdue unresolved forced intents.
5. **Activate** `activateProgramVKey(newVKey)` — requires `block.timestamp >= proposalTimestamp + VKEY_TIMELOCK`, requires `paused() == true`, requires `proverQueueDrained()` oracle = true (a trusted off-chain-signed attestation from a guardian set OR simply a manual governance-signed assertion in v1). Writes `programVKey = newVKey`, emits `ProgramVKeyRotated(oldVKey, newVKey)`.
6. **Redeploy prover** with the new matcher program binary whose vkey matches `newVKey`. Verify `cargo run -p gaekju-prover -- verify-vkey` matches the on-chain value.
7. **Unpause** sequencer. Fresh batches start at `batchNonce = previousNonce + 1` with `prevStateRoot` still equal to the last finalized root — nonce/root continuity is preserved because no batches were lost in between.

Rejected alternatives:
- **Immutable vkey + redeploy Settlement.** Requires migrating `stateRoot`, `batchNonce`, `forceIncludeQueue`, `pendingForcedIntent[]`, and all `SETTLEMENT_ROLE` grants. Too much state to migrate safely for a matcher bug fix.
- **Dual-vkey grace window.** Verifier must try two keys or Settlement must pick by batch header; adds circuit/proof branching complexity for a feature used ≤ annually.

**Anti-grief: non-cooperative sequencer during rotation.** A malicious sequencer could refuse to close its last open batch, blocking the drain step (3) and preventing `activateProgramVKey`. Governance circuit-breaker:

- `ROTATION_TIMELOCK` (default 24h) is the standard path.
- `ROTATION_FORCE_TIMELOCK` (default 7 days) is a second, longer timelock attached to the same `proposeProgramVKey` proposal. If it expires **and** `paused() == true` for the entire window, governance may call `forceActivateProgramVKey(newVKey, forceState)` which: (a) accepts governance-signed `(postStateRoot, batchNonce, forceIncludeCursor)` as the new canonical state (skipping any in-flight undrained batch), (b) marks all currently-queued force-included intents `resolved = true, outcome = REJECTED_SEQUENCER_FORCED_ROTATION`, refunds their fees, (c) writes `programVKey = newVKey`, (d) emits `ProgramVKeyForceRotated(oldVKey, newVKey, forceState)`.
- Assumption: 7-day + pause requirement is severe enough that this path is only ever used to recover from a captured or dead sequencer, not routine upgrades. Tradeoff: governance effectively asserts the state root unilaterally, which is a trust concentration — this is the escape hatch for "sequencer hostile, bug in matcher requires vkey change, force-include queue would otherwise accumulate forever" and is documented as such.

**Force-include deadline unit.** Deadlines are stored on-chain as `deadlineBatchNonce = batchNonce_at_queue_time + FORCE_INCLUDE_N` (a batch-nonce count, not wall-clock seconds). Across a pause-and-drain rotation, `batchNonce` does not advance while the sequencer is paused, so queued intents do not spontaneously expire during the 24h timelock. If the rotation takes long enough that protocol operators judge the queue stale, governance may call `extendForceIncludeDeadlines(delta)` (admin helper) to add `delta` to every queued entry's `deadlineBatchNonce` before unpausing. This replaces the earlier "wall-clock" framing — it was a documentation bug; the implementation is batch-nonce based, consistent with §15.2 / §15.3.

---

## 16. Soft-Confirm UX

Users experience three confidence levels. **Only `finalized` is durable.** Both `soft-ack` and `batch-sealed` are sequencer-local states that can be rewound under prover or verifier failure (§17.2, §17.3).

| State | Latency | Backed by | Durable? |
|-------|---------|-----------|----------|
| **Soft-ack** | <50ms (sequencer response) | Sequencer signature + WAL | **No** — rewound if sequencer crashes before batch close OR if the enclosing batch later fails to prove. User-facing guarantee: "acknowledged, not final." |
| **Batch-sealed** | ~5s (matches Giwa block cadence) | Sequencer committed batch to prover | **No** — rewound if the proof cannot be produced (§17.2) or if the proof is invalid (§17.3). Sealed does NOT mean on-chain. |
| **Finalized** | ~30s–2min (proof gen + Giwa inclusion) | `BatchSettled` event on Settlement | **Yes** — fully on-chain, not reversible except by L2 reorg. |

**UX patterns (Phase 8):**
- Trade history panel shows soft-acked and sealed fills with a clear **pending** badge. Badge flips to **final** on the `BatchSettled` event that carries their `batchNonce`.
- Balance panel shows `available` (finalized free collateral) and `pending` (soft-acked/sealed deltas) separately. Withdrawals draw from `available` only. This is a hard rule, not a default.
- On sequencer disconnect: client warns "matching paused"; user can still read on-chain finalized state and submit `Router.forceInclude`. Any soft-acked intent not yet sealed MAY be lost.
- On batch rewind (§17.3): client surfaces a **rollback** banner and replays/reconciles the user's local trade log against the new tip.
- Wallet popups for deposit / withdraw / force-include still look like normal tx flows; all other actions are off-chain signature prompts.

**SLAs (Phase 10 targets) — operational, not protocol invariants:**
- Soft-ack p95 < 50ms regional, < 200ms global.
- Batch close p95 < 6s.
- Batch finalization p95 < 2 min (dominated by Succinct Prover Network latency).

**Protocol-enforced bounds (distinct from SLAs above):**
- Force-include bound: **N = 3 batches** (≈ 15s at 5s cadence, ADR-0014). This is the maximum latency from a force-included intent landing in the on-chain queue to Settlement either processing it or entering recovery mode. It is enforced in `applyBatch` (§15.3 step 6) — the exchange halts if the bound is violated. Any longer "30-minute"-style number seen in earlier drafts was an operational SLA target, not a protocol invariant, and is retracted.

---

## 17. Failure Modes

### 17.1 Sequencer halt

Symptom: sequencer stops accepting or stops batching.

- Traders cannot submit new intents through normal path.
- Traders can use `Router.forceInclude(intent)` to queue in-flight trades; Settlement must produce a proved outcome for each within `FORCE_INCLUDE_N` batches (≈ 15s at the 5s ADR-0015 cadence).
- If halt persists past deadline, Settlement rejects the next attempted batch (forced-inclusion invariant fires) → `pauseMatching("force_timeout")` emits.
- Governance rotates sequencer via `rotateSequencer(next)`; force-include queue carries across.
- Existing positions continue to accrue funding and remain liquidatable on-chain (liquidation path does not require sequencer).

### 17.2 Prover halt

Symptom: sequencer emits batches but no proofs are produced.

- Soft-acks keep flowing (users can still open/close).
- Finalization stalls; on-chain state does not update.
- Batch backlog grows in sequencer WAL. Bounded by disk.
- Liquidations still work from last finalized state.
- Mitigation: redundant provers (local + Succinct network). If both fail, ops rolls the sequencer back to the last finalized batch; soft-acked-but-unproved intents are dropped and replayed.
- User-facing: "finalization delayed" banner.

### 17.3 Proof invalid (verifier revert)

Symptom: `applyBatch` reverts with `Sp1VerifyFailed`.

- The offending batch never finalizes on-chain.
- Sequencer is in an inconsistent state (its soft book diverged from what the prover proved).
- Response: sequencer pauses, rewinds its in-memory state to last finalized batch, replays the WAL against the matcher, re-proves.
- If repro: the matcher is buggy or the prover is misconfigured — investigate out-of-band. Governance may `setProgramVKey` after fix.

### 17.4 Batch reversion on L1

Symptom: `applyBatch` tx reverts for reasons other than verifier (e.g., nonce mismatch after a Giwa reorg).

- Sequencer detects revert in `BatchSettled` event absence past expected block.
- Re-reads `stateRoot` and `batchNonce` from Settlement.
- If current on-chain nonce is behind sequencer's assumption: resubmit the batch with refreshed `prevStateRoot`.
- If current on-chain nonce is ahead (another submitter somehow landed a batch): pause, investigate — this should only happen if multiple sequencers are mistakenly authorized.

### 17.5 Pyth oracle degraded

- Mark price stale or confidence wide → OracleAdapter reverts.
- Sequencer enters cancel-only mode per market (reject new openings; allow closes).
- Liquidations pause (on-chain `isLiquidatable` reverts on stale).
- Funding skipped until oracle returns.

### 17.6 Giwa L2 outage

- Standard OP Stack: force-inclusion via L1 after sequencer grace window.
- Off-chain matching continues; finalization defers.
- Withdrawals delayed until L2 resumes.

---

## Appendix: Glossary

| Term | Definition |
|------|-----------|
| **CLOB** | Central Limit Order Book — matching engine using price-time priority |
| **IMR** | Initial Margin Rate — minimum margin to open a position |
| **MMR** | Maintenance Margin Rate — minimum margin to keep a position open |
| **ADL** | Auto-Deleverage — force-closing profitable positions when insurance fund is empty |
| **Funding Rate** | Periodic payment between longs and shorts to anchor perp price to index |
| **Mark Price** | Oracle price used for margin and liquidation calculations |
| **Index Price** | Spot price used for funding rate calculation |
| **Tick** | Minimum price increment for a market |
| **Lot** | Minimum size increment for a market |
| **TWAP** | Time-Weighted Average Price |
| **UUPS** | Universal Upgradeable Proxy Standard (EIP-1822) |
| **RWA** | Real-World Assets (forex, commodities, indices) |
| **Sequencer** | Rust service that accepts signed intents, matches, and emits batches |
| **Prover** | SP1 zkVM service that proves matcher execution over a batch |
| **SP1** | Succinct Labs' RISC-V zkVM used as the proving target |
| **Batch** | Ordered set of accepted intents + resulting fills + forced-intent acks |
| **Intent** | EIP-712-signed user order (place/cancel/modify) |
| **Settlement** | On-chain contract that verifies SP1 proofs and applies batch state deltas |
| **Soft-ack** | Sequencer-signed acknowledgment before on-chain finalization |
| **Force-include** | On-chain escape hatch for censored intents |
