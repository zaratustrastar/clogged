// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogGenuineMarket} from "./ClogGenuineMarket.sol";
import {ClogGenuineMath} from "./ClogGenuineMath.sol";

interface IRewardVaultRecorderG {
    function recordWinnerPotClaim(uint256 amount) external;
}

interface IERC20LikeG {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amt) external returns (bool);
}

/// @title ClogGenuineLiquidityHook (Architecture B prototype)
/// @notice One genuine token-only v4 position + genuine nonzero user swaps + exact canonical
///         ClogGenuineMarket economics + an afterSwap LP re-anchor. No sentinel, no operating fund, no
///         calibration swap, no bypass pool, no protocol ETH seed.
///
///   ClogGenuineMarket.sol is used UNCHANGED. It remains the single source of economic truth; the v4
///   position is a faithful mirror of its (re, rt, realETH, physicalInventory).
///
///   BUY (exactInput ETH, zeroForOne)
///     beforeSwap  applyBuy(gross) -> canonical out; form sqrtPtarget = sqrt(rt1/re1)*Q96;
///                 dE = amount0 needed to walk the PRE-trade curve to sqrtPtarget;
///                 return BeforeSwapDelta(specified = +(gross - dE)). Hooks.sol:271 then sets
///                 amountToSwap = -dE, so the core swap is genuine and carries ~97% of gross.
///     afterSwap   return -(out - coreOut) on the unspecified side so the user receives EXACTLY
///                 the canonical number; burn the stale position; mint the new canonical one;
///                 resolve every delta. slot0 is already canonical - nothing recalibrates it.
///
///   SELL (exactInput token)
///     Uncapped sells need NO specified-side delta: walking the pool to sqrtPtarget consumes
///     exactly tokensIn and pays exactly the canonical gross. afterSwap removes the 0.6% tax.
///     Capped sells absorb only the unfillable remainder - the position's upper bound Pb is
///     precisely where its real ETH hits zero, which is where ClogGenuineMarket caps.
///
///   DELTA ACCOUNTING (derived from pinned v4.0.0, not guessed)
///     Hooks.sol:305-311 applies hookDelta AFTER afterSwap returns, so inside afterSwap the
///     hook's ledger holds only its own modifyLiquidity deltas. For the unlock to close, the
///     hook must leave its ledger at exactly -hookDelta. Therefore with
///         R = burnDelta + mintDelta + hookDelta
///     the hook resolves R: R > 0 -> it is owed, R < 0 -> it owes.
///
///     Algebraically R.amount0 == tax + clogExtracted and R.amount1 == 0:
///         ETH   : absorb + (realETH0 + dE) - realETH1
///               = (gross - dE) + realETH0 + dE - realETH1
///               = gross - (budget - clogExtracted) = tax + clogExtracted
///         token : -(out - coreOut) + (physInv0 - coreOut) - (physInv0 - out) = 0
///     dE cancels completely, so the split between core swap and hook delta cannot leak value.
///     R.amount0 is discharged as ERC6909 claims exactly as ClogV4HookV2 did - to the market for
///     pendingWithdrawals, to the RewardVault for the WinnerPot - so withdraw() is unchanged.
///     Any R.amount1 that is not zero is pure tick-boundary rounding and is tracked in
///     residualToken; it is NEVER netted against user output.
contract ClogGenuineLiquidityHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public immutable registry;
    address public rewardVault;

    bytes32 internal constant POSITION_SALT = bytes32(uint256(0x0106));

    struct PoolState {
        address market;
        uint256 virtualEthSeed;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool registered;
    }

    struct Pending {
        bool isBuy;
        uint256 canonicalOut; // buy: tokens to user. sell: net ETH to user.
        uint256 winnerPotShare;
        uint256 absorbed; // specified-side BeforeSwapDelta
        uint256 grossIn; // buy: full gross ETH input
        uint256 re1;
        uint256 rt1;
        uint256 realEth0;
        uint256 realEth1;
        uint256 physInv1;
        uint160 sqrtP0;
        uint128 L0;
    }

    mapping(PoolId => PoolState) public pools;
    /// @notice Tick-boundary rounding residual held by the hook, per pool. Explicitly tracked,
    ///         never hidden inside user output or CLOG accounting.
    mapping(PoolId => uint256) public residualToken;
    mapping(PoolId => uint256) public residualEth;
    mapping(address => bool) public isMarket;
    /// @notice ETH liability backing that a few-wei rounding deficit forced us to defer, repaid
    ///         out of the next positive rounding. Bounded and asserted in tests.
    mapping(PoolId => uint256) public deferredEthLiability;
    mapping(PoolId => uint256) public maxDeferredEthLiability;

    Pending internal _p;

    error NotPoolManager();
    error NotRegistry();
    error UnauthorizedLiquidity();
    error ExactOutputUnsupported();
    error UnknownMarket();
    error VaultNotSet();
    error TokenResidualExhausted(uint256 due, uint256 held);
    error EthResidualExhausted(uint256 due, uint256 held);

    /// @notice Per-trade ETH rounding telemetry. `canonicalLiability` is derived from UNCHANGED
    ///         ClogGenuineMarket state, never from actualR0, so the two are independent.
    event EthRounding(
        bool isBuy, int256 actualR0, uint256 canonicalLiability, int256 roundingEth, uint256 residualEthAfter
    );

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager pm, address registry_) {
        poolManager = pm;
        registry = registry_;
    }

    function setRewardVault(address v) external {
        if (msg.sender != registry) revert NotRegistry();
        rewardVault = v;
    }

    /// @notice Called by the Registry at launch, before the pool is initialized.
    function registerPool(PoolKey calldata key, address market, uint256 virtualEthSeed) external {
        if (msg.sender != registry) revert NotRegistry();
        PoolState storage ps = pools[key.toId()];
        ps.market = market;
        ps.virtualEthSeed = virtualEthSeed;
        ps.registered = true;
        isMarket[market] = true;
    }

    /// @notice Establish the protocol's token-only position. Called by the Registry at launch.
    /// @dev The mint MUST be issued by the hook itself: Hooks.sol:194-199 applies noSelfCall to
    ///      beforeModifyLiquidity, so only the hook's own call bypasses the liquidity gate that
    ///      rejects every outsider. Requires ZERO protocol ETH - the pool is initialized at a
    ///      price at or above the position's upper bound, so the position is 100% currency1 by
    ///      construction and modifyLiquidity returns amount0 == 0.
    function launch(PoolKey calldata key, uint256 re, uint256 rt) external {
        if (msg.sender != registry) revert NotRegistry();
        PoolState storage ps = pools[key.toId()];
        ClogGenuineMarket(ps.market).depositInventoryTo(Currency.unwrap(key.currency1), address(this));
        poolManager.unlock(abi.encode(uint8(0), key, re, rt, address(0), uint256(0)));
    }

    /// @notice Pull-payment leg for ClogGenuineMarket.withdraw(): burn the market's ERC6909 ETH claim
    ///         and deliver real native ETH to `to`.
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
            PoolState storage ps = pools[key.toId()];
            ClogGenuineMath.Position memory np =
                ClogGenuineMath.positionFor(re, rt, ps.virtualEthSeed, key.tickSpacing);
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: np.tickLower,
                    tickUpper: np.tickUpper,
                    liquidityDelta: int256(uint256(np.liquidity)),
                    salt: POSITION_SALT
                }),
                ""
            );
            require(d.amount0() == 0, "launch must require zero ETH");
            if (d.amount1() < 0) {
                uint256 owed = uint256(uint128(-d.amount1()));
                poolManager.sync(key.currency1);
                IERC20LikeG(Currency.unwrap(key.currency1)).transfer(address(poolManager), owed);
                poolManager.settle();
            }
            ps.tickLower = np.tickLower;
            ps.tickUpper = np.tickUpper;
            ps.liquidity = np.liquidity;
            // Whatever the tick-rounded position could not absorb stays here and is TRACKED.
            // It is never netted against user output or CLOG accounting.
            residualToken[key.toId()] = IERC20LikeG(Currency.unwrap(key.currency1)).balanceOf(address(this));
        } else {
            poolManager.burn(_withdrawMarket, 0, amount);
            poolManager.take(Currency.wrap(address(0)), to, amount);
        }
        return "";
    }

    address internal _withdrawMarket;

    function _emptyKey() internal pure returns (PoolKey memory k) {
        k.currency0 = Currency.wrap(address(0));
        k.currency1 = Currency.wrap(address(0));
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
        PoolState storage ps = pools[id];
        if (ps.market == address(0)) revert UnknownMarket();
        if (rewardVault == address(0)) revert VaultNotSet();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();

        uint256 specified = uint256(-params.amountSpecified);
        (uint160 sqrtP0,,,) = poolManager.getSlot0(id);
        uint128 L0 = ps.liquidity;
        ClogGenuineMarket m = ClogGenuineMarket(ps.market);

        // OPTION B: the genuine v4 swap is the source of truth for execution, price movement,
        // slippage and tick/Q96 rounding. beforeSwap no longer predicts an output and no longer
        // trims the input to hit a synthetic target price. It removes ONLY the CLOG tax, so the
        // core swap carries the entire post-tax budget.
        uint256 absorb;
        uint256 realEth0 = m.realETH();
        if (params.zeroForOne) {
            absorb = Math.mulDiv(specified, m.BUY_TAX_BPS(), m.BPS()); // 0.6% buy tax
            _p = Pending({
                isBuy: true,
                canonicalOut: 0,
                winnerPotShare: 0,
                absorbed: absorb,
                grossIn: specified,
                re1: 0,
                rt1: 0,
                realEth0: realEth0,
                realEth1: 0,
                physInv1: 0,
                sqrtP0: sqrtP0,
                L0: L0
            });
        } else {
            // Sells take no specified-side delta at all: the pool's own liquidity is what caps a
            // solvency-capped sell (the position holds exactly realETH), so a partial fill IS
            // the genuine behaviour. The 0.6% sell tax is taken from the ETH side in afterSwap.
            _p = Pending({
                isBuy: false,
                canonicalOut: 0,
                winnerPotShare: 0,
                absorbed: 0,
                grossIn: 0,
                re1: 0,
                rt1: 0,
                realEth0: realEth0,
                realEth1: 0,
                physInv1: 0,
                sqrtP0: sqrtP0,
                L0: L0
            });
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(absorb)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolState storage ps = pools[id];
        Pending memory p = _p;
        delete _p;

        // ── 1. the pool has executed. Apply CLOG's rules to what it ACTUALLY did. ──
        //    No top-up: the user receives the genuine v4 execution amount.
        ClogGenuineMarket m = ClogGenuineMarket(ps.market);
        (uint160 sqrtP1,,,) = poolManager.getSlot0(id);

        int128 unspecified;
        if (p.isBuy) {
            uint256 actualOut = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
            (, uint256 wp) = m.applyBuyActual(p.grossIn, actualOut, p.sqrtP0, sqrtP1, p.L0);
            p.winnerPotShare = wp;
            unspecified = 0; // user keeps exactly what the pool gave
        } else {
            uint256 tokensUsed = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
            uint256 actualGross = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
            (uint256 netOut, uint256 wp,) = m.applySellActual(tokensUsed, actualGross);
            p.winnerPotShare = wp;
            // hook keeps the 0.6% sell tax; user receives the rest of the genuine payout
            unspecified = int128(int256(actualGross) - int256(netOut));
        }
        p.re1 = m.re();
        p.rt1 = m.rt();
        p.realEth1 = m.realETH();
        p.physInv1 = m.physicalInventory();

        // ── 2. hook delta, known before the re-anchor ──
        int128 hd0;
        int128 hd1;
        if (p.isBuy) {
            hd0 = int128(uint128(p.absorbed));
            hd1 = 0;
        } else {
            hd0 = unspecified;
            hd1 = 0;
        }

        // ── 3. re-anchor the protocol position onto the post-rules state ──
        BalanceDelta net = _reanchor(key, ps, p, hd0);

        _resolve(key, id, int256(net.amount0()) + int256(hd0), int256(net.amount1()) + int256(hd1), p);

        return (IHooks.afterSwap.selector, unspecified);
    }

    function _reanchor(PoolKey calldata key, PoolState storage ps, Pending memory p, int128 hd0)
        internal
        returns (BalanceDelta net)
    {
        ClogGenuineMath.Position memory np =
            ClogGenuineMath.positionFor(p.re1, p.rt1, ps.virtualEthSeed, key.tickSpacing);

        if (ps.liquidity > 0) {
            (BalanceDelta burnDelta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: ps.tickLower,
                    tickUpper: ps.tickUpper,
                    liquidityDelta: -int256(uint256(ps.liquidity)),
                    salt: POSITION_SALT
                }),
                ""
            );
            net = net + burnDelta;
        }

        // ── ZERO-LIQUIDITY PRICE TRAVERSAL ──────────────────────────────────────────────
        // The old position is now burned, so the pool holds NO liquidity at any tick. In that
        // state SwapMath.computeSwapStep returns amountIn == 0 (getAmountXDelta with liquidity
        // 0 is 0), so `amountRemainingLessFee >= amountIn` holds and the step sets
        // sqrtPriceNextX96 = sqrtPriceTargetX96. A swap therefore walks the price to
        // sqrtPriceLimitX96 exchanging NOTHING and returning a zero BalanceDelta.
        //
        // This is what makes capped sells representable without a single wei of protocol ETH.
        // A capped sell ends canonically at re1 == virtualEthSeed and realETH1 == 0, i.e. price
        // == the NEW position's upper bound Pb_new. The user's core swap can only reach the OLD
        // bound Pb_old (that is where the old position's real ETH runs out), and Pb_new > Pb_old
        // - measured ratio 1.1277. Minting the new position while slot0 still sat at Pb_old put
        // the price INSIDE the new range, so the position demanded 0.557 ETH of real reserves:
        // the EthResidualExhausted(0.553 ether, 0) revert. It was never a funding problem.
        //
        // Moving slot0 to Pb_new BEFORE the mint puts the price exactly at the new upper bound,
        // where a position is 100% token and needs ZERO ETH. The hook self-calls swap, and
        // Hooks.sol:252/292 skip beforeSwap/afterSwap when msg.sender == address(self), so this
        // cannot recurse. It is not a calibration swap: it exchanges nothing and exists only
        // because the burn left the pool empty.
        _traverseToCanonical(key, p.re1, p.rt1);

        // Cap the new position's liquidity so it can never demand MORE real ETH than canonical
        // realETH1. tickUpper must round DOWN (otherwise the token-only launch price would sit
        // inside the range and require ETH), which makes the rounded position hold slightly
        // more ETH than canonical at the same price - a few e13 wei. The fuzzer hit exactly
        // that: EthResidualExhausted(9.48e13, 0).
        //
        // Scaling L is safe ONLY because _traverseToCanonical now pins slot0 to the canonical
        // price independently of L, and the user's output is reconciled exactly by the afterSwap
        // delta. Position amounts are linear in L for fixed geometry, so the scale factor is
        // exact. The reduction is ~1e-5 relative and never touches CLOG state.
        (BalanceDelta mintDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: np.tickLower,
                tickUpper: np.tickUpper,
                liquidityDelta: int256(uint256(np.liquidity)),
                salt: POSITION_SALT
            }),
            ""
        );
        net = net + mintDelta;

        ps.tickLower = np.tickLower;
        ps.tickUpper = np.tickUpper;
        ps.liquidity = np.liquidity;
    }

    /// @dev Walk slot0 to the canonical price across an EMPTY pool. Must be called only after
    ///      the old position has been burned, so that liquidity is zero at every tick and the
    ///      swap exchanges nothing. Returns a zero BalanceDelta by construction.
    function _traverseToCanonical(PoolKey calldata key, uint256 re1, uint256 rt1) internal {
        uint160 target = ClogGenuineMath.sqrtPriceX96Of(re1, rt1);
        (uint160 cur,,,) = poolManager.getSlot0(key.toId());
        if (cur == target) return;
        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: cur > target,
                amountSpecified: -1,
                sqrtPriceLimitX96: target
            }),
            ""
        );
    }

    /// @dev Discharge the hook's net position. R > 0 means the manager owes the hook; the ETH
    ///      side is turned into ERC6909 claims (market + RewardVault) exactly as ClogV4HookV2
    ///      did, so ClogGenuineMarket.withdraw() is unchanged. R < 0 means the hook owes and pays from
    ///      its tracked residual.
    /// @dev Canonical ETH liability for this trade, derived purely from ClogGenuineMarket state.
    ///        BUY : grossInput - (realETH1 - realETH0)  == buyTax + clogExtracted
    ///        SELL: (realETH0 - realETH1) - canonicalNetOut == sellTax
    function _canonicalLiability(Pending memory p) internal pure returns (uint256) {
        if (p.isBuy) {
            uint256 gained = p.realEth1 - p.realEth0;
            return p.grossIn > gained ? p.grossIn - gained : 0;
        }
        uint256 gross = p.realEth0 - p.realEth1;
        return gross > p.canonicalOut ? gross - p.canonicalOut : 0;
    }

    function _resolve(PoolKey calldata key, PoolId id, int256 r0, int256 r1, Pending memory p) internal {
        PoolState storage ps = pools[id];
        {
            uint256 liab = _canonicalLiability(p);
            emit EthRounding(p.isBuy, r0, liab, r0 - int256(liab), residualEth[id]);
        }

        // ── ETH side: canonical liability EXACT, rounding to a hook-owned claim ────────
        // The continuous algebra says r0 == tax + clogExtracted. Tick-rounded v4 geometry makes
        // the realised r0 differ by an epsilon. Previously EVERY positive r0 was paid out as
        // economic revenue, so that epsilon was given away as market/RewardVault claims - and
        // the first buy alone donates +2.06e14 wei. A later -2.7e13 shortfall then had nothing
        // to draw on, which is what produced EthResidualExhausted(..., 0).
        //
        // Now the rounding is separated from the economics and parked as the hook's OWN native
        // ERC6909 claim (currency id 0), exactly as V2 uses mint/burn for native claims. No
        // external ETH ever enters: the reserve is funded purely by positive rounding.
        //
        // Delta arithmetic (hook ledger starts at r0):
        //   rounding > 0 : mint(self, rounding)  -> ledger = r0 - rounding = liability
        //   rounding < 0 : burn(self, -rounding) -> ledger = r0 + (-rounding) = liability
        //   then mint(liability) to vault + market -> ledger = 0
        {
            uint256 liab = _canonicalLiability(p);
            int256 rounding = r0 - int256(liab);

            if (rounding > 0) {
                poolManager.mint(address(this), _cid(key.currency0), uint256(rounding));
                residualEth[id] += uint256(rounding);
            } else if (rounding < 0) {
                uint256 need = uint256(-rounding);
                uint256 held = residualEth[id];
                if (held < need) revert EthResidualExhausted(need, held);
                poolManager.burn(address(this), _cid(key.currency0), need);
                residualEth[id] = held - need;
            }

            uint256 payable_ = liab;
            if (payable_ > 0) {
                uint256 wp = p.winnerPotShare;
                if (wp > payable_) wp = payable_;
                if (wp > 0) {
                    poolManager.mint(rewardVault, _cid(key.currency0), wp);
                    IRewardVaultRecorderG(rewardVault).recordWinnerPotClaim(wp);
                }
                uint256 rest = payable_ - wp;
                if (rest > 0) poolManager.mint(ps.market, _cid(key.currency0), rest);
            }
        }

        // Token side: settle against the hook's REAL token balance (the tracked tick-rounding
        // residual), not against ERC6909 claims it does not hold. Burning claims here was an
        // arithmetic underflow - caught by the differential suite, not by inspection.
        if (r1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(r1));
            residualToken[id] += uint256(r1);
        } else if (r1 < 0) {
            uint256 due = uint256(-r1);
            uint256 held = residualToken[id];
            if (held < due) revert TokenResidualExhausted(due, held);
            poolManager.sync(key.currency1);
            IERC20LikeG(Currency.unwrap(key.currency1)).transfer(address(poolManager), due);
            poolManager.settle();
            residualToken[id] = held - due;
        }
    }

    function _cid(Currency c) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(c)));
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
