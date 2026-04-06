// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library PackedOrder {
    struct Order {
        address owner;
        uint32 orderId;
        uint32 timestamp;
        bool side;
        uint8 orderType;
        bool reduceOnly;
        uint256 price;
        uint256 size;
    }

    function pack(Order memory order) internal pure returns (bytes32 slot0, bytes32 slot1) {
        uint8 flags = (order.side ? 1 : 0) | (uint8(order.orderType & 0x07) << 1) | (order.reduceOnly ? 1 << 4 : 0);

        slot0 = bytes32(
            uint256(uint160(order.owner)) | (uint256(order.orderId) << 160) | (uint256(order.timestamp) << 192)
                | (uint256(flags) << 224)
        );

        slot1 = bytes32(uint256(uint128(order.price)) | (uint256(uint128(order.size)) << 128));
    }

    function unpack(bytes32 slot0, bytes32 slot1) internal pure returns (Order memory order) {
        uint256 s0 = uint256(slot0);
        uint256 s1 = uint256(slot1);
        uint8 flags = uint8(s0 >> 224);

        order.owner = address(uint160(s0));
        order.orderId = uint32(s0 >> 160);
        order.timestamp = uint32(s0 >> 192);
        order.side = (flags & 1) == 1;
        order.orderType = (flags >> 1) & 0x07;
        order.reduceOnly = (flags >> 4) & 1 == 1;
        order.price = uint128(s1);
        order.size = uint128(s1 >> 128);
    }

    function getPrice(bytes32 slot1) internal pure returns (uint256) {
        return uint128(uint256(slot1));
    }

    function getSize(bytes32 slot1) internal pure returns (uint256) {
        return uint128(uint256(slot1) >> 128);
    }

    function getSide(bytes32 slot0) internal pure returns (bool) {
        return (uint256(slot0) >> 224) & 1 == 1;
    }

    function getOwner(bytes32 slot0) internal pure returns (address) {
        return address(uint160(uint256(slot0)));
    }

    function setSize(bytes32 slot1, uint256 newSize) internal pure returns (bytes32) {
        uint256 s1 = uint256(slot1);
        s1 = (s1 & type(uint128).max) | (uint256(uint128(newSize)) << 128);
        return bytes32(s1);
    }
}
