# Phase 1: Foundation & Core Orderbook — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Gaekju project from scratch — Foundry contracts (libraries, Vault, OracleAdapter, MarginEngine, OrderBook with limit order matching) and a Rust types crate with ABI bindings. By the end a two-party deposit → place → match → fill flow works on Anvil.

**Architecture:** Modular Solidity contracts behind UUPS proxies, each with a single responsibility. Libraries (BitmapLib, FixedPointMath, PackedOrder, TickMath) are pure and stateless. Contracts interact through explicit interfaces. Rust workspace provides shared types and ABI bindings generated from Foundry artifacts via alloy. All internal accounting uses 18-decimal fixed-point; USDC 6→18 conversion happens only at the Vault boundary.

**Tech Stack:** Solidity 0.8.28 · Foundry · OpenZeppelin 5.x (UUPS, AccessControl, ReentrancyGuard, EnumerableSet) · Rust 1.82+ · alloy 0.12 · tokio · serde

**Spec reference:** `docs/specs/2026-04-06-gaekju-design.md` — Sections 1-3 (Overview, Architecture, Smart Contracts), Section 5 (Project Structure), Section 8 (Formulas)

---

## File Map

### New files created in this plan

```
gaekju/
├── contracts/
│   ├── foundry.toml
│   ├── remappings.txt
│   ├── src/
│   │   ├── libraries/
│   │   │   ├── BitmapLib.sol
│   │   │   ├── FixedPointMath.sol
│   │   │   ├── PackedOrder.sol
│   │   │   └── TickMath.sol
│   │   ├── interfaces/
│   │   │   ├── IVault.sol
│   │   │   ├── IOracleAdapter.sol
│   │   │   ├── IMarginEngine.sol
│   │   │   └── IOrderBook.sol
│   │   ├── Vault.sol
│   │   ├── OracleAdapter.sol
│   │   ├── MarginEngine.sol
│   │   └── OrderBook.sol
│   ├── test/
│   │   ├── unit/
│   │   │   ├── BitmapLib.t.sol
│   │   │   ├── FixedPointMath.t.sol
│   │   │   ├── PackedOrder.t.sol
│   │   │   ├── TickMath.t.sol
│   │   │   ├── Vault.t.sol
│   │   │   ├── OracleAdapter.t.sol
│   │   │   ├── MarginEngine.t.sol
│   │   │   └── OrderBook.t.sol
│   │   ├── integration/
│   │   │   └── DepositPlaceMatch.t.sol
│   │   ├── fuzz/
│   │   │   ├── FixedPointMath.fuzz.t.sol
│   │   │   └── PackedOrder.fuzz.t.sol
│   │   └── mocks/
│   │       ├── MockERC20.sol
│   │       └── MockPyth.sol
│   └── script/
│       └── Deploy.s.sol
├── crates/
│   ├── gaekju-types/
│   │   ├── Cargo.toml
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── order.rs
│   │   │   ├── position.rs
│   │   │   ├── market.rs
│   │   │   ├── account.rs
│   │   │   └── events.rs
│   │   └── build.rs
│   ├── gaekju-indexer/
│   │   └── Cargo.toml          (stub only)
│   ├── gaekju-api/
│   │   └── Cargo.toml          (stub only)
│   ├── gaekju-keeper/
│   │   └── Cargo.toml          (stub only)
│   ├── gaekju-sdk/
│   │   └── Cargo.toml          (stub only)
│   ├── gaekju-cli/
│   │   └── Cargo.toml          (stub only)
│   └── gaekju-mirror/
│       └── Cargo.toml          (stub only)
├── Cargo.toml                  (workspace root)
├── .github/
│   └── workflows/
│       └── ci.yml
├── CLAUDE.md
├── CHANGELOG.md
└── LICENSE
```

---

## Task 0: Project Scaffolding

**Files:**
- Create: `contracts/foundry.toml`
- Create: `contracts/remappings.txt`
- Create: `Cargo.toml` (workspace root)
- Create: `crates/gaekju-types/Cargo.toml`
- Create: stub `Cargo.toml` for all other crates
- Create: `.github/workflows/ci.yml`
- Create: `CLAUDE.md`
- Create: `CHANGELOG.md`
- Create: `LICENSE`

- [ ] **Step 0.1: Initialize Foundry project**

```bash
cd /Users/sskys/Mine/gaekju
forge init contracts --no-git --no-commit
```

- [ ] **Step 0.2: Configure Foundry**

`contracts/foundry.toml`:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.28"
optimizer = true
optimizer_runs = 200
via_ir = false
ffi = false
fuzz = { runs = 10000, seed = "0xdeadbeef" }
invariant = { runs = 256, depth = 50 }
fs_permissions = [{ access = "read", path = "out" }]

[fmt]
line_length = 120
tab_width = 4
bracket_spacing = true
```

- [ ] **Step 0.3: Install OpenZeppelin and Pyth SDK**

```bash
cd /Users/sskys/Mine/gaekju/contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-git --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-git --no-commit
forge install pyth-network/pyth-sdk-solidity --no-git --no-commit
```

- [ ] **Step 0.4: Create remappings.txt**

`contracts/remappings.txt`:
```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
@pythnetwork/=lib/pyth-sdk-solidity/
```

- [ ] **Step 0.5: Scaffold Rust workspace**

`Cargo.toml` (workspace root):
```toml
[workspace]
resolver = "2"
members = [
    "crates/gaekju-types",
    "crates/gaekju-indexer",
    "crates/gaekju-api",
    "crates/gaekju-keeper",
    "crates/gaekju-sdk",
    "crates/gaekju-cli",
    "crates/gaekju-mirror",
]

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
alloy = { version = "0.12", features = ["full"] }
alloy-sol-types = "0.8"
alloy-primitives = "0.8"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
eyre = "0.6"
```

`crates/gaekju-types/Cargo.toml`:
```toml
[package]
name = "gaekju-types"
version = "0.1.0"
edition = "2021"

[dependencies]
alloy-sol-types = { workspace = true }
alloy-primitives = { workspace = true }
serde = { workspace = true }
eyre = { workspace = true }
```

Create stub Cargo.toml for each remaining crate (indexer, api, keeper, sdk, cli, mirror) with minimal content:
```toml
[package]
name = "gaekju-<name>"
version = "0.1.0"
edition = "2021"

[dependencies]
gaekju-types = { path = "../gaekju-types" }
```

Each stub crate also needs a `src/lib.rs` (or `src/main.rs` for binaries) with just:
```rust
// Stub — implementation in Phase 2+
```

Use `src/main.rs` for: `gaekju-indexer`, `gaekju-api`, `gaekju-keeper`, `gaekju-cli`, `gaekju-mirror`.
Use `src/lib.rs` for: `gaekju-types`, `gaekju-sdk`.

- [ ] **Step 0.6: Verify both toolchains compile**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge build
cd /Users/sskys/Mine/gaekju && cargo check
```

Expected: both succeed with no errors.

- [ ] **Step 0.7: Create CI workflow**

`.github/workflows/ci.yml`:
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

env:
  FOUNDRY_PROFILE: default

jobs:
  contracts:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: foundry-rs/foundry-toolchain@v1
      - run: cd contracts && forge fmt --check
      - run: cd contracts && forge build --sizes
      - run: cd contracts && forge test -vvv

  rust:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --all -- --check
      - run: cargo clippy --all-targets --all-features -- -D warnings
      - run: cargo test --all
```

- [ ] **Step 0.8: Create CLAUDE.md, CHANGELOG.md, LICENSE**

`CLAUDE.md`:
```markdown
# Gaekju

Perpetual DEX on Giwa Chain (OP Stack L2). On-chain CLOB following the Lighter.xyz architecture.

## Build Commands

### Contracts (Foundry)
- `cd contracts && forge build` — compile
- `cd contracts && forge test -vvv` — run tests
- `cd contracts && forge fmt` — format
- `cd contracts && forge test --match-contract <Name>` — run specific test file

### Rust
- `cargo check` — typecheck
- `cargo test --all` — run all tests
- `cargo clippy --all-targets -- -D warnings` — lint
- `cargo fmt --all -- --check` — format check

## Architecture
- `contracts/src/libraries/` — pure math/encoding libs (BitmapLib, FixedPointMath, PackedOrder, TickMath)
- `contracts/src/interfaces/` — contract interfaces
- `contracts/src/*.sol` — core contracts (Vault, OracleAdapter, MarginEngine, OrderBook, etc.)
- `contracts/test/` — unit/, integration/, fuzz/, mocks/
- `crates/gaekju-types/` — shared Rust types + ABI bindings

## Conventions
- All internal math uses 18-decimal fixed-point (1e18 = 1.0)
- USDC 6→18 conversion happens ONLY at Vault boundary
- Contracts use UUPS proxy pattern
- Solidity: 0.8.28, optimizer 200 runs
- Tests: unit tests co-located by contract, integration tests in integration/
```

`CHANGELOG.md`:
```markdown
# Changelog

## [Unreleased]

### Added
- Project scaffolding (Foundry + Rust workspace)
- CI pipeline (forge test + cargo test + clippy + fmt)
```

`LICENSE`: MIT license text with "2026 Gaekju Contributors".

- [ ] **Step 0.9: Commit**

```bash
git add -A
git commit -m "chore: scaffold Foundry + Rust workspace with CI"
```

---

## Task 1: FixedPointMath Library

**Files:**
- Create: `contracts/src/libraries/FixedPointMath.sol`
- Test: `contracts/test/unit/FixedPointMath.t.sol`
- Fuzz: `contracts/test/fuzz/FixedPointMath.fuzz.t.sol`

- [ ] **Step 1.1: Write unit tests**

`contracts/test/unit/FixedPointMath.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/FixedPointMath.sol";

contract FixedPointMathTest is Test {
    using FixedPointMath for uint256;

    uint256 constant ONE = 1e18;

    function test_mulFp_oneTimesOne() public pure {
        assertEq(FixedPointMath.mulFp(ONE, ONE), ONE);
    }

    function test_mulFp_twoTimesThree() public pure {
        assertEq(FixedPointMath.mulFp(2e18, 3e18), 6e18);
    }

    function test_mulFp_zeroReturnsZero() public pure {
        assertEq(FixedPointMath.mulFp(0, 5e18), 0);
        assertEq(FixedPointMath.mulFp(5e18, 0), 0);
    }

    function test_mulFp_fractional() public pure {
        // 0.5 * 0.5 = 0.25
        assertEq(FixedPointMath.mulFp(5e17, 5e17), 25e16);
    }

    function test_divFp_sixDividedByTwo() public pure {
        assertEq(FixedPointMath.divFp(6e18, 2e18), 3e18);
    }

    function test_divFp_oneDividedByThree() public pure {
        // 1/3 ≈ 0.333...e18
        uint256 result = FixedPointMath.divFp(ONE, 3e18);
        assertApproxEqAbs(result, 333333333333333333, 1);
    }

    function test_divFp_revertsOnZero() public {
        vm.expectRevert();
        FixedPointMath.divFp(ONE, 0);
    }

    function test_mulDiv_basic() public pure {
        // 100 * 200 / 50 = 400
        assertEq(FixedPointMath.mulDiv(100, 200, 50), 400);
    }

    function test_mulDiv_largeNumbers() public pure {
        // (2^128) * (2^128) / (2^128) = 2^128  — would overflow naively
        uint256 big = 1 << 128;
        assertEq(FixedPointMath.mulDiv(big, big, big), big);
    }

    function test_abs_positive() public pure {
        assertEq(FixedPointMath.abs(int256(5e18)), 5e18);
    }

    function test_abs_negative() public pure {
        assertEq(FixedPointMath.abs(int256(-5e18)), 5e18);
    }

    function test_abs_zero() public pure {
        assertEq(FixedPointMath.abs(int256(0)), 0);
    }

    function test_mulFpSigned() public pure {
        // positive * positive
        assertEq(FixedPointMath.mulFpSigned(2e18, 3e18), 6e18);
        // negative * positive
        assertEq(FixedPointMath.mulFpSigned(-2e18, 3e18), -6e18);
        // negative * negative
        assertEq(FixedPointMath.mulFpSigned(-2e18, -3e18), 6e18);
    }

    function test_min() public pure {
        assertEq(FixedPointMath.min(3, 5), 3);
        assertEq(FixedPointMath.min(5, 3), 3);
        assertEq(FixedPointMath.min(3, 3), 3);
    }

    function test_max() public pure {
        assertEq(FixedPointMath.max(3, 5), 5);
        assertEq(FixedPointMath.max(5, 3), 5);
    }

    function test_clamp() public pure {
        assertEq(FixedPointMath.clamp(int256(5), int256(-10), int256(10)), int256(5));
        assertEq(FixedPointMath.clamp(int256(15), int256(-10), int256(10)), int256(10));
        assertEq(FixedPointMath.clamp(int256(-15), int256(-10), int256(10)), int256(-10));
    }
}
```

- [ ] **Step 1.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract FixedPointMathTest -vvv
```

Expected: compilation error, `FixedPointMath.sol` not found.

- [ ] **Step 1.3: Implement FixedPointMath**

