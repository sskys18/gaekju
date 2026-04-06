# Gaekju — Perpetual DEX Design Specification

> **Status:** Revised (post-review)
> **Date:** 2026-04-06
> **Chain:** Giwa Chain (OP Stack L2 Testnet)
> **License:** MIT

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

---

## 1. Overview

Gaekju is a **production-grade perpetual futures DEX** deployed on Giwa Chain, an OP Stack L2 testnet. It follows the **Lighter.xyz architecture**: a fully on-chain central limit orderbook (CLOB) with bitmap-based price level encoding for gas efficiency.

### Design Principles

- **On-chain first:** All matching, position management, and risk checks happen in smart contracts. No trust assumptions beyond the L2 sequencer.
- **Modular contracts:** Each concern (orderbook, margin, liquidation, funding) lives in its own contract. Independently upgradeable and testable.
- **Rust backend as infrastructure:** The Rust codebase provides indexing, API serving, keeper bots, and SDK — it does not perform matching or risk decisions.
- **Documentation as a product:** Every phase produces ADRs, specs, changelog entries, and a blog post. The project is a tutorial as much as a product.

### What Gaekju Is

- A fully on-chain perpetual futures exchange
- Bitmap-based CLOB (Lighter model) on an OP Stack L2
- Supports crypto perpetuals (BTC, ETH, SOL, etc.) and RWA perpetuals (EUR/USD, XAU/USD)
- USDC-only collateral with isolated margin
- Per-market configurable leverage (up to 50x crypto, 10x RWA)
- Pyth Network oracle integration

### What Gaekju Is Not

- Not an AMM or vAMM — this is a proper orderbook
- Not an off-chain matching engine — all matching is on-chain
- Not cross-margin (in v1) — isolated margin only
- Not a token launch — no governance token in scope

---

## 2. Architecture

### 2.1 System Overview

```
                           ┌─────────────────────────────┐
                           │      Giwa Chain (OP Stack)   │
                           │                               │
  Traders ──WebSocket───▶  │  ┌─────────────────────────┐ │
  & REST API               │  │    Smart Contracts        │ │
                           │  │                           │ │
  ┌────────────────┐       │  │  MarketFactory            │ │
  │  Rust Backend   │◀events│  │  ├─ OrderBook (per mkt)  │ │
  │                 │       │  │  ├─ PositionManager       │ │
  │  gaekju-indexer │       │  │  ├─ MarginEngine          │ │
  │  gaekju-api     │──tx──▶│  │  ├─ LiquidationEngine    │ │
  │  gaekju-keeper  │       │  │  ├─ FundingRate           │ │
  │  gaekju-sdk     │       │  │  ├─ OracleAdapter (Pyth)  │ │
  │  gaekju-cli     │       │  │  ├─ Vault (USDC)          │ │
  └────────────────┘       │  │  └─ Router                 │ │
                           │  └─────────────────────────┘ │
                           └─────────────────────────────┘
```

### 2.2 Data Flow: Order Lifecycle

```
Trader                    Giwa L2                         Rust Backend
  │                         │                                │
  │── deposit USDC ────────▶│ Vault.deposit()                │
  │                         │   └─ credit balance            │
  │                         │                                │
  │── place limit order ──▶│ Router.placeOrder()             │
  │                         │   ├─ MarginEngine.check()      │
  │                         │   ├─ OrderBook.insert()        │
  │                         │   └─ emit OrderPlaced          │
  │                         │                       ────────▶│ index event
  │                         │                                │ update API
  │                         │                                │
  │                         │ (another trader's order matches)│
  │                         │   ├─ OrderBook.match()         │
  │                         │   ├─ PositionManager.updatePosition() │
  │                         │   ├─ Vault.unlockOrderMargin() + lockMargin() │
  │                         │   └─ emit OrderMatched, Fill   │
  │                         │                       ────────▶│ index events
  │                         │                                │ push WS update
  │◀── position update ────│                                │
```

### 2.3 Data Flow: Liquidation

