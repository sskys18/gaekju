# Phase 2: Position Management & Liquidation Engine — Implementation Plan

> **2026-04-22 Status:** Executed. 131 tests green. Under Path B pivot (ADR-0012), Task 4 (OrderBook → PositionManager wiring) rebinds caller from ORDERBOOK_ROLE to SETTLEMENT_ROLE; test harness updates accordingly. All other tasks survive.


> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add position lifecycle management (open, increase, decrease, close, flip) integrated with the OrderBook fill flow, plus a full liquidation engine (partial, full, insurance fund, ADL) and a Rust liquidation keeper bot. By the end, a trader can deposit, place orders, get matched into positions, see unrealized PnL, and be liquidated when undercollateralized.

**Architecture:** PositionManager owns all position state and is the only contract that calls `vault.lockMargin` / `vault.unlockMargin` for position collateral. OrderBook's `_executeFill` delegates to PositionManager for margin conversion. LiquidationEngine reads position/margin state and calls PositionManager to reduce positions. FundingRate settlement is stubbed as a no-op (Phase 3).

**Tech Stack:** Solidity 0.8.28 · Foundry · OpenZeppelin 5.x (UUPS, AccessControl, ReentrancyGuard, EnumerableSet) · Rust 1.82+ · alloy 0.12 · tokio

**Spec reference:** `docs/specs/2026-04-06-gaekju-design.md` — Sections 3.6 (PositionManager), 3.7 (LiquidationEngine), 6 (Phase 2a + 2b), 8 (Formulas)

**Depends on:** Phase 1 complete — Vault, OracleAdapter, MarginEngine, OrderBook, all libraries, gaekju-types crate.

---

## File Map

### New files created in this plan

```
gaekju/
├── contracts/
│   ├── src/
│   │   ├── interfaces/
│   │   │   ├── IPositionManager.sol
│   │   │   └── ILiquidationEngine.sol
│   │   ├── PositionManager.sol
│   │   └── LiquidationEngine.sol
│   ├── test/
│   │   ├── unit/
│   │   │   ├── PositionManager.t.sol
│   │   │   └── LiquidationEngine.t.sol
│   │   ├── integration/
│   │   │   ├── PositionLifecycle.t.sol
│   │   │   └── LiquidationFlow.t.sol
│   │   └── fuzz/
│   │       └── PositionManager.fuzz.t.sol
├── crates/
│   └── gaekju-keeper/
│       ├── Cargo.toml              (updated with dependencies)
│       └── src/
│           ├── main.rs             (updated from stub)
│           ├── liquidator.rs
│           └── tx.rs
└── docs/
    └── blog/
        ├── 03-margin-from-scratch.md   (written)
        └── 04-liquidation-math.md      (written)
```

### Existing files modified in this plan

```
contracts/src/OrderBook.sol         — _executeFill calls PositionManager
contracts/src/interfaces/IOrderBook.sol — add setPositionManager
crates/gaekju-types/src/events.rs   — add position + liquidation events
crates/gaekju-keeper/Cargo.toml     — add alloy, tokio, tracing deps
```

---

## Task 0: IPositionManager Interface

**Files:**
- Create: `contracts/src/interfaces/IPositionManager.sol`

- [ ] **Step 0.1: Create IPositionManager interface**

`contracts/src/interfaces/IPositionManager.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPositionManager {
    struct Position {
        int256 size;
        uint256 entryPrice;
        uint256 collateral;
        int256 lastCumulativeFunding;
        uint256 lastUpdated;
    }

    function updatePosition(
        address account,
        uint256 marketId,
        int256 sizeDelta,
        uint256 fillPrice,
        uint256 marginDelta
    ) external;

    function liquidatePosition(
        address account,
        uint256 marketId,
        int256 sizeDelta,
        uint256 liquidationPrice
    ) external;

    function getPosition(address account, uint256 marketId) external view returns (Position memory);
    function getUnrealizedPnl(address account, uint256 marketId) external view returns (int256);
    function getMarginRatio(address account, uint256 marketId) external view returns (uint256);
    function getPositionHolders(uint256 marketId) external view returns (address[] memory);
    function getPositionCount(uint256 marketId) external view returns (uint256);

    event PositionUpdated(
        address indexed account,
        uint256 indexed marketId,
        int256 newSize,
        uint256 entryPrice,
        uint256 collateral,
        int256 realizedPnl
    );
    event PositionClosed(address indexed account, uint256 indexed marketId, int256 realizedPnl);
}
```

- [ ] **Step 0.2: Commit**

```bash
git add contracts/src/interfaces/IPositionManager.sol
git commit -m "feat(contracts): add IPositionManager interface"
```

---

## Task 1: PositionManager — Unit Tests (TDD)

**Files:**
- Create: `contracts/test/unit/PositionManager.t.sol`

- [ ] **Step 1.1: Write unit tests for all position transitions**

`contracts/test/unit/PositionManager.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { Vault } from "../../src/Vault.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";

contract PositionManagerTest is Test {
    PositionManager public pm;
    Vault public vault;
    MarginEngine public engine;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public orderBook = makeAddr("orderBook");
    address public liquidationEngine = makeAddr("liquidationEngine");
    address public alice = makeAddr("alice");

    uint256 constant MARKET_ID = 0;
    uint256 constant TICK_SIZE = 0.1e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );

        oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );

        engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );

        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (address(vault), address(engine), address(oracle), admin)
                    )
                )
            )
        );

        vm.startPrank(admin);
        vault.grantAuthorized(address(pm));
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(orderBook);
        pm.setOrderBook(orderBook);
        pm.setLiquidationEngine(liquidationEngine);

        engine.setMarketConfig(
            MARKET_ID,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                tickSize: TICK_SIZE,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );
        oracle.setMarketOracle(MARKET_ID, bytes32(uint256(1)), 60);
        vm.stopPrank();

        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);

        // Fund alice
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100_000e6);

        // Lock some order margin to simulate pre-fill state
        vm.prank(orderBook);
        vault.lockOrderMargin(alice, 600e18);
    }

    // ─── New Position ───

    function test_newLongPosition() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);
        assertTrue(pos.lastUpdated > 0);
    }

    function test_newShortPosition() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 60_000e18, 600e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);
    }

    function test_newPosition_registersHolder() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);

        assertEq(pm.getPositionCount(MARKET_ID), 1);
        address[] memory holders = pm.getPositionHolders(MARKET_ID);
        assertEq(holders[0], alice);
    }

    // ─── Increase Position ───

    function test_increaseLong_weightedAvgEntry() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);

        // Lock more order margin for second fill
        vm.prank(orderBook);
        vault.lockOrderMargin(alice, 620e18);

        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 62_000e18, 620e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 1e18);
        // Weighted avg: (60000 * 0.5 + 62000 * 0.5) / 1.0 = 61000
        assertEq(pos.entryPrice, 61_000e18);
        assertEq(pos.collateral, 1_220e18);
    }

    function test_increaseShort_weightedAvgEntry() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 60_000e18, 600e18);

        vm.prank(orderBook);
        vault.lockOrderMargin(alice, 580e18);

        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 58_000e18, 580e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -1e18);
        // Weighted avg: (60000 * 0.5 + 58000 * 0.5) / 1.0 = 59000
        assertEq(pos.entryPrice, 59_000e18);
        assertEq(pos.collateral, 1_180e18);
    }

    // ─── Partial Close ───

    function test_partialCloseLong_profit() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        uint256 balanceBefore = vault.balances(alice);

        // Close half at $62,000 => PnL = (62000 - 60000) * 0.5 = 1000
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 62_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);

        // Balance increased by: PnL (1000) + released collateral (600)
        uint256 balanceAfter = vault.balances(alice);
        assertApproxEqAbs(balanceAfter - balanceBefore, 1_600e18, 1e15);
    }

    function test_partialCloseLong_loss() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        uint256 balanceBefore = vault.balances(alice);

        // Close half at $58,000 => PnL = (58000 - 60000) * 0.5 = -1000
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);

        // Balance changed by: PnL (-1000) + released collateral (600) = -400
        uint256 balanceAfter = vault.balances(alice);
        // balanceAfter = balanceBefore + 600 - 1000 = balanceBefore - 400
        assertApproxEqAbs(balanceBefore - balanceAfter, 400e18, 1e15);
    }

    function test_partialCloseShort_profit() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 1_200e18);

        uint256 balanceBefore = vault.balances(alice);

        // Close half at $58,000 => PnL = (58000 - 60000) * (-0.5) = +1000
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);

        uint256 balanceAfter = vault.balances(alice);
        assertApproxEqAbs(balanceAfter - balanceBefore, 1_600e18, 1e15);
    }

    // ─── Full Close ───

    function test_fullCloseLong() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -1e18, 62_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0);
        assertEq(pos.collateral, 0);

        // Holder removed from registry
        assertEq(pm.getPositionCount(MARKET_ID), 0);
    }

    function test_fullCloseShort() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 1_200e18);

        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0);
        assertEq(pm.getPositionCount(MARKET_ID), 0);
    }

    // ─── Flip ───

    function test_flipLongToShort() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        // Flip: sell 1.5 => close 1 long + open 0.5 short
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -1.5e18, 62_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -0.5e18);
        assertEq(pos.entryPrice, 62_000e18);
        // New margin = 0.5 * 62000 * 2% = 620
        assertEq(pos.collateral, 620e18);

        // Still registered as holder
        assertEq(pm.getPositionCount(MARKET_ID), 1);
    }

    function test_flipShortToLong() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 1_200e18);

        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1.5e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 58_000e18);
        // New margin = 0.5 * 58000 * 2% = 580
        assertEq(pos.collateral, 580e18);
    }

    // ─── Unrealized PnL ───

    function test_unrealizedPnl_long_profit() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        // Mark price from oracle = $60,000 (set in setUp)
        int256 pnl = pm.getUnrealizedPnl(alice, MARKET_ID);
        // (60000 - 60000) * 1 = 0
        assertEq(pnl, 0);
    }

    function test_unrealizedPnl_short_profit() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, -1e18, 62_000e18, 1_240e18);

        // Mark price ~ $60,000
        int256 pnl = pm.getUnrealizedPnl(alice, MARKET_ID);
        // (60000 - 62000) * (-1) = +2000
        assertApproxEqAbs(uint256(pnl), 2_000e18, 100e18); // blended price tolerance
    }

    // ─── Margin Ratio ───

    function test_marginRatio_noPosition() public view {
        uint256 ratio = pm.getMarginRatio(alice, MARKET_ID);
        assertEq(ratio, type(uint256).max);
    }

    function test_marginRatio_healthyPosition() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        uint256 ratio = pm.getMarginRatio(alice, MARKET_ID);
        // collateral=1200, notional=60000*1=60000, unrealPnL~0
        // ratio = 1200 / 60000 = 0.02 = 2e16
        assertApproxEqAbs(ratio, 2e16, 1e15);
    }

    // ─── Access Control ───

    function test_updatePosition_onlyOrderBook() public {
        vm.expectRevert();
        vm.prank(alice);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);
    }

    function test_liquidatePosition_onlyLiquidationEngine() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        vm.expectRevert();
        vm.prank(alice);
        pm.liquidatePosition(alice, MARKET_ID, -0.5e18, 60_000e18);
    }

    // ─── Events ───

    function test_emitsPositionUpdated() public {
        vm.prank(orderBook);
        vm.expectEmit(true, true, false, true);
        emit IPositionManager.PositionUpdated(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18, 0);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);
    }

    function test_emitsPositionClosed() public {
        vm.prank(orderBook);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        vm.prank(orderBook);
        vm.expectEmit(true, true, false, false);
        emit IPositionManager.PositionClosed(alice, MARKET_ID, 0);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 0);
    }
}
```