`contracts/src/libraries/FixedPointMath.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library FixedPointMath {
    uint256 internal constant ONE = 1e18;

    function mulFp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, ONE);
    }

    function divFp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, ONE, b);
    }

    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return Math.mulDiv(a, b, c);
    }

    function mulFpSigned(int256 a, int256 b) internal pure returns (int256) {
        bool negative = (a < 0) != (b < 0);
        uint256 result = mulFp(abs(a), abs(b));
        return negative ? -int256(result) : int256(result);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(int256 value, int256 lower, int256 upper) internal pure returns (int256) {
        if (value < lower) return lower;
        if (value > upper) return upper;
        return value;
    }
}
```

- [ ] **Step 1.4: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract FixedPointMathTest -vvv
```

Expected: all tests PASS.

- [ ] **Step 1.5: Write fuzz tests**

`contracts/test/fuzz/FixedPointMath.fuzz.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/FixedPointMath.sol";

contract FixedPointMathFuzzTest is Test {
    // mulFp(a, ONE) == a
    function testFuzz_mulFp_identity(uint128 a) public pure {
        uint256 x = uint256(a);
        assertEq(FixedPointMath.mulFp(x, 1e18), x);
    }

    // mulFp is commutative
    function testFuzz_mulFp_commutative(uint128 a, uint128 b) public pure {
        uint256 x = uint256(a);
        uint256 y = uint256(b);
        assertEq(FixedPointMath.mulFp(x, y), FixedPointMath.mulFp(y, x));
    }

    // divFp(mulFp(a, b), b) ≈ a (within 1 wei rounding)
    function testFuzz_mulDiv_roundTrip(uint128 a, uint128 b) public pure {
        vm.assume(b > 0);
        uint256 x = uint256(a);
        uint256 y = uint256(b);
        uint256 product = FixedPointMath.mulFp(x, y);
        uint256 recovered = FixedPointMath.divFp(product, y);
        assertApproxEqAbs(recovered, x, 1);
    }

    // abs(-x) == abs(x)
    function testFuzz_abs_symmetric(int128 x) public pure {
        vm.assume(x != type(int128).min); // avoid -min overflow
        assertEq(FixedPointMath.abs(int256(x)), FixedPointMath.abs(int256(-x)));
    }
}
```

- [ ] **Step 1.6: Run fuzz tests**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract FixedPointMathFuzzTest -vvv
```

Expected: all pass (10,000 runs per fuzz test as configured).

- [ ] **Step 1.7: Commit**

```bash
git add contracts/src/libraries/FixedPointMath.sol contracts/test/unit/FixedPointMath.t.sol contracts/test/fuzz/FixedPointMath.fuzz.t.sol
git commit -m "feat(contracts): add FixedPointMath library with unit + fuzz tests"
```

---

## Task 2: BitmapLib Library

**Files:**
- Create: `contracts/src/libraries/BitmapLib.sol`
- Test: `contracts/test/unit/BitmapLib.t.sol`

- [ ] **Step 2.1: Write unit tests**

`contracts/test/unit/BitmapLib.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/BitmapLib.sol";

contract BitmapLibTest is Test {
    function test_setBit_and_isSet() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 0);
        assertTrue(BitmapLib.isSet(bitmap, 0));
        assertFalse(BitmapLib.isSet(bitmap, 1));
    }

    function test_setBit_multiple() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 5);
        bitmap = BitmapLib.setBit(bitmap, 100);
        bitmap = BitmapLib.setBit(bitmap, 255);
        assertTrue(BitmapLib.isSet(bitmap, 5));
        assertTrue(BitmapLib.isSet(bitmap, 100));
        assertTrue(BitmapLib.isSet(bitmap, 255));
        assertFalse(BitmapLib.isSet(bitmap, 6));
    }

    function test_clearBit() public pure {
        uint256 bitmap = BitmapLib.setBit(0, 42);
        assertTrue(BitmapLib.isSet(bitmap, 42));
        bitmap = BitmapLib.clearBit(bitmap, 42);
        assertFalse(BitmapLib.isSet(bitmap, 42));
    }

    function test_clearBit_noopIfNotSet() public pure {
        uint256 bitmap = 0;
        uint256 result = BitmapLib.clearBit(bitmap, 42);
        assertEq(result, 0);
    }

    function test_isEmpty() public pure {
        assertTrue(BitmapLib.isEmpty(0));
        assertFalse(BitmapLib.isEmpty(BitmapLib.setBit(0, 0)));
    }

    function test_findFirstSet_singleBit() public pure {
        uint256 bitmap = BitmapLib.setBit(0, 37);
        assertEq(BitmapLib.findFirstSet(bitmap), 37);
    }

    function test_findFirstSet_multipleBits() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 10);
        bitmap = BitmapLib.setBit(bitmap, 50);
        bitmap = BitmapLib.setBit(bitmap, 200);
        assertEq(BitmapLib.findFirstSet(bitmap), 10);
    }

    function test_findFirstSet_revertsOnEmpty() public {
        vm.expectRevert(BitmapLib.EmptyBitmap.selector);
        BitmapLib.findFirstSet(0);
    }

    function test_findLastSet_singleBit() public pure {
        uint256 bitmap = BitmapLib.setBit(0, 37);
        assertEq(BitmapLib.findLastSet(bitmap), 37);
    }

    function test_findLastSet_multipleBits() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 10);
        bitmap = BitmapLib.setBit(bitmap, 50);
        bitmap = BitmapLib.setBit(bitmap, 200);
        assertEq(BitmapLib.findLastSet(bitmap), 200);
    }

    function test_findLastSet_revertsOnEmpty() public {
        vm.expectRevert(BitmapLib.EmptyBitmap.selector);
        BitmapLib.findLastSet(0);
    }

    function test_findNextSet() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 10);
        bitmap = BitmapLib.setBit(bitmap, 50);
        bitmap = BitmapLib.setBit(bitmap, 200);
        // starting after 10, next set is 50
        (bool found, uint8 next) = BitmapLib.findNextSet(bitmap, 10);
        assertTrue(found);
        assertEq(next, 50);
        // starting after 50
        (found, next) = BitmapLib.findNextSet(bitmap, 50);
        assertTrue(found);
        assertEq(next, 200);
        // starting after 200 — nothing
        (found, ) = BitmapLib.findNextSet(bitmap, 200);
        assertFalse(found);
    }

    function test_findPrevSet() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 10);
        bitmap = BitmapLib.setBit(bitmap, 50);
        bitmap = BitmapLib.setBit(bitmap, 200);
        // starting before 200, prev is 50
        (bool found, uint8 prev) = BitmapLib.findPrevSet(bitmap, 200);
        assertTrue(found);
        assertEq(prev, 50);
        // starting before 50
        (found, prev) = BitmapLib.findPrevSet(bitmap, 50);
        assertTrue(found);
        assertEq(prev, 10);
        // starting before 10 — nothing
        (found, ) = BitmapLib.findPrevSet(bitmap, 10);
        assertFalse(found);
    }
}
```

- [ ] **Step 2.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract BitmapLibTest -vvv
```

Expected: compilation error.

- [ ] **Step 2.3: Implement BitmapLib**

`contracts/src/libraries/BitmapLib.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BitmapLib
/// @notice Single-word (256-bit) bitmap operations for price level tracking.
/// Two-level bitmap support is handled by the OrderBook contract, which uses
/// one bitmap as an index over multiple tick-level bitmaps.
library BitmapLib {
    error EmptyBitmap();

    function setBit(uint256 bitmap, uint8 index) internal pure returns (uint256) {
        return bitmap | (1 << index);
    }

    function clearBit(uint256 bitmap, uint8 index) internal pure returns (uint256) {
        return bitmap & ~(1 << index);
    }

    function isSet(uint256 bitmap, uint8 index) internal pure returns (bool) {
        return (bitmap & (1 << index)) != 0;
    }

    function isEmpty(uint256 bitmap) internal pure returns (bool) {
        return bitmap == 0;
    }

    /// @notice Find lowest set bit index (best ask / lowest tick with orders).
    function findFirstSet(uint256 bitmap) internal pure returns (uint8) {
        if (bitmap == 0) revert EmptyBitmap();
        // Least significant bit: isolate via x & (-x), then count trailing zeros
        uint256 isolated = bitmap & (~bitmap + 1);
        return uint8(_log2(isolated));
    }

    /// @notice Find highest set bit index (best bid / highest tick with orders).
    function findLastSet(uint256 bitmap) internal pure returns (uint8) {
        if (bitmap == 0) revert EmptyBitmap();
        return uint8(_log2HighBit(bitmap));
    }

    /// @notice Find next set bit strictly above `current`. Returns (found, index).
    function findNextSet(uint256 bitmap, uint8 current) internal pure returns (bool, uint8) {
        // Mask out current and all bits below it
        uint256 mask = type(uint256).max << (current + 1);
        uint256 masked = bitmap & mask;
        if (masked == 0) return (false, 0);
        return (true, findFirstSet(masked));
    }

    /// @notice Find previous set bit strictly below `current`. Returns (found, index).
    function findPrevSet(uint256 bitmap, uint8 current) internal pure returns (bool, uint8) {
        if (current == 0) return (false, 0);
        // Mask out current and all bits above it
        uint256 mask = (1 << current) - 1;
        uint256 masked = bitmap & mask;
        if (masked == 0) return (false, 0);
        return (true, findLastSet(masked));
    }

    /// @dev Floor log2 via binary search — returns position of the single set bit.
    function _log2(uint256 x) private pure returns (uint256 r) {
        // De Bruijn or binary search. Using binary search for clarity.
        if (x >= 1 << 128) { x >>= 128; r += 128; }
        if (x >= 1 << 64)  { x >>= 64;  r += 64; }
        if (x >= 1 << 32)  { x >>= 32;  r += 32; }
        if (x >= 1 << 16)  { x >>= 16;  r += 16; }
        if (x >= 1 << 8)   { x >>= 8;   r += 8; }
        if (x >= 1 << 4)   { x >>= 4;   r += 4; }
        if (x >= 1 << 2)   { x >>= 2;   r += 2; }
        if (x >= 1 << 1)   { r += 1; }
    }

    /// @dev Highest set bit position.
    function _log2HighBit(uint256 x) private pure returns (uint256) {
        return _log2(x);
    }
}
```

- [ ] **Step 2.4: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract BitmapLibTest -vvv
```

Expected: all PASS.

- [ ] **Step 2.5: Commit**

```bash
git add contracts/src/libraries/BitmapLib.sol contracts/test/unit/BitmapLib.t.sol
git commit -m "feat(contracts): add BitmapLib with 256-bit bitmap operations"
```

---

## Task 3: PackedOrder Library

**Files:**
- Create: `contracts/src/libraries/PackedOrder.sol`
- Test: `contracts/test/unit/PackedOrder.t.sol`
- Fuzz: `contracts/test/fuzz/PackedOrder.fuzz.t.sol`

- [ ] **Step 3.1: Write unit tests**

`contracts/test/unit/PackedOrder.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/PackedOrder.sol";

contract PackedOrderTest is Test {
    function test_packUnpack_roundTrip() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(0xBEEF),
            orderId: 42,
            timestamp: uint32(block.timestamp),
            side: true, // buy
            orderType: 1, // limit
            reduceOnly: false,
            price: 60_000e18,
            size: 1e18
        });
        (bytes32 slot0, bytes32 slot1) = PackedOrder.pack(order);
        PackedOrder.Order memory unpacked = PackedOrder.unpack(slot0, slot1);

        assertEq(unpacked.owner, order.owner);
        assertEq(unpacked.orderId, order.orderId);
        assertEq(unpacked.timestamp, order.timestamp);
        assertEq(unpacked.side, order.side);
        assertEq(unpacked.orderType, order.orderType);
        assertEq(unpacked.reduceOnly, order.reduceOnly);
        assertEq(unpacked.price, order.price);
        assertEq(unpacked.size, order.size);
    }

    function test_getPrice() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(1),
            orderId: 1,
            timestamp: 1000,
            side: true,
            orderType: 0,
            reduceOnly: false,
            price: 50_000e18,
            size: 2e18
        });
        (, bytes32 slot1) = PackedOrder.pack(order);
        assertEq(PackedOrder.getPrice(slot1), 50_000e18);
    }

    function test_getSize() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(1),
            orderId: 1,
            timestamp: 1000,
            side: false,
            orderType: 0,
            reduceOnly: false,
            price: 50_000e18,
            size: 3e18
        });
        (, bytes32 slot1) = PackedOrder.pack(order);
        assertEq(PackedOrder.getSize(slot1), 3e18);
    }

    function test_getSide() public pure {
        PackedOrder.Order memory buyOrder = PackedOrder.Order({
            owner: address(1), orderId: 1, timestamp: 1000,
            side: true, orderType: 0, reduceOnly: false,
            price: 1e18, size: 1e18
        });
        (bytes32 slot0, ) = PackedOrder.pack(buyOrder);
        assertTrue(PackedOrder.getSide(slot0));

        PackedOrder.Order memory sellOrder = PackedOrder.Order({
            owner: address(1), orderId: 2, timestamp: 1000,
            side: false, orderType: 0, reduceOnly: false,
            price: 1e18, size: 1e18
        });
        (slot0, ) = PackedOrder.pack(sellOrder);
        assertFalse(PackedOrder.getSide(slot0));
    }

    function test_getOwner() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(0xCAFE), orderId: 99, timestamp: 5000,
            side: true, orderType: 2, reduceOnly: true,
            price: 100e18, size: 10e18
        });
        (bytes32 slot0, ) = PackedOrder.pack(order);
        assertEq(PackedOrder.getOwner(slot0), address(0xCAFE));
    }

    function test_setSize() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(1), orderId: 1, timestamp: 1000,
            side: true, orderType: 0, reduceOnly: false,
            price: 50_000e18, size: 10e18
        });
        (, bytes32 slot1) = PackedOrder.pack(order);
        bytes32 newSlot1 = PackedOrder.setSize(slot1, 7e18);
        assertEq(PackedOrder.getSize(newSlot1), 7e18);
        assertEq(PackedOrder.getPrice(newSlot1), 50_000e18); // price unchanged
    }
}
```

