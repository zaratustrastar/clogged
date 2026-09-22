// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";

interface IRV3 {
    function recordWinnerPotClaim(uint256 amount) external;
}

interface IERC20V3 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CalibratingHookV3 (TEST CANDIDATE - not production source)
/// @notice Protocol-funded calibration candidate. User trades are absorbed 100% via
///         BeforeSwapDelta exactly as V1; afterSwap then issues ONE nested core swap against
///         the protocol sentinel to move slot0 to sqrt(rt/re)*2^96.
///
/// @dev FUNDING RULE (the point of this revision): calibration is funded ONLY by the explicit
///      operatingFundETH / operatingFundToken ledger. Raw balances and transient PoolManager
///      credits are never consulted to decide whether calibration can proceed. For the
///      calibration BalanceDelta d (v4 semantics, verified against pinned v4.0.0 source:
///      negative = hook owes PoolManager, positive = PoolManager owes hook):
///        d.amount0 < 0: require ledgerETH >= |d.amount0|; ledgerETH -= |d.amount0|; settle ETH
///        d.amount0 > 0: take ETH;   ledgerETH   += d.amount0
///        d.amount1 < 0: require ledgerToken >= |d.amount1|; ledgerToken -= |d.amount1|; settle token
///        d.amount1 > 0: take token; ledgerToken += d.amount1
///      After calibration, raw balances must still cover the ledger (asserted in-contract).
///
/// @dev RECURSION: pinned v4.0.0 Hooks.beforeSwap/afterSwap return early when
///      msg.sender == address(hook), so a hook-initiated nested swap never calls back into this
///      contract. `_calibrating` is defense-in-depth only; `calibratingShortCircuitHits`
///      records whether it was ever actually needed (tests assert it stays 0).
contract CalibratingHookV3 is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public market;
    address public rewardVault;
    bool private _calibrating;
    address private _lpFunder;

    int24 constant SENTINEL_TICK_LOWER = -887220;
    int24 constant SENTINEL_TICK_UPPER = 887220;

    uint256 public operatingFundETH;
    uint256 public operatingFundToken;

    uint256 public beforeSwapCalls;
    uint256 public afterSwapCalls;
    uint256 public calibratingShortCircuitHits;
    uint256 public nestedCalibrationSwaps;

    // stage: 1 = end of outer beforeSwap, 2 = immediately before nested swap,
    //        3 = immediately after nested swap (pre-settlement), 4 = after calibration settlement
    // data = abi.encode(ProbeData)
    event Probe(uint8 indexed stage, bytes data);

    struct ProbeData {
        uint256 rawEth;
        uint256 rawToken;
        uint256 ledgerEth;
        uint256 ledgerToken;
        int256 transientDelta0;
        int256 transientDelta1;
        uint256 hookClaim0;
        uint256 hookClaim1;
        uint256 marketClaim0;
        uint256 marketClaim1;
    }
    event CalibrationDelta(int128 amount0, int128 amount1);

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

    /// @notice Installs the sentinel LP (paid from msg.value + caller's token approval, exact
    ///         amounts from PoolManager's own delta) and credits the operating-fund ledger with
    ///         exactly `tokenOperatingFund` token and whatever msg.value the LP did not consume.
    function fundSentinelAndOperatingFund(PoolKey calldata key, uint256 sentinelL, uint256 tokenOperatingFund) external payable {
        address tokenAddr = Currency.unwrap(key.currency1);
        require(IERC20V3(tokenAddr).transferFrom(msg.sender, address(this), tokenOperatingFund), "op fund pull failed");
        operatingFundToken += tokenOperatingFund;

        uint256 ethBefore = address(this).balance - msg.value;
        _lpFunder = msg.sender;
        poolManager.unlock(abi.encode(uint8(3), abi.encode(key, sentinelL)));
        _lpFunder = address(0);
        // Whatever msg.value remains after the LP's own ETH cost is credited to the ledger
        // EXPLICITLY - never left as an implicit raw-balance cushion.
        operatingFundETH += address(this).balance - ethBefore;
    }

    /// @notice TEST-ONLY: lowers the ledger without touching raw balances, to prove the ledger
    ///         (not raw balances or transient credits) decides whether calibration is funded.
    function reduceOperatingFundForTest(uint256 newEth, uint256 newToken) external {
        require(newEth <= operatingFundETH && newToken <= operatingFundToken, "may only reduce");
        operatingFundETH = newEth;
        operatingFundToken = newToken;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert("unused");
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == address(this), "only sentinel manager");
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, BalanceDelta)
    {
        revert("unused");
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == address(this), "only sentinel manager");
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, BalanceDelta)
    {
        revert("unused");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        revert("unused");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        revert("unused");
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCalls++;
        if (_calibrating) {
            calibratingShortCircuitHits++;
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        require(params.amountSpecified < 0, "exact input only");
        uint256 specifiedAmount = uint256(-params.amountSpecified);
        BeforeSwapDelta result;

        if (params.zeroForOne) {
            (uint256 tokensOut, uint256 winnerPotShare) = ClogMarket(market).applyBuy(specifiedAmount);
            poolManager.mint(market, _id(key.currency0), specifiedAmount - winnerPotShare);
            if (winnerPotShare > 0) {
                poolManager.mint(rewardVault, _id(key.currency0), winnerPotShare);
                IRV3(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            poolManager.burn(market, _id(key.currency1), tokensOut);
            result = toBeforeSwapDelta(int128(int256(specifiedAmount)), -int128(int256(tokensOut)));
        } else {
            (uint256 netEthOut, uint256 winnerPotShare,) = ClogMarket(market).applySell(specifiedAmount);
            poolManager.mint(market, _id(key.currency1), specifiedAmount);
            poolManager.burn(market, _id(key.currency0), netEthOut);
            if (winnerPotShare > 0) {
                poolManager.burn(market, _id(key.currency0), winnerPotShare);
                poolManager.mint(rewardVault, _id(key.currency0), winnerPotShare);
                IRV3(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            result = toBeforeSwapDelta(int128(int256(specifiedAmount)), -int128(int256(netEthOut)));
        }
        _probe(1, key);
        return (IHooks.beforeSwap.selector, result, 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        afterSwapCalls++;
        if (_calibrating) {
            calibratingShortCircuitHits++;
            return (IHooks.afterSwap.selector, 0);
        }
        uint160 target = _target();
        (uint160 current,,,) = poolManager.getSlot0(key.toId());
        if (target != current) {
            _calibrating = true;
            _performCalibration(key, target, current);
            _calibrating = false;
        }
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Called inside the outer unlock session (unlock() is not re-entered; swap/settle/take
    ///      only require an active session). Funding decisions use the ledger only.
    function _performCalibration(PoolKey calldata key, uint160 target, uint160 current) internal {
        _probe(2, key);
        bool zeroForOne = target < current; // verified: zeroForOne moves sqrtPrice down
        nestedCalibrationSwaps++;
        BalanceDelta d = poolManager.swap(
            key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: target}), bytes("")
        );
        emit CalibrationDelta(d.amount0(), d.amount1());
        _probe(3, key);

        _settleCalibrationEth(key, d.amount0());
        _settleCalibrationToken(key, d.amount1());
        _assertLedgerBacked(key);
        _probe(4, key);
    }

    function _settleCalibrationEth(PoolKey calldata key, int128 a0) internal {
        if (a0 < 0) {
            uint256 owed = uint256(int256(-a0));
            require(operatingFundETH >= owed, "operating fund ETH insufficient");
            operatingFundETH -= owed;
            poolManager.sync(key.currency0);
            poolManager.settle{value: owed}();
        } else if (a0 > 0) {
            uint256 received = uint256(int256(a0));
            poolManager.take(key.currency0, address(this), received);
            operatingFundETH += received;
        }
    }

    function _settleCalibrationToken(PoolKey calldata key, int128 a1) internal {
        address tokenAddr = Currency.unwrap(key.currency1);
        if (a1 < 0) {
            uint256 owed = uint256(int256(-a1));
            require(operatingFundToken >= owed, "operating fund token insufficient");
            operatingFundToken -= owed;
            poolManager.sync(key.currency1);
            require(IERC20V3(tokenAddr).transfer(address(poolManager), owed), "token transfer failed");
            poolManager.settle();
        } else if (a1 > 0) {
            uint256 received = uint256(int256(a1));
            poolManager.take(key.currency1, address(this), received);
            operatingFundToken += received;
        }
    }

    function _assertLedgerBacked(PoolKey calldata key) internal view {
        require(address(this).balance >= operatingFundETH, "ledger ETH exceeds raw balance");
        require(IERC20V3(Currency.unwrap(key.currency1)).balanceOf(address(this)) >= operatingFundToken, "ledger token exceeds raw balance");
    }

    function _probe(uint8 stage, PoolKey calldata key) internal {
        emit Probe(stage, this.probeState(key.currency0, key.currency1));
    }

    /// @notice Read-only instrumentation snapshot (external so via-IR does not inline it at
    ///         four call sites). Returns abi.encode(ProbeData).
    function probeState(Currency c0, Currency c1) external view returns (bytes memory) {
        ProbeData memory pd;
        address tokenAddr = Currency.unwrap(c1);
        pd.rawEth = address(this).balance;
        pd.rawToken = IERC20V3(tokenAddr).balanceOf(address(this));
        pd.ledgerEth = operatingFundETH;
        pd.ledgerToken = operatingFundToken;
        pd.transientDelta0 = TransientStateLibrary.currencyDelta(poolManager, address(this), c0);
        pd.transientDelta1 = TransientStateLibrary.currencyDelta(poolManager, address(this), c1);
        pd.hookClaim0 = poolManager.balanceOf(address(this), uint256(uint160(Currency.unwrap(c0))));
        pd.hookClaim1 = poolManager.balanceOf(address(this), uint256(uint160(tokenAddr)));
        pd.marketClaim0 = poolManager.balanceOf(market, uint256(uint160(Currency.unwrap(c0))));
        pd.marketClaim1 = poolManager.balanceOf(market, uint256(uint160(tokenAddr)));
        return abi.encode(pd);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (uint8 kind, bytes memory rest) = abi.decode(data, (uint8, bytes));
        require(kind == 3, "only sentinel funding uses unlock() directly");
        (PoolKey memory key, uint256 sentinelL) = abi.decode(rest, (PoolKey, uint256));
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: SENTINEL_TICK_LOWER, tickUpper: SENTINEL_TICK_UPPER, liquidityDelta: int256(sentinelL), salt: bytes32(0)}),
            bytes("")
        );
        if (d.amount0() < 0) {
            poolManager.sync(key.currency0);
            poolManager.settle{value: uint256(int256(-d.amount0()))}();
        }
        if (d.amount1() < 0) {
            uint256 owed = uint256(int256(-d.amount1()));
            address tokenAddr = Currency.unwrap(key.currency1);
            require(IERC20V3(tokenAddr).transferFrom(_lpFunder, address(this), owed), "lp token pull failed");
            poolManager.sync(key.currency1);
            require(IERC20V3(tokenAddr).transfer(address(poolManager), owed), "lp token transfer failed");
            poolManager.settle();
        }
        return bytes("");
    }

    function _target() internal view returns (uint160) {
        uint256 val = Math.mulDiv(ClogMarket(market).rt(), 1 << 192, ClogMarket(market).re());
        uint256 s = Math.sqrt(val);
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    function _id(Currency c) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(c)));
    }

    receive() external payable {}
}
