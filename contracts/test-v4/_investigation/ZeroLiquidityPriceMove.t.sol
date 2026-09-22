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

/// @notice ISOLATED, throwaway investigation test - not part of the permanent suite. Proves or
///         disproves, empirically, the core premise behind a proposed price-observability fix:
///         does a swap against a pool with ZERO added liquidity move slot0.sqrtPriceX96 toward
///         params.sqrtPriceLimitX96 while consuming/producing ZERO real balance delta?
contract ZeroLiquidityPriceMoveInvestigation is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    PoolKey key;
    MinimalToken token;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new MinimalToken();
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, 79228162514264337593543950336);
    }

    struct Req {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        Req memory req = abi.decode(data, (Req));
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: req.amountSpecified, sqrtPriceLimitX96: req.sqrtPriceLimitX96}),
            bytes("")
        );
        return abi.encode(delta);
    }

    function test_swapAgainstZeroLiquidity_movesPriceForFree_zeroRealDelta() public {
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceBefore, 79228162514264337593543950336, "sanity: starting price must be exactly what initialize() set");

        uint160 target = 158456325028528675187087900672; // exactly 2x the starting sqrtPriceX96 (price = 4x)
        bytes memory result = manager.unlock(abi.encode(Req({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: target})));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceAfter, target, "the pool's own price must have moved to EXACTLY the target sqrtPriceLimitX96, with no real liquidity ever added");
        assertEq(delta.amount0(), 0, "with zero liquidity, moving price must cost/produce EXACTLY zero of currency0 - a true zero-cost relocation");
        assertEq(delta.amount1(), 0, "with zero liquidity, moving price must cost/produce EXACTLY zero of currency1 - a true zero-cost relocation");
    }

    function test_swapAgainstZeroLiquidity_movesPriceForFree_otherDirection() public {
        uint160 target = 39614081257132168796771975168; // exactly half the starting sqrtPriceX96
        bytes memory result = manager.unlock(abi.encode(Req({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: target})));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceAfter, target, "the pool's own price must have moved to EXACTLY the target in the other direction too");
        assertEq(delta.amount0(), 0, "zero real cost in this direction too");
        assertEq(delta.amount1(), 0, "zero real cost in this direction too");
    }
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