- [ ] **Step 3.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract PackedOrderTest -vvv
```

Expected: compilation error.

- [ ] **Step 3.3: Implement PackedOrder**

`contracts/src/libraries/PackedOrder.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PackedOrder
/// @notice Packs/unpacks order data into two 256-bit storage slots.
///
/// Slot 0 layout (256 bits):
///   [0:159]   owner address (160 bits)
///   [160:191] orderId (32 bits)
///   [192:223] timestamp (32 bits)
///   [224:231] orderFlags: side[1] | orderType[3] | reduceOnly[1] | unused[3]
///   [232:255] reserved (24 bits)
///
/// Slot 1 layout (256 bits):
///   [0:127]   price (128 bits, 18-decimal fixed-point)
///   [128:255] size (128 bits, 18-decimal fixed-point)
library PackedOrder {
    struct Order {
        address owner;
        uint32 orderId;
        uint32 timestamp;
        bool side;          // true = buy/long
        uint8 orderType;    // 0=market, 1=limit, 2=IOC, 3=FOK
        bool reduceOnly;
        uint256 price;      // 18-decimal
        uint256 size;       // 18-decimal
    }

    function pack(Order memory order) internal pure returns (bytes32 slot0, bytes32 slot1) {
        uint8 flags = (order.side ? 1 : 0)
            | (uint8(order.orderType & 0x07) << 1)
            | (order.reduceOnly ? 1 << 4 : 0);

        slot0 = bytes32(
            uint256(uint160(order.owner))
            | (uint256(order.orderId) << 160)
            | (uint256(order.timestamp) << 192)
            | (uint256(flags) << 224)
        );

        slot1 = bytes32(
            uint256(uint128(order.price))
            | (uint256(uint128(order.size)) << 128)
        );
    }

    function unpack(bytes32 slot0, bytes32 slot1) internal pure returns (Order memory order) {
        uint256 s0 = uint256(slot0);
        uint256 s1 = uint256(slot1);
        uint8 flags = uint8(s0 >> 224);

        order.owner = address(uint160(s0));
        order.orderId = uint32(s0 >> 160);
        order.timestamp = uint32(s0 >> 192);
        order.side = (flags & 1) == 1;
        order.orderType = (flags >> 1) & 0x07;
        order.reduceOnly = (flags >> 4) & 1 == 1;
        order.price = uint128(s1);
        order.size = uint128(s1 >> 128);
    }

    function getPrice(bytes32 slot1) internal pure returns (uint256) {
        return uint128(uint256(slot1));
    }

    function getSize(bytes32 slot1) internal pure returns (uint256) {
        return uint128(uint256(slot1) >> 128);
    }

    function getSide(bytes32 slot0) internal pure returns (bool) {
        return (uint256(slot0) >> 224) & 1 == 1;
    }

    function getOwner(bytes32 slot0) internal pure returns (address) {
        return address(uint160(uint256(slot0)));
    }

    function setSize(bytes32 slot1, uint256 newSize) internal pure returns (bytes32) {
        uint256 s1 = uint256(slot1);
        // Clear upper 128 bits, set new size
        s1 = (s1 & type(uint128).max) | (uint256(uint128(newSize)) << 128);
        return bytes32(s1);
    }
}
```

- [ ] **Step 3.4: Run unit tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract PackedOrderTest -vvv
```

Expected: all PASS.

- [ ] **Step 3.5: Write fuzz test for pack/unpack round-trip**

`contracts/test/fuzz/PackedOrder.fuzz.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/PackedOrder.sol";

contract PackedOrderFuzzTest is Test {
    function testFuzz_packUnpack_roundTrip(
        address owner,
        uint32 orderId,
        uint32 timestamp,
        bool side,
        uint8 orderType,
        bool reduceOnly,
        uint128 price,
        uint128 size
    ) public pure {
        orderType = orderType % 4; // 0..3

        PackedOrder.Order memory original = PackedOrder.Order({
            owner: owner,
            orderId: orderId,
            timestamp: timestamp,
            side: side,
            orderType: orderType,
            reduceOnly: reduceOnly,
            price: uint256(price),
            size: uint256(size)
        });

        (bytes32 slot0, bytes32 slot1) = PackedOrder.pack(original);
        PackedOrder.Order memory recovered = PackedOrder.unpack(slot0, slot1);

        assertEq(recovered.owner, original.owner);
        assertEq(recovered.orderId, original.orderId);
        assertEq(recovered.timestamp, original.timestamp);
        assertEq(recovered.side, original.side);
        assertEq(recovered.orderType, original.orderType);
        assertEq(recovered.reduceOnly, original.reduceOnly);
        assertEq(recovered.price, original.price);
        assertEq(recovered.size, original.size);
    }
}
```

- [ ] **Step 3.6: Run fuzz tests**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract PackedOrderFuzzTest -vvv
```

Expected: PASS (10,000 runs).

- [ ] **Step 3.7: Commit**

```bash
git add contracts/src/libraries/PackedOrder.sol contracts/test/unit/PackedOrder.t.sol contracts/test/fuzz/PackedOrder.fuzz.t.sol
git commit -m "feat(contracts): add PackedOrder library with bit-packing into 2 slots"
```

---

## Task 4: TickMath Library

**Files:**
- Create: `contracts/src/libraries/TickMath.sol`
- Test: `contracts/test/unit/TickMath.t.sol`

- [ ] **Step 4.1: Write unit tests**

`contracts/test/unit/TickMath.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/TickMath.sol";

contract TickMathTest is Test {
    // BTC: price $60,000, tickSize $0.10
    // tickIndex = 60_000e18 / 0.1e18 = 600_000
    function test_priceToTick_btc() public pure {
        uint256 price = 60_000e18;
        uint256 tickSize = 0.1e18; // $0.10
        assertEq(TickMath.priceToTick(price, tickSize), 600_000);
    }

    function test_tickToPrice_btc() public pure {
        uint256 tickSize = 0.1e18;
        assertEq(TickMath.tickToPrice(600_000, tickSize), 60_000e18);
    }

    function test_roundTrip() public pure {
        uint256 tickSize = 0.01e18;
        uint256 price = 3_500.05e18; // $3,500.05
        uint256 tick = TickMath.priceToTick(price, tickSize);
        uint256 recovered = TickMath.tickToPrice(tick, tickSize);
        assertEq(recovered, price);
    }

    function test_priceToTick_unaligned_reverts() public {
        uint256 tickSize = 0.1e18;
        uint256 unalignedPrice = 60_000.05e18; // not aligned to $0.10
        vm.expectRevert(TickMath.PriceNotAligned.selector);
        TickMath.priceToTick(unalignedPrice, tickSize);
    }

    function test_priceToTick_zero_reverts() public {
        vm.expectRevert(TickMath.ZeroPrice.selector);
        TickMath.priceToTick(0, 0.1e18);
    }

    function test_tickToPrice_zeroTick() public pure {
        // Tick 0 is price 0 — this shouldn't happen in practice, but the math is valid
        assertEq(TickMath.tickToPrice(0, 0.1e18), 0);
    }

    function test_alignPrice() public pure {
        uint256 tickSize = 0.1e18;
        // $60,000.15 rounds down to $60,000.10
        assertEq(TickMath.alignPrice(60_000.15e18, tickSize), 60_000.1e18);
    }

    function test_isAligned() public pure {
        uint256 tickSize = 0.1e18;
        assertTrue(TickMath.isAligned(60_000e18, tickSize));
        assertTrue(TickMath.isAligned(60_000.1e18, tickSize));
        assertFalse(TickMath.isAligned(60_000.05e18, tickSize));
    }

    // Two-level bitmap helpers
    function test_tickToWordAndBit() public pure {
        // Tick 300 = word 1 (300 / 256 = 1), bit 44 (300 % 256 = 44)
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(300);
        assertEq(word, 1);
        assertEq(bit, 44);
    }

    function test_tickToWordAndBit_zero() public pure {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(0);
        assertEq(word, 0);
        assertEq(bit, 0);
    }

    function test_wordAndBitToTick() public pure {
        assertEq(TickMath.wordAndBitToTick(1, 44), 300);
    }
}
```

- [ ] **Step 4.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract TickMathTest -vvv
```

Expected: compilation error.

- [ ] **Step 4.3: Implement TickMath**

`contracts/src/libraries/TickMath.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TickMath
/// @notice Converts between 18-decimal prices and integer tick indices.
/// tickIndex = price / tickSize (integer division, must be exact).
library TickMath {
    error PriceNotAligned();
    error ZeroPrice();

    function priceToTick(uint256 price, uint256 tickSize) internal pure returns (uint256) {
        if (price == 0) revert ZeroPrice();
        if (price % tickSize != 0) revert PriceNotAligned();
        return price / tickSize;
    }

    function tickToPrice(uint256 tickIndex, uint256 tickSize) internal pure returns (uint256) {
        return tickIndex * tickSize;
    }

    function alignPrice(uint256 price, uint256 tickSize) internal pure returns (uint256) {
        return (price / tickSize) * tickSize;
    }

    function isAligned(uint256 price, uint256 tickSize) internal pure returns (bool) {
        return price % tickSize == 0;
    }

    /// @notice Split a tick index into its two-level bitmap coordinates.
    /// word = tick / 256, bit = tick % 256
    function tickToWordAndBit(uint256 tick) internal pure returns (uint256 word, uint8 bit) {
        word = tick >> 8;    // tick / 256
        bit = uint8(tick & 0xFF); // tick % 256
    }

    function wordAndBitToTick(uint256 word, uint8 bit) internal pure returns (uint256) {
        return (word << 8) | uint256(bit);
    }
}
```

- [ ] **Step 4.4: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract TickMathTest -vvv
```

Expected: all PASS.

- [ ] **Step 4.5: Commit**

```bash
git add contracts/src/libraries/TickMath.sol contracts/test/unit/TickMath.t.sol
git commit -m "feat(contracts): add TickMath for price↔tick conversion with two-level bitmap support"
```

---

## Task 5: Mock Contracts

**Files:**
- Create: `contracts/test/mocks/MockERC20.sol`
- Create: `contracts/test/mocks/MockPyth.sol`

- [ ] **Step 5.1: Create MockERC20 (USDC)**

`contracts/test/mocks/MockERC20.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC with 6 decimals and public mint.
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```

- [ ] **Step 5.2: Create MockPyth**

`contracts/test/mocks/MockPyth.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Minimal mock of the Pyth Network contract for testing.
/// Stores prices set by the test and returns them on query.
contract MockPyth {
    struct PriceData {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => PriceData) public prices;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo) external {
        prices[id] = PriceData({
            price: price,
            conf: conf,
            expo: expo,
            publishTime: block.timestamp
        });
    }

    function setPriceWithTimestamp(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 ts) external {
        prices[id] = PriceData({
            price: price,
            conf: conf,
            expo: expo,
            publishTime: ts
        });
    }

    /// @dev Mimics IPyth.getPriceNoOlderThan
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PriceData memory) {
        PriceData memory p = prices[id];
        require(p.publishTime >= block.timestamp - age, "stale price");
        require(p.price > 0, "invalid price");
        return p;
    }

    /// @dev Mimics IPyth.getPriceUnsafe (no staleness check)
    function getPriceUnsafe(bytes32 id) external view returns (PriceData memory) {
        return prices[id];
    }

    /// @dev Mimics IPyth.updatePriceFeeds
    function updatePriceFeeds(bytes[] calldata) external payable {
        // no-op in mock — tests set prices directly
    }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }
}
```

- [ ] **Step 5.3: Verify mocks compile**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge build
```

Expected: success.

- [ ] **Step 5.4: Commit**

```bash
git add contracts/test/mocks/MockERC20.sol contracts/test/mocks/MockPyth.sol
git commit -m "test: add MockERC20 (USDC) and MockPyth for contract testing"
```

---

## Task 6: Interfaces

**Files:**
- Create: `contracts/src/interfaces/IVault.sol`
- Create: `contracts/src/interfaces/IOracleAdapter.sol`
- Create: `contracts/src/interfaces/IMarginEngine.sol`
- Create: `contracts/src/interfaces/IOrderBook.sol`

