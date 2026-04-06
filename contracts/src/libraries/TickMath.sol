// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

    function tickToWordAndBit(uint256 tick) internal pure returns (uint256 word, uint8 bit) {
        word = tick >> 8;
        bit = uint8(tick & 0xFF);
    }

    function wordAndBitToTick(uint256 word, uint8 bit) internal pure returns (uint256) {
        return (word << 8) | uint256(bit);
    }
}
