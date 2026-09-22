// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {CalibratingHookV3} from "./CalibratingHookV3.sol";

/// @notice Item A (sell direction) and Item C (recursion safety) for the protocol-funded
///         calibration architecture. Reuses CalibratingHookV3 directly (not a copy) so these
///         tests exercise the exact same contract the buy-direction tests already proved.
contract ProtocolFundedCalibrationSellAndRecursionTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    CalibratingHookV3 hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;

    address constant HOOK_ADDRESS = address(0x2AC8);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 constant SENTINEL_L = 1e15;

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));
        CalibratingHookV3 impl = new CalibratingHookV3(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = CalibratingHookV3(payable(HOOK_ADDRESS));

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

        vm.deal(address(this), 100_000 ether);
        token.mint(address(this), 1_000_000_000_000e18);
        token.approve(address(hook), type(uint256).max);
        hook.fundSentinelAndOperatingFund{value: 10 ether}(key, SENTINEL_L, 1_000_000e18);
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

    function _doBuy(uint256 amount) internal returns (BalanceDelta) {
        vm.deal(address(this), amount);
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(amount)})));
        return abi.decode(result, (BalanceDelta));
    }

    function _doSell(uint256 amount) internal returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: false, amountSpecified: -int256(amount)})));
        return abi.decode(result, (BalanceDelta));
    }

    function _slot0() internal view returns (uint160 price, int24 tick, uint128 liquidity) {
        (price, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        liquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
    }

    function _computeSqrtPrice(uint256 rt, uint256 re) internal pure returns (uint160) {
        uint256 val = Math.mulDiv(rt, 1 << 192, re);
        uint256 s = Math.sqrt(val);
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    // ── ITEM A: SELL DIRECTION, full field-by-field record ──────────────────────────────────
    function test_sellDirection_fullFieldRecord() public {
        BalanceDelta buyDelta = _doBuy(0.05 ether);
        uint256 tokensHeld = uint256(int256(buyDelta.amount1()));
        uint256 sellAmount = tokensHeld / 2;

        uint256 reBefore = market.re();
        uint256 rtBefore = market.rt();
        uint256 soldBefore = market.sold();
        uint256 hwmBefore = market.hwm();
        uint256 clogRemainingBefore = market.clogRemaining();
        uint256 rtCeilingBefore = market.rtCeiling();
        (uint160 slot0Before, int24 tickBefore,) = _slot0();
        uint256 operatingFundTokenBefore = hook.operatingFundToken();
        uint256 hookEthBefore = address(hook).balance;

        emit log_string("=== SELL: PRE-TRADE STATE ===");
        emit log_named_uint("re before", reBefore);
        emit log_named_uint("rt before", rtBefore);
        emit log_named_uint("slot0 before", slot0Before);
        emit log_named_int("tick before", tickBefore);
        emit log_named_uint("operating fund token before", operatingFundTokenBefore);
        emit log_named_uint("hook ETH before", hookEthBefore);

        BalanceDelta sellDelta = _doSell(sellAmount);
        uint256 netEthReceived = uint256(int256(sellDelta.amount0()));

        uint256 reAfter = market.re();
        uint256 rtAfter = market.rt();
        uint160 canonicalTarget = _computeSqrtPrice(rtAfter, reAfter);
        int24 canonicalTargetTick = TickMath.getTickAtSqrtPrice(canonicalTarget);

        (uint160 slot0After, int24 tickAfter,) = _slot0();

        emit log_string("=== SELL: CANONICAL CLOG TARGET ===");
        emit log_named_uint("re after (canonical)", reAfter);
        emit log_named_uint("rt after (canonical)", rtAfter);
        emit log_named_uint("canonical target sqrtPriceX96", canonicalTarget);
        emit log_named_int("canonical target tick", canonicalTargetTick);

        emit log_string("=== SELL: ACTUAL POST-CALIBRATION slot0 ===");
        emit log_named_uint("actual sqrtPriceX96", slot0After);
        emit log_named_int("actual tick", tickAfter);
        assertEq(slot0After, canonicalTarget, "slot0 must land EXACTLY on the canonical CLOG target after a sell");
        assertEq(tickAfter, canonicalTargetTick, "tick must match exactly too");
        assertGt(slot0After, slot0Before, "price (token/ETH) must INCREASE after a sell");

        emit log_string("=== SELL: operating fund composition change ===");
        uint256 operatingFundTokenAfter = hook.operatingFundToken();
        uint256 hookEthAfter = address(hook).balance;
        emit log_named_uint("operating fund token after", operatingFundTokenAfter);
        emit log_named_uint("hook ETH after", hookEthAfter);
        if (hookEthAfter > hookEthBefore) {
            emit log_named_uint("  hook RECEIVED ETH from calibration (wei)", hookEthAfter - hookEthBefore);
        } else if (hookEthAfter < hookEthBefore) {
            emit log_named_uint("  hook SPENT ETH on calibration (wei)", hookEthBefore - hookEthAfter);
        }
        if (operatingFundTokenAfter > operatingFundTokenBefore) {
            emit log_named_uint("  operating fund GAINED token from calibration (wei)", operatingFundTokenAfter - operatingFundTokenBefore);
        } else if (operatingFundTokenAfter < operatingFundTokenBefore) {
            emit log_named_uint("  operating fund SPENT token on calibration (wei)", operatingFundTokenBefore - operatingFundTokenAfter);
        }

        emit log_string("=== SELL: full CLOG accounting fields ===");
        emit log_named_uint("user ETH received (netEthOut)", netEthReceived);
        emit log_named_uint("sold before", soldBefore);
        emit log_named_uint("sold after", market.sold());
        emit log_named_uint("hwm before", hwmBefore);
        emit log_named_uint("hwm after", market.hwm());
        emit log_named_uint("clogRemaining before", clogRemainingBefore);
        emit log_named_uint("clogRemaining after", market.clogRemaining());
        emit log_named_uint("rtCeiling before", rtCeilingBefore);
        emit log_named_uint("rtCeiling after", market.rtCeiling());
        emit log_named_uint("realETH after", market.realETH());
        emit log_named_uint("pendingWithdrawals[tickerOwner]", market.pendingWithdrawals(tickerNFT.ownerOf(1)));
        emit log_named_uint("pendingWithdrawals[multisig]", market.pendingWithdrawals(market.multisig()));

        assertGt(netEthReceived, 0, "seller must receive real ETH");
    }

    // ── ITEM C: RECURSION SAFETY ─────────────────────────────────────────────────────────────
    function test_recursionSafety_exactlyOneNestedCalibrationSwap() public {
        vm.recordLogs();
        _doBuy(0.05 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 swapEventCount = 0;
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == swapTopic) {
                swapEventCount++;
            }
        }
        emit log_named_uint("total v4-core Swap events emitted for one outer buy", swapEventCount);
        assertEq(swapEventCount, 2, "exactly one outer swap + one nested calibration swap - never more, proving no recursive calibration is possible");
    }

    function test_beforeSwapDuringCalibration_neverEmitsClogEvents() public {
        vm.recordLogs();
        _doBuy(0.05 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 boughtTopic = keccak256("Bought(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 boughtCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == boughtTopic) {
                boughtCount++;
            }
        }
        emit log_named_uint("Bought events emitted for one outer buy", boughtCount);
        assertEq(boughtCount, 1, "exactly ONE Bought event - the nested calibration swap must never trigger a second, spurious applyBuy call");
    }
}