```
Keeper (Rust)             Giwa L2
  │                         │
  │── isLiquidatable? ────▶│ LiquidationEngine.isLiquidatable()
  │◀── true ───────────────│   └─ marginRatio < MMR
  │                         │
  │── liquidate() ────────▶│ LiquidationEngine.liquidate()
  │                         │   ├─ FundingRate.settleFunding()
  │                         │   ├─ calculate liquidation size
  │                         │   ├─ PositionManager.updatePosition()
  │                         │   ├─ fee → keeper + insurance fund
  │                         │   └─ emit PositionLiquidated
```

---

## 3. Smart Contracts

### 3.1 Libraries

#### BitmapLib.sol
Bitmap operations for price level tracking. Each bit represents whether orders exist at a given tick.

- `setBit(bitmap, index)` — mark tick as having orders
- `clearBit(bitmap, index)` — mark tick as empty
- `findFirstSet(bitmap)` — find lowest tick with orders (best ask)
- `findLastSet(bitmap)` — find highest tick with orders (best bid)
- `isEmpty(bitmap)` — check if any bits are set

Implementation: 256-bit words, with a two-level bitmap for markets with >256 ticks. First level indexes which 256-bit word has active ticks, second level is the actual tick bitmap.

#### FixedPointMath.sol
18-decimal fixed-point arithmetic. All prices, sizes, and rates use `uint256` with 18 decimals (1e18 = 1.0).

- `mulFp(a, b) → a * b / 1e18`
- `divFp(a, b) → a * 1e18 / b`
- `mulDiv(a, b, c) → a * b / c` (full precision, no overflow)
- Uses OpenZeppelin's `Math.mulDiv` for overflow-safe multiplication.

#### PackedOrder.sol
Pack order data into minimal storage slots.

```
Slot 0 (256 bits):
  [0:159]   owner address (160 bits)
  [160:191] orderId (32 bits)
  [192:223] timestamp (32 bits)
  [224:231] orderFlags (8 bits: side[1], orderType[3], reduceOnly[1], unused[3])
  [232:255] reserved (24 bits)

Slot 1 (256 bits):
  [0:127]   price (128 bits, fixed-point 18 dec)
  [128:255] size (128 bits, fixed-point 18 dec)
```

- `pack(order) → (bytes32, bytes32)`
- `unpack(slot0, slot1) → Order`
- `getPrice(slot1) → uint128`
- `getSize(slot1) → uint128`
- `getSide(slot0) → bool` (true = buy/long)

#### TickMath.sol
Convert between human-readable prices and tick indices.

- `priceToTick(price, tickSize) → tickIndex`
- `tickToPrice(tickIndex, tickSize) → price`
- Tick index is an integer: `tickIndex = price / tickSize`
- Example: BTC at $60,000 with tickSize $0.10 → tick 600,000

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
midPrice = (bestBid + bestAsk) / 2   // from OrderBook, 0 if empty
if midPrice == 0:
    markPrice = oraclePrice
else:
    markPrice = oraclePrice * 0.7 + midPrice * 0.3  // oracle-weighted blend
```
This ensures mark price and index price diverge when the orderbook trades away from oracle, producing non-zero funding rates. In v2, mark price uses a TWAP of this blend for smoothing.

### 3.4 OrderBook

The core matching engine. One instance per market, deployed by MarketFactory.

#### Storage Layout

```solidity
// Two-level bitmap for price levels
// Level 0: which 256-bit words have active ticks
uint256 public bidBitmapIndex;   // bitmap of active bid words
uint256 public askBitmapIndex;   // bitmap of active ask words

// Level 1: actual tick bitmaps (256 ticks per word)
mapping(uint256 => uint256) public bidBitmaps;  // wordIndex → bitmap
mapping(uint256 => uint256) public askBitmaps;

// Orders at each tick (FIFO queue)
mapping(uint256 => uint256) public bidHeadAtTick;  // tick → first orderId
mapping(uint256 => uint256) public bidTailAtTick;  // tick → last orderId
mapping(uint256 => uint256) public askHeadAtTick;
mapping(uint256 => uint256) public askTailAtTick;

// Order storage (packed)
mapping(uint256 => bytes32) public orderSlot0;   // orderId → packed slot 0
mapping(uint256 => bytes32) public orderSlot1;   // orderId → packed slot 1
mapping(uint256 => uint256) public nextOrder;     // orderId → next in FIFO

