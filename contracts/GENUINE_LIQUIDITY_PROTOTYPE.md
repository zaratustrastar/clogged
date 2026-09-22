# Architecture B — Genuine Liquidity Prototype

Branch `v4-genuine-liquidity-prototype`, forked from `422a61a`. `ClogMarket.sol` byte-identical.

## STATUS (sixth commit) — ETH rounding hypothesis CONFIRMED; randomized still not green

`forge test --profile v4`: **150 passed, 0 failed, 3 skipped**.

### The hypothesis was right

`residualEth` was declared but **never credited** — only consumed. And `_resolve` treated every
positive `r0` as economic revenue, when the continuous algebra only guarantees
`r0 == tax + clogExtracted`. Instrumenting `canonicalLiability` independently from unchanged
`ClogMarket` state showed it immediately, on the very first buy:

```
BUY   actualR0           = 1,637,839,902,439,969
      canonicalLiability = 1,431,907,322,368,047      (derived from ClogMarket, not from r0)
      roundingEth        = +205,932,580,071,922       (+0.000206 ETH)
      residualEth        = 0
```

That +2.06e14 was being paid out as market/RewardVault claims. The later shortfall was only
**-2.7e13**, an order of magnitude smaller — so the reserve would have covered it easily had it
ever been credited. It was accounting, not geometry.

Note the epsilon is **not random noise**: it is the systematic tick-rounding geometry offset
(the rounded position holds less real ETH than canonical at the same price), and it flips sign
with price direction.

### Implemented

Symmetric ETH ledger using native ERC6909 claims (currency id 0, same mechanism V2 uses), zero
external ETH:

```
rounding > 0 : mint(self, rounding);  residualEth += rounding
rounding < 0 : burn(self, need);      residualEth -= need
then          : mint EXACTLY canonicalLiability -> RewardVault (WinnerPot) + market
```

The originally failing seed now **passes**, and fuzzing reaches run ~183 instead of ~4.

### Still NOT solved — randomized differential remains skipped

Two obstacles, both surfaced only by fuzzing:

1. **The token side has the same disease.** `residualToken` drained to 23,196 against a 75,387
   demand. Raising `TICK_LOWER_BUMP` to 6 spacings pushed it further out (launch reserve now
   298,424 tokens, max drawdown 238,868) but did not eliminate it.
2. **Deficit can exceed the trade's own liability.** On trades with little or no tax,
   `payable_` clamps to 0 while the hook's ledger sits at `liab - deficit < 0` and nothing can
   cover it → `CurrencyNotSettled()`.

Per the agreed stop condition, the residual-ledger idea **alone is insufficient**: position
rounding needs revisiting, exactly as anticipated. The token side needs the same
canonical-vs-rounding separation the ETH side just received, and the ETH deficit needs a source
that does not depend on the current trade carrying enough liability.

### Measured

| | |
|---|---|
| launch | 435,561 |
| first buy | **1,096,441** |
| subsequent buy | **769,986** |
| ordinary sell | **642,740** |
| capped sell | **805,424** |
| runtime size | **14,686 bytes** (EIP-170 24,576) |
| launch `residualToken` | 298,424 (0.0298% of supply) |
| max `residualToken` observed | 238,868 |
| max `residualEth` observed | not reportable — fuzz does not complete |

Gas rose ~8% vs the previous commit from the ERC6909 ledger plus the wider tick bump.

### Gaps

1. Randomized differential skipped (above). **Registry/fork work is blocked on it by instruction.**
2. Registry genuine-liquidity launch path not implemented.
3. Complete CLOG exhaustion not reached.
4. Fork suite deferred to `clogrun`.

---

## 1. Orientation (corrected)

`currency0 = native ETH`, `currency1 = token`, so the v4 price is `P = amount1/amount0 = token/ETH`.
A token-only launch therefore sits at the **upper** bound. For a position `[Pa, Pb]`, liquidity `L`:

```
re = actualETH   + L / sqrt(Pb)
rt = actualToken + L * sqrt(Pa)
re * rt = L^2
```

At launch `actualETH = 0` ⟹ `P0 = Pb`. Solving with `Q` = physical tokens deposited:

```
L  = sqrt(re0 * rt0)
Pb = rt0 / re0
Pa = (rt0 - Q)^2 / (re0 * rt0)
```

Verified numerically for `virtualEthSeed = 9 ETH`, `bufferBps = 20_000`, `Q = 1B`:

