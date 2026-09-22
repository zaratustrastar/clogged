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
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../../src-v4/ClogMarket.sol";

interface IRewardVaultRecorderV2 {
    function recordWinnerPotClaim(uint256 amount) external;
}

interface IERC20LikeV2 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title RejectedResidualHook (REJECTED residual-user-swap design - kept only as evidence)
/// @notice V2 canary hook. Preserves ClogMarket's own economics EXACTLY (same contract, zero
///         changes) while making PoolManager's own slot0 a faithful, externally-observable
///         mirror of CLOG's own marginal price, and giving PoolManager nonzero real active
///         liquidity for third-party terminals to recognize.
///
/// @dev THE CORE MECHANISM (read this before touching beforeSwap/afterSwap):
///      V1's ClogV4Hook fully absorbs every swap via BeforeSwapDelta, driving the core engine's
///      own amountToSwap to exactly zero - Pool.sol's own zero-amount early return then leaves
///      slot0 completely frozen forever (proven empirically, not merely reasoned about, in
///      test-v4/_investigation/CurrentHookPriceStatic.t.sol). This hook instead computes CLOG's
///      full economics exactly as V1 does, then works out the MINIMAL residual amount `r` that,
///      swapped against the protocol-controlled sentinel position's own real liquidity, moves
///      slot0 from its pre-trade value to EXACTLY the post-trade CLOG marginal price
///      (sqrt(rt/re)*2^96 - see _targetSqrtPriceX96, derived from and validated against
///      ClogMarket's own _safeExtract, which uses this exact re/rt ratio as its own internal
///      spot-price definition for solvency checks, not merely assumed). `r` is computed with
///      the EXACT SAME v4-core SqrtPriceMath functions (same rounding mode) the core swap
///      engine itself uses internally, so the achieved price is bit-exact, not approximate.
///
///      Because `r` is sized by the price MOVEMENT (fixed by CLOG's own curve) and the
///      sentinel's fixed liquidity L - never by the trade's own size - it is always tiny
///      relative to any real trade, and its magnitude is fully bounded by L (see
///      test-v4/_investigation for the measured linear cost-vs-L relationship this relies on).
///
///      CONSEQUENCE, STATED PLAINLY: since `r` flows through the sentinel's own liquidity
///      instead of the market's own claim, and the hook's own BeforeSwapDelta must exactly
///      cancel whatever it minted/burned (or the hook's own account is left with a nonzero
///      delta and the whole unlock() reverts), the market's own ERC6909 claim receives
///      EXACTLY `r` less than its own realETH state assumes entered the curve on a buy (and
///      symmetrically less token claim on a sell). This is a real, tiny, fully bounded-by-L
///      economic side effect of providing external price observability - not hidden, tracked
///      explicitly via events, and small enough (a few wei to roughly 1e5 wei at the tested
///      L=1,000 sentinel size) to be utterly negligible next to ETH-scale trades, but it is a
///      genuine deviation from V1's exact conservation invariant and must be treated as an
///      operational item (sentinel/market reconciliation), not ignored.
///
///      afterSwap is used PURELY as a postcondition verifier (never as the mechanism that
///      moves price): it reverts unless the ACTUAL post-swap slot0 lands within SLOT0_TOLERANCE
///      of the target computed during beforeSwap. This one check absorbs two distinct risks at
///      once: any residual rounding mismatch in `r`'s own computation, AND a case where the
///      swap's own caller-supplied sqrtPriceLimitX96 was too restrictive to let the core engine
///      actually reach the target - either way, the trade reverts rather than silently landing
///      on a wrong observable price.
contract RejectedResidualHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable launchInitializer;
    address public rewardVault;
    address public sentinelFunder;

    mapping(PoolId => address) public marketOf;
    mapping(address => PoolId) public poolOf;
    // 0 = no postcondition check pending for this pool (set just before the core swap runs in
    // beforeSwap, cleared and checked in afterSwap for the SAME transaction - never persists
    // across transactions).
    mapping(PoolId => uint256) private _pendingTargetSqrtPriceX96;

    int24 public constant SENTINEL_TICK_LOWER = -887220; // full range, tickSpacing = 60
    int24 public constant SENTINEL_TICK_UPPER = 887220;
    bytes32 public constant SENTINEL_SALT = keccak256("CLOG_V2_SENTINEL");

    // Defensive margin only - the residual-swap math is proven bit-exact against v4-core's own
    // SqrtPriceMath (see test suite), so this exists purely to absorb any truly unrelated
    // rounding noise, not because the design relies on it. Utterly negligible relative to
    // sqrtPriceX96's own ~1e33+ typical magnitude for this pairing.
    uint256 public constant SLOT0_TOLERANCE = 4;

    event SentinelResidualSwap(PoolId indexed poolId, bool zeroForOne, uint256 residualAmount, uint256 coreOutput);
    event SlotZeroCalibrated(PoolId indexed poolId, uint160 targetSqrtPriceX96, uint160 actualSqrtPriceX96);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(IPoolManager poolManager_, address launchInitializer_) {
        require(address(poolManager_) != address(0) && launchInitializer_ != address(0), "zero address");
        poolManager = poolManager_;
        launchInitializer = launchInitializer_;
    }

    function setRewardVault(address rewardVault_) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(rewardVault == address(0), "already set");
        require(rewardVault_ != address(0), "zero reward vault");
        rewardVault = rewardVault_;
    }

    /// @notice The ONLY address ever allowed to fund/withdraw the sentinel position (see
    ///         beforeAddLiquidity/beforeRemoveLiquidity below, which gate on
    ///         sender == address(this) - fundSentinel/withdrawSentinel are the sole entry
    ///         points that make the hook itself call modifyLiquidity, and both are restricted
    ///         to this address). Set once, immutably in practice (no setter after the first
    ///         call), by the launch initializer.
    function setSentinelFunder(address funder_) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(sentinelFunder == address(0), "already set");
        require(funder_ != address(0), "zero funder");
        sentinelFunder = funder_;
    }

    function registerMarket(PoolKey calldata key, address market) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(address(key.hooks) == address(this), "wrong hook");
        require(Currency.unwrap(key.currency0) == address(0), "currency0 must be native ETH");
        require(Currency.unwrap(key.currency1) == ClogMarket(market).token(), "currency1 mismatch");
        require(ClogMarket(market).hook() == address(this), "market hook mismatch");
        require(rewardVault != address(0), "reward vault not configured");
        PoolId poolId = key.toId();
        require(marketOf[poolId] == address(0), "already registered");
        marketOf[poolId] = market;
        poolOf[market] = poolId;
    }

    // ── Hook callbacks ──────────────────────────────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert("afterInitialize not used");
    }

    /// @notice Only this hook's own internal calls (via fundSentinel's own unlockCallback) may
    ///         add liquidity to any pool this hook governs - no outsider, however well-
    ///         intentioned, can add ordinary LP here at all.
    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == address(this), "only the sentinel manager may add liquidity");
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Symmetric to beforeAddLiquidity - only this hook's own internal calls (via
    ///         withdrawSentinel) may ever remove liquidity.
    function beforeRemoveLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == address(this), "only the sentinel manager may remove liquidity");
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("donate not used");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("donate not used");
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        address market = marketOf[poolId];
        require(market != address(0), "unknown market");
        require(rewardVault != address(0), "reward vault not configured");
        require(params.amountSpecified < 0, "only exact input supported in this slice");

        uint256 specifiedAmount = uint256(-params.amountSpecified);
        bool buyingToken = params.zeroForOne;

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 sentinelLiquidity = poolManager.getLiquidity(poolId);

        uint256 clogOutput;
        if (buyingToken) {
            (uint256 tokensOut, uint256 winnerPotShare) = ClogMarket(market).applyBuy(specifiedAmount);
            clogOutput = tokensOut;

            uint256 r;
            uint256 coreTokensOut;
            uint160 targetSqrtPriceX96 = _targetSqrtPriceX96(market);
            if (sentinelLiquidity > 0 && targetSqrtPriceX96 != currentSqrtPriceX96) {
                r = SqrtPriceMath.getAmount0Delta(currentSqrtPriceX96, targetSqrtPriceX96, sentinelLiquidity, true);
                // Defensive clamp: the residual must never exceed what the trade itself
                // provides/produces - if an extreme sentinel size or edge-case price jump ever
                // implied otherwise, clamp rather than underflow; the afterSwap postcondition
                // check will then correctly reject the trade instead of silently mispricing it.
                if (r > specifiedAmount) r = specifiedAmount;
                coreTokensOut = SqrtPriceMath.getAmount1Delta(currentSqrtPriceX96, targetSqrtPriceX96, sentinelLiquidity, false);
                if (coreTokensOut > tokensOut) coreTokensOut = tokensOut;
                _pendingTargetSqrtPriceX96[poolId] = targetSqrtPriceX96;
                emit SentinelResidualSwap(poolId, true, r, coreTokensOut);
            }

            uint256 marketPortion = specifiedAmount - winnerPotShare - r;
            poolManager.mint(market, _currencyId(key.currency0), marketPortion);
            if (winnerPotShare > 0) {
                poolManager.mint(rewardVault, _currencyId(key.currency0), winnerPotShare);
                IRewardVaultRecorderV2(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            uint256 hookBurnAmount = tokensOut - coreTokensOut;
            if (hookBurnAmount > 0) {
                poolManager.burn(market, _currencyId(key.currency1), hookBurnAmount);
            }

            int128 specifiedDelta = int128(int256(specifiedAmount - r));
            int128 unspecifiedDelta = -int128(int256(tokensOut - coreTokensOut));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
        } else {
            (uint256 netEthOut, uint256 winnerPotShare,) = ClogMarket(market).applySell(specifiedAmount);
            clogOutput = netEthOut;

            uint256 r;
            uint256 coreEthOut;
            uint160 targetSqrtPriceX96 = _targetSqrtPriceX96(market);
            if (sentinelLiquidity > 0 && targetSqrtPriceX96 != currentSqrtPriceX96) {
                r = SqrtPriceMath.getAmount1Delta(currentSqrtPriceX96, targetSqrtPriceX96, sentinelLiquidity, true);
                if (r > specifiedAmount) r = specifiedAmount;
                coreEthOut = SqrtPriceMath.getAmount0Delta(currentSqrtPriceX96, targetSqrtPriceX96, sentinelLiquidity, false);
                if (coreEthOut > netEthOut) coreEthOut = netEthOut;
                _pendingTargetSqrtPriceX96[poolId] = targetSqrtPriceX96;
                emit SentinelResidualSwap(poolId, false, r, coreEthOut);
            }

            uint256 tokenMintAmount = specifiedAmount - r;
            if (tokenMintAmount > 0) {
                poolManager.mint(market, _currencyId(key.currency1), tokenMintAmount);
            }
            uint256 ethBurnAmount = netEthOut - coreEthOut;
            poolManager.burn(market, _currencyId(key.currency0), ethBurnAmount);
            if (winnerPotShare > 0) {
                poolManager.burn(market, _currencyId(key.currency0), winnerPotShare);
                poolManager.mint(rewardVault, _currencyId(key.currency0), winnerPotShare);
                IRewardVaultRecorderV2(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }

            int128 specifiedDelta = int128(int256(specifiedAmount - r));
            int128 unspecifiedDelta = -int128(int256(netEthOut - coreEthOut));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
        }
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint256 target = _pendingTargetSqrtPriceX96[poolId];
        if (target != 0) {
            _pendingTargetSqrtPriceX96[poolId] = 0;
            (uint160 actual,,,) = poolManager.getSlot0(poolId);
            uint256 diff = actual > target ? actual - target : target - actual;
            require(diff <= SLOT0_TOLERANCE, "slot0 did not reach the expected CLOG-implied price");
            emit SlotZeroCalibrated(poolId, uint160(target), actual);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice The CLOG-implied external marginal price: sqrt(rt/re) * 2^96, computed via the
    ///         same overflow-safe mulDiv+sqrt pattern verified separately (matches a precise
    ///         decimal computation exactly, and matches TickMath's valid bounds for any
    ///         realistic re/rt this market can reach). Validated against ClogMarket's own
    ///         _safeExtract, which independently uses re/rt as its own internal spot-price
    ///         definition for solvency checks - not merely assumed to be the right formula.
    function _targetSqrtPriceX96(address market) internal view returns (uint160) {
        uint256 rt = ClogMarket(market).rt();
        uint256 re = ClogMarket(market).re();
        uint256 val = Math.mulDiv(rt, 1 << 192, re);
        uint256 sqrtPrice = Math.sqrt(val);
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (sqrtPrice > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sqrtPrice);
    }

    function _currencyId(Currency currency) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(currency)));
    }

    // ── Sentinel funding/withdrawal - the ONLY paths that ever call modifyLiquidity on a pool
    //    this hook governs, and the ONLY calls beforeAddLiquidity/beforeRemoveLiquidity permit ──

    struct SentinelOp {
        PoolKey key;
        int256 liquidityDelta;
        address counterparty; // funder (add) or recipient (remove)
    }

    /// @notice Funds the sentinel position for `key`'s pool with `liquidityDelta` (positive) of
    ///         liquidity, pulling real ETH (msg.value) and real token (pre-approved
    ///         transferFrom) from the caller, who must be the designated sentinelFunder. Unused
    ///         msg.value is refunded in the same transaction.
    function fundSentinel(PoolKey calldata key, int256 liquidityDelta) external payable returns (int256 amount0, int256 amount1) {
        require(msg.sender == sentinelFunder, "not sentinel funder");
        require(liquidityDelta > 0, "fundSentinel requires positive liquidityDelta");
        bytes memory result = poolManager.unlock(abi.encode(uint8(0), abi.encode(SentinelOp({key: key, liquidityDelta: liquidityDelta, counterparty: msg.sender}))));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        amount0 = int256(delta.amount0());
        amount1 = int256(delta.amount1());
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    /// @notice Withdraws `-liquidityDelta` of the sentinel position for `key`'s pool, sending
    ///         the recovered ETH/token entirely to the caller, who must be the designated
    ///         sentinelFunder.
    function withdrawSentinel(PoolKey calldata key, int256 liquidityDelta) external returns (int256 amount0, int256 amount1) {
        require(msg.sender == sentinelFunder, "not sentinel funder");
        require(liquidityDelta < 0, "withdrawSentinel requires negative liquidityDelta");
        bytes memory result = poolManager.unlock(abi.encode(uint8(1), abi.encode(SentinelOp({key: key, liquidityDelta: liquidityDelta, counterparty: msg.sender}))));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        amount0 = int256(delta.amount0());
        amount1 = int256(delta.amount1());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (uint8 kind, bytes memory opBytes) = abi.decode(data, (uint8, bytes));
        SentinelOp memory op = abi.decode(opBytes, (SentinelOp));

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            op.key,
            IPoolManager.ModifyLiquidityParams({tickLower: SENTINEL_TICK_LOWER, tickUpper: SENTINEL_TICK_UPPER, liquidityDelta: op.liquidityDelta, salt: SENTINEL_SALT}),
            bytes("")
        );

        if (kind == 0) {
            int128 ethOwed = -callerDelta.amount0();
            int128 tokOwed = -callerDelta.amount1();
            if (ethOwed > 0) {
                poolManager.sync(op.key.currency0);
                poolManager.settle{value: uint256(int256(ethOwed))}();
            }
            if (tokOwed > 0) {
                address tokenAddr = Currency.unwrap(op.key.currency1);
                require(IERC20LikeV2(tokenAddr).transferFrom(op.counterparty, address(this), uint256(int256(tokOwed))), "token pull failed");
                poolManager.sync(op.key.currency1);
                require(IERC20LikeV2(tokenAddr).transfer(address(poolManager), uint256(int256(tokOwed))), "token transfer to pool manager failed");
                poolManager.settle();
            }
        } else {
            int128 ethOut = callerDelta.amount0();
            int128 tokOut = callerDelta.amount1();
            if (ethOut > 0) {
                poolManager.take(op.key.currency0, op.counterparty, uint256(int256(ethOut)));
            }
            if (tokOut > 0) {
                poolManager.take(op.key.currency1, op.counterparty, uint256(int256(tokOut)));
            }
        }
        return abi.encode(callerDelta);
    }

    receive() external payable {}
}
