// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Systematic measurement of calibration-swap cost across liquidity levels and target
///         distances, with a large enough budget that sqrtPriceLimitX96 (not amountSpecified)
///         is the actual binding constraint - correcting the prior investigation's own
///         methodology error (a 1-wei placeholder was insufficient budget at L=1e6, so that
///         result measured "cost when budget-starved", not the true cost to reach the target).
contract CalibrationCostGrid is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    PoolKey key;
    MinimalToken token;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;
    uint160 constant START_PRICE = 79228162514264337593543950336; // price = 1

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new MinimalToken();
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, START_PRICE);
        vm.deal(address(this), 1_000_000 ether);
        token.mint(address(this), 1_000_000_000_000_000e18);
    }

    struct Req {
        uint8 kind; // 0 = add liquidity, 1 = swap
        int256 liquidityDelta;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        Req memory req = abi.decode(data, (Req));
        if (req.kind == 0) {
            (BalanceDelta callerDelta,) = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: req.liquidityDelta, salt: bytes32(0)}), bytes("")
            );
            _settleOrTake(callerDelta);
            return abi.encode(callerDelta);
        } else {
            BalanceDelta delta = manager.swap(
                key, IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: req.amountSpecified, sqrtPriceLimitX96: req.sqrtPriceLimitX96}), bytes("")
            );
            _settleOrTake(delta);
            return abi.encode(delta);
        }
    }

    function _settleOrTake(BalanceDelta delta) internal {
        int128 eth = -delta.amount0();
        int128 tok = -delta.amount1();
        if (eth > 0) {
            manager.sync(key.currency0);
            manager.settle{value: uint256(int256(eth))}();
        } else if (eth < 0) {
            manager.take(key.currency0, address(this), uint256(int256(-eth)));
        }
        if (tok > 0) {
            manager.sync(key.currency1);
            token.transfer(address(manager), uint256(int256(tok)));
            manager.settle();
        } else if (tok < 0) {
            manager.take(key.currency1, address(this), uint256(int256(-tok)));
        }
    }

    receive() external payable {}

    function _addLiquidity(int256 liquidityDelta) internal {
        manager.unlock(abi.encode(Req({kind: 0, liquidityDelta: liquidityDelta, zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0})));
    }

    /// @dev Large-enough-budget calibration swap: amountSpecified is deliberately huge in
    ///      magnitude (an exact-input swap for a vast amount) so sqrtPriceLimitX96 alone
    ///      determines how far the swap actually goes - the returned delta is then the TRUE
    ///      cost to reach that exact target, not an artifact of an undersized placeholder.
    function _calibrate(bool zeroForOne, uint160 targetSqrtPriceX96) internal returns (BalanceDelta) {
        bytes memory result = manager.unlock(
            abi.encode(Req({kind: 1, liquidityDelta: 0, zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: targetSqrtPriceX96}))
        );
        return abi.decode(result, (BalanceDelta));
    }

    function _priceAt(int256 bpsMove, bool up) internal pure returns (uint160) {
        // Move price by roughly bpsMove/10000 fraction, up or down, from the 1:1 start.
        // Computed precisely enough for this investigation's own purposes (exact grid points,
        // not requiring round numbers).
        if (up) {
            return uint160((uint256(START_PRICE) * (10_000 + uint256(bpsMove))) / 10_000);
        } else {
            return uint160((uint256(START_PRICE) * (10_000 - uint256(bpsMove))) / 10_000);
        }
    }

    /// @notice THE grid: exact BalanceDelta for a calibration swap at each (liquidity, target
    ///         distance) combination, both directions, reported via logs for direct inspection
    ///         - not just pass/fail, the actual numbers.
    function test_calibrationCostGrid_allLevelsAndDistances() public {
        uint256[3] memory liquidityLevels = [uint256(1_000), uint256(1_000_000), uint256(1_000_000_000)];
        string[3] memory labels = ["VERY SMALL (L=1e3)", "MODERATE (L=1e6)", "LARGER (L=1e9)"];
        int256[3] memory bpsDistances = [int256(1), int256(100), int256(5000)]; // 0.01%, 1%, 50% moves

        for (uint256 i = 0; i < liquidityLevels.length; i++) {
            // Fresh pool per liquidity level, so each measurement starts from the same known
            // price = 1 baseline with no cross-contamination from a prior calibration.
            PoolManager m = new PoolManager(address(this));
            MinimalToken t = new MinimalToken();
            PoolKey memory k = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
            m.initialize(k, START_PRICE);
            GridHelper helper = new GridHelper(m, k, t);
            vm.deal(address(helper), 1_000_000 ether);
            t.mint(address(helper), 1_000_000_000_000_000e18);
            helper.addLiquidity(int256(liquidityLevels[i]));

            emit log_string(string.concat("=== ", labels[i], " ==="));

            for (uint256 j = 0; j < bpsDistances.length; j++) {
                uint160 targetUp = _priceAt(bpsDistances[j], true);
                (int256 eth0, int256 tok0) = helper.calibrate(false, targetUp);
                emit log_named_uint("  bps move (up)", uint256(bpsDistances[j]));
                emit log_named_int("    delta.amount0 (ETH)", eth0);
                emit log_named_int("    delta.amount1 (TOKEN)", tok0);

                uint160 targetDown = _priceAt(bpsDistances[j], false);
                (int256 eth1, int256 tok1) = helper.calibrate(true, targetDown);
                emit log_named_uint("  bps move (down)", uint256(bpsDistances[j]));
                emit log_named_int("    delta.amount0 (ETH)", eth1);
                emit log_named_int("    delta.amount1 (TOKEN)", tok1);

                // The central empirical question: is cost mathematically nonzero whenever
                // liquidity > 0, for ANY nonzero target distance?
                assertTrue(eth0 != 0 || tok0 != 0, "calibrating UP must have a nonzero real cost whenever liquidity > 0");
                assertTrue(eth1 != 0 || tok1 != 0, "calibrating DOWN must have a nonzero real cost whenever liquidity > 0");
            }
        }
    }
}

