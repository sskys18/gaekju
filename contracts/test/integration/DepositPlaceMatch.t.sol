// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { OrderBook } from "../../src/OrderBook.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";

contract DepositPlaceMatchTest is Test {
    Vault public vault;
    OrderBook public book;
    MarginEngine public engine;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

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
        oracle.setMarketOracle(MARKET_ID, bytes32(uint256(1)), 60);
        book.setFeeConfig(-1e14, 5e14); // maker rebate -0.01%, taker fee 0.05%
        vm.stopPrank();

        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);
    }

    function test_fullLifecycle() public {
        // 1. Deposit
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

        // 2. Alice places limit buy: 0.5 BTC @ $60,000
        vm.prank(alice);
        uint256 aliceOrderId = book.placeOrder(alice, true, 60_000e18, 0.5e18, 1);
        assertEq(aliceOrderId, 1);

        // Required margin: 0.5 * 60,000 * 2% = 600 USDC
        assertEq(vault.orderMargin(alice), 600e18);
        assertEq(vault.balances(alice), 9_400e18);

        assertEq(book.bestBidTick(), 600_000);
        assertEq(book.bestAskTick(), 0);

        // 3. Bob places limit sell: 0.5 BTC @ $60,000 -> matches
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 0.5e18, 1);

        assertEq(book.bestBidTick(), 0);
        assertEq(book.bestAskTick(), 0);

        assertEq(vault.orderMargin(alice), 0);
        assertEq(vault.orderMargin(bob), 0);

        // 4. Verify balances after fees
        // Notional = 0.5 * 60,000 = 30,000
        // Alice (maker): rebate = 30,000 * 0.01% = 3 USDC
        // Bob (taker): fee = 30,000 * 0.05% = 15 USDC
        uint256 aliceExpected = 10_000e18 + 3e18;
        uint256 bobExpected = 10_000e18 - 15e18;
        assertApproxEqAbs(vault.balances(alice), aliceExpected, 1e15);
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

        // Bob sells 1 BTC -> partial fill
        vm.prank(bob);
        book.placeOrder(bob, false, 60_000e18, 1e18, 1);

        assertEq(book.bestBidTick(), 600_000);

        // Alice cancels remaining
        vm.prank(alice);
        book.cancelOrder(aliceOrderId);

        assertEq(book.bestBidTick(), 0);
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
        book.placeOrder(bob, false, 60_000e18, 0.5e18, 1);
        vm.prank(bob);
        book.placeOrder(bob, false, 60_100e18, 0.5e18, 1);

        assertEq(book.bestAskTick(), 600_000);

        // Alice buys 0.8 BTC @ $60,100 -> walks through both levels
        vm.prank(alice);
        book.placeOrder(alice, true, 60_100e18, 0.8e18, 1);

        // 0.5 filled @ $60,000, 0.3 filled @ $60,100
        // Remaining 0.2 ask @ $60,100
        assertEq(book.bestAskTick(), 601_000);
        assertEq(book.bestBidTick(), 0);
    }
}
