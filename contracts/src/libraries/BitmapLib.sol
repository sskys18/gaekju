// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

    function findFirstSet(uint256 bitmap) internal pure returns (uint8) {
        if (bitmap == 0) revert EmptyBitmap();
        uint256 isolated = bitmap & (~bitmap + 1);
        return uint8(_log2(isolated));
    }

    function findLastSet(uint256 bitmap) internal pure returns (uint8) {
        if (bitmap == 0) revert EmptyBitmap();
        return uint8(_log2HighBit(bitmap));
    }

    function findNextSet(uint256 bitmap, uint8 current) internal pure returns (bool, uint8) {
        uint256 mask = type(uint256).max << (current + 1);
        uint256 masked = bitmap & mask;
        if (masked == 0) return (false, 0);
        return (true, findFirstSet(masked));
    }

    function findPrevSet(uint256 bitmap, uint8 current) internal pure returns (bool, uint8) {
        if (current == 0) return (false, 0);
        uint256 mask = (1 << current) - 1;
        uint256 masked = bitmap & mask;
        if (masked == 0) return (false, 0);
        return (true, findLastSet(masked));
    }

    function _log2(uint256 x) private pure returns (uint256 r) {
        if (x >= 1 << 128) {
            x >>= 128;
            r += 128;
        }
        if (x >= 1 << 64) {
            x >>= 64;
            r += 64;
        }
        if (x >= 1 << 32) {
            x >>= 32;
            r += 32;
        }
        if (x >= 1 << 16) {
            x >>= 16;
            r += 16;
        }
        if (x >= 1 << 8) {
            x >>= 8;
            r += 8;
        }
        if (x >= 1 << 4) {
            x >>= 4;
            r += 4;
        }
        if (x >= 1 << 2) {
            x >>= 2;
            r += 2;
        }
        if (x >= 1 << 1) {
            r += 1;
        }
    }

    function _log2HighBit(uint256 x) private pure returns (uint256) {
        return _log2(x);
    }
}
