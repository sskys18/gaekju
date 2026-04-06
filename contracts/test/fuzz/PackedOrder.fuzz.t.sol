// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/PackedOrder.sol";

contract PackedOrderFuzzTest is Test {
    function testFuzz_packUnpack_roundTrip(
        address owner,
        uint32 orderId,
        uint32 timestamp,
        bool side,
        uint8 orderType,
        bool reduceOnly,
        uint128 price,
        uint128 size
    ) public pure {
        orderType = orderType % 4;

        PackedOrder.Order memory original = PackedOrder.Order({
            owner: owner,
            orderId: orderId,
            timestamp: timestamp,
            side: side,
            orderType: orderType,
            reduceOnly: reduceOnly,
            price: uint256(price),
            size: uint256(size)
        });

        (bytes32 slot0, bytes32 slot1) = PackedOrder.pack(original);
        PackedOrder.Order memory recovered = PackedOrder.unpack(slot0, slot1);

        assertEq(recovered.owner, original.owner);
        assertEq(recovered.orderId, original.orderId);
        assertEq(recovered.timestamp, original.timestamp);
        assertEq(recovered.side, original.side);
        assertEq(recovered.orderType, original.orderType);
        assertEq(recovered.reduceOnly, original.reduceOnly);
        assertEq(recovered.price, original.price);
        assertEq(recovered.size, original.size);
    }
}
