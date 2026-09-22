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
import {ClogMarket} from "../ClogMarket.sol";
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
///         ClogMarket economics + an afterSwap LP re-anchor. No sentinel, no operating fund, no
///         calibration swap, no bypass pool, no protocol ETH seed.
///
///   ClogMarket.sol is used UNCHANGED. It remains the single source of economic truth; the v4
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
///     precisely where its real ETH hits zero, which is where ClogMarket caps.
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
        uint256 re1;
        uint256 rt1;
        uint256 realEth1;
        uint256 physInv1;
    }

    mapping(PoolId => PoolState) public pools;
    /// @notice Tick-boundary rounding residual held by the hook, per pool. Explicitly tracked,
    ///         never hidden inside user output or CLOG accounting.
    mapping(PoolId => uint256) public residualToken;
    mapping(PoolId => uint256) public residualEth;
    mapping(address => bool) public isMarket;

    Pending internal _p;

    error NotPoolManager();
    error NotRegistry();
    error UnauthorizedLiquidity();
    error ExactOutputUnsupported();
    error UnknownMarket();
    error VaultNotSet();
    error TokenResidualExhausted(uint256 due, uint256 held);
    error EthResidualExhausted(uint256 due, uint256 held);

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
        ClogMarket(ps.market).depositInventoryTo(Currency.unwrap(key.currency1), address(this));
        poolManager.unlock(abi.encode(uint8(0), key, re, rt, address(0), uint256(0)));
    }

    /// @notice Pull-payment leg for ClogMarket.withdraw(): burn the market's ERC6909 ETH claim
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
        ClogMarket m = ClogMarket(ps.market);

        uint256 absorb;
        if (params.zeroForOne) {
            (uint256 out, uint256 wp) = m.applyBuy(specified);
            uint160 sqrtT = ClogGenuineMath.sqrtPriceX96Of(m.re(), m.rt());
            // The price may sit ABOVE the position's upper bound (the token-only launch state),
            // where ACTIVE liquidity is zero. A swap traverses that gap for free, so dE must be
            // computed only over the in-range span. Using sqrtP0 directly over-charged the core
            // swap and left slot0 0.0043% off canonical - found by the differential suite.
            uint160 sqrtPbPos = TickMath.getSqrtPriceAtTick(ps.tickUpper);
            uint160 startP = sqrtP0 > sqrtPbPos ? sqrtPbPos : sqrtP0;
            uint256 dE = ClogGenuineMath.coreBuyInput(startP, sqrtT, L0);
            if (dE > specified) dE = specified;
            absorb = specified - dE;
            _p = Pending({
                isBuy: true,
                canonicalOut: out,
                winnerPotShare: wp,
                absorbed: absorb,
                re1: m.re(),
                rt1: m.rt(),
                realEth1: m.realETH(),
                physInv1: m.physicalInventory()
            });
        } else {
            (uint256 netOut, uint256 wp, bool capped) = m.applySell(specified);
            if (capped) {
                // The core swap can only fill as far as Pb, where the position's real ETH is
                // exhausted - which is exactly where ClogMarket capped. Absorb the remainder.
                uint160 sqrtPb = TickMath.getSqrtPriceAtTick(ps.tickUpper);
                uint256 fillable = ClogGenuineMath.coreSellInput(sqrtP0, sqrtPb, L0);
                absorb = specified > fillable ? specified - fillable : 0;
            }
            _p = Pending({
                isBuy: false,
                canonicalOut: netOut,
                winnerPotShare: wp,
                absorbed: absorb,
                re1: m.re(),
                rt1: m.rt(),
                realEth1: m.realETH(),
                physInv1: m.physicalInventory()
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

        // ── 1. reconcile the user's side to the exact canonical number ──
        int128 unspecified;
        if (p.isBuy) {
            uint256 coreOut = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
            // negative == hook owes, i.e. tops the user up to canonicalOut
            unspecified = int128(int256(coreOut) - int256(p.canonicalOut));
        } else {
            uint256 coreEth = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
            unspecified = int128(int256(coreEth) - int256(p.canonicalOut));
        }

        // ── 2. re-anchor the protocol position onto the new canonical state ──
        BalanceDelta net = _reanchor(key, ps, p);

        // ── 3. resolve R = burn + mint + hookDelta ──
        int128 hd0;
        int128 hd1;
        if (p.isBuy) {
            hd0 = int128(uint128(p.absorbed));
            hd1 = unspecified;
        } else {
            // sell: specified side is currency1, unspecified is currency0
            hd0 = unspecified;
            hd1 = int128(uint128(p.absorbed));
        }
        _resolve(key, id, int256(net.amount0()) + int256(hd0), int256(net.amount1()) + int256(hd1), p);

        return (IHooks.afterSwap.selector, unspecified);
    }

    function _reanchor(PoolKey calldata key, PoolState storage ps, Pending memory p)
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

    /// @dev Discharge the hook's net position. R > 0 means the manager owes the hook; the ETH
    ///      side is turned into ERC6909 claims (market + RewardVault) exactly as ClogV4HookV2
    ///      did, so ClogMarket.withdraw() is unchanged. R < 0 means the hook owes and pays from
    ///      its tracked residual.
    function _resolve(PoolKey calldata key, PoolId id, int256 r0, int256 r1, Pending memory p) internal {
        PoolState storage ps = pools[id];

        if (r0 > 0) {
            uint256 owed = uint256(r0);
            uint256 wp = p.winnerPotShare;
            if (wp > owed) wp = owed;
            if (wp > 0) {
                poolManager.mint(rewardVault, _cid(key.currency0), wp);
                IRewardVaultRecorderG(rewardVault).recordWinnerPotClaim(wp);
            }
            uint256 rest = owed - wp;
            if (rest > 0) poolManager.mint(ps.market, _cid(key.currency0), rest);
        } else if (r0 < 0) {
            uint256 due = uint256(-r0);
            uint256 held = residualEth[id];
            if (held < due) revert EthResidualExhausted(due, held);
            poolManager.settle{value: due}();
            residualEth[id] = held - due;
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
