# Formulas Reference

All values use 18-decimal fixed-point (`1e18 = 1.0`).

```
mulFp(a, b) = a * b / 1e18
divFp(a, b) = a * 1e18 / b
```

## USDC Decimal Conversion

USDC uses 6 decimals. All internal accounting uses 18 decimals.

```
On deposit:  internalAmount = usdcAmount * 1e12
On withdraw: usdcAmount = internalAmount / 1e12
```

## Margin

```
notionalValue = mulFp(abs(positionSize), markPrice)
requiredMargin = mulFp(notionalValue, IMR)
marginRatio = divFp(collateral + unrealizedPnL, notionalValue)
  // Returns type(uint256).max when notionalValue == 0
```

## PnL

```
unrealizedPnL = mulFp(markPrice - entryPrice, positionSize)
  // positionSize: positive = long, negative = short
  // Result: positive = profit, negative = loss
```

## Weighted Average Entry Price

```
newEntryPrice = divFp(
    mulFp(oldEntryPrice, abs(oldSize)) + mulFp(fillPrice, abs(fillSize)),
    abs(oldSize) + abs(fillSize)
)
```

## Mark Price

```
oraclePrice = pyth.getPrice(marketId)
midPrice = (bestBid + bestAsk) / 2
markPrice = oraclePrice * 0.7 + midPrice * 0.3
  // Falls back to oraclePrice if orderbook empty
```

## Funding Rate

```
fundingRate = clamp(
    divFp(markPrice - indexPrice, indexPrice),
    -maxFundingRate,
    +maxFundingRate
)

fundingDelta = currentCumulativeFunding - positionLastCumulativeFunding
fundingPayment = mulFp(mulFp(positionSize, fundingDelta), markPrice)
  // Positive = longs pay, negative = shorts pay
```

## Liquidation

```
isLiquidatable = marginRatio < MMR

// Partial liquidation (post-fee targeting)
equity = collateral + unrealizedPnL
feeRate = liquidatorFeeRate + insuranceFundFeeRate

reduceSize = divFp(
    mulFp(IMR, notionalValue) - equity,
    mulFp(markPrice, IMR + feeRate - 1e18)
)
// Full liquidation if: reduceSize > position.size OR equity <= 0

liquidationFee = mulFp(mulFp(reduceSize, markPrice), feeRate)
```

## Fees

```
notional = mulFp(fillSize, fillPrice)
makerFee = mulFp(notional, makerFeeRate)   // negative = rebate
takerFee = mulFp(notional, takerFeeRate)   // positive = charge
protocolRevenue = takerFee + makerFee       // always net positive
```
