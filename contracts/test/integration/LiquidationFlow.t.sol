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
                        PositionManager.initialize, (address(vault), address(engine), address(oracle), admin)
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
            MARKET_ID, ILiquidationEngine.LiquidationConfig({ liquidatorFeeRate: 5e15, insuranceFundFeeRate: 5e15 })
        );
        vm.stopPrank();

        vm.warp(1000);
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
        assertTrue(alicePostLiq.size == 0 || FixedPointMath.abs(alicePostLiq.size) < FixedPointMath.abs(alicePos.size));
    }

    function test_adlFlow() public {
        // Alice: 1 BTC long @ $60,000 with ~$1200 margin (2%)
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
