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
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";

/// @notice Pins down v4.0.0 BalanceDelta semantics empirically on the unmodified PoolManager with
///         NO hook: negative = caller owes PoolManager; positive = PoolManager owes caller.
///         currency0 = native ETH, currency1 = token (same orientation as every CLOG pool).
contract V4SignConventionTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    PoolManager manager;
    MinimalMockToken token;
    PoolKey key;

    uint8 private _mode; // 1 = add liquidity, 2 = swap, 3 = primitive sign probe
    bool private _zeroForOne;

    int256 public probeAfterSettle;
    int256 public probeAfterTake;
    int256 public probeAfterMint;
    int256 public probeAfterBurn;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new MinimalMockToken();
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, 1120455419495722798374638764549163); // CLOG-start price
        vm.deal(address(this), 1000 ether);
        token.mint(address(this), 1e30);
        _mode = 1;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (_mode == 1) {
            (BalanceDelta d,) = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0}), ""
            );
            _pay(d);
            return "";
        }
        if (_mode == 2) {
            BalanceDelta d = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: _zeroForOne, amountSpecified: -1e12, sqrtPriceLimitX96: _zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
                ""
            );
            _pay(d);
            return abi.encode(d);
        }
        // mode 3: primitive sign probe on currency0 (ETH), using this contract's own transient delta
        manager.sync(key.currency0);
        manager.settle{value: 100}();
        probeAfterSettle = IPoolManager(address(manager)).currencyDelta(address(this), key.currency0); // expect +100 (credited)
        manager.take(key.currency0, address(this), 40);
        probeAfterTake = IPoolManager(address(manager)).currencyDelta(address(this), key.currency0); // expect +60
        manager.mint(address(this), 0, 60);
        probeAfterMint = IPoolManager(address(manager)).currencyDelta(address(this), key.currency0); // expect 0
        manager.burn(address(this), 0, 60);
        probeAfterBurn = IPoolManager(address(manager)).currencyDelta(address(this), key.currency0); // expect +60
        manager.take(key.currency0, address(this), 60);
        return "";
    }

    function _pay(BalanceDelta d) internal {
        if (d.amount0() < 0) {
            manager.sync(key.currency0);
            manager.settle{value: uint256(int256(-d.amount0()))}();
        } else if (d.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(int256(d.amount0())));
        }
        if (d.amount1() < 0) {
            manager.sync(key.currency1);
            token.transfer(address(manager), uint256(int256(-d.amount1())));
            manager.settle();
        } else if (d.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(int256(d.amount1())));
        }
    }

    receive() external payable {}

    function _swap(bool zeroForOne) internal returns (BalanceDelta d, uint160 before, uint160 afterP) {
        (before,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        _mode = 2;
        _zeroForOne = zeroForOne;
        d = abi.decode(manager.unlock(""), (BalanceDelta));
        (afterP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function test_zeroForOne_callerSpendsEth_receivesToken_priceDown() public {
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));
        (BalanceDelta d, uint160 p0, uint160 p1) = _swap(true);
        assertLt(d.amount0(), 0, "zeroForOne: amount0 negative = caller owes ETH");
        assertGt(d.amount1(), 0, "zeroForOne: amount1 positive = caller receives token");
        assertEq(ethBefore - address(this).balance, uint256(int256(-d.amount0())), "real ETH spent == -amount0");
        assertEq(token.balanceOf(address(this)) - tokBefore, uint256(int256(d.amount1())), "real token received == amount1");
        assertLt(p1, p0, "zeroForOne moves sqrtPriceX96 DOWN");
    }

    function test_oneForZero_callerSpendsToken_receivesEth_priceUp() public {
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));
        (BalanceDelta d, uint160 p0, uint160 p1) = _swap(false);
        assertGt(d.amount0(), 0, "oneForZero: amount0 positive = caller receives ETH");
        assertLt(d.amount1(), 0, "oneForZero: amount1 negative = caller owes token");
        assertEq(address(this).balance - ethBefore, uint256(int256(d.amount0())), "real ETH received == amount0");
        assertEq(tokBefore - token.balanceOf(address(this)), uint256(int256(-d.amount1())), "real token spent == -amount1");
        assertGt(p1, p0, "oneForZero moves sqrtPriceX96 UP");
    }

    function test_primitiveDeltaSigns_settleCredits_takeDebits_mintDebits_burnCredits() public {
        _mode = 3;
        manager.unlock("");
        assertEq(probeAfterSettle, 100, "settle credits the caller (+)");
        assertEq(probeAfterTake, 60, "take debits the caller (-)");
        assertEq(probeAfterMint, 0, "mint debits the caller (-)");
        assertEq(probeAfterBurn, 60, "burn credits the caller (+)");
    }
}
