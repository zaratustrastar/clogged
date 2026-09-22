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
    uint256 internal constant Q96 = 0x1000000000000000000000000;

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
    function solveMargins(Grid memory g, uint256 vEth, uint256 vTok) public pure returns (Weights memory w) {
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
        uint256 hh = Math.mulDiv(w.LAh, w.LBh, g.L);
        uint256 lo = w.LAh + w.LBh > g.L ? w.LAh + w.LBh - g.L : 0;
        uint256 hi = w.LAh < w.LBh ? w.LAh : w.LBh;
        if (hh < lo) hh = lo;
        if (hh > hi) hh = hi;
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

    /// @notice One external call per re-anchor: the complete 2x2 table for a canonical state.
    function allQuads(uint256 re, uint256 rt, uint256 vEth, uint256 vTok)
        external
        pure
        returns (Quad[4] memory out)
    {
        Grid memory g = deriveGrid(re, rt, vEth, vTok);
        Weights memory w = solveMargins(g, vEth, vTok);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = quad(g, w, i);
        }
    }
}
