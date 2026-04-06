// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrderBook} from "../../src/OrderBook.sol";
import {Vault} from "../../src/Vault.sol";
import {MarginEngine} from "../../src/MarginEngine.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";

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
    uint256 public constant TICK_SIZE = 0.1e18;
    bytes32 public constant BTC_PYTH_ID = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        vault = Vault(
            address(
                new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin)))
            )
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
                    abi.encodeCall(
                        OrderBook.initialize, (MARKET_ID, address(vault), address(engine), TICK_SIZE, admin)
                    )
                )
            )
        );

        vm.startPrank(admin);
        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(book));
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
        oracle.setMarketOracle(MARKET_ID, BTC_PYTH_ID, 60);
        vm.stopPrank();

        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

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
        uint256 orderId = book.placeOrder(alice, true, 59_000e18, 1e18, 1);

        assertEq(orderId, 1);
        assertEq(book.bestBidTick(), 59_000e18 / TICK_SIZE);
    }

    function test_placeAskOrder() public {
        vm.prank(alice);
        uint256 orderId = book.placeOrder(alice, false, 61_000e18, 1e18, 1);

        assertEq(orderId, 1);
        assertEq(book.bestAskTick(), 61_000e18 / TICK_SIZE);
    }

    function test_placeBid_reservesOrderMargin() public {
        uint256 balBefore = vault.balances(alice);

        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        uint256 expectedMargin = 1_200e18;
        assertEq(vault.orderMargin(alice), expectedMargin);
        assertEq(vault.balances(alice), balBefore - expectedMargin);
    }

    // ─── Matching Tests ───

    function test_twoOrders_match() public {
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        assertEq(book.bestBidTick(), 0);
        assertEq(book.bestAskTick(), 0);
    }

    function test_partialFill() public {
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 2e18, 1);

        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        assertGt(book.bestBidTick(), 0);
    }

    function test_matchEmits_fillEvent() public {
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        vm.expectEmit(true, true, true, true);
        emit IOrderBook.Fill(MARKET_ID, alice, bob, 60_000e18, 1e18, false);

        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);
    }

    function test_priceTimePriority() public {
        vm.prank(alice);
        book.placeOrder(alice, true, 59_000e18, 1e18, 1);

        vm.prank(bob);
        book.placeOrder(bob, true, 60_000e18, 1e18, 1);

        assertEq(book.bestBidTick(), 60_000e18 / TICK_SIZE);

        address charlie = makeAddr("charlie");
        _fundTrader(charlie, 100_000e6);

        vm.prank(charlie);
        book.placeOrder(charlie, false, 59_000e18, 1e18, 1);

        assertEq(book.bestBidTick(), 59_000e18 / TICK_SIZE);
    }

    // ─── Cancel Tests ───

    function test_cancelOrder() public {
        vm.prank(alice);
        uint256 orderId = book.placeOrder(alice, true, 59_000e18, 1e18, 1);

        assertGt(vault.orderMargin(alice), 0);

        vm.prank(alice);
        book.cancelOrder(orderId);

        assertEq(vault.orderMargin(alice), 0);
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
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        vm.prank(alice);
        book.placeOrder(alice, false, 60_000e18, 1e18, 1);

        assertGt(book.bestBidTick(), 0);
        assertGt(book.bestAskTick(), 0);
    }

    // ─── Edge Cases ───

    function test_multipleBidsAtSamePrice_fifo() public {
        vm.prank(alice);
        book.placeOrder(alice, true, 60_000e18, 1e18, 1);

        vm.prank(bob);
        book.placeOrder(bob, true, 60_000e18, 1e18, 1);

        address charlie = makeAddr("charlie");
        _fundTrader(charlie, 100_000e6);

        vm.expectEmit(true, true, true, true);
        emit IOrderBook.Fill(MARKET_ID, alice, charlie, 60_000e18, 1e18, false);

        vm.prank(charlie);
        book.placeOrder(charlie, false, 60_000e18, 1e18, 1);
    }
}
