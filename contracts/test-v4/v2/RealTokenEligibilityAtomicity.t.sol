// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {EligibilityRegistry} from "../../src/EligibilityRegistry.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {CalibratingHookV3} from "./CalibratingHookV3.sol";

/// @notice D1. REAL MemeToken (TWAB checkpoints) + REAL EligibilityRegistry, driven through the
///         calibrating hook. Proves the restored ClogMarket -> EligibilityRegistry.onTrade path
///         on BUY and SELL, and that a reverted outer swap (insufficient calibration ledger)
///         leaves token balances, checkpoints, and every eligibility field untouched.
contract RealTokenEligibilityAtomicityTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    CalibratingHookV3 hook;
    ClogMarket market;
    MemeToken token;
    EligibilityRegistry registry;
    RewardVault rewardVault;
    PoolKey key;
    uint256 tokenId;

    address constant HOOK_ADDRESS = address(0x2AC8);
    uint256 constant SENTINEL_L = 1e15;
    uint256 constant MIN_PROGRESS_BPS = 4;
    uint256 constant MIN_RESERVE = 0.03 ether;
    uint256 constant REQUIRED_SECONDS = 600;
    uint256 constant CURVE_ALLOCATION = 900_000_000e18;

    bool private _depositing;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        CalibratingHookV3 impl = new CalibratingHookV3(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = CalibratingHookV3(payable(HOOK_ADDRESS));
        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        registry = new EligibilityRegistry(address(this), MIN_PROGRESS_BPS, MIN_RESERVE, REQUIRED_SECONDS);
        MockTickerNFT nft = new MockTickerNFT();
        token = new MemeToken("CANARY", "CANARY", address(this));
        tokenId = registry.nextTokenId();
        nft.setOwner(tokenId, makeAddr("tickerOwner"));
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(nft), tokenId, makeAddr("multisig"), 9 ether, 20_000, address(registry));
        token.setMarket(address(market)); // real mint of the full fixed 1B supply to the market
        assertEq(registry.registerToken(address(market)), tokenId, "tokenId association");
        hook.setMarket(address(market));

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        manager.initialize(key, _target());

        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;
        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, 0, type(uint256).max);
        vm.stopPrank();

        // Protocol bootstrap: buy sentinel + operating-fund tokens THROUGH the taxed CLOG curve
        // (supply is fixed; there is nothing to mint). At L = 0 calibration moves slot0 for free.
        vm.deal(address(this), 100 ether);
        _swap(true, 0.01 ether);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0, "bootstrap ran with zero liquidity");
        token.approve(address(hook), type(uint256).max);
        hook.fundSentinelAndOperatingFund{value: 1 ether}(key, SENTINEL_L, 1_000e18);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), SENTINEL_L, "sentinel installed");
        assertLt(market.realETH(), MIN_RESERVE, "bootstrap alone stays below the reserve threshold");
    }

    function _target() internal view returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(market.rt(), 1 << 192, market.re())));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (_depositing) {
            uint256 supply = token.TOTAL_SUPPLY();
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), supply);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), supply);
            return bytes("");
        }
        (bool zeroForOne, uint256 amount) = abi.decode(data, (bool, uint256));
        BalanceDelta d = manager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            bytes("")
        );
        if (zeroForOne) {
            manager.sync(key.currency0);
            manager.settle{value: uint256(int256(-d.amount0()))}();
            manager.take(key.currency1, address(this), uint256(int256(d.amount1())));
        } else {
            manager.sync(key.currency1);
            token.transfer(address(manager), uint256(int256(-d.amount1())));
            manager.settle();
            manager.take(key.currency0, address(this), uint256(int256(d.amount0())));
        }
        return abi.encode(d);
    }

    receive() external payable {}

    function _swap(bool zeroForOne, uint256 amount) internal returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amount)), (BalanceDelta));
    }

    // ── Successful-trade eligibility / TWAB effects ─────────────────────────────────────────

    function _assertEligibilityInputs() internal view {
        assertEq(market.realReserve(), market.realETH(), "realReserve() == realETH, exactly as production");
        assertEq(market.progressBps(), Math.mulDiv(market.sold(), 10_000, CURVE_ALLOCATION), "progressBps() exactly as production");
        assertEq(registry.tokenMarket(tokenId), address(market), "registry maps tokenId -> market");
        assertEq(market.tickerTokenId(), tokenId, "market carries the same tokenId");
    }

    function test_buy_realTokenTransfer_twab_eligibilityStreak_thenQualifies() public {
        uint256 cpUser0 = token.checkpointCount(address(this));
        uint256 cpPm0 = token.checkpointCount(address(manager));
        uint256 bal0 = token.balanceOf(address(this));
        assertEq(registry.aboveThresholdSince(tokenId), 0, "no streak before the qualifying buy");

        vm.warp(vm.getBlockTimestamp() + 10);
        BalanceDelta d = _swap(true, 0.05 ether);

        assertEq(token.balanceOf(address(this)) - bal0, uint256(int256(d.amount1())), "real MemeToken transfer == swap output");
        assertEq(token.checkpointCount(address(this)), cpUser0 + 1, "buyer TWAB checkpoint written");
        assertEq(token.checkpointCount(address(manager)), cpPm0 + 1, "PoolManager TWAB checkpoint written");
        assertGe(market.realETH(), MIN_RESERVE, "buy lifts real reserve above threshold");
        assertEq(registry.aboveThresholdSince(tokenId), vm.getBlockTimestamp(), "onTrade started the streak in the SAME tx");
        assertFalse(registry.isCandidate(registry.currentRoundId(), tokenId), "not yet qualified: streak too short");
        _assertEligibilityInputs();

        vm.warp(vm.getBlockTimestamp() + REQUIRED_SECONDS);
        vm.recordLogs();
        _swap(true, 0.001 ether);
        assertTrue(registry.isCandidate(registry.currentRoundId(), tokenId), "a later trade qualifies the token via onTrade");
        assertEq(registry.candidateCount(registry.currentRoundId()), 1, "exactly one candidate entry");
        _assertEligibilityInputs();
    }

    function test_sell_realTokenTransfer_twab_belowThresholdResetsStreak() public {
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 held = token.balanceOf(address(this));
        BalanceDelta b = _swap(true, 0.05 ether);
        uint256 bought = uint256(int256(b.amount1()));
        assertGt(registry.aboveThresholdSince(tokenId), 0, "streak active after buy");

        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 cpUser0 = token.checkpointCount(address(this));
        uint256 ethBefore = address(this).balance;
        BalanceDelta s = _swap(false, bought);

        assertEq(held + bought - token.balanceOf(address(this)), bought, "real MemeToken leaves the seller");
        assertEq(address(this).balance - ethBefore, uint256(int256(s.amount0())), "seller receives exactly netEthOut");
        assertEq(token.checkpointCount(address(this)), cpUser0 + 1, "seller TWAB checkpoint written");
        assertLt(market.realETH(), MIN_RESERVE, "sell drops real reserve below threshold");
        assertEq(registry.aboveThresholdSince(tokenId), 0, "onTrade reset the streak in the SAME tx (the case production refuses to swallow)");
        _assertEligibilityInputs();
    }

    // ── Atomic rollback incl. MemeToken / TWAB / EligibilityRegistry ────────────────────────

    struct Snap {
        uint256 balUser;
        uint256 balPm;
        uint256 balHook;
        uint256 balMarket;
        uint256 cpUser;
        uint256 cpPm;
        uint256 cpHook;
        uint256 cumUser;
        uint256 cumPm;
        uint256 cumHook;
        uint256 streakSince;
        uint256 candCount;
        bool isCand;
        uint256 nextId;
        uint256 realETH;
        uint256 sold;
        uint256 re;
        uint256 rt;
        uint256 ledgerEth;
        uint256 ledgerTok;
        uint160 px;
        uint256 userEth;
    }

    function _snap() internal view returns (Snap memory s) {
        s.balUser = token.balanceOf(address(this));
        s.balPm = token.balanceOf(address(manager));
        s.balHook = token.balanceOf(address(hook));
        s.balMarket = token.balanceOf(address(market));
        s.cpUser = token.checkpointCount(address(this));
        s.cpPm = token.checkpointCount(address(manager));
        s.cpHook = token.checkpointCount(address(hook));
        s.cumUser = token.cumulativeAt(address(this), vm.getBlockTimestamp());
        s.cumPm = token.cumulativeAt(address(manager), vm.getBlockTimestamp());
        s.cumHook = token.cumulativeAt(address(hook), vm.getBlockTimestamp());
        s.streakSince = registry.aboveThresholdSince(tokenId);
        s.candCount = registry.candidateCount(registry.currentRoundId());
        s.isCand = registry.isCandidate(registry.currentRoundId(), tokenId);
        s.nextId = registry.nextTokenId();
        s.realETH = market.realETH();
        s.sold = market.sold();
        s.re = market.re();
        s.rt = market.rt();
        s.ledgerEth = hook.operatingFundETH();
        s.ledgerTok = hook.operatingFundToken();
        (s.px,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        s.userEth = address(this).balance;
    }

    function _eq(Snap memory a, Snap memory b) internal pure {
        assertEq(a.balUser, b.balUser, "MemeToken user balance");
        assertEq(a.balPm, b.balPm, "MemeToken PoolManager balance");
        assertEq(a.balHook, b.balHook, "MemeToken hook balance");
        assertEq(a.balMarket, b.balMarket, "MemeToken market balance");
        assertEq(a.cpUser, b.cpUser, "user checkpoint count");
        assertEq(a.cpPm, b.cpPm, "PoolManager checkpoint count");
        assertEq(a.cpHook, b.cpHook, "hook checkpoint count");
        assertEq(a.cumUser, b.cumUser, "user TWAB cumulative");
        assertEq(a.cumPm, b.cumPm, "PoolManager TWAB cumulative");
        assertEq(a.cumHook, b.cumHook, "hook TWAB cumulative");
        assertEq(a.streakSince, b.streakSince, "aboveThresholdSince (qualification timestamp)");
        assertEq(a.candCount, b.candCount, "round candidate count");
        assertEq(a.isCand, b.isCand, "candidate membership");
        assertEq(a.nextId, b.nextId, "registry nextTokenId");
        assertEq(a.realETH, b.realETH, "realETH");
        assertEq(a.sold, b.sold, "sold");
        assertEq(a.re, b.re, "re");
        assertEq(a.rt, b.rt, "rt");
        assertEq(a.ledgerEth, b.ledgerEth, "ledger ETH");
        assertEq(a.ledgerTok, b.ledgerTok, "ledger token");
        assertEq(a.px, b.px, "slot0");
        assertEq(a.userEth, b.userEth, "user ETH");
    }

    bytes32 constant CALDELTA_TOPIC = keccak256("CalibrationDelta(int128,int128)");

    function _dryRun(bool zeroForOne, uint256 amount) internal returns (int128 a0, int128 a1, Snap memory wouldBe) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _swap(zeroForOne, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 1 && logs[i].topics[0] == CALDELTA_TOPIC) (a0, a1) = abi.decode(logs[i].data, (int128, int128));
        }
        wouldBe = _snap();
        vm.revertToState(snap);
    }

    function _wrapped(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, HOOK_ADDRESS, IHooks.afterSwap.selector,
            abi.encodeWithSignature("Error(string)", reason), abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice The failed BUY would have QUALIFIED the token (dry run proves it) - rollback
    ///         must undo candidate membership, checkpoints, balances and all CLOG state.
    function test_buyFailure_rollsBackTokenTwabAndEligibility() public {
        vm.warp(vm.getBlockTimestamp() + 10);
        _swap(true, 0.05 ether); // start streak
        vm.warp(vm.getBlockTimestamp() + REQUIRED_SECONDS);

        (int128 a0,, Snap memory wouldBe) = _dryRun(true, 0.01 ether);
        assertTrue(wouldBe.isCand, "dry run: this buy WOULD qualify the token");
        assertGt(wouldBe.cpUser, token.checkpointCount(address(this)) - 0, "dry run: WOULD write a user checkpoint");

        hook.reduceOperatingFundForTest(uint256(int256(-a0)) - 1, hook.operatingFundToken());
        Snap memory before = _snap();
        vm.expectRevert(_wrapped("operating fund ETH insufficient"));
        manager.unlock(abi.encode(true, uint256(0.01 ether)));
        _eq(before, _snap());
        assertFalse(registry.isCandidate(registry.currentRoundId(), tokenId), "qualification did NOT survive the revert");
    }

    /// @notice The failed SELL would have BROKEN the streak (dry run proves it) - rollback must
    ///         leave aboveThresholdSince at its pre-trade nonzero value.
    function test_sellFailure_rollsBackTokenTwabAndEligibility() public {
        vm.warp(vm.getBlockTimestamp() + 10);
        BalanceDelta b = _swap(true, 0.05 ether);
        uint256 bought = uint256(int256(b.amount1()));
        vm.warp(vm.getBlockTimestamp() + 10);

        (, int128 a1, Snap memory wouldBe) = _dryRun(false, bought);
        assertEq(wouldBe.streakSince, 0, "dry run: this sell WOULD reset the streak");

        hook.reduceOperatingFundForTest(hook.operatingFundETH(), uint256(int256(-a1)) - 1);
        Snap memory before = _snap();
        assertGt(before.streakSince, 0, "streak is live before the failed sell");
        vm.expectRevert(_wrapped("operating fund token insufficient"));
        manager.unlock(abi.encode(false, bought));
        _eq(before, _snap());
    }
}
