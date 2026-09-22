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
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {CalibratingHookV3} from "./CalibratingHookV3.sol";

contract CalibrationFundingTraceTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    CalibratingHookV3 hook;
    ClogMarket market;
    MinimalMockToken token;
    RewardVault rewardVault;
    PoolKey key;

    address constant HOOK_ADDRESS = address(0x2AC8);
    uint256 constant SENTINEL_L = 1e15;
    bool private _depositing;

    bytes32 constant PROBE_TOPIC = keccak256("Probe(uint8,bytes)");
    bytes32 constant CALDELTA_TOPIC = keccak256("CalibrationDelta(int128,int128)");

    function setUp() public {
        manager = new PoolManager(address(this));
        CalibratingHookV3 impl = new CalibratingHookV3(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = CalibratingHookV3(payable(HOOK_ADDRESS));
        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));
        MockTickerNFT nft = new MockTickerNFT();
        nft.setOwner(1, makeAddr("tickerOwner"));
        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(nft), 1, makeAddr("multisig"), 9 ether, 20_000, address(new NoopEligibility()));
        hook.setMarket(address(market));
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        manager.initialize(key, _target());
        token.mint(address(market), 1_000_000_000e18);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;
        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, 0, type(uint256).max);
        vm.stopPrank();
        vm.deal(address(this), 100 ether);
        token.mint(address(this), 10_000_000e18);
        token.approve(address(hook), type(uint256).max);
        hook.fundSentinelAndOperatingFund{value: 10 ether}(key, SENTINEL_L, 1_000_000e18);
    }

    function _target() internal view returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(market.rt(), 1 << 192, market.re())));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (_depositing) {
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), 1_000_000_000e18);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), 1_000_000_000e18);
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
        if (zeroForOne) vm.deal(address(this), address(this).balance + amount);
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amount)), (BalanceDelta));
    }

    struct P {
        uint256 rawEth;
        uint256 rawToken;
        uint256 ledgerEth;
        uint256 ledgerToken;
        int256 td0;
        int256 td1;
        uint256 hc0;
        uint256 hc1;
        uint256 mc0;
        uint256 mc1;
    }

    function _decode(Vm.Log[] memory logs, uint8 stage) internal pure returns (P memory p, bool found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 2 && logs[i].topics[0] == PROBE_TOPIC && uint256(logs[i].topics[1]) == stage) {
                bytes memory inner = abi.decode(logs[i].data, (bytes));
                p = abi.decode(inner, (P));
                return (p, true);
            }
        }
    }

    function _calDelta(Vm.Log[] memory logs) internal pure returns (int128 a0, int128 a1, bool found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 1 && logs[i].topics[0] == CALDELTA_TOPIC) {
                (a0, a1) = abi.decode(logs[i].data, (int128, int128));
                return (a0, a1, true);
            }
        }
    }

    function _log(string memory label, P memory p) internal {
        emit log_string(label);
        emit log_named_uint("   hook raw ETH", p.rawEth);
        emit log_named_uint("   hook raw token", p.rawToken);
        emit log_named_uint("   ledger operatingFundETH", p.ledgerEth);
        emit log_named_uint("   ledger operatingFundToken", p.ledgerToken);
        emit log_named_int("   PM transient delta(hook, ETH)", p.td0);
        emit log_named_int("   PM transient delta(hook, token)", p.td1);
        emit log_named_uint("   hook ERC6909 claim ETH", p.hc0);
        emit log_named_uint("   hook ERC6909 claim token", p.hc1);
        emit log_named_uint("   market ERC6909 claim ETH", p.mc0);
        emit log_named_uint("   market ERC6909 claim token", p.mc1);
    }

    function _traceAndCheck(bool zeroForOne, uint256 amount) internal {
        uint256 rawEth0 = address(hook).balance;
        uint256 rawTok0 = token.balanceOf(address(hook));
        uint256 ledEth0 = hook.operatingFundETH();
        uint256 ledTok0 = hook.operatingFundToken();
        emit log_string(zeroForOne ? "######## BUY TRACE ########" : "######## SELL TRACE ########");
        emit log_named_uint("[0] before outer swap: hook raw ETH", rawEth0);
        emit log_named_uint("[0] before outer swap: hook raw token", rawTok0);
        emit log_named_uint("[0] before outer swap: ledger ETH", ledEth0);
        emit log_named_uint("[0] before outer swap: ledger token", ledTok0);

        vm.recordLogs();
        _swap(zeroForOne, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (P memory p1, bool f1) = _decode(logs, 1);
        (P memory p2, bool f2) = _decode(logs, 2);
        (P memory p3, bool f3) = _decode(logs, 3);
        (P memory p4, bool f4) = _decode(logs, 4);
        (int128 a0, int128 a1, bool fc) = _calDelta(logs);
        assertTrue(f1 && f2 && f3 && f4 && fc, "all probe stages and the calibration delta must be emitted");

        _log("[1] end of outer beforeSwap", p1);
        _log("[2] immediately before nested calibration", p2);
        emit log_named_int("   calibration d.amount0 (ETH)", a0);
        emit log_named_int("   calibration d.amount1 (token)", a1);
        _log("[3] immediately after nested calibration swap (pre-settlement)", p3);
        _log("[4] after calibration settlement", p4);
        emit log_named_uint("[5] after full outer settlement: hook raw ETH", address(hook).balance);
        emit log_named_uint("[5] after full outer settlement: hook raw token", token.balanceOf(address(hook)));

        // 9. The outer beforeSwap transfers NO raw ETH/token to the hook and grants NO claims.
        assertEq(p1.rawEth, rawEth0, "outer beforeSwap must not move raw ETH into the hook");
        assertEq(p1.rawToken, rawTok0, "outer beforeSwap must not move raw token into the hook");
        assertEq(p1.hc0 + p1.hc1 + p2.hc0 + p2.hc1 + p4.hc0 + p4.hc1, 0, "hook must never hold ERC6909 claims");

        // The incidental transient position from the outer swap IS present during calibration -
        // this is the credit that could mask a funding gap if settlement relied on it.
        assertTrue(p2.td0 != 0 && p2.td1 != 0, "outer swap leaves the hook a nonzero transient position during afterSwap");

        // The nested swap changes the hook's transient position by exactly d.
        assertEq(p3.td0 - p2.td0, int256(a0), "nested swap must change transient ETH delta by exactly d.amount0");
        assertEq(p3.td1 - p2.td1, int256(a1), "nested swap must change transient token delta by exactly d.amount1");
        // Settlement returns the transient position to its pre-calibration value - calibration
        // borrowed nothing from the outer swap's credit.
        assertEq(p4.td0, p2.td0, "after settlement, hook's transient ETH delta must equal its pre-calibration value");
        assertEq(p4.td1, p2.td1, "after settlement, hook's transient token delta must equal its pre-calibration value");

        // Ledger moved by exactly d; raw balances moved by exactly d; nothing else.
        assertEq(int256(p4.ledgerEth) - int256(ledEth0), int256(a0), "ledger ETH must move by exactly d.amount0");
        assertEq(int256(p4.ledgerToken) - int256(ledTok0), int256(a1), "ledger token must move by exactly d.amount1");
        assertEq(int256(p4.rawEth) - int256(rawEth0), int256(a0), "raw ETH must move by exactly d.amount0");
        assertEq(int256(p4.rawToken) - int256(rawTok0), int256(a1), "raw token must move by exactly d.amount1");
        assertEq(address(hook).balance, p4.rawEth, "nothing after calibration moves hook raw ETH");
        assertEq(token.balanceOf(address(hook)), p4.rawToken, "nothing after calibration moves hook raw token");

        // Direction/sign: buy => hook spends ETH, receives token; sell => spends token, receives ETH.
        if (zeroForOne) {
            assertLt(a0, 0, "BUY calibration: hook spends ETH (negative = owes PoolManager)");
            assertGt(a1, 0, "BUY calibration: hook receives token");
        } else {
            assertGt(a0, 0, "SELL calibration: hook receives ETH");
            assertLt(a1, 0, "SELL calibration: hook spends token");
        }
        (uint160 px,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(px, _target(), "slot0 equals canonical target");
    }

    function test_trace_buy() public {
        _traceAndCheck(true, 0.05 ether);
    }

    function test_trace_sell() public {
        BalanceDelta b = _swap(true, 0.05 ether);
        _traceAndCheck(false, uint256(int256(b.amount1())) / 2);
    }

    // ── Ledger governs funding, independent of raw balances ─────────────────────────────────

    function _expectedLedgerRevert(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            HOOK_ADDRESS,
            IHooks.afterSwap.selector,
            abi.encodeWithSignature("Error(string)", reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Dry-runs the trade to learn the exact calibration delta, then restores state.
    function _dryRunCalDelta(bool zeroForOne, uint256 amount) internal returns (int128 a0, int128 a1) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _swap(zeroForOne, amount);
        bool found;
        (a0, a1, found) = _calDelta(vm.getRecordedLogs());
        require(found, "no calibration in dry run");
        vm.revertToState(snap);
    }

    function test_buy_ledgerOneWeiShort_revertsDespiteLargeRawBalance() public {
        (int128 a0,) = _dryRunCalDelta(true, 0.05 ether);
        uint256 needed = uint256(int256(-a0));
        hook.reduceOperatingFundForTest(needed - 1, hook.operatingFundToken());
        emit log_named_uint("ETH needed by BUY calibration", needed);
        emit log_named_uint("ledger ETH (set to needed-1)", hook.operatingFundETH());
        emit log_named_uint("hook raw ETH (untouched, far larger)", address(hook).balance);
        assertGt(address(hook).balance, needed * 1000, "raw balance is far above need - only the ledger can cause the revert");

        uint256 reBefore = market.re();
        vm.deal(address(this), address(this).balance + 0.05 ether);
        vm.expectRevert(_expectedLedgerRevert("operating fund ETH insufficient"));
        manager.unlock(abi.encode(true, uint256(0.05 ether)));
        assertEq(market.re(), reBefore, "applyBuy rolled back");
    }

    function test_buy_ledgerExact_succeeds() public {
        (int128 a0,) = _dryRunCalDelta(true, 0.05 ether);
        hook.reduceOperatingFundForTest(uint256(int256(-a0)), hook.operatingFundToken());
        _swap(true, 0.05 ether);
        assertEq(hook.operatingFundETH(), 0, "exactly-sufficient ledger is fully consumed");
    }

    function test_sell_ledgerOneWeiShort_revertsDespiteLargeRawBalance() public {
        BalanceDelta b = _swap(true, 0.05 ether);
        uint256 sellAmt = uint256(int256(b.amount1())) / 2;
        (, int128 a1) = _dryRunCalDelta(false, sellAmt);
        uint256 needed = uint256(int256(-a1));
        hook.reduceOperatingFundForTest(hook.operatingFundETH(), needed - 1);
        emit log_named_uint("token needed by SELL calibration", needed);
        emit log_named_uint("ledger token (set to needed-1)", hook.operatingFundToken());
        emit log_named_uint("hook raw token (untouched, far larger)", token.balanceOf(address(hook)));
        assertGt(token.balanceOf(address(hook)), needed * 1000, "raw balance far above need");

        uint256 reBefore = market.re();
        vm.expectRevert(_expectedLedgerRevert("operating fund token insufficient"));
        manager.unlock(abi.encode(false, sellAmt));
        assertEq(market.re(), reBefore, "applySell rolled back");
    }

    function test_sell_ledgerExact_succeeds() public {
        BalanceDelta b = _swap(true, 0.05 ether);
        uint256 sellAmt = uint256(int256(b.amount1())) / 2;
        (, int128 a1) = _dryRunCalDelta(false, sellAmt);
        hook.reduceOperatingFundForTest(hook.operatingFundETH(), uint256(int256(-a1)));
        _swap(false, sellAmt);
        assertEq(hook.operatingFundToken(), 0, "exactly-sufficient ledger is fully consumed");
    }

    // ── Recursion: which guard actually prevents it ─────────────────────────────────────────

    function test_recursion_preventedByV4SelfCallGuard_notByCalibratingFlag() public {
        uint256 bs0 = hook.beforeSwapCalls();
        uint256 as0 = hook.afterSwapCalls();
        vm.recordLogs();
        _swap(true, 0.05 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == swapTopic) swaps++;
        }
        assertEq(swaps, 2, "exactly one outer + one nested core swap");
        assertEq(hook.nestedCalibrationSwaps(), 1, "exactly one nested calibration swap");
        assertEq(hook.beforeSwapCalls() - bs0, 1, "beforeSwap invoked ONCE (outer only) - nested swap never calls back");
        assertEq(hook.afterSwapCalls() - as0, 1, "afterSwap invoked ONCE (outer only) - nested swap never calls back");
        assertEq(hook.calibratingShortCircuitHits(), 0, "_calibrating short-circuit was never reached: v4's self-call guard is what prevents recursion");
    }
}
