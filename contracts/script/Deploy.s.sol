// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MarginEngine} from "../src/MarginEngine.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address pyth = vm.envAddress("PYTH_ADDRESS");

        vm.startBroadcast(deployerPk);

        Vault vault = Vault(
            address(
                new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (usdc, deployer)))
            )
        );

        OracleAdapter oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (pyth, deployer))
                )
            )
        );

        MarginEngine engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), deployer))
                )
            )
        );

        // BTC-USD market (id=0)
        uint256 btcTickSize = 0.1e18;
        OrderBook btcBook = OrderBook(
            address(
                new ERC1967Proxy(
                    address(new OrderBook()),
                    abi.encodeCall(
                        OrderBook.initialize, (0, address(vault), address(engine), btcTickSize, deployer)
                    )
                )
            )
        );

        vault.grantAuthorized(address(engine));
        vault.grantAuthorized(address(btcBook));

        engine.setMarketConfig(
            0,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                tickSize: btcTickSize,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );

        btcBook.setFeeConfig(-1e14, 5e14);

        vm.stopBroadcast();

        console.log("Vault:", address(vault));
        console.log("OracleAdapter:", address(oracle));
        console.log("MarginEngine:", address(engine));
        console.log("BTC OrderBook:", address(btcBook));
    }
}