- [ ] **Step 6.1: Create IVault**

`contracts/src/interfaces/IVault.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;

    function balances(address account) external view returns (uint256);
    function lockedMargin(address account) external view returns (uint256);
    function orderMargin(address account) external view returns (uint256);
    function insuranceFund() external view returns (uint256);
    function totalDeposits() external view returns (uint256);

    function lockMargin(address account, uint256 amount) external;
    function unlockMargin(address account, uint256 amount) external;
    function lockOrderMargin(address account, uint256 amount) external;
    function unlockOrderMargin(address account, uint256 amount) external;
    function transferToInsuranceFund(uint256 amount) external;
    function drawFromInsuranceFund(uint256 amount) external;
    function realizePnl(address account, int256 pnl) external;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event MarginLocked(address indexed account, uint256 amount);
    event MarginUnlocked(address indexed account, uint256 amount);
    event OrderMarginLocked(address indexed account, uint256 amount);
    event OrderMarginUnlocked(address indexed account, uint256 amount);
    event PnlRealized(address indexed account, int256 amount);
}
```

- [ ] **Step 6.2: Create IOracleAdapter**

`contracts/src/interfaces/IOracleAdapter.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracleAdapter {
    function getMarkPrice(uint256 marketId) external view returns (uint256);
    function getIndexPrice(uint256 marketId) external view returns (uint256);
    function updatePrice(uint256 marketId, bytes[] calldata priceUpdateData) external payable;
    function setMarketOracle(uint256 marketId, bytes32 pythPriceId, uint256 stalenessThreshold) external;

    event PriceUpdated(uint256 indexed marketId, uint256 price, uint256 timestamp);
}
```

- [ ] **Step 6.3: Create IMarginEngine**

`contracts/src/interfaces/IMarginEngine.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMarginEngine {
    struct MarketConfig {
        uint256 maxLeverage;
        uint256 initialMarginRate;
        uint256 maintenanceMarginRate;
        uint256 tickSize;
        uint256 lotSize;
        uint256 maxOrderSize;
        uint256 minOrderSize;
    }

    function configs(uint256 marketId) external view returns (
        uint256 maxLeverage,
        uint256 initialMarginRate,
        uint256 maintenanceMarginRate,
        uint256 tickSize,
        uint256 lotSize,
        uint256 maxOrderSize,
        uint256 minOrderSize
    );

    function setMarketConfig(uint256 marketId, MarketConfig calldata config) external;
    function checkInitialMargin(address account, uint256 marketId, uint256 orderSize, uint256 price) external view returns (bool);
    function getAvailableMargin(address account) external view returns (uint256);
    function getRequiredMargin(uint256 marketId, uint256 size, uint256 price) external view returns (uint256);
}
```

- [ ] **Step 6.4: Create IOrderBook**

`contracts/src/interfaces/IOrderBook.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOrderBook {
    function placeOrder(
        address trader,
        bool side,
        uint256 price,
        uint256 size,
        uint8 orderType
    ) external returns (uint256 orderId);

    function cancelOrder(uint256 orderId) external;

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
}
```

- [ ] **Step 6.5: Verify interfaces compile**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge build
```

Expected: success.

- [ ] **Step 6.6: Commit**

```bash
git add contracts/src/interfaces/
git commit -m "feat(contracts): add IVault, IOracleAdapter, IMarginEngine, IOrderBook interfaces"
```

---

## Task 7: Vault Contract

**Files:**
- Create: `contracts/src/Vault.sol`
- Test: `contracts/test/unit/Vault.t.sol`

- [ ] **Step 7.1: Write unit tests**

`contracts/test/unit/Vault.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/Vault.sol";
import "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultTest is Test {
    Vault public vault;
    MockERC20 public usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public authorized = makeAddr("authorized");
    address public admin = makeAddr("admin");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy behind UUPS proxy
        Vault impl = new Vault();
        bytes memory initData = abi.encodeCall(Vault.initialize, (address(usdc), admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = Vault(address(proxy));

        // Grant authorized role
        vm.prank(admin);
        vault.grantAuthorized(authorized);

        // Fund alice with 10,000 USDC (6 decimals)
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_deposit() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        // Internal balance is 18-decimal: 1_000e6 * 1e12 = 1_000e18
        assertEq(vault.balances(alice), 1_000e18);
        assertEq(vault.totalDeposits(), 1_000e18);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_withdraw() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(alice);
        vault.withdraw(500e18); // withdraw 500 in 18-dec

        assertEq(vault.balances(alice), 500e18);
        assertEq(usdc.balanceOf(alice), 9_500e6); // started with 10k, deposited 1k, withdrew 500
    }

    function test_withdraw_moreThanBalance_reverts() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(alice);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.withdraw(1_001e18);
    }

    function test_lockMargin_onlyAuthorized() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.lockMargin(alice, 500e18);
        assertEq(vault.balances(alice), 500e18);
        assertEq(vault.lockedMargin(alice), 500e18);
    }

    function test_lockMargin_unauthorized_reverts() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(bob);
        vm.expectRevert();
        vault.lockMargin(alice, 500e18);
    }

    function test_unlockMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.lockMargin(alice, 500e18);

        vm.prank(authorized);
        vault.unlockMargin(alice, 200e18);

        assertEq(vault.balances(alice), 700e18);
        assertEq(vault.lockedMargin(alice), 300e18);
    }

    function test_lockOrderMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.lockOrderMargin(alice, 300e18);

        assertEq(vault.balances(alice), 700e18);
        assertEq(vault.orderMargin(alice), 300e18);
    }

    function test_unlockOrderMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.lockOrderMargin(alice, 300e18);

        vm.prank(authorized);
        vault.unlockOrderMargin(alice, 300e18);

        assertEq(vault.balances(alice), 1_000e18);
        assertEq(vault.orderMargin(alice), 0);
    }

    function test_realizePnl_profit() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.realizePnl(alice, int256(200e18));

        assertEq(vault.balances(alice), 1_200e18);
    }

    function test_realizePnl_loss() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.realizePnl(alice, -int256(200e18));

        assertEq(vault.balances(alice), 800e18);
    }

    function test_transferToInsuranceFund() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.realizePnl(alice, -int256(100e18)); // take 100 from alice
        // In practice, insurance fund fees come from specific flows.
        // For this test, just transfer from alice's balance:
        vm.prank(authorized);
        vault.lockMargin(alice, 100e18);
        vm.prank(authorized);
        vault.transferToInsuranceFund(100e18);

        assertEq(vault.insuranceFund(), 100e18);
    }

    function test_cannotWithdraw_lockedMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(authorized);
        vault.lockMargin(alice, 800e18);

        // Only 200 free
        vm.prank(alice);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.withdraw(300e18);

        // 200 should work
        vm.prank(alice);
        vault.withdraw(200e18);
        assertEq(vault.balances(alice), 0);
    }
}
```

- [ ] **Step 7.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract VaultTest -vvv
```

Expected: compilation error, Vault.sol not found.

- [ ] **Step 7.3: Implement Vault**

`contracts/src/Vault.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IVault} from "./interfaces/IVault.sol";

contract Vault is IVault, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant AUTHORIZED_ROLE = keccak256("AUTHORIZED_ROLE");

    /// @dev USDC uses 6 decimals; internal accounting uses 18. Scale factor = 1e12.
    uint256 internal constant DECIMAL_SCALE = 1e12;

    error InsufficientBalance();
    error InsufficientLockedMargin();
    error InsufficientOrderMargin();
    error InsufficientInsuranceFund();
    error ZeroAmount();

    IERC20 public usdc;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lockedMargin;
    mapping(address => uint256) public orderMargin;
    uint256 public insuranceFund;
    uint256 public totalDeposits;

    uint256[50] private __gap;

    function initialize(address _usdc, address _admin) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        usdc = IERC20(_usdc);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function grantAuthorized(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(AUTHORIZED_ROLE, account);
    }

    function deposit(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 internalAmount = usdcAmount * DECIMAL_SCALE;

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        balances[msg.sender] += internalAmount;
        totalDeposits += internalAmount;

        emit Deposited(msg.sender, internalAmount);
    }

    function withdraw(uint256 internalAmount) external nonReentrant {
        if (internalAmount == 0) revert ZeroAmount();
        if (balances[msg.sender] < internalAmount) revert InsufficientBalance();

        balances[msg.sender] -= internalAmount;
        totalDeposits -= internalAmount;
        uint256 usdcAmount = internalAmount / DECIMAL_SCALE;

        usdc.safeTransfer(msg.sender, usdcAmount);

        emit Withdrawn(msg.sender, internalAmount);
    }

    function lockMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (balances[account] < amount) revert InsufficientBalance();
        balances[account] -= amount;
        lockedMargin[account] += amount;
        emit MarginLocked(account, amount);
    }

    function unlockMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (lockedMargin[account] < amount) revert InsufficientLockedMargin();
        lockedMargin[account] -= amount;
        balances[account] += amount;
        emit MarginUnlocked(account, amount);
    }

    function lockOrderMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (balances[account] < amount) revert InsufficientBalance();
        balances[account] -= amount;
        orderMargin[account] += amount;
        emit OrderMarginLocked(account, amount);
    }

    function unlockOrderMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (orderMargin[account] < amount) revert InsufficientOrderMargin();
        orderMargin[account] -= amount;
        balances[account] += amount;
        emit OrderMarginUnlocked(account, amount);
    }

    function transferToInsuranceFund(uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        insuranceFund += amount;
    }

    function drawFromInsuranceFund(uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (insuranceFund < amount) revert InsufficientInsuranceFund();
        insuranceFund -= amount;
    }

    function realizePnl(address account, int256 pnl) external onlyRole(AUTHORIZED_ROLE) {
        if (pnl >= 0) {
            balances[account] += uint256(pnl);
            totalDeposits += uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            if (balances[account] >= loss) {
                balances[account] -= loss;
            } else {
                // Loss exceeds free balance — take from locked margin as well
                uint256 remaining = loss - balances[account];
                balances[account] = 0;
                lockedMargin[account] -= remaining;
            }
            totalDeposits -= loss;
        }
        emit PnlRealized(account, pnl);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
```

- [ ] **Step 7.4: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract VaultTest -vvv
```

Expected: all PASS.

- [ ] **Step 7.5: Commit**

```bash
git add contracts/src/Vault.sol contracts/test/unit/Vault.t.sol
git commit -m "feat(contracts): add Vault with USDC deposit/withdraw, margin locking, UUPS proxy"
```

---

## Task 8: OracleAdapter Contract

**Files:**
- Create: `contracts/src/OracleAdapter.sol`
- Test: `contracts/test/unit/OracleAdapter.t.sol`

- [ ] **Step 8.1: Write unit tests**

`contracts/test/unit/OracleAdapter.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/OracleAdapter.sol";
import "../mocks/MockPyth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract OracleAdapterTest is Test {
    OracleAdapter public oracle;
    MockPyth public mockPyth;
    address public admin = makeAddr("admin");
    uint256 public constant MARKET_BTC = 0;
    bytes32 public constant BTC_PYTH_ID = bytes32(uint256(1));

    function setUp() public {
        mockPyth = new MockPyth();

        OracleAdapter impl = new OracleAdapter();
        bytes memory initData = abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        oracle = OracleAdapter(address(proxy));

        // Configure BTC market
        vm.prank(admin);
        oracle.setMarketOracle(MARKET_BTC, BTC_PYTH_ID, 60); // 60s staleness

        // Set a valid BTC price: $60,000 with expo=-8
        // Pyth stores price as int64 with exponent. $60,000 = 6000000000000 * 10^(-8)
        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 60_000_000, -8);
    }

    function test_getIndexPrice() public view {
        uint256 price = oracle.getIndexPrice(MARKET_BTC);
        assertEq(price, 60_000e18);
    }

    function test_getMarkPrice_noOrderbook() public view {
        // No orderbook set → markPrice = oraclePrice
        uint256 price = oracle.getMarkPrice(MARKET_BTC);
        assertEq(price, 60_000e18);
    }

    function test_stalePrice_reverts() public {
        // Advance time past staleness threshold
        vm.warp(block.timestamp + 120);

        vm.expectRevert();
        oracle.getIndexPrice(MARKET_BTC);
    }

    function test_confidenceBand_tooWide_reverts() public {
        // Set conf > 1% of price. price=60000e8, 1% = 600e8.
        // conf = 700e8 > 1% → should revert
        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 70_000_000_000, -8);

        vm.expectRevert(OracleAdapter.ConfidenceTooWide.selector);
        oracle.getIndexPrice(MARKET_BTC);
    }

    function test_negativePrice_reverts() public {
        mockPyth.setPrice(BTC_PYTH_ID, -100, 1, -8);

        vm.expectRevert();
        oracle.getIndexPrice(MARKET_BTC);
    }

    function test_setOrderBook() public {
        address mockOB = makeAddr("orderbook");
        vm.prank(admin);
        oracle.setOrderBook(MARKET_BTC, mockOB);
        // After setting orderbook, getMarkPrice should blend (but mock OB returns 0 for best bid/ask)
        // With zero mid-price, mark price falls back to oracle only
        uint256 price = oracle.getMarkPrice(MARKET_BTC);
        assertEq(price, 60_000e18);
    }
}
```

- [ ] **Step 8.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract OracleAdapterTest -vvv
```

