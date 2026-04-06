// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IVault} from "./interfaces/IVault.sol";
import {BitmapLib} from "./libraries/BitmapLib.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";
import {PackedOrder} from "./libraries/PackedOrder.sol";
import {TickMath} from "./libraries/TickMath.sol";

interface IMarginEngineForOB {
    function getRequiredMargin(uint256 marketId, uint256 size, uint256 price) external view returns (uint256);
    function validateOrder(uint256 marketId, uint256 size, uint256 price) external view;
}

contract OrderBook is IOrderBook, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    using BitmapLib for uint256;

    error NotOrderOwner();
    error OrderNotFound();
    error InsufficientMargin();
    error NoLiquidity();

    uint256 public marketId;
    uint256 public tickSize;
    IVault public vault;
    IMarginEngineForOB public marginEngine;

    // Two-level bitmap: index bitmap tracks which words are active
    uint256 public bidBitmapIndex;
    uint256 public askBitmapIndex;

    // Level 1: tick bitmaps (256 ticks per word)
    mapping(uint256 => uint256) public bidBitmaps;
    mapping(uint256 => uint256) public askBitmaps;

    // FIFO queues per tick
    mapping(uint256 => uint256) public bidHeadAtTick;
    mapping(uint256 => uint256) public bidTailAtTick;
    mapping(uint256 => uint256) public askHeadAtTick;
    mapping(uint256 => uint256) public askTailAtTick;

    // Order storage
    mapping(uint256 => bytes32) public orderSlot0;
    mapping(uint256 => bytes32) public orderSlot1;
    mapping(uint256 => uint256) public nextOrder;

    // Book state
    uint256 public bestBidTick;
    uint256 public bestAskTick;
    uint256 public nextOrderId;

    // Fee config
    int256 public makerFeeRate;
    int256 public takerFeeRate;

    // Track order margin per order for release on cancel/fill
    mapping(uint256 => uint256) public orderMarginAmount;

    uint256[50] private __gap;

    function initialize(
        uint256 _marketId,
        address _vault,
        address _marginEngine,
        uint256 _tickSize,
        address _admin
    ) external initializer {
        __AccessControl_init();
        marketId = _marketId;
        vault = IVault(_vault);
        marginEngine = IMarginEngineForOB(_marginEngine);
        tickSize = _tickSize;
        nextOrderId = 1;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setFeeConfig(int256 _makerFeeRate, int256 _takerFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        makerFeeRate = _makerFeeRate;
        takerFeeRate = _takerFeeRate;
    }

    function placeOrder(address trader, bool side, uint256 price, uint256 size, uint8 orderType)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        marginEngine.validateOrder(marketId, size, price);

        uint256 requiredMargin = marginEngine.getRequiredMargin(marketId, size, price);
        vault.lockOrderMargin(trader, requiredMargin);

        uint256 tick = TickMath.priceToTick(price, tickSize);
        orderId = nextOrderId++;

        uint256 remaining = size;
        uint256 marginUsed = 0;

        if (orderType == 1) {
            remaining = _tryMatch(trader, side, tick, size, orderId);
            uint256 filledSize = size - remaining;
            if (filledSize > 0) {
                marginUsed = FixedPointMath.mulDiv(requiredMargin, filledSize, size);
            }
        }

        // Release taker's order margin for the filled portion
        // (In Phase 2, this converts to position margin via PositionManager)
        if (marginUsed > 0) {
            vault.unlockOrderMargin(trader, marginUsed);
        }

        if (remaining > 0) {
            uint256 restingMargin = requiredMargin - marginUsed;
            _insertOrder(trader, side, tick, remaining, orderId, restingMargin);
            emit OrderPlaced(orderId, trader, marketId, side, price, remaining, orderType);
        } else {
            uint256 leftoverMargin = requiredMargin - marginUsed;
            if (leftoverMargin > 0) {
                vault.unlockOrderMargin(trader, leftoverMargin);
            }
        }
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        bytes32 slot0 = orderSlot0[orderId];
        if (slot0 == bytes32(0)) revert OrderNotFound();
        if (PackedOrder.getOwner(slot0) != msg.sender) revert NotOrderOwner();

        bool side = PackedOrder.getSide(slot0);
        bytes32 slot1 = orderSlot1[orderId];
        uint256 price = PackedOrder.getPrice(slot1);
        uint256 tick = TickMath.priceToTick(price, tickSize);

        _removeOrder(orderId, side, tick);

        uint256 margin = orderMarginAmount[orderId];
        if (margin > 0) {
            vault.unlockOrderMargin(msg.sender, margin);
            delete orderMarginAmount[orderId];
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // ─── Internal: Matching ───

    function _tryMatch(address taker, bool takerSide, uint256 limitTick, uint256 size, uint256 takerOrderId)
        internal
        returns (uint256 remaining)
    {
        remaining = size;
        if (takerSide) {
            remaining = _matchAgainstAsks(taker, limitTick, remaining, takerOrderId);
        } else {
            remaining = _matchAgainstBids(taker, limitTick, remaining, takerOrderId);
        }
    }

    function _matchAgainstAsks(address taker, uint256 limitTick, uint256 remaining, uint256 takerOrderId)
        internal
        returns (uint256)
    {
        uint256 tick = bestAskTick;
        if (tick == 0) return remaining;

        while (remaining > 0 && tick != 0 && tick <= limitTick) {
            uint256 headId = askHeadAtTick[tick];

            while (headId != 0 && remaining > 0) {
                bytes32 s0 = orderSlot0[headId];
                address maker = PackedOrder.getOwner(s0);
                uint256 nextId = nextOrder[headId];

                if (maker == taker) {
                    headId = nextId;
                    continue;
                }

                bytes32 s1 = orderSlot1[headId];
                uint256 makerSize = PackedOrder.getSize(s1);
                uint256 fillSize = FixedPointMath.min(remaining, makerSize);
                uint256 fillPrice = TickMath.tickToPrice(tick, tickSize);

                _executeFill(maker, taker, fillPrice, fillSize, true, headId, takerOrderId);
                remaining -= fillSize;

                if (fillSize == makerSize) {
                    _removeOrderFromQueue(headId, true, tick);
                    headId = nextId;
                } else {
                    orderSlot1[headId] = PackedOrder.setSize(s1, makerSize - fillSize);
                    uint256 makerMargin = orderMarginAmount[headId];
                    uint256 usedMargin = FixedPointMath.mulDiv(makerMargin, fillSize, makerSize);
                    orderMarginAmount[headId] -= usedMargin;
                    break;
                }
            }

            if (askHeadAtTick[tick] == 0) {
                _clearAskTick(tick);
                tick = _findNextAskTick(tick);
            } else {
                break;
            }
        }

        bestAskTick = tick;
        return remaining;
    }

    function _matchAgainstBids(address taker, uint256 limitTick, uint256 remaining, uint256 takerOrderId)
        internal
        returns (uint256)
    {
        uint256 tick = bestBidTick;
        if (tick == 0) return remaining;

        while (remaining > 0 && tick != 0 && tick >= limitTick) {
            uint256 headId = bidHeadAtTick[tick];

            while (headId != 0 && remaining > 0) {
                bytes32 s0 = orderSlot0[headId];
                address maker = PackedOrder.getOwner(s0);
                uint256 nextId = nextOrder[headId];

                if (maker == taker) {
                    headId = nextId;
                    continue;
                }

                bytes32 s1 = orderSlot1[headId];
                uint256 makerSize = PackedOrder.getSize(s1);
                uint256 fillSize = FixedPointMath.min(remaining, makerSize);
                uint256 fillPrice = TickMath.tickToPrice(tick, tickSize);

                _executeFill(maker, taker, fillPrice, fillSize, false, headId, takerOrderId);
                remaining -= fillSize;

                if (fillSize == makerSize) {
                    _removeOrderFromQueue(headId, false, tick);
                    headId = nextId;
                } else {
                    orderSlot1[headId] = PackedOrder.setSize(s1, makerSize - fillSize);
                    uint256 makerMargin = orderMarginAmount[headId];
                    uint256 usedMargin = FixedPointMath.mulDiv(makerMargin, fillSize, makerSize);
                    orderMarginAmount[headId] -= usedMargin;
                    break;
                }
            }

            if (bidHeadAtTick[tick] == 0) {
                _clearBidTick(tick);
                tick = _findPrevBidTick(tick);
            } else {
                break;
            }
        }

        bestBidTick = tick;
        return remaining;
    }

    function _executeFill(
        address maker,
        address taker,
        uint256 price,
        uint256 size,
        bool takerSide,
        uint256 makerOrderId,
        uint256 takerOrderId
    ) internal {
        // Release maker's order margin for the filled portion
        uint256 makerMargin = orderMarginAmount[makerOrderId];
        bytes32 s1 = orderSlot1[makerOrderId];
        uint256 makerTotalSize = PackedOrder.getSize(s1);
        uint256 makerMarginUsed =
            (makerTotalSize == size) ? makerMargin : FixedPointMath.mulDiv(makerMargin, size, makerTotalSize);

        if (makerMarginUsed > 0) {
            vault.unlockOrderMargin(maker, makerMarginUsed);
        }

        // Apply fees
        uint256 notional = FixedPointMath.mulFp(size, price);
        if (makerFeeRate != 0) {
            int256 makerFee = FixedPointMath.mulFpSigned(int256(notional), makerFeeRate);
            vault.realizePnl(maker, -makerFee);
        }
        if (takerFeeRate != 0) {
            int256 takerFee = FixedPointMath.mulFpSigned(int256(notional), takerFeeRate);
            vault.realizePnl(taker, -takerFee);
        }

        emit OrderMatched(marketId, makerOrderId, takerOrderId, price, size);
        emit Fill(marketId, maker, taker, price, size, takerSide);
    }

    // ─── Internal: Book Management ───

    function _insertOrder(address trader, bool side, uint256 tick, uint256 size, uint256 orderId, uint256 margin)
        internal
    {
        uint256 price = TickMath.tickToPrice(tick, tickSize);

        PackedOrder.Order memory order = PackedOrder.Order({
            owner: trader,
            orderId: uint32(orderId),
            timestamp: uint32(block.timestamp),
            side: side,
            orderType: 1,
            reduceOnly: false,
            price: price,
            size: size
        });

        (bytes32 slot0, bytes32 slot1) = PackedOrder.pack(order);
        orderSlot0[orderId] = slot0;
        orderSlot1[orderId] = slot1;
        orderMarginAmount[orderId] = margin;

        if (side) {
            if (bidHeadAtTick[tick] == 0) {
                bidHeadAtTick[tick] = orderId;
                _setBidTick(tick);
            } else {
                nextOrder[bidTailAtTick[tick]] = orderId;
            }
            bidTailAtTick[tick] = orderId;

            if (bestBidTick == 0 || tick > bestBidTick) {
                bestBidTick = tick;
            }
        } else {
            if (askHeadAtTick[tick] == 0) {
                askHeadAtTick[tick] = orderId;
                _setAskTick(tick);
            } else {
                nextOrder[askTailAtTick[tick]] = orderId;
            }
            askTailAtTick[tick] = orderId;

            if (bestAskTick == 0 || tick < bestAskTick) {
                bestAskTick = tick;
            }
        }
    }

    function _removeOrder(uint256 orderId, bool side, uint256 tick) internal {
        if (side) {
            _removeFromBidQueue(orderId, tick);
            if (bidHeadAtTick[tick] == 0) {
                _clearBidTick(tick);
                if (tick == bestBidTick) {
                    bestBidTick = _findPrevBidTick(tick);
                }
            }
        } else {
            _removeFromAskQueue(orderId, tick);
            if (askHeadAtTick[tick] == 0) {
                _clearAskTick(tick);
                if (tick == bestAskTick) {
                    bestAskTick = _findNextAskTick(tick);
                }
            }
        }

        delete orderSlot0[orderId];
        delete orderSlot1[orderId];
        delete nextOrder[orderId];
    }

    function _removeOrderFromQueue(uint256 orderId, bool isAsk, uint256 tick) internal {
        if (isAsk) {
            _removeFromAskQueue(orderId, tick);
        } else {
            _removeFromBidQueue(orderId, tick);
        }

        delete orderSlot0[orderId];
        delete orderSlot1[orderId];
        delete nextOrder[orderId];
        delete orderMarginAmount[orderId];
    }

    function _removeFromBidQueue(uint256 orderId, uint256 tick) internal {
        uint256 head = bidHeadAtTick[tick];
        if (head == orderId) {
            bidHeadAtTick[tick] = nextOrder[orderId];
            if (bidHeadAtTick[tick] == 0) {
                bidTailAtTick[tick] = 0;
            }
            return;
        }
        uint256 current = head;
        while (current != 0) {
            uint256 next = nextOrder[current];
            if (next == orderId) {
                nextOrder[current] = nextOrder[orderId];
                if (orderId == bidTailAtTick[tick]) {
                    bidTailAtTick[tick] = current;
                }
                return;
            }
            current = next;
        }
    }

    function _removeFromAskQueue(uint256 orderId, uint256 tick) internal {
        uint256 head = askHeadAtTick[tick];
        if (head == orderId) {
            askHeadAtTick[tick] = nextOrder[orderId];
            if (askHeadAtTick[tick] == 0) {
                askTailAtTick[tick] = 0;
            }
            return;
        }
        uint256 current = head;
        while (current != 0) {
            uint256 next = nextOrder[current];
            if (next == orderId) {
                nextOrder[current] = nextOrder[orderId];
                if (orderId == askTailAtTick[tick]) {
                    askTailAtTick[tick] = current;
                }
                return;
            }
            current = next;
        }
    }

    // ─── Two-Level Bitmap Operations ───

    function _setBidTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        bidBitmaps[word] = BitmapLib.setBit(bidBitmaps[word], bit);
        bidBitmapIndex = BitmapLib.setBit(bidBitmapIndex, uint8(word & 0xFF));
    }

    function _clearBidTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        bidBitmaps[word] = BitmapLib.clearBit(bidBitmaps[word], bit);
        if (BitmapLib.isEmpty(bidBitmaps[word])) {
            bidBitmapIndex = BitmapLib.clearBit(bidBitmapIndex, uint8(word & 0xFF));
        }
    }

    function _setAskTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        askBitmaps[word] = BitmapLib.setBit(askBitmaps[word], bit);
        askBitmapIndex = BitmapLib.setBit(askBitmapIndex, uint8(word & 0xFF));
    }

    function _clearAskTick(uint256 tick) internal {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(tick);
        askBitmaps[word] = BitmapLib.clearBit(askBitmaps[word], bit);
        if (BitmapLib.isEmpty(askBitmaps[word])) {
            askBitmapIndex = BitmapLib.clearBit(askBitmapIndex, uint8(word & 0xFF));
        }
    }

    /// @dev Max number of words to scan when searching for next/prev tick.
    /// BTC at $100k with $0.10 ticks = word 3906. Scanning 4096 words covers this.
    uint256 internal constant MAX_WORD_SCAN = 4096;

    function _findNextAskTick(uint256 currentTick) internal view returns (uint256) {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(currentTick);

        // Check remaining bits in current word
        (bool found, uint8 nextBit) = BitmapLib.findNextSet(askBitmaps[word], bit);
        if (found) return TickMath.wordAndBitToTick(word, nextBit);

        // Scan forward through words
        for (uint256 w = word + 1; w <= word + MAX_WORD_SCAN; w++) {
            uint256 bitmap = askBitmaps[w];
            if (!BitmapLib.isEmpty(bitmap)) {
                return TickMath.wordAndBitToTick(w, BitmapLib.findFirstSet(bitmap));
            }
        }
        return 0;
    }

    function _findPrevBidTick(uint256 currentTick) internal view returns (uint256) {
        (uint256 word, uint8 bit) = TickMath.tickToWordAndBit(currentTick);

        // Check remaining bits in current word
        (bool found, uint8 prevBit) = BitmapLib.findPrevSet(bidBitmaps[word], bit);
        if (found) return TickMath.wordAndBitToTick(word, prevBit);

        // Scan backward through words
        for (uint256 i = 1; i <= word && i <= MAX_WORD_SCAN; i++) {
            uint256 w = word - i;
            uint256 bitmap = bidBitmaps[w];
            if (!BitmapLib.isEmpty(bitmap)) {
                return TickMath.wordAndBitToTick(w, BitmapLib.findLastSet(bitmap));
            }
        }
        return 0;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
