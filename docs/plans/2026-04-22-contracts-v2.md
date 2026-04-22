# Contracts v2 — Path B Settlement Rebuild

**Date:** 2026-04-22
**Supersedes:** `2026-04-06-phase3-funding-factory-router.md`
**Governing ADR:** [ADR-0012](../adr/0012-zkvm-matcher-pivot.md)
**For agentic workers:** REQUIRED SUB-SKILL: `sspower:subagent-driven-development` or `sspower:executing-plans`.

---

## Goal

Replace the on-chain bitmap CLOB with a `Settlement.sol` that verifies an SP1 proof and applies a batch state delta to the surviving Phase 1/2 contracts. Matching itself moves to the Rust sequencer (see `2026-04-22-rust-sequencer.md`).

By the end of this plan:

- `OrderBook.sol`, `IOrderBook.sol`, `BitmapLib.sol`, `PackedOrder.sol`, `TickMath.sol` and their tests are deleted.
- `Settlement.sol` + `ISettlement.sol` exist, wire an `ISP1Verifier`, and are the only caller permitted on Vault / PositionManager / MarginEngine / FundingRate (`SETTLEMENT_ROLE`).
- `MarketFactory` deploys a per-market Settlement instead of an OrderBook.
- `Router.sol` is a thin shim: `deposit`, `withdraw`, `forceInclude(Intent)`.
- All surviving Phase 1/2 tests compile and pass; new Settlement unit + integration tests cover the proof verification and state-delta application paths.

`forge build && forge test` must be green at the end of each task.

---

## Pre-flight — baseline snapshot

- `cd contracts && forge test -vvv 2>&1 | tee /tmp/pre-pivot-tests.log` — record the 131 green tests before any deletion so we can diff at the end.
- `git switch -c pivot/contracts-v2` — work on a dedicated branch.
- Confirm `SP1Verifier` address for Giwa testnet (ADR-0013). If Succinct has not deployed on Giwa, task 4 builds an inline verifier wrapper that can be swapped.

---

## Task list

### Task 1 — Delete the bitmap orderbook surface

**Files removed:**

- `contracts/src/OrderBook.sol`
- `contracts/src/interfaces/IOrderBook.sol`
- `contracts/src/libraries/BitmapLib.sol`
- `contracts/src/libraries/TickMath.sol`
- `contracts/src/libraries/PackedOrder.sol`
- `contracts/test/unit/OrderBook*.t.sol`
- `contracts/test/unit/BitmapLib*.t.sol`
- `contracts/test/unit/TickMath*.t.sol`
- `contracts/test/unit/PackedOrder*.t.sol`
- `contracts/test/fuzz/Bitmap*.t.sol`
- `contracts/test/fuzz/TickMath*.t.sol`
- `contracts/test/integration/OrderBook*.t.sol`

**Steps:**

1. `git rm` each file above.
2. `grep -rn "IOrderBook\|OrderBook\|BitmapLib\|TickMath\|PackedOrder" contracts/` — verify no stragglers.
3. Remove the matching import lines left behind in `PositionManager.sol`, `Vault.sol`, `MarketFactory.sol`, mocks, deploy scripts.
4. `forge build` — expected to fail (caller guards in surviving contracts still reference `ORDERBOOK_ROLE`). Task 2 fixes that.

**Verification:** build fails only with `ORDERBOOK_ROLE` / caller-guard errors, no "file not found" imports.

Survival estimate: of the 131 Phase 2 tests, roughly 30–50 touch OrderBook directly and delete here; 80–100 survive (Vault, MarginEngine, OracleAdapter, PositionManager, LiquidationEngine, FixedPointMath, oracle fuzz, mocks).

---

### Task 2 — Rebind caller guards (`ORDERBOOK_ROLE` → `SETTLEMENT_ROLE`)

**Files edited:**

- `contracts/src/Vault.sol`
- `contracts/src/PositionManager.sol`
- `contracts/src/MarginEngine.sol`
- `contracts/src/FundingRate.sol` (Phase 3 design: caller guard was pending, bind to Settlement now)
- `contracts/src/interfaces/IVault.sol`
- `contracts/src/interfaces/IPositionManager.sol`
- `contracts/test/unit/Vault.t.sol`, `MarginEngine.t.sol`, `PositionManager.t.sol`, `FundingRate.t.sol`
- `contracts/test/integration/*.t.sol`

**Steps:**

1. Rename the role constant: `bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");` on each contract that used `ORDERBOOK_ROLE`.
2. Update modifier comments: `onlyOrderBook` → `onlySettlement`.
3. In test setup helpers, grant `SETTLEMENT_ROLE` to a `settlement` address placeholder (until Task 3 plugs the real contract in).
4. Remove any `IOrderBook orderBook` fields; replace with `address settlement` + an interface call through `ISettlement` after Task 3.
5. `forge build` must pass; `forge test` must be green for all surviving tests. Expected green count ≈ 80-100 of the original 131.

**Verification:**