Expected: compilation error.

- [ ] **Step 8.3: Implement OracleAdapter**

`contracts/src/OracleAdapter.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";
import {TickMath} from "./libraries/TickMath.sol";

interface IMockPyth {
    struct PriceData {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PriceData memory);
    function updatePriceFeeds(bytes[] calldata data) external payable;
    function getUpdateFee(bytes[] calldata data) external view returns (uint256);
}

contract OracleAdapter is IOracleAdapter, UUPSUpgradeable, AccessControlUpgradeable {
    error StalePrice();
    error NegativePrice();
    error ConfidenceTooWide();
    error MarketNotConfigured();

    /// @dev Max confidence / price ratio: 1% = 1e16 in 18-dec
    uint256 internal constant MAX_CONFIDENCE_RATIO = 1e16;

    struct MarketOracle {
        bytes32 pythPriceId;
        uint256 stalenessThreshold;
    }

    IMockPyth public pyth;

    mapping(uint256 => MarketOracle) public marketOracles;
    mapping(uint256 => address) public orderBooks; // marketId → OrderBook (for mid-price)
    mapping(uint256 => uint256) public tickSizes;  // cached from MarginEngine config

    uint256[50] private __gap;

    function initialize(address _pyth, address _admin) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        pyth = IMockPyth(_pyth);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setMarketOracle(uint256 marketId, bytes32 pythPriceId, uint256 stalenessThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        marketOracles[marketId] = MarketOracle(pythPriceId, stalenessThreshold);
    }

    function setOrderBook(uint256 marketId, address orderBook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        orderBooks[marketId] = orderBook;
    }

    function setTickSize(uint256 marketId, uint256 tickSize) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tickSizes[marketId] = tickSize;
    }

    function getIndexPrice(uint256 marketId) public view returns (uint256) {
        return _getOraclePrice(marketId);
    }

    function getMarkPrice(uint256 marketId) public view returns (uint256) {
        uint256 oraclePrice = _getOraclePrice(marketId);

        address ob = orderBooks[marketId];
        if (ob == address(0)) return oraclePrice;

        uint256 tickSize = tickSizes[marketId];
        if (tickSize == 0) return oraclePrice;

        // Try to get mid-price from orderbook
        uint256 bestBid = IOrderBook(ob).bestBidTick();
        uint256 bestAsk = IOrderBook(ob).bestAskTick();

        if (bestBid == 0 || bestAsk == 0) return oraclePrice;

        uint256 bidPrice = TickMath.tickToPrice(bestBid, tickSize);
        uint256 askPrice = TickMath.tickToPrice(bestAsk, tickSize);
        uint256 midPrice = (bidPrice + askPrice) / 2;

        if (midPrice == 0) return oraclePrice;

        // Blend: 70% oracle + 30% orderbook mid
        return FixedPointMath.mulFp(oraclePrice, 0.7e18) + FixedPointMath.mulFp(midPrice, 0.3e18);
    }

    function updatePrice(uint256 marketId, bytes[] calldata priceUpdateData) external payable {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);
        emit PriceUpdated(marketId, _getOraclePrice(marketId), block.timestamp);
    }

    function _getOraclePrice(uint256 marketId) internal view returns (uint256) {
        MarketOracle memory mo = marketOracles[marketId];
        if (mo.pythPriceId == bytes32(0)) revert MarketNotConfigured();

        IMockPyth.PriceData memory p = pyth.getPriceNoOlderThan(mo.pythPriceId, mo.stalenessThreshold);

        if (p.price <= 0) revert NegativePrice();

        // Check confidence band: conf/price < 1%
        uint256 absPrice = uint256(uint64(p.price));
        uint256 confRatio = (uint256(p.conf) * 1e18) / absPrice;
        if (confRatio > MAX_CONFIDENCE_RATIO) revert ConfidenceTooWide();

        // Convert Pyth price to 18-decimal
        return _pythTo18Dec(p.price, p.expo);
    }

    /// @dev Convert Pyth price (int64 * 10^expo) to 18-decimal uint256.
    function _pythTo18Dec(int64 price, int32 expo) internal pure returns (uint256) {
        uint256 absPrice = uint256(uint64(price));
        if (expo >= 0) {
            return absPrice * (10 ** uint32(expo)) * 1e18;
        } else {
            uint32 negExpo = uint32(-expo);
            if (negExpo <= 18) {
                return absPrice * (10 ** (18 - negExpo));
            } else {
                return absPrice / (10 ** (negExpo - 18));
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
```

- [ ] **Step 8.4: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract OracleAdapterTest -vvv
```

Expected: all PASS.

- [ ] **Step 8.5: Commit**

```bash
git add contracts/src/OracleAdapter.sol contracts/test/unit/OracleAdapter.t.sol
git commit -m "feat(contracts): add OracleAdapter wrapping Pyth with staleness + confidence checks"
```

---

## Task 9: MarginEngine Contract

**Files:**
- Create: `contracts/src/MarginEngine.sol`
- Test: `contracts/test/unit/MarginEngine.t.sol`

- [ ] **Step 9.1: Write unit tests**

`contracts/test/unit/MarginEngine.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/MarginEngine.sol";
import "../../src/Vault.sol";
import "../../src/OracleAdapter.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPyth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";

contract MarginEngineTest is Test {
    MarginEngine public engine;
    Vault public vault;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    uint256 public constant MARKET_BTC = 0;
    bytes32 public constant BTC_PYTH_ID = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        // Deploy Vault
        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl), abi.encodeCall(Vault.initialize, (address(usdc), admin))
        );
        vault = Vault(address(vaultProxy));

        // Deploy OracleAdapter
        OracleAdapter oracleImpl = new OracleAdapter();
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
        );
        oracle = OracleAdapter(address(oracleProxy));

        // Deploy MarginEngine
        MarginEngine engineImpl = new MarginEngine();
        ERC1967Proxy engineProxy = new ERC1967Proxy(
            address(engineImpl), abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
        );
        engine = MarginEngine(address(engineProxy));

        // Grant MarginEngine authorized role on Vault
        vm.prank(admin);
        vault.grantAuthorized(address(engine));

        // Configure BTC market: 50x leverage, IMR=2%, MMR=1%, tickSize=$0.10, lotSize=0.00001
        vm.prank(admin);
        engine.setMarketConfig(MARKET_BTC, IMarginEngine.MarketConfig({
            maxLeverage: 50e18,
            initialMarginRate: 2e16,  // 2%
            maintenanceMarginRate: 1e16, // 1%
            tickSize: 0.1e18,
            lotSize: 0.00001e18,
            maxOrderSize: 100e18,
            minOrderSize: 0.001e18
        }));

        // Set BTC price: $60,000
        vm.prank(admin);
        oracle.setMarketOracle(MARKET_BTC, BTC_PYTH_ID, 60);
        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

        // Fund alice: 10,000 USDC
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(10_000e6);
    }

    function test_getRequiredMargin() public view {
        // 1 BTC at $60,000 with 2% IMR = $1,200
        uint256 margin = engine.getRequiredMargin(MARKET_BTC, 1e18, 60_000e18);
        assertEq(margin, 1_200e18);
    }

    function test_getRequiredMargin_small() public view {
        // 0.01 BTC at $60,000 with 2% IMR = $12
        uint256 margin = engine.getRequiredMargin(MARKET_BTC, 0.01e18, 60_000e18);
        assertEq(margin, 12e18);
    }

    function test_getAvailableMargin() public view {
        // Alice has 10,000 USDC, nothing locked
        assertEq(engine.getAvailableMargin(alice), 10_000e18);
    }

    function test_checkInitialMargin_sufficient() public view {
        // Alice has $10,000. Required for 0.1 BTC at $60,000 = $120. Should pass.
        assertTrue(engine.checkInitialMargin(alice, MARKET_BTC, 0.1e18, 60_000e18));
    }

    function test_checkInitialMargin_insufficient() public view {
        // Required for 10 BTC at $60,000 = $12,000. Alice only has $10,000.
        assertFalse(engine.checkInitialMargin(alice, MARKET_BTC, 10e18, 60_000e18));
    }

    function test_validateOrder_size() public {
        // Below min order size
        vm.expectRevert(MarginEngine.OrderTooSmall.selector);
        engine.validateOrder(MARKET_BTC, 0.0001e18, 60_000e18);

        // Above max order size
        vm.expectRevert(MarginEngine.OrderTooLarge.selector);
        engine.validateOrder(MARKET_BTC, 200e18, 60_000e18);
    }

    function test_validateOrder_priceAlignment() public {
        // Price not aligned to tick size ($0.10)
        vm.expectRevert(MarginEngine.PriceNotAligned.selector);
        engine.validateOrder(MARKET_BTC, 1e18, 60_000.05e18);
    }

    function test_validateOrder_valid() public view {
        // Should not revert
        engine.validateOrder(MARKET_BTC, 1e18, 60_000e18);
    }
}
```

- [ ] **Step 9.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract MarginEngineTest -vvv
```

Expected: compilation error.

- [ ] **Step 9.3: Implement MarginEngine**

`contracts/src/MarginEngine.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IMarginEngine} from "./interfaces/IMarginEngine.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";
import {TickMath} from "./libraries/TickMath.sol";

contract MarginEngine is IMarginEngine, UUPSUpgradeable, AccessControlUpgradeable {
    error OrderTooSmall();
    error OrderTooLarge();
    error PriceNotAligned();
    error MarketNotConfigured();

    IVault public vault;
    IOracleAdapter public oracle;

    mapping(uint256 => MarketConfig) internal _configs;

    uint256[50] private __gap;

    function initialize(address _vault, address _oracle, address _admin) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        vault = IVault(_vault);
        oracle = IOracleAdapter(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setMarketConfig(uint256 marketId, MarketConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _configs[marketId] = config;
    }

    function configs(uint256 marketId) external view returns (
        uint256 maxLeverage,
        uint256 initialMarginRate,
        uint256 maintenanceMarginRate,
        uint256 tickSize,
        uint256 lotSize,
        uint256 maxOrderSize,
        uint256 minOrderSize
    ) {
        MarketConfig storage c = _configs[marketId];
        return (c.maxLeverage, c.initialMarginRate, c.maintenanceMarginRate, c.tickSize, c.lotSize, c.maxOrderSize, c.minOrderSize);
    }

    function getConfig(uint256 marketId) external view returns (MarketConfig memory) {
        return _configs[marketId];
    }

    function getRequiredMargin(uint256 marketId, uint256 size, uint256 price) public view returns (uint256) {
        MarketConfig storage c = _configs[marketId];
        uint256 notional = FixedPointMath.mulFp(size, price);
        return FixedPointMath.mulFp(notional, c.initialMarginRate);
    }

    function getAvailableMargin(address account) public view returns (uint256) {
        uint256 balance = vault.balances(account);
        return balance;
    }

    function checkInitialMargin(
        address account,
        uint256 marketId,
        uint256 orderSize,
        uint256 price
    ) external view returns (bool) {
        uint256 required = getRequiredMargin(marketId, orderSize, price);
        uint256 available = getAvailableMargin(account);
        return available >= required;
    }

    function validateOrder(uint256 marketId, uint256 size, uint256 price) external view {
        MarketConfig storage c = _configs[marketId];
        if (c.maxLeverage == 0) revert MarketNotConfigured();
        if (size < c.minOrderSize) revert OrderTooSmall();
        if (size > c.maxOrderSize) revert OrderTooLarge();
        if (!TickMath.isAligned(price, c.tickSize)) revert PriceNotAligned();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
```

- [ ] **Step 9.4: Run tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract MarginEngineTest -vvv
```

Expected: all PASS.

- [ ] **Step 9.5: Commit**

```bash
git add contracts/src/MarginEngine.sol contracts/test/unit/MarginEngine.t.sol
git commit -m "feat(contracts): add MarginEngine with market config, margin checks, order validation"
```

---

## Task 10: OrderBook Contract

**Files:**
- Create: `contracts/src/OrderBook.sol`
- Test: `contracts/test/unit/OrderBook.t.sol`

This is the largest task. The OrderBook implements the two-level bitmap CLOB with price-time priority matching for limit orders.

- [ ] **Step 10.1: Write unit tests**

`contracts/test/unit/OrderBook.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/OrderBook.sol";
import "../../src/Vault.sol";
import "../../src/MarginEngine.sol";
import "../../src/OracleAdapter.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPyth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";

