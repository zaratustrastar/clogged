// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {RewardVault} from "../../src/RewardVault.sol";

interface IRewardVaultRecorderLike {
    function recordWinnerPotClaim(uint256 amount) external;
}

/// @notice TEST-ONLY investigation fixture, never imported by production source under src-v4/.
///         Mimics ClogV4Hook's own beforeSwap logic EXACTLY (delegating to the real, unmodified
///         ClogMarket for genuine CLOG accounting) but adds a test-controllable
///         `setCalibrating` toggle that makes beforeSwap skip straight to a zero delta - a
///         stand-in for the internal, hook-only reentrancy flag a REAL calibration mechanism
///         would set around its own nested calibration swap. This isolates "what happens to the
///         LP/price when a calibration-style swap runs" from "how does the hook decide it's a
///         calibration" (a separate, already-reasoned-through design question), without
///         modifying any real production file to do it.
contract MockCalibratingHook is IHooks, IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public market;
    address public rewardVault;
    bool public calibrating;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function setMarket(address market_) external {
        market = market_;
    }

    function setRewardVault(address rewardVault_) external {
        rewardVault = rewardVault_;
    }

    function setCalibrating(bool value) external {
        calibrating = value;
    }

    struct CalibrateData {
        PoolKey key;
        bool zeroForOne;
        uint160 targetSqrtPriceX96;
    }

    /// @notice Mimics the REAL proposed mechanism: the HOOK ITSELF (not an external caller)
    ///         initiates the nested calibration swap and its own funding - the hook is the one
    ///         holding the market's own ERC6909 approval, exactly matching how a real
    ///         calibration mechanism would need to work (an external caller lacks that
    ///         approval entirely, confirmed empirically by this investigation's own first,
    ///         failing attempt at routing funding through the test contract instead).
    function triggerCalibration(PoolKey calldata key, bool zeroForOne, uint160 targetSqrtPriceX96) external returns (BalanceDelta) {
        calibrating = true;
        bytes memory result = poolManager.unlock(abi.encode(CalibrateData({key: key, zeroForOne: zeroForOne, targetSqrtPriceX96: targetSqrtPriceX96})));
        calibrating = false;
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        CalibrateData memory req = abi.decode(data, (CalibrateData));
        BalanceDelta delta = poolManager.swap(
            req.key, IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: req.targetSqrtPriceX96}), bytes("")
        );

        // Fund the calibration's own real cost from the market's own claim - purely as
        // internal PoolManager-ledger movements (burn/mint), never touching real external
        // funds at all: burning the market's claim for whatever the swap owes produces an
        // exactly offsetting credit for this hook, and minting the market a claim for
        // whatever the swap paid out produces an exactly offsetting debit - both net to zero
        // without any settle/take needed, mirroring exactly how the real beforeSwap's own
        // mint/burn pair already works for ordinary trades.
        int128 eth = -delta.amount0();
        int128 tok = -delta.amount1();
        if (eth > 0) {
            poolManager.burn(market, uint256(uint160(address(0))), uint256(int256(eth)));
        } else if (eth < 0) {
            poolManager.mint(market, uint256(uint160(address(0))), uint256(int256(-eth)));
        }
        if (tok > 0) {
            address tokenAddr = ClogMarket(market).token();
            poolManager.burn(market, uint256(uint160(tokenAddr)), uint256(int256(tok)));
        } else if (tok < 0) {
            address tokenAddr = ClogMarket(market).token();
            poolManager.mint(market, uint256(uint160(tokenAddr)), uint256(int256(-tok)));
        }

        return abi.encode(delta);
    }

    receive() external payable {}

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (calibrating) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        require(params.amountSpecified < 0, "only exact input supported in this fixture");
        uint256 specifiedAmount = uint256(-params.amountSpecified);
        bool buyingToken = params.zeroForOne;
        uint256 unspecifiedAmount;

        if (buyingToken) {
            (uint256 tokensOut, uint256 winnerPotShare) = ClogMarket(market).applyBuy(specifiedAmount);
            uint256 marketPortion = specifiedAmount - winnerPotShare;
            poolManager.mint(market, _currencyId(key.currency0), marketPortion);
            if (winnerPotShare > 0) {
                poolManager.mint(rewardVault, _currencyId(key.currency0), winnerPotShare);
                IRewardVaultRecorderLike(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            poolManager.burn(market, _currencyId(key.currency1), tokensOut);
            unspecifiedAmount = tokensOut;
        } else {
            (uint256 netEthOut, uint256 winnerPotShare,) = ClogMarket(market).applySell(specifiedAmount);
            poolManager.mint(market, _currencyId(key.currency1), specifiedAmount);
            poolManager.burn(market, _currencyId(key.currency0), netEthOut);
            if (winnerPotShare > 0) {
                poolManager.burn(market, _currencyId(key.currency0), winnerPotShare);
                poolManager.mint(rewardVault, _currencyId(key.currency0), winnerPotShare);
                IRewardVaultRecorderLike(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            unspecifiedAmount = netEthOut;
        }

        int128 specifiedDelta = int128(int256(specifiedAmount));
        int128 unspecifiedDelta = -int128(int256(unspecifiedAmount));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    function _currencyId(Currency currency) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(currency)));
    }
}
