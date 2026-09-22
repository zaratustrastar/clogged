# Option B — v4-native execution. Implemented, partially green, one structural flaw found.

Branch `v4-genuine-liquidity-prototype`, forked from `422a61a`. `ClogMarket.sol` byte-identical
— it is now only a divergence reference and never drives execution.

## What was built

`src-v4/genuine/ClogGenuineMarket.sol` — every CLOG RULE verbatim (1B/900M/100M, 0.6% taxes,
40/10/50, 10/90, RELEASE_RATIO_BPS 1111, HWM, extraction 40%/50%, dynamic TickerNFT owner,
WinnerPot, pull withdrawals, solvency). The single change: rules operate on what the pool
ACTUALLY executed via `applyBuyActual` / `applySellActual`. The CLOG leg is still a genuine rear
segment of the real fill, priced on the swap's own geometry, not a proportional carve-up.

Removed as instructed: user top-ups, `deferredEthLiability`, legacy-reconciliation residuals.

## Results — 142 passed, 3 failed, 2 skipped

Green: zero-ETH token-only launch · genuine buys (user keeps exactly what the pool gave) ·
**256-run fuzz with full token conservation after every trade** · CLOG driven to **exactly 0
remaining** · owner 40% / multisig 10% / WinnerPot 50% asserted directly · 10/90 extraction split
· HWM and release driven from actual execution · withdrawals pay exact liabilities ·
`re - realETH == 9 ether` and `rt - physicalInventory == 800M` hold throughout.

## The structural flaw (this is the finding that matters)

Three tests fail, and they share one cause:

```
test_3_repeatedBuysAndSells   EthResidualExhausted(0.4128 ETH, 0.0000591 ETH)
test_7_cappedSell             EthResidualExhausted(0.1878 ETH, 0.0000956 ETH)
```

**0.41 ETH is not rounding.** `re`/`rt` are tracked ADDITIVELY from actual amounts, so the price
they imply (`rt/re`) drifts away from the pool's ACTUAL price, because the pool's virtual offsets
are tick-rounded and are not exactly (9 ETH, 800M). The afterSwap traversal then forces the pool
onto the bookkeeping price, and the re-mint needs a materially different amount of ETH.

**The deferred-liability ledger was masking this.** With it in place the suite showed 9/10 green;
removing it — as instructed — exposed a 0.41 ETH structural gap that had been silently absorbed.
Removing the oversized `TICK_LOWER_BUMP` was NOT the cause; restoring it changes nothing.

## Measured divergence from legacy, on the REAL PoolManager

| quantity | Python model predicted | actual PoolManager |
|---|---|---|
| user execution | 3.7e-4 | **1.08e-3 (0.108%)** |
| price | 1.9e-5 | **1.19e-3 (0.119%)** |
| CLOG released | 4.2e-4 | **1.12e-1 (11.2%)** |
| taxes / liabilities | 5.2e-4 | **6.45e-2 (6.45%)** |

The Python model **understated divergence by 1–2 orders of magnitude**. The CLOG-release figure
is the serious one: the rule is applied exactly, but `newTerritory` compounds the per-trade
execution difference across trades. 11% of the 100M allocation is not a microscopic rounding
effect and should not be accepted on the strength of the Python estimate.

## The fix, derived but not implemented

Stop tracking `re`/`rt` additively. **Define them as the pool's virtual reserves** and keep the
ticks FIXED for the pool's lifetime:

```
realETH  = L(1/√P − 1/√Pb)
physInv  = L(√P − √Pa)
```

Two equations, two unknowns (`L`, `P`) with `Pa`,`Pb` fixed — a quadratic in `u = √P`:

```
realETH·√Pb·u² + (physInv − realETH·√Pb·√Pa)·u − physInv·√Pb = 0
```

Ticks are then exact tick prices by construction, so there is no rounding residual at all, and
the implied price cannot drift from the actual price because it IS the actual price. Caution:
the X96 intermediates reach ~1e83 and need rescaling to stay inside uint256.

## Sizes / gas

`ClogGenuineLiquidityHook` 13,744 bytes · `ClogGenuineMarket` 7,026 bytes (EIP-170 24,576).
Buy 957,185 gas. Sell/capped-sell gas not meaningful while those paths fail.

## Not done

Registry launch path, 0.002 ETH fee → Safe, TickerNFT mint via Registry (blocked behind the
above). Robinhood fork suite — V4Quoter / Universal Router / Permit2 — **not run: no
`ROBINHOOD_RPC` on this machine**; must run on `clogrun`.