contract OrderBookTest is Test {
    OrderBook public book;
    Vault public vault;
    MarginEngine public engine;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant MARKET_ID = 0;
    uint256 public constant TICK_SIZE = 0.1e18; // $0.10
    bytes32 public constant BTC_PYTH_ID = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        // Deploy Vault
        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl), abi.encodeCall(Vault.initialize, (address(usdc), admin))
        );
        vault = Vault(address(vaultProxy));

        // Deploy Oracle
        OracleAdapter oracleImpl = new OracleAdapter();
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
        );
        oracle = OracleAdapter(address(oracleProxy));

        // Deploy MarginEngine
        MarginEngine engineImpl = new MarginEngine();
        ERC1967Proxy engineProxy = new ERC1967Proxy(
            address(engineImpl), abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
        );
        engine = MarginEngine(address(engineProxy));

        // Deploy OrderBook
        OrderBook bookImpl = new OrderBook();
        ERC1967Proxy bookProxy = new ERC1967Proxy(
            address(bookImpl), abi.encodeCall(OrderBook.initialize, (MARKET_ID, address(vault), address(engine), TICK_SIZE, admin))
        );
        book = OrderBook(address(bookProxy));

        // Grant roles
        vm.startPrank(admin);
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(book));
        engine.setMarketConfig(MARKET_ID, IMarginEngine.MarketConfig({
            maxLeverage: 50e18,
            initialMarginRate: 2e16,
            maintenanceMarginRate: 1e16,
            tickSize: TICK_SIZE,
            lotSize: 0.00001e18,
            maxOrderSize: 100e18,
            minOrderSize: 0.001e18
        }));
        oracle.setMarketOracle(MARKET_ID, BTC_PYTH_ID, 60);
        vm.stopPrank();

        // Set BTC price
        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

        // Fund traders
        _fundTrader(alice, 100_000e6);
        _fundTrader(bob, 100_000e6);
    }

    function _fundTrader(address trader, uint256 usdcAmount) internal {
        usdc.mint(trader, usdcAmount);
        vm.startPrank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(usdcAmount);
        vm.stopPrank();
    }

    // ─── Place Order Tests ───

    function test_placeBidOrder() public {
        vm.prank(alice);
        uint256 orderId = book.placeOrder(alice, true, 59_000e18, 1e18, 1); // limit buy 1 BTC @ $59,000

        assertEq(orderId, 1);
        assertEq(book.bestBidTick(), 59_000e18 / TICK_SIZE); // tick = 590_000
    }

    function test_placeAskOrder() public {
        vm.prank(alice);
        uint256 orderId = book.placeOrder(alice, false, 61_000e18, 1e18, 1); // limit sell 1 BTC @ $61,000

        assertEq(orderId, 1);
        assertEq(book.bestAskTick(), 61_000e18 / TICK_SIZE); // tick = 610_000
    }

    function test_placeBid_reservesOrderMargin() public {
        uint256 balBefore = vault.balances(alice);

        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        // Required margin: 1 BTC * $60,000 * 2% = $1,200
        uint256 expectedMargin = 1_200e18;
        assertEq(vault.orderMargin(alice), expectedMargin);
        assertEq(vault.balances(alice), balBefore - expectedMargin);
    }

    // ─── Matching Tests ───

    function test_twoOrders_match() public {
        // Alice bids $60,000
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        // Bob asks $60,000 → should match
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        // Both orders should be fully filled — book is empty
        assertEq(book.bestBidTick(), 0);
        assertEq(book.bestAskTick(), 0);
    }

    function test_partialFill() public {
        // Alice bids 2 BTC @ $60,000
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 2e18, 1);

        // Bob sells 1 BTC @ $60,000 → partial fill, 1 BTC remains on bid
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        // Bid still has 1 BTC remaining
        assertGt(book.bestBidTick(), 0);
    }

    function test_matchEmits_fillEvent() public {
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        vm.expectEmit(true, true, true, true);
        emit OrderBook.Fill(MARKET_ID, alice, bob, 60_000e18, 1e18, false);

        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);
    }

    function test_priceTimePriority() public {
        // Alice bids $59,000
        vm.prank(alice);
        book.placeOrder(alice, true, 59_000e18, 1e18, 1);

        // Bob bids $60,000 (better price)
        vm.prank(bob);
        book.placeOrder(bob, true, 60_000e18, 1e18, 1);

        // Best bid should be Bob's $60,000
        assertEq(book.bestBidTick(), 60_000e18 / TICK_SIZE);

        // Charlie sells 1 BTC @ $59,000 → should match Bob first (better price)
        address charlie = makeAddr("charlie");
        _fundTrader(charlie, 100_000e6);

        vm.prank(charlie);
        book.placeOrder(charlie, false, 59_000e18, 1e18, 1);

        // Bob's order filled, Alice's still resting
        assertEq(book.bestBidTick(), 59_000e18 / TICK_SIZE);
    }

    // ─── Cancel Tests ───

    function test_cancelOrder() public {
        vm.prank(alice);
        uint256 orderId = book.placeOrder(alice, true, 59_000e18, 1e18, 1);

        uint256 marginBefore = vault.orderMargin(alice);
        assertGt(marginBefore, 0);

        vm.prank(alice);
        book.cancelOrder(orderId);

        // Order margin released
        assertEq(vault.orderMargin(alice), 0);
        // Book is empty
        assertEq(book.bestBidTick(), 0);
    }

    function test_cancelOrder_notOwner_reverts() public {
        vm.prank(alice);
        uint256 orderId = book.placeOrder(alice, true, 59_000e18, 1e18, 1);

        vm.prank(bob);
        vm.expectRevert(OrderBook.NotOrderOwner.selector);
        book.cancelOrder(orderId);
    }

    // ─── Self-Trade Prevention ───

    function test_selfTradePrevention() public {
        // Alice places both bid and ask at same price
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1); // bid

        vm.prank(alice);
        book.placeOrder(alice, false, 60_000e18, 1e18, 1); // ask — should NOT match own bid

        // Both orders should be resting on the book (crossed but same owner)
        assertGt(book.bestBidTick(), 0);
        assertGt(book.bestAskTick(), 0);
    }

    // ─── Edge Cases ───

    function test_placeOrder_insufficientMargin_reverts() public {
        // Alice has $100k. Try to buy 100 BTC @ $60k = $6M notional, margin = $120k
        vm.prank(alice);
        vm.expectRevert(); // InsufficientBalance from vault
        book.placeOrder(alice, true, 60_000e18, 100e18, 1);
    }

    function test_multipleBidsAtSamePrice() public {
        vm.prank(alice);
        uint256 id1 = book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        vm.prank(bob);
        uint256 id2 = book.placeOrder(bob, true, 60_000e18, 1e18, 1);

        assertEq(id1, 1);
        assertEq(id2, 2);

        // Both resting at same price
        assertEq(book.bestBidTick(), 60_000e18 / TICK_SIZE);

        // Charlie sells 1 BTC → should fill alice first (FIFO)
        address charlie = makeAddr("charlie");
        _fundTrader(charlie, 100_000e6);

        vm.expectEmit(true, true, true, true);
        emit OrderBook.Fill(MARKET_ID, alice, charlie, 60_000e18, 1e18, false);

        vm.prank(charlie);
        book.placeOrder(charlie, false, 60_000e18, 1e18, 1);
    }
}
```

- [ ] **Step 10.2: Run tests — verify they fail**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract OrderBookTest -vvv
```

Expected: compilation error.

- [ ] **Step 10.3: Implement OrderBook**

