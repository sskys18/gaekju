# ADR-0002: Modular Contract Architecture

## Status
Accepted

## Date
2026-04-06

## Context
Gaekju's on-chain CLOB requires several distinct pieces of logic: order matching, position tracking, margin calculations, liquidation, funding rates, oracle integration, collateral management, market creation, and a convenience router. The question is how to organize this logic across contracts.

The simplest approach is a single monolithic contract that does everything. This is how early DeFi protocols were built, but it runs into the EVM's 24KB contract size limit (EIP-170) quickly, and any change to one subsystem requires redeploying the entire protocol. The Diamond pattern (EIP-2535) allows a single address to delegate to multiple "facet" contracts that share storage, but this introduces tight coupling through shared storage slots and makes it harder to test and reason about individual components.

The protocol has natural separation boundaries: the orderbook is stateful per market, the margin engine is pure computation, the liquidation engine orchestrates multiple components, and the vault is a simple accounting ledger. These boundaries suggest separate contracts that interact through well-defined interfaces.

## Decision
We use separate contracts per concern, each behind its own UUPS proxy. The contracts are: OrderBook (one per market, deployed by MarketFactory), PositionManager, MarginEngine, LiquidationEngine, FundingRate, OracleAdapter, Vault, MarketFactory, and Router. Each contract has a defined interface (IOrderBook, IPositionManager, etc.) and interacts with other contracts only through these interfaces.

Authorization between contracts uses OpenZeppelin's AccessControl. Only the OrderBook can call PositionManager.updatePosition(). Only authorized contracts can call Vault.lockMargin(). The Router is a thin convenience layer that composes multi-step operations but holds no state.

## Consequences
### Positive
- Each contract can be upgraded independently without touching the rest of the protocol
- Each contract stays well under the 24KB EIP-170 limit without needing workarounds
- Unit testing is clean: each contract can be tested in isolation with mocked dependencies
- Clear ownership boundaries make code review and auditing easier
- New developers can understand one contract without loading the entire protocol into their head

### Negative
- Cross-contract calls cost more gas than internal function calls (CALL opcode overhead, ~2600 gas per external call)
- State that spans multiple contracts (e.g., a fill that updates the orderbook, positions, and vault) requires careful ordering to maintain consistency
- More contracts means more deployment scripts, more proxy management, and more addresses to track
- Integration testing requires deploying and wiring the full contract suite

### Neutral
- The number of contracts (9 core + libraries) is typical for a DeFi protocol of this scope
- Each contract has a corresponding interface file, doubling the number of Solidity files but improving documentation and type safety
- Storage gaps (`uint256[50] private __gap`) are needed in each contract for upgrade safety, consuming some deployment gas

## Alternatives Considered
### Monolithic Contract
- Pros: Simplest mental model, cheapest gas (no cross-contract calls), single address to interact with
- Cons: Hits 24KB size limit quickly with orderbook + margin + liquidation logic, any change requires full redeployment, testing requires the entire protocol context, single file becomes unmanageable
- Why rejected: The orderbook matching alone approaches the contract size limit. Adding margin, liquidation, and funding logic would require aggressive optimization or splitting into libraries, which provides modularity's complexity without its benefits.

### Diamond Proxy (EIP-2535)
- Pros: Single contract address, shared storage between facets, unlimited contract size, facets can be upgraded independently
- Cons: Shared storage is a footgun (one facet's storage layout change can corrupt another facet's data), delegatecall debugging is painful, tooling support is weaker (Foundry's coverage and debugging work better with standard contracts), audit complexity increases because reviewers must reason about cross-facet storage interactions
- Why rejected: The shared storage model trades deployment convenience for correctness risk. With separate contracts, a bug in the MarginEngine cannot corrupt the OrderBook's storage. With Diamond, it can. The single-address benefit is not worth this risk, especially when the Router provides a unified entry point for common operations.

### Library-Heavy Single Contract
- Pros: Internal library calls are cheap (no CALL overhead), can share storage, simpler deployment
- Cons: Libraries cannot have state (only pure/view functions), so stateful logic still needs to live in the main contract, and the main contract still hits size limits. Using linked libraries (DELEGATECALL) has its own complexity and gas overhead.
- Why rejected: Libraries are used for stateless utilities (BitmapLib, FixedPointMath, PackedOrder, TickMath), but stateful components like the orderbook and position manager need their own storage and access control, which libraries cannot provide.
