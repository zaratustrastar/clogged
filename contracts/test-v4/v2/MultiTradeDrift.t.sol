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
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {CalibratingHookV3} from "./CalibratingHookV3.sol";

/// @notice D2. Every outer transaction is checked against:
///         (a) a CANONICAL reference ClogMarket driven directly by this test as its own hook
///             (same code, same inputs, no v4 at all) - every economic field and the trade
///             output must match exactly;
///         (b) slot0 == sqrt(rt/re)*2^96 and tick == getTickAtSqrtPrice(slot0);
///         (c) ledger movement == calibration BalanceDelta; raw balance >= ledger;
///         (d) hook transient deltas restored (probe stage 4 == stage 2);
///         (e) market ERC6909 conservation: ETH claim == realETH + owner + multisig credits,
///             token claim == physicalInventory.
contract MultiTradeDriftTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    CalibratingHookV3 hook;
    ClogMarket market;
    ClogMarket refMarket;
    MemeToken token;
    RewardVault rewardVault;
    PoolKey key;
    address tickerOwner;
    address multisig;

    address constant HOOK_ADDRESS = address(0x2AC8);
    uint256 constant SENTINEL_L = 1e15;
    bool private _depositing;

    bytes32 constant PROBE_TOPIC = keccak256("Probe(uint8,bytes)");
    bytes32 constant CALDELTA_TOPIC = keccak256("CalibrationDelta(int128,int128)");

    int256 public cumCalEth;
    int256 public cumCalToken;
    uint256 public steps;
    uint256 public calibrations;
    uint256 public maxCalEthSpent;
    uint256 public maxCalTokenSpent;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        CalibratingHookV3 impl = new CalibratingHookV3(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = CalibratingHookV3(payable(HOOK_ADDRESS));
        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        MockTickerNFT nft = new MockTickerNFT();
        tickerOwner = makeAddr("tickerOwner");
        multisig = makeAddr("multisig");
        nft.setOwner(1, tickerOwner);
        token = new MemeToken("CANARY", "CANARY", address(this));
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(nft), 1, multisig, 9 ether, 20_000, address(new NoopEligibility()));
        refMarket = new ClogMarket(address(this), address(token), address(nft), 1, multisig, 9 ether, 20_000, address(new NoopEligibility()));
        token.setMarket(address(market));
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

        vm.deal(address(this), 1_000 ether);
        // protocol bootstrap buy (mirrored on the reference so both start identical)
        _step(true, 0.01 ether);
        token.approve(address(hook), type(uint256).max);
        hook.fundSentinelAndOperatingFund{value: 5 ether}(key, SENTINEL_L, 1_000e18);
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

    // ── one outer transaction + every invariant ─────────────────────────────────────────────

    function _step(bool zeroForOne, uint256 amount) internal {
        uint256 ledEth0 = hook.operatingFundETH();
        uint256 ledTok0 = hook.operatingFundToken();

        vm.recordLogs();
        BalanceDelta d = abi.decode(manager.unlock(abi.encode(zeroForOne, amount)), (BalanceDelta));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // (a) canonical reference, same input
        uint256 refOut;
        if (zeroForOne) {
            (refOut,) = refMarket.applyBuy(amount);
            assertEq(uint256(int256(d.amount1())), refOut, "user tokens == canonical applyBuy output");
        } else {
            (refOut,,) = refMarket.applySell(amount);
            assertEq(uint256(int256(d.amount0())), refOut, "user ETH == canonical applySell netEthOut");
        }
        _assertStateEqualsReference();

        // (b) observable price
        (uint160 px, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(px, _target(), "slot0 == canonical target after EVERY outer tx");
        assertEq(tick, TickMath.getTickAtSqrtPrice(px), "tick consistent with slot0");

        // (c)(d) calibration accounting
        (int128 a0, int128 a1, bool calibrated) = _calDelta(logs);
        if (calibrated) {
            calibrations++;
            _assertTransientRestored(logs);
            if (a0 < 0 && uint256(int256(-a0)) > maxCalEthSpent) maxCalEthSpent = uint256(int256(-a0));
            if (a1 < 0 && uint256(int256(-a1)) > maxCalTokenSpent) maxCalTokenSpent = uint256(int256(-a1));
        }
        assertEq(int256(hook.operatingFundETH()) - int256(ledEth0), int256(a0), "ledger ETH delta == calibration amount0");
        assertEq(int256(hook.operatingFundToken()) - int256(ledTok0), int256(a1), "ledger token delta == calibration amount1");
        assertGe(address(hook).balance, hook.operatingFundETH(), "raw ETH >= ledger");
        assertGe(token.balanceOf(address(hook)), hook.operatingFundToken(), "raw token >= ledger");
        cumCalEth += a0;
        cumCalToken += a1;

        // (e) ERC6909 conservation
        assertEq(
            manager.balanceOf(address(market), 0),
            market.realETH() + market.pendingWithdrawals(tickerOwner) + market.pendingWithdrawals(multisig),
            "market ETH claim == realETH + owner + multisig liabilities"
        );
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(token)))), market.physicalInventory(), "market token claim == physicalInventory");
        steps++;
    }

    function _assertStateEqualsReference() internal view {
        assertEq(market.re(), refMarket.re(), "re");
        assertEq(market.rt(), refMarket.rt(), "rt");
        assertEq(market.k(), refMarket.k(), "k");
        assertEq(market.sold(), refMarket.sold(), "sold");
        assertEq(market.hwm(), refMarket.hwm(), "hwm");
        assertEq(market.clogRemaining(), refMarket.clogRemaining(), "clogRemaining");
        assertEq(market.rtCeiling(), refMarket.rtCeiling(), "rtCeiling");
        assertEq(market.realETH(), refMarket.realETH(), "realETH");
        assertEq(market.physicalInventory(), refMarket.physicalInventory(), "physicalInventory");
        assertEq(market.pendingWithdrawals(tickerOwner), refMarket.pendingWithdrawals(tickerOwner), "owner credit");
        assertEq(market.pendingWithdrawals(multisig), refMarket.pendingWithdrawals(multisig), "multisig credit");
    }

    function _calDelta(Vm.Log[] memory logs) internal pure returns (int128 a0, int128 a1, bool found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 1 && logs[i].topics[0] == CALDELTA_TOPIC) {
                (a0, a1) = abi.decode(logs[i].data, (int128, int128));
                found = true;
            }
        }
    }

    function _probeDeltas(Vm.Log[] memory logs, uint8 stage) internal pure returns (int256 td0, int256 td1) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 2 && logs[i].topics[0] == PROBE_TOPIC && uint256(logs[i].topics[1]) == stage) {
                bytes memory inner = abi.decode(logs[i].data, (bytes));
                (,,,, td0, td1) = abi.decode(inner, (uint256, uint256, uint256, uint256, int256, int256));
                return (td0, td1);
            }
        }
        revert("probe stage missing");
    }

    function _assertTransientRestored(Vm.Log[] memory logs) internal pure {
        (int256 b0, int256 b1) = _probeDeltas(logs, 2);
        (int256 c0, int256 c1) = _probeDeltas(logs, 4);
        assertEq(c0, b0, "transient ETH delta restored after calibration");
        assertEq(c1, b1, "transient token delta restored after calibration");
    }

    function _report(string memory label) internal {
        emit log_string(label);
        emit log_named_uint("  outer txs checked (cumulative)", steps);
        emit log_named_uint("  calibrations executed (cumulative)", calibrations);
        emit log_named_int("  cumulative calibration ETH flow (hook view, wei)", cumCalEth);
        emit log_named_int("  cumulative calibration token flow (hook view, wei)", cumCalToken);
        emit log_named_uint("  max single calibration ETH spend (wei)", maxCalEthSpent);
        emit log_named_uint("  max single calibration token spend (wei)", maxCalTokenSpent);
        emit log_named_uint("  ledger ETH now", hook.operatingFundETH());
        emit log_named_uint("  ledger token now", hook.operatingFundToken());
    }

    // ── sequences ───────────────────────────────────────────────────────────────────────────

    function test_tenSequentialBuys() public {
        for (uint256 i = 0; i < 10; i++) _step(true, 0.02 ether);
        _report("10 sequential buys");
    }

    function test_tenSequentialSells() public {
        for (uint256 i = 0; i < 10; i++) _step(true, 0.02 ether);
        uint256 chunk = token.balanceOf(address(this)) / 12;
        for (uint256 i = 0; i < 10; i++) _step(false, chunk);
        _report("10 buys then 10 sequential sells");
    }

    function test_tenAlternatingPairs() public {
        for (uint256 i = 0; i < 10; i++) {
            uint256 before = token.balanceOf(address(this));
            _step(true, 0.03 ether);
            _step(false, (token.balanceOf(address(this)) - before) * 2 / 3);
        }
        _report("10 alternating buy/sell pairs");
    }

    function test_manyTinyTrades() public {
        for (uint256 i = 0; i < 40; i++) _step(true, 1e9); // 1 gwei buys
        for (uint256 i = 0; i < 40; i++) _step(false, 1e15); // 0.001-token sells
        _report("40 tiny buys + 40 tiny sells");
    }

    function test_varyingSizes() public {
        uint256 seed = 0xC10C;
        for (uint256 i = 0; i < 30; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool buy = (seed & 1) == 0 || token.balanceOf(address(this)) < 1e18;
            if (buy) {
                _step(true, 1e9 + (seed >> 8) % 0.5 ether);
            } else {
                uint256 bal = token.balanceOf(address(this));
                _step(false, 1e15 + (seed >> 8) % (bal / 2));
            }
        }
        _report("30 pseudo-random mixed-size trades");
    }
}
