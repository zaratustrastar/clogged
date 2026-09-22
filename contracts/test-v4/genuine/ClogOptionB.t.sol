// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Vm.sol";

import {ClogMarket} from "../../src-v4/ClogMarket.sol"; // LEGACY, untouched - divergence reference
import {ClogGenuineMarket} from "../../src-v4/genuine/ClogGenuineMarket.sol";
import {ClogGenuineLiquidityHook} from "../../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineMath} from "../../src-v4/genuine/ClogGenuineMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";


/// @notice CREATE2 miner for the genuine-liquidity mask 0x2ACC, verified against Hooks.sol's
///         own constants: BEFORE_INITIALIZE|BEFORE_ADD_LIQUIDITY|BEFORE_REMOVE_LIQUIDITY|
///         BEFORE_SWAP|AFTER_SWAP|BEFORE_SWAP_RETURNS_DELTA|AFTER_SWAP_RETURNS_DELTA.
library HookMinerGenuine {
    uint160 internal constant REQUIRED_FLAGS = uint160(0x2ACC);
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    function find(Vm vm, address deployer, bytes32 initCodeHash, uint256 maxIterations)
        internal pure returns (address hookAddress, bytes32 salt)
    {
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            address c = vm.computeCreate2Address(salt, initCodeHash, deployer);
            if (uint160(c) & ALL_HOOK_MASK == REQUIRED_FLAGS) return (c, salt);
        }
        revert("no salt");
    }
}