`contracts/src/OrderBook.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IVault} from "./interfaces/IVault.sol";
import {BitmapLib} from "./libraries/BitmapLib.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";
import {PackedOrder} from "./libraries/PackedOrder.sol";
import {TickMath} from "./libraries/TickMath.sol";

interface IMarginEngineForOB {
    function getRequiredMargin(uint256 marketId, uint256 size, uint256 price) external view returns (uint256);
    function validateOrder(uint256 marketId, uint256 size, uint256 price) external view;
}

contract OrderBook is IOrderBook, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using BitmapLib for uint256;

    error NotOrderOwner();
    error OrderNotFound();
    error InsufficientMargin();
    error NoLiquidity();

    uint256 public marketId;
    uint256 public tickSize;
    IVault public vault;
    IMarginEngineForOB public marginEngine;

    // Two-level bitmap: index bitmap tracks which words are active
    uint256 public bidBitmapIndex;
    uint256 public askBitmapIndex;

    // Level 1: tick bitmaps (256 ticks per word)
    mapping(uint256 => uint256) public bidBitmaps;
    mapping(uint256 => uint256) public askBitmaps;

    // FIFO queues per tick
    mapping(uint256 => uint256) public bidHeadAtTick;
    mapping(uint256 => uint256) public bidTailAtTick;
    mapping(uint256 => uint256) public askHeadAtTick;
    mapping(uint256 => uint256) public askTailAtTick;

    // Order storage
    mapping(uint256 => bytes32) public orderSlot0;
    mapping(uint256 => bytes32) public orderSlot1;
    mapping(uint256 => uint256) public nextOrder;

    // Book state
    uint256 public bestBidTick;
    uint256 public bestAskTick;
    uint256 public nextOrderId;

    // Fee config
    int256 public makerFeeRate;  // e.g., -1e14 = -0.01% (rebate)
    int256 public takerFeeRate;  // e.g., 5e14 = +0.05%

    // Track order margin per order for release on cancel/fill
    mapping(uint256 => uint256) public orderMarginAmount;

    uint256[50] private __gap;

    function initialize(
        uint256 _marketId,
        address _vault,
        address _marginEngine,
        uint256 _tickSize,
        address _admin
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        marketId = _marketId;
        vault = IVault(_vault);
        marginEngine = IMarginEngineForOB(_marginEngine);
        tickSize = _tickSize;
        nextOrderId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setFeeConfig(int256 _makerFeeRate, int256 _takerFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        makerFeeRate = _makerFeeRate;
        takerFeeRate = _takerFeeRate;
    }

    function placeOrder(
        address trader,
        bool side,
        uint256 price,
        uint256 size,
        uint8 orderType
    ) external nonReentrant returns (uint256 orderId) {
        // 1. Validate
        marginEngine.validateOrder(marketId, size, price);

        // 2. Reserve order margin
        uint256 requiredMargin = marginEngine.getRequiredMargin(marketId, size, price);
        vault.lockOrderMargin(trader, requiredMargin);

        uint256 tick = TickMath.priceToTick(price, tickSize);
        orderId = nextOrderId++;

        // 3. Try to match (limit orders only in Phase 1)
        uint256 remaining = size;
        uint256 marginUsed = 0;

        if (orderType == 1) { // LIMIT
            remaining = _tryMatch(trader, side, tick, size, orderId);
            uint256 filledSize = size - remaining;
            if (filledSize > 0) {
                marginUsed = FixedPointMath.mulDiv(requiredMargin, filledSize, size);
            }
        }

        // 4. Rest remaining on book
        if (remaining > 0) {
            uint256 restingMargin = requiredMargin - marginUsed;
            _insertOrder(trader, side, tick, remaining, orderId, restingMargin);

            emit OrderPlaced(orderId, trader, marketId, side, price, remaining, orderType);
        } else {
            // Fully filled — release any remaining order margin
            uint256 leftoverMargin = requiredMargin - marginUsed;
            if (leftoverMargin > 0) {
                vault.unlockOrderMargin(trader, leftoverMargin);
            }
        }
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        bytes32 slot0 = orderSlot0[orderId];
        if (slot0 == bytes32(0)) revert OrderNotFound();
        if (PackedOrder.getOwner(slot0) != msg.sender) revert NotOrderOwner();

        bool side = PackedOrder.getSide(slot0);
        bytes32 slot1 = orderSlot1[orderId];
        uint256 price = PackedOrder.getPrice(slot1);
        uint256 tick = TickMath.priceToTick(price, tickSize);

        _removeOrder(orderId, side, tick);

        // Release order margin
        uint256 margin = orderMarginAmount[orderId];
        if (margin > 0) {
            vault.unlockOrderMargin(msg.sender, margin);
            delete orderMarginAmount[orderId];
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // ─── Internal: Matching ───

    function _tryMatch(
        address taker,
        bool takerSide,
        uint256 limitTick,
        uint256 size,
        uint256 takerOrderId
    ) internal returns (uint256 remaining) {
        remaining = size;

        if (takerSide) {
            // Buyer matches against asks (lowest first)
            remaining = _matchAgainstAsks(taker, limitTick, remaining, takerOrderId);
        } else {
            // Seller matches against bids (highest first)
            remaining = _matchAgainstBids(taker, limitTick, remaining, takerOrderId);
        }
    }

    function _matchAgainstAsks(
        address taker,
        uint256 limitTick,
        uint256 remaining,
        uint256 takerOrderId
    ) internal returns (uint256) {
        uint256 tick = bestAskTick;
        if (tick == 0) return remaining;

        while (remaining > 0 && tick != 0 && tick <= limitTick) {
            uint256 headId = askHeadAtTick[tick];

            while (headId != 0 && remaining > 0) {
                bytes32 s0 = orderSlot0[headId];
                bytes32 s1 = orderSlot1[headId];
                address maker = PackedOrder.getOwner(s0);
                uint256 nextId = nextOrder[headId];

                // Self-trade prevention
                if (maker == taker) {
                    headId = nextId;
                    continue;
                }

                uint256 makerSize = PackedOrder.getSize(s1);
                uint256 fillSize = FixedPointMath.min(remaining, makerSize);
                uint256 fillPrice = TickMath.tickToPrice(tick, tickSize);

                _executeFill(maker, taker, fillPrice, fillSize, false, headId, takerOrderId);

                remaining -= fillSize;

                if (fillSize == makerSize) {
                    // Fully filled — remove from book
                    _removeOrderFromQueue(headId, true, tick);
                    headId = nextId;
                } else {
                    // Partial fill — update size
                    orderSlot1[headId] = PackedOrder.setSize(s1, makerSize - fillSize);
                    // Update margin proportionally
                    uint256 makerMargin = orderMarginAmount[headId];
                    uint256 usedMargin = FixedPointMath.mulDiv(makerMargin, fillSize, makerSize);
                    orderMarginAmount[headId] -= usedMargin;
                    break;
                }
            }

            // Check if tick is now empty
            if (askHeadAtTick[tick] == 0) {
                _clearAskTick(tick);
                tick = _findNextAskTick(tick);
            } else {
                break;
            }
        }

        bestAskTick = tick;
        return remaining;
    }

    function _matchAgainstBids(
        address taker,
        uint256 limitTick,
        uint256 remaining,
        uint256 takerOrderId
    ) internal returns (uint256) {
        uint256 tick = bestBidTick;
        if (tick == 0) return remaining;

        while (remaining > 0 && tick != 0 && tick >= limitTick) {
            uint256 headId = bidHeadAtTick[tick];

            while (headId != 0 && remaining > 0) {
                bytes32 s0 = orderSlot0[headId];
                bytes32 s1 = orderSlot1[headId];
                address maker = PackedOrder.getOwner(s0);
                uint256 nextId = nextOrder[headId];

                if (maker == taker) {
                    headId = nextId;
                    continue;
                }

                uint256 makerSize = PackedOrder.getSize(s1);
                uint256 fillSize = FixedPointMath.min(remaining, makerSize);
                uint256 fillPrice = TickMath.tickToPrice(tick, tickSize);

                _executeFill(maker, taker, fillPrice, fillSize, true, headId, takerOrderId);

                remaining -= fillSize;

                if (fillSize == makerSize) {
                    _removeOrderFromQueue(headId, false, tick);
                    headId = nextId;
                } else {
                    orderSlot1[headId] = PackedOrder.setSize(s1, makerSize - fillSize);
                    uint256 makerMargin = orderMarginAmount[headId];
                    uint256 usedMargin = FixedPointMath.mulDiv(makerMargin, fillSize, makerSize);
                    orderMarginAmount[headId] -= usedMargin;
                    break;
                }
            }

            if (bidHeadAtTick[tick] == 0) {
                _clearBidTick(tick);
                tick = _findPrevBidTick(tick);
            } else {
                break;
            }
        }

        bestBidTick = tick;
        return remaining;
    }

    function _executeFill(
        address maker,
        address taker,
        uint256 price,
        uint256 size,
        bool takerSide,
        uint256 makerOrderId,
        uint256 takerOrderId
    ) internal {
        // Release maker's order margin for the filled portion
        uint256 makerMargin = orderMarginAmount[makerOrderId];
        bytes32 s1 = orderSlot1[makerOrderId];
        uint256 makerTotalSize = PackedOrder.getSize(s1);
        uint256 makerMarginUsed = (makerTotalSize == size)
            ? makerMargin
            : FixedPointMath.mulDiv(makerMargin, size, makerTotalSize);

        if (makerMarginUsed > 0) {
            vault.unlockOrderMargin(maker, makerMarginUsed);
        }

        // Release taker's order margin proportionally
        // (handled by caller tracking marginUsed)

        // Apply fees
        uint256 notional = FixedPointMath.mulFp(size, price);
        if (makerFeeRate != 0) {
            int256 makerFee = FixedPointMath.mulFpSigned(int256(notional), makerFeeRate);
            vault.realizePnl(maker, -makerFee); // negative fee = rebate → positive PnL
        }
        if (takerFeeRate != 0) {
            int256 takerFee = FixedPointMath.mulFpSigned(int256(notional), takerFeeRate);
            vault.realizePnl(taker, -takerFee);
        }

        emit OrderMatched(marketId, makerOrderId, takerOrderId, price, size);
        emit Fill(marketId, maker, taker, price, size, takerSide);
    }

    // ─── Internal: Book Management ───

    function _insertOrder(
        address trader,
        bool side,
        uint256 tick,
        uint256 size,
        uint256 orderId,
        uint256 margin
    ) internal {
        uint256 price = TickMath.tickToPrice(tick, tickSize);

        PackedOrder.Order memory order = PackedOrder.Order({
            owner: trader,
            orderId: uint32(orderId),
            timestamp: uint32(block.timestamp),
            side: side,
            orderType: 1, // limit
            reduceOnly: false,
            price: price,
            size: size
        });

        (bytes32 slot0, bytes32 slot1) = PackedOrder.pack(order);
        orderSlot0[orderId] = slot0;
        orderSlot1[orderId] = slot1;
        orderMarginAmount[orderId] = margin;

        // Append to FIFO at this tick
        if (side) {
            if (bidHeadAtTick[tick] == 0) {
                bidHeadAtTick[tick] = orderId;
                _setBidTick(tick);
            } else {
                nextOrder[bidTailAtTick[tick]] = orderId;
            }
            bidTailAtTick[tick] = orderId;

            if (bestBidTick == 0 || tick > bestBidTick) {
                bestBidTick = tick;
            }
        } else {
            if (askHeadAtTick[tick] == 0) {
                askHeadAtTick[tick] = orderId;
                _setAskTick(tick);
            } else {
                nextOrder[askTailAtTick[tick]] = orderId;
            }
            askTailAtTick[tick] = orderId;

            if (bestAskTick == 0 || tick < bestAskTick) {
                bestAskTick = tick;
            }
        }
    }

    function _removeOrder(uint256 orderId, bool side, uint256 tick) internal {
        // Simple removal: walk the linked list at this tick
        if (side) {
            _removeFromBidQueue(orderId, tick);
            if (bidHeadAtTick[tick] == 0) {
                _clearBidTick(tick);
                if (tick == bestBidTick) {
                    bestBidTick = _findPrevBidTick(tick);
                }
            }
        } else {
            _removeFromAskQueue(orderId, tick);
            if (askHeadAtTick[tick] == 0) {
                _clearAskTick(tick);
                if (tick == bestAskTick) {
                    bestAskTick = _findNextAskTick(tick);
                }
            }
        }

        delete orderSlot0[orderId];
        delete orderSlot1[orderId];
        delete nextOrder[orderId];
    }

    function _removeOrderFromQueue(uint256 orderId, bool isAsk, uint256 tick) internal {
        if (isAsk) {
            _removeFromAskQueue(orderId, tick);
        } else {
            _removeFromBidQueue(orderId, tick);
        }

        delete orderSlot0[orderId];
        delete orderSlot1[orderId];
        delete nextOrder[orderId];
        delete orderMarginAmount[orderId];
    }

    function _removeFromBidQueue(uint256 orderId, uint256 tick) internal {
        uint256 head = bidHeadAtTick[tick];
        if (head == orderId) {
            bidHeadAtTick[tick] = nextOrder[orderId];
            if (bidHeadAtTick[tick] == 0) {
                bidTailAtTick[tick] = 0;
            }
            return;
        }
        // Walk to find predecessor
        uint256 current = head;
        while (current != 0) {
            uint256 next = nextOrder[current];
            if (next == orderId) {
                nextOrder[current] = nextOrder[orderId];
                if (orderId == bidTailAtTick[tick]) {
                    bidTailAtTick[tick] = current;
                }
                return;
            }
            current = next;
        }
    }

    function _removeFromAskQueue(uint256 orderId, uint256 tick) internal {
        uint256 head = askHeadAtTick[tick];
        if (head == orderId) {
            askHeadAtTick[tick] = nextOrder[orderId];
            if (askHeadAtTick[tick] == 0) {
                askTailAtTick[tick] = 0;
            }
            return;
        }
        uint256 current = head;
        while (current != 0) {
            uint256 next = nextOrder[current];
            if (next == orderId) {
                nextOrder[current] = nextOrder[orderId];
                if (orderId == askTailAtTick[tick]) {
                    askTailAtTick[tick] = current;
                }
                return;
            }
            current = next;
        }
    }

    // ─── Two-Level Bitmap Operations ───

    function _setBidTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        bidBitmaps[word] = BitmapLib.setBit(bidBitmaps[word], bit);
        bidBitmapIndex = BitmapLib.setBit(bidBitmapIndex, uint8(word & 0xFF));
    }

    function _clearBidTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        bidBitmaps[word] = BitmapLib.clearBit(bidBitmaps[word], bit);
        if (BitmapLib.isEmpty(bidBitmaps[word])) {
            bidBitmapIndex = BitmapLib.clearBit(bidBitmapIndex, uint8(word & 0xFF));
        }
    }

    function _setAskTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        askBitmaps[word] = BitmapLib.setBit(askBitmaps[word], bit);
        askBitmapIndex = BitmapLib.setBit(askBitmapIndex, uint8(word & 0xFF));
    }

    function _clearAskTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        askBitmaps[word] = BitmapLib.clearBit(askBitmaps[word], bit);
        if (BitmapLib.isEmpty(askBitmaps[word])) {
            askBitmapIndex = BitmapLib.clearBit(askBitmapIndex, uint8(word & 0xFF));
        }
    }

    /// @dev Find next higher ask tick (for advancing after emptying a level).
    function _findNextAskTick(uint256 currentTick) internal view returns (uint256) {
        if (BitmapLib.isEmpty(askBitmapIndex)) return 0;

        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(currentTick);

        // Search within current word first
        (bool found, uint8 nextBit) = BitmapLib.findNextSet(askBitmaps[word], bit);
        if (found) return TickMath.wordAndBitToTick(word, nextBit);

        // Search next words
        (bool wordFound, uint8 nextWord) = BitmapLib.findNextSet(askBitmapIndex, uint8(word & 0xFF));
        if (!wordFound) return 0;

        uint256 nextBitmap = askBitmaps[uint256(nextWord)];
        if (BitmapLib.isEmpty(nextBitmap)) return 0;
        return TickMath.wordAndBitToTick(uint256(nextWord), BitmapLib.findFirstSet(nextBitmap));
    }

    /// @dev Find next lower bid tick (for advancing after emptying a level).
    function _findPrevBidTick(uint256 currentTick) internal view returns (uint256) {
        if (BitmapLib.isEmpty(bidBitmapIndex)) return 0;

        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(currentTick);

        // Search within current word first
        (bool found, uint8 prevBit) = BitmapLib.findPrevSet(bidBitmaps[word], bit);
        if (found) return TickMath.wordAndBitToTick(word, prevBit);

        // Search previous words
        (bool wordFound, uint8 prevWord) = BitmapLib.findPrevSet(bidBitmapIndex, uint8(word & 0xFF));
        if (!wordFound) return 0;

        uint256 prevBitmap = bidBitmaps[uint256(prevWord)];
        if (BitmapLib.isEmpty(prevBitmap)) return 0;
        return TickMath.wordAndBitToTick(uint256(prevWord), BitmapLib.findLastSet(prevBitmap));
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
```

- [ ] **Step 10.4: Run unit tests — verify they pass**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract OrderBookTest -vvv
```

Expected: all PASS.

- [ ] **Step 10.5: Commit**

```bash
git add contracts/src/OrderBook.sol contracts/test/unit/OrderBook.t.sol
git commit -m "feat(contracts): add OrderBook with two-level bitmap CLOB, limit order matching, cancel"
```

---

## Task 11: Integration Test — Deposit → Place → Match → Fill

**Files:**
- Create: `contracts/test/integration/DepositPlaceMatch.t.sol`

- [ ] **Step 11.1: Write integration test**

`contracts/test/integration/DepositPlaceMatch.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/Vault.sol";
import "../../src/OrderBook.sol";
import "../../src/MarginEngine.sol";
import "../../src/OracleAdapter.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPyth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";

