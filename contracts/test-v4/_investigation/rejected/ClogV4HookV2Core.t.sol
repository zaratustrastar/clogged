// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoopEligibility} from "../../mocks/NoopEligibility.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {RejectedResidualHook as ClogV4HookV2} from "./RejectedResidualHook.sol";
import {ClogMarket} from "../../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../../src/RewardVault.sol";

/// @notice Core V2 architecture test suite. Uses vm.etch to place ClogV4HookV2 at an address
///         with the correct flag bits for rapid iteration on the underlying logic - a separate
///         test (V2RealHookDeployment.t.sol) proves the same logic works via genuine CREATE2
///         mining and deployment, matching production reality exactly.
contract ClogV4HookV2CoreTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    ClogV4HookV2 hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;

    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    address sentinelFunder = makeAddr("sentinelFunder");
    uint256 constant TICKER_TOKEN_ID = 1;
    // BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP |
    // AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA = 0x2AC8
    address constant HOOK_ADDRESS = address(0x2AC8);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;
    int24 constant SENTINEL_TICK_LOWER = -887220;
    int24 constant SENTINEL_TICK_UPPER = 887220;
    int256 constant SENTINEL_LIQUIDITY = 1_000_000_000_000_000;

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4HookV2 impl = new ClogV4HookV2(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4HookV2(payable(HOOK_ADDRESS));

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));
        hook.setSentinelFunder(sentinelFunder);

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(key, address(market));

        uint160 correctInitialPrice = _computeExpectedSqrtPrice(market.rt(), market.re());
        manager.initialize(key, correctInitialPrice);

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();

        // Fund the sentinel - the designated funder acquires tokens via mint (standing in for
        // "acquired externally" in this isolated test) and funds the position.
        vm.deal(sentinelFunder, 1000 ether);
        token.mint(sentinelFunder, 1_000_000e18);
        vm.startPrank(sentinelFunder);
        token.approve(address(hook), type(uint256).max);
        hook.fundSentinel{value: 1e12}(key, SENTINEL_LIQUIDITY);
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

    function _doBuy(uint256 amount) internal returns (BalanceDelta) {
        vm.deal(address(this), amount);
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(amount)})));
        return abi.decode(result, (BalanceDelta));
    }

    function _doSell(uint256 amount) internal returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: false, amountSpecified: -int256(amount)})));
        return abi.decode(result, (BalanceDelta));
    }

    function _slot0AndLiquidity() internal view returns (uint160 price, int24 tick, uint128 liquidity) {
        (price, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        liquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
    }

    function _computeExpectedSqrtPrice(uint256 rt, uint256 re) internal pure returns (uint160) {
        uint256 val = Math.mulDiv(rt, 1 << 192, re);
        return uint160(Math.sqrt(val));
    }

    // ── Test 1: initial slot0 represents the intended CLOG starting price, not 1:1 ──────────
    function test_initialSlot0_matchesClogStartingPrice_notOneToOne() public view {
        (uint160 price,, uint128 liquidity) = _slot0AndLiquidity();
        uint160 expected = _computeExpectedSqrtPrice(market.rt(), market.re());
        assertEq(price, expected, "initial slot0 must exactly match sqrt(rt/re)*2^96");
        assertNotEq(price, 79228162514264337593543950336, "initial slot0 must NOT be the old buggy 1:1 Q96 value");
        assertGt(liquidity, 0, "requirement: active liquidity must be nonzero immediately after sentinel funding");
        assertEq(liquidity, uint256(SENTINEL_LIQUIDITY), "active liquidity must exactly equal the funded sentinel amount");
    }

    // ── Test 3: a BUY through the standard v4 path — RESIDUAL DESIGN LIMITATION DOCUMENTED ─
    // This test explicitly proves what the parameter sweep discovered: the residual-user-swap
    // design in ClogV4HookV2 cannot achieve exact slot0 synchronization because it cannot
    // resolve the circular dependency between "compute r to reach target" and "call applyBuy
    // which mutates state". The afterSwap postcondition check correctly catches this and
    // reverts. This test documents that behavior - the protocol-funded design in
    // ProtocolFundedCalibration.t.sol solves this correctly.
    function test_residualDesign_reverts_demonstratingAccountingDeviation() public {
        uint256 reBefore = market.re();

        uint256 buyAmount = 0.05 ether;
        vm.deal(address(this), buyAmount);
        // The residual design reverts in afterSwap because slot0 doesn't reach the exact target.
        vm.expectRevert();
        manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(buyAmount)})));

        // The whole transaction rolled back — re must be unchanged.
        assertEq(market.re(), reBefore, "full rollback: applyBuy state changes must be reverted when afterSwap postcondition fails");
    }
}
