# ADR-0002: Modular Contract Architecture

## Status
Accepted

## Date
2026-04-06

## Context
Gaekju's protocol requires several distinct pieces of logic: batch settlement (verifying SP1 proofs from the off-chain sequencer, per ADR-0012), position tracking, margin calculations, liquidation, funding rates, oracle integration, collateral management, market creation, and a convenience router. The question is how to organize this logic across contracts.

The simplest approach is a single monolithic contract that does everything. This is how early DeFi protocols were built, but it runs into the EVM's 24KB contract size limit (EIP-170) quickly, and any change to one subsystem requires redeploying the entire protocol. The Diamond pattern (EIP-2535) allows a single address to delegate to multiple "facet" contracts that share storage, but this introduces tight coupling through shared storage slots and makes it harder to test and reason about individual components.

The protocol has natural separation boundaries: Settlement is the single on-chain entry point for proven batch state deltas, the margin engine is pure computation, the liquidation engine orchestrates multiple components, and the vault is a simple accounting ledger. These boundaries suggest separate contracts that interact through well-defined interfaces.

## Decision
We use separate contracts per concern, each behind its own UUPS proxy. The contracts are: Settlement (single global instance proving-and-applying batches from the off-chain sequencer), PositionManager, MarginEngine, LiquidationEngine, FundingRate, OracleAdapter, Vault, MarketFactory, and Router. MarketFactory is config-only under the Path B design; it registers market params but does not deploy per-market Settlement proxies. Each contract has a defined interface (ISettlement, IPositionManager, etc.) and interacts with other contracts only through these interfaces. Note: the bitmap libraries (BitmapLib, PackedOrder, TickMath) were removed along with OrderBook.sol per ADR-0012; only FixedPointMath remains from the original library set.

Authorization between contracts uses OpenZeppelin's AccessControl. Settlement is the sole caller of the batch entry points (`PositionManager.applyBatchFills`, `Vault.applyBatchDelta`, `FundingRate.updateSequencerMid`) and downstream helper calls stay role-gated. The Router is a thin convenience layer that composes user entrypoints (including `forceInclude` per ADR-0014) but holds no state.

## Consequences
### Positive
- Each contract can be upgraded independently without touching the rest of the protocol
- Each contract stays well under the 24KB EIP-170 limit without needing workarounds
- Unit testing is clean: each contract can be tested in isolation with mocked dependencies
- Clear ownership boundaries make code review and auditing easier
- New developers can understand one contract without loading the entire protocol into their head

### Negative
- Cross-contract calls cost more gas than internal function calls (CALL opcode overhead, ~2600 gas per external call)
- State that spans multiple contracts (e.g., a proven batch that updates Vault, FundingRate mid-price state, and positions) requires careful ordering to maintain consistency
- More contracts means more deployment scripts, more proxy management, and more addresses to track
- Integration testing requires deploying and wiring the full contract suite

### Neutral
- The number of contracts (one global Settlement + 8 other core contracts + libraries) is typical for a DeFi protocol of this scope
- Each contract has a corresponding interface file, doubling the number of Solidity files but improving documentation and type safety
- Storage gaps (`uint256[50] private __gap`) are needed in each contract for upgrade safety, consuming some deployment gas

## Alternatives Considered
### Monolithic Contract
- Pros: Simplest mental model, cheapest gas (no cross-contract calls), single address to interact with
- Cons: Hits 24KB size limit quickly with orderbook + margin + liquidation logic, any change requires full redeployment, testing requires the entire protocol context, single file becomes unmanageable
- Why rejected: A monolith would combine proof verification, batch decoding, margin, liquidation, funding, and collateral logic in one address. That pushes the contract toward the size limit and makes any Settlement-path change operationally risky.

### Diamond Proxy (EIP-2535)
- Pros: Single contract address, shared storage between facets, unlimited contract size, facets can be upgraded independently
- Cons: Shared storage is a footgun (one facet's storage layout change can corrupt another facet's data), delegatecall debugging is painful, tooling support is weaker (Foundry's coverage and debugging work better with standard contracts), audit complexity increases because reviewers must reason about cross-facet storage interactions
- Why rejected: The shared storage model trades deployment convenience for correctness risk. With separate contracts, a bug in the MarginEngine cannot corrupt Settlement or Vault storage. With Diamond, it can. The single-address benefit is not worth this risk, especially when the Router provides a unified entry point for common operations.

### Library-Heavy Single Contract
- Pros: Internal library calls are cheap (no CALL overhead), can share storage, simpler deployment
- Cons: Libraries cannot have state (only pure/view functions), so stateful logic still needs to live in the main contract, and the main contract still hits size limits. Using linked libraries (DELEGATECALL) has its own complexity and gas overhead.
- Why rejected: Libraries are used for stateless utilities (BitmapLib, FixedPointMath, PackedOrder, TickMath), but stateful components like the orderbook and position manager need their own storage and access control, which libraries cannot provide.