// Book state
uint256 public bestBidTick;
uint256 public bestAskTick;
uint256 public nextOrderId;
```

#### Place Order Flow

```
placeOrder(side, price, size, orderType):
  1. Validate: size >= minOrderSize, price aligned to tickSize
  2. Calculate required margin: size * price / maxLeverage
  3. MarginEngine.checkAndReserve(account, margin)
  4. If orderType == MARKET:
       matched = matchAgainst(oppositeSide, size)
       if matched == 0: revert("no liquidity")
       // Market orders fill what's available, like aggressive IOC
       // Unfilled remainder is discarded (not resting on book)
  5. If orderType == LIMIT:
       matchable = tryMatch(oppositeSide, price, size)
       if orderFlags.postOnly && matchable > 0: revert  // Post-Only check via flags
       if matchable > 0: executeMatches(...)
       remaining = size - matched
       if remaining > 0: insertIntoBook(side, price, remaining)
  6. If orderType == IOC:
       matched = tryMatch(oppositeSide, price, size)
       // discard unfilled portion
  7. If orderType == FOK:
       if canFullyFill(oppositeSide, price, size): executeMatches(...)
       else: revert
```

#### Matching Algorithm

```
tryMatch(side, limitPrice, size):
  remaining = size
  if side == BUY:
    tick = bestAskTick
    while remaining > 0 && tick <= priceToTick(limitPrice):
      orderId = askHeadAtTick[tick]
      while orderId != 0 && remaining > 0:
        makerOrder = unpack(orderId)
        nextId = nextOrder[orderId]       // cache BEFORE potential removal
        fillSize = min(remaining, makerOrder.size)
        executeFill(maker, taker, tick, fillSize)
        remaining -= fillSize
        if makerOrder fully filled:
          removeOrder(orderId)            // safe: nextId already cached
          orderId = nextId
        else:
          updateOrderSize(orderId, makerOrder.size - fillSize)
          break  // partial fill, this order stays at head
      if tick is now empty: clearBit, advance to next ask tick
    update bestAskTick
  // mirror for SELL side
  return size - remaining  // total matched
```

#### Fee Model

```solidity
struct FeeConfig {
    int256 makerFeeRate;    // -1e14 = -0.01% (negative = rebate)
    int256 takerFeeRate;    //  5e14 = +0.05%
}

// Applied on each fill inside executeFill():
//   notional = mulFp(fillSize, fillPrice)
//   makerFee = mulFp(notional, makerFeeRate)  // negative → maker receives
//   takerFee = mulFp(notional, takerFeeRate)  // positive → taker pays
//   vault.realizePnl(maker, -makerFee)
//   vault.realizePnl(taker, -takerFee)
//   protocolRevenue += takerFee + makerFee    // always net positive
```

#### Events

```solidity
event OrderPlaced(uint256 indexed orderId, address indexed trader, uint256 indexed marketId, bool side, uint256 price, uint256 size, uint8 orderType);
event OrderMatched(uint256 indexed marketId, uint256 makerOrderId, uint256 takerOrderId, uint256 price, uint256 size);
event OrderCancelled(uint256 indexed orderId, address indexed trader);
event Fill(uint256 indexed marketId, address indexed maker, address indexed taker, uint256 price, uint256 size, bool takerSide);
```

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

// Called by OrderBook on fill
function updatePosition(
    address account,
    uint256 marketId,
    int256 sizeDelta,     // positive = buy, negative = sell
    uint256 fillPrice,
    uint256 marginDelta
) external onlyOrderBook;

// View functions
function getPosition(address account, uint256 marketId) external view returns (Position memory);
function getUnrealizedPnl(address account, uint256 marketId) external view returns (int256);
function getPositionValue(address account, uint256 marketId) external view returns (uint256);
```

