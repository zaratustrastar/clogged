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
    /// @dev The four protocol-owned positions, kept OUT of PoolState: a fixed-size struct array
    ///      inside a mapped struct reproducibly ICEs solc 0.8.26 under via_ir.
    mapping(PoolId => mapping(uint256 => ClogGenuineMath.Quad)) public quads;
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
    ///         ClogMarket state, never from actualR0, so the two are independent.
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
            _doLaunch(key, re, rt);
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
        uint128 L0 = poolManager.getLiquidity(id);
        ClogMarket m = ClogMarket(ps.market);

        // The four-position geometry represents canonical (re, rt) EXACTLY, so the pool's own
        // virtual reserves ARE ClogMarket's. A swap of the full post-tax budget therefore lands
        // on exactly rt1 and hands the user exactly the canonical output - there is nothing to
        // top up. beforeSwap removes only the CLOG tax.
        uint256 absorb;
        uint256 realEth0 = m.realETH();
        if (params.zeroForOne) {
            (uint256 out, uint256 wp) = m.applyBuy(specified);
            absorb = Math.mulDiv(specified, m.BUY_TAX_BPS(), m.BPS());
            _p = Pending({
                isBuy: true, canonicalOut: out, winnerPotShare: wp, absorbed: absorb,
                grossIn: specified, re1: m.re(), rt1: m.rt(), realEth0: realEth0,
                realEth1: m.realETH(), physInv1: m.physicalInventory(), sqrtP0: sqrtP0, L0: L0
            });
        } else {
            (uint256 netOut, uint256 wp,) = m.applySell(specified);
            _p = Pending({
                isBuy: false, canonicalOut: netOut, winnerPotShare: wp, absorbed: 0,
                grossIn: 0, re1: m.re(), rt1: m.rt(), realEth0: realEth0,
                realEth1: m.realETH(), physInv1: m.physicalInventory(), sqrtP0: sqrtP0, L0: L0
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

        // ── 1. no top-up. Exact geometry means the core swap already delivered the
        //    canonical amount; for sells the hook keeps only the 0.6% tax. ──
        int128 unspecified;
        int128 hd0;
        if (p.isBuy) {
            unspecified = 0;
            hd0 = int128(uint128(p.absorbed));
        } else {
            uint256 gross = p.realEth0 - p.realEth1; // canonical gross payout
            unspecified = int128(int256(gross) - int256(p.canonicalOut)); // the sell tax
            hd0 = unspecified;
        }

        // ── 2. re-anchor all four positions onto the new canonical state ──
        BalanceDelta net = _reanchor(key, ps, p, hd0);

        _resolve(key, id, int256(net.amount0()) + int256(hd0), int256(net.amount1()), p);

        return (IHooks.afterSwap.selector, unspecified);
    }

    function _reanchor(PoolKey calldata key, PoolState storage ps, Pending memory p, int128)
        internal
        returns (BalanceDelta net)
    {
        // burn all four, leaving the pool completely empty
        for (uint256 i = 0; i < 4; i++) {
            uint128 liq = quads[key.toId()][i].liquidity;
            if (liq == 0) continue;
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: quads[key.toId()][i].tickLower,
                    tickUpper: quads[key.toId()][i].tickUpper,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: bytes32(uint256(i))
                }),
                ""
            );
            net = net + d;
        }

        // pool is empty -> walking the price costs nothing (see _traverseToCanonical)
        _traverseToCanonical(key, p.re1, p.rt1);

        ClogGenuineMath.Quad[4] memory nq =
            ClogGenuineMath.fourPositions(p.re1, p.rt1, ps.virtualEthSeed, ClogGenuineMath.VIRTUAL_TOKEN_OFFSET);
        for (uint256 i = 0; i < 4; i++) {
            quads[key.toId()][i] = nq[i];
            if (nq[i].liquidity == 0) continue;
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: nq[i].tickLower,
                    tickUpper: nq[i].tickUpper,
                    liquidityDelta: int256(uint256(nq[i].liquidity)),
                    salt: bytes32(uint256(i))
                }),
                ""
            );
            net = net + d;
        }
    }

    /// @dev Launch mint, factored out to keep unlockCallback inside via_ir's stack budget.
    ///      LAUNCH ONLY uses the single-position form. At the canonical price the four-position
    ///      construction is exact, but a token-only launch must sit ABOVE the range, and above
    ///      the range the token requirement is SUM Li*(sqrt(Pb_i) - sqrt(Pa_i)), which is not
    ///      physicalInventory - measured 0.617 tokens over the 1B supply. Zero protocol ETH wins
    ///      at launch; the first re-anchor installs the exact four positions.
    function _doLaunch(PoolKey memory key, uint256 re, uint256 rt) internal {
        PoolState storage ps = pools[key.toId()];
        ClogGenuineMath.Position memory np =
            ClogGenuineMath.positionFor(re, rt, ps.virtualEthSeed, key.tickSpacing);
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
        if (d.amount1() < 0) {
            uint256 owed = uint256(uint128(-d.amount1()));
            poolManager.sync(key.currency1);
            IERC20LikeG(Currency.unwrap(key.currency1)).transfer(address(poolManager), owed);
            poolManager.settle();
        }
        quads[key.toId()][0] = ClogGenuineMath.Quad({
            tickLower: np.tickLower, tickUpper: np.tickUpper, liquidity: np.liquidity
        });
        residualToken[key.toId()] = IERC20LikeG(Currency.unwrap(key.currency1)).balanceOf(address(this));
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
    ///      did, so ClogMarket.withdraw() is unchanged. R < 0 means the hook owes and pays from
    ///      its tracked residual.
    /// @dev Canonical ETH liability for this trade, derived purely from ClogMarket state.
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