contract GridHelper is IUnlockCallback {
    PoolManager manager;
    PoolKey key;
    MinimalToken token;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    constructor(PoolManager manager_, PoolKey memory key_, MinimalToken token_) {
        manager = manager_;
        key = key_;
        token = token_;
    }

    function addLiquidity(int256 liquidityDelta) external {
        manager.unlock(abi.encode(uint8(0), liquidityDelta, false, int256(0), uint160(0)));
    }

    function calibrate(bool zeroForOne, uint160 targetSqrtPriceX96) external returns (int256, int256) {
        bytes memory result = manager.unlock(abi.encode(uint8(1), int256(0), zeroForOne, int256(-1e30), targetSqrtPriceX96));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        return (int256(delta.amount0()), int256(delta.amount1()));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint8 kind, int256 liquidityDelta, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (uint8, int256, bool, int256, uint160));
        BalanceDelta delta;
        if (kind == 0) {
            (delta,) = manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0)}), bytes(""));
        } else {
            delta = manager.swap(key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}), bytes(""));
        }
        int128 eth = -delta.amount0();
        int128 tok = -delta.amount1();
        if (eth > 0) {
            manager.sync(key.currency0);
            manager.settle{value: uint256(int256(eth))}();
        } else if (eth < 0) {
            manager.take(key.currency0, address(this), uint256(int256(-eth)));
        }
        if (tok > 0) {
            manager.sync(key.currency1);
            token.transfer(address(manager), uint256(int256(tok)));
            manager.settle();
        } else if (tok < 0) {
            manager.take(key.currency1, address(this), uint256(int256(-tok)));
        }
        return abi.encode(delta);
    }

    receive() external payable {}
}

contract MinimalToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