Position update logic:
```
updatePosition(account, market, sizeDelta, fillPrice, marginDelta):
  pos = positions[account][market]
  settleFunding(account, market)  // settle accumulated funding first

  if pos.size == 0:
    // New position
    pos.size = sizeDelta
    pos.entryPrice = fillPrice
    pos.collateral = marginDelta

  else if sameDirection(pos.size, sizeDelta):
    // Increase position — weighted average entry
    newSize = pos.size + sizeDelta
    pos.entryPrice = (mulFp(pos.entryPrice, abs(pos.size)) + mulFp(fillPrice, abs(sizeDelta))) * 1e18 / abs(newSize)
    pos.size = newSize
    pos.collateral += marginDelta

  // On every fill: release order margin, convert to position margin
  vault.unlockOrderMargin(account, orderMarginForThisFill)

  else if abs(sizeDelta) < abs(pos.size):
    // Partial close — realize PnL
    pnl = mulFp(fillPrice - pos.entryPrice, abs(sizeDelta)) * sign(pos.size)
    vault.realizePnl(account, pnl)
    pos.size += sizeDelta
    proportionalCollateral = pos.collateral * abs(sizeDelta) / abs(pos.size)
    pos.collateral -= proportionalCollateral
    vault.unlockMargin(account, proportionalCollateral)

  else if abs(sizeDelta) == abs(pos.size):
    // Full close
    pnl = mulFp(fillPrice - pos.entryPrice, abs(pos.size)) * sign(pos.size)
    vault.realizePnl(account, pnl)
    vault.unlockMargin(account, pos.collateral)
    delete positions[account][market]

  else:
    // Flip — close old + open new in opposite direction
    closePnl = mulFp(fillPrice - pos.entryPrice, abs(pos.size)) * sign(pos.size)
    vault.realizePnl(account, closePnl)
    vault.unlockMargin(account, pos.collateral)
    remainingSize = sizeDelta + pos.size  // opposite sign
    newMargin = mulFp(abs(remainingSize), fillPrice) * IMR  // margin for new direction
    vault.lockMargin(account, newMargin)
    pos.size = remainingSize
    pos.entryPrice = fillPrice
    pos.collateral = newMargin
```

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

```solidity
struct FundingState {
    int256 cumulativeFundingRate;  // accumulated funding rate (18 dec)
    uint256 lastFundingTime;       // last update timestamp
    uint256 fundingInterval;       // 8 hours = 28800 seconds
    int256 maxFundingRate;         // e.g., 1e15 = 0.1%
}

mapping(uint256 => FundingState) public fundingStates;

function applyFunding(uint256 marketId) external;
// 1. Check: block.timestamp >= lastFundingTime + fundingInterval
// 2. markPrice = oracle.getMarkPrice(marketId)
//    indexPrice = oracle.getIndexPrice(marketId)
// 3. rate = clamp((markPrice - indexPrice) * 1e18 / indexPrice, -maxRate, +maxRate)
// 4. cumulativeFundingRate += rate
// 5. lastFundingTime = block.timestamp
// 6. Emit FundingApplied(marketId, rate, cumulativeFundingRate)

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
mapping(uint256 => address) public orderBooks;     // marketId → OrderBook address
mapping(uint256 => MarketParams) public marketParams;
mapping(uint256 => bool) public marketActive;

function createMarket(MarketParams calldata params) external onlyAdmin returns (uint256 marketId);
function pauseMarket(uint256 marketId) external onlyAdmin;
function resumeMarket(uint256 marketId) external onlyAdmin;
function updateMarketConfig(uint256 marketId, MarketParams calldata params) external onlyAdmin;
```

### 3.10 Router

Single entry point for common multi-step operations.

