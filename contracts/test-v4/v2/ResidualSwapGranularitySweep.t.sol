// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";

/// @notice MEASUREMENT-ONLY investigation: sweeps the residual-swap mechanism across sentinel
///         liquidity sizes, using the REAL PoolManager, REAL SqrtPriceMath, and REAL
///         (unmodified) ClogMarket for ground truth. Deliberately does NOT revert on a
///         postcondition mismatch (unlike ClogV4HookV2's own afterSwap) - the point here is to
///         MEASURE the actual behavior at every L, including the ones where it fails, not to
///         test the revert-guard itself (that is tested separately once a viable L is known).
contract ResidualSwapGranularitySweep is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    MeasuringHook hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;

    address constant HOOK_ADDRESS = address(0x2AC8);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;
    int24 constant SENTINEL_TICK_LOWER = -887220;
    int24 constant SENTINEL_TICK_UPPER = 887220;

    bool private _depositing;

    function _freshSetup() internal {
        manager = new PoolManager(address(this));
        MeasuringHook impl = new MeasuringHook(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = MeasuringHook(payable(HOOK_ADDRESS));

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(1, makeAddr("tickerOwner"));

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), 1, makeAddr("multisig"), VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));
        hook.setMarket(address(market));

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        uint160 correctInitialPrice = _computeSqrtPrice(market.rt(), market.re());
        manager.initialize(key, correctInitialPrice);

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();
    }

    function _fundSentinel(uint256 L) internal returns (uint256 ethUsed, uint256 tokenUsed) {
        vm.deal(address(this), 100_000 ether);
        token.mint(address(this), 1_000_000_000_000e18);
        bytes memory result = manager.unlock(abi.encode(uint8(2), abi.encode(L)));
        (int256 a0, int256 a1) = abi.decode(result, (int256, int256));
        ethUsed = uint256(-a0);
        tokenUsed = uint256(-a1);
    }

    struct SwapRequest {
        bool zeroForOne;
        int256 amountSpecified;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not pool manager");
        if (_depositing) {
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), PHYSICAL_TOKEN_SUPPLY);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), PHYSICAL_TOKEN_SUPPLY);
            return bytes("");
        }
        (uint8 kind, bytes memory rest) = abi.decode(data, (uint8, bytes));

        if (kind == 2) {
            uint256 L = abi.decode(rest, (uint256));
            (BalanceDelta d,) = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({tickLower: SENTINEL_TICK_LOWER, tickUpper: SENTINEL_TICK_UPPER, liquidityDelta: int256(L), salt: bytes32(0)}), bytes("")
            );
            int128 ethOwed = -d.amount0();
            int128 tokOwed = -d.amount1();
            if (ethOwed > 0) {
                manager.sync(key.currency0);
                manager.settle{value: uint256(int256(ethOwed))}();
            }
            if (tokOwed > 0) {
                manager.sync(key.currency1);
                token.transfer(address(manager), uint256(int256(tokOwed)));
                manager.settle();
            }
            return abi.encode(d.amount0(), d.amount1());
        } else {
            SwapRequest memory req = abi.decode(rest, (SwapRequest));
            BalanceDelta swapDelta = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: req.zeroForOne,
                    amountSpecified: req.amountSpecified,
                    sqrtPriceLimitX96: req.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
                }),
                bytes("")
            );
            if (req.zeroForOne) {
                int128 ethOwed = -swapDelta.amount0();
                manager.sync(key.currency0);
                manager.settle{value: uint256(int256(ethOwed))}();
                int128 tokenOwed = swapDelta.amount1();
                if (tokenOwed > 0) manager.take(key.currency1, address(this), uint256(int256(tokenOwed)));
            } else {
                int128 tokenOwed = -swapDelta.amount1();
                manager.sync(key.currency1);
                token.transfer(address(manager), uint256(int256(tokenOwed)));
                manager.settle();
                int128 ethOwed = swapDelta.amount0();
                if (ethOwed > 0) manager.take(key.currency0, address(this), uint256(int256(ethOwed)));
            }
            return abi.encode(swapDelta);
        }
    }

    receive() external payable {}

    function _slot0() internal view returns (uint160 price, int24 tick) {
        (price, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function _computeSqrtPrice(uint256 rt, uint256 re) internal pure returns (uint160) {
        uint256 val = Math.mulDiv(rt, 1 << 192, re);
        uint256 s = Math.sqrt(val);
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    function test_sweep_buyDirection() public {
        uint256[5] memory Ls = [uint256(1e6), uint256(1e9), uint256(1e12), uint256(1e15), uint256(1e18)];
        for (uint256 i = 0; i < Ls.length; i++) {
            _runOneBuy(Ls[i]);
        }
    }

    function _runOneBuy(uint256 L) internal {
        _freshSetup();
        (uint256 ethUsed, uint256 tokenUsed) = _fundSentinel(L);

        uint256 reBefore = market.re();
        uint256 rtBefore = market.rt();

        uint256 buyAmount = 0.05 ether;
        vm.deal(address(this), buyAmount);
        bytes memory result = manager.unlock(abi.encode(uint8(1), abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(buyAmount)}))));
        abi.decode(result, (BalanceDelta));

        uint256 reAfter = market.re();
        uint256 rtAfter = market.rt();
        uint160 targetPrice = _computeSqrtPrice(rtAfter, reAfter);
        int24 targetTick = TickMath.getTickAtSqrtPrice(targetPrice);

        (uint160 actualPrice, int24 actualTick) = _slot0();

        uint256 absError = actualPrice > targetPrice ? actualPrice - targetPrice : targetPrice - actualPrice;
        uint256 relErrorE18 = targetPrice == 0 ? 0 : Math.mulDiv(absError, 1e18, targetPrice);

        emit log_string("========================================");
        emit log_named_uint("L", L);
        emit log_named_uint("  re before", reBefore);
        emit log_named_uint("  rt before", rtBefore);
        emit log_named_uint("  re after (target basis)", reAfter);
        emit log_named_uint("  rt after (target basis)", rtAfter);
        emit log_named_uint("  target sqrtPriceX96", targetPrice);
        emit log_named_int("  target tick", targetTick);
        emit log_named_uint("  integer residual sent through core (wei)", hook.lastResidual());
        emit log_named_uint("  core output computed (wei)", hook.lastCoreOutput());
        emit log_named_uint("  actual sqrtPriceX96", actualPrice);
        emit log_named_int("  actual tick", actualTick);
        emit log_named_uint("  ABSOLUTE ERROR (sqrtPriceX96 units)", absError);
        emit log_named_uint("  RELATIVE ERROR (x1e18, i.e. 1e18=100%)", relErrorE18);
        emit log_named_string("  tick match?", actualTick == targetTick ? "YES" : "NO");
        emit log_named_uint("  sentinel ETH principal required", ethUsed);
        emit log_named_uint("  sentinel TOKEN principal required", tokenUsed);
        emit log_named_int("  sentinel principal change from calibration - ETH (wei)", hook.lastPrincipalChangeEth());
        emit log_named_int("  sentinel principal change from calibration - TOKEN (wei)", hook.lastPrincipalChangeToken());
    }
}

