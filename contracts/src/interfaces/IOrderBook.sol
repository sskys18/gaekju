// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOrderBook {
    function placeOrder(address trader, bool side, uint256 price, uint256 size, uint8 orderType)
        external
        returns (uint256 orderId);

    function cancelOrder(uint256 orderId) external;

    function bestBidTick() external view returns (uint256);
    function bestAskTick() external view returns (uint256);
    function nextOrderId() external view returns (uint256);

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint256 indexed marketId,
        bool side,
        uint256 price,
        uint256 size,
        uint8 orderType
    );
    event OrderMatched(
        uint256 indexed marketId, uint256 makerOrderId, uint256 takerOrderId, uint256 price, uint256 size
    );
    event OrderCancelled(uint256 indexed orderId, address indexed trader);
    event Fill(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 price,
        uint256 size,
        bool takerSide
    );
}