```solidity
function depositAndPlaceOrder(
    uint256 depositAmount,
    uint256 marketId,
    bool side,
    uint256 price,
    uint256 size,
    uint8 orderType
) external;

function cancelAllOrders(uint256 marketId) external;

function closePositionMarket(uint256 marketId) external;
// Places a market order to fully close the position

function batchPlaceOrders(
    uint256 marketId,
    Order[] calldata orders
) external;
// For market makers: place multiple orders in one tx

function batchCancel(
    uint256 marketId,
    uint256[] calldata orderIds
) external;
```

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
│   │   ├── OrderBook.sol
│   │   ├── PositionManager.sol
│   │   ├── MarginEngine.sol
│   │   ├── LiquidationEngine.sol
│   │   ├── FundingRate.sol
│   │   ├── OracleAdapter.sol
│   │   ├── Vault.sol
│   │   ├── MarketFactory.sol
│   │   ├── Router.sol
│   │   ├── interfaces/
│   │   │   ├── IOrderBook.sol
│   │   │   ├── IPositionManager.sol
│   │   │   ├── IMarginEngine.sol
│   │   │   ├── ILiquidationEngine.sol
│   │   │   ├── IFundingRate.sol
│   │   │   ├── IOracleAdapter.sol
│   │   │   ├── IVault.sol
│   │   │   └── IRouter.sol
│   │   └── libraries/
│   │       ├── BitmapLib.sol
│   │       ├── FixedPointMath.sol
│   │       ├── PackedOrder.sol
│   │       └── TickMath.sol
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
│   ├── gaekju-indexer/
│   ├── gaekju-api/
│   ├── gaekju-keeper/
│   ├── gaekju-sdk/
│   ├── gaekju-cli/
│   └── gaekju-mirror/              # Lighter liquidity mirror
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

### Phase 1: Foundation & Core Orderbook (Weeks 1-3)

#### 1.0 Project Setup
- [ ] Initialize git repo, add LICENSE (MIT), README.md
- [ ] Scaffold Foundry project in `contracts/`
- [ ] Scaffold Rust workspace in `crates/` with all crate stubs
- [ ] Set up CI: `forge test` + `cargo test` + `cargo clippy` + `forge fmt`
- [ ] Create `docs/` directory structure
- [ ] Write ADR-0001 through ADR-0009 (all initial decisions)
- [ ] Write blog post #00: "Why We're Building Gaekju"

#### 1.1 Solidity Libraries
- [ ] `BitmapLib.sol` — implement + unit test all operations
- [ ] `FixedPointMath.sol` — implement + fuzz test (check vs Python reference)
- [ ] `PackedOrder.sol` — implement + round-trip fuzz test (pack → unpack == original)
- [ ] `TickMath.sol` — implement + test edge cases (min/max tick, zero price)

#### 1.2 Vault Contract
- [ ] Implement Vault with UUPS proxy
- [ ] Unit tests: deposit, withdraw, balance checks, access control
- [ ] Test: cannot withdraw more than balance
- [ ] Test: only authorized contracts can lock/unlock margin

#### 1.3 OracleAdapter Contract
- [ ] Integrate Pyth SDK
- [ ] Implement price fetching with staleness + confidence checks
- [ ] Unit tests with mock Pyth contract
- [ ] Test: reverts on stale price
- [ ] Test: reverts on wide confidence band

#### 1.4 MarginEngine Contract (Basic)
- [ ] Implement MarketConfig storage
- [ ] Implement margin checks (initial margin, available margin)
- [ ] Implement order margin reservation
- [ ] Unit tests for each margin function
- [ ] Fuzz test: margin calculations never overflow