/// @dev Test-only hook mirroring ClogV4HookV2's own residual-swap computation, but WITHOUT the
///      afterSwap revert-on-mismatch, so behavior can be measured across L values that would
///      otherwise revert - never used as, or confused with, a production contract.
contract MeasuringHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public market;
    address public rewardVault;

    uint256 public lastResidual;
    uint256 public lastCoreOutput;
    int256 public lastPrincipalChangeEth;
    int256 public lastPrincipalChangeToken;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function setMarket(address market_) external {
        market = market_;
    }

    function setRewardVault(address rewardVault_) external {
        rewardVault = rewardVault_;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(params.amountSpecified < 0, "exact input only");
        uint256 specifiedAmount = uint256(-params.amountSpecified);
        bool buyingToken = params.zeroForOne;

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 L = poolManager.getLiquidity(key.toId());

        if (buyingToken) {
            (uint256 tokensOut, uint256 winnerPotShare) = ClogMarket(market).applyBuy(specifiedAmount);
            uint256 r;
            uint256 coreTokensOut;
            uint160 target = _target();
            if (L > 0 && target != currentSqrtPriceX96) {
                r = SqrtPriceMath.getAmount0Delta(currentSqrtPriceX96, target, L, true);
                if (r > specifiedAmount) r = specifiedAmount;
                coreTokensOut = SqrtPriceMath.getAmount1Delta(currentSqrtPriceX96, target, L, false);
                if (coreTokensOut > tokensOut) coreTokensOut = tokensOut;
                lastResidual = r;
                lastCoreOutput = coreTokensOut;
                lastPrincipalChangeEth = int256(r);
                lastPrincipalChangeToken = -int256(coreTokensOut);
            } else {
                lastResidual = 0;
                lastCoreOutput = 0;
                lastPrincipalChangeEth = 0;
                lastPrincipalChangeToken = 0;
            }

            uint256 marketPortion = specifiedAmount - winnerPotShare - r;
            poolManager.mint(market, _id(key.currency0), marketPortion);
            if (winnerPotShare > 0) {
                poolManager.mint(rewardVault, _id(key.currency0), winnerPotShare);
                IRV(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            uint256 hookBurn = tokensOut - coreTokensOut;
            if (hookBurn > 0) poolManager.burn(market, _id(key.currency1), hookBurn);

            int128 specifiedDelta = int128(int256(specifiedAmount - r));
            int128 unspecifiedDelta = -int128(int256(tokensOut - coreTokensOut));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
        } else {
            (uint256 netEthOut, uint256 winnerPotShare,) = ClogMarket(market).applySell(specifiedAmount);
            uint256 r;
            uint256 coreEthOut;
            uint160 target = _target();
            if (L > 0 && target != currentSqrtPriceX96) {
                r = SqrtPriceMath.getAmount1Delta(currentSqrtPriceX96, target, L, true);
                if (r > specifiedAmount) r = specifiedAmount;
                coreEthOut = SqrtPriceMath.getAmount0Delta(currentSqrtPriceX96, target, L, false);
                if (coreEthOut > netEthOut) coreEthOut = netEthOut;
                lastResidual = r;
                lastCoreOutput = coreEthOut;
                lastPrincipalChangeEth = -int256(coreEthOut);
                lastPrincipalChangeToken = int256(r);
            } else {
                lastResidual = 0;
                lastCoreOutput = 0;
                lastPrincipalChangeEth = 0;
                lastPrincipalChangeToken = 0;
            }

            uint256 tokenMint = specifiedAmount - r;
            if (tokenMint > 0) poolManager.mint(market, _id(key.currency1), tokenMint);
            uint256 ethBurn = netEthOut - coreEthOut;
            poolManager.burn(market, _id(key.currency0), ethBurn);
            if (winnerPotShare > 0) {
                poolManager.burn(market, _id(key.currency0), winnerPotShare);
                poolManager.mint(rewardVault, _id(key.currency0), winnerPotShare);
                IRV(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }

            int128 specifiedDelta = int128(int256(specifiedAmount - r));
            int128 unspecifiedDelta = -int128(int256(netEthOut - coreEthOut));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
        }
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function _target() internal view returns (uint160) {
        uint256 rt = ClogMarket(market).rt();
        uint256 re = ClogMarket(market).re();
        uint256 val = Math.mulDiv(rt, 1 << 192, re);
        uint256 s = Math.sqrt(val);
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    function _id(Currency c) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(c)));
    }

    function unlockCallback(bytes calldata) external pure returns (bytes memory) {
        revert("not used");
    }

    receive() external payable {}
}

interface IRV {
    function recordWinnerPotClaim(uint256 amount) external;
}
