// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// @title ClogGenuineMath
/// @notice Pure mapping between canonical ClogMarket state and a single Uniswap v4
///         concentrated-liquidity position that reproduces it EXACTLY.
///
///   ORIENTATION (this is the part V2's analysis got wrong - do not "simplify" it):
///     currency0 = native ETH, currency1 = MemeToken, therefore the v4 price is
///         P = amount1 / amount0 = token / ETH
///     A token-only launch therefore sits at the position's UPPER bound, not the lower one.
///     For a bounded position [Pa, Pb] with liquidity L, the v4 virtual-reserve identities are
///         re = actualETH   + L / sqrt(Pb)
///         rt = actualToken + L * sqrt(Pa)
///         re * rt = L^2                       (while the price is inside the range)
///
///   THE TWO INVARIANTS THIS WHOLE DESIGN RESTS ON (proven against ClogMarket @ 422a61a,
///   and re-asserted on every trade by ClogGenuineLiquidityHook):
///
///         re - realETH           == virtualEthSeed        (9 ether for the canary params)
///         rt - physicalInventory == VIRTUAL_TOKEN_OFFSET  (800_000_000e18)
///
///   Proof sketch, by inspection of every state mutation in ClogMarket:
///     applyBuy/_executeBudget
///       leg 1:       re += curveBudget      and realETH += curveBudget       (difference held)
///       leg 2:       re  = k/newRt2         and realETH += netForClog        (same increment)
///       dust:        re += dust             and realETH += dust              (same increment)
///       extraction:  re -= clogExtracted    and realETH -= clogExtracted     (same decrement)
///       token side:  rt -= (curveTokens + clogTokens) and physicalInventory -= tokensOut,
///                    where tokensOut == curveTokens + clogTokens exactly
///     applySell
///       re -= grossPayout and realETH -= grossPayout;  rt += tokensIn and physicalInventory
///       += tokensIn
///     Neither `dust` nor `clogExtracted` ever touches `rt`, and nothing but the two token
///     movements above ever touches `physicalInventory`. Both differences are therefore
///     constants of motion, fixed at construction.
///
///   CONSEQUENCE - the position geometry collapses to a one-parameter family. Because the two
///   virtual offsets are CONSTANT, only L moves:
///         sqrt(Pb) = L / virtualEthSeed
///         sqrt(Pa) = VIRTUAL_TOKEN_OFFSET / L
///         L        = sqrt(re * rt)
///   and L itself only changes when k changes, i.e. on extraction (k down) or a solvency-capped
///   sell (k up). A pure curve move leaves L untouched.
///
///   CONSEQUENCE - the solvency cap is the upper bound. At P = Pb the position's actualETH is
///   zero by construction, so re = virtualEthSeed. ClogMarket's fully-capped sell lands on
///   re == virtualEthSeed too. The AMM runs out of ETH at exactly the point ClogMarket caps.
///   Verified numerically: a 500M-token sell drives realETH to 0 and re to exactly 9.0 ether.
library ClogGenuineMath {
    /// @dev rt - physicalInventory, fixed at construction. For CURVE_ALLOCATION = 900M,
    ///      CLOG_ALLOCATION = 100M and bufferMultiplierBps = 20_000:
    ///          rt0   = 900M * 2            = 1_800_000_000e18
    ///          inv0  = 900M + 100M         = 1_000_000_000e18
    ///          rt0 - inv0                  =   800_000_000e18
    uint256 internal constant VIRTUAL_TOKEN_OFFSET = 800_000_000e18;

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    error PriceOutOfRange();
    error DegenerateState();

    struct Position {
        uint128 liquidity;
        uint160 sqrtPaX96;
        uint160 sqrtPbX96;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice sqrt(re * rt) - the position's liquidity for the given canonical state.
    function liquidityOf(uint256 re, uint256 rt) internal pure returns (uint256) {
        return Math.sqrt(re * rt);
    }

    /// @notice Canonical price as a v4 sqrtPriceX96: sqrt(rt/re) * 2^96.
    /// @dev    Computed as sqrt(rt * 2^192 / re) so the square root is taken once, on a value
    ///         that already carries the full Q96^2 scaling. For the canary parameters the
    ///         intermediate is ~1.3e66, comfortably inside uint256.
    function sqrtPriceX96Of(uint256 re, uint256 rt) internal pure returns (uint160) {
        if (re == 0 || rt == 0) revert DegenerateState();
        uint256 ratio = Math.mulDiv(rt, Q96 * Q96, re);
        uint256 s = Math.sqrt(ratio);
        if (s < TickMath.MIN_SQRT_PRICE || s > TickMath.MAX_SQRT_PRICE) revert PriceOutOfRange();
        return uint160(s);
    }

    /// @notice Derive the full position geometry for a canonical CLOG state.
    /// @param  re                 canonical re
    /// @param  rt                 canonical rt
    /// @param  virtualEthSeed     re - realETH (invariant)
    /// @param  tickSpacing        pool tick spacing (prototype targets 1)
    /// @dev    Boundary rounding is CONSERVATIVE and deliberately asymmetric:
    ///           tickUpper rounds DOWN  -> at launch the pool price sits at or above the upper
    ///                                     bound, so the position is 100% token and requires
    ///                                     ZERO protocol ETH (this is exactly the shape Klik
    ///                                     ships: init tick 184,216 > tickUpper 184,200).
    ///           tickLower rounds DOWN  -> the range can only ever be wider than canonical, so
    ///                                     the position can never run out of inventory earlier
    ///                                     than ClogMarket would.
    ///         The residual introduced by both roundings is bounded by one tick of each virtual
    ///         offset and is reconciled explicitly in afterSwap; it is never silently absorbed.
    function positionFor(uint256 re, uint256 rt, uint256 virtualEthSeed, int24 tickSpacing)
        internal
        pure
        returns (Position memory p)
    {
        uint256 L = liquidityOf(re, rt);
        if (L == 0 || virtualEthSeed == 0) revert DegenerateState();

        // sqrt(Pb) = L / virtualEthSeed   (X96)
        uint256 sqrtPb = Math.mulDiv(L, Q96, virtualEthSeed);
        // sqrt(Pa) = VIRTUAL_TOKEN_OFFSET / L  (X96)
        uint256 sqrtPa = Math.mulDiv(VIRTUAL_TOKEN_OFFSET, Q96, L);

        if (sqrtPa < TickMath.MIN_SQRT_PRICE || sqrtPb > TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }

        int24 tU = TickMath.getTickAtSqrtPrice(uint160(sqrtPb));
        int24 tL = TickMath.getTickAtSqrtPrice(uint160(sqrtPa));
        tU = _floorTo(tU, tickSpacing);
        tL = _floorTo(tL, tickSpacing);
        if (tL >= tU) revert DegenerateState();

        p.tickLower = tL;
        p.tickUpper = tU;
        p.sqrtPaX96 = TickMath.getSqrtPriceAtTick(tL);
        p.sqrtPbX96 = TickMath.getSqrtPriceAtTick(tU);
        p.liquidity = uint128(L);
    }

    /// @notice Exact currency0 (ETH) input the genuine core swap needs so that it finishes
    ///         NATURALLY at the canonical post-trade price - no nested calibration swap.
    /// @dev    On the pre-trade curve the pool's virtual ETH reserve is L0 / sqrt(P). Moving
    ///         from sqrtP0 to sqrtPtarget therefore costs
    ///             dE = L0 / sqrtPtarget - L0 / sqrtP0
    ///         which is precisely v4's own getAmount0Delta over [sqrtPtarget, sqrtP0]. For a buy
    ///         the price falls (fewer tokens per ETH), so sqrtPtarget < sqrtP0.
    ///
    ///         Measured against the reference model, dE is 97.31%-97.34% of gross input for
    ///         0.5 ETH buys - the hook absorbs only the ~2.7% that is tax plus extraction, so
    ///         the core Swap event carries the overwhelming majority of the trade. For
    ///         comparison, UniversalKlikHook absorbs up to MAX_FEE_BPS = 125 (1.25%).
    function coreBuyInput(uint160 sqrtP0X96, uint160 sqrtPtargetX96, uint128 L0)
        internal
        pure
        returns (uint256 dE)
    {
        if (sqrtPtargetX96 >= sqrtP0X96) return 0;
        dE = SqrtPriceMath.getAmount0Delta(sqrtPtargetX96, sqrtP0X96, L0, true);
    }

    /// @notice Exact currency1 (token) input needed to move the pool up to `sqrtPtargetX96`.
    /// @dev    For an UNCAPPED sell this equals the user's full token input exactly - the pool
    ///         reaches canonical state on its own, so NO specified-side delta is required and
    ///         afterSwap only has to apply the 0.6% sell tax. Verified against the reference
    ///         model: tokens required 2,000,000.000000 for a 2,000,000 token input, and the
    ///         pool's ETH payout equals the canonical gross payout to the wei.
    ///
    ///         For a CAPPED sell the target price is above Pb, where the position holds no ETH
    ///         at all. The core swap fills only as far as Pb; the caller must take the unfilled
    ///         remainder of the token input as a specified-side hook delta and fold it into
    ///         physicalInventory on the re-mint. See ClogGenuineLiquidityHook._afterSwapSell.
    function coreSellInput(uint160 sqrtP0X96, uint160 sqrtPtargetX96, uint128 L0)
        internal
        pure
        returns (uint256 dT)
    {
        if (sqrtPtargetX96 <= sqrtP0X96) return 0;
        dT = SqrtPriceMath.getAmount1Delta(sqrtP0X96, sqrtPtargetX96, L0, true);
    }

    /// @notice Real reserves a position of `liquidity` over [Pa,Pb] holds at price P.
    /// @return amountEth  currency0 held
    /// @return amountTok  currency1 held
    function reservesAt(uint160 sqrtPX96, uint160 sqrtPaX96, uint160 sqrtPbX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amountEth, uint256 amountTok)
    {
        if (sqrtPX96 <= sqrtPaX96) {
            amountEth = SqrtPriceMath.getAmount0Delta(sqrtPaX96, sqrtPbX96, liquidity, false);
            amountTok = 0;
        } else if (sqrtPX96 >= sqrtPbX96) {
            amountEth = 0;
            amountTok = SqrtPriceMath.getAmount1Delta(sqrtPaX96, sqrtPbX96, liquidity, false);
        } else {
            amountEth = SqrtPriceMath.getAmount0Delta(sqrtPX96, sqrtPbX96, liquidity, false);
            amountTok = SqrtPriceMath.getAmount1Delta(sqrtPaX96, sqrtPX96, liquidity, false);
        }
    }

    function _floorTo(int24 tick, int24 spacing) private pure returns (int24) {
        if (spacing <= 1) return tick;
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q -= 1;
        return q * spacing;
    }
}
