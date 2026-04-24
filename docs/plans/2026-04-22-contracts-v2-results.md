# Contracts v2 Results

Date: 2026-04-24
Branch target: `pivot/contracts-v2`

## Summary

- Baseline from `/tmp/pre-pivot-tests.log`: 131 passing tests across 16 suites.
- Final result from `/tmp/post-pivot-tests.log`: 103 passing tests across 13 suites.
- Delta vs Phase 2 baseline: `-28` tests.
- Note: the pre-pivot log retained only the final suite-summary line, so the diff is available at the total-count level, not per-suite.

## Final Test Matrix

| Suite | Count | Result |
| --- | ---: | --- |
| `test/unit/OracleAdapter.t.sol:OracleAdapterTest` | 5 | PASS |
| `test/unit/FixedPointMath.t.sol:FixedPointMathTest` | 16 | PASS |
| `test/unit/Router.t.sol:RouterTest` | 4 | PASS |
| `test/unit/Vault.t.sol:VaultTest` | 12 | PASS |
| `test/integration/SettlementBatch_Integration.t.sol:SettlementBatchIntegrationTest` | 3 | PASS |
| `test/unit/LiquidationEngine.t.sol:LiquidationEngineTest` | 4 | PASS |
| `test/unit/MarketFactory.t.sol:MarketFactoryTest` | 5 | PASS |
| `test/unit/MarginEngine.t.sol:MarginEngineTest` | 9 | PASS |
| `test/unit/BatchEquivalence.t.sol:BatchEquivalenceTest` | 5 | PASS |
| `test/unit/Settlement.t.sol:SettlementTest` | 14 | PASS |
| `test/unit/PositionManager.t.sol:PositionManagerTest` | 20 | PASS |
| `test/fuzz/FixedPointMath.fuzz.t.sol:FixedPointMathFuzzTest` | 4 | PASS |
| `test/fuzz/PositionManager.fuzz.t.sol:PositionManagerFuzzTest` | 2 | PASS |

Total: `103 / 103` passing.

## Coverage Notes

- `SettlementBatchIntegrationTest` now covers the Path B end-to-end batch path: router deposits, inline `BatchBlob` construction, `Settlement.applyBatch`, nonce monotonicity, force-include overdue handling, and paused-market rejection.
- `LiquidationEngineTest` was rewritten for Path B and seeds positions through `Settlement.applyBatch` instead of deleted orderbook flows.
- Liquidation coverage now includes:
  - healthy position rejected by `liquidate`
  - full liquidation with keeper fee credit
  - partial liquidation with remaining open size
  - full liquidation with deficit covered by the insurance fund
- Removed bitmap/orderbook suites account for the net drop from the 131-test Phase 2 baseline.

## Deferrals

- FundingRate Task T8 remains deferred to Phase 5.5.
- ADL placeholder coverage for `LiquidationEngine.autoDeleverage` was intentionally skipped in this task and should be added later when the keeper/ADL path is specified in more detail.

## Hygiene Checks

- `forge build --offline` succeeded.
- `forge test --offline -vvv` succeeded and wrote `/tmp/post-pivot-tests.log`.
- `grep -r 'OrderBook\|BitmapLib\|TickMath\|PackedOrder\|ORDERBOOK_ROLE' contracts/src contracts/test` returned zero matches.
