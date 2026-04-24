# Contracts v2 — Path B Settlement Rebuild

**Date:** 2026-04-22
**Status:** ✅ COMPLETE — merged to main as `98baf7c` on 2026-04-24.
  Results matrix: [`2026-04-22-contracts-v2-results.md`](2026-04-22-contracts-v2-results.md).
  T8 FundingRate deferred to Phase 5.5 miniplan; ADL placeholder deferred.
**Supersedes:** `2026-04-06-phase3-funding-factory-router.md`
**Governing ADR:** [ADR-0012](../adr/0012-zkvm-matcher-pivot.md)
**For agentic workers:** REQUIRED SUB-SKILL: `sspower:subagent-driven-development` or `sspower:executing-plans`.

---

## Goal

Replace the on-chain bitmap CLOB with a `Settlement.sol` that verifies an SP1 proof and applies a batch state delta to the surviving Phase 1/2 contracts. Matching itself moves to the Rust sequencer (see `2026-04-22-rust-sequencer.md`).

By the end of this plan:

- `OrderBook.sol`, `IOrderBook.sol`, `BitmapLib.sol`, `PackedOrder.sol`, `TickMath.sol` and their tests are deleted.
- `Settlement.sol` + `ISettlement.sol` exist, wire an `ISP1Verifier`, and are the only caller permitted on Vault / PositionManager / MarginEngine / FundingRate (`SETTLEMENT_ROLE`).
- `MarketFactory` is a config-only registry — **no per-market contract deploys**. Settlement, Vault, PositionManager, MarginEngine, LiquidationEngine, FundingRate, OracleAdapter are deployed once globally. `createMarket(params)` writes a `marketId` entry into shared storage.
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

**Canonical types — match design spec §14.1, §15.1, §15.2 exactly.** If these diverge, the spec wins. Do not invent alternate layouts.

```solidity
struct BatchPublicInputs {
    bytes32 prevStateRoot;
    bytes32 postStateRoot;
    bytes32 batchHash;            // keccak256(abi.encode(BatchBlob))
    uint64  batchNonce;
    uint64  chainId;
    uint64  forceIncludeCursor;
}

struct ProofBundle {
    BatchPublicInputs publicInputs;
    bytes             sp1Proof;
    bytes             batchBlob;   // canonical encoding — see spec §15.2
}

interface ISettlement {
    function applyBatch(ProofBundle calldata bundle) external;
    function forceInclude(bytes calldata intent, bytes calldata sig) external payable;
    function stateRoot()            external view returns (bytes32);
    function batchNonce()           external view returns (uint64);
    function forceIncludeCursor()   external view returns (uint64);
    function programVKey()          external view returns (bytes32);
}

event BatchSettled(
    uint64  indexed batchNonce,
    bytes32         prevStateRoot,
    bytes32         postStateRoot,
    bytes32         batchHash,
    uint64          forceIncludeCursor
);
event ForcedIntentResolved(
    uint256 indexed forcedIntentId,
    uint8           outcome,      // 1 = accepted, 2 = rejected
    uint8           rejectReason,
    bytes32         resultHash
);
```

No `BatchHeader { marketId, intentsRoot, fillsRoot, ... }` — that earlier sketch is retracted. `marketId` is per-`Fill`, not per-batch (one batch can contain fills across markets). `intentsRoot` / `fillsRoot` are not public inputs; the batch blob is identified by `batchHash` and decoded on-chain.

**Steps:**

1. Scaffold `Settlement.sol` UUPS upgradable (`Initializable`, `AccessControlUpgradeable`, `UUPSUpgradeable`, `PausableUpgradeable`).
2. Wire `ISP1Verifier public verifier;` + `bytes32 public programVKey;` + `bytes32 public pendingProgramVKey;` + `uint64 public programVKeyTimelockStart;` — set via initializer.
3. Implement `applyBatch(ProofBundle calldata bundle)` — order of ops exactly as spec §15.3 steps 1-14:
   - decode `bundle.batchBlob` → `blob`; assert `keccak256(bundle.batchBlob) == bundle.publicInputs.batchHash`;
   - `require(bundle.publicInputs.chainId == block.chainid)`;
   - `require(bundle.publicInputs.batchNonce == batchNonce + 1)`;
   - `require(bundle.publicInputs.prevStateRoot == stateRoot)`;
   - `require(blob.header.forceIncludeCursor == bundle.publicInputs.forceIncludeCursor)`;
   - `verifier.verifyProof(programVKey, abi.encode(bundle.publicInputs), bundle.sp1Proof)`;
   - force-include liveness: every `pendingForcedIntent[i]` with `deadlineBatchNonce <= bundle.publicInputs.batchNonce` and `!resolved` MUST appear in `blob.forcedOutcomes` — else revert `ForcedIntentOverdue(i)`;
   - for each `blob.forcedOutcomes[k]`: store `outcome` + `rejectReason` + `resultHash` + set `resolved = true`, emit `ForcedIntentResolved(...)`;
   - `Vault.applyBatchDelta(batchNonce, blob.balanceDeltas)` — Vault is the sole writer of free/order/position-margin and realized-PnL buckets (spec §15.3.1);
   - For each `MidPriceUpdate` in `blob.midPriceUpdates`, Settlement calls `FundingRate.updateSequencerMid(marketId, mid)` **directly** — not via Vault. `SETTLEMENT_ROLE` on FundingRate is granted once at bootstrap;
   - `PositionManager.applyBatchFills(batchNonce, blob.fills)` — position-state only, no inline `vault.*` mutations (spec §15.3.1);
   - assert `forceIncludeCursor` is contiguous (every queue id `[1..=newCursor]` now `resolved == true`) and `>= storedCursor` (monotonic, spec §15.3);
   - persist `stateRoot = postStateRoot; batchNonce = newNonce; forceIncludeCursor = newCursor`;
   - emit `BatchSettled(...)`. (Not `BatchApplied`, not `BatchFinalized` — those names are retired.)
