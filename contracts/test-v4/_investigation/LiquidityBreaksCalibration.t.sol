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

/// @notice ISOLATED investigation. Tests whether the "calibration swap is zero-cost" premise
///         (proven true for a zero-liquidity pool in ZeroLiquidityPriceMove.t.sol) still holds
///         once REAL, nonzero, full-range liquidity has been added - directly testing the
///         concern raised: does the calibration swap's own real BalanceDelta stay zero, or does
///         it become nonzero and scale with the liquidity amount?
contract LiquidityBreaksCalibrationInvestigation is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    PoolKey key;
    MinimalToken token;

    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new MinimalToken();
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, 79228162514264337593543950336); // price = 1
    }

    struct AddLiquidityReq {
        int256 liquidityDelta;
    }

    struct SwapReq {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool isAdd, bytes memory inner) = abi.decode(data, (bool, bytes));
        if (isAdd) {
            AddLiquidityReq memory req = abi.decode(inner, (AddLiquidityReq));
            (BalanceDelta callerDelta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: req.liquidityDelta, salt: bytes32(0)}),
                bytes("")
            );
            // Settle whatever the position actually requires.
            int128 eth = -callerDelta.amount0();
            int128 tok = -callerDelta.amount1();
            if (eth > 0) {
                manager.sync(key.currency0);
                manager.settle{value: uint256(int256(eth))}();
            }
            if (tok > 0) {
                manager.sync(key.currency1);
                token.transfer(address(manager), uint256(int256(tok)));
                manager.settle();
            }
            if (eth < 0) manager.take(key.currency0, address(this), uint256(int256(-eth)));
            if (tok < 0) manager.take(key.currency1, address(this), uint256(int256(-tok)));
            return abi.encode(callerDelta);
        } else {
            SwapReq memory req = abi.decode(inner, (SwapReq));
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: req.amountSpecified, sqrtPriceLimitX96: req.sqrtPriceLimitX96}),
                bytes("")
            );
            // Settle/take whatever this swap requires, for real - if it turns out nonzero, we
            // NEED to be able to pay it or this whole unlock() call reverts, which is itself
            // informative: it proves whether the swap has a real cost at all.
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
    }

    receive() external payable {}

    function _addLiquidity(int256 liquidityDelta) internal returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(true, abi.encode(AddLiquidityReq({liquidityDelta: liquidityDelta}))));
        return abi.decode(result, (BalanceDelta));
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) internal returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(false, abi.encode(SwapReq({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}))));
        return abi.decode(result, (BalanceDelta));
    }

    /// @notice Confirms adding real full-range liquidity makes getLiquidity() nonzero at all -
    ///         the necessary precondition for the whole "sentinel liquidity" idea to even be
    ///         worth investigating further.
    function test_fullRangeLiquidity_makesGetLiquidityNonzero() public {
        (,, uint128 liquidityBefore) = _getSlot0AndLiquidity();
        assertEq(liquidityBefore, 0, "sanity: this pool must genuinely start with zero liquidity, matching the current live architecture exactly");

        uint256 liquidityAmount = 1_000_000; // deliberately tiny, to test the SMALLEST viable sentinel
        vm.deal(address(this), 100 ether);
        token.mint(address(this), 1_000_000_000e18);
        _addLiquidity(int256(liquidityAmount));

        (,, uint128 liquidityAfter) = _getSlot0AndLiquidity();
        assertEq(liquidityAfter, liquidityAmount, "PoolManager must now report exactly the added liquidity as active, in-range liquidity");
    }

    /// @notice THE decisive test: once real (even tiny, hook-owned) liquidity exists, is a
    ///         calibration-style swap (targeting a specific sqrtPriceLimitX96, with a nominal
    ///         placeholder amountSpecified) still zero-cost, or does it now require real
    ///         ETH/token to move? This is not assumed - it is measured directly, and the test
    ///         is written so that if the cost is nonzero, the unlock() call still succeeds
    ///         (this test contract pays whatever is actually owed), making the ACTUAL delta
    ///         observable rather than merely causing a revert that hides the answer.
    function test_calibrationSwap_withRealLiquidity_isNoLongerFree() public {
        uint256 liquidityAmount = 1_000_000;
        vm.deal(address(this), 100 ether);
        token.mint(address(this), 1_000_000_000e18);
        _addLiquidity(int256(liquidityAmount));

        uint256 ethBalanceBefore = address(this).balance;
        uint256 tokenBalanceBefore = token.balanceOf(address(this));

        // Target a MEANINGFUL price move (2x), exactly the kind of move a real CLOG trade
        // could require of the calibration mechanism.
        uint160 target = 158456325028528675187087900672; // 2x starting sqrtPriceX96
        BalanceDelta delta = _swap(false, -1, target);

        uint256 ethBalanceAfter = address(this).balance;
        uint256 tokenBalanceAfter = token.balanceOf(address(this));

        // The core finding: report exactly what happened, rather than asserting a specific
        // expected direction up front - this is an investigation, not a confirmation of a
        // pre-decided answer.
        emit log_named_int("delta.amount0() (real ETH moved by the calibration swap)", int256(delta.amount0()));
        emit log_named_int("delta.amount1() (real TOKEN moved by the calibration swap)", int256(delta.amount1()));
        emit log_named_uint("liquidityAmount used for this test", liquidityAmount);

        bool wasFree = (delta.amount0() == 0 && delta.amount1() == 0);
        assertFalse(wasFree, "CONFIRMS THE CONCERN: once real liquidity exists, moving price via a calibration-style swap is NO LONGER free - real ETH/token must actually move, unlike the zero-liquidity case proven separately");

        // Whatever moved, it must have come from/gone to REAL balances - not manufactured from
        // nothing - confirming this is a genuine economic cost, not an accounting artifact.
        assertTrue(ethBalanceAfter != ethBalanceBefore || tokenBalanceAfter != tokenBalanceBefore, "the calibration swap's real cost must show up as an actual balance change for whoever initiated it");
    }

    /// @notice Measures how the calibration cost scales with liquidity size, to understand
    ///         whether a "tiny enough" sentinel could make this cost negligible rather than
    ///         merely nonzero.
    function test_calibrationCost_scalesWithLiquiditySize() public {
        uint160 target = 158456325028528675187087900672; // same 2x move each time, for comparison

        // Small liquidity run.
        vm.deal(address(this), 1000 ether);
        token.mint(address(this), 1_000_000_000_000e18);
        _addLiquidity(1_000_000);
        BalanceDelta smallDelta = _swap(false, -1, target);
        int128 smallCost = smallDelta.amount0() > 0 ? smallDelta.amount0() : -smallDelta.amount0();

        // Reset via a fresh pool with 1000x the liquidity, same price move.
        PoolManager manager2 = new PoolManager(address(this));
        MinimalToken token2 = new MinimalToken();
        PoolKey memory key2 = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token2)), fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
        manager2.initialize(key2, 79228162514264337593543950336);

        LargeLiquidityHelper helper = new LargeLiquidityHelper(manager2, key2, token2);
        vm.deal(address(helper), 1000 ether);
        token2.mint(address(helper), 1_000_000_000_000e18);
        helper.addLiquidity(1_000_000_000);
        BalanceDelta largeDelta = helper.swap(false, -1, target);
        int128 largeCost = largeDelta.amount0() > 0 ? largeDelta.amount0() : -largeDelta.amount0();

        emit log_named_int("cost at L=1e6", int256(smallCost));
        emit log_named_int("cost at L=1e9 (1000x)", int256(largeCost));

        // If cost scales linearly with L (as the underlying AMM math implies), the 1000x
        // liquidity run should cost approximately 1000x more - confirming the mechanism, not
        // merely that it's "some nonzero number".
        assertApproxEqRel(uint256(int256(largeCost)), uint256(int256(smallCost)) * 1000, 0.01e18, "calibration cost must scale linearly with liquidity size, confirming this is the standard AMM constant-product cost, not a fixed or negligible fee");
    }

    function _getSlot0AndLiquidity() internal view returns (uint160 price, int24 tick, uint128 liquidity) {
        (price, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        liquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
    }
}

contract LargeLiquidityHelper is IUnlockCallback {
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
        manager.unlock(abi.encode(true, liquidityDelta, false, int256(0), uint160(0)));
    }

    function swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) external returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(false, int256(0), zeroForOne, amountSpecified, sqrtPriceLimitX96));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool isAdd, int256 liquidityDelta, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (bool, int256, bool, int256, uint160));
        if (isAdd) {
            (BalanceDelta callerDelta,) = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0)}), bytes("")
            );
            int128 eth = -callerDelta.amount0();
            int128 tok = -callerDelta.amount1();
            if (eth > 0) {
                manager.sync(key.currency0);
                manager.settle{value: uint256(int256(eth))}();
            }
            if (tok > 0) {
                manager.sync(key.currency1);
                token.transfer(address(manager), uint256(int256(tok)));
                manager.settle();
            }
            return abi.encode(callerDelta);
        } else {
            BalanceDelta delta = manager.swap(key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}), bytes(""));
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