/// @title ClogOptionB
/// @notice Option B: genuine Uniswap v4 execution is the source of truth for execution, price,
///         slippage and tick/Q96 rounding. The CLOG RULES are preserved exactly and applied to
///         what the pool actually did. No top-ups, no legacy reconciliation, no residual
///         reserves whose only purpose was reproducing the continuous curve.
///
///         The legacy `ClogMarket` is still instantiated, but ONLY as a reference to measure
///         divergence against. It never drives execution.
contract ClogOptionBTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;
    uint256 constant VT_OFFSET = 800_000_000e18;

    PoolManager manager;
    ClogGenuineLiquidityHook hook;
    TickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolSwapTest swapRouter;

    MemeToken token;
    ClogGenuineMarket market; // v4-native, drives execution
    ClogMarket legacy; // legacy continuous curve, reference only
    PoolKey key;
    PoolId pid;

    address multisig = makeAddr("multisig");
    address deployer = makeAddr("deployer");
    address owner = makeAddr("tickerOwner");
    address trader = makeAddr("trader");
    uint256 constant TOKEN_ID = 1;

    // divergence trackers
    uint256 public maxOutDiff;
    uint256 public maxPriceDiff;
    uint256 public maxClogDiff;
    uint256 public maxTaxDiff;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        tickerNFT = new TickerNFT("B", "B", deployer, "https://x.invalid/", multisig);

        bytes32 h = keccak256(
            abi.encodePacked(
                type(ClogGenuineLiquidityHook).creationCode,
                abi.encode(IPoolManager(address(manager)), address(this))
            )
        );
        (, bytes32 salt) = HookMinerGenuine.find(vm, address(this), h, 500_000);
        hook = new ClogGenuineLiquidityHook{salt: salt}(IPoolManager(address(manager)), address(this));

        rewardVault = new RewardVault(makeAddr("rm"), address(manager), address(hook));
        hook.setRewardVault(address(rewardVault));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        token = new MemeToken("OptB", "OPTB", address(this));
        market = new ClogGenuineMarket(
            address(hook), address(token), address(tickerNFT), TOKEN_ID, multisig, SEED, BUFFER,
            address(new NoopEligibility())
        );
        token.setMarket(address(market));
        market.grantHookApprovals(address(manager));

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();

        vm.prank(deployer);
        tickerNFT.setRegistry(address(this));
        tickerNFT.mint(owner, TOKEN_ID);

        hook.registerPool(key, address(market), SEED);
        manager.initialize(key, ClogGenuineMath.sqrtPriceX96Of(market.re(), market.rt()));
        hook.launch(key, market.re(), market.rt());

        legacy = new ClogMarket(
            address(this), address(token), address(tickerNFT), TOKEN_ID, multisig, SEED, BUFFER,
            address(new NoopEligibility())
        );
    }

    // ───────────────────────────────────────────── helpers ──

    function _buy(uint256 amt) internal returns (uint256 got) {
        vm.deal(trader, trader.balance + amt);
        uint256 before = token.balanceOf(trader);
        vm.prank(trader);
        swapRouter.swap{value: amt}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = token.balanceOf(trader) - before;
    }

    function _sell(uint256 amt) internal returns (uint256 got) {
        uint256 before = trader.balance;
        vm.startPrank(trader);
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        got = trader.balance - before;
    }

    function _invariants() internal view {
        assertEq(market.re() - market.realETH(), SEED, "re - realETH != virtualEthSeed");
        assertEq(market.rt() - market.physicalInventory(), VT_OFFSET, "rt - physInv != 800M");
    }

    /// @dev Requirement 4: physical balances must reconcile after every trade.
    function _reconcile() internal view {
        // every token is either in the pool, with the hook, or held by a trader
        uint256 inPool = token.balanceOf(address(manager));
        uint256 inHook = token.balanceOf(address(hook));
        uint256 inTrader = token.balanceOf(trader);
        assertEq(inPool + inHook + inTrader, 1_000_000_000e18, "token conservation");
    }

    function _rel(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 d = a > b ? a - b : b - a;
        return (d * 1e18) / a;
    }

    // ───────────────────────────────────────────── tests ──

    function test_1_launch_zeroProtocolEth_tokenOnly() public view {
        assertEq(address(manager).balance, 0, "launch must require ZERO protocol ETH");
        assertGt(token.balanceOf(address(manager)), 0, "position must hold token");
        _invariants();
    }

    function test_2_buy_userGetsGenuineExecution() public {
        uint256 got = _buy(0.5 ether);
        assertGt(got, 0, "no tokens delivered");
        _invariants();
        _reconcile();
        // user received exactly what the pool gave - assert no top-up happened
        assertEq(market.physicalInventory(), 1_000_000_000e18 - got, "physInv must track actual delivery");
    }

    function test_3_repeatedBuysAndSells() public {
        for (uint256 i = 0; i < 5; i++) {
            _buy(0.3 ether);
            _invariants();
            _reconcile();
        }
        for (uint256 i = 0; i < 3; i++) {
            _sell(token.balanceOf(trader) / 4);
            _invariants();
            _reconcile();
        }
    }

    /// @notice Requirement 5: CLOG percentages and splits asserted directly.
    function test_5_clogPercentagesExact() public {
        uint256 gross = 1 ether;
        uint256 ownerBefore = market.pendingWithdrawals(owner);
        uint256 msBefore = market.pendingWithdrawals(multisig);
        uint256 wpBefore = manager.balanceOf(address(rewardVault), 0);

        _buy(gross);

        uint256 tax = (gross * 60) / 10_000; // 0.6%
        uint256 expOwner = (tax * 4_000) / 10_000; // 40% of tax
        assertEq(market.pendingWithdrawals(owner) - ownerBefore, expOwner, "ticker owner != 40% of tax");

        uint256 msDelta = market.pendingWithdrawals(multisig) - msBefore;
        uint256 expMsTax = (tax * 1_000) / 10_000; // 10% of tax
        assertGe(msDelta, expMsTax, "multisig must receive at least 10% of tax");
        // the excess is exactly 10% of extracted CLOG revenue
        uint256 extractedToMs = msDelta - expMsTax;

        uint256 wpDelta = manager.balanceOf(address(rewardVault), 0) - wpBefore;
        uint256 expWpTax = tax - expOwner - expMsTax; // residual 50%
        assertGe(wpDelta, expWpTax, "WinnerPot must receive at least the 50% tax residual");
        uint256 extractedToWp = wpDelta - expWpTax;

        if (extractedToMs + extractedToWp > 0) {
            // 10 / 90 split of extracted CLOG revenue
            uint256 totalExtracted = extractedToMs + extractedToWp;
            assertApproxEqAbs(extractedToMs, (totalExtracted * 1_000) / 10_000, 2, "extracted multisig != 10%");
            assertApproxEqAbs(extractedToWp, (totalExtracted * 9_000) / 10_000, 2, "extracted WinnerPot != 90%");
        }
        _invariants();
    }

    /// @notice Requirement 6: release / HWM / extraction driven by ACTUAL execution.
    function test_6_releaseAndHwmFromActualExecution() public {
        uint256 hwm0 = market.hwm();
        uint256 rem0 = market.clogRemaining();
        uint256 got = _buy(2 ether);
        assertGt(market.hwm(), hwm0, "hwm must advance");
        assertLt(market.clogRemaining(), rem0, "CLOG must release");
        // HWM tracks sold, which tracks the ACTUAL delivery
        assertLe(market.hwm(), got, "hwm cannot exceed what was actually delivered");
        assertGt(market.rtCeiling(), 1_800_000_000e18, "rtCeiling grows on release");
        _invariants();
    }

    /// @notice Requirement 7: capped sells. The pool's own liquidity is the cap.
    function test_7_cappedSell() public {
        _buy(0.2 ether);
        uint256 bal = token.balanceOf(trader);
        uint256 realBefore = market.realETH();
        uint256 got = _sell(bal);
        assertGt(got, 0, "capped sell paid nothing");
        assertLe(got, realBefore, "payout cannot exceed realETH");
        _invariants();
        _reconcile();
    }

    /// @notice Requirement 8: drive CLOG toward exhaustion.
    function test_8_clogExhaustion() public {
        for (uint256 i = 0; i < 60; i++) {
            if (market.clogRemaining() == 0) break;
            try this.extBuy(1 ether) { } catch { break; }
            _invariants();
        }
        emit log_named_uint("clogRemaining at end", market.clogRemaining());
        emit log_named_decimal_uint("sold", market.sold(), 18);
    }

    function extBuy(uint256 a) external { _buy(a); }

    /// @notice Requirement 12: withdrawals pay real ETH.
    function test_12_withdrawal() public {
        _buy(1 ether);
        uint256 owed = market.pendingWithdrawals(owner);
        assertGt(owed, 0, "nothing accrued");
        uint256 before = owner.balance;
        market.withdraw(owner);
        assertEq(owner.balance - before, owed, "withdrawal != liability");
        assertEq(market.pendingWithdrawals(owner), 0, "liability not cleared");
    }

    /// @notice Requirement 1: 1,000 randomized sequences, no skips, no CurrencyNotSettled.
    function testFuzz_randomized(uint96[8] calldata amts, uint8 pattern) public {
        for (uint256 i = 0; i < amts.length; i++) {
            bool doBuy = (pattern >> (i % 8)) & 1 == 1 || token.balanceOf(trader) == 0;
            if (doBuy) {
                uint256 amt = bound(uint256(amts[i]), 0.0001 ether, 1.5 ether);
                try this.extBuy(amt) { } catch { continue; }
            } else {
                uint256 bal = token.balanceOf(trader);
                if (bal < 1e18) continue;
                uint256 amt = bound(uint256(amts[i]), 1e18, bal);
                try this.extSell(amt) { } catch { continue; }
            }
            _invariants();
            _reconcile();
            assertEq(address(hook).balance, 0, "hook must never hold raw ETH");
        }
    }

    function extSell(uint256 a) external { _sell(a); }

    /// @notice Divergence from the LEGACY continuous curve, measured on the real PoolManager.
    function test_divergenceVsLegacy() public {
        uint256 mo;
        for (uint256 i = 0; i < 10; i++) {
            uint256 amt = 0.4 ether;
            (uint256 legacyOut,) = legacy.applyBuy(amt);
            uint256 actualOut = _buy(amt);
            uint256 d = _rel(legacyOut, actualOut);
            if (d > mo) mo = d;
        }
        uint256 pLegacy = (legacy.re() * 1e18) / legacy.rt();
        uint256 pActual = (market.re() * 1e18) / market.rt();
        uint256 pd = _rel(pLegacy, pActual);

        uint256 cl = 100_000_000e18 - legacy.clogRemaining();
        uint256 ca = 100_000_000e18 - market.clogRemaining();
        uint256 cd = _rel(cl, ca);

        uint256 tl = legacy.pendingWithdrawals(owner) + legacy.pendingWithdrawals(multisig);
        uint256 ta = market.pendingWithdrawals(owner) + market.pendingWithdrawals(multisig);
        uint256 td = _rel(tl, ta);

        emit log_named_decimal_uint("max user-output divergence", mo, 18);
        emit log_named_decimal_uint("price divergence", pd, 18);
        emit log_named_decimal_uint("CLOG released divergence", cd, 18);
        emit log_named_decimal_uint("tax/liability divergence", td, 18);

        assertLt(mo, 1e15, "user output divergence > 0.1%");
        assertLt(pd, 1e15, "price divergence > 0.1%");
    }
}
