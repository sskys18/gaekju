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
import { FixedPointMath } from "../../src/libraries/FixedPointMath.sol";

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
        vm.warp(1000);
        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);
    }

    function _openLongPosition(address account, uint256 usdcAmount, uint256 size, uint256 price) internal {
        usdc.mint(account, usdcAmount);
        vm.prank(account);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(usdcAmount);

        // Directly call PositionManager as orderBook for test setup
        uint256 margin = engine.getRequiredMargin(MARKET_ID, size, price);
        vm.prank(address(book));
        vault.lockOrderMargin(account, margin);

        vm.prank(address(book));
        pm.updatePosition(account, MARKET_ID, int256(size), price, margin);
    }

    function _openShortPosition(address account, uint256 usdcAmount, uint256 size, uint256 price) internal {
        usdc.mint(account, usdcAmount);
        vm.prank(account);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(usdcAmount);

        uint256 margin = engine.getRequiredMargin(MARKET_ID, size, price);
        vm.prank(address(book));
        vault.lockOrderMargin(account, margin);

        vm.prank(address(book));
        pm.updatePosition(account, MARKET_ID, -int256(size), price, margin);
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

        // Price drops massively -> Alice bankrupt
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