```
cd contracts && forge build
cd contracts && forge test --no-match-contract "OrderBook\|Bitmap\|TickMath\|PackedOrder"
```

---

### Task 3 — Write `ISettlement` + skeleton `Settlement.sol`

**New files:**

- `contracts/src/interfaces/ISettlement.sol`
- `contracts/src/Settlement.sol`
- `contracts/test/unit/Settlement.t.sol`

**Interface sketch:**

```solidity
struct BatchHeader {
    uint64 marketId;
    uint64 batchNonce;
    bytes32 prevStateRoot;
    bytes32 postStateRoot;
    bytes32 intentsRoot;
    bytes32 fillsRoot;
    uint64 timestamp;
}

struct Fill {
    bytes32 takerIntentHash;
    bytes32 makerIntentHash;
    address taker;
    address maker;
    int256 baseDelta;   // signed qty, 1e18
    uint256 price;      // 1e18
    uint256 fee;        // 1e6 USDC
}

interface ISettlement {
    function applyBatch(
        BatchHeader calldata header,
        Fill[] calldata fills,
        bytes calldata publicValues,
        bytes calldata proof
    ) external;

    function forceInclude(bytes calldata intent, bytes calldata sig) external;
    function stateRoot() external view returns (bytes32);
    function batchNonce() external view returns (uint64);
}
```

**Steps:**

1. Scaffold `Settlement.sol` UUPS upgradable (`Initializable`, `AccessControlUpgradeable`, `UUPSUpgradeable`).
2. Wire `ISP1Verifier public verifier;` + `bytes32 public programVKey;` — set via initializer.
3. Implement `applyBatch`:
   - `require(header.batchNonce == batchNonce + 1, "bad nonce");`
   - `require(header.prevStateRoot == stateRoot, "bad prev root");`
   - `verifier.verifyProof(programVKey, publicValues, proof);`
   - decode `publicValues` and assert it commits to `(header, intentsRoot, fillsRoot)`.
   - loop `fills`: call `PositionManager.applyBatchFills(Fill[])` and `Vault.applyBatchDelta(Delta[])` in one external tx. Both new entry points added in Task 4.
   - persist `stateRoot = header.postStateRoot; batchNonce = header.batchNonce;`.
   - emit `BatchApplied(header)`.
4. Implement `forceInclude` — stash the raw intent in a bounded queue (`bytes32[] forceIncludeQueue`), emit `ForceIncluded(hash, deadlineBatch)`. Settlement enforces that force-included intents appear in a batch within `N` batches (config) or Settlement enters `defaultMode` halting new non-force batches.
5. Unit tests: nonce monotonicity, bad prev root, bad proof revert, happy path with a mock verifier that always returns true, force-include queue bounds.

**Verification:** `forge test --match-contract Settlement` green.

---

### Task 4 — Vault + PositionManager batch entry points

**Files edited:**

- `contracts/src/Vault.sol` — `applyBatchDelta(Delta[])`
- `contracts/src/PositionManager.sol` — `applyBatchFills(Fill[])`
- `contracts/src/interfaces/IVault.sol`, `IPositionManager.sol`

**Steps:**

1. `Vault.applyBatchDelta` iterates signed collateral deltas, calls `_credit` / `_debit`, guarded by `SETTLEMENT_ROLE`.
2. `PositionManager.applyBatchFills` mirrors the old per-fill path (`openOrIncrease` / `reduceOrClose` / `flip`) but batched, with a single MarginEngine check after each trader's cumulative delta is applied to reduce redundant oracle reads.
3. Reuse Phase 2 invariants: signed qty conservation, no cross-market writes, IMR check at position open/increase, MMR check for decrease into-loss positions.
4. Extend Phase 2 unit tests to assert batched input produces identical state to sequential per-fill calls.

**Verification:** `forge test --match-path contracts/test/unit/PositionManager.t.sol` + `Vault.t.sol` green; new `Settlement_Integration.t.sol` simulates a 10-fill batch and asserts Vault/PM state.

---

### Task 5 — SP1Verifier wiring