4. Implement `forceInclude(bytes calldata intent, bytes calldata sig) external payable` — decode `marketId + trader + nonce + deadline` from the EIP-712 payload, append to `pendingForcedIntent[]` with `deadlineBatchNonce = batchNonce + FORCE_INCLUDE_N` (default 3 per ADR-0014). Charge fixed USDC fee for spam protection. Emit `ForceIncludeQueued(id, trader, intentHash, deadlineBatchNonce)`.
5. Implement `proposeProgramVKey(newVKey)` + `activateProgramVKey(newVKey)` per spec §15.5 (storage-backed, pause-and-drain). `activate` requires `paused() == true`, `block.timestamp >= proposalTimestamp + ROTATION_TIMELOCK`, and no overdue unresolved force-included intents. Plus `forceActivateProgramVKey(newVKey, forceState)` per spec §15.5 anti-grief path (non-cooperative sequencer recovery) — requires `paused() == true` for the full `ROTATION_FORCE_TIMELOCK` window (default 7 days) and writes governance-asserted `(postStateRoot, batchNonce, forceIncludeCursor)` while rejecting all queued force-included intents with `rejectReason = REJECTED_SEQUENCER_FORCED_ROTATION`.
6. Unit tests: nonce monotonicity, bad prev root, bad chainId, bad proof revert, happy path with mock verifier, force-include queue bounds, force-include overdue revert, force-include outcome storage, vkey rotation happy path, vkey rotation while sequencer unpaused (must revert).

**Verification:** `forge test --match-contract Settlement` green.

---

### Task 4 — Vault + PositionManager batch entry points (single-owner split)

**Files edited:**

- `contracts/src/Vault.sol` — `applyBatchDelta(BalanceDelta[])`
- `contracts/src/PositionManager.sol` — `applyBatchFills(Fill[])`
- `contracts/src/interfaces/IVault.sol`, `IPositionManager.sol`

**Single-owner rule (spec §15.3.1):** under Path B, every Vault-bucket mutation for a fill (order-margin release, position-margin lock/unlock, realized PnL, funding payment, flip margin delta) is pre-computed off-chain by the matcher and applied by `Vault.applyBatchDelta` **only**. `PositionManager.applyBatchFills` writes position state only and **MUST NOT** call any mutating `vault.*` method. This reverses the Phase 2 per-fill pattern where PositionManager called `vault.unlockOrderMargin`, `vault.lockMargin`, `vault.realizePnl` inline. Those calls are deleted from the batch path.

**Steps:**

1. `Vault.applyBatchDelta(uint64 batchNonce, BalanceDelta[] calldata deltas)`:
   - `onlyRole(SETTLEMENT_ROLE)`.
   - Iterate `deltas`; dispatch on balance/margin/PnL/funding kinds only (e.g. `UnlockOrderMargin`, `LockPositionMargin`, `UnlockPositionMargin`, `RealizePnl`, `FundingPayment`). Each type maps to an existing Phase 1 internal helper (`_unlockOrderMargin`, `_realizePnl`, etc.).
   - `MidPriceUpdate` is **not** a `BalanceDelta` kind under the final spec. Settlement applies `blob.midPriceUpdates` separately via `FundingRate.updateSequencerMid` before `PositionManager.applyBatchFills`.
   - Assert fills-conservation `Σ balanceDeltas + insurance + fees == 0` (spec §10).
2. `PositionManager.applyBatchFills(uint64 batchNonce, Fill[] calldata fills)`:
   - `onlyRole(SETTLEMENT_ROLE)`.
   - Walk `fills` in order; for each, update `(size, entryPrice, collateral, lastCumulativeFunding)` and the `_positionHolders` set.
   - **No `vault.*` calls.** Read `vault.freeCollateral(account)` only for invariant assertions (IMR at open/increase, MMR at decrease-into-loss). A failed assertion reverts the whole `applyBatch` — the sequencer must not have accepted the fill in the first place if invariants would break, so a revert means prover/matcher divergence and is an incident.
