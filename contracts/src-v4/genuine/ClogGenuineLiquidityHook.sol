// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../ClogMarket.sol";
import {ClogGenuineMath} from "./ClogGenuineMath.sol";

/// @title ClogGenuineLiquidityHook (PROTOTYPE - NOT DEPLOYED, NOT COMPILED, NOT TESTED)
/// @notice Architecture B: a genuine, liquidity-backed PoolManager swap for every user trade,
///         plus hook deltas used ONLY for CLOG-specific tax / extraction / exact reconciliation,
///         plus an afterSwap re-anchor of the single protocol-owned position.
///
///   WHAT THIS REPLACES. ClogV4HookV2 consumed 100% of the user's input in beforeSwap and then
///   ran a SEPARATE nested calibration swap in afterSwap purely to drag slot0 onto the canonical
///   price. The core AMM never priced a user trade, which is the leading explanation for Sigma
///   refusing to route. Here there is NO calibration swap: the core swap is handed exactly the
///   input that makes it finish, naturally, at the canonical post-trade price.
///
///   BUY (exactInput, ETH specified)
///     beforeSwap:
///       1. market.applyBuy(grossInput) mutates canonical state and returns the exact output.
///       2. Read the post-trade canonical (re1, rt1) and form sqrtPtarget = sqrt(rt1/re1)*2^96.
///       3. dE = ClogGenuineMath.coreBuyInput(sqrtP0, sqrtPtarget, L0) is the ETH the genuine
///          core swap needs to land exactly on sqrtPtarget along the PRE-trade curve.
///       4. Return a PARTIAL BeforeSwapDelta of (grossInput - dE) on the specified side. Against
///          the reference model this absorption is only ~2.67% of gross (tax + extraction);
///          the core Swap event carries ~97.3%.
///     afterSwap:
///       5. The core swap delivered dT tokens. Canonical says `out`. Return (out - dT) on the
///          unspecified side so the user receives EXACTLY the ClogMarket number.
///       6. Re-anchor: burn the old position, mint the new one for (re1, rt1, realETH1,
///          physicalInventory1). slot0 is ALREADY canonical - nothing else touches the price.
///
///   SELL (exactInput, token specified)
///     An uncapped sell needs NO specified-side delta at all: moving the pool to sqrtPtarget
///     consumes exactly the user's full token input, and pays exactly ClogMarket's gross payout.
///     (Verified in the reference model to the wei.) afterSwap applies only the 0.6% tax.
///
///     A CAPPED sell is the one case that cannot ride ordinary AMM execution. ClogMarket takes
///     the whole token input but pays out at most realETH. The position holds exactly realETH,
///     and its upper bound Pb is precisely where actualETH hits zero - so the core swap fills
///     only as far as Pb and stops. The hook therefore takes the UNFILLED remainder of the token
///     input as an explicit specified-side delta, pays no ETH for it, and folds it into
///     physicalInventory on the re-mint. This is designed, not inherited from AMM behaviour.
///
///   EXACT-OUTPUT is unsupported on both sides, as in ClogV4HookV2 and in UniversalKlikHook
///   (which reverts "exactOutput sells not supported" and is still traded by Sigma).
///
///   MASK: BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP |
///         AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA = 0x2ACC
///         (V2 was 0x2AC8; AFTER_SWAP_RETURNS_DELTA is newly required for the sell-side tax.)
///
///   UNPROVEN AND LOAD-BEARING. Whether PoolManager.modifyLiquidity() may be called from inside
///   afterSwap, during the same unlock session, on the Robinhood-pinned v4 implementation, is
///   NOT established. If it reverts or re-enters, this entire architecture is invalid as written
///   and must fall back to a deferred re-anchor. See
///   test-v4/genuine/ModifyLiquidityInAfterSwapProbe.t.sol - run that FIRST.
contract ClogGenuineLiquidityHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public immutable registry;

    /// @dev Fixed salt for the single protocol-owned position. One pool, one position, ever.
    bytes32 internal constant POSITION_SALT = bytes32(uint256(0x0106));

    struct PoolState {
        ClogMarket market;
        uint256 virtualEthSeed;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool initialized;
        // Residual inventory held by the hook because tick-rounded boundaries cannot reproduce
        // both virtual offsets exactly. Tracked explicitly and asserted in tests; never netted
        // silently against user output.
        uint256 residualEth;
        uint256 residualToken;
    }

    mapping(PoolId => PoolState) public pools;

    /// @dev Set for the duration of one swap so afterSwap can see what beforeSwap decided.
    struct PendingSwap {
        bool active;
        bool isBuy;
        uint256 canonicalOut; // tokens out (buy) or gross ETH out (sell)
        uint256 canonicalGross;
        uint256 re1;
        uint256 rt1;
        uint256 realEth1;
        uint256 physInv1;
        uint256 specifiedRemainder; // capped-sell leftover to absorb
    }

    PendingSwap internal _pending;

    error NotPoolManager();
    error NotRegistry();
    error UnauthorizedLiquidity();
    error ExactOutputUnsupported();
    error PoolNotInitialized();
    error ReanchorFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager pm, address registry_) {
        poolManager = pm;
        registry = registry_;
    }

    // ─────────────────────────────────────────── liquidity gating ──

    /// @dev PoolManager passes the unlock holder as `sender`. The hook's own modifyLiquidity
    ///      calls skip these callbacks entirely (v4 noSelfCall), so anything arriving here is by
    ///      definition an outsider. This is the "no unauthorized liquidity" guarantee, and it is
    ///      strictly stronger than Klik's pools, which carry no add/remove gating at all.
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
        if (!pools[key.toId()].initialized) revert PoolNotInitialized();
        return IHooks.beforeInitialize.selector;
    }

    // ─────────────────────────────────────────────────── swap ──

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolState storage ps = pools[key.toId()];
        if (!ps.initialized) revert PoolNotInitialized();
        if (params.amountSpecified > 0) revert ExactOutputUnsupported();

        uint256 specified = uint256(-params.amountSpecified);
        // currency0 == native ETH, so zeroForOne == true is ETH -> token == a BUY.
        bool isBuy = params.zeroForOne;

        (uint160 sqrtP0,,,) = poolManager.getSlot0(key.toId());
        uint128 L0 = ps.liquidity;

        uint256 absorb;
        if (isBuy) {
            (uint256 out,) = ps.market.applyBuy(specified);
            uint256 re1 = ps.market.re();
            uint256 rt1 = ps.market.rt();
            uint160 sqrtT = ClogGenuineMath.sqrtPriceX96Of(re1, rt1);
            uint256 dE = ClogGenuineMath.coreBuyInput(sqrtP0, sqrtT, L0);
            absorb = specified > dE ? specified - dE : 0;

            _pending = PendingSwap({
                active: true,
                isBuy: true,
                canonicalOut: out,
                canonicalGross: specified,
                re1: re1,
                rt1: rt1,
                realEth1: ps.market.realETH(),
                physInv1: ps.market.physicalInventory(),
                specifiedRemainder: 0
            });
        } else {
            (uint256 netOut,, bool capped) = ps.market.applySell(specified);
            uint256 re1 = ps.market.re();
            uint256 rt1 = ps.market.rt();
            uint160 sqrtT = ClogGenuineMath.sqrtPriceX96Of(re1, rt1);

            uint256 remainder;
            if (capped) {
                // A capped sell targets a price at or above Pb, where the position holds no
                // ETH. The core swap can only fill as far as Pb, so take the unfilled token
                // remainder as an explicit specified-side delta and pay no ETH for it.
                uint160 sqrtPb = TickMath.getSqrtPriceAtTick(ps.tickUpper);
                uint256 fillable = ClogGenuineMath.coreSellInput(sqrtP0, sqrtPb, L0);
                remainder = specified > fillable ? specified - fillable : 0;
                absorb = remainder;
            } else {
                // Proven against the reference model: moving the pool to sqrtT consumes exactly
                // the user's full token input and pays exactly the canonical gross payout, so
                // no specified-side delta is required here at all.
                require(sqrtT > sqrtP0, "sell must raise token/ETH price");
            }

            _pending = PendingSwap({
                active: true,
                isBuy: false,
                canonicalOut: netOut,
                canonicalGross: specified,
                re1: re1,
                rt1: rt1,
                realEth1: ps.market.realETH(),
                physInv1: ps.market.physicalInventory(),
                specifiedRemainder: remainder
            });
        }

        // Positive specified-side delta == hook takes that much of the specified currency.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(absorb)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolState storage ps = pools[key.toId()];
        PendingSwap memory p = _pending;
        delete _pending;

        int128 unspecifiedDelta;
        if (p.isBuy) {
            uint256 coreOut = uint256(int256(delta.amount1() > 0 ? delta.amount1() : int128(0)));
            // Reconcile to the exact ClogMarket number. Negative == hook pays the user more.
            unspecifiedDelta = int128(int256(coreOut) - int256(p.canonicalOut));
        } else {
            uint256 coreEth = uint256(int256(delta.amount0() > 0 ? delta.amount0() : int128(0)));
            unspecifiedDelta = int128(int256(coreEth) - int256(p.canonicalOut));
        }

        _reanchor(key, ps, p);
        return (IHooks.afterSwap.selector, unspecifiedDelta);
    }

    /// @dev Burn the stale position and mint the one representing the new canonical state.
    ///      slot0 is already canonical because the core swap finished there - this call must
    ///      NOT move the price, only re-shape the liquidity around it.
    function _reanchor(PoolKey calldata key, PoolState storage ps, PendingSwap memory p) internal {
        ClogGenuineMath.Position memory np =
            ClogGenuineMath.positionFor(p.re1, p.rt1, ps.virtualEthSeed, key.tickSpacing);

        if (ps.liquidity > 0) {
            poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: ps.tickLower,
                    tickUpper: ps.tickUpper,
                    liquidityDelta: -int256(uint256(ps.liquidity)),
                    salt: POSITION_SALT
                }),
                ""
            );
        }
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: np.tickLower,
                tickUpper: np.tickUpper,
                liquidityDelta: int256(uint256(np.liquidity)),
                salt: POSITION_SALT
            }),
            ""
        );

        ps.tickLower = np.tickLower;
        ps.tickUpper = np.tickUpper;
        ps.liquidity = np.liquidity;
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
}