- [ ] **Step 1.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract PositionManagerTest -vvv
```

Expected: compilation error, `PositionManager.sol` not found.

- [ ] **Step 1.3: Commit test file**

```bash
git add contracts/test/unit/PositionManager.t.sol
git commit -m "test(contracts): add PositionManager unit tests (TDD — red phase)"
```

---

## Task 2: PositionManager Implementation

**Files:**
- Create: `contracts/src/PositionManager.sol`

- [ ] **Step 2.1: Implement PositionManager**

`contracts/src/PositionManager.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IMarginEngine } from "./interfaces/IMarginEngine.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { FixedPointMath } from "./libraries/FixedPointMath.sol";

contract PositionManager is IPositionManager, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixedPointMath for uint256;

    error OnlyOrderBook();
    error OnlyLiquidationEngine();
    error NoPosition();
    error InsufficientBalance();

    IVault public vault;
    IMarginEngine public marginEngine;
    IOracleAdapter public oracle;
    address public orderBook;
    address public liquidationEngine;

    mapping(address => mapping(uint256 => Position)) internal _positions;
    mapping(uint256 => EnumerableSet.AddressSet) internal _positionHolders;

    uint256[50] private __gap;

    modifier onlyOrderBook() {
        if (msg.sender != orderBook) revert OnlyOrderBook();
        _;
    }

    modifier onlyLiquidationEngine() {
        if (msg.sender != liquidationEngine) revert OnlyLiquidationEngine();
        _;
    }

    function initialize(address _vault, address _marginEngine, address _oracle, address _admin)
        external
        initializer
    {
        __AccessControl_init();
        vault = IVault(_vault);
        marginEngine = IMarginEngine(_marginEngine);
        oracle = IOracleAdapter(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setOrderBook(address _orderBook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        orderBook = _orderBook;
    }

    function setLiquidationEngine(address _liquidationEngine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        liquidationEngine = _liquidationEngine;
    }

    function updatePosition(
        address account,
        uint256 marketId,
        int256 sizeDelta,
        uint256 fillPrice,
        uint256 marginDelta
    ) external onlyOrderBook nonReentrant {
        _updatePositionInternal(account, marketId, sizeDelta, fillPrice, marginDelta);
    }

    function liquidatePosition(
        address account,
        uint256 marketId,
        int256 sizeDelta,
        uint256 liquidationPrice
    ) external onlyLiquidationEngine nonReentrant {
        _liquidateInternal(account, marketId, sizeDelta, liquidationPrice);
    }

    function _updatePositionInternal(
        address account,
        uint256 marketId,
        int256 sizeDelta,
        uint256 fillPrice,
        uint256 marginDelta
    ) internal {
        Position storage pos = _positions[account][marketId];

        // Stub: settleFunding(account, marketId) — no-op until Phase 3

        // Convert order margin to position margin
        if (marginDelta > 0) {
            vault.unlockOrderMargin(account, marginDelta);
            vault.lockMargin(account, marginDelta);
        }

        int256 realizedPnl = 0;

        if (pos.size == 0) {
            // New position
            pos.size = sizeDelta;
            pos.entryPrice = fillPrice;
            pos.collateral = marginDelta;
            pos.lastUpdated = block.timestamp;
            _positionHolders[marketId].add(account);

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, 0);
        } else if (_sameDirection(pos.size, sizeDelta)) {
            // Increase — weighted average entry price
            uint256 oldNotional = FixedPointMath.mulFp(pos.entryPrice, FixedPointMath.abs(pos.size));
            uint256 newNotional = FixedPointMath.mulFp(fillPrice, FixedPointMath.abs(sizeDelta));
            uint256 totalSize = FixedPointMath.abs(pos.size) + FixedPointMath.abs(sizeDelta);

            pos.entryPrice = FixedPointMath.divFp(oldNotional + newNotional, totalSize);
            pos.size = pos.size + sizeDelta;
            pos.collateral += marginDelta;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, 0);
        } else if (FixedPointMath.abs(sizeDelta) < FixedPointMath.abs(pos.size)) {
            // Partial close
            uint256 closeSize = FixedPointMath.abs(sizeDelta);
            uint256 absOldSize = FixedPointMath.abs(pos.size);

            realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, fillPrice, closeSize);
            vault.realizePnl(account, realizedPnl);

            uint256 proportionalCollateral = FixedPointMath.mulDiv(pos.collateral, closeSize, absOldSize);
            pos.collateral -= proportionalCollateral;
            vault.unlockMargin(account, proportionalCollateral);

            pos.size = pos.size + sizeDelta;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, realizedPnl);
        } else if (FixedPointMath.abs(sizeDelta) == FixedPointMath.abs(pos.size)) {
            // Full close
            realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, fillPrice, FixedPointMath.abs(pos.size));
            vault.realizePnl(account, realizedPnl);
            vault.unlockMargin(account, pos.collateral);

            emit PositionClosed(account, marketId, realizedPnl);

            delete _positions[account][marketId];
            _positionHolders[marketId].remove(account);
        } else {
            // Flip — close old, open new in opposite direction
            uint256 absOldSize = FixedPointMath.abs(pos.size);
            realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, fillPrice, absOldSize);
            vault.realizePnl(account, realizedPnl);
            vault.unlockMargin(account, pos.collateral);

            int256 remainingSize = pos.size + sizeDelta;
            uint256 absRemaining = FixedPointMath.abs(remainingSize);

            (uint256 imr,,,,,,) = marginEngine.configs(marketId);
            // IMR is stored in initialMarginRate field (2nd return), but configs returns maxLeverage first
            // Re-read properly
            IMarginEngine.MarketConfig memory cfg = marginEngine.getConfig(marketId);
            uint256 newNotional = FixedPointMath.mulFp(absRemaining, fillPrice);
            uint256 newCollateral = FixedPointMath.mulFp(newNotional, cfg.initialMarginRate);

            vault.lockMargin(account, newCollateral);

            pos.size = remainingSize;
            pos.entryPrice = fillPrice;
            pos.collateral = newCollateral;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, realizedPnl);
        }
    }

    function _liquidateInternal(
        address account,
        uint256 marketId,
        int256 sizeDelta,
        uint256 liquidationPrice
    ) internal {
        Position storage pos = _positions[account][marketId];
        if (pos.size == 0) revert NoPosition();

        uint256 closeSize = FixedPointMath.abs(sizeDelta);
        uint256 absOldSize = FixedPointMath.abs(pos.size);

        int256 realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, liquidationPrice, closeSize);

        if (closeSize == absOldSize) {
            // Full liquidation
            vault.realizePnl(account, realizedPnl);
            vault.unlockMargin(account, pos.collateral);

            emit PositionClosed(account, marketId, realizedPnl);
            delete _positions[account][marketId];
            _positionHolders[marketId].remove(account);
        } else {
            // Partial liquidation
            uint256 proportionalCollateral = FixedPointMath.mulDiv(pos.collateral, closeSize, absOldSize);
            vault.realizePnl(account, realizedPnl);
            pos.collateral -= proportionalCollateral;
            vault.unlockMargin(account, proportionalCollateral);
            pos.size = pos.size + sizeDelta;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, realizedPnl);
        }
    }

    // ─── View Functions ───

    function getPosition(address account, uint256 marketId) external view returns (Position memory) {
        return _positions[account][marketId];
    }

    function getUnrealizedPnl(address account, uint256 marketId) external view returns (int256) {
        Position memory pos = _positions[account][marketId];
        if (pos.size == 0) return 0;

        uint256 markPrice = oracle.getMarkPrice(marketId);
        return _computeUnrealizedPnl(pos.size, pos.entryPrice, markPrice);
    }

    function getMarginRatio(address account, uint256 marketId) external view returns (uint256) {
        Position memory pos = _positions[account][marketId];
        if (pos.size == 0) return type(uint256).max;

        uint256 markPrice = oracle.getMarkPrice(marketId);
        uint256 notional = FixedPointMath.mulFp(FixedPointMath.abs(pos.size), markPrice);
        int256 unrealizedPnl = _computeUnrealizedPnl(pos.size, pos.entryPrice, markPrice);

        int256 equity = int256(pos.collateral) + unrealizedPnl;
        if (equity <= 0) return 0;

        return FixedPointMath.divFp(uint256(equity), notional);
    }

    function getPositionHolders(uint256 marketId) external view returns (address[] memory) {
        return _positionHolders[marketId].values();
    }

    function getPositionCount(uint256 marketId) external view returns (uint256) {
        return _positionHolders[marketId].length();
    }

    // ─── Internal Helpers ───

    function _sameDirection(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function _calculateClosePnl(int256 posSize, uint256 entryPrice, uint256 closePrice, uint256 closeSize)
        internal
        pure
        returns (int256)
    {
        int256 priceDiff = int256(closePrice) - int256(entryPrice);
        int256 sign = posSize > 0 ? int256(1) : int256(-1);
        return FixedPointMath.mulFpSigned(priceDiff * sign, int256(closeSize));
    }

    function _computeUnrealizedPnl(int256 posSize, uint256 entryPrice, uint256 markPrice)
        internal
        pure
        returns (int256)
    {
        int256 priceDiff = int256(markPrice) - int256(entryPrice);
        return FixedPointMath.mulFpSigned(priceDiff, posSize);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
```

- [ ] **Step 2.2: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract PositionManagerTest -vvv
```

Expected: all tests PASS.

- [ ] **Step 2.3: Commit**

```bash
git add contracts/src/PositionManager.sol
git commit -m "feat(contracts): add PositionManager with position lifecycle (new, increase, close, flip)"
```

---

## Task 3: PositionManager Fuzz Tests

**Files:**
- Create: `contracts/test/fuzz/PositionManager.fuzz.t.sol`

- [ ] **Step 3.1: Write fuzz tests for weighted average entry price**

`contracts/test/fuzz/PositionManager.fuzz.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { FixedPointMath } from "../../src/libraries/FixedPointMath.sol";

contract PositionManagerFuzzTest is Test {
    /// @dev Weighted avg entry must always be between the two fill prices.
    function testFuzz_weightedAvgEntry_bounded(
        uint64 rawOldSize,
        uint64 rawNewSize,
        uint64 rawOldPrice,
        uint64 rawNewPrice
    ) public pure {
        // Constrain to reasonable ranges: size 0.001-100 BTC, price $100-$1M
        uint256 oldSize = bound(uint256(rawOldSize), 0.001e18, 100e18);
        uint256 newSize = bound(uint256(rawNewSize), 0.001e18, 100e18);
        uint256 oldPrice = bound(uint256(rawOldPrice), 100e18, 1_000_000e18);
        uint256 newPrice = bound(uint256(rawNewPrice), 100e18, 1_000_000e18);

        uint256 oldNotional = FixedPointMath.mulFp(oldPrice, oldSize);
        uint256 newNotional = FixedPointMath.mulFp(newPrice, newSize);
        uint256 totalSize = oldSize + newSize;

        uint256 avgPrice = FixedPointMath.divFp(oldNotional + newNotional, totalSize);

        uint256 minPrice = FixedPointMath.min(oldPrice, newPrice);
        uint256 maxPrice = FixedPointMath.max(oldPrice, newPrice);

        // Avg price must be within [minPrice, maxPrice] (with 1 wei tolerance for rounding)
        assertTrue(avgPrice >= minPrice - 1, "avg below min");
        assertTrue(avgPrice <= maxPrice + 1, "avg above max");
    }

    /// @dev Close PnL + remaining position value should equal total position value.
    function testFuzz_closePnl_conservesValue(
        uint64 rawSize,
        uint64 rawEntry,
        uint64 rawClose,
        uint64 rawCloseRatio
    ) public pure {
        uint256 posSize = bound(uint256(rawSize), 0.001e18, 100e18);
        uint256 entryPrice = bound(uint256(rawEntry), 100e18, 1_000_000e18);
        uint256 closePrice = bound(uint256(rawClose), 100e18, 1_000_000e18);
        uint256 closeRatio = bound(uint256(rawCloseRatio), 1, 99); // 1-99% close

        uint256 closeSize = (posSize * closeRatio) / 100;
        if (closeSize == 0) closeSize = 1;
        if (closeSize >= posSize) closeSize = posSize - 1;

        int256 priceDiff = int256(closePrice) - int256(entryPrice);
        int256 pnl = FixedPointMath.mulFpSigned(priceDiff, int256(closeSize));

        // Verify PnL is proportional to close size
        int256 fullPnl = FixedPointMath.mulFpSigned(priceDiff, int256(posSize));
        int256 expectedPnl = (fullPnl * int256(closeSize)) / int256(posSize);

        // Allow 2 wei tolerance for rounding
        assertApproxEqAbs(pnl, expectedPnl, 2);
    }
}
```

- [ ] **Step 3.2: Run fuzz tests**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract PositionManagerFuzzTest -vvv
```

Expected: all pass (10,000 runs per fuzz test).

- [ ] **Step 3.3: Commit**

```bash
git add contracts/test/fuzz/PositionManager.fuzz.t.sol
git commit -m "test(contracts): add PositionManager fuzz tests for weighted avg + PnL conservation"
```

---

## Task 4: OrderBook Integration — Connect Fills to PositionManager

**Files:**
- Modify: `contracts/src/OrderBook.sol`
- Modify: `contracts/src/interfaces/IOrderBook.sol`

This is the key integration point: OrderBook `_executeFill` must call PositionManager to convert order margin into position margin and update positions.

- [ ] **Step 4.1: Update IOrderBook interface**

Add to `contracts/src/interfaces/IOrderBook.sol`:
```solidity
function setPositionManager(address positionManager) external;
```

The full updated interface:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOrderBook {
    function placeOrder(address trader, bool side, uint256 price, uint256 size, uint8 orderType)
        external
        returns (uint256 orderId);

    function cancelOrder(uint256 orderId) external;
    function setPositionManager(address positionManager) external;

    function bestBidTick() external view returns (uint256);
    function bestAskTick() external view returns (uint256);
    function nextOrderId() external view returns (uint256);

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint256 indexed marketId,
        bool side,
        uint256 price,
        uint256 size,
        uint8 orderType
    );
    event OrderMatched(
        uint256 indexed marketId, uint256 makerOrderId, uint256 takerOrderId, uint256 price, uint256 size
    );
    event OrderCancelled(uint256 indexed orderId, address indexed trader);
    event Fill(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 price,
        uint256 size,
        bool takerSide
    );
}
```

- [ ] **Step 4.2: Modify OrderBook._executeFill to call PositionManager**

In `contracts/src/OrderBook.sol`, add the PositionManager import and state variable, then modify `_executeFill`.

Add import and interface after existing imports:
```solidity
import { IPositionManager } from "./interfaces/IPositionManager.sol";
```

Add state variable after `orderMarginAmount` mapping:
```solidity
IPositionManager public positionManager;
```

Add setter function after `setFeeConfig`:
```solidity
function setPositionManager(address _positionManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
    positionManager = IPositionManager(_positionManager);
}
```

Replace the existing `_executeFill` function with:
```solidity
function _executeFill(
    address maker,
    address taker,
    uint256 price,
    uint256 size,
    bool takerSide,
    uint256 makerOrderId,
    uint256 takerOrderId
) internal {
    // Calculate maker's margin portion for this fill
    uint256 makerMargin = orderMarginAmount[makerOrderId];
    bytes32 s1 = orderSlot1[makerOrderId];
    uint256 makerTotalSize = PackedOrder.getSize(s1);
    uint256 makerMarginUsed =
        (makerTotalSize == size) ? makerMargin : FixedPointMath.mulDiv(makerMargin, size, makerTotalSize);

    // Apply fees
    uint256 notional = FixedPointMath.mulFp(size, price);
    if (makerFeeRate != 0) {
        int256 makerFee = FixedPointMath.mulFpSigned(int256(notional), makerFeeRate);
        vault.realizePnl(maker, -makerFee);
    }
    if (takerFeeRate != 0) {
        int256 takerFee = FixedPointMath.mulFpSigned(int256(notional), takerFeeRate);
        vault.realizePnl(taker, -takerFee);
    }

    // Update positions via PositionManager (if connected)
    if (address(positionManager) != address(0)) {
        // Maker: opposite of taker side
        int256 makerSizeDelta = takerSide ? -int256(size) : int256(size);
        int256 takerSizeDelta = takerSide ? int256(size) : -int256(size);

        positionManager.updatePosition(maker, marketId, makerSizeDelta, price, makerMarginUsed);
        positionManager.updatePosition(taker, marketId, takerSizeDelta, price, 0);
    } else {
        // Legacy behavior: just release order margin (Phase 1 compat)
        if (makerMarginUsed > 0) {
            vault.unlockOrderMargin(maker, makerMarginUsed);
        }
    }

    emit OrderMatched(marketId, makerOrderId, takerOrderId, price, size);
    emit Fill(marketId, maker, taker, price, size, takerSide);
}
```

Also update `placeOrder` to not release taker margin directly when PositionManager is connected. Replace the margin release block in `placeOrder` (lines 107-111 in the current code):

Replace:
```solidity
        // Release taker's order margin for the filled portion
        // (In Phase 2, this converts to position margin via PositionManager)
        if (marginUsed > 0) {
            vault.unlockOrderMargin(trader, marginUsed);
        }
```

With:
```solidity
        // When PositionManager is not connected, release taker's margin directly.
        // When connected, PositionManager handles the margin conversion inside updatePosition.
        if (marginUsed > 0 && address(positionManager) == address(0)) {
            vault.unlockOrderMargin(trader, marginUsed);
        }
```

**Important note:** The taker's marginDelta is passed as 0 in `_executeFill` because the taker's order margin was already locked by `placeOrder`. The PositionManager's `updatePosition` for the taker will receive `marginDelta=0`, but the taker already has order margin locked. The PositionManager converts order margin to position margin via `vault.unlockOrderMargin` + `vault.lockMargin`. For the taker, this happens through a separate mechanism: the taker's order margin proportional to the fill is already tracked in the `placeOrder` flow. We need to pass the taker's margin correctly.

Actually, let me reconsider. The taker's order margin for the filled portion needs to be converted too. The `placeOrder` function locks `requiredMargin` for the full order. For fills, the margin needs to flow to PositionManager. The cleanest approach: pass the taker margin to PositionManager as well.

Update the `_executeFill` to compute taker margin proportionally. But we don't have the taker's total margin easily accessible here. Instead, compute it from the fill:

```solidity
    if (address(positionManager) != address(0)) {
        int256 makerSizeDelta = takerSide ? -int256(size) : int256(size);
        int256 takerSizeDelta = takerSide ? int256(size) : -int256(size);

        // Taker margin is calculated from the fill (same formula as maker)
        uint256 takerMarginForFill = marginEngine.getRequiredMargin(marketId, size, price);

        positionManager.updatePosition(maker, marketId, makerSizeDelta, price, makerMarginUsed);
        positionManager.updatePosition(taker, marketId, takerSizeDelta, price, takerMarginForFill);
    } else {
        if (makerMarginUsed > 0) {
            vault.unlockOrderMargin(maker, makerMarginUsed);
        }
    }
```

And then in `placeOrder`, never release taker's margin for filled portions when PositionManager is connected (the `if marginUsed > 0 && address(positionManager) == address(0)` change above handles this).

But wait — there's a subtlety. The taker locks margin based on total order size and price at `placeOrder`. But fills can happen at different prices (walking through multiple ticks). The order margin locked is based on the limit price, while fills happen at better prices. The margin per fill should be recalculated from the actual fill price via `marginEngine.getRequiredMargin`.

However, the taker may have locked more order margin than needed (if fills happen at better prices). The `placeOrder` function already handles releasing leftover margin. So the approach above is correct: let PositionManager convert `getRequiredMargin(fill)` worth of order margin for each fill, and `placeOrder` releases any leftover at the end.

Let me finalize the complete `_executeFill`:

```solidity
function _executeFill(
    address maker,
    address taker,
    uint256 price,
    uint256 size,
    bool takerSide,
    uint256 makerOrderId,
    uint256 takerOrderId
) internal {
    uint256 makerMargin = orderMarginAmount[makerOrderId];
    bytes32 s1 = orderSlot1[makerOrderId];
    uint256 makerTotalSize = PackedOrder.getSize(s1);
    uint256 makerMarginUsed =
        (makerTotalSize == size) ? makerMargin : FixedPointMath.mulDiv(makerMargin, size, makerTotalSize);

    uint256 notional = FixedPointMath.mulFp(size, price);
    if (makerFeeRate != 0) {
        int256 makerFee = FixedPointMath.mulFpSigned(int256(notional), makerFeeRate);
        vault.realizePnl(maker, -makerFee);
    }
    if (takerFeeRate != 0) {
        int256 takerFee = FixedPointMath.mulFpSigned(int256(notional), takerFeeRate);
        vault.realizePnl(taker, -takerFee);
    }

    if (address(positionManager) != address(0)) {
        int256 makerSizeDelta = takerSide ? -int256(size) : int256(size);
        int256 takerSizeDelta = takerSide ? int256(size) : -int256(size);
        uint256 takerMarginForFill = marginEngine.getRequiredMargin(marketId, size, price);

        positionManager.updatePosition(maker, marketId, makerSizeDelta, price, makerMarginUsed);
        positionManager.updatePosition(taker, marketId, takerSizeDelta, price, takerMarginForFill);
    } else {
        if (makerMarginUsed > 0) {
            vault.unlockOrderMargin(maker, makerMarginUsed);
        }
    }

    emit OrderMatched(marketId, makerOrderId, takerOrderId, price, size);
    emit Fill(marketId, maker, taker, price, size, takerSide);
}
```

- [ ] **Step 4.3: Run existing OrderBook tests to verify backward compatibility**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract OrderBookTest -vvv
```

Expected: all existing tests still PASS (PositionManager is not connected, so legacy path runs).

- [ ] **Step 4.4: Run full test suite**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test -vvv
```

Expected: all PASS including PositionManager tests.

- [ ] **Step 4.5: Commit**

```bash
git add contracts/src/OrderBook.sol contracts/src/interfaces/IOrderBook.sol
git commit -m "feat(contracts): integrate OrderBook fills with PositionManager for margin conversion"
```

---

## Task 5: Integration Test — Position Lifecycle

**Files:**
- Create: `contracts/test/integration/PositionLifecycle.t.sol`

- [ ] **Step 5.1: Write integration test**

`contracts/test/integration/PositionLifecycle.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { OrderBook } from "../../src/OrderBook.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";

contract PositionLifecycleTest is Test {
    Vault public vault;
    OrderBook public book;
    MarginEngine public engine;
    OracleAdapter public oracle;
    PositionManager public pm;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant MARKET_ID = 0;
    uint256 constant TICK_SIZE = 0.1e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );

        oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );

        engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );

        book = OrderBook(
            address(
                new ERC1967Proxy(
                    address(new OrderBook()),
                    abi.encodeCall(OrderBook.initialize, (MARKET_ID, address(vault), address(engine), TICK_SIZE, admin))
                )
            )
        );

        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (address(vault), address(engine), address(oracle), admin)
                    )
                )
            )
        );

        vm.startPrank(admin);
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(book));
        vault.grantAuthorized(address(pm));
        book.setPositionManager(address(pm));
        pm.setOrderBook(address(book));

        engine.setMarketConfig(
            MARKET_ID,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                tickSize: TICK_SIZE,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );
        oracle.setMarketOracle(MARKET_ID, bytes32(uint256(1)), 60);
        book.setFeeConfig(-1e14, 5e14);
        vm.stopPrank();

        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);

        // Fund accounts
        _fundAccount(alice, 100_000e6);
        _fundAccount(bob, 100_000e6);
        _fundAccount(charlie, 100_000e6);
    }

    function _fundAccount(address account, uint256 usdcAmount) internal {
        usdc.mint(account, usdcAmount);
        vm.prank(account);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(usdcAmount);
    }

    function test_depositPlaceMatchPosition() public {
        // Alice buys 0.5 BTC @ $60,000
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 0.5e18, 1);

        // Bob sells 0.5 BTC @ $60,000 -> match
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 0.5e18, 1);

        // Check Alice's position: long 0.5 BTC
        IPositionManager.Position memory alicePos = pm.getPosition(alice, MARKET_ID);
        assertEq(alicePos.size, 0.5e18);
        assertEq(alicePos.entryPrice, 60_000e18);
        assertTrue(alicePos.collateral > 0);

        // Check Bob's position: short 0.5 BTC
        IPositionManager.Position memory bobPos = pm.getPosition(bob, MARKET_ID);
        assertEq(bobPos.size, -0.5e18);
        assertEq(bobPos.entryPrice, 60_000e18);
        assertTrue(bobPos.collateral > 0);

        // Both registered as holders
        assertEq(pm.getPositionCount(MARKET_ID), 2);

        // No order margin remaining
        assertEq(vault.orderMargin(alice), 0);
        assertEq(vault.orderMargin(bob), 0);
    }

    function test_multipleFills_correctEntryPrice() public {
        // Bob places asks at two levels
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 0.5e18, 1);
        vm.prank(bob);
        book.placeOrder(bob, false, 60_100e18, 0.5e18, 1);

        // Alice buys 0.8 BTC @ $60,100 -> walks through both levels
        vm.prank(alice);
        book.placeOrder(alice, true, 60_100e18, 0.8e18, 1);

        // Alice filled: 0.5 @ $60,000 + 0.3 @ $60,100
        // Weighted avg: (60000*0.5 + 60100*0.3) / 0.8 = (30000+18030)/0.8 = 48030/0.8 = 60037.5
        IPositionManager.Position memory alicePos = pm.getPosition(alice, MARKET_ID);
        assertEq(alicePos.size, 0.8e18);
        assertApproxEqAbs(alicePos.entryPrice, 60_037.5e18, 1e15);
    }

    function test_increasePosition_thenClose() public {
        // Alice opens 0.5 BTC long @ $60,000
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 0.5e18, 1);
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 0.5e18, 1);

        // Alice increases to 1.0 BTC long @ $61,000
        vm.prank(alice);
        book.placeOrder(alice, true, 61_000e18, 0.5e18, 1);
        vm.prank(charlie);
        book.placeOrder(charlie, false, 61_000e18, 0.5e18, 1);

        IPositionManager.Position memory alicePos = pm.getPosition(alice, MARKET_ID);
        assertEq(alicePos.size, 1e18);
        // Weighted avg: (60000*0.5 + 61000*0.5) / 1.0 = 60500
        assertApproxEqAbs(alicePos.entryPrice, 60_500e18, 1e15);

        // Alice closes full position at $62,000
        vm.prank(bob);
        book.placeOrder(bob, true, 62_000e18, 1e18, 1);
        vm.prank(alice);
        book.placeOrder(alice, false, 62_000e18, 1e18, 1);

        IPositionManager.Position memory closedPos = pm.getPosition(alice, MARKET_ID);
        assertEq(closedPos.size, 0);
        assertEq(pm.getPositionCount(MARKET_ID), 2); // bob + charlie still have positions
    }

    function test_noOrderMarginLeaks() public {
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        // All order margin converted to position margin, none left in limbo
        assertEq(vault.orderMargin(alice), 0);
        assertEq(vault.orderMargin(bob), 0);

        // Position margin is locked
        assertTrue(vault.lockedMargin(alice) > 0);
        assertTrue(vault.lockedMargin(bob) > 0);
    }
}
```

- [ ] **Step 5.2: Run integration tests**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract PositionLifecycleTest -vvv
```

Expected: all PASS.

- [ ] **Step 5.3: Commit**

```bash
git add contracts/test/integration/PositionLifecycle.t.sol
git commit -m "test(contracts): add position lifecycle integration test (deposit -> place -> match -> position)"
```

---

## Task 6: ILiquidationEngine Interface

**Files:**
- Create: `contracts/src/interfaces/ILiquidationEngine.sol`

- [ ] **Step 6.1: Create ILiquidationEngine interface**

`contracts/src/interfaces/ILiquidationEngine.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILiquidationEngine {
    struct LiquidationConfig {
        uint256 liquidatorFeeRate;
        uint256 insuranceFundFeeRate;
    }

    function isLiquidatable(address account, uint256 marketId) external view returns (bool);
    function liquidate(address account, uint256 marketId) external;
    function autoDeleverage(uint256 marketId, address bankruptAccount) external;

    event PositionLiquidated(
        address indexed account,
        uint256 indexed marketId,
        address indexed liquidator,
        int256 sizeReduced,
        uint256 liquidationPrice,
        uint256 liquidatorFee,
        uint256 insuranceFee,
        bool isFullLiquidation
    );
    event AutoDeleveraged(
        address indexed bankruptAccount,
        address indexed counterparty,
        uint256 indexed marketId,
        int256 sizeReduced,
        uint256 price
    );
}
```

- [ ] **Step 6.2: Commit**

```bash
git add contracts/src/interfaces/ILiquidationEngine.sol
git commit -m "feat(contracts): add ILiquidationEngine interface"
```

---

## Task 7: LiquidationEngine — Unit Tests (TDD)

**Files:**
- Create: `contracts/test/unit/LiquidationEngine.t.sol`

- [ ] **Step 7.1: Write unit tests**

`contracts/test/unit/LiquidationEngine.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { LiquidationEngine } from "../../src/LiquidationEngine.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { Vault } from "../../src/Vault.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { OrderBook } from "../../src/OrderBook.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";
import { ILiquidationEngine } from "../../src/interfaces/ILiquidationEngine.sol";

contract LiquidationEngineTest is Test {
    LiquidationEngine public le;
    PositionManager public pm;
    Vault public vault;
    MarginEngine public engine;
    OracleAdapter public oracle;
    OrderBook public book;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public keeper = makeAddr("keeper");

    uint256 constant MARKET_ID = 0;
    uint256 constant TICK_SIZE = 0.1e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );

        oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );

        engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );

        book = OrderBook(
            address(
                new ERC1967Proxy(
                    address(new OrderBook()),
                    abi.encodeCall(OrderBook.initialize, (MARKET_ID, address(vault), address(engine), TICK_SIZE, admin))
                )
            )
        );

        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (address(vault), address(engine), address(oracle), admin)
                    )
                )
            )
        );

        le = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(new LiquidationEngine()),
                    abi.encodeCall(
                        LiquidationEngine.initialize,
                        (address(vault), address(pm), address(engine), address(oracle), admin)
                    )
                )
            )
        );

        vm.startPrank(admin);
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(book));
        vault.grantAuthorized(address(pm));
        vault.grantAuthorized(address(le));
        book.setPositionManager(address(pm));
        pm.setOrderBook(address(book));
        pm.setLiquidationEngine(address(le));

        engine.setMarketConfig(
            MARKET_ID,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16, // 2%
                maintenanceMarginRate: 12e15, // 1.2%
                tickSize: TICK_SIZE,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );
        oracle.setMarketOracle(MARKET_ID, bytes32(uint256(1)), 60);
        book.setFeeConfig(0, 0); // No trading fees for clarity in liq tests

        le.setLiquidationConfig(
            MARKET_ID,
            ILiquidationEngine.LiquidationConfig({
                liquidatorFeeRate: 5e15, // 0.5%
                insuranceFundFeeRate: 5e15 // 0.5%
            })
        );
        vm.stopPrank();

        // BTC @ $60,000
        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);
    }

    function _openLongPosition(address account, uint256 usdcAmount, uint256 size, uint256 price) internal {
        usdc.mint(account, usdcAmount);
        vm.prank(account);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(usdcAmount);

        // Directly call PositionManager as orderBook for test setup
        // First lock order margin
        vm.prank(address(book));
        vault.lockOrderMargin(account, engine.getRequiredMargin(MARKET_ID, size, price));

        vm.prank(address(book));
        pm.updatePosition(
            account, MARKET_ID, int256(size), price, engine.getRequiredMargin(MARKET_ID, size, price)
        );
    }

    function _openShortPosition(address account, uint256 usdcAmount, uint256 size, uint256 price) internal {
        usdc.mint(account, usdcAmount);
        vm.prank(account);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(usdcAmount);

        vm.prank(address(book));
        vault.lockOrderMargin(account, engine.getRequiredMargin(MARKET_ID, size, price));

        vm.prank(address(book));
        pm.updatePosition(
            account, MARKET_ID, -int256(size), price, engine.getRequiredMargin(MARKET_ID, size, price)
        );
    }

    // ─── isLiquidatable ───

    function test_notLiquidatable_healthyPosition() public {
        _openLongPosition(alice, 10_000e6, 1e18, 60_000e18);
        assertFalse(le.isLiquidatable(alice, MARKET_ID));
    }

    function test_isLiquidatable_atMMRBoundary() public {
        // Long 1 BTC @ $60,000, collateral = 2% * 60000 = $1200
        _openLongPosition(alice, 10_000e6, 1e18, 60_000e18);

        // Drop price so margin ratio < MMR (1.2%)
        // Equity = collateral + unrealizedPnl = 1200 + (markPrice - 60000) * 1
        // MarginRatio = equity / (markPrice * 1)
        // At MMR boundary: 1200 + (p - 60000) = 0.012 * p
        // 1200 + p - 60000 = 0.012p => 0.988p = 58800 => p = 59514.17
        // Price just below that triggers liquidation
        mockPyth.setPrice(bytes32(uint256(1)), 5_950_000_000_000, 59_500_000, -8); // ~$59,500

        assertTrue(le.isLiquidatable(alice, MARKET_ID));
    }

    function test_notLiquidatable_noPosition() public view {
        assertFalse(le.isLiquidatable(alice, MARKET_ID));
    }

    // ─── Partial Liquidation ───

    function test_partialLiquidation() public {
        _openLongPosition(alice, 10_000e6, 1e18, 60_000e18);

        // Drop price to trigger liquidation but not full wipeout
        mockPyth.setPrice(bytes32(uint256(1)), 5_950_000_000_000, 59_500_000, -8);

        assertTrue(le.isLiquidatable(alice, MARKET_ID));

        IPositionManager.Position memory posBefore = pm.getPosition(alice, MARKET_ID);
        uint256 keeperBalanceBefore = vault.balances(keeper);

        vm.prank(keeper);
        le.liquidate(alice, MARKET_ID);

        IPositionManager.Position memory posAfter = pm.getPosition(alice, MARKET_ID);

        // Position partially reduced
        assertTrue(posAfter.size > 0, "should still have position");
        assertTrue(posAfter.size < posBefore.size, "position should be smaller");

        // Keeper received fee
        assertTrue(vault.balances(keeper) > keeperBalanceBefore, "keeper should receive fee");
    }

    // ─── Full Liquidation ───

    function test_fullLiquidation_equityNearZero() public {
        _openLongPosition(alice, 2_000e6, 1e18, 60_000e18);
        // Collateral = 1200. Price needs to drop enough for equity <= 0
        // equity = 1200 + (p - 60000). equity=0 when p = 58800
        mockPyth.setPrice(bytes32(uint256(1)), 5_870_000_000_000, 58_700_000, -8); // ~$58,700

        vm.prank(keeper);
        le.liquidate(alice, MARKET_ID);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0);
        assertEq(pm.getPositionCount(MARKET_ID), 0);
    }

    // ─── Insurance Fund ───

    function test_insuranceFundReceivesFee() public {
        _openLongPosition(alice, 10_000e6, 1e18, 60_000e18);

        uint256 insuranceBefore = vault.insuranceFund();

        mockPyth.setPrice(bytes32(uint256(1)), 5_950_000_000_000, 59_500_000, -8);

        vm.prank(keeper);
        le.liquidate(alice, MARKET_ID);

        assertTrue(vault.insuranceFund() > insuranceBefore, "insurance fund should increase");
    }

    function test_insuranceFundDeficit() public {
        // Alice has minimal collateral, big position
        _openLongPosition(alice, 2_000e6, 1e18, 60_000e18);

        // Massive price drop -> negative equity -> insurance fund covers deficit
        // Seed insurance fund first
        vm.prank(admin);
        vault.grantAuthorized(admin);
        vm.prank(admin);
        vault.transferToInsuranceFund(5_000e18);

        mockPyth.setPrice(bytes32(uint256(1)), 5_850_000_000_000, 58_500_000, -8); // ~$58,500

        vm.prank(keeper);
        le.liquidate(alice, MARKET_ID);

        // Position should be fully closed
        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0);
    }

    // ─── Revert Cases ───

    function test_liquidate_revertsIfNotLiquidatable() public {
        _openLongPosition(alice, 10_000e6, 1e18, 60_000e18);

        vm.prank(keeper);
        vm.expectRevert();
        le.liquidate(alice, MARKET_ID);
    }

    function test_liquidate_revertsIfNoPosition() public {
        vm.prank(keeper);
        vm.expectRevert();
        le.liquidate(alice, MARKET_ID);
    }

    // ─── ADL ───

    function test_adl_forceCloseMostProfitable() public {
        // Alice is long, Bob is short (the counterparty for ADL)
        _openLongPosition(alice, 2_000e6, 1e18, 60_000e18);
        _openShortPosition(bob, 10_000e6, 1e18, 60_000e18);

        // Price drops massively -> Alice bankrupt, insurance fund empty
        mockPyth.setPrice(bytes32(uint256(1)), 5_800_000_000_000, 58_000_000, -8); // ~$58,000

        // Bob is short and in profit (price dropped). He's the ADL target.
        vm.prank(keeper);
        le.autoDeleverage(MARKET_ID, alice);

        // Alice's position closed
        IPositionManager.Position memory alicePos = pm.getPosition(alice, MARKET_ID);
        assertEq(alicePos.size, 0);

        // Bob's position reduced (or closed)
        IPositionManager.Position memory bobPos = pm.getPosition(bob, MARKET_ID);
        assertTrue(bobPos.size == 0 || FixedPointMath.abs(bobPos.size) < 1e18);
    }

    // ─── Events ───

    function test_emitsPositionLiquidated() public {
        _openLongPosition(alice, 10_000e6, 1e18, 60_000e18);
        mockPyth.setPrice(bytes32(uint256(1)), 5_950_000_000_000, 59_500_000, -8);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, false);
        emit ILiquidationEngine.PositionLiquidated(alice, MARKET_ID, keeper, 0, 0, 0, 0, false);
        le.liquidate(alice, MARKET_ID);
    }
}
```

- [ ] **Step 7.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract LiquidationEngineTest -vvv
```

