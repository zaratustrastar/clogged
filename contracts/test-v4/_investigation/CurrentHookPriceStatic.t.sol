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
import {ClogV4Hook} from "../../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";

/// @notice ISOLATED investigation test. Confirms empirically (not merely by source-tracing)
///         that the CURRENT ClogV4Hook.beforeSwap - which returns a BeforeSwapDelta whose
///         specifiedDelta fully equals params.amountSpecified - drives the underlying
///         Pool.swap()'s own amountToSwap to exactly zero, which Pool.sol's own early-return
///         (`if (params.amountSpecified == 0) return ... result unchanged`) leaves
///         slot0.sqrtPriceX96 completely untouched, forever, regardless of trade volume.
contract CurrentHookPriceStaticInvestigation is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    ClogV4Hook hook;
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

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(key, address(market));
        // Initialize at the SAME hardcoded 1:1 the real TickerRegistryV4 currently uses, exactly
        // reproducing the reported bug's own starting condition.
        manager.initialize(key, 79228162514264337593543950336);

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();
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

    function test_realBuy_leavesPoolPriceCompletelyStatic() public {
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint256 curveREBefore = market.re();
        uint256 curveRTBefore = market.rt();

        vm.deal(address(this), 0.05 ether);
        manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(0.05 ether)})));

        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());

        assertGt(market.re(), curveREBefore, "sanity: the CLOG curve's own re must have genuinely moved from this buy");
        assertLt(market.rt(), curveRTBefore, "sanity: the CLOG curve's own rt must have genuinely moved from this buy");
        assertEq(priceAfter, priceBefore, "CONFIRMED BUG: PoolManager's own externally-observable price is COMPLETELY UNCHANGED despite the real CLOG curve having moved substantially - any standard v4 indexer reading slot0 sees a stale, frozen price forever");
    }

    function test_manyBuys_stillLeavesPoolPriceStatic() public {
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        vm.deal(address(this), 1 ether);
        for (uint256 i = 0; i < 5; i++) {
            manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(0.1 ether)})));
        }
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceAfter, priceBefore, "even after FIVE substantial real buys, PoolManager's own reported price never moves at all - not a one-off rounding artifact, a structural property of the current architecture");
    }
}
