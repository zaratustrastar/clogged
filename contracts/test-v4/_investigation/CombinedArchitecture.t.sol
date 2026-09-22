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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {MockCalibratingHook} from "./MockCalibratingHook.sol";

/// @notice ISOLATED investigation. Full combined architecture: sentinel (hook-owned) full-range
///         liquidity installed into the REAL CLOG pool, then a normal CLOG buy/sell executed
///         through a hook that delegates to the REAL, UNMODIFIED ClogMarket for genuine
///         accounting (MockCalibratingHook - see its own docs for why this is a test-only
///         fixture, not a production change), with LP-position balance snapshots at every
///         stage, then a calibration attempt (funded from the market's own claim, as a
///         mechanical stand-in - not yet a committed production design) with the resulting
///         delta and LP effect measured directly.
contract CombinedArchitectureInvestigation is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    MockCalibratingHook hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;

    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    uint256 constant TICKER_TOKEN_ID = 1;
    address constant HOOK_ADDRESS = address(0x2088);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;
    int256 constant SENTINEL_LIQUIDITY = 1_000;
    uint256 constant CORRECT_INITIAL_SQRT_PRICE = 1120455419495722798374638764549163;

    bool private _depositing;
    bool private _addingSentinel;

    function setUp() public {
        manager = new PoolManager(address(this));
        MockCalibratingHook impl = new MockCalibratingHook(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = MockCalibratingHook(payable(HOOK_ADDRESS));

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));
        hook.setMarket(address(market));

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        // NOTE: this fixture's own mock hook has no registerMarket/access-control machinery at
        // all (that machinery is unrelated to what this investigation measures) - it always
        // delegates to whatever `market` was set via setMarket above, for any pool that uses it.
        manager.initialize(key, uint160(CORRECT_INITIAL_SQRT_PRICE));

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();

        vm.deal(address(this), 1000 ether);
        token.mint(address(this), 1_000_000_000_000e18);
        _addingSentinel = true;
        manager.unlock(bytes(""));
        _addingSentinel = false;

        (,, uint128 liq) = _slot0AndLiquidity();
        assertGt(liq, 0, "sanity: sentinel liquidity must register as nonzero before the real investigation proceeds");
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

        if (_addingSentinel) {
            (BalanceDelta callerDelta,) = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: SENTINEL_LIQUIDITY, salt: bytes32(0)}), bytes("")
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
        }


        SwapRequest memory req = abi.decode(data, (SwapRequest));
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
            manager.take(key.currency1, address(this), uint256(int256(tokenOwed)));
        } else {
            int128 tokenOwed = -swapDelta.amount1();
            manager.sync(key.currency1);
            token.transfer(address(manager), uint256(int256(tokenOwed)));
            manager.settle();
            int128 ethOwed = swapDelta.amount0();
            manager.take(key.currency0, address(this), uint256(int256(ethOwed)));
        }
        return abi.encode(swapDelta);
    }

    receive() external payable {}

    function _slot0AndLiquidity() internal view returns (uint160 price, int24 tick, uint128 liquidity) {
        (price, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        liquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
    }

    /// @dev The LP position's own REAL, redeemable reserves at the current price - computed via
    ///      the same SqrtPriceMath formulas PoolManager itself uses, so "LP balances" here means
    ///      what the sentinel position could actually withdraw right now, not a proxy metric.
    function _sentinelPrincipal() internal view returns (uint256 ethSide, uint256 tokenSide) {
        (uint160 currentSqrtPriceX96,,) = _slot0AndLiquidity();
        uint160 sqrtLower = _getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = _getSqrtPriceAtTick(TICK_UPPER);
        uint128 liquidity = uint128(uint256(SENTINEL_LIQUIDITY));
        ethSide = _getAmount0Delta(currentSqrtPriceX96 < sqrtUpper ? currentSqrtPriceX96 : sqrtUpper, sqrtUpper, liquidity);
        tokenSide = _getAmount1Delta(sqrtLower, currentSqrtPriceX96 > sqrtLower ? currentSqrtPriceX96 : sqrtLower, liquidity);
    }

    function _getSqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function _getAmount0Delta(uint160 a, uint160 b, uint128 l) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(a, b, l, false);
    }

    function _getAmount1Delta(uint160 a, uint160 b, uint128 l) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(a, b, l, false);
    }

    function _doBuy(uint256 amount) internal returns (BalanceDelta) {
        vm.deal(address(this), amount);
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(amount)})));
        return abi.decode(result, (BalanceDelta));
    }

    function _doSell(uint256 amount) internal returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: false, amountSpecified: -int256(amount)})));
        return abi.decode(result, (BalanceDelta));
    }

    function _calibrate(bool zeroForOne, uint160 targetSqrtPriceX96) internal returns (BalanceDelta) {
        return hook.triggerCalibration(key, zeroForOne, targetSqrtPriceX96);
    }

    function _computeTargetSqrtPriceX96() internal view returns (uint256) {
        uint256 rt = market.rt();
        uint256 re = market.re();
        uint256 val = Math.mulDiv(rt, 1 << 192, re);
        return Math.sqrt(val);
    }

    function test_combinedArchitecture_buy() public {
        (uint256 ethBefore, uint256 tokenBefore) = _sentinelPrincipal();
        emit log_string("=== BUY: LP principal BEFORE the CLOG buy ===");
        emit log_named_uint("  LP ETH side (wei)", ethBefore);
        emit log_named_uint("  LP TOKEN side (wei)", tokenBefore);

        uint256 buyAmount = 0.05 ether;
        BalanceDelta buyDelta = _doBuy(buyAmount);
        uint256 tokensOut = uint256(int256(buyDelta.amount1()));
        assertGt(tokensOut, 0, "sanity: the buy must deliver real tokens");

        (uint256 ethAfterBuy, uint256 tokenAfterBuy) = _sentinelPrincipal();
        emit log_string("=== BUY: LP principal AFTER the CLOG buy, BEFORE calibration ===");
        emit log_named_uint("  LP ETH side (wei)", ethAfterBuy);
        emit log_named_uint("  LP TOKEN side (wei)", tokenAfterBuy);

        bool buyChangedPrincipal = (ethAfterBuy != ethBefore) || (tokenAfterBuy != tokenBefore);
        emit log_named_string("  Did the CLOG buy change LP principal by even 1 wei?", buyChangedPrincipal ? "YES" : "NO");
        assertFalse(buyChangedPrincipal, "the real CLOG buy itself must not move the sentinel LP's own principal by even 1 wei - it is fully absorbed by BeforeSwapDelta");

        (uint160 priceAfterBuy,,) = _slot0AndLiquidity();
        uint256 target = _computeTargetSqrtPriceX96();
        bool up = target > priceAfterBuy;
        BalanceDelta calDelta = _calibrate(!up, uint160(target));

        emit log_string("=== BUY: calibration BalanceDelta ===");
        emit log_named_int("  amount0 (real ETH)", int256(calDelta.amount0()));
        emit log_named_int("  amount1 (real TOKEN)", int256(calDelta.amount1()));

        (uint256 ethAfterCal, uint256 tokenAfterCal) = _sentinelPrincipal();
        emit log_string("=== BUY: LP principal AFTER calibration ===");
        emit log_named_uint("  LP ETH side (wei)", ethAfterCal);
        emit log_named_uint("  LP TOKEN side (wei)", tokenAfterCal);

        bool calibrationChangedPrincipal = (ethAfterCal != ethAfterBuy) || (tokenAfterCal != tokenAfterBuy);
        emit log_named_string("  Did calibration change LP principal?", calibrationChangedPrincipal ? "YES" : "NO");
        assertTrue(calibrationChangedPrincipal, "calibration's own real cost must show up as an actual change in the sentinel LP's own principal - confirming the cost passes THROUGH the sentinel LP itself, not around it");

        (uint160 priceAfterCalibration,,) = _slot0AndLiquidity();
        assertEq(priceAfterCalibration, target, "slot0 must land exactly on the CLOG curve's new marginal price");
    }

    function test_combinedArchitecture_sell() public {
        BalanceDelta buyDelta = _doBuy(0.05 ether);
        uint256 tokensHeld = uint256(int256(buyDelta.amount1()));
        uint256 sellAmount = tokensHeld / 2;

        (uint256 ethBefore, uint256 tokenBefore) = _sentinelPrincipal();
        emit log_string("=== SELL: LP principal BEFORE the CLOG sell ===");
        emit log_named_uint("  LP ETH side (wei)", ethBefore);
        emit log_named_uint("  LP TOKEN side (wei)", tokenBefore);

        BalanceDelta sellDelta = _doSell(sellAmount);
        uint256 netEthOut = uint256(int256(sellDelta.amount0()));
        assertGt(netEthOut, 0, "sanity: the sell must deliver real ETH");

        (uint256 ethAfterSell, uint256 tokenAfterSell) = _sentinelPrincipal();
        emit log_string("=== SELL: LP principal AFTER the CLOG sell, BEFORE calibration ===");
        emit log_named_uint("  LP ETH side (wei)", ethAfterSell);
        emit log_named_uint("  LP TOKEN side (wei)", tokenAfterSell);

        bool sellChangedPrincipal = (ethAfterSell != ethBefore) || (tokenAfterSell != tokenBefore);
        emit log_named_string("  Did the CLOG sell change LP principal by even 1 wei?", sellChangedPrincipal ? "YES" : "NO");
        assertFalse(sellChangedPrincipal, "the real CLOG sell itself must not move the sentinel LP's own principal by even 1 wei");

        (uint160 priceAfterSell,,) = _slot0AndLiquidity();
        uint256 target = _computeTargetSqrtPriceX96();
        bool up = target > priceAfterSell;
        BalanceDelta calDelta = _calibrate(!up, uint160(target));

        emit log_string("=== SELL: calibration BalanceDelta ===");
        emit log_named_int("  amount0 (real ETH)", int256(calDelta.amount0()));
        emit log_named_int("  amount1 (real TOKEN)", int256(calDelta.amount1()));

        (uint256 ethAfterCal, uint256 tokenAfterCal) = _sentinelPrincipal();
        emit log_string("=== SELL: LP principal AFTER calibration ===");
        emit log_named_uint("  LP ETH side (wei)", ethAfterCal);
        emit log_named_uint("  LP TOKEN side (wei)", tokenAfterCal);

        bool calibrationChangedPrincipal = (ethAfterCal != ethAfterSell) || (tokenAfterCal != tokenAfterSell);
        emit log_named_string("  Did calibration change LP principal?", calibrationChangedPrincipal ? "YES" : "NO");
        assertTrue(calibrationChangedPrincipal, "calibration's own cost must pass through the sentinel LP for a sell too");

        (uint160 priceAfterCalibration,,) = _slot0AndLiquidity();
        assertEq(priceAfterCalibration, target, "slot0 must land exactly on the CLOG curve's new marginal price after a sell too");
    }
}