Expected: compilation error, `LiquidationEngine.sol` not found.

- [ ] **Step 7.3: Commit test file**

```bash
git add contracts/test/unit/LiquidationEngine.t.sol
git commit -m "test(contracts): add LiquidationEngine unit tests (TDD — red phase)"
```

---

## Task 8: LiquidationEngine Implementation

**Files:**
- Create: `contracts/src/LiquidationEngine.sol`

- [ ] **Step 8.1: Implement LiquidationEngine**

`contracts/src/LiquidationEngine.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ILiquidationEngine } from "./interfaces/ILiquidationEngine.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IMarginEngine } from "./interfaces/IMarginEngine.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { FixedPointMath } from "./libraries/FixedPointMath.sol";

contract LiquidationEngine is ILiquidationEngine, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    error NotLiquidatable();
    error NoPosition();
    error NotBankrupt();
    error NoCounterparties();

    IVault public vault;
    IPositionManager public positionManager;
    IMarginEngine public marginEngine;
    IOracleAdapter public oracle;

    mapping(uint256 => LiquidationConfig) public liquidationConfigs;

    uint256[50] private __gap;

    function initialize(
        address _vault,
        address _positionManager,
        address _marginEngine,
        address _oracle,
        address _admin
    ) external initializer {
        __AccessControl_init();
        vault = IVault(_vault);
        positionManager = IPositionManager(_positionManager);
        marginEngine = IMarginEngine(_marginEngine);
        oracle = IOracleAdapter(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setLiquidationConfig(uint256 marketId, LiquidationConfig calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        liquidationConfigs[marketId] = config;
    }

    function isLiquidatable(address account, uint256 marketId) public view returns (bool) {
        IPositionManager.Position memory pos = positionManager.getPosition(account, marketId);
        if (pos.size == 0) return false;

        uint256 marginRatio = positionManager.getMarginRatio(account, marketId);
        (,, uint256 mmr,,,,) = marginEngine.configs(marketId);

        return marginRatio < mmr;
    }

    function liquidate(address account, uint256 marketId) external nonReentrant {
        IPositionManager.Position memory pos = positionManager.getPosition(account, marketId);
        if (pos.size == 0) revert NoPosition();

        // Stub: settleFunding would go here in Phase 3

        if (!isLiquidatable(account, marketId)) revert NotLiquidatable();

        uint256 markPrice = oracle.getMarkPrice(marketId);
        uint256 absSize = FixedPointMath.abs(pos.size);
        uint256 notional = FixedPointMath.mulFp(absSize, markPrice);

        LiquidationConfig memory config = liquidationConfigs[marketId];
        uint256 totalFeeRate = config.liquidatorFeeRate + config.insuranceFundFeeRate;

        IMarginEngine.MarketConfig memory mktCfg = marginEngine.getConfig(marketId);

        // Calculate equity
        int256 unrealizedPnl = positionManager.getUnrealizedPnl(account, marketId);
        int256 equity = int256(pos.collateral) + unrealizedPnl;

        bool isFullLiquidation;
        uint256 reduceSize;

        if (equity <= 0 || absSize <= mktCfg.minOrderSize) {
            // Full liquidation: equity depleted or position too small to partially liquidate
            isFullLiquidation = true;
            reduceSize = absSize;
        } else {
            // Partial liquidation: solve for reduceSize where post-fee marginRatio = IMR
            // reduceSize = (IMR * notional - equity) / (markPrice * (IMR + feeRate - 1))
            uint256 imrTimesNotional = FixedPointMath.mulFp(mktCfg.initialMarginRate, notional);

            // Numerator: imrTimesNotional - equity (equity is positive here)
            int256 numerator = int256(imrTimesNotional) - equity;
            if (numerator <= 0) {
                // Position is actually healthy enough — shouldn't happen after isLiquidatable check
                // but guard against rounding
                revert NotLiquidatable();
            }

            // Denominator: markPrice * (IMR + feeRate - 1e18)
            // Note: IMR + feeRate < 1e18 always (e.g. 0.02 + 0.01 = 0.03), so (IMR + feeRate - 1e18) is negative
            // This makes the denominator negative, which is wrong.
            // Correct formula derivation:
            //   target: (equity - fee) / (notional - reduceSize * markPrice) = IMR
            //   equity - reduceSize * markPrice * feeRate = IMR * (notional - reduceSize * markPrice)
            //   equity - reduceSize * markPrice * feeRate = IMR * notional - IMR * reduceSize * markPrice
            //   reduceSize * markPrice * (IMR - feeRate) = IMR * notional - equity
            //   reduceSize = (IMR * notional - equity) / (markPrice * (IMR - feeRate))
            // Wait, that's also potentially negative since IMR (0.02) < feeRate (0.01) gives positive.
            // Let me re-derive carefully:
            //   equity_after = equity - fee = equity - reduceSize * markPrice * feeRate
            //   notional_after = (absSize - reduceSize) * markPrice
            //   equity_after / notional_after = IMR
            //   (equity - reduceSize * markPrice * feeRate) = IMR * (absSize - reduceSize) * markPrice
            //   equity - reduceSize * markPrice * feeRate = IMR * absSize * markPrice - IMR * reduceSize * markPrice
            //   equity - IMR * notional = reduceSize * markPrice * feeRate - IMR * reduceSize * markPrice
            //   equity - IMR * notional = reduceSize * markPrice * (feeRate - IMR)
            //   reduceSize = (equity - IMR * notional) / (markPrice * (feeRate - IMR))
            // But equity < IMR * notional (that's why we're liquidating), so numerator is negative.
            // And feeRate (0.01) < IMR (0.02), so denominator is negative too. Negative/negative = positive.
            // Use the spec formula: reduceSize = (IMR * notional - equity) / (markPrice * (IMR + feeRate - 1e18))
            // IMR + feeRate = 0.02 + 0.01 = 0.03, minus 1 = -0.97. markPrice * (-0.97) is negative.
            // (positive) / (negative) = negative. That's wrong too.
            //
            // The spec formula assumes 1e18-normalized: IMR + feeRate - 1e18
            // But the derivation above gives: (IMR * notional - equity) / (markPrice * (IMR - feeRate))
            // Let's use the correct derivation:

            // denominator = markPrice * (IMR - feeRate)
            // When IMR > feeRate: denominator > 0, numerator > 0 (since position is undercollateralized)
            // When IMR <= feeRate: full liquidation (fees eat all margin)

            if (mktCfg.initialMarginRate <= totalFeeRate) {
                isFullLiquidation = true;
                reduceSize = absSize;
            } else {
                uint256 denom = FixedPointMath.mulFp(markPrice, mktCfg.initialMarginRate - totalFeeRate);
                reduceSize = FixedPointMath.divFp(uint256(numerator), denom);

                // Clamp and check
                if (reduceSize >= absSize || (absSize - reduceSize) < mktCfg.minOrderSize) {
                    isFullLiquidation = true;
                    reduceSize = absSize;
                }
            }
        }

        // Calculate fees
        uint256 liqNotional = FixedPointMath.mulFp(reduceSize, markPrice);
        uint256 liquidatorFee = FixedPointMath.mulFp(liqNotional, config.liquidatorFeeRate);
        uint256 insuranceFee = FixedPointMath.mulFp(liqNotional, config.insuranceFundFeeRate);
        uint256 totalFee = liquidatorFee + insuranceFee;

        // Execute liquidation via PositionManager
        int256 sizeDelta = pos.size > 0 ? -int256(reduceSize) : int256(reduceSize);
        positionManager.liquidatePosition(account, marketId, sizeDelta, markPrice);

        // Distribute fees from the account's released balance
        // After liquidation, PnL is realized and collateral is unlocked back to balance
        // We need to take fees from the account's balance
        if (vault.balances(account) >= totalFee) {
            vault.realizePnl(account, -int256(totalFee));
        } else {
            // Account can't cover full fees — take what's available
            uint256 available = vault.balances(account);
            if (available > 0) {
                vault.realizePnl(account, -int256(available));
            }
            totalFee = available;
            // Redistribute proportionally
            if (totalFee > 0) {
                liquidatorFee = (totalFee * config.liquidatorFeeRate) / (config.liquidatorFeeRate + config.insuranceFundFeeRate);
                insuranceFee = totalFee - liquidatorFee;
            } else {
                liquidatorFee = 0;
                insuranceFee = 0;
            }
        }

        // Pay keeper
        if (liquidatorFee > 0) {
            vault.realizePnl(msg.sender, int256(liquidatorFee));
        }

        // Pay insurance fund
        if (insuranceFee > 0) {
            vault.transferToInsuranceFund(insuranceFee);
        }

        // Handle deficit: if account balance is negative after full liquidation
        if (isFullLiquidation) {
            // Check if there's a socialized deficit
            // After full close + fee deduction, if account had negative equity,
            // the deficit is absorbed by insurance fund
            int256 remainingEquity = int256(vault.balances(account)) + int256(vault.lockedMargin(account));
            if (remainingEquity < 0) {
                uint256 deficit = uint256(-remainingEquity);
                uint256 fundBalance = vault.insuranceFund();
                if (fundBalance >= deficit) {
                    vault.drawFromInsuranceFund(deficit);
                    vault.realizePnl(account, int256(deficit));
                }
                // If insurance fund insufficient, position is flagged for ADL (handled externally)
            }
        }

        emit PositionLiquidated(
            account, marketId, msg.sender, sizeDelta, markPrice, liquidatorFee, insuranceFee, isFullLiquidation
        );
    }

    function autoDeleverage(uint256 marketId, address bankruptAccount) external nonReentrant {
        IPositionManager.Position memory bankruptPos = positionManager.getPosition(bankruptAccount, marketId);
        if (bankruptPos.size == 0) revert NoPosition();

        // Verify the account is actually bankrupt (negative equity)
        int256 unrealizedPnl = positionManager.getUnrealizedPnl(bankruptAccount, marketId);
        int256 equity = int256(bankruptPos.collateral) + unrealizedPnl;
        if (equity > 0) revert NotBankrupt();

        uint256 markPrice = oracle.getMarkPrice(marketId);
        uint256 absSize = FixedPointMath.abs(bankruptPos.size);

        // Get opposite-side positions and rank by unrealized PnL (most profitable first)
        address[] memory holders = positionManager.getPositionHolders(marketId);
        if (holders.length == 0) revert NoCounterparties();

        // Find the most profitable opposite-side position
        address bestTarget;
        int256 bestPnl = type(int256).min;

        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == bankruptAccount) continue;

            IPositionManager.Position memory pos = positionManager.getPosition(holders[i], marketId);
            // Opposite side: if bankrupt is long, find shorts; if bankrupt is short, find longs
            bool isOpposite = (bankruptPos.size > 0 && pos.size < 0) || (bankruptPos.size < 0 && pos.size > 0);
            if (!isOpposite) continue;

            int256 pnl = positionManager.getUnrealizedPnl(holders[i], marketId);
            if (pnl > bestPnl) {
                bestPnl = pnl;
                bestTarget = holders[i];
            }
        }

        if (bestTarget == address(0)) revert NoCounterparties();

        IPositionManager.Position memory targetPos = positionManager.getPosition(bestTarget, marketId);
        uint256 targetAbsSize = FixedPointMath.abs(targetPos.size);

        // ADL size: min of bankrupt size and target size
        uint256 adlSize = FixedPointMath.min(absSize, targetAbsSize);

        // Force-close both at mark price
        // Close bankrupt position
        int256 bankruptDelta = bankruptPos.size > 0 ? -int256(adlSize) : int256(adlSize);
        positionManager.liquidatePosition(bankruptAccount, marketId, bankruptDelta, markPrice);

        // Close counterparty position
        int256 targetDelta = targetPos.size > 0 ? -int256(adlSize) : int256(adlSize);
        positionManager.liquidatePosition(bestTarget, marketId, targetDelta, markPrice);

        // Cover the bankrupt account's deficit from insurance fund if possible
        uint256 fundBalance = vault.insuranceFund();
        int256 bankruptBalance = int256(vault.balances(bankruptAccount));
        if (bankruptBalance < 0) {
            uint256 deficit = uint256(-bankruptBalance);
            if (fundBalance >= deficit) {
                vault.drawFromInsuranceFund(deficit);
                vault.realizePnl(bankruptAccount, int256(deficit));
            }
        }

        emit AutoDeleveraged(bankruptAccount, bestTarget, marketId, bankruptDelta, markPrice);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
```