| quantity | value |
|---|---|
| `L` | `1.27279221e23` |
| `Pb` | `200,000,000` token/ETH |
| `Pa` | `39,506,172.8395` token/ETH |
| reconstruction `actualETH` | `0.000e+00` |
| reconstruction `re` | `9.000000 ETH` (err `1.1e-16`) |
| reconstruction `rt` | `1,800,000,000.00` (err `0`) |

---

## 2. The two invariants

```
re - realETH           == virtualEthSeed        == 9 ether
rt - physicalInventory == VIRTUAL_TOKEN_OFFSET  == 800_000_000e18
```

Proof by inspection of every mutation in `ClogMarket`: `re` and `realETH` always move by the
same signed amount (leg 1, leg 2, `dust`, `clogExtracted`, sell payout); `rt` and
`physicalInventory` always move by the same signed amount (`curveTokens + clogTokens` on a buy,
`tokensIn` on a sell). Neither `dust` nor `clogExtracted` touches `rt`.

**Empirical:** 4,771 randomized buy/sell transitions, **zero violations**.

Consequence — the geometry is a one-parameter family. The virtual offsets are constants, so:

```
sqrt(Pb) = L / virtualEthSeed
sqrt(Pa) = VIRTUAL_TOKEN_OFFSET / L
L        = sqrt(re * rt)
```

`L` moves only when `k` moves: extraction (down) or a capped sell (up). A pure curve move leaves
it untouched.

---

## 3. Target-priced core swap (no calibration swap)

On the pre-trade curve the pool's virtual ETH reserve is `L0 / sqrt(P)`. To finish at
`Ptarget = rt1/re1`:

```
dE = L0/sqrt(Ptarget) - L0/sqrt(P0)      == v4 getAmount0Delta(sqrtPtarget, sqrtP0, L0)
```

**Measured (0.5 ETH buys):**

| buy | gross | `dE` (core) | core/gross | hook absorbs |
|---|---|---|---|---|
| 1 | 0.5000 | 0.48656393 | **97.3128%** | 0.01343607 |
| 4 | 0.5000 | 0.48663172 | 97.3263% | 0.01336828 |
| 8 | 0.5000 | 0.48669778 | **97.3396%** | 0.01330222 |

The core `Swap` event carries ~97.3% of the trade; the hook absorbs only tax + extraction. For
comparison `UniversalKlikHook` absorbs up to `MAX_FEE_BPS = 125` (1.25%) and Sigma trades it.

The token side needs a reconciling `afterSwap` delta of roughly −1.0M to −1.9M tokens on a ~94M
output (~2%), because the pool rides `L0` while canonical `k` shrinks by extraction.

### Sells

**Uncapped — proven to need no specified-side delta.** Moving the pool to `sqrtPtarget` consumes
exactly the user's full token input and pays exactly the canonical gross:

```
tokens needed by pool = 2,000,000.000000   vs input 2,000,000   (diff +1.6e-7, float noise)
pool ETH out          = 0.020516636        canonical gross = 0.020516636
```

`afterSwap` applies only the 0.6% tax.

**Capped — designed explicitly, not inherited.** At `P = Pb` the position holds zero ETH, so
`re = virtualEthSeed`. `ClogMarket`'s fully-capped sell lands on `re == virtualEthSeed` too:

```
huge sell: capped=True  realETH after = 0.000000000  re after = 9.000000000
```

The cap **is** the upper bound. The core swap fills only as far as `Pb`; the hook takes the
unfilled token remainder as a specified-side delta, pays no ETH for it, and folds it into
`physicalInventory` on the re-mint.

---

## 4. Tick residual (`fee = 0`, `tickSpacing = 1`, economics unchanged)

`virtualEthSeed = 9 ETH` and `bufferBps = 20_000` are **untouched**. Boundaries are rounded
conservatively (`tickUpper` down so launch stays token-only with zero ETH; `tickLower` down so
the range can only be wider than canonical). Residual over 10 re-anchors:

| | ETH residual | token residual |
|---|---|---|
| range | `2.0e13` – `4.2e14` wei | `4.1e19` – `4.1e22` |
| bound | ≈ one tick of `L/sqrt(Pb)` ≈ **0.00045 ETH** | ≈ one tick of `L*sqrt(Pa)` ≈ **40,000 tokens** (0.004% of supply) |

Effect on user output at `tickSpacing = 1`: **−0.002369%** (0.24 bps, 1/250th of the 0.6% tax).
At spacing 60 it would be −0.142%, at Klik's spacing 200 it would be −0.472%. Spacing 1 is not
optional.

