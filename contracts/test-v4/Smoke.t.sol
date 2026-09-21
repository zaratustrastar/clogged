// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Minimal smoke test: proves the real v4-core PoolManager can be deployed and
///         initialized in this environment at all, before any ClogMarket/hook logic is built
///         on top of it. Deliberately no hook (address(0)) - just confirming the dependency
///         setup (separate solc 0.8.26 profile, real v4-core source) actually works.
contract SmokeTest is Test {
    PoolManager manager;

    function setUp() public {
        manager = new PoolManager(address(this));
    }

    function test_deployAndInitializeTrivialPool() public {
        // A trivial native-ETH / mock-ERC20 pool, no hook.
        Currency currency0 = Currency.wrap(address(0)); // native ETH
        Currency currency1 = Currency.wrap(address(0x1234)); // arbitrary placeholder address, no real token needed just to prove initialize() works
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        int24 tick = manager.initialize(key, 79228162514264337593543950336); // sqrtPriceX96 for price = 1
        assertEq(tick, 0);
    }
}