**New file:** `contracts/src/interfaces/ISP1Verifier.sol` (alias of Succinct's `ISP1Verifier`).

**Steps:**

1. If Succinct has deployed `SP1VerifierGateway` on Giwa, store the address in `deploy/config/giwa.json` and inject via initializer.
2. Otherwise vendor Succinct's `SP1Verifier` (v3) contract under `contracts/src/external/sp1/` and deploy it ourselves in the deploy script.
3. Write a `MockSP1Verifier.sol` in `contracts/test/mocks/` that exposes `setValid(bool)` for unit tests.
4. Parameterise `Settlement.initialize(verifier, programVKey, ...)` — programVKey comes from the prover crate's build output (`gaekju-prover/elf/gaekju-program.vkey`).

**Verification:** Deploy script boots on Anvil with the mock verifier and a synthetic batch.

---

### Task 6 — MarketFactory (deploys Settlement per market)

**Files edited:**

- `contracts/src/MarketFactory.sol`
- `contracts/test/unit/MarketFactory.t.sol`
- `contracts/script/DeployMarket.s.sol`

**Steps:**

1. Remove the `_deployOrderBook` internal; replace with `_deploySettlement(params)` that deploys the `Settlement` UUPS proxy with market-specific config (verifier address, programVKey, initial IMR/MMR per ADR-0006, fee schedule, force-include window `N`).
2. `createMarket(MarketParams)` wires: Vault (shared), MarginEngine (shared), OracleAdapter (shared), FundingRate (per market), PositionManager (per market), Settlement (per market).
3. Grant `SETTLEMENT_ROLE` on Vault + PM + MarginEngine + FundingRate to the new Settlement.
4. Emit `MarketCreated(marketId, settlement, fundingRate, positionManager)`.

**Verification:** `forge test --match-contract MarketFactory` green, deploy script on Anvil creates a market and the Settlement address is stored in the registry.

---

### Task 7 — Router (thin)

**File rewritten:** `contracts/src/Router.sol` (+ `IRouter.sol`).

Public surface:

```solidity
function deposit(uint256 usdcAmount) external;
function withdraw(uint256 usdcAmount) external;
function forceInclude(bytes calldata intent, bytes calldata sig) external;
```

**Steps:**

1. Delete every call that wrapped OrderBook (place/cancel/IOC/FOK/market/reduce-only).
2. `deposit` / `withdraw` are pass-throughs to Vault.
3. `forceInclude` proxies to the correct market's Settlement based on the decoded intent (read `marketId` from the EIP-712 payload). Charges a fixed fee in USDC to prevent spam.
4. Update `Router.t.sol` to cover the three entry points only.

**Verification:** `forge test --match-contract Router` green.

---

### Task 8 — FundingRate caller rebind

Already partially handled in Task 2 (role rename). Confirm:

- `FundingRate.poke()` is callable by a keeper EOA (unchanged).
- `FundingRate.applyFundingOnSettle(address trader, int256 fundingDelta)` is `onlySettlement`.
- Remove any vestigial "called by OrderBook on fill" docs.

**Verification:** `forge test --match-contract FundingRate` green. Phase 3 funding tests survive verbatim except for the caller setUp line.

---

### Task 9 — Integration test (end-to-end batch)

**New file:** `contracts/test/integration/SettlementBatch_Integration.t.sol`.

Scenario:

1. Two traders deposit via Router.
2. Construct a synthetic batch off-chain (fixture JSON): 5 fills, half taker half maker, alternating long/short, one liquidation-triggering drawdown.
3. Submit via `Settlement.applyBatch` with the mock verifier set to `true`.
4. Assert Vault balances, PositionManager positions, FundingRate accumulators, LiquidationEngine invariants.
5. Submit a second batch with `batchNonce` skipping one — expect revert.
6. Submit a force-include intent; assert it lands in `forceIncludeQueue`; submit the next batch without including it — expect `defaultMode` turns true after `N` batches.

**Verification:**

```
cd contracts && forge test --match-path contracts/test/integration/SettlementBatch_Integration.t.sol -vvv
```

---

### Task 10 — Cleanup + format + full suite

Steps:

1. `cd contracts && forge fmt`
2. `cd contracts && forge build` — zero warnings.
3. `cd contracts && forge test -vvv 2>&1 | tee /tmp/post-pivot-tests.log`
4. Diff `pre-pivot-tests.log` vs `post-pivot-tests.log`; write the surviving-tests matrix into `docs/plans/2026-04-22-contracts-v2-results.md` for the handoff.
5. `cargo check -p gaekju-types` — ABI bindings regenerate cleanly (new `Settlement` ABI, dropped `OrderBook`).

**Definition of done:**

- `forge build` clean.
- `forge test` green, count ≥ previous 80–100 survivors plus new Settlement/Router coverage (target: ~110–130 total).
- `OrderBook*`, `BitmapLib*`, `TickMath*`, `PackedOrder*` symbols are absent from `find contracts/src contracts/test -name '*.sol' | xargs grep -l`.
- ABI bindings for `Settlement` published in `crates/gaekju-types` (ready for sequencer/prover plans).

---

## Migration notes for downstream crates

- `gaekju-types` regenerates bindings after Task 5. Downstream crates (sequencer, prover, indexer, keeper, mirror, SDK, CLI) pick up via Cargo workspace.
- `gaekju-indexer` must stop watching OrderBook events after Task 1 or it will crash. Coordinate so indexer update (see `2026-04-22-indexer-api-updates.md`) lands in the same release train.

---

## Risks

- **ABI drift during deletion.** Mitigation: build types crate between every contract task.
- **`SETTLEMENT_ROLE` misgranted in deploy script.** Mitigation: post-deploy assertion script that checks `hasRole(SETTLEMENT_ROLE, settlement) == true` on Vault/PM/MarginEngine/FundingRate.
- **Force-include griefing.** Mitigation: fixed USDC fee + per-sender rate limit in Router.
- **Proof replay.** Mitigation: batch-nonce monotonicity enforced in `applyBatch`.
