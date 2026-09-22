// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
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

/// @notice Item B: proves that when the operating fund cannot cover a calibration, the ENTIRE
///         outer transaction reverts, leaving every single piece of state - user balances,
///         hook balances, market claims, all ClogMarket fields, slot0, and sentinel liquidity -
///         bit-for-bit unchanged. Snapshots every field explicitly before/after rather than
///         inferring atomicity from a single revert.
contract BidirectionalFundFailureTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    CalibratingHookV3 hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;
    address tickerOwnerAddr;
    address multisigAddr;

    address constant HOOK_ADDRESS = address(0x2AC8);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 constant SENTINEL_L = 1e15;

    bool private _depositing;

    struct FullSnapshot {
        uint256 userEth;
        uint256 userToken;
        uint256 hookEth;
        uint256 hookOperatingFundToken;
        uint256 hookOperatingFundETH;
        uint256 hookRawToken;
        uint256 marketEthClaim;
        uint256 marketTokenClaim;
        uint256 realETH;
        uint256 sold;
        uint256 hwm;
        uint256 clogRemaining;
        uint256 rtCeiling;
        uint256 re;
        uint256 rt;
        uint256 pendingOwner;
        uint256 pendingMultisig;
        uint256 rewardVaultPool;
        uint160 slot0Price;
        int24 slot0Tick;
        uint128 sentinelLiquidity;
    }

    function setUp() public {
        manager = new PoolManager(address(this));
        CalibratingHookV3 impl = new CalibratingHookV3(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = CalibratingHookV3(payable(HOOK_ADDRESS));

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerOwnerAddr = makeAddr("tickerOwner");
        tickerNFT.setOwner(1, tickerOwnerAddr);
        multisigAddr = makeAddr("multisig");

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), 1, multisigAddr, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));
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
        // Fund sentinel LP only - operating fund starts at a MINIMAL amount we control per test.
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

    function _computeSqrtPrice(uint256 rt, uint256 re) internal pure returns (uint160) {
        uint256 val = Math.mulDiv(rt, 1 << 192, re);
        uint256 s = Math.sqrt(val);
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    function _snapshot() internal view returns (FullSnapshot memory s) {
        s.userEth = address(this).balance;
        s.userToken = token.balanceOf(address(this));
        s.hookEth = address(hook).balance;
        s.hookOperatingFundToken = hook.operatingFundToken();
        s.hookOperatingFundETH = hook.operatingFundETH();
        s.hookRawToken = token.balanceOf(address(hook));
        s.marketEthClaim = manager.balanceOf(address(market), uint256(uint160(address(0))));
        s.marketTokenClaim = manager.balanceOf(address(market), uint256(uint160(address(token))));
        s.realETH = market.realETH();
        s.sold = market.sold();
        s.hwm = market.hwm();
        s.clogRemaining = market.clogRemaining();
        s.rtCeiling = market.rtCeiling();
        s.re = market.re();
        s.rt = market.rt();
        s.pendingOwner = market.pendingWithdrawals(tickerOwnerAddr);
        s.pendingMultisig = market.pendingWithdrawals(multisigAddr);
        s.rewardVaultPool = rewardVault.unallocatedPool();
        (s.slot0Price, s.slot0Tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        s.sentinelLiquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
    }

    function _assertIdentical(FullSnapshot memory a, FullSnapshot memory b, string memory label) internal pure {
        assertEq(a.userEth, b.userEth, string.concat(label, ": userEth must be unchanged"));
        assertEq(a.userToken, b.userToken, string.concat(label, ": userToken must be unchanged"));
        assertEq(a.hookEth, b.hookEth, string.concat(label, ": hookEth must be unchanged"));
        assertEq(a.hookOperatingFundToken, b.hookOperatingFundToken, string.concat(label, ": operatingFundToken must be unchanged"));
        assertEq(a.hookOperatingFundETH, b.hookOperatingFundETH, string.concat(label, ": operatingFundETH must be unchanged"));
        assertEq(a.hookRawToken, b.hookRawToken, string.concat(label, ": hook raw token must be unchanged"));
        assertEq(a.marketEthClaim, b.marketEthClaim, string.concat(label, ": marketEthClaim must be unchanged"));
        assertEq(a.marketTokenClaim, b.marketTokenClaim, string.concat(label, ": marketTokenClaim must be unchanged"));
        assertEq(a.realETH, b.realETH, string.concat(label, ": realETH must be unchanged"));
        assertEq(a.sold, b.sold, string.concat(label, ": sold must be unchanged"));
        assertEq(a.hwm, b.hwm, string.concat(label, ": hwm must be unchanged"));
        assertEq(a.clogRemaining, b.clogRemaining, string.concat(label, ": clogRemaining must be unchanged"));
        assertEq(a.rtCeiling, b.rtCeiling, string.concat(label, ": rtCeiling must be unchanged"));
        assertEq(a.re, b.re, string.concat(label, ": re must be unchanged"));
        assertEq(a.rt, b.rt, string.concat(label, ": rt must be unchanged"));
        assertEq(a.pendingOwner, b.pendingOwner, string.concat(label, ": ticker-owner pending credit must be unchanged"));
        assertEq(a.pendingMultisig, b.pendingMultisig, string.concat(label, ": multisig pending credit must be unchanged"));
        assertEq(a.rewardVaultPool, b.rewardVaultPool, string.concat(label, ": WinnerPot/RewardVault pool must be unchanged"));
        assertEq(a.slot0Price, b.slot0Price, string.concat(label, ": slot0 price must be unchanged"));
        assertEq(a.slot0Tick, b.slot0Tick, string.concat(label, ": slot0 tick must be unchanged"));
        assertEq(a.sentinelLiquidity, b.sentinelLiquidity, string.concat(label, ": sentinel active liquidity must be unchanged"));
    }

    bytes32 constant CALDELTA_TOPIC = keccak256("CalibrationDelta(int128,int128)");

    function _dryRunCalDelta(bool zeroForOne, uint256 amount) internal returns (int128 a0, int128 a1) {
        uint256 snap = vm.snapshotState();
        if (zeroForOne) vm.deal(address(this), address(this).balance + amount);
        vm.recordLogs();
        manager.unlock(abi.encode(SwapRequest({zeroForOne: zeroForOne, amountSpecified: -int256(amount)})));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 1 && logs[i].topics[0] == CALDELTA_TOPIC) {
                (a0, a1) = abi.decode(logs[i].data, (int128, int128));
                found = true;
            }
        }
        require(found, "no calibration in dry run");
        vm.revertToState(snap);
    }

    function _wrapped(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, HOOK_ADDRESS, IHooks.afterSwap.selector,
            abi.encodeWithSignature("Error(string)", reason), abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice BUY calibration spends ETH (d.amount0 < 0). Ledger ETH is set to exactly one wei
    ///         below the dry-run requirement while raw ETH stays ~10 ETH. The user is funded
    ///         BEFORE the snapshot so the comparison sees only effects of the failed trade.
    function test_buyCalibrationFailure_atomicRollback_fullFieldComparison() public {
        (int128 a0,) = _dryRunCalDelta(true, 0.05 ether);
        hook.reduceOperatingFundForTest(uint256(int256(-a0)) - 1, hook.operatingFundToken());
        vm.deal(address(this), address(this).balance + 0.05 ether);

        FullSnapshot memory before = _snapshot();
        vm.expectRevert(_wrapped("operating fund ETH insufficient"));
        manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(0.05 ether)})));
        _assertIdentical(before, _snapshot(), "BUY failure");
    }

    /// @notice SELL calibration spends token (d.amount1 < 0). Ledger token set one wei short.
    function test_sellCalibrationFailure_atomicRollback_fullFieldComparison() public {
        vm.deal(address(this), address(this).balance + 0.05 ether);
        bytes memory buyResult = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(0.05 ether)})));
        uint256 sellAmount = uint256(int256(abi.decode(buyResult, (BalanceDelta)).amount1())) / 2;

        (, int128 a1) = _dryRunCalDelta(false, sellAmount);
        hook.reduceOperatingFundForTest(hook.operatingFundETH(), uint256(int256(-a1)) - 1);

        FullSnapshot memory before = _snapshot();
        vm.expectRevert(_wrapped("operating fund token insufficient"));
        manager.unlock(abi.encode(SwapRequest({zeroForOne: false, amountSpecified: -int256(sellAmount)})));
        _assertIdentical(before, _snapshot(), "SELL failure");
    }

    /// @notice Explains the earlier false "BUY succeeded after vm.deal(hook, 0)" observation:
    ///         the old test snapshotted user ETH, THEN called vm.deal(user, 0.05 ether), which
    ///         SETS (not adds) the balance - so the userEth mismatch came from the test's own
    ///         cheatcode, while vm.expectRevert had in fact been satisfied (the call reverted).
    function test_explainPriorArtifact_vmDealSetsBalance() public {
        uint256 big = address(this).balance;
        assertGt(big, 0.05 ether);
        vm.deal(address(this), 0.05 ether);
        assertEq(address(this).balance, 0.05 ether, "vm.deal overwrites; it does not add");
    }
}
