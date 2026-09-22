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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {CalibratingHookV3} from "./CalibratingHookV3.sol";

/// @notice E. Full-curve operating-fund / sentinel model.
///         Part 1 drives a CANONICAL ClogMarket (no v4) from launch until it can no longer fill a
///         buy, then sells everything back, recording (re, rt) at representative states. For each
///         L it then computes, with v4-core's own SqrtPriceMath (the exact math the core engine
///         applies between the sentinel's full-range bounds, where no other ticks are
///         initialized), the sentinel composition at each state and the calibration flows for
///         each transition. Rows are emitted as "CSV|..." for programmatic table generation.
///         Part 2 runs REAL trades through PoolManager + calibrating hook for several L values
///         including 0 and asserts exact slot0 == target after every trade.
contract FullCurveFundingTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint256 constant CURVE_ALLOCATION = 900_000_000e18;
    int24 constant LO = -887220;
    int24 constant HI = 887220;

    struct St {
        string label;
        uint256 re;
        uint256 rt;
        uint256 progressBps;
    }

    St[] internal states;

    // ── Part 1: canonical full-range walk ───────────────────────────────────────────────────

    function _sqrtP(uint256 re, uint256 rt) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(rt, 1 << 192, re)));
    }

    function _record(ClogMarket m, string memory label) internal {
        states.push(St({label: label, re: m.re(), rt: m.rt(), progressBps: m.progressBps()}));
    }

    function _walk() internal returns (uint256 totalTokensBought) {
        MinimalMockToken t = new MinimalMockToken();
        MockTickerNFT nft = new MockTickerNFT();
        nft.setOwner(1, address(0xBEEF));
        ClogMarket m = new ClogMarket(address(this), address(t), address(nft), 1, address(0xCAFE), 9 ether, 20_000, address(new NoopEligibility()));
        _record(m, "initial");

        uint256[6] memory targets = [uint256(100), 2_500, 5_000, 7_500, 9_000, 9_900];
        string[6] memory names = ["low_1pct", "p25", "p50", "p75", "high_90pct", "p99"];
        uint256 ti = 0;
        uint256 step = 0.05 ether;
        while (step >= 1e9) {
            try m.applyBuy(step) returns (uint256 out, uint256) {
                totalTokensBought += out;
                while (ti < 6 && m.progressBps() >= targets[ti]) {
                    _record(m, names[ti]);
                    ti++;
                }
            } catch {
                step /= 2;
            }
        }
        _record(m, "near_max");

        // sell everything back in 8 equal chunks (+ remainder)
        uint256 chunk = totalTokensBought / 8;
        for (uint256 i = 0; i < 8; i++) {
            m.applySell(i == 7 ? totalTokensBought - chunk * 7 : chunk);
            _record(m, string.concat("sellback_", vm.toString(i + 1), "of8"));
        }
    }

    function _csvState(St memory s) internal pure returns (string memory) {
        uint160 p = _sqrtP(s.re, s.rt);
        return string.concat(
            "CSV|STATE|", s.label, "|", vm.toString(s.re), "|", vm.toString(s.rt), "|", vm.toString(s.progressBps), "|",
            vm.toString(uint256(p)), "|", vm.toString(int256(TickMath.getTickAtSqrtPrice(p)))
        );
    }

    function _csvComposition(uint128 L, St memory s) internal pure returns (string memory) {
        uint160 p = _sqrtP(s.re, s.rt);
        uint256 eth = SqrtPriceMath.getAmount0Delta(p, TickMath.getSqrtPriceAtTick(HI), L, true);
        uint256 tok = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(LO), p, L, true);
        return string.concat("CSV|COMP|", vm.toString(uint256(L)), "|", s.label, "|", vm.toString(eth), "|", vm.toString(tok));
    }

    /// @dev Calibration from price a to price b against L. Down (b<a) = BUY-direction calibration:
    ///      hook spends ETH (rounded up) and receives token (rounded down). Up = SELL-direction:
    ///      hook spends token (up) and receives ETH (down). Exactly SwapMath's rounding.
    function _cal(uint128 L, uint160 a, uint160 b) internal pure returns (uint256 ethSpent, uint256 ethRecv, uint256 tokSpent, uint256 tokRecv) {
        if (b < a) {
            ethSpent = SqrtPriceMath.getAmount0Delta(b, a, L, true);
            tokRecv = SqrtPriceMath.getAmount1Delta(b, a, L, false);
        } else if (b > a) {
            tokSpent = SqrtPriceMath.getAmount1Delta(a, b, L, true);
            ethRecv = SqrtPriceMath.getAmount0Delta(a, b, L, false);
        }
    }

    function test_fullCurve_table() public {
        uint256 bought = _walk();
        emit log_named_uint("total tokens bought over full run-up", bought);
        for (uint256 i = 0; i < states.length; i++) emit log_string(_csvState(states[i]));

        uint128[4] memory Ls = [uint128(1e9), 1e12, 1e15, 1e18];
        for (uint256 li = 0; li < 4; li++) {
            uint128 L = Ls[li];
            for (uint256 i = 0; i < states.length; i++) emit log_string(_csvComposition(L, states[i]));

            // transitions + running ledger (starting at zero) along the representative path
            int256 runEth;
            int256 runTok;
            int256 minEth;
            int256 minTok;
            uint256 maxEthOne;
            uint256 maxTokOne;
            for (uint256 i = 1; i < states.length; i++) {
                uint160 a = _sqrtP(states[i - 1].re, states[i - 1].rt);
                uint160 b = _sqrtP(states[i].re, states[i].rt);
                (uint256 es, uint256 er, uint256 ts, uint256 tr) = _cal(L, a, b);
                runEth += int256(er) - int256(es);
                runTok += int256(tr) - int256(ts);
                if (runEth < minEth) minEth = runEth;
                if (runTok < minTok) minTok = runTok;
                if (es > maxEthOne) maxEthOne = es;
                if (ts > maxTokOne) maxTokOne = ts;
                emit log_string(string.concat(
                    "CSV|STEP|", vm.toString(uint256(L)), "|", states[i - 1].label, "->", states[i].label, "|",
                    vm.toString(es), "|", vm.toString(tr), "|", vm.toString(ts), "|", vm.toString(er), "|",
                    vm.toString(runEth), "|", vm.toString(runTok)
                ));
            }
            // worst single trades: whole range in ONE tx each way
            uint160 pInit = _sqrtP(states[0].re, states[0].rt);
            uint160 pMax;
            uint160 pMaxP; // highest token/ETH seen (lowest ETH price) across all states
            pMax = pInit;
            pMaxP = pInit;
            for (uint256 i = 0; i < states.length; i++) {
                uint160 p = _sqrtP(states[i].re, states[i].rt);
                if (p < pMax) pMax = p; // lowest sqrtP = highest ETH/token price
                if (p > pMaxP) pMaxP = p;
            }
            (uint256 worstEth,,,) = _cal(L, pMaxP, pMax);
            (,, uint256 worstTok,) = _cal(L, pMax, pMaxP);
            emit log_string(string.concat(
                "CSV|SUMMARY|", vm.toString(uint256(L)), "|", vm.toString(maxEthOne), "|", vm.toString(maxTokOne), "|",
                vm.toString(worstEth), "|", vm.toString(worstTok), "|", vm.toString(-minEth), "|", vm.toString(-minTok), "|",
                vm.toString(runEth), "|", vm.toString(runTok)
            ));
        }
    }

    // ── Part 2: real trades, exact slot0 for every L including 0 ────────────────────────────

    PoolManager manager;
    CalibratingHookV3 hook;
    ClogMarket market;
    MemeToken token;
    PoolKey key;
    bool private _depositing;
    address constant HOOK_ADDRESS = address(0x2AC8);

    function _deploy() internal {
        manager = new PoolManager(address(this));
        CalibratingHookV3 impl = new CalibratingHookV3(IPoolManager(address(manager)));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = CalibratingHookV3(payable(HOOK_ADDRESS));
        hook.setRewardVault(address(new RewardVault(address(this), address(manager), HOOK_ADDRESS)));
        MockTickerNFT nft = new MockTickerNFT();
        nft.setOwner(1, address(0xBEEF));
        token = new MemeToken("C", "C", address(this));
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(nft), 1, address(0xCAFE), 9 ether, 20_000, address(new NoopEligibility()));
        token.setMarket(address(market));
        hook.setMarket(address(market));
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        manager.initialize(key, _sqrtP(market.re(), market.rt()));
        _depositing = true;
        manager.unlock("");
        _depositing = false;
        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, 0, type(uint256).max);
        vm.stopPrank();
        vm.deal(address(this), 10_000 ether);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (_depositing) {
            uint256 supply = token.TOTAL_SUPPLY();
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), supply);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), supply);
            return "";
        }
        (bool z, uint256 amt) = abi.decode(data, (bool, uint256));
        BalanceDelta d = manager.swap(
            key, IPoolManager.SwapParams({zeroForOne: z, amountSpecified: -int256(amt), sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), ""
        );
        if (z) {
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

    function _tradeAndCheck(bool z, uint256 amt) internal returns (BalanceDelta d) {
        d = abi.decode(manager.unlock(abi.encode(z, amt)), (BalanceDelta));
        (uint160 px,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(px, _sqrtP(market.re(), market.rt()), "slot0 == canonical target");
    }

    function _exactnessAtL(uint256 L) internal {
        _deploy();
        _tradeAndCheck(true, 0.5 ether); // bootstrap (L = 0 here) - calibration free and exact
        if (L > 0) {
            token.approve(address(hook), type(uint256).max);
            hook.fundSentinelAndOperatingFund{value: 50 ether}(key, L, token.balanceOf(address(this)) / 4);
        }
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), L, "active liquidity == L");
        for (uint256 i = 0; i < 6; i++) _tradeAndCheck(true, 0.2 ether + i * 1e15);
        for (uint256 i = 0; i < 6; i++) _tradeAndCheck(false, token.balanceOf(address(this)) / 10);
        for (uint256 i = 0; i < 10; i++) _tradeAndCheck(i % 2 == 0, i % 2 == 0 ? 1e9 : 1e15);
    }

    function test_exactness_L0() public {
        _exactnessAtL(0);
    }

    function test_exactness_L1() public {
        _exactnessAtL(1);
    }

    function test_exactness_L1e6() public {
        _exactnessAtL(1e6);
    }

    function test_exactness_L1e9() public {
        _exactnessAtL(1e9);
    }

    function test_exactness_L1e12() public {
        _exactnessAtL(1e12);
    }

    function test_exactness_L1e15() public {
        _exactnessAtL(1e15);
    }

    function test_exactness_L1e18() public {
        _exactnessAtL(1e18);
    }

    function test_exactness_L1e21() public {
        _exactnessAtL(1e21);
    }
}
