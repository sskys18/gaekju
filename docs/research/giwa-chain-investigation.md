# Giwa Chain Investigation

Date: 2026-04-22
Purpose: Evaluate Giwa Chain (OP Stack L2) as host for Gaekju, a Lighter-style fully on-chain perpetual CLOB.

## TL;DR

Giwa is an obscure, early-stage L2. Public information is limited — most documentation is marketing-level, and L2BEAT lists the project as "upcoming" with nearly every risk row marked "Coming soon". Most numbers below are either from the official docs (thin) or extrapolated from OP Stack defaults. Treat any figure that is not explicitly cited as Giwa-specific as an OP Stack assumption, not a Giwa guarantee.

## 1. Status, operator, governance

- Giwa Chain is an Ethereum L2 built on the OP Stack by Dunamu Inc., the parent company of Korean exchange Upbit. Announced at Upbit D Conference (UDC) on 2025-09-09. [cointelegraph](https://cointelegraph.com/news/south-korea-crypto-exchange-ubit-launches-ethereum-l2), [blocmates](https://www.blocmates.com/news-posts/korea-enters-the-rollup-race-upbit-parent-company-unveils-giwa-chain)
- Testnet name: "Giwa Sepolia" (settles to Ethereum Sepolia). Chain ID `91342`. Over 4M blocks observed at announcement (consistent with ~1s block time). [docs.giwa.io](https://docs.giwa.io/giwa-chain/en/get-started/connect-to-giwa), [chainlist](https://chainlist.wtf/chain/91342/)
- Mainnet: not live as of research date. Original guidance was Q4 2025; no public mainnet at time of writing (2026-04-22). Giwa Wallet also listed as under development. [docs.giwa.io](https://docs.giwa.io/undefined/en)
- Gas token: ETH (explicitly chosen over a native token, reportedly to sidestep Korean regulatory issues with issuer tokens). [blockonomi](https://blockonomi.com/south-korean-exchange-upbit-launches-ethereum-l2-blockchain-giwa/)
- Sequencer: single sequencer operated by Dunamu / Upbit. L2BEAT has no decentralization data yet. [panewslab](https://www.panewslab.com/en/articles/0308a43f-5f60-4949-8390-c63f9b2c87d9), [l2beat](https://l2beat.com/scaling/projects/giwa)
- Governance: no published on-chain governance. Multisig/Security-Council details not disclosed.

## 2. OP Stack config

From Giwa's "Differences between Ethereum and GIWA" doc:
- Block time: 1 second (vs 12s on L1). [docs.giwa.io diffs](https://docs.giwa.io/giwa-chain/en/network-information/diffs-ethereum-giwa)
- Block gas limit: 60,000,000 (vs 45M on Ethereum at time of docs).
- Production: sequencer-based, no public mempool (only the sequencer sees pending txs).
- Block states: unsafe (sequencer) -> safe (batched to L1) -> finalized (L1 finality).
- Cross-chain: standard OP Stack address aliasing; withdrawals subject to fault-proof challenge window (7 days by OP Stack default).

Not disclosed by Giwa: batcher cadence, channel timeout, exact calldata vs blob policy, blob target, sequencer window, challenger set. Assume OP Stack post-Ecotone defaults (Ecotone/Fjord era gas accounting, blob DA by default).

Fault proofs / stage:
- L2BEAT lists GIWA as "Optimistic" but stage, proof system, DA, forced-inclusion, and upgradeability rows are all "Coming soon". No TVL/TVS data. [l2beat](https://l2beat.com/scaling/projects/giwa)
- Effectively Stage 0 at launch (typical for new OP Stack chains — OP Mainnet and Base only reached Stage 1 in 2024 after fault-proof rollout). [optimism.io fault proofs blog](https://www.optimism.io/blog/the-fault-proof-system-is-available-for-the-op-stack)

## 3. Throughput

- No Giwa-specific TPS benchmarks published.
- Theoretical ceiling from gas limit + block time: 60M gas / 1s = 60M gas/s. For a typical 200k-gas tx that caps at ~300 TPS sustained; for simple 21k-gas transfers ~2,850 TPS ceiling. Real CLOB order placement is gas-heavier than a transfer, so expect well below theoretical.
- Flashblocks: ~200ms preconfirmations exposed via a Flashblocks-aware RPC; does NOT produce blocks faster, only earlier receipts against a `pending` tag. [docs.giwa.io flashblocks](https://docs.giwa.io/giwa-chain/en/network-information/flashblocks)
- Bottlenecks to expect on OP Stack at this block cadence: sequencer single-threaded EVM, L1 blob throughput (6 blobs/block target post-Pectra), and batcher submission lag.

## 4. Fees

- No published Giwa fee oracle values. Fee model is the standard OP Stack two-part cost: L2 execution gas (priced in ETH at L2 base fee) + L1 data fee (priced from blob base fee via the GasPriceOracle after Ecotone). [optimism docs fees](https://docs.optimism.io/op-stack/transactions/fees)
- After EIP-4844 on OP-Stack chains, L1 data cost for a typical tx dropped to single-digit cents; illustrative figures cited in the literature: pre-blob ~$2.47 all-in vs ~$0.10 post-blob for a representative L2 tx. [medium: Ecotone gas](https://medium.com/quarkchain-official/op-stack-ecotone-upgrade-gas-cost-explained-affcb78abf1f)
- For a 200k-gas Gaekju order-placement tx on Base today, all-in cost is typically ~$0.01-$0.05 depending on L1 blob base fee and L2 base fee. Giwa should be in the same order of magnitude assuming it follows OP Stack defaults. Exact USD figure for Giwa: not public.

## 5. Sequencer centralization / escape hatch

- Single sequencer, Dunamu-operated. No public decentralization roadmap.
- Forced inclusion: L2BEAT row "Coming soon" — assume OP Stack default forced-inclusion via L1 `OptimismPortal.depositTransaction` (7-day challenge window when fault proofs active; otherwise governed by a privileged proposer).
- Escape hatch: Standard OP Stack withdrawal through `L2ToL1MessagePasser` -> `OptimismPortal` once proven + challenge window passes. Effectiveness depends on whether fault proofs are live on Giwa mainnet at launch (unconfirmed; likely not initially).
- MEV: no public-mempool means private sequencer ordering — low retail MEV, high operator trust requirement. This is both a pro (no sandwich attacks) and con (single entity sees all order flow).

## 6. Tooling

- Oracles: no confirmed Pyth or Chainlink deployments on Giwa. Neither vendor lists Giwa on their supported-chains pages. For Gaekju this means either (a) running our own oracle adapter and feeding prices via a trusted signer, (b) waiting for Pyth/Chainlink to deploy, or (c) bridging price data via CCIP / Pyth Lazer from an already-supported chain. Risk: block if we assume presence.
- USDC: no native Circle USDC on Giwa at research time. Upbit's stated roadmap mentions KRW and global stablecoins as a focus, but CCTP support is not announced. Initially Gaekju would need bridged USDC via Giwa's canonical bridge (standard OP Stack bridge UX: L1->L2 ~1min, L2->L1 7-day challenge). [bridge-giwa](https://bridge-giwa.vercel.app)
- RPC: `https://sepolia-rpc.giwa.io/` (rate-limited, dev only), flashblocks variant `https://sepolia-rpc-flashblocks.giwa.io/`. Explorer: `https://sepolia-explorer.giwa.io`. No mainnet endpoints yet. Third-party providers (Alchemy, QuickNode, Infura) not yet supporting Giwa publicly.
- Ecosystem services announced by Giwa: Dojang (EAS-based attestation), Giwa Wallet (WIP). [iq.wiki](https://iq.wiki/wiki/giwa)

## 7. Ecosystem / MEV / PBS

- No major DEXs live. No Flashbots-style PBS infra. No reported public MEV-boost / builder market for Giwa.
- Being a Superchain-lineage OP Stack chain it can plausibly adopt op-rbuilder, Flashblocks (already has), and eventually Superchain interop, but none are production-ready on Giwa today.
- Upbit listing access is the one real ecosystem edge — a Korean-exchange pipeline for KRW on/off-ramp.

## 8. Known risks

- Extremely short operational history (~7 months testnet, no mainnet). No reorg, downtime, or sequencer-failure incident record — positive or negative, simply absent.
- Dunamu operates sequencer AND parent exchange: large MEV / order-flow visibility risk if a perp DEX runs here.
- Fault proofs and decentralization timeline undisclosed (L2BEAT rows all "Coming soon"). Governance upgrade keys likely held by a Dunamu multisig; no Security Council documented.
- No confirmed institutional-grade oracle and no native USDC — the two hard blockers for a leveraged perp DEX.
- Regulatory exposure: Korean FSC stance on derivatives for retail is restrictive; operating a perp on a Korean-exchange-operated L2 invites heightened regulatory attention regardless of protocol decentralization.

## 9. Comparison vs alternatives for a CLOB perp DEX

| Dimension              | Giwa                               | Base                              | OP Mainnet                        | Arbitrum One                      | Blast                              |
|------------------------|------------------------------------|-----------------------------------|-----------------------------------|-----------------------------------|------------------------------------|
| Stack                  | OP Stack                           | OP Stack                          | OP Stack                          | Nitro (Arb tech)                  | OP Stack fork                      |
| Block time             | 1s (Flashblocks ~200ms preconf)    | 2s (Flashblocks 200ms)            | 2s                                | ~0.25s                            | 2s                                 |
| Stage (L2BEAT)         | Not rated (Stage 0 de facto)       | Stage 1                           | Stage 1                           | Stage 1                           | Stage 0                            |
| Fault proofs           | Unknown                            | Live                              | Live                              | Live (BoLD)                       | Not live                           |
| Sequencer              | Dunamu (single)                    | Coinbase (single)                 | OP Labs (single)                  | Offchain Labs (single)            | Blast team (single)                |
| Native USDC (CCTP)     | No                                 | Yes                               | Yes                               | Yes                               | No                                 |
| Pyth / Chainlink       | No confirmed deploy                | Both live                         | Both live                         | Both live                         | Both live                          |
| MEV / PBS infra        | None                               | op-rbuilder, Flashblocks          | Limited                           | Timeboost auction                 | Limited                            |
| TVL / liquidity depth  | ~0 (no mainnet)                    | Large                             | Large                             | Largest L2                        | Mid                                |
| Existing perp DEXs     | None                               | Aerodrome spot, perp v limited    | Synthetix, Kwenta                 | GMX, Vertex, Hyperliquid bridge   | Thruster, Blitz perps              |

Implication for Gaekju: Giwa offers the headline feature set (1s blocks, blob DA, EVM) but is missing every piece of ecosystem infra a CLOB perp DEX actually depends on — oracles, native USDC, real liquidity, proven sequencer behavior, and third-party RPC/indexing. Base or Arbitrum are strictly safer operational choices today; Giwa only makes sense if the goal is explicitly to be the flagship DEX for Upbit's L2 and we're willing to operate our own oracle adapter, accept bridged USDC, and live with Stage-0 trust assumptions.

## Sources

- [Giwa docs — Connect to Giwa](https://docs.giwa.io/giwa-chain/en/get-started/connect-to-giwa)
- [Giwa docs — Differences between Ethereum and Giwa](https://docs.giwa.io/giwa-chain/en/network-information/diffs-ethereum-giwa)
- [Giwa docs — Flashblocks](https://docs.giwa.io/giwa-chain/en/network-information/flashblocks)
- [Giwa docs — Introducing GIWA](https://docs.giwa.io/giwa-chain/en)
- [L2BEAT — GIWA](https://l2beat.com/scaling/projects/giwa)
- [CoinMarketCap Academy — Upbit launches Giwa L2 testnet](https://coinmarketcap.com/academy/article/upbit-launches-giwa-ethereum-l2-chain-on-testnet-platform)
- [Cointelegraph — Upbit launches Giwa](https://cointelegraph.com/news/south-korea-crypto-exchange-ubit-launches-ethereum-l2)
- [Blocmates — Korea enters the rollup race](https://www.blocmates.com/news-posts/korea-enters-the-rollup-race-upbit-parent-company-unveils-giwa-chain)
- [PANews — Upbit GIWA coinless L2](https://www.panewslab.com/en/articles/0308a43f-5f60-4949-8390-c63f9b2c87d9)
- [Blockonomi — Upbit launches Giwa](https://blockonomi.com/south-korean-exchange-upbit-launches-ethereum-l2-blockchain-giwa/)
- [IQ.wiki — Giwa](https://iq.wiki/wiki/giwa)
- [Chainlist — GIWA Sepolia 91342](https://chainlist.wtf/chain/91342/)
- [Optimism docs — Transaction fees on OP Mainnet](https://docs.optimism.io/op-stack/transactions/fees)
- [Optimism blog — Fault proofs available on OP Stack](https://www.optimism.io/blog/the-fault-proof-system-is-available-for-the-op-stack)
- [QuarkChain — Ecotone gas cost explained](https://medium.com/quarkchain-official/op-stack-ecotone-upgrade-gas-cost-explained-affcb78abf1f)
- [L2BEAT — Stages framework](https://l2beat.com/stages)
