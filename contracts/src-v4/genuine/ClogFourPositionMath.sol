// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title ClogFourPositionMath
/// @notice Exact representation of a canonical CLOG state (re, rt) as FOUR protocol-owned
///         concentrated-liquidity positions on ONE pool: the two neighbouring `Pa` ticks crossed
///         with the two neighbouring `Pb` ticks.
///
///   WHY FOUR. Three constraints must hold simultaneously:
///       SUM Li              = sqrt(re * rt)
///       SUM Li / sqrt(Pb_i) = virtualEthSeed        (9 ether)
///       SUM Li * sqrt(Pa_i) = VIRTUAL_TOKEN_OFFSET  (800M)
///   Each position contributes exactly one free weight. One position: 1 unknown, 3 equations.
///   Two: still over-determined. Three: square, but the solve can demand a negative weight. The
///   2x2 product always works and every weight is nonnegative.
///
///   WHY NOT FIXED TICKS. If `Pa`,`Pb` are frozen and `L` moves with trading/extraction, both
///   offsets scale linearly in `L`. Measured over 15 buys: `L/L0 = 0.988947`, so 9 ETH becomes
///   8.900527 ETH and 800M becomes 791,157,949 — 1.105% off BOTH. That silently redefines the
///   curve, so the ticks must be re-derived every trade.
///
///   EXACTNESS. The two margins are solved in INTEGERS, not interpolated, so both offsets hold
///   exactly rather than approximately. The aggregate ACTUAL reserves then follow automatically:
///       SUM actualETH = L/sqrt(P) - virtualEthSeed = re - virtualEthSeed = realETH
///       SUM actualTok = L*sqrt(P) - VT             = rt - VT             = physicalInventory
///   so there is no residual to fund in any trading state.
///
///   STAGED DELIBERATELY. solc 0.8.26 ICEs under via_ir (and reports plain "Stack too deep"
///   without it) when this is written as one function carrying ~20 live locals. `deriveGrid` /
///   `solveMargins` / `quad` each keep their live set small.
/// @dev Deployed as an immutable CONTRACT, not an inlined library. Inlining `deriveGrid` +
///      `solveMargins` (both return memory structs) into the hook makes solc 0.8.26 ICE under
///      via_ir - bisected: the library compiles standalone, and the hook compiles once those two
///      calls are removed. One external pure call per re-anchor; gas measured in the suite.
contract ClogFourPositionMath {
    /// @notice Which feasible transportation-table solution to use.
    /// @dev LAh and LBh are the ROW and COLUMN sums, so every one of the three continuous
    ///      constraints is satisfied for ANY hh in [lo, hi] - the table is not unique. At either
    ///      endpoint one cell is exactly zero, so the exact representation normally needs only
    ///      THREE live positions, not four. That is not in tension with "a FIXED choice of three
    ///      can demand negative liquidity": here the omitted corner is chosen dynamically from
    ///      the current canonical state, deterministically.
    ///        PRODUCT: hh = LAh*LBh/L  (interior, 4 live cells)
    ///        LO     : hh = max(0, LAh+LBh-L)  -> q00 or q11 is zero
    ///        HI     : hh = min(LAh, LBh)      -> q01 or q10 is zero
    enum HhMode {
        PRODUCT,
        LO,
        HI
    }

    HhMode public immutable hhMode;

    constructor(HhMode m) {
        hhMode = m;
    }

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @dev Liquidity units shaved off each NEAR_BOUNDARY position so the mint can never need
    ///      more token than the burn just returned. See boundaryPair.
    uint256 internal constant TRIM_UNITS = 64;

    error DegenerateState();
    error PriceOutOfRange();

    struct Grid {
        uint256 L;
        int24 al; // lower neighbouring Pa tick
        int24 bl; // lower neighbouring Pb tick
        uint160 Al;
        uint160 Ah;
        uint160 Bl;
        uint160 Bh;
    }

    struct Weights {
        uint256 LAh; // total liquidity assigned to the UPPER Pa tick
        uint256 LBh; // total liquidity assigned to the UPPER Pb tick
        uint256 hh; // the (Ah,Bh) cell
    }

    struct Quad {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice Stage 1 - the ideal bounds and their two neighbouring ticks.
    function deriveGrid(uint256 re, uint256 rt, uint256 vEth, uint256 vTok)
        public
        pure
        returns (Grid memory g)
    {
        if (re == 0 || rt == 0 || vEth == 0) revert DegenerateState();
        g.L = Math.sqrt(re * rt);
        if (g.L == 0) revert DegenerateState();

        uint256 sqrtPb = Math.mulDiv(g.L, Q96, vEth);
        uint256 sqrtPa = Math.mulDiv(vTok, Q96, g.L);
        if (sqrtPa < TickMath.MIN_SQRT_PRICE || sqrtPb > TickMath.MAX_SQRT_PRICE) revert PriceOutOfRange();

        g.al = TickMath.getTickAtSqrtPrice(uint160(sqrtPa));
        g.bl = TickMath.getTickAtSqrtPrice(uint160(sqrtPb));
        g.Al = TickMath.getSqrtPriceAtTick(g.al);
        g.Ah = TickMath.getSqrtPriceAtTick(g.al + 1);
        g.Bl = TickMath.getSqrtPriceAtTick(g.bl);
        g.Bh = TickMath.getSqrtPriceAtTick(g.bl + 1);
    }

    /// @notice Stage 2 - integer margins, so both offsets are EXACT.
    /// @dev  token side: g_x = L*sqrt(Pa_x)  ->  LAh = L*(vTok - g_l)/(g_h - g_l)
    ///       ETH side  : f_x = L/sqrt(Pb_x)  ->  LBh = L*(f_l - vEth)/(f_l - f_h)
    ///       then the 2x2 cell (Ah,Bh) is pinned inside the feasible box so BOTH margins hold.
    function solveMargins(Grid memory g, uint256 vEth, uint256 vTok) public view returns (Weights memory w) {
        {
            uint256 gl = Math.mulDiv(g.L, g.Al, Q96);
            uint256 gh = Math.mulDiv(g.L, g.Ah, Q96);
            w.LAh = (gh > gl && vTok > gl) ? Math.mulDiv(g.L, vTok - gl, gh - gl) : 0;
            if (w.LAh > g.L) w.LAh = g.L;
        }
        {
            uint256 fl = Math.mulDiv(g.L, Q96, g.Bl);
            uint256 fh = Math.mulDiv(g.L, Q96, g.Bh);
            w.LBh = (fl > fh && fl > vEth) ? Math.mulDiv(g.L, fl - vEth, fl - fh) : 0;
            if (w.LBh > g.L) w.LBh = g.L;
        }
        uint256 lo = w.LAh + w.LBh > g.L ? w.LAh + w.LBh - g.L : 0;
        uint256 hi = w.LAh < w.LBh ? w.LAh : w.LBh;
        uint256 hh;
        if (hhMode == HhMode.LO) {
            hh = lo;
        } else if (hhMode == HhMode.HI) {
            hh = hi;
        } else {
            hh = Math.mulDiv(w.LAh, w.LBh, g.L);
            if (hh < lo) hh = lo;
            if (hh > hi) hh = hi;
        }
        w.hh = hh;
    }

    /// @notice Stage 3 - one cell of the 2x2 table.
    /// @dev Index order: 0 = (Ah,Bh), 1 = (Ah,Bl), 2 = (Al,Bh), 3 = (Al,Bl).
    ///      Cell 3 is written `(L + hh) - LAh - LBh`, NOT `L - LAh - LBh + hh`: Solidity
    ///      evaluates left-to-right and `LAh + LBh > L` is exactly the feasible case, so the
    ///      naive form underflows before the `+ hh` ever applies.
    function quad(Grid memory g, Weights memory w, uint256 i) public pure returns (Quad memory q) {
        if (i == 0) return Quad(g.al + 1, g.bl + 1, uint128(w.hh));
        if (i == 1) return Quad(g.al + 1, g.bl, uint128(w.LAh - w.hh));
        if (i == 2) return Quad(g.al, g.bl + 1, uint128(w.LBh - w.hh));
        return Quad(g.al, g.bl, uint128((g.L + w.hh) - w.LAh - w.LBh));
    }

    /// @notice NEAR_BOUNDARY representation: TWO positions sharing the upper bound Bh (the tick
    ///         strictly ABOVE the canonical price), with lower bounds at the two neighbouring Pa
    ///         ticks.
    ///
    ///   WHY THE THREE-POSITION FORM CANNOT BE PATCHED HERE. The ETH-offset margin
    ///   SUM Li/sqrt(Pb_i) = virtualEthSeed needs the Pb ticks to BRACKET the ideal Pb. Since
    ///   P <= Pb always (P/Pb = (vEth/re)^2), the canonical price can rise above the LOWER of
    ///   those two ticks while still below Pb - a sub-tick band, entered at
    ///   realETH < vEth*(sqrt(1.0001)-1) ~ 0.00045 ETH. Any position whose upper bound sits
    ///   below P is out of range and holds no currency0, so the margin stops reconstructing.
    ///   Shifting the bracket up would put vEth outside it, breaking the same margin.
    ///
    ///   WHAT THIS FORM GUARANTEES INSTEAD. Settlement only needs the minted geometry to hold
    ///   EXACTLY (realETH, physicalInventory) at the canonical price - that is what makes
    ///   r0 == canonicalLiability. With both upper bounds at Bh and both positions in range:
    ///       realETH  = (L1+L2) * (1/sqrt(P) - 1/sqrt(Bh))        -> fixes L1+L2
    ///       physInv  = L1*(sqrt(P)-sqrt(Al)) + L2*(sqrt(P)-sqrt(Ah)) -> fixes the split
    ///   Two equations, two unknowns, both in range. The virtual offsets drift within this
    ///   sub-tick band, but the hook reconciles user output exactly and traverses slot0 to the
    ///   canonical price, so canonical ClogMarket state and user output are unaffected.
    function boundaryPair(uint256 realEth, uint256 physInv, uint160 sqrtP, int24 tickBelowP)
        external
        pure
        returns (Quad[2] memory out)
    {
        int24 bh = tickBelowP + 1; // strictly above P
        uint160 Bh = TickMath.getSqrtPriceAtTick(bh);
        if (Bh <= sqrtP || realEth == 0) revert DegenerateState();

        // L_total = realEth * sqrt(P) * sqrt(Bh) / ((sqrt(Bh) - sqrt(P)) * Q96)
        uint256 lTotal;
        {
            uint256 num = Math.mulDiv(realEth, uint256(sqrtP), Q96);
            lTotal = Math.mulDiv(num, uint256(Bh), uint256(Bh) - uint256(sqrtP));
        }
        if (lTotal == 0) revert DegenerateState();

        // pick the Pa bracket from the token side of the same canonical state
        int24 al = TickMath.getTickAtSqrtPrice(uint160(Math.mulDiv(physInv, Q96, lTotal) < uint256(sqrtP)
            ? uint160(uint256(sqrtP) - Math.mulDiv(physInv, Q96, lTotal))
            : TickMath.MIN_SQRT_PRICE + 1));
        uint160 Al = TickMath.getSqrtPriceAtTick(al);
        uint160 Ah = TickMath.getSqrtPriceAtTick(al + 1);

        // L1*(sqrt(P)-Al) + (lTotal-L1)*(sqrt(P)-Ah) = physInv*Q96
        //   => L1 = (physInv*Q96 - lTotal*(sqrt(P)-Ah)) / (Ah - Al)
        uint256 rhsTotal = Math.mulDiv(lTotal, uint256(sqrtP) - uint256(Ah), Q96);
        uint256 l1;
        if (physInv > rhsTotal && Ah > Al) {
            l1 = Math.mulDiv(physInv - rhsTotal, Q96, uint256(Ah) - uint256(Al));
        }
        if (l1 > lTotal) l1 = lTotal;

        // Conservative trim. PoolManager rounds the amount OWED for a mint UP, ~1 wei per
        // position, so the pair can need a few token-wei more than the burn returned - measured
        // exactly 3 wei short at bootstrap. Token per unit of liquidity here is physInv/L
        // (~1.4e4 wei), so shaving a few units frees far more than enough. ETH per unit of
        // liquidity is realETH/L (~1e-9 wei), so the currency0 backing is untouched.
        uint256 l2 = lTotal - l1;
        if (l1 > TRIM_UNITS) l1 -= TRIM_UNITS;
        if (l2 > TRIM_UNITS) l2 -= TRIM_UNITS;

        out[0] = Quad(al, bh, uint128(l1));
        out[1] = Quad(al + 1, bh, uint128(l2));
    }

    /// @notice One external call per re-anchor: the complete 2x2 table for a canonical state.
    function allQuads(uint256 re, uint256 rt, uint256 vEth, uint256 vTok)
        external
        view
        returns (Quad[4] memory out)
    {
        Grid memory g = deriveGrid(re, rt, vEth, vTok);
        Weights memory w = solveMargins(g, vEth, vTok);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = quad(g, w, i);
        }
    }
}
