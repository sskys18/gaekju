# ADR-0009: UUPS Proxy Pattern

## Status
Accepted

## Date
2026-04-06

## Context
Gaekju's smart contracts are deployed on Giwa Chain, an OP Stack L2 testnet. During the testnet phase, contracts will undergo frequent iteration: parameter tuning (margin rates, funding caps, fee structures), bug fixes discovered through live trading, and feature additions (new order types, ADL improvements, cross-margin preparation, SP1 verification key rotations per ADR-0013). Without an upgrade mechanism, every contract change requires redeploying the entire system, migrating all state (open positions, balances, settlement cursors), and updating every address reference across the backend, frontend, and keeper bots. This is operationally prohibitive for a system with active positions and user balances.

The standard approaches to contract upgradeability in the EVM ecosystem are the Transparent Proxy pattern (EIP-1967), the UUPS pattern (EIP-1822), and the Diamond pattern (EIP-2535). All three separate storage (held by a proxy contract at a stable address) from logic (held by an implementation contract that can be swapped). The key differences are where the upgrade logic lives (in the proxy vs. in the implementation), gas overhead per call, and operational complexity.

Upgradeability introduces trust assumptions: whoever controls the upgrade mechanism can change contract behavior arbitrarily, including draining funds. For a testnet this is acceptable with reasonable guardrails, but the upgrade mechanism must be designed so that mainnet deployment can tighten controls (longer timelocks, higher multisig thresholds, or eventual renouncement of upgrade authority). The architecture must support this progression without requiring contract redeployment.

## Decision
All Gaekju contracts use the UUPS proxy pattern (EIP-1822) with OpenZeppelin's `UUPSUpgradeable` base contract. Upgrades are controlled by a 24-hour Timelock contract owned by a 3-of-5 multisig (Gnosis Safe). The `_authorizeUpgrade()` function in each implementation contract restricts upgrade calls to the Timelock address. An emergency pause mechanism (separate from upgrades) allows any multisig signer to pause trading without waiting for the timelock, but pause cannot modify contract logic or drain funds. All contracts use the initializer pattern (`initialize()` instead of `constructor()`) and include storage gaps (`uint256[50] private __gap`) in every contract to reserve storage slots for future variables.

Settlement's SP1 `programVKey` rotation follows the same governance envelope but is **not** an implementation upgrade. The normal path is a 24-hour timelocked `proposeProgramVKey` → pause-and-drain → `activateProgramVKey` flow. In the non-cooperative-sequencer case documented in design spec §15.5, governance may use `forceActivateProgramVKey` only after a separate `ROTATION_FORCE_TIMELOCK` (default 7 days) with Settlement continuously paused; that path force-asserts `(postStateRoot, batchNonce, forceIncludeCursor)` and rejects queued force-included intents with a dedicated reject code. This is an explicit circuit-breaker, not the default upgrade path.