- [ ] **Step 8.2: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract LiquidationEngineTest -vvv
```

Expected: all tests PASS.

- [ ] **Step 8.3: Commit**

```bash
git add contracts/src/LiquidationEngine.sol
git commit -m "feat(contracts): add LiquidationEngine with partial/full liquidation, insurance fund, ADL"
```

---

## Task 9: Liquidation Integration Test

**Files:**
- Create: `contracts/test/integration/LiquidationFlow.t.sol`

- [ ] **Step 9.1: Write integration test**

`contracts/test/integration/LiquidationFlow.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { OrderBook } from "../../src/OrderBook.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { LiquidationEngine } from "../../src/LiquidationEngine.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";
import { ILiquidationEngine } from "../../src/interfaces/ILiquidationEngine.sol";
import { FixedPointMath } from "../../src/libraries/FixedPointMath.sol";

contract LiquidationFlowTest is Test {
    Vault public vault;
    OrderBook public book;
    MarginEngine public engine;
    OracleAdapter public oracle;
    PositionManager public pm;
    LiquidationEngine public le;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public keeper = makeAddr("keeper");

    uint256 constant MARKET_ID = 0;
    uint256 constant TICK_SIZE = 0.1e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );
        oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );
        engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );
        book = OrderBook(
            address(
                new ERC1967Proxy(
                    address(new OrderBook()),
                    abi.encodeCall(OrderBook.initialize, (MARKET_ID, address(vault), address(engine), TICK_SIZE, admin))
                )
            )
        );
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (address(vault), address(engine), address(oracle), admin)
                    )
                )
            )
        );
        le = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(new LiquidationEngine()),
                    abi.encodeCall(
                        LiquidationEngine.initialize,
                        (address(vault), address(pm), address(engine), address(oracle), admin)
                    )
                )
            )
        );

        vm.startPrank(admin);
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(book));
        vault.grantAuthorized(address(pm));
        vault.grantAuthorized(address(le));
        book.setPositionManager(address(pm));
        pm.setOrderBook(address(book));
        pm.setLiquidationEngine(address(le));

        engine.setMarketConfig(
            MARKET_ID,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 12e15,
                tickSize: TICK_SIZE,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );
        oracle.setMarketOracle(MARKET_ID, bytes32(uint256(1)), 60);
        book.setFeeConfig(0, 0);
        le.setLiquidationConfig(
            MARKET_ID,
            ILiquidationEngine.LiquidationConfig({ liquidatorFeeRate: 5e15, insuranceFundFeeRate: 5e15 })
        );
        vm.stopPrank();

        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);

        _fundAccount(alice, 10_000e6);
        _fundAccount(bob, 10_000e6);
    }

    function _fundAccount(address account, uint256 usdcAmount) internal {
        usdc.mint(account, usdcAmount);
        vm.prank(account);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(usdcAmount);
    }

    function test_fullFlow_openTradeLiquidate() public {
        // 1. Alice buys 1 BTC @ $60,000
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        // Verify positions opened
        IPositionManager.Position memory alicePos = pm.getPosition(alice, MARKET_ID);
        assertEq(alicePos.size, 1e18);

        // 2. Price drops -> Alice undercollateralized
        assertFalse(le.isLiquidatable(alice, MARKET_ID));

        mockPyth.setPrice(bytes32(uint256(1)), 5_950_000_000_000, 59_500_000, -8);
        assertTrue(le.isLiquidatable(alice, MARKET_ID));

        // Bob (short) should not be liquidatable (in profit)
        assertFalse(le.isLiquidatable(bob, MARKET_ID));

        // 3. Keeper liquidates Alice
        uint256 keeperBalBefore = vault.balances(keeper);
        vm.prank(keeper);
        le.liquidate(alice, MARKET_ID);

        // Keeper earned fee
        assertTrue(vault.balances(keeper) > keeperBalBefore);

        // Alice's position reduced or closed
        IPositionManager.Position memory alicePostLiq = pm.getPosition(alice, MARKET_ID);
        assertTrue(
            alicePostLiq.size == 0 || FixedPointMath.abs(alicePostLiq.size) < FixedPointMath.abs(alicePos.size)
        );
    }

    function test_adlFlow() public {
        // Minimal capital for Alice — will go bankrupt quickly
        // Alice: 1 BTC long @ $60,000 with only $1200 margin (2%)
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        // Massive drop
        mockPyth.setPrice(bytes32(uint256(1)), 5_850_000_000_000, 58_500_000, -8);

        // Alice is liquidatable (equity ~ 1200 + (58500 - 60000) = 1200 - 1500 = -300)
        // Full liquidation, deficit
        vm.prank(keeper);
        le.liquidate(alice, MARKET_ID);

        // If insurance fund can't cover, ADL against Bob
        IPositionManager.Position memory alicePos = pm.getPosition(alice, MARKET_ID);
        if (alicePos.size != 0) {
            // Still has position -> need ADL
            vm.prank(keeper);
            le.autoDeleverage(MARKET_ID, alice);

            alicePos = pm.getPosition(alice, MARKET_ID);
            assertEq(alicePos.size, 0);
        }
    }
}
```

- [ ] **Step 9.2: Run integration tests**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract LiquidationFlowTest -vvv
```

