# ADR-0005: USDC-Only Collateral

## Status
Accepted

## Date
2026-04-06

## Context
A perpetual futures exchange needs a collateral system. Traders deposit collateral to open leveraged positions, and that collateral is used to cover losses, pay funding, and absorb liquidation fees. The design question is whether to accept a single collateral asset or multiple assets.

Multi-collateral systems (like dYdX v3 or GMX v2) accept ETH, BTC, stablecoins, and sometimes governance tokens as margin. This increases capital efficiency for traders who already hold these assets but introduces significant complexity: each collateral type needs a price feed, a haircut (discount to account for volatility), liquidation logic that handles collateral price drops alongside position losses, and accounting that tracks multiple denomination currencies.

Single-collateral systems use one stablecoin (typically USDC or USDT) for all margin. This is the model used by Lighter.xyz, Hyperliquid, and most modern perp DEXes. All PnL, margin, and fees are denominated in the same unit, which dramatically simplifies the accounting layer.

USDC is the standard stablecoin for DeFi on OP Stack chains. It has native issuance on most L2s, deep liquidity, and is widely held by DeFi users. USDC uses 6 decimals, while Gaekju's internal accounting uses 18-decimal fixed-point for precision in leverage calculations.

## Decision
Gaekju uses USDC as the sole collateral asset. All deposits, margin, PnL, funding payments, and fee calculations are denominated in USDC. The Vault contract handles decimal conversion at its boundary: deposits multiply by 1e12 (6 to 18 decimals), withdrawals divide by 1e12 (18 to 6 decimals). All other contracts work exclusively in 18-decimal space and are unaware of USDC's native 6-decimal representation.

No multi-collateral support is planned for v1 or v2. If multi-collateral is ever needed, it would be implemented as a separate collateral vault with haircut logic that feeds into the existing margin system.

## Consequences
### Positive
- All accounting is in a single unit, eliminating an entire class of bugs related to cross-asset margin calculation
- No haircut calculations needed, which removes a complex and security-critical parameter that requires ongoing tuning
- No collateral price feeds needed (USDC is the numeraire), reducing oracle dependency
- Liquidation logic only needs to consider position PnL, not collateral value fluctuations
- Simpler for traders to understand: deposit USDC, trade, withdraw USDC
- Insurance fund accounting is straightforward since everything is in the same denomination

### Negative
- Traders must acquire USDC before trading, adding friction for those who primarily hold ETH or other assets
- Capital efficiency is lower for traders with crypto holdings they do not want to sell: they must swap to USDC first
- If USDC depegs, the entire protocol's collateral base is affected (though this is true for any single-collateral system)
- Cannot attract TVL from non-stablecoin holders who want to use their assets as margin

### Neutral
- The 6-to-18 decimal conversion at the Vault boundary is a one-time operation per deposit/withdrawal, adding negligible gas cost
- USDC is the dominant collateral standard for perp DEXes, so this is not an unusual choice and aligns with user expectations
- Rounding on withdrawal (18 to 6 decimal truncation) means users may lose up to 0.000000000001 USDC per withdrawal, which is economically insignificant

## Alternatives Considered
### Multi-Collateral (USDC + ETH + WBTC)
- Pros: Higher capital efficiency for crypto holders, larger potential user base, can attract more TVL by accepting volatile assets as margin
- Cons: Each collateral type needs its own price feed, haircut ratio, and liquidation trigger. Haircuts must be calibrated conservatively (e.g., ETH collateral valued at 90% of spot) and rebalanced as market conditions change. A sharp drop in ETH price could trigger cascading liquidations even if the trader's perpetual position is healthy. Accounting complexity roughly triples per additional collateral type. Insurance fund must hold or convert multiple assets.
- Why rejected: The accounting and risk management complexity is substantial, and the benefit is marginal for a testnet deployment. The dominant perp DEXes (Hyperliquid, Lighter) have proven that USDC-only is the right default for the perp market.

### USDT Instead of USDC
- Pros: Higher global trading volume than USDC, dominant stablecoin in Asian markets
- Cons: Less transparent reserves, weaker regulatory standing, less native L2 issuance on OP Stack chains, more bridged (wrapped) versions with additional smart contract risk
- Why rejected: USDC has better native support on OP Stack L2s and is the DeFi standard for new protocol deployments. The choice is pragmatic rather than ideological.

### DAI / Algorithmic Stablecoin
- Pros: More decentralized than USDC, no single issuer risk
- Cons: DAI is over-collateralized and capital-inefficient as collateral itself, algorithmic stablecoins have a poor track record (UST), less liquidity on L2s, and the "decentralization" benefit is moot when the entire protocol runs on an L2 with a centralized sequencer
- Why rejected: The decentralization benefit does not outweigh the liquidity and stability advantages of USDC for this use case.