The residual is held by the hook as `residualEth` / `residualToken`, asserted in tests, and
never netted silently against user output. Multi-position representation is **not** pursued
unless the suite shows this residual is material.

---

## 5. Why static LP was rejected

| buy | user token Δ vs canonical | `re` Δ |
|---|---|---|
| 1 | 0 (match) | +0.220139% |
| 2 | −0.208732% | +0.418718% |
| 10 | **−1.073473%** | +1.502907% |

By buy 10 the error is 1.8× the entire tax. Also: `realETH_static − realETH_clog` equals
cumulative `clogExtracted` **exactly**, i.e. a static LP cannot extract at all — revenue stays
trapped and multisig/WinnerPot are never paid.

`dust` was **identically zero** in every path tested (60 sequential buys, `clogRemaining` down to
27.8M). Extraction is the sole divergence driver. Not proven unreachable in edge cases.

---

## 6. Hook mask

`0x2AC8` → **`0x2ACC`**. Adds `AFTER_SWAP_RETURNS_DELTA` (bit 2), newly required for the
sell-side tax. Retains `BEFORE_ADD_LIQUIDITY` / `BEFORE_REMOVE_LIQUIDITY`, which Klik's pools do
not have. New CREATE2 mining required.

---

## 7. What must be run on `clogrun`

Fetch this exact branch; do not merge, do not modify `v4-v2-calibration-candidate`.

```bash
git fetch origin v4-genuine-liquidity-prototype
git checkout v4-genuine-liquidity-prototype
```

### Step 0 — the load-bearing probe, before anything else

```bash
forge test --profile v4 --fork-url $ROBINHOOD_RPC \
  --match-path test-v4/genuine/ModifyLiquidityInAfterSwapProbe.t.sol -vvvv
```

**RESULT: the load-bearing question is answered POSITIVELY on the real Robinhood fork.**
`modifyLiquidity` from inside `afterSwap`, during the same unlock session, is **admissible and
settleable**. Confirmed on-chain, first run:

| result | evidence |
|---|---|
| Solidity compiles | build succeeded |
| genuine core swap | `amount0 < 0`, `amount1 > 0`, both nonzero |
| `afterSwap` ran | `afterSwapRan == true` |
| first re-anchor mint | `mintSucceeded == true` |
| second re-anchor burn + mint | `burnAttempted`, `burnSucceeded`, `mintSucceeded` all true |
| **no `CurrencyNotSettled`** | both outer `unlock()` calls returned |
| **re-anchor does not move price** | slot0 before == after == `981699536437775202883382546593510` |
| **`noSelfCall` holds** | no gate invocation during the hook's own burn/re-mint |
| replacement position | exists with the intended range and liquidity |

Two assertions failed on the first run and were **false failures in the test, not the platform**;
both are fixed in the third commit:

1. `assertEq(address(POOL_MANAGER).balance, 0)` — invalid on a fork of the live manager, whose
   global native balance carries ETH from unrelated pools. Replaced with position-scoped
   evidence: the `BalanceDelta` returned by our own `modifyLiquidity`
   (`initialLiquidityAmount0 == 0`, `initialLiquidityAmount1 < 0`), plus this contract's ETH
   balance being unchanged across the add.
2. `assertEq(hook.addLiquidityGateCalls(), 0)` — `setUp()` legitimately adds the seed position
   from the TEST contract, a genuine outsider, which correctly fires `beforeAddLiquidity` once.
   Replaced with a baseline captured after `setUp()`, asserted unchanged across both re-anchors.
   Nothing is reset or hidden; real unexpected callbacks still fail.

The probe contains no CLOG economics, so these results are v4-platform facts.

**Read from pinned v4-core v4.0.0 (`e50237c43811bd9b526eff40f26772152a42daba`), not assumed:**

| fact | source |
|---|---|
| `modifyLiquidity` is `onlyWhenUnlocked noDelegateCall` — **no reentrancy guard**, and the lock is still open during `afterSwap` | `PoolManager.sol:148` |
| `_swap()` completes **before** `afterSwap` is called, so `slot0` is already final; the re-anchor must not move it | `PoolManager.sol:185-224` |
| a hook-initiated `modifyLiquidity` accrues its delta to the **hook**, which must settle/take it itself | `PoolManager.sol:180` |
| `modifier noSelfCall(IHooks self) { if (msg.sender != address(self)) { _; } }` | `Hooks.sol:170-174` |
| `beforeModifyLiquidity` carries `noSelfCall`, so the hook's own call does **not** re-enter its add/remove gates | `Hooks.sol:194-199` |
| `unlock()` reverts `CurrencyNotSettled` if `NonzeroDeltaCount != 0` | `PoolManager.sol:112` |