Expected: all PASS.

- [ ] **Step 9.3: Commit**

```bash
git add contracts/test/integration/LiquidationFlow.t.sol
git commit -m "test(contracts): add liquidation flow integration test (open -> price drop -> liquidate -> ADL)"
```

---

## Task 10: Update Rust Event Types

**Files:**
- Modify: `crates/gaekju-types/src/events.rs`

- [ ] **Step 10.1: Add position and liquidation events**

Add the following to `crates/gaekju-types/src/events.rs`, inside the `sol!` block:

```rust
    event PositionUpdated(
        address indexed account,
        uint256 indexed marketId,
        int256 newSize,
        uint256 entryPrice,
        uint256 collateral,
        int256 realizedPnl
    );

    event PositionClosed(
        address indexed account,
        uint256 indexed marketId,
        int256 realizedPnl
    );

    event PositionLiquidated(
        address indexed account,
        uint256 indexed marketId,
        address indexed liquidator,
        int256 sizeReduced,
        uint256 liquidationPrice,
        uint256 liquidatorFee,
        uint256 insuranceFee,
        bool isFullLiquidation
    );

    event AutoDeleveraged(
        address indexed bankruptAccount,
        address indexed counterparty,
        uint256 indexed marketId,
        int256 sizeReduced,
        uint256 price
    );
```