## Consequences
### Positive
- Stable contract addresses: traders, keepers, and the frontend interact with proxy addresses that never change, even across dozens of upgrades during testnet
- Lower gas overhead than Transparent Proxy: UUPS does not require the proxy to check `msg.sender` on every call to determine whether to delegate or handle an admin function, saving ~2,100 gas per external call. (Note: after ADR-0012 matching runs off-chain, so the primary value of UUPS is upgradeability, not per-call gas savings on a hot matching loop. The gas saving remains a small plus on Vault / Settlement calls but is no longer load-bearing.)
- Upgrade logic lives in the implementation, so a buggy upgrade function can be fixed by deploying a new implementation (unlike Transparent Proxy where the proxy's admin logic is immutable)
- 24-hour timelock provides a window for the community and team to review proposed upgrades before execution, preventing unilateral instant changes
- 3-of-5 multisig eliminates single-key risk: no individual can upgrade contracts or drain funds alone
- Storage gaps allow adding new state variables to existing contracts without colliding with derived contract storage
- The pattern is well-supported by OpenZeppelin's hardhat-upgrades and foundry-upgrades plugins, which validate storage layout compatibility before deployment
- The governance model cleanly distinguishes ordinary upgrades / vkey rotations (24h timelock) from sequencer-hostile recovery (`ROTATION_FORCE_TIMELOCK`, default 7 days, pause-only window)

### Negative
- If the `_authorizeUpgrade()` function is accidentally removed or broken in a new implementation, the contract becomes permanently non-upgradeable (this is the primary UUPS footgun, mitigated by OpenZeppelin's upgrade safety checks)
- Initializer pattern is error-prone: forgetting to call a parent initializer or calling `initialize()` on the implementation contract directly (not the proxy) are common bugs
- 24-hour timelock slows down iteration during active testnet development; critical bug fixes must wait 24 hours unless the emergency pause is sufficient as a stopgap
- The forced vkey-rotation path is a concentrated governance power: after 7 paused days it can assert a settlement state and flush queued force-includes. This is intentionally narrow but it is still trust-heavy.
- Proxy indirection makes debugging harder: transaction traces show delegatecall into the implementation, and storage reads must account for the proxy's storage layout
- Each contract deployment is two transactions (deploy implementation + deploy proxy) instead of one, increasing deployment script complexity

## Alternatives Considered
### Transparent Proxy (EIP-1967)
- Pros: Simpler mental model (proxy handles admin calls, delegates everything else), no risk of losing upgrade capability through implementation bugs, widely deployed and battle-tested (most OpenZeppelin proxy deployments historically used this pattern)
- Cons: Higher gas cost per call (~2,100 gas for the `msg.sender == admin` check on every external call, which compounds across thousands of daily transactions on an active orderbook), admin address cannot interact with the contract as a normal user (the proxy intercepts admin calls), separate ProxyAdmin contract adds deployment complexity
- Why rejected: UUPS provides the same upgradeability with less runtime overhead and a cleaner implementation-owned authorization model. Historically this ADR cited per-call gas savings for frequent on-chain matching as a key factor; after ADR-0012 matching is off-chain and that rationale no longer applies, but the upgradeability, storage-backed Settlement continuity, and implementation-owned authorization arguments remain decisive on their own.

### Diamond Pattern (EIP-2535)
- Pros: Supports unlimited contract size by splitting logic across multiple facets, fine-grained upgradeability (upgrade one function without touching others), single proxy address for the entire protocol
- Cons: Dramatically more complex than UUPS (facet routing, diamond storage, loupe functions), debugging is harder (which facet handled this call?), tooling support is weaker (fewer auditing tools understand Diamond storage layout), the complexity is unjustified when individual contracts are well within the 24KB size limit, fewer auditors are experienced with Diamond patterns
- Why rejected: Gaekju's modular architecture (separate contracts for Settlement, MarginEngine, LiquidationEngine, etc.) already provides the separation that Diamond addresses. Each contract is independently upgradeable via its own UUPS proxy. Diamond would consolidate everything behind a single proxy, which is architecturally opposed to the modular design chosen in ADR-0002. The complexity cost is high with no corresponding benefit.

### No Proxy (Immutable Contracts)
- Pros: Simplest deployment, no proxy overhead, no upgrade trust assumptions, strongest trust guarantees for users (code is law, literally)
- Cons: Any bug fix or parameter change requires deploying entirely new contracts, migrating all state (positions, balances, orderbook state), and updating every address reference in the backend, frontend, and keeper configs. On a testnet where iteration speed is critical, this would reduce deployment cadence from hours to days. Even minor parameter adjustments (changing a maintenance margin rate) would require full redeployment.
- Why rejected: Immutability is the right choice for a mature mainnet protocol, but Gaekju is on testnet with active development. The iteration speed cost of immutable contracts is prohibitive. The upgrade path is designed so that upgrade authority can be renounced on mainnet once the contracts are stable, achieving immutability as an end state rather than a constraint during development.
