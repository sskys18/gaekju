// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/BitmapLib.sol";

contract BitmapLibWrapper {
    function findFirstSet(uint256 bitmap) external pure returns (uint8) {
        return BitmapLib.findFirstSet(bitmap);
    }

    function findLastSet(uint256 bitmap) external pure returns (uint8) {
        return BitmapLib.findLastSet(bitmap);
    }
}

contract BitmapLibTest is Test {
    BitmapLibWrapper wrapper;

    function setUp() public {
        wrapper = new BitmapLibWrapper();
    }

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
        wrapper.findFirstSet(0);
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
        wrapper.findLastSet(0);
    }

    function test_findNextSet() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 10);
        bitmap = BitmapLib.setBit(bitmap, 50);
        bitmap = BitmapLib.setBit(bitmap, 200);
        (bool found, uint8 next) = BitmapLib.findNextSet(bitmap, 10);
        assertTrue(found);
        assertEq(next, 50);
        (found, next) = BitmapLib.findNextSet(bitmap, 50);
        assertTrue(found);
        assertEq(next, 200);
        (found,) = BitmapLib.findNextSet(bitmap, 200);
        assertFalse(found);
    }

    function test_findPrevSet() public pure {
        uint256 bitmap = 0;
        bitmap = BitmapLib.setBit(bitmap, 10);
        bitmap = BitmapLib.setBit(bitmap, 50);
        bitmap = BitmapLib.setBit(bitmap, 200);
        (bool found, uint8 prev) = BitmapLib.findPrevSet(bitmap, 200);
        assertTrue(found);
        assertEq(prev, 50);
        (found, prev) = BitmapLib.findPrevSet(bitmap, 50);
        assertTrue(found);
        assertEq(prev, 10);
        (found,) = BitmapLib.findPrevSet(bitmap, 10);
        assertFalse(found);
    }
}