Add to the `GaekjuEvent` enum:

```rust
    PositionUpdated {
        account: Address,
        market_id: U256,
        new_size: I256,
        entry_price: U256,
        collateral: U256,
        realized_pnl: I256,
    },
    PositionClosed {
        account: Address,
        market_id: U256,
        realized_pnl: I256,
    },
    PositionLiquidated {
        account: Address,
        market_id: U256,
        liquidator: Address,
        size_reduced: I256,
        liquidation_price: U256,
        liquidator_fee: U256,
        insurance_fee: U256,
        is_full_liquidation: bool,
    },
    AutoDeleveraged {
        bankrupt_account: Address,
        counterparty: Address,
        market_id: U256,
        size_reduced: I256,
        price: U256,
    },
```

The complete updated file:

`crates/gaekju-types/src/events.rs`:
```rust
use alloy_primitives::{Address, I256, U256};
use alloy_sol_types::sol;
use serde::{Deserialize, Serialize};

sol! {
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint256 indexed marketId,
        bool side,
        uint256 price,
        uint256 size,
        uint8 orderType
    );

    event OrderMatched(
        uint256 indexed marketId,
        uint256 makerOrderId,
        uint256 takerOrderId,
        uint256 price,
        uint256 size
    );

    event OrderCancelled(uint256 indexed orderId, address indexed trader);

    event Fill(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 price,
        uint256 size,
        bool takerSide
    );

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event MarginLocked(address indexed account, uint256 amount);
    event MarginUnlocked(address indexed account, uint256 amount);
    event PnlRealized(address indexed account, int256 amount);

    event PositionUpdated(
        address indexed account,
        uint256 indexed marketId,
        int256 newSize,
        uint256 entryPrice,
        uint256 collateral,
        int256 realizedPnl
    );

    event PositionClosed(
        address indexed account,
        uint256 indexed marketId,
        int256 realizedPnl
    );

    event PositionLiquidated(
        address indexed account,
        uint256 indexed marketId,
        address indexed liquidator,
        int256 sizeReduced,
        uint256 liquidationPrice,
        uint256 liquidatorFee,
        uint256 insuranceFee,
        bool isFullLiquidation
    );

    event AutoDeleveraged(
        address indexed bankruptAccount,
        address indexed counterparty,
        uint256 indexed marketId,
        int256 sizeReduced,
        uint256 price
    );
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GaekjuEvent {
    OrderPlaced {
        order_id: U256,
        trader: Address,
        market_id: U256,
        side: bool,
        price: U256,
        size: U256,
        order_type: u8,
    },
    OrderMatched {
        market_id: U256,
        maker_order_id: U256,
        taker_order_id: U256,
        price: U256,
        size: U256,
    },
    OrderCancelled {
        order_id: U256,
        trader: Address,
    },
    Fill {
        market_id: U256,
        maker: Address,
        taker: Address,
        price: U256,
        size: U256,
        taker_side: bool,
    },
    Deposited {
        account: Address,
        amount: U256,
    },
    Withdrawn {
        account: Address,
        amount: U256,
    },
    PositionUpdated {
        account: Address,
        market_id: U256,
        new_size: I256,
        entry_price: U256,
        collateral: U256,
        realized_pnl: I256,
    },
    PositionClosed {
        account: Address,
        market_id: U256,
        realized_pnl: I256,
    },
    PositionLiquidated {
        account: Address,
        market_id: U256,
        liquidator: Address,
        size_reduced: I256,
        liquidation_price: U256,
        liquidator_fee: U256,
        insurance_fee: U256,
        is_full_liquidation: bool,
    },
    AutoDeleveraged {
        bankrupt_account: Address,
        counterparty: Address,
        market_id: U256,
        size_reduced: I256,
        price: U256,
    },
}
```

