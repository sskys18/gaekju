# Building a Bitmap Orderbook On-Chain

> Part 02 of "Building a Perp DEX from Scratch"

> **2026-04-22 Retraction:** This post described the original Gaekju on-chain bitmap orderbook design. Under the Path B pivot (ADR-0012), matching moved off-chain to a Rust sequencer with SP1 zkVM proof of correctness. The bitmap orderbook code (BitmapLib, TickMath, PackedOrder, OrderBook.sol) has been deleted. Post preserved for historical reference on EVM bitmap orderbook design — the technique itself remains valid for spot CLOBs on EVM (cf. Clober on Base).

---

Most DEX orderbooks are off-chain. The matching happens on a server, and only settlements land on-chain. We wanted Gaekju's matching to be fully on-chain — no trust assumptions beyond the L2 sequencer. The problem: iterating through price levels in Solidity is expensive. This post explains how we use bitmaps to make it practical.

## The Problem with Naive Orderbooks

A traditional CLOB stores orders at discrete price levels. When a taker order arrives, the matching engine walks the opposite side of the book from the best price inward. In a naive Solidity implementation, you'd store price levels in a sorted array or linked list and iterate:

```
// Pseudocode — DON'T do this
for (uint i = bestAskIndex; i < pricelevels.length; i++) {
    // match against orders at pricelevels[i]
}
```

This is O(n) in the number of empty levels between the best price and the taker's limit price. For BTC with $0.10 tick size, there are 600,000 possible ticks up to $60,000. Walking through empty ticks burns gas for nothing.

## Bitmaps: O(1) Best Price Lookup

A bitmap compresses "is there an order at this tick?" into a single bit. A 256-bit `uint256` represents 256 consecutive ticks. Setting bit 42 means "tick 42 has orders." Finding the best bid means finding the highest set bit — a single operation using binary search over bit positions.

```solidity
library BitmapLib {
    function findLastSet(uint256 bitmap) internal pure returns (uint8) {
        // Binary search: check upper half, lower half, narrow down
        uint256 r;
        if (bitmap >= 1 << 128) { bitmap >>= 128; r += 128; }
        if (bitmap >= 1 << 64)  { bitmap >>= 64;  r += 64; }
        // ... down to single bits
        return uint8(r);
    }
}
```

This runs in constant gas regardless of how many ticks are active.

## Two-Level Bitmaps for Large Tick Ranges

One `uint256` covers 256 ticks. BTC at $60,000 with $0.10 ticks needs tick index 600,000 — that's word 2343 (600,000 / 256). We can't fit all words into a single bitmap.

Our approach: per-word bitmaps stored in a mapping, with a scan to find the next non-empty word when crossing word boundaries:

```solidity
// Word-level: which ticks within a 256-tick range have orders
mapping(uint256 => uint256) public bidBitmaps;  // wordIndex => bitmap

// Tick decomposition
function tickToWordAndBit(uint256 tick) returns (uint256 word, uint8 bit) {
    word = tick >> 8;      // tick / 256
    bit = uint8(tick & 0xFF);  // tick % 256
}
```

Within a single word, finding the next/previous set bit is O(1). Crossing word boundaries requires scanning neighboring words, but in practice the spread is rarely wider than a few words.

## Order Storage: Packed into Two Slots

Each order is packed into two 256-bit storage slots to minimize SSTORE costs:

```
Slot 0: [owner:160][orderId:32][timestamp:32][flags:8][reserved:24]
Slot 1: [price:128][size:128]
```

At each tick, orders form a FIFO linked list. This gives us price-time priority: the oldest order at the best price fills first.

## The Matching Algorithm

When a taker buy order arrives:

1. Start at `bestAskTick`
2. Walk the FIFO queue at that tick, filling against each maker order
3. If the tick is fully consumed, clear the bit in the bitmap
4. Find the next ask tick (next set bit in the bitmap, or scan to the next word)
5. Repeat until the taker order is fully filled or we pass the limit price

```solidity
function _matchAgainstAsks(address taker, uint256 limitTick, uint256 remaining)
    internal returns (uint256)
{
    uint256 tick = bestAskTick;
    while (remaining > 0 && tick != 0 && tick <= limitTick) {
        // Walk FIFO at this tick
        uint256 headId = askHeadAtTick[tick];
        while (headId != 0 && remaining > 0) {
            // Self-trade prevention: skip own orders
            if (maker == taker) { headId = nextOrder[headId]; continue; }

            uint256 fillSize = min(remaining, makerSize);
            executeFill(maker, taker, tick, fillSize);
            remaining -= fillSize;
            // Remove fully filled orders, update partial fills
        }
        // If tick emptied, clear bitmap bit and advance
        if (askHeadAtTick[tick] == 0) {
            clearAskTick(tick);
            tick = findNextAskTick(tick);
        }
    }
    bestAskTick = tick;
    return remaining;
}
```

## Gas Profile

On Giwa Chain (OP Stack L2), typical costs:

| Operation | Gas |
|-----------|-----|
| Place limit order (no match) | ~150k |
| Match against 1 resting order | ~200k |
| Match across 2 price levels | ~300k |
| Cancel order | ~80k |

These are feasible on an L2 with ~2s block times and low gas prices. On L1, this would cost $50+ per trade — on Giwa it's fractions of a cent.

## Self-Trade Prevention

One subtle requirement: a trader's own resting orders must be skipped during matching. Without this, a market maker refreshing quotes could accidentally trade against themselves. Our implementation simply checks `maker == taker` in the inner loop and skips to the next order.

## What We Learned

1. **Bitmaps are the right tool for sparse tick spaces.** The orderbook has 600k+ possible ticks but only dozens are active at any time. Bitmaps make the empty ticks free.

2. **Two-level bitmaps need care at scale.** Our initial implementation used a uint8 word index, which silently aliased word 0 and word 256. We caught this in integration tests when orders at different price levels weren't found after matching. The fix: bounded linear scan over word indices instead of a bitmap-of-bitmaps.

3. **Pack aggressively.** Two storage slots per order (vs 5+ for a naive struct) cuts SSTORE costs by 60%. The PackedOrder library was worth the complexity.

4. **Test the full flow, not just units.** Our unit tests for BitmapLib all passed. The bug only showed up in the integration test where real tick values (590,000 vs 600,000) landed in different bitmap words. Always test with production-scale parameters.

---

**Next up:** [Margin Systems from Scratch](03-margin-from-scratch.md) — how we calculate initial margin, maintenance margin, and handle leverage up to 50x.

---

*This is part of the ["Building a Perp DEX from Scratch"](README.md) series.*
