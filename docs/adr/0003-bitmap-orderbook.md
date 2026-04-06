# ADR-0003: Bitmap-Based Orderbook

## Status
Accepted

## Date
2026-04-06

## Context
An on-chain CLOB needs a data structure to track which price levels have active orders and to find the best bid/ask efficiently. This is the core performance bottleneck of the entire protocol: every order placement, cancellation, and match must query and update this structure, and every operation costs gas.

Traditional orderbook implementations in off-chain systems use self-balancing trees (red-black trees, AVL trees) or skip lists. These provide O(log n) insertion, deletion, and best-price lookup. However, on the EVM, these data structures are expensive because each node requires a separate storage slot (SSTORE/SLOAD at 5000-20000 gas each), and tree rebalancing requires multiple pointer updates.

Lighter.xyz pioneered the use of bitmap encoding for on-chain orderbooks. Each bit in a uint256 represents whether orders exist at a given tick (price level). Finding the best bid is a "find last set bit" operation, and finding the best ask is a "find first set bit" operation. Both are O(1) using bit manipulation.

The challenge is scale: a single uint256 covers only 256 ticks. For BTC-USD with a $0.10 tick size, 256 ticks covers only $25.60 of price range, which is insufficient. A two-level bitmap solves this: a top-level bitmap tracks which 256-tick "words" have active ticks, and each word is a second-level bitmap tracking individual ticks.

## Decision
We use a two-level bitmap structure following Lighter's approach. The first level (`bidBitmapIndex` / `askBitmapIndex`) is a uint256 where each bit indicates whether the corresponding second-level word has any active ticks. The second level (`bidBitmaps[wordIndex]` / `askBitmaps[wordIndex]`) contains the actual tick bitmaps. This gives us 256 x 256 = 65,536 ticks of range per side.

For BTC-USD with $0.10 tick size, 65,536 ticks covers $6,553.60 of price range. For most markets and normal trading conditions, this is more than sufficient. Markets with wider price ranges can use larger tick sizes.

Best price lookup: read the top-level bitmap, find the relevant bit (last set for bids, first set for asks), read the corresponding second-level word, find the specific tick. This is 2 SLOADs plus bit math, regardless of how many price levels exist.

## Consequences
### Positive
- O(1) best bid/ask lookup using bit manipulation (findFirstSet / findLastSet), which maps directly to efficient EVM operations
- Inserting or removing a price level is a single bit flip (setBit / clearBit) in the relevant word, plus potentially updating the top-level bitmap
- No tree rebalancing, no pointer chasing, no variable-length storage reads
- Gas cost is predictable and does not degrade as the number of active price levels increases
- The two-level structure gives 65,536 ticks of range, sufficient for all planned markets

### Negative
- Tick granularity is fixed per market at deployment time. If the tick size needs to change, the market must be recreated
- Price range is bounded by the bitmap dimensions. Extreme price moves beyond 65,536 ticks from the reference point would require handling (though this represents a >100% move for most markets)
- Bitmap operations require careful bit-level Solidity code that is harder to read and audit than straightforward mapping lookups
- Orders at each tick still need a FIFO queue (linked list of order IDs), so the bitmap only optimizes price level discovery, not order-level operations

### Neutral
- Each second-level word is a single storage slot (uint256), so the storage layout is compact
- The bitmap approach is well-documented in Lighter's codebase and has been battle-tested in production
- Gas benchmarks should be run during Phase 1 to verify expected performance characteristics on Giwa Chain specifically

## Alternatives Considered
### Sorted Linked List
- Pros: Conceptually simple, unlimited price range, dynamic tick granularity, well-understood data structure
- Cons: O(n) traversal to find insertion point in the worst case, each node is a separate storage slot (minimum 2 SLOADs per hop), gas cost scales linearly with the number of active price levels. A market with 100 active price levels could cost 200+ SLOADs just to find the insertion point.
- Why rejected: Gas cost is prohibitive. On-chain orderbooks need constant-time operations to be viable, and linked lists are fundamentally O(n) for insertion and search.

### Red-Black Tree
- Pros: O(log n) for all operations, proven correctness properties, balanced by construction
- Cons: Each node requires 3+ storage slots (value, left pointer, right pointer, color), rebalancing after insertion/deletion requires 2-3 rotations with multiple SSTOREs each. A tree with 1000 nodes would need ~10 SLOADs for lookup and potentially 6+ SSTOREs for a rebalancing rotation.
- Why rejected: The storage overhead per node and the rebalancing cost make this impractical on the EVM. What is O(log n) in compute becomes O(log n * 5000) in gas, which is far worse than the bitmap's O(1) with 2 SLOADs.

### Single-Level Bitmap (256 ticks)
- Pros: Simpler implementation, single SLOAD for best price lookup, no two-level indirection
- Cons: 256 ticks is too narrow. BTC-USD with $0.10 ticks covers only $25.60, which would be exhausted by normal market activity. Either the tick size must be extremely coarse (losing price precision) or the market must be frequently recreated.
- Why rejected: The price range is insufficient for real markets. The two-level bitmap adds one extra SLOAD but provides 256x the range, which is a decisive tradeoff.

### Mapping-Based (No Bitmap)
- Pros: Unlimited price range and granularity, simple storage model (mapping from tick to order queue), no bit manipulation
- Cons: No efficient way to find the best bid/ask. You would need to scan from the last known best price, checking each tick. If the best price moved 100 ticks since the last update, that is 100 SLOADs. There is no O(1) "find nearest occupied key" operation on EVM mappings.
- Why rejected: The inability to efficiently find the best price makes this a non-starter for an orderbook that needs to match incoming market orders against the best available price.