- [ ] **Step 10.2: Verify Rust compiles**

```bash
cd /Users/sskys/Mine/gaekju && cargo check -p gaekju-types
```

Expected: success.

- [ ] **Step 10.3: Commit**

```bash
git add crates/gaekju-types/src/events.rs
git commit -m "feat(types): add position, liquidation, and ADL event types"
```

---

## Task 11: Liquidation Keeper — Rust Implementation

**Files:**
- Modify: `crates/gaekju-keeper/Cargo.toml`
- Create: `crates/gaekju-keeper/src/liquidator.rs`
- Create: `crates/gaekju-keeper/src/tx.rs`
- Modify: `crates/gaekju-keeper/src/main.rs`

- [ ] **Step 11.1: Update Cargo.toml with dependencies**

`crates/gaekju-keeper/Cargo.toml`:
```toml
[package]
name = "gaekju-keeper"
version = "0.1.0"
edition = "2021"

[dependencies]
gaekju-types = { path = "../gaekju-types" }
alloy = { workspace = true }
alloy-primitives = { workspace = true }
alloy-sol-types = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
eyre = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }

[dev-dependencies]
```

- [ ] **Step 11.2: Implement tx.rs — transaction submission with nonce management**

`crates/gaekju-keeper/src/tx.rs`:
```rust
use alloy::network::EthereumWallet;
use alloy::primitives::Address;
use alloy::providers::{Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;
use eyre::Result;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub struct TxManager {
    pub provider: Arc<dyn Provider + Send + Sync>,
    pub wallet: EthereumWallet,
    pub sender: Address,
    nonce: AtomicU64,
}

impl TxManager {
    pub async fn new(rpc_url: &str, private_key: &str) -> Result<Self> {
        let signer: PrivateKeySigner = private_key.parse()?;
        let sender = signer.address();
        let wallet = EthereumWallet::from(signer);

        let provider = ProviderBuilder::new()
            .wallet(wallet.clone())
            .on_http(rpc_url.parse()?);

        let nonce = provider.get_transaction_count(sender).await?;

        Ok(Self {
            provider: Arc::new(provider),
            wallet,
            sender,
            nonce: AtomicU64::new(nonce),
        })
    }

    pub fn next_nonce(&self) -> u64 {
        self.nonce.fetch_add(1, Ordering::SeqCst)
    }

    pub async fn sync_nonce(&self) -> Result<()> {
        let nonce = self.provider.get_transaction_count(self.sender).await?;
        self.nonce.store(nonce, Ordering::SeqCst);
        Ok(())
    }
}
```

- [ ] **Step 11.3: Implement liquidator.rs — position monitoring loop**

`crates/gaekju-keeper/src/liquidator.rs`:
```rust
use alloy::primitives::{Address, U256};
use alloy::sol;
use eyre::Result;
use std::sync::Arc;
use std::time::Duration;
use tracing::{error, info, warn};

use crate::tx::TxManager;

sol! {
    #[sol(rpc)]
    interface ILiquidationEngine {
        function isLiquidatable(address account, uint256 marketId) external view returns (bool);
        function liquidate(address account, uint256 marketId) external;
    }

    #[sol(rpc)]
    interface IPositionManager {
        function getPositionHolders(uint256 marketId) external view returns (address[] memory);
        function getPositionCount(uint256 marketId) external view returns (uint256);
    }
}

pub struct Liquidator {
    tx_manager: Arc<TxManager>,
    liquidation_engine: Address,
    position_manager: Address,
    market_ids: Vec<U256>,
    poll_interval: Duration,
}

impl Liquidator {
    pub fn new(
        tx_manager: Arc<TxManager>,
        liquidation_engine: Address,
        position_manager: Address,
        market_ids: Vec<U256>,
        poll_interval: Duration,
    ) -> Self {
        Self {
            tx_manager,
            liquidation_engine,
            position_manager,
            market_ids,
            poll_interval,
        }
    }

    pub async fn run(&self) -> Result<()> {
        info!("liquidation keeper started");
        info!(
            markets = ?self.market_ids,
            engine = ?self.liquidation_engine,
            "monitoring {} markets",
            self.market_ids.len()
        );

        loop {
            if let Err(e) = self.check_and_liquidate().await {
                error!(error = %e, "liquidation check failed");
                // Resync nonce on error
                if let Err(sync_err) = self.tx_manager.sync_nonce().await {
                    error!(error = %sync_err, "nonce resync failed");
                }
            }
            tokio::time::sleep(self.poll_interval).await;
        }
    }

    async fn check_and_liquidate(&self) -> Result<()> {
        let le = ILiquidationEngine::new(self.liquidation_engine, &*self.tx_manager.provider);
        let pm = IPositionManager::new(self.position_manager, &*self.tx_manager.provider);

        for market_id in &self.market_ids {
            let count = pm
                .getPositionCount(*market_id)
                .call()
                .await?
                ._0;

            if count.is_zero() {
                continue;
            }

            let holders = pm
                .getPositionHolders(*market_id)
                .call()
                .await?
                ._0;

            for account in holders {
                let liquidatable = le
                    .isLiquidatable(account, *market_id)
                    .call()
                    .await?
                    ._0;

                if liquidatable {
                    info!(
                        account = ?account,
                        market_id = %market_id,
                        "position liquidatable — submitting tx"
                    );

                    match le.liquidate(account, *market_id).send().await {
                        Ok(pending) => {
                            let receipt = pending.get_receipt().await?;
                            info!(
                                tx_hash = ?receipt.transaction_hash,
                                account = ?account,
                                "liquidation confirmed"
                            );
                        }
                        Err(e) => {
                            warn!(
                                error = %e,
                                account = ?account,
                                "liquidation tx failed"
                            );
                        }
                    }
                }
            }
        }

        Ok(())
    }
}
```

- [ ] **Step 11.4: Update main.rs**

`crates/gaekju-keeper/src/main.rs`:
```rust
mod liquidator;
mod tx;

use alloy::primitives::{Address, U256};
use eyre::Result;
use std::env;
use std::sync::Arc;
use std::time::Duration;
use tracing_subscriber::EnvFilter;

use crate::liquidator::Liquidator;
use crate::tx::TxManager;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("gaekju_keeper=info".parse()?))
        .init();

    let rpc_url = env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:8545".to_string());
    let private_key = env::var("KEEPER_PRIVATE_KEY").expect("KEEPER_PRIVATE_KEY must be set");
    let le_addr: Address = env::var("LIQUIDATION_ENGINE")
        .expect("LIQUIDATION_ENGINE must be set")
        .parse()?;
    let pm_addr: Address = env::var("POSITION_MANAGER")
        .expect("POSITION_MANAGER must be set")
        .parse()?;

    let poll_ms: u64 = env::var("POLL_INTERVAL_MS")
        .unwrap_or_else(|_| "2000".to_string())
        .parse()?;

    let market_ids: Vec<U256> = env::var("MARKET_IDS")
        .unwrap_or_else(|_| "0".to_string())
        .split(',')
        .map(|s| U256::from(s.trim().parse::<u64>().unwrap_or(0)))
        .collect();

    let tx_manager = Arc::new(TxManager::new(&rpc_url, &private_key).await?);

    let liquidator = Liquidator::new(
        tx_manager,
        le_addr,
        pm_addr,
        market_ids,
        Duration::from_millis(poll_ms),
    );

    liquidator.run().await
}
```

- [ ] **Step 11.5: Verify Rust compiles**

```bash
cd /Users/sskys/Mine/gaekju && cargo check -p gaekju-keeper
```

Expected: success (or minor fixups needed — fix until clean).

- [ ] **Step 11.6: Commit**

```bash
git add crates/gaekju-keeper/
git commit -m "feat(keeper): implement liquidation keeper with position monitoring and tx management"
```

---

## Task 12: Blog Posts

**Files:**
- Update: `docs/blog/03-margin-from-scratch.md`
- Update: `docs/blog/04-liquidation-math.md`

- [ ] **Step 12.1: Write Blog #03 — Margin Systems from Scratch**

`docs/blog/03-margin-from-scratch.md`:
```markdown
# Margin Systems from Scratch

> Part 03 of "Building a Perp DEX from Scratch"

---

## Why Margin Matters

Every perpetual futures exchange needs a margin system. Without it, a trader could open a $1M position with $1 and walk away when it goes south. Margin is the collateral that backs a position — the protocol's guarantee that losses can be covered.

In Gaekju, we implemented isolated margin with per-market configuration. This post walks through the math, the code, and the design decisions.

## The Three Margin Types

### Order Margin
When you place an order on the book, capital is reserved immediately. You can't spend it elsewhere or withdraw it. This prevents a common exploit: placing orders with capital you don't actually have.

```
orderMargin = notional * initialMarginRate
            = size * price * IMR
```

### Position Margin (Locked Margin)
Once your order matches and creates a position, order margin converts to position margin. This is the collateral backing your open position.

### Free Balance
Everything not locked. Available for new orders or withdrawal.

```
accountEquity = freeBalance + lockedMargin + orderMargin
```

## Margin Rates

Two rates govern the system:

**Initial Margin Rate (IMR):** The minimum collateral to open a position. For BTC-USD at 50x leverage, IMR = 2%. A $60,000 BTC position requires at least $1,200 in margin.

**Maintenance Margin Rate (MMR):** The minimum to keep a position open. For BTC-USD, MMR = 1.2%. If your margin ratio drops below MMR, you get liquidated.

IMR > MMR always. The gap between them is the buffer zone — your position can lose value without immediate liquidation, but you can't open a new position that's already in the danger zone.

## The Margin Ratio

```
marginRatio = (collateral + unrealizedPnL) / notionalValue
```

Where:
- `collateral`: your locked margin for this position
- `unrealizedPnL`: `(markPrice - entryPrice) * positionSize` (signed)
- `notionalValue`: `abs(positionSize) * markPrice`

When `marginRatio >= IMR`, the position is healthy.
When `marginRatio < MMR`, the position is liquidatable.
When `marginRatio` is between, the position survives but you can't increase it without adding more margin.

## Weighted Average Entry Price

When you increase an existing position, you don't get two separate entries. Instead, the system computes a weighted average:

```
newEntry = (oldEntry * abs(oldSize) + fillPrice * abs(fillSize)) / (abs(oldSize) + abs(fillSize))
```

This is implemented using 18-decimal fixed-point math (`mulFp` / `divFp`) to avoid precision loss. We fuzz-tested this extensively — the result always falls between the two input prices, within 1 wei of rounding.

## Order Margin to Position Margin Conversion

This is where the plumbing gets interesting. When an order fills:

1. OrderBook calls `PositionManager.updatePosition(account, marketId, sizeDelta, fillPrice, marginDelta)`
2. PositionManager calls `vault.unlockOrderMargin(account, marginDelta)` — releases order reservation
3. PositionManager calls `vault.lockMargin(account, marginDelta)` — locks as position collateral
4. Position struct is updated with new size, entry price, and collateral

The key insight: order margin and position margin are different accounting buckets in the Vault. The conversion happens atomically inside a single transaction.

## PnL on Close

Partial close realizes proportional PnL:

```
pnl = (closePrice - entryPrice) * closeSize * sign(positionSize)
```

For a long position closing at profit: `(62000 - 60000) * 0.5 = +$1000`.
For a short position closing at profit: `(58000 - 60000) * (-0.5) = +$1000`.

The collateral released is proportional to the close ratio, not the PnL. If you close 50% of a position, you get back 50% of the collateral plus whatever PnL you realized.

## Position Flips

A flip happens when a trade reverses your direction — selling 1.5 BTC when you're long 1 BTC. The system handles this as two atomic operations:

1. Close the old position (1 BTC long at entry) — realize PnL, unlock all collateral
2. Open a new position (0.5 BTC short at fill price) — lock new margin at IMR

This avoids any gap where the account has no position but has unrealized capital in limbo.

## Implementation Notes

- All math is 18-decimal fixed-point. USDC (6 decimals) is scaled at the Vault boundary.
- `FixedPointMath.mulFpSigned` handles signed multiplication correctly — the sign of PnL depends on position direction.
- The `EnumerableSet` tracks position holders per market for ADL ranking (next post).
- Funding settlement is stubbed as a no-op — Phase 3 fills that in.

---

*Next: [Liquidation: Protecting the Protocol](04-liquidation-math.md)*

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
```