On paper this says the re-anchor is admissible. The probe exists to confirm it on-chain.

**Design notes.** No `try/catch` anywhere near the `modifyLiquidity` calls — a platform rejection
reverts the whole swap with its real reason. `burnSucceeded` / `mintSucceeded` are set only
*after* the calls return, so they can never report success for a call that did not run. The test
swaps **twice**: pass 1 has no hook-owned position and only mints; pass 2 exercises burn +
re-mint. `burnAttempted` distinguishes the two.

**Corrected launch criteria (per your instruction).** `getLiquidity() > 0` is NOT required at a
token-only launch — the live Klik pool has `initial tick 184,216 > tickUpper 184,200`, so
pool-wide active liquidity is legitimately zero until the first buy crosses the upper tick. The
probe therefore asserts:

- a real initialized protocol position exists with **nonzero position liquidity**
  (`getPositionLiquidity`, not `getLiquidity`);
- it holds token and **zero ETH** (`address(POOL_MANAGER).balance == 0`);
- the price starts **above** the range;
- a genuine swap traverses into the range;
- the core `Swap` deltas are nonzero and correctly signed (`amount0 < 0`, `amount1 > 0`);
- **after** the first buy, `getLiquidity() > 0` and `tick < tickUpper`.

V4Quoter / Universal Router / Permit2 coverage is deferred to Step 3 — this probe deliberately
drives `PoolManager` directly so that a failure cannot be blamed on router plumbing.

**If the probe shows `modifyLiquidity` from `afterSwap` is impossible, or its deltas cannot be
settled in the same unlock: STOP.** Architecture B as written is invalid and a deferred /
keeper re-anchor is required. No workaround is implemented in this branch by instruction.

### Step 1 — invariants (no fork needed)

```bash
forge test --profile v4 --match-path test-v4/genuine/ClogGenuineInvariants.t.sol -vv
```

`setUp()` needs wiring to the same fixtures `test-v4/v2/ClogV4HookV2Production.t.sol` builds.

### Step 2 — differential vs reference

Port `reference/clog_reference_model.py` to a Solidity reference or drive it via FFI, then assert
state-for-state equality for: user output, `re`, `rt`, `k`, `realETH`, `sold`, `hwm`,
`clogRemaining`, `rtCeiling`, `physicalInventory`, owner / multisig / WinnerPot credits.

Scenarios: first buy · repeated buys · new-HWM buy · capped-release buy · extraction-heavy buy ·
ordinary sell · capped sell · alternating · randomized.

### Step 3 — real Robinhood integration

`V4Quoter 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` ·
`UniversalRouter 0x8876789976dEcBfCbBbe364623C63652db8C0904` ·
`Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3` ·
`PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951`

Assert: zero-ETH launch · token-only initial position · `getLiquidity > 0` at launch ·
core `Swap` deltas nonzero and economically meaningful · `slot0 == sqrt(rt/re)` after every trade
· no second pool · unauthorized `modifyLiquidity` rejected · withdrawal solvency.

### Step 4 — the cheap Sigma falsification (still unrun)

Independently of CLOG: deploy one throwaway token as a plain Klik-shaped pool (one-sided,
`fee=0`, genuine swap, no CLOG economics). If Sigma trades it, "genuine core swap delta" is
confirmed as the gating property. If it does not, the cause is elsewhere and this entire
redesign is premature. **This is the highest information-per-cost test available and it has
still not been run.**

---

## 8. Known gaps in this commit

- Nothing compiles-checked (no Foundry on the authoring machine). The probe was written against
  the pinned v4.0.0 APIs read directly from `lib/v4-core` — `IPoolManager.ModifyLiquidityParams`,
  `IPoolManager.SwapParams`, `StateLibrary.getPositionLiquidity/getLiquidity/getSlot0`,
  `Position.calculatePositionKey`, `settle()/take()/sync()` — but has never been through `solc`.
- `ClogGenuineInvariants.setUp()` is still unwired; `ClogGenuineLiquidityHook` is still unreviewed
  against pinned signatures. Neither was in scope for this commit.
- Tax/extraction settlement (`_credit`, `take`/`settle`, ERC-6909 WinnerPot claim) is **not**
  implemented in the hook — only the swap-shaping and re-anchor are.
- Registry/launch path for the genuine architecture is not written.
- CREATE2 mining for mask `0x2ACC` not done.
- Gas for burn+mint per trade is an estimate (~250–400k on top of ~120k), never measured.
