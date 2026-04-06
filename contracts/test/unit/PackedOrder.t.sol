// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/PackedOrder.sol";

contract PackedOrderTest is Test {
    function test_packUnpack_roundTrip() public view {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(0xBEEF),
            orderId: 42,
            timestamp: uint32(block.timestamp),
            side: true,
            orderType: 1,
            reduceOnly: false,
            price: 60_000e18,
            size: 1e18
        });
        (bytes32 slot0, bytes32 slot1) = PackedOrder.pack(order);
        PackedOrder.Order memory unpacked = PackedOrder.unpack(slot0, slot1);

        assertEq(unpacked.owner, order.owner);
        assertEq(unpacked.orderId, order.orderId);
        assertEq(unpacked.timestamp, order.timestamp);
        assertEq(unpacked.side, order.side);
        assertEq(unpacked.orderType, order.orderType);
        assertEq(unpacked.reduceOnly, order.reduceOnly);
        assertEq(unpacked.price, order.price);
        assertEq(unpacked.size, order.size);
    }

    function test_getPrice() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(1),
            orderId: 1,
            timestamp: 1000,
            side: true,
            orderType: 0,
            reduceOnly: false,
            price: 50_000e18,
            size: 2e18
        });
        (, bytes32 slot1) = PackedOrder.pack(order);
        assertEq(PackedOrder.getPrice(slot1), 50_000e18);
    }

    function test_getSize() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(1),
            orderId: 1,
            timestamp: 1000,
            side: false,
            orderType: 0,
            reduceOnly: false,
            price: 50_000e18,
            size: 3e18
        });
        (, bytes32 slot1) = PackedOrder.pack(order);
        assertEq(PackedOrder.getSize(slot1), 3e18);
    }

    function test_getSide() public pure {
        PackedOrder.Order memory buyOrder = PackedOrder.Order({
            owner: address(1),
            orderId: 1,
            timestamp: 1000,
            side: true,
            orderType: 0,
            reduceOnly: false,
            price: 1e18,
            size: 1e18
        });
        (bytes32 slot0,) = PackedOrder.pack(buyOrder);
        assertTrue(PackedOrder.getSide(slot0));

        PackedOrder.Order memory sellOrder = PackedOrder.Order({
            owner: address(1),
            orderId: 2,
            timestamp: 1000,
            side: false,
            orderType: 0,
            reduceOnly: false,
            price: 1e18,
            size: 1e18
        });
        (slot0,) = PackedOrder.pack(sellOrder);
        assertFalse(PackedOrder.getSide(slot0));
    }

    function test_getOwner() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(0xCAFE),
            orderId: 99,
            timestamp: 5000,
            side: true,
            orderType: 2,
            reduceOnly: true,
            price: 100e18,
            size: 10e18
        });
        (bytes32 slot0,) = PackedOrder.pack(order);
        assertEq(PackedOrder.getOwner(slot0), address(0xCAFE));
    }

    function test_setSize() public pure {
        PackedOrder.Order memory order = PackedOrder.Order({
            owner: address(1),
            orderId: 1,
            timestamp: 1000,
            side: true,
            orderType: 0,
            reduceOnly: false,
            price: 50_000e18,
            size: 10e18
        });
        (, bytes32 slot1) = PackedOrder.pack(order);
        bytes32 newSlot1 = PackedOrder.setSize(slot1, 7e18);
        assertEq(PackedOrder.getSize(newSlot1), 7e18);
        assertEq(PackedOrder.getPrice(newSlot1), 50_000e18);
    }
}