- [ ] **Step 12.2: Write Blog #04 — Liquidation Math**

`docs/blog/04-liquidation-math.md`:
```markdown
# Liquidation: Protecting the Protocol

> Part 04 of "Building a Perp DEX from Scratch"

---

## The Problem Liquidation Solves

Without liquidation, a leveraged trader who loses more than their collateral creates a debt the protocol can't collect. The exchange becomes insolvent. Liquidation is the mechanism that closes undercollateralized positions before they can damage the system.

## When Does Liquidation Trigger?

A position is liquidatable when:

```
marginRatio < maintenanceMarginRate (MMR)
```

For BTC-USD with MMR = 1.2%: if your $60,000 position has less than $720 of effective collateral (collateral + unrealized PnL), you're liquidatable.

Anyone can call `liquidate()` — we incentivize keepers with a fee.

## Partial vs Full Liquidation

### Partial Liquidation

When there's still equity in the position, we don't close everything. Instead, we find the minimum reduction that restores the margin ratio to IMR (the initial margin rate):

```
reduceSize = (IMR * notional - equity) / (markPrice * (IMR - feeRate))
```

After partial liquidation:
- Position is smaller but still open
- Margin ratio is back at IMR
- Fees have been paid to the liquidator and insurance fund

### Full Liquidation

When equity <= 0, or when the remaining position after partial liquidation would be smaller than `minOrderSize`, we close everything.

## Fee Distribution

Each liquidation generates two fees, both proportional to the liquidated notional:

```
liquidatorFee = reduceSize * markPrice * liquidatorFeeRate   (0.5%)
insuranceFee  = reduceSize * markPrice * insuranceFundFeeRate (0.5%)
```

The liquidator (keeper bot) receives their fee as a direct balance credit. The insurance fund fee accrues in the Vault's insurance fund pool.

If the account can't cover the full fees (equity depleted), we take what's available and split proportionally.

## The Insurance Fund

The insurance fund is the protocol's backstop against socialized losses. It accumulates from:
- Liquidation insurance fees (0.5% of each liquidation)
- Any excess collateral from liquidated positions

When a fully liquidated position has negative equity (the loss exceeds the collateral), the insurance fund covers the deficit. This prevents the loss from being passed to counterparties.

## Auto-Deleverage (ADL)

When the insurance fund is depleted and there's still a deficit, we need a last resort: ADL.

ADL force-closes the most profitable position on the opposite side against the bankrupt position. The logic:

1. Get all positions in the market via `PositionRegistry.getPositionHolders()`
2. Filter for opposite-side positions
3. Rank by unrealized PnL (highest first)
4. Force-close the most profitable counterparty at the mark price
5. Both positions closed, deficit absorbed

ADL is undesirable — it takes profits away from successful traders. A well-capitalized insurance fund should make ADL extremely rare. But it must exist as the final safety net.

## The Liquidation Keeper Bot

We built a Rust keeper bot that:
- Polls position holders per market on every new block
- Calls `isLiquidatable()` for each position
- Submits `liquidate()` transactions for positions below MMR
- Manages nonces for rapid sequential transactions
- Resyncs nonce on errors to avoid stuck transactions

The keeper is economically incentivized — the 0.5% liquidator fee covers gas costs and provides profit. On an L2 like Giwa Chain, gas is cheap enough that even small liquidations are profitable.

## Implementation Considerations

### Funding First
Before checking if a position is liquidatable, accumulated funding must be settled. A position might cross the MMR threshold due to funding payments alone. We stub this in Phase 2 (funding is Phase 3) but the settlement hook is already in place.

### Oracle Price for Liquidation
Liquidations execute at the oracle mark price, not at an orderbook price. This prevents manipulation where a liquidator could move the book to trigger liquidation at a favorable price.

### Partial Liquidation Formula Derivation

Starting from the target:
```
(equity - fee) / newNotional = IMR
```

Where:
```
fee = reduceSize * markPrice * feeRate
newNotional = (absSize - reduceSize) * markPrice
```

Expanding:
```
equity - reduceSize * markPrice * feeRate = IMR * (absSize - reduceSize) * markPrice
equity - IMR * absSize * markPrice = reduceSize * markPrice * (feeRate - IMR)
```

Since feeRate < IMR (1% < 2%), the right side is negative, so:
```
reduceSize = (IMR * notional - equity) / (markPrice * (IMR - feeRate))
```

Both numerator and denominator are positive when the position is liquidatable (equity < IMR * notional) and IMR > feeRate.

---

*Next: [How Perp Funding Rates Actually Work](05-funding-rates.md)*

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
```

- [ ] **Step 12.3: Commit**

```bash
git add docs/blog/03-margin-from-scratch.md docs/blog/04-liquidation-math.md
git commit -m "docs: write blog posts #03 (margin systems) and #04 (liquidation math)"
```

---

## Task 13: Full Verification

- [ ] **Step 13.1: Run full Solidity test suite**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test -vvv
```

Expected: ALL tests pass (unit, fuzz, integration — both Phase 1 and Phase 2).

- [ ] **Step 13.2: Run format check**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge fmt --check
cd /Users/sskys/Mine/gaekju && cargo fmt --all -- --check
```

Fix any formatting issues.

- [ ] **Step 13.3: Run Rust checks**

```bash
cd /Users/sskys/Mine/gaekju && cargo clippy --all-targets --all-features -- -D warnings
cd /Users/sskys/Mine/gaekju && cargo test --all
```

Expected: clean clippy, all tests pass.

- [ ] **Step 13.4: Check contract sizes**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge build --sizes
```

Expected: all contracts under 24KB.

- [ ] **Step 13.5: Verify DepositPlaceMatch still passes (backward compat)**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract DepositPlaceMatchTest -vvv
```

Expected: PASS — existing Phase 1 integration test unbroken. The OrderBook's `_executeFill` falls back to legacy behavior when `positionManager == address(0)`.

---

## Task 14: Phase 2 Wrap-up

- [ ] **Step 14.1: Update CHANGELOG.md**

Add to CHANGELOG.md under `## [0.2.0] - 2026-04-XX`:

```markdown
## [0.2.0] - 2026-04-XX

### Added
- **PositionManager:** Full position lifecycle — open, increase, decrease, close, flip with weighted avg entry pricing
- **PositionRegistry:** EnumerableSet-based holder tracking per market (for ADL)
- **LiquidationEngine:** Partial and full liquidation with fee distribution
- **Insurance Fund:** Deficit absorption from liquidation shortfalls
- **ADL (Auto-Deleverage):** Force-close most profitable counterparty when insurance fund is depleted
- **OrderBook Integration:** Fills now create/update positions via PositionManager
- **Liquidation Keeper:** Rust keeper bot with position monitoring, tx submission, nonce management
- **Events:** PositionUpdated, PositionClosed, PositionLiquidated, AutoDeleveraged
- **Fuzz tests:** Weighted avg entry price bounded, PnL conservation across partial closes
- **Integration tests:** Full position lifecycle, liquidation flow with ADL
- **Blog #03:** "Margin Systems from Scratch"
- **Blog #04:** "Liquidation: Protecting the Protocol"

### Changed
- **OrderBook._executeFill:** Now delegates to PositionManager for margin conversion (backward-compatible when PositionManager not set)

### Notes
- Funding settlement is stubbed (no-op) — real FundingRate implementation is Phase 3
```

- [ ] **Step 14.2: Tag v0.2.0**

```bash
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG for v0.2.0"
git tag v0.2.0
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - [x] Section 3.6 PositionManager — Task 2 (struct, storage, updatePosition, views)
   - [x] Section 3.6 PositionRegistry (EnumerableSet) — Task 2 (_positionHolders)
   - [x] Section 3.6 Position transitions (new, increase, partial close, full close, flip) — Task 1-2
   - [x] Section 3.6 Order margin → position margin conversion — Task 4 (OrderBook integration)
   - [x] Section 3.6 Unrealized PnL — Task 2 (getUnrealizedPnl)
   - [x] Section 3.6 Margin ratio — Task 2 (getMarginRatio)
   - [x] Section 3.7 LiquidationEngine — Task 8
   - [x] Section 3.7 isLiquidatable — Task 8 (marginRatio < MMR)
   - [x] Section 3.7 Partial liquidation (solve for reduceSize) — Task 8
   - [x] Section 3.7 Full liquidation (equity <= 0 or size < minOrderSize) — Task 8
   - [x] Section 3.7 Fee distribution (liquidator + insurance) — Task 8
   - [x] Section 3.7 Insurance fund deficit handling — Task 8
   - [x] Section 3.7 ADL (rank by unrealized PnL, force-close) — Task 8
   - [x] Section 8 Weighted avg entry formula — Task 2 + 3 (fuzz tested)
   - [x] Section 8 Partial close PnL formula — Task 2
   - [x] Section 8 Liquidation formula (reduceSize) — Task 8
   - [x] Phase 2a checklist items — Tasks 0-5
   - [x] Phase 2b checklist items — Tasks 6-11
   - [x] Blog #03 — Task 12
   - [x] Blog #04 — Task 12
   - [x] Liquidation keeper (Rust) — Task 11

2. **Placeholder scan:** No "TBD", "TODO", or "implement later" patterns found. FundingRate settlement is explicitly stubbed with a clear Phase 3 note, not a placeholder.

3. **Type consistency:** `int256` for position size and PnL, `uint256` for prices and collateral, `IPositionManager.Position` struct matches spec. `FixedPointMath.mulFpSigned` used for signed PnL calculations.

4. **Backward compatibility:** OrderBook's `_executeFill` checks `address(positionManager) != address(0)` and falls through to legacy behavior if not set. Existing Phase 1 tests pass unchanged.

5. **Access control:** PositionManager restricts `updatePosition` to orderBook, `liquidatePosition` to liquidationEngine. LiquidationEngine config is admin-only. All contracts use `onlyRole(DEFAULT_ADMIN_ROLE)` for admin functions.

6. **Deferred to Phase 3:** FundingRate.settleFunding (called as no-op in PositionManager and LiquidationEngine), MarketFactory, Router, advanced order types.

---

**Plan complete. Three execution options:**
1. **Subagent-Driven (recommended)** — sspower:subagent-driven-development
2. **Inline Execution** — sspower:executing-plans
3. **Codex execute** — delegate via `/codex:rescue`