/// @notice Full lifecycle: deposit USDC → place bid → place ask (different account) → match → verify fills + margin changes.
contract DepositPlaceMatchTest is Test {
    Vault public vault;
    OrderBook public book;
    MarginEngine public engine;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice"); // buyer
    address public bob = makeAddr("bob");     // seller

    uint256 constant MARKET_ID = 0;
    uint256 constant TICK_SIZE = 0.1e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        // ── Deploy stack ──
        vault = Vault(address(new ERC1967Proxy(
            address(new Vault()),
            abi.encodeCall(Vault.initialize, (address(usdc), admin))
        )));

        oracle = OracleAdapter(address(new ERC1967Proxy(
            address(new OracleAdapter()),
            abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
        )));

        engine = MarginEngine(address(new ERC1967Proxy(
            address(new MarginEngine()),
            abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
        )));

        book = OrderBook(address(new ERC1967Proxy(
            address(new OrderBook()),
            abi.encodeCall(OrderBook.initialize, (MARKET_ID, address(vault), address(engine), TICK_SIZE, admin))
        )));

        // ── Configure ──
        vm.startPrank(admin);
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(book));
        engine.setMarketConfig(MARKET_ID, IMarginEngine.MarketConfig({
            maxLeverage: 50e18,
            initialMarginRate: 2e16,
            maintenanceMarginRate: 1e16,
            tickSize: TICK_SIZE,
            lotSize: 0.00001e18,
            maxOrderSize: 100e18,
            minOrderSize: 0.001e18
        }));
        oracle.setMarketOracle(MARKET_ID, bytes32(uint256(1)), 60);
        book.setFeeConfig(-1e14, 5e14); // maker rebate -0.01%, taker fee 0.05%
        vm.stopPrank();

        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);
    }

    function test_fullLifecycle() public {
        // ── 1. Deposit ──
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(10_000e6);
        assertEq(vault.balances(alice), 10_000e18);

        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vault.deposit(10_000e6);
        assertEq(vault.balances(bob), 10_000e18);

        // ── 2. Alice places limit buy: 0.5 BTC @ $60,000 ──
        vm.prank(alice);
        uint256 aliceOrderId = book.placeOrder(alice, true, 60_000e18, 0.5e18, 1);
        assertEq(aliceOrderId, 1);

        // Required margin: 0.5 * 60,000 * 2% = 600 USDC
        assertEq(vault.orderMargin(alice), 600e18);
        assertEq(vault.balances(alice), 9_400e18);

        // Book state: best bid at tick 600,000
        assertEq(book.bestBidTick(), 600_000);
        assertEq(book.bestAskTick(), 0);

        // ── 3. Bob places limit sell: 0.5 BTC @ $60,000 → matches ──
        vm.prank(bob);
        uint256 bobOrderId = book.placeOrder(bob, false, 60_000e18, 0.5e18, 1);

        // Match should have occurred — book empty
        assertEq(book.bestBidTick(), 0);
        assertEq(book.bestAskTick(), 0);

        // Order margin should be released for both
        assertEq(vault.orderMargin(alice), 0);
        assertEq(vault.orderMargin(bob), 0);

        // ── 4. Verify margin after fees ──
        // Notional = 0.5 * 60,000 = 30,000 USDC
        // Alice (maker): -0.01% rebate = +3 USDC → balance should include rebate
        // Bob (taker): +0.05% fee = -15 USDC → balance should reflect fee
        //
        // Alice: started 10,000, locked 600 margin, margin released, +3 rebate
        // Bob: started 10,000, locked 600 margin, margin released, -15 fee
        uint256 aliceExpected = 10_000e18 + 3e18;  // rebate
        uint256 bobExpected = 10_000e18 - 15e18;    // fee
        assertApproxEqAbs(vault.balances(alice), aliceExpected, 1e15); // within 0.001 USDC
        assertApproxEqAbs(vault.balances(bob), bobExpected, 1e15);
    }

    function test_partialFill_thenCancel() public {
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vault.deposit(10_000e6);

        // Alice bids 2 BTC @ $60,000
        vm.prank(alice);
        uint256 aliceOrderId = book.placeOrder(alice, true, 60_000e18, 2e18, 1);

        // Bob sells 1 BTC → partial fill
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        // Alice still has 1 BTC resting
        assertEq(book.bestBidTick(), 600_000);

        // Alice cancels remaining order
        vm.prank(alice);
        book.cancelOrder(aliceOrderId);

        assertEq(book.bestBidTick(), 0);
        // Remaining order margin released
        assertEq(vault.orderMargin(alice), 0);
    }

    function test_multipleMatchesAtDifferentPrices() public {
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100_000e6);

        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vault.deposit(100_000e6);

        // Bob places asks at multiple levels
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 0.5e18, 1); // ask 0.5 @ $60,000
        vm.prank(bob);
        book.placeOrder(bob, false, 60_100e18, 0.5e18, 1); // ask 0.5 @ $60,100

        assertEq(book.bestAskTick(), 600_000); // lowest ask

        // Alice buys 0.8 BTC @ $60,100 limit → walks through both levels
        vm.prank(alice);
        book.placeOrder(alice, true, 60_100e18, 0.8e18, 1);

        // 0.5 filled @ $60,000, 0.3 filled @ $60,100
        // Remaining 0.2 ask @ $60,100
        assertEq(book.bestAskTick(), 601_000);
        assertEq(book.bestBidTick(), 0); // nothing resting on bid
    }
}
```

- [ ] **Step 11.2: Run integration tests**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract DepositPlaceMatchTest -vvv
```

Expected: all PASS.

- [ ] **Step 11.3: Run the full test suite + gas benchmarks**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test -vvv
cd /Users/sskys/Mine/gaekju/contracts && forge test --match-contract OrderBookTest --gas-report
```

Expected: all tests pass. Gas report shows per-function costs.

- [ ] **Step 11.4: Commit**

```bash
git add contracts/test/integration/DepositPlaceMatch.t.sol
git commit -m "test: add integration test for full deposit→place→match→fill lifecycle"
```

---

## Task 12: Rust Types Crate

**Files:**
- Modify: `crates/gaekju-types/Cargo.toml`
- Create: `crates/gaekju-types/src/lib.rs`
- Create: `crates/gaekju-types/src/order.rs`
- Create: `crates/gaekju-types/src/position.rs`
- Create: `crates/gaekju-types/src/market.rs`
- Create: `crates/gaekju-types/src/account.rs`
- Create: `crates/gaekju-types/src/events.rs`

- [ ] **Step 12.1: Define core types**

`crates/gaekju-types/src/lib.rs`:
```rust
pub mod account;
pub mod events;
pub mod market;
pub mod order;
pub mod position;

pub use alloy_primitives::{Address, U256};
```

`crates/gaekju-types/src/order.rs`:
```rust
use alloy_primitives::{Address, U256};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Side {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum OrderType {
    Market = 0,
    Limit = 1,
    Ioc = 2,
    Fok = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum OrderStatus {
    Open = 0,
    Filled = 1,
    Cancelled = 2,
    PartiallyFilled = 3,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub order_id: u64,
    pub market_id: u32,
    pub trader: Address,
    pub side: Side,
    pub price: U256,
    pub size: U256,
    pub original_size: U256,
    pub order_type: OrderType,
    pub status: OrderStatus,
    pub reduce_only: bool,
    pub created_at: u64,
    pub updated_at: u64,
}
```

`crates/gaekju-types/src/position.rs`:
```rust
use alloy_primitives::{Address, I256, U256};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Position {
    pub account: Address,
    pub market_id: u32,
    pub size: I256,
    pub entry_price: U256,
    pub collateral: U256,
    pub last_cumulative_funding: I256,
    pub last_updated: u64,
}
```

`crates/gaekju-types/src/market.rs`:
```rust
use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketConfig {
    pub id: u32,
    pub name: String,
    pub max_leverage: U256,
    pub initial_margin_rate: U256,
    pub maintenance_margin_rate: U256,
    pub tick_size: U256,
    pub lot_size: U256,
    pub max_order_size: U256,
    pub min_order_size: U256,
    pub active: bool,
}
```

`crates/gaekju-types/src/account.rs`:
```rust
use alloy_primitives::{Address, U256};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountBalance {
    pub address: Address,
    pub balance: U256,
    pub locked_margin: U256,
    pub order_margin: U256,
}
```

`crates/gaekju-types/src/events.rs`:
```rust
use alloy_primitives::{Address, U256};
use alloy_sol_types::sol;
use serde::{Deserialize, Serialize};

// Generate Rust types from Solidity event signatures
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
}
```

- [ ] **Step 12.2: Verify Rust types compile**

```bash
cd /Users/sskys/Mine/gaekju && cargo check -p gaekju-types
```

Expected: success.

- [ ] **Step 12.3: Run full workspace check**

```bash
cd /Users/sskys/Mine/gaekju && cargo check && cargo clippy --all-targets -- -D warnings
```

Expected: success with no warnings.

- [ ] **Step 12.4: Commit**

```bash
git add crates/gaekju-types/
git commit -m "feat(rust): add gaekju-types crate with Order, Position, Market, Account types + event definitions"
```

---

## Task 13: Deploy Script + Full Verification

**Files:**
- Create: `contracts/script/Deploy.s.sol`

- [ ] **Step 13.1: Write deploy script**

`contracts/script/Deploy.s.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/Vault.sol";
import "../src/OracleAdapter.sol";
import "../src/MarginEngine.sol";
import "../src/OrderBook.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address pyth = vm.envAddress("PYTH_ADDRESS");

        vm.startBroadcast(deployerPk);

        // Deploy implementations
        Vault vaultImpl = new Vault();
        OracleAdapter oracleImpl = new OracleAdapter();
        MarginEngine engineImpl = new MarginEngine();
        OrderBook bookImpl = new OrderBook();

        // Deploy proxies
        Vault vault = Vault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(Vault.initialize, (usdc, deployer))
        )));

        OracleAdapter oracle = OracleAdapter(address(new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeCall(OracleAdapter.initialize, (pyth, deployer))
        )));

        MarginEngine engine = MarginEngine(address(new ERC1967Proxy(
            address(engineImpl),
            abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), deployer))
        )));

        // BTC-USD market (id=0)
        uint256 btcTickSize = 0.1e18;
        OrderBook btcBook = OrderBook(address(new ERC1967Proxy(
            address(bookImpl),
            abi.encodeCall(OrderBook.initialize, (0, address(vault), address(engine), btcTickSize, deployer))
        )));

        // Grant roles
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(btcBook));

        // Configure BTC market
        engine.setMarketConfig(0, IMarginEngine.MarketConfig({
            maxLeverage: 50e18,
            initialMarginRate: 2e16,
            maintenanceMarginRate: 1e16,
            tickSize: btcTickSize,
            lotSize: 0.00001e18,
            maxOrderSize: 100e18,
            minOrderSize: 0.001e18
        }));

        // Configure fees: maker -0.01%, taker 0.05%
        btcBook.setFeeConfig(-1e14, 5e14);

        vm.stopBroadcast();

        console.log("Vault:", address(vault));
        console.log("OracleAdapter:", address(oracle));
        console.log("MarginEngine:", address(engine));
        console.log("BTC OrderBook:", address(btcBook));
    }
}
```

- [ ] **Step 13.2: Run full test suite**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge test -vvv
```

Expected: ALL tests pass (unit, fuzz, integration).

- [ ] **Step 13.3: Run format check**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge fmt --check
cd /Users/sskys/Mine/gaekju && cargo fmt --all -- --check
```

Fix any formatting issues if found.

- [ ] **Step 13.4: Check contract sizes**

```bash
cd /Users/sskys/Mine/gaekju/contracts && forge build --sizes
```

Expected: all contracts under 24KB Spurious Dragon limit.

- [ ] **Step 13.5: Commit**

```bash
git add contracts/script/Deploy.s.sol
git commit -m "feat(contracts): add Deploy script for Vault, Oracle, MarginEngine, OrderBook"
```

---

## Task 14: Phase 1 Wrap-up

- [ ] **Step 14.1: Update CHANGELOG.md**

Add to CHANGELOG.md under `## [0.1.0] - 2026-04-XX`:

```markdown
## [0.1.0] - 2026-04-XX

### Added
- **Libraries:** BitmapLib, FixedPointMath, PackedOrder, TickMath
- **Vault:** USDC deposit/withdraw, margin locking, UUPS proxy
- **OracleAdapter:** Pyth Network integration with staleness + confidence checks
- **MarginEngine:** Market config, initial margin checks, order validation
- **OrderBook:** Two-level bitmap CLOB, limit order matching (price-time priority), self-trade prevention, order cancellation
- **Fees:** Maker rebate (-0.01%) + taker fee (0.05%)
- **Integration test:** Full deposit → place → match → fill lifecycle
- **Rust types crate:** Order, Position, Market, Account types with alloy event definitions
- **Deploy script:** Foundry script for full stack deployment
- **CI:** forge test + cargo test + clippy + fmt
```

- [ ] **Step 14.2: Tag v0.1.0**

```bash
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG for v0.1.0"
git tag v0.1.0
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - [x] Section 3.1 Libraries → Tasks 1-4
   - [x] Section 3.2 Vault → Task 7
   - [x] Section 3.3 OracleAdapter → Task 8
   - [x] Section 3.5 MarginEngine → Task 9
   - [x] Section 3.4 OrderBook (limit orders) → Task 10
   - [x] Section 3.4 Fee Model → Task 10 + 11
   - [x] Section 4.1 Rust types → Task 12
   - [x] Phase 1 checklist items 1.0-1.6 → Tasks 0-12
   - [x] Self-trade prevention (Section 10) → Task 10
   - [x] USDC 6→18 decimal conversion (Section 3.2) → Task 7

2. **Placeholder scan:** No "TBD", "TODO", "implement later" patterns found.

3. **Type consistency:** `uint256` for 18-decimal values, `IMarginEngine.MarketConfig` used consistently, `PackedOrder.Order` struct consistent across pack/unpack tests.

4. **Deferred to Phase 2:** PositionManager integration (fills don't update positions yet — only margin flows are tested). This matches spec note: "full position integration test deferred to Phase 2."

---

**Plan complete. Three execution options:**
1. **Subagent-Driven (recommended)** → sspower:subagent-driven-development
2. **Inline Execution** → sspower:executing-plans
3. **Codex execute** → delegate via `/codex:rescue`

**Which approach?**
