// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/TickMath.sol";

contract TickMathWrapper {
    function priceToTick(uint256 price, uint256 tickSize) external pure returns (uint256) {
        return TickMath.priceToTick(price, tickSize);
    }
}

contract TickMathTest is Test {
    TickMathWrapper wrapper;

    function setUp() public {
        wrapper = new TickMathWrapper();
    }

    function test_priceToTick_btc() public pure {
        uint256 price = 60_000e18;
        uint256 tickSize = 0.1e18;
        assertEq(TickMath.priceToTick(price, tickSize), 600_000);
    }

    function test_tickToPrice_btc() public pure {
        uint256 tickSize = 0.1e18;
        assertEq(TickMath.tickToPrice(600_000, tickSize), 60_000e18);
    }

    function test_roundTrip() public pure {
        uint256 tickSize = 0.01e18;
        uint256 price = 3_500.05e18;
        uint256 tick = TickMath.priceToTick(price, tickSize);
        uint256 recovered = TickMath.tickToPrice(tick, tickSize);
        assertEq(recovered, price);
    }

    function test_priceToTick_unaligned_reverts() public {
        uint256 tickSize = 0.1e18;
        uint256 unalignedPrice = 60_000.05e18;
        vm.expectRevert(TickMath.PriceNotAligned.selector);
        wrapper.priceToTick(unalignedPrice, tickSize);
    }

    function test_priceToTick_zero_reverts() public {
        vm.expectRevert(TickMath.ZeroPrice.selector);
        wrapper.priceToTick(0, 0.1e18);
    }

    function test_tickToPrice_zeroTick() public pure {
        assertEq(TickMath.tickToPrice(0, 0.1e18), 0);
    }

    function test_alignPrice() public pure {
        uint256 tickSize = 0.1e18;
        assertEq(TickMath.alignPrice(60_000.15e18, tickSize), 60_000.1e18);
    }

    function test_isAligned() public pure {
        uint256 tickSize = 0.1e18;
        assertTrue(TickMath.isAligned(60_000e18, tickSize));
        assertTrue(TickMath.isAligned(60_000.1e18, tickSize));
        assertFalse(TickMath.isAligned(60_000.05e18, tickSize));
    }

    function test_tickToWordAndBit() public pure {
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
