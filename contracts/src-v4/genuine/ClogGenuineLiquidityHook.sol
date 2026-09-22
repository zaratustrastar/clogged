// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {ClogMarket} from "../ClogMarket.sol";
import {ClogGenuineMath} from "./ClogGenuineMath.sol";
import {ClogFourPositionMath} from "./ClogFourPositionMath.sol";
import {ClogFourPositionMath as FP} from "./ClogFourPositionMath.sol";

interface IRewardVaultRecorderG {
    function recordWinnerPotClaim(uint256 amount) external;
}

interface IERC20LikeG {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amt) external returns (bool);
}

/// @title ClogGenuineLiquidityHook
/// @notice Genuine nonzero user swaps against protocol-owned liquidity on ONE pool, with EXACT
///         unchanged-ClogMarket economics. No sentinel, no calibration swap, no bypass pool, no
///         protocol ETH seed.
///
///   GEOMETRY BOOTSTRAP. Four positions cannot represent the zero-ETH launch: a token-only
///   launch must sit ABOVE the range, and above the range the token requirement is
///   SUM Li*(sqrt(Pb_i) - sqrt(Pa_i)), which is NOT physicalInventory - measured 0.617 tokens
///   over the 1B supply. The pool therefore passes through two explicit modes:
///       SINGLE_LAUNCH : one token-only position, zero protocol ETH
///       FOUR_EXACT    : installed by the FIRST afterSwap, used forever after
///   Four-position geometry is never assumed before the first re-anchor.
///
///   BUY PATH. Deliberately NOT simplified to `gross - tax`. applyBuy splits the budget across a
///   curve leg and a CLOG leg, may leave dust, and extraction lowers `re` at constant `rt` AFTER
///   the token output is fixed. So the core swap receives exactly dE - the input that walks the
///   pre-trade curve to the canonical post-trade price - and afterSwap reconciles the token side:
///       core token output + hook token delta == canonical tokensOut
///       net ETH retained by the hook         == canonical realETH change
///
///   CAPPED SELLS keep the proven zero-liquidity traversal.
contract ClogGenuineLiquidityHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    enum GeometryMode {
        NONE,
        SINGLE_BOUNDARY,
        FOUR_EXACT
    }

    IPoolManager public immutable poolManager;
    address public immutable registry;
    address public rewardVault;
    ClogFourPositionMath public immutable geometry;

    /// @dev Target settlement surplus per re-anchor, in wei of currency0. Set above the measured
    ///      4-7 wei one-directional ETH shortfall with headroom.
    /// @notice Strict per-trade upper bound on the v4 settlement cost, in wei of currency0.
    ///         Measured worst case is 7 wei across PRODUCT/LO/HI over 50-trade sequences; this
    ///         is an order of magnitude above it and is ASSERTED, not assumed.
    uint256 internal constant MAX_SETTLEMENT_COST = 100;

    struct PoolState {
        address market;
        uint256 virtualEthSeed;
        bool registered;
        GeometryMode mode;
    }

    struct Pending {
        bool isBuy;
        uint256 canonicalOut;
        uint256 winnerPotShare;
        uint256 absorbed;
        uint256 re1;
        uint256 rt1;
        /// @dev Derived from ClogMarket.realETH pre/post, NEVER from the observed r0, so
        ///      settlement can assert the identity independently.
        ///        BUY : grossIn - (realETH1 - realETH0)  == buyTax + clogExtracted
        ///        SELL: (realETH0 - realETH1) - netOut   == sellTax
        uint256 canonicalLiability;
        uint256 realEth1;
    }

    mapping(PoolId => PoolState) public pools;
    /// @dev Four protocol-owned positions, kept OUT of PoolState: a fixed-size struct array in a
    ///      mapped struct is one of the constructs that pushed solc 0.8.26 over its stack budget.
    mapping(PoolId => mapping(uint256 => FP.Quad)) internal quads;
    mapping(address => bool) public isMarket;
    /// @notice Tokens held by the hook: the SINGLE_LAUNCH bootstrap remainder plus any
    ///         unavoidable integer-wei dust PoolManager leaves. Bounded in tests.
    mapping(PoolId => uint256) public residualToken;
    /// @notice Cumulative v4 settlement cost absorbed by the WinnerPot residual. Asserted.
    mapping(PoolId => uint256) public settlementCostPaid;

    Pending internal _p;
    address internal _withdrawMarket;

    error NotPoolManager();
    error NotRegistry();
    error UnauthorizedLiquidity();
    error ExactOutputUnsupported();
    error UnknownMarket();
    error VaultNotSet();

    /// @notice r0/r1 vs the INDEPENDENTLY derived canonical liability. Emitted every trade so
    ///         the suite can assert the identity rather than infer it from r0 itself.
    event SettleCheck(bool isBuy, int256 r0, int256 r1, uint256 canonicalLiability);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager pm, address registry_, ClogFourPositionMath geometry_) {
        poolManager = pm;
        registry = registry_;
        geometry = geometry_;
    }

    /// @dev Explicit getter: the auto-generated getter for a nested mapping returning a struct
    ///      is what made solc 0.8.26 ICE under via_ir here.
    function positionAt(PoolId id, uint256 i)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        FP.Quad memory q = quads[id][i];
        return (q.tickLower, q.tickUpper, q.liquidity);
    }

    function geometryMode(PoolId id) external view returns (GeometryMode) {
        return pools[id].mode;
    }

    function setRewardVault(address v) external {
        if (msg.sender != registry) revert NotRegistry();
        rewardVault = v;
    }

    function registerPool(PoolKey calldata key, address market, uint256 seed) external {
        if (msg.sender != registry) revert NotRegistry();
        PoolState storage ps = pools[key.toId()];
        ps.market = market;
        ps.virtualEthSeed = seed;
        ps.registered = true;
        isMarket[market] = true;
    }

    // ───────────────────────────────────────────────── launch ──

    function launch(PoolKey calldata key, uint256 re, uint256 rt) external {
        if (msg.sender != registry) revert NotRegistry();
        ClogMarket(pools[key.toId()].market).depositInventoryTo(Currency.unwrap(key.currency1), address(this));
        poolManager.unlock(abi.encode(uint8(0), key, re, rt, address(0), uint256(0)));
    }

    function executeWithdrawal(address to, uint256 amount) external {
        if (!isMarket[msg.sender]) revert UnknownMarket();
        _withdrawMarket = msg.sender;
        poolManager.unlock(abi.encode(uint8(1), _emptyKey(), uint256(0), uint256(0), to, amount));
        _withdrawMarket = address(0);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, PoolKey memory key, uint256 re, uint256 rt, address to, uint256 amount) =
            abi.decode(data, (uint8, PoolKey, uint256, uint256, address, uint256));
        if (action == 0) {
            _doLaunch(key, re, rt);
        } else {
            poolManager.burn(_withdrawMarket, 0, amount);
            poolManager.take(Currency.wrap(address(0)), to, amount);
        }
        return "";
    }

    function _doLaunch(PoolKey memory key, uint256 re, uint256 rt) internal {
        PoolId id = key.toId();
        ClogGenuineMath.Position memory np =
            ClogGenuineMath.positionFor(re, rt, pools[id].virtualEthSeed, key.tickSpacing);
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: np.tickLower,
                tickUpper: np.tickUpper,
                liquidityDelta: int256(uint256(np.liquidity)),
                salt: bytes32(uint256(0))
            }),
            ""
        );
        require(d.amount0() == 0, "launch must require zero ETH");
        _payToken(key, d.amount1());
        quads[id][0] = FP.Quad(np.tickLower, np.tickUpper, np.liquidity);
        pools[id].mode = GeometryMode.SINGLE_BOUNDARY;
        residualToken[id] = IERC20LikeG(Currency.unwrap(key.currency1)).balanceOf(address(this));
    }

    // ───────────────────────────────────────── liquidity gating ──

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert UnauthorizedLiquidity();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert UnauthorizedLiquidity();
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!pools[key.toId()].registered) revert UnknownMarket();
        return IHooks.beforeInitialize.selector;
    }

    // ─────────────────────────────────────────────────── swap ──

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (pools[id].market == address(0)) revert UnknownMarket();
        if (rewardVault == address(0)) revert VaultNotSet();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();

        uint256 spec = uint256(-params.amountSpecified);
        uint256 absorb = params.zeroForOne ? _prepBuy(id, spec) : _prepSell(id, spec);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(absorb)), 0), 0);
    }

    function _prepBuy(PoolId id, uint256 gross) internal returns (uint256 absorb) {
        ClogMarket m = ClogMarket(pools[id].market);
        uint256 e0 = m.realETH();
        (uint256 out, uint256 wp) = m.applyBuy(gross);
        uint256 gained = m.realETH() - e0;
        uint256 dE = _coreBuyInput(id, m.re(), m.rt());
        if (dE > gross) dE = gross;
        absorb = gross - dE;
        _p = Pending(true, out, wp, absorb, m.re(), m.rt(), gross > gained ? gross - gained : 0, m.realETH());
    }

    function _prepSell(PoolId id, uint256 tokensIn) internal returns (uint256 absorb) {
        ClogMarket m = ClogMarket(pools[id].market);
        uint256 e0 = m.realETH();
        (uint256 netOut, uint256 wp, bool capped) = m.applySell(tokensIn);
        uint256 gross = e0 - m.realETH();
        absorb = capped ? _cappedRemainder(id, tokensIn) : 0;
        _p = Pending(false, netOut, wp, absorb, m.re(), m.rt(), gross > netOut ? gross - netOut : 0, m.realETH());
    }

    /// @dev Tokens the user's sell input that the LP genuinely CANNOT absorb.
    ///      A capped sell drives the pool's real ETH to zero, i.e. the price to the highest
    ///      live upper bound. The fillable amount is the AGGREGATE currency1 the four ranges
    ///      take while the price walks from here to that bound - summed per position over the
    ///      overlap of [P, top] with [Pa_i, Pb_i]. The single-position formula does not apply:
    ///      the four ranges start and end at different ticks, so they enter the fill at
    ///      different points.
    function _cappedRemainder(PoolId id, uint256 tokensIn) internal view returns (uint256) {
        (uint160 p0,,,) = poolManager.getSlot0(id);
        uint160 top = _activeTop(id);
        if (top <= p0) return 0;
        uint256 fillable;
        for (uint256 i = 0; i < 4; i++) {
            FP.Quad memory q = quads[id][i];
            if (q.liquidity == 0) continue;
            uint160 a = TickMath.getSqrtPriceAtTick(q.tickLower);
            uint160 b = TickMath.getSqrtPriceAtTick(q.tickUpper);
            uint160 lo = p0 > a ? p0 : a;
            uint160 hi = top < b ? top : b;
            if (lo >= hi) continue;
            fillable += SqrtPriceMath.getAmount1Delta(lo, hi, q.liquidity, false);
        }
        return tokensIn > fillable ? tokensIn - fillable : 0;
    }

    function _coreBuyInput(PoolId id, uint256 re1, uint256 rt1) internal view returns (uint256) {
        (uint160 sqrtP0,,,) = poolManager.getSlot0(id);
        uint128 L0 = poolManager.getLiquidity(id);
        uint160 sqrtT = ClogGenuineMath.sqrtPriceX96Of(re1, rt1);
        uint160 top = _activeTop(id);
        uint160 start = sqrtP0 > top ? top : sqrtP0;
        if (sqrtT >= start || L0 == 0) return 0;
        return SqrtPriceMath.getAmount0Delta(sqrtT, start, L0, true);
    }

    /// @dev Highest upper bound among live positions. Above it liquidity is zero and a swap
    ///      crosses for free, so only the in-range span may be charged to the core swap.
    function _activeTop(PoolId id) internal view returns (uint160) {
        int24 t = TickMath.MIN_TICK;
        for (uint256 i = 0; i < 4; i++) {
            if (quads[id][i].liquidity == 0) continue;
            int24 u = quads[id][i].tickUpper;
            if (u > t) t = u;
        }
        return TickMath.getSqrtPriceAtTick(t);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        Pending memory p = _p;
        delete _p;

        int128 unspec = p.isBuy ? _afterBuy(p, delta) : _afterSell(p, delta);
        // Symmetric hook delta. For a BUY the specified side is currency0 and the unspecified
        // side is currency1; for a SELL they swap. Omitting the currency1 leg on buys was what
        // left the unlock unbalanced.
        int128 hd0 = p.isBuy ? int128(uint128(p.absorbed)) : unspec;
        int128 hd1 = p.isBuy ? unspec : int128(uint128(p.absorbed));

        BalanceDelta net = _reanchor(key, id, p);
        _settle(key, id, int256(net.amount0()) + int256(hd0), int256(net.amount1()) + int256(hd1), p);
        return (IHooks.afterSwap.selector, unspec);
    }

    /// @dev core token output + this delta == canonical tokensOut, exactly.
    function _afterBuy(Pending memory p, BalanceDelta delta) internal pure returns (int128) {
        uint256 coreOut = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
        return int128(int256(coreOut) - int256(p.canonicalOut));
    }

    /// @dev the hook retains exactly the sell tax; the user receives the canonical net.
    function _afterSell(Pending memory p, BalanceDelta delta) internal pure returns (int128) {
        uint256 coreEth = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
        return int128(int256(coreEth) - int256(p.canonicalOut));
    }

    // ───────────────────────────────────────────── re-anchor ──

    /// @dev realETH == 0 is a genuine BOUNDARY for the four-position interpolation, not just a
    ///      launch quirk. At that point the canonical price is the position's own upper bound,
    ///      so the two upper-Pb quads fall in-range and demand real ETH the protocol does not
    ///      have. Measured: the hook silently absorbed 61,693,772,385,126 wei there by crediting
    ///      r0 below canonicalLiability - an UNBACKED claim. Both launch and a fully capped sell
    ///      land on realETH == 0, so both use the proven single token-only position instead.
    function _reanchor(PoolKey calldata key, PoolId id, Pending memory p) internal returns (BalanceDelta net) {
        net = _burnPositions(key, id);
        _traverseToCanonical(key, p.re1, p.rt1);
        if (p.realEth1 == 0) {
            net = net + _mintBoundaryPosition(key, id, p);
            pools[id].mode = GeometryMode.SINGLE_BOUNDARY;
        } else {
            net = net + _mintExactPositions(key, id, p);
            pools[id].mode = GeometryMode.FOUR_EXACT;
        }
    }

    /// @dev The proven single token-only position. Requires ZERO protocol ETH by construction.
    function _mintBoundaryPosition(PoolKey calldata key, PoolId id, Pending memory p)
        internal
        returns (BalanceDelta net)
    {
        ClogGenuineMath.Position memory np =
            ClogGenuineMath.positionFor(p.re1, p.rt1, pools[id].virtualEthSeed, key.tickSpacing);
        quads[id][0] = FP.Quad(np.tickLower, np.tickUpper, np.liquidity);
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: np.tickLower,
                tickUpper: np.tickUpper,
                liquidityDelta: int256(uint256(np.liquidity)),
                salt: bytes32(uint256(0))
            }),
            ""
        );
        require(d.amount0() == 0, "boundary position must require zero ETH");
        net = d;
    }

    function _burnPositions(PoolKey calldata key, PoolId id) internal returns (BalanceDelta net) {
        for (uint256 i = 0; i < 4; i++) {
            FP.Quad memory q = quads[id][i];
            if (q.liquidity == 0) continue;
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: q.tickLower,
                    tickUpper: q.tickUpper,
                    liquidityDelta: -int256(uint256(q.liquidity)),
                    salt: bytes32(i)
                }),
                ""
            );
            net = net + d;
            delete quads[id][i];
        }
    }

    function _mintExactPositions(PoolKey calldata key, PoolId id, Pending memory p)
        internal
        returns (BalanceDelta net)
    {
        uint256 vEth = pools[id].virtualEthSeed;
        uint256 vTok = ClogGenuineMath.VIRTUAL_TOKEN_OFFSET;
        FP.Quad[4] memory qs = geometry.allQuads(p.re1, p.rt1, vEth, vTok);

        // CONSERVATIVE INTEGER ROUNDING. Measured over FOUR_EXACT sequences, the ETH side of
        // the re-anchor is NEVER positive: the four mints together require 4-7 wei MORE than
        // the four burns returned, every single trade, so r0 lands just under
        // canonicalLiability and the market's claim backing runs perpetually short. Token dust
        // is two-sided and self-cancelling; ETH dust is one-directional and accumulates.
        //
        // Shaving a few units of liquidity off the largest quad makes the mint require slightly
        // LESS of both currencies, so r0/r1 come out non-negative and the surplus forms an
        // explicit settlement reserve instead of a deficit. Sizing: ETH per unit of L is about
        // realETH/L, so freeing TRIM_WEI costs dL ~ TRIM_WEI * L / realETH. With realETH ~1 ETH
        // and L ~1.3e23 that is dL ~1e6, i.e. dL/L ~1e-17 - far below the precision of the
        // offsets it protects, and it never touches user output or ClogMarket.
        // NOTE: a conservative liquidity trim was tried here (both largest-quad and
        // proportional) sized to free ~64 wei of currency0. It did NOT move the ETH shortfall at
        // all and inflated token dust from ~6e3 to ~5e10 wei, so it is deliberately absent. The
        // remaining ETH shortfall is attributed below.
        for (uint256 i = 0; i < 4; i++) {
            FP.Quad memory q = qs[i];
            quads[id][i] = q;
            if (q.liquidity == 0) continue;
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: q.tickLower,
                    tickUpper: q.tickUpper,
                    liquidityDelta: int256(uint256(q.liquidity)),
                    salt: bytes32(i)
                }),
                ""
            );
            net = net + d;
        }
    }

    /// @dev Walk slot0 across an EMPTY pool. Valid only after every position is burned: with
    ///      liquidity 0, SwapMath.computeSwapStep returns amountIn 0 and sets sqrtPriceNext to
    ///      the target, so it exchanges nothing and returns a zero delta.
    function _traverseToCanonical(PoolKey calldata key, uint256 re1, uint256 rt1) internal {
        uint160 target = ClogGenuineMath.sqrtPriceX96Of(re1, rt1);
        (uint160 cur,,,) = poolManager.getSlot0(key.toId());
        if (cur == target) return;
        poolManager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: cur > target, amountSpecified: -1, sqrtPriceLimitX96: target}),
            ""
        );
    }

    // ───────────────────────────────────────────── settlement ──

    function _settle(PoolKey calldata key, PoolId id, int256 r0, int256 r1, Pending memory p) internal {
        address market = pools[id].market;
        emit SettleCheck(p.isBuy, r0, r1, p.canonicalLiability);

        // ── ETH side ────────────────────────────────────────────────────────────────────────
        // PoolManager rounds liquidity removal DOWN and addition UP, so six-to-eight
        // modifyLiquidity calls per trade leave r0 a few wei BELOW canonicalLiability. Measured
        // across all three transportation-table solutions (PRODUCT / LO / HI) the per-trade ETH
        // delta is NEVER positive - 0 max, -5..-7 min - so no choice of the free hh parameter
        // can close it. It is a genuine Uniswap v4 settlement cost, not an accounting error.
        //
        // POLICY: owner and multisig claims - the ones ClogMarket records in
        // pendingWithdrawals - stay FULLY backed. The cost is deducted from the WinnerPot
        // portion, which is not represented in pendingWithdrawals, so nothing is ever silently
        // under-backed and no debt accumulates.
        if (r0 > 0) {
            uint256 owed = uint256(r0);
            uint256 liab = p.canonicalLiability;
            uint256 wp = p.winnerPotShare;
            if (owed < liab) {
                uint256 cost = liab - owed;
                require(cost <= MAX_SETTLEMENT_COST, "settlement cost above bound");
                require(cost <= wp, "settlement cost exceeds WinnerPot residual");
                wp -= cost;
                settlementCostPaid[id] += cost;
            } else if (owed > liab) {
                wp += owed - liab; // surplus also belongs to the WinnerPot residual
            }
            if (wp > owed) wp = owed;
            if (wp > 0) {
                poolManager.mint(rewardVault, 0, wp);
                IRewardVaultRecorderG(rewardVault).recordWinnerPotClaim(wp);
            }
            if (owed > wp) poolManager.mint(market, 0, owed - wp);
        } else if (r0 < 0) {
            poolManager.burn(market, 0, uint256(-r0));
        }

        if (r1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(r1));
            residualToken[id] += uint256(r1);
        } else if (r1 < 0) {
            uint256 due = uint256(-r1);
            residualToken[id] -= due;
            poolManager.sync(key.currency1);
            IERC20LikeG(Currency.unwrap(key.currency1)).transfer(address(poolManager), due);
            poolManager.settle();
        }
    }

    function _payToken(PoolKey memory key, int128 amount1) internal {
        if (amount1 >= 0) return;
        poolManager.sync(key.currency1);
        IERC20LikeG(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(uint128(-amount1)));
        poolManager.settle();
    }

    function _emptyKey() internal pure returns (PoolKey memory k) {
        k.currency0 = Currency.wrap(address(0));
        k.currency1 = Currency.wrap(address(0));
    }

    // ───────────────────────────────────── unused IHooks members ──

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    receive() external payable {}
}
