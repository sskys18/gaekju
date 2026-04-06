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
                        PositionManager.initialize, (address(vault), address(engine), address(oracle), admin)
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

        vm.warp(1000);
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