3. **Equivalence test** (spec §15.3.1 gate): `contracts/test/unit/BatchEquivalence.t.sol`. For each scenario in `PositionManager.t.sol` (open / increase / partial close / full close / flip / flip-into-loss / funding-settled-on-fill), construct (a) a one-fill `Fill[]` + equivalent `BalanceDelta[]` computed in a pure-Solidity helper, and (b) the Phase 2 sequential per-fill call path (legacy test harness). Assert end-state `(Position, vault.freeCollateral, vault.lockedOrderMargin, vault.lockedPositionMargin, FundingRate.cumulative)` is **bit-identical**. Any divergence blocks the contracts-v2 merge.
4. Reuse Phase 2 invariants: signed qty conservation, no cross-market writes, IMR at open/increase, MMR at decrease-into-loss, `USDC.balanceOf(vault) * 1e12 >= totalDeposits`.

**Verification:** `forge test --match-path contracts/test/unit/PositionManager.t.sol` + `Vault.t.sol` + `BatchEquivalence.t.sol` green; new `SettlementBatch_Integration.t.sol` (Task 9) simulates a 10-fill batch and asserts end state.

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

### Task 6 — MarketFactory (config-only registry, global Settlement)

**Files edited:**

- `contracts/src/MarketFactory.sol`
- `contracts/test/unit/MarketFactory.t.sol`
- `contracts/script/DeployMarket.s.sol`

**Global-singleton model.** Settlement / Vault / PositionManager / MarginEngine / LiquidationEngine / FundingRate / OracleAdapter are all deployed once by a bootstrap script (`script/DeployCore.s.sol`, separate from per-market creation). `MarketFactory.createMarket` is pure configuration registration — no contract deploys — so adding a market is a single storage write + event.

**Steps:**

1. Delete the `_deployOrderBook` internal. Do **not** replace with `_deploySettlement` — Settlement is global, already deployed.
2. `createMarket(MarketParams params) external onlyRole(ADMIN_ROLE) returns (uint256 marketId)`:
   - assign `marketId = nextMarketId++`;
   - write `marketParams[marketId] = params` (tick, lot, IMR, MMR, Pyth price id, funding interval, max funding rate, min/max order size, maker/taker fees);
   - `marketActive[marketId] = true`;
   - write initial `FundingRate.fundingStates[marketId]` via `FundingRate.initMarket(marketId, params)` (new admin helper);
   - write initial `MarginEngine` market config;
   - emit `MarketCreated(marketId, params)`.
3. `SETTLEMENT_ROLE` is granted at bootstrap, once, to the global Settlement. It is **not** re-granted per market.
4. `pauseMarket(marketId)` / `unpauseMarket(marketId)` admin functions flip `marketActive[marketId]`; Settlement reads this during `applyBatch` and reverts any batch containing a fill for a paused market.
5. Define `script/DeployCore.s.sol` explicitly instead of hand-waving it:
   - deploy verifier, Vault, PositionManager, MarginEngine, FundingRate, LiquidationEngine, OracleAdapter, Settlement, Router, and MarketFactory once;
   - initialize every proxy in dependency order;
   - grant `SETTLEMENT_ROLE` to the global Settlement on Vault / PositionManager / MarginEngine / FundingRate;
   - grant keeper / admin roles (`LIQUIDATOR_ROLE`, market-admin) and wire Router / MarketFactory to the already-deployed core addresses;
   - assert `hasRole(SETTLEMENT_ROLE, settlement) == true` everywhere before any market registration.

**Verification:** `forge test --match-contract MarketFactory` green; `DeployCore.s.sol` on Anvil deploys the core set once, then `DeployMarket.s.sol` registers BTC-USD and ETH-USD as market ids 1 and 2 without redeploying any contracts.

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
3. `forceInclude` forwards the raw signed intent to the **global** Settlement contract. Settlement pushes it into a single unified force-include queue (one queue for the whole exchange, not one per market) and assigns `deadlineBatchNonce = batchNonce + FORCE_INCLUDE_N`. Validates `marketActive[intent.marketId] == true`. Charges a fixed fee in USDC to prevent spam.
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
- `gaekju-types` must export the final Path B surface, not just raw ABIs: `BatchPublicInputs`, `ProofBundle`, `BatchBlob`, `BatchHeader`, `Intent` (EIP-712 signed-intent envelope shared by sequencer intake + `Router.forceInclude` + prover guest), `Fill`, `BalanceDelta`, `MidPriceUpdate`, `ForcedOutcome`, and event decoders for `BatchSettled`, `ForceIncludeQueued`, and `ForcedIntentResolved`.
- `gaekju-indexer` must stop watching OrderBook events after Task 1 or it will crash. Coordinate so indexer update (see `2026-04-22-indexer-api-updates.md`) lands in the same release train.

---

## Risks

- **ABI drift during deletion.** Mitigation: build types crate between every contract task.
- **`SETTLEMENT_ROLE` misgranted in deploy script.** Mitigation: post-deploy assertion script that checks `hasRole(SETTLEMENT_ROLE, settlement) == true` on Vault/PM/MarginEngine/FundingRate.
- **Force-include griefing.** Mitigation: fixed USDC fee + per-sender rate limit in Router.
- **Proof replay.** Mitigation: batch-nonce monotonicity enforced in `applyBatch`.