#### 1.5 OrderBook Contract (Limit Orders Only)
- [ ] Implement bitmap storage layout
- [ ] Implement order insertion (place limit order)
- [ ] Implement matching algorithm (price-time priority)
- [ ] Implement order cancellation
- [ ] Unit test: place order → check book state
- [ ] Unit test: two orders match → check fill events
- [ ] Unit test: partial fill → check remaining size
- [ ] Unit test: cancel → check margin released
- [ ] Unit test: self-trade prevention (same account orders don't match)
- [ ] Integration test: deposit → place bid → place ask (diff account) → match → check fill events + margin changes
- [ ] Gas benchmark: place, match, cancel operations
- [ ] Note: full position integration test deferred to Phase 2 (requires PositionManager)

#### 1.6 Rust Types Crate
- [ ] Define Order, Position, Market, Account types
- [ ] Generate ABI bindings from Foundry artifacts using alloy
- [ ] Event type definitions matching contract events

#### 1.7 Phase 1 Wrap-up
- [ ] Write blog post #01: "Choosing a Perp DEX Architecture"
- [ ] Write blog post #02: "Building a Bitmap Orderbook"
- [ ] Update CHANGELOG.md
- [ ] Tag: v0.1.0

---

### Phase 2a: Position Management (Weeks 4-5)

#### 2a.1 PositionManager Contract
- [ ] Implement Position struct and storage
- [ ] Implement PositionRegistry (EnumerableSet of holders per market) for ADL
- [ ] Implement updatePosition: new, increase, decrease, close, flip
- [ ] Implement order margin → position margin conversion on fill
- [ ] Implement unrealized PnL calculation (with mulFp normalization)
- [ ] Implement margin ratio calculation (handle zero-notional case)
- [ ] Unit tests for each position transition
- [ ] Fuzz test: weighted average entry price calculation (verify mulFp precision)
- [ ] Integration test: deposit → place → match → check positions + PnL
- [ ] Integration test: multiple fills → correct entry price

#### 2a.2 Indexer — Basic
- [ ] Set up PostgreSQL schema (migrations via sqlx)
- [ ] Implement block-by-block event fetching
- [ ] Implement event decoding for all contract events
- [ ] Implement reorg detection and rollback
- [ ] Implement resumption from last indexed block
- [ ] Integration test: index events from local Anvil

#### 2a.3 Phase 2a Wrap-up
- [ ] Write blog post #03: "Margin Systems from Scratch"
- [ ] Update CHANGELOG.md
- [ ] Tag: v0.2.0

---

### Phase 2b: Liquidation Engine (Weeks 6-7)

#### 2b.1 LiquidationEngine Contract
- [ ] Implement isLiquidatable check (with funding settlement first)
- [ ] Implement partial liquidation logic (post-fee IMR targeting)
- [ ] Implement full liquidation (when equity <= 0 or size < minOrderSize)
- [ ] Implement per-market insurance fund + global insurance fund backstop
- [ ] Implement dust position cleanup on partial liquidation
- [ ] Unit test: liquidation at exactly MMR boundary
- [ ] Unit test: partial liquidation restores margin to IMR after fees
- [ ] Unit test: full liquidation when equity negative
- [ ] Unit test: insurance fund absorbs deficit
- [ ] Unit test: funding settled before liquidation check

#### 2b.2 ADL (Auto-Deleverage)
- [ ] Implement ADL ranking using PositionRegistry.getPositionHolders()
- [ ] Implement force-close logic against bankrupt positions
- [ ] Implement loss waterfall: per-market fund → global fund → ADL → socialized loss
- [ ] Unit test: ADL triggers when insurance fund empty
- [ ] Scenario test: cascading liquidation chain → insurance depletion → ADL

#### 2b.3 Liquidation Keeper
- [ ] Implement position monitoring loop
- [ ] Implement liquidation transaction submission
- [ ] Implement nonce management for rapid txs
- [ ] Implement gas price estimation
- [ ] Integration test: position goes under margin → keeper liquidates

#### 2b.4 Phase 2b Wrap-up
- [ ] Write blog post #04: "Liquidation: Protecting the Protocol"
- [ ] Update CHANGELOG.md
- [ ] Tag: v0.3.0

---

### Phase 3: Funding Rate, Markets & Advanced Orders (Weeks 8-9)

#### 3.1 FundingRate Contract
- [ ] Implement cumulative funding rate calculation
- [ ] Implement funding settlement in PositionManager (with markPrice multiplication for USDC denomination)
- [ ] Implement mark price blend: 70% oracle + 30% orderbook mid-price
- [ ] Implement missed-interval catch-up logic (sequential application, not multiplier)
- [ ] Unit test: positive/negative/zero/clamped funding
- [ ] Unit test: funding settlement on position update
- [ ] Integration test: hold position across 3 funding intervals

#### 3.2 MarketFactory Contract
- [ ] Implement market creation (deploys OrderBook proxy)
- [ ] Implement market config management
- [ ] Implement market pause/resume
- [ ] Unit test: create market → trade → verify isolation
- [ ] Define initial market configs (see Section 9)

#### 3.3 Advanced Order Types
- [ ] Implement Market order in OrderBook
- [ ] Implement IOC (immediate-or-cancel)
- [ ] Implement FOK (fill-or-kill)
- [ ] Implement Post-Only
- [ ] Implement Reduce-Only flag
- [ ] Unit test for each order type + edge cases

#### 3.4 Router Contract
- [ ] Implement depositAndPlaceOrder
- [ ] Implement cancelAllOrders
- [ ] Implement closePositionMarket
- [ ] Implement batchPlaceOrders
- [ ] Implement batchCancel
- [ ] Integration tests for all router functions

#### 3.5 Funding Keeper
- [ ] Implement funding rate trigger loop
- [ ] Implement Pyth price update before funding
- [ ] Integration test: keeper triggers funding on schedule

#### 3.6 Phase 3 Wrap-up
- [ ] Write blog post #05: "How Perp Funding Rates Actually Work"
- [ ] Update CHANGELOG.md
- [ ] Tag: v0.4.0

---

### Phase 4: Rust Infrastructure Complete (Weeks 10-12)

#### 4.1 API Server
- [ ] Set up axum server with tower middleware (CORS, compression, rate limit)
- [ ] Implement all REST endpoints (see Section 4.4)
- [ ] Implement WebSocket handler with subscription management
- [ ] Implement orderbook snapshot + incremental update streams
- [ ] Implement trade stream
- [ ] Implement position + order update streams
- [ ] Integration tests against local stack
- [ ] Write OpenAPI spec (docs/api/openapi.yaml)

#### 4.2 SDK
- [ ] Implement GaekjuClient (REST + contract interaction)
- [ ] Implement WebSocket subscription client
- [ ] Implement order builder helpers
- [ ] Implement transaction signing + nonce management
- [ ] Unit + integration tests
- [ ] Rust doc comments on all public APIs

#### 4.3 CLI
- [ ] Implement admin commands (deploy, create-market, pause)
- [ ] Implement trading commands (deposit, withdraw, buy, sell, cancel)
- [ ] Implement info commands (orderbook, positions, markets, funding)
- [ ] Add config file support (~/.gaekju/config.toml)

#### 4.4 Docker & Monitoring
- [ ] Dockerfiles for indexer, api, keeper
- [ ] docker-compose.yml for full local stack
- [ ] Prometheus metrics in API + keeper
- [ ] Health check endpoints
- [ ] Structured logging with tracing

#### 4.5 Phase 4 Wrap-up
- [ ] Write blog post #06: "Building an L2 Indexer in Rust"
- [ ] Write blog post #07: "Keeper Bots: The Unseen Infrastructure"
- [ ] Update CHANGELOG.md
- [ ] Tag: v0.5.0

---

### Phase 5: Testing, Security & Testnet Launch (Weeks 13-16)

#### 5.1 Comprehensive Testing
- [ ] Fuzz testing campaign: all math functions, position transitions
- [ ] Invariant tests:
  - Total vault balance >= sum of all account balances + insurance fund
  - Sum of long open interest == sum of short open interest (per market)
  - Every order in the book has reserved margin
  - Orderbook is sorted (no crossed book)
- [ ] Load test: simulate 100 concurrent traders via SDK
- [ ] Scenario tests: market crash, all positions liquidated, ADL chain

#### 5.2 Security Review
- [ ] Run Slither static analysis, fix all findings
- [ ] Reentrancy audit: check all external calls
- [ ] Access control audit: verify all onlyAuthorized modifiers
- [ ] Oracle manipulation audit: price staleness, confidence checks
- [ ] Integer overflow audit (should be covered by Solidity 0.8+)
- [ ] Write SECURITY.md with disclosure policy

#### 5.3 Testnet Deployment
- [ ] Write Foundry deployment scripts (CREATE2 deterministic)
- [ ] Deploy all contracts to Giwa testnet
- [ ] Verify contracts on block explorer
- [ ] Deploy Rust backend (Docker on VPS)
- [ ] Create initial markets (BTC, ETH, SOL, EUR, XAU)
- [ ] Seed liquidity with market-making bot
- [ ] Testnet USDC faucet

#### 5.4 Documentation Completion
- [ ] Getting started guide
- [ ] Local development guide
- [ ] Deployment guide
- [ ] API documentation (REST + WebSocket)
- [ ] Contributing guide
- [ ] Glossary and formula reference

#### 5.5 Phase 5 Wrap-up
- [ ] Write blog post #08: "Fuzz Testing a DeFi Protocol"
- [ ] Write blog post #09: "Deploying to an OP Stack Testnet"
- [ ] Write blog post #10: "Lessons from Building a Perp DEX"
- [ ] Update CHANGELOG.md
- [ ] Tag: v1.0.0-testnet

---

## 7. Technical Decisions (ADR Summary)

| ADR | Decision | Key Rationale |
|-----|----------|---------------|
| 0001 | On-chain CLOB (Lighter model) | No off-chain trust assumptions, L2 makes gas feasible |
| 0002 | Modular contracts | Independent upgrades, clean testing, contract size limits |
| 0003 | Bitmap orderbook | O(1) best price lookup, gas-efficient tick management |
| 0004 | Pyth Network oracle | Pull-based, sub-second updates, L2 native |
| 0005 | USDC-only collateral | Simplifies accounting, no haircut calculations |
| 0006 | Isolated margin (v1) | Simpler risk model, cross-margin in v2 |
| 0007 | Rust for backend | Performance, type safety, alloy ecosystem |
| 0008 | Alloy over ethers-rs | Actively maintained, better type generation |
| 0009 | UUPS proxy pattern | Minimal gas overhead, clean upgrade path |

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

### Crypto Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Max Funding Rate |
|--------|-------------|-----|-----|-----------|----------|-----------------|
| BTC-USD | 50x | 2% | 1% | $0.10 | 0.001 BTC | 0.1% / 8h |
| ETH-USD | 50x | 2% | 1% | $0.01 | 0.01 ETH | 0.1% / 8h |
| SOL-USD | 20x | 5% | 2.5% | $0.001 | 0.1 SOL | 0.1% / 8h |
| OP-USD | 20x | 5% | 2.5% | $0.0001 | 1 OP | 0.1% / 8h |
| ARB-USD | 20x | 5% | 2.5% | $0.0001 | 1 ARB | 0.1% / 8h |
| DOGE-USD | 10x | 10% | 5% | $0.00001 | 100 DOGE | 0.1% / 8h |

### RWA Perpetuals

| Market | Max Leverage | IMR | MMR | Tick Size | Lot Size | Max Funding Rate |
|--------|-------------|-----|-----|-----------|----------|-----------------|
| EUR-USD | 10x | 10% | 5% | $0.0001 | 100 EUR | 0.05% / 8h |
| GBP-USD | 10x | 10% | 5% | $0.0001 | 100 GBP | 0.05% / 8h |
| XAU-USD | 10x | 10% | 5% | $0.01 | 0.01 oz | 0.05% / 8h |
| XAG-USD | 10x | 10% | 5% | $0.001 | 1 oz | 0.05% / 8h |
| SPX-USD | 5x | 20% | 10% | $0.01 | 0.01 units | 0.05% / 8h |

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

### Orderbook Integrity
- **Self-trade prevention:** Orders from the same account skip each other during matching.
- **Crossed book recovery:** If bestBid >= bestAsk after an update (should never happen), halt the market and alert. This is a critical invariant.
- **Quote stuffing mitigation:** Per-account rate limit on order placement (configurable, e.g., 100 orders/block).

### Testing Requirements
- 100% branch coverage on all contracts
- Fuzz testing on all math functions (minimum 10,000 runs)
- Invariant testing on system-wide properties
- Slither + Mythril static analysis with zero high/medium findings

---

## 11. Live Market Operations — Lighter Mirror + Testnet Traders

Gaekju connects to **Lighter.xyz** as its liquidity source. Lighter has 220+ perpetual markets including crypto, forex, and commodities — all with free unauthenticated API access. Real Lighter orderbook depth is mirrored onto Gaekju's on-chain book. Testnet users trade against this real-world depth, and their orders coexist with the mirrored orders on the same on-chain orderbook.

**Why Lighter as the mirror source:**
- Gaekju follows Lighter's architecture — same on-chain CLOB model
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
