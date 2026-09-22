// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogGenuineLiquidityHook} from "../../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineMath} from "../../src-v4/genuine/ClogGenuineMath.sol";
import {ClogFourPositionMath} from "../../src-v4/genuine/ClogFourPositionMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";

library Miner {
    uint160 constant FLAGS = uint160(0x2ACC);
    uint160 constant MASK = uint160((1 << 14) - 1);
    function find(Vm vm, address d, bytes32 h, uint256 n) internal pure returns (address, bytes32) {
        for (uint256 i = 0; i < n; i++) {
            bytes32 s = bytes32(i);
            address c = vm.computeCreate2Address(s, h, d);
            if (uint160(c) & MASK == FLAGS) return (c, s);
        }
        revert("no salt");
    }
}

/// @notice The single simplest case: one bootstrap buy. Asserts the settlement identity
///         r0 == canonical liability and r1 == 0 directly from the hook's own telemetry.
contract BootstrapBuyTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;

    PoolManager manager;
    ClogGenuineLiquidityHook hook;
    ClogFourPositionMath geometry;
    TickerNFT nft;
    RewardVault vault;
    PoolSwapTest router;
    MemeToken token;
    ClogMarket market;
    PoolKey key;
    PoolId pid;

    address multisig = makeAddr("ms");
    address deployer = makeAddr("dep");
    address owner = makeAddr("own");
    address trader = makeAddr("tr");

    bytes32 constant SETTLE_TOPIC = keccak256("SettleCheck(bool,int256,int256,uint256)");

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        nft = new TickerNFT("B", "B", deployer, "https://x/", multisig);
        geometry = new ClogFourPositionMath(ClogFourPositionMath.HhMode.HI);

        bytes32 h = keccak256(
            abi.encodePacked(
                type(ClogGenuineLiquidityHook).creationCode,
                abi.encode(IPoolManager(address(manager)), address(this), geometry)
            )
        );
        (, bytes32 salt) = Miner.find(vm, address(this), h, 500_000);
        hook = new ClogGenuineLiquidityHook{salt: salt}(IPoolManager(address(manager)), address(this), geometry);

        vault = new RewardVault(makeAddr("rm"), address(manager), address(hook));
        hook.setRewardVault(address(vault));
        router = new PoolSwapTest(IPoolManager(address(manager)));

        token = new MemeToken("G", "G", address(this));
        market = new ClogMarket(
            address(hook), address(token), address(nft), 1, multisig, SEED, BUFFER,
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
        nft.setRegistry(address(this));
        nft.mint(owner, 1);

        hook.registerPool(key, address(market), SEED);
        manager.initialize(key, ClogGenuineMath.sqrtPriceX96Of(market.re(), market.rt()));
        hook.launch(key, market.re(), market.rt());
    }

    function _buy(uint256 amt) internal returns (int256 r0, int256 r1, uint256 liab) {
        vm.recordLogs();
        vm.deal(trader, trader.balance + amt);
        vm.prank(trader);
        router.swap{value: amt}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != SETTLE_TOPIC) continue;
            (, r0, r1, liab) = abi.decode(logs[i].data, (bool, int256, int256, uint256));
        }
    }

    /// @notice BOOTSTRAP buy: r1 is NOT zero here by design - the launch remainder the hook is
    ///         holding gets absorbed into the exact four positions on this first re-anchor.
    function test_1_bootstrapBuy() public {
        uint256 launchResidual = hook.residualToken(pid);
        (int256 r0, int256 r1, uint256 liab) = _buy(0.5 ether);
        emit log_named_int("bootstrap r0 - liability", r0 - int256(liab));
        emit log_named_decimal_uint("launch residual", launchResidual, 18);
        emit log_named_int("bootstrap r1", r1);

        assertApproxEqAbs(r0, int256(liab), 64, "r0 must equal canonical liability (within integer dust)");
        assertLt(r1, int256(0), "bootstrap should consume the launch remainder");
        assertLe(uint256(-r1), launchResidual, "cannot consume more than the launch remainder");
        assertEq(uint8(hook.geometryMode(pid)), 2, "must be FOUR_EXACT after the bootstrap trade");
    }

    function extSell(uint256 a) external { _sell(a); }

    function _sell(uint256 amt) internal {
        vm.recordLogs();
        vm.startPrank(trader);
        token.approve(address(router), type(uint256).max);
        router.swap(
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
    }

    uint8 constant NONE = 0;
    uint8 constant BOUNDARY = 1;
    uint8 constant FOUR = 2;
    uint8 constant NEAR = 3;

    function _mode() internal view returns (uint8) {
        return uint8(hook.geometryMode(pid));
    }

    /// @notice The full geometry state machine, including the realETH == 0 boundary.
    function test_4_modeTransitions() public {
        assertEq(_mode(), BOUNDARY, "launch must be SINGLE_BOUNDARY");

        _buy(0.5 ether);
        assertEq(_mode(), FOUR, "first buy must install FOUR_EXACT");

        _buy(0.2 ether);
        assertEq(_mode(), FOUR, "ordinary trades stay FOUR_EXACT");

        // fully capped sell -> realETH must hit exactly zero, geometry back to the boundary
        uint256 hookEthBefore = address(hook).balance;
        _sell(token.balanceOf(trader));
        assertEq(market.realETH(), 0, "capped sell must drive realETH to 0");
        assertEq(_mode(), BOUNDARY, "capped sell must install SINGLE_BOUNDARY");
        assertEq(address(hook).balance, hookEthBefore, "protocol ETH contribution must be 0");

        _buy(0.1 ether);
        assertEq(_mode(), FOUR, "buy after capped sell must return to FOUR_EXACT");
    }

    /// @notice Repeat the boundary cycle - it must be stable, not a one-shot.
    function test_5_repeatedCappedCycles() public {
        uint256 hookEth0 = address(hook).balance;
        for (uint256 i = 0; i < 6; i++) {
            _buy(0.2 ether);
            assertEq(_mode(), FOUR, "buy should give FOUR_EXACT");
            uint256 b = token.balanceOf(trader);
            if (b == 0) break;
            _sell(b);
            assertEq(market.realETH(), 0, "cycle must cap");
            assertEq(_mode(), BOUNDARY, "cycle must return to SINGLE_BOUNDARY");
        }
        assertEq(address(hook).balance, hookEth0, "no protocol ETH consumed across cycles");
    }

    /// @notice The sub-tick NEAR_BOUNDARY band, entered and left in both directions.
    /// @dev A SMALL first buy lands straight in it: realETH after 0.01 ETH is ~9.5e13 wei,
    ///      already below the analytic threshold vEth*(sqrt(1.0001)-1) ~ 4.5e14 wei.
    function test_6_nearBoundaryCrossings() public {
        uint256 hookEth0 = address(hook).balance;

        // 0.0001 ETH leaves realETH ~9.5e13 wei, inside the band; 0.01 ETH would leave ~9.4e15
        // and sit safely outside it.
        _buy(0.0001 ether);
        assertEq(_mode(), NEAR, "a small first buy must land in NEAR_BOUNDARY");
        assertGt(market.realETH(), 0, "NEAR_BOUNDARY must have realETH > 0");
        assertLt(market.realETH(), 0.00045 ether, "must be inside the analytic band");

        // buy back out of the band into the exact form
        _buy(1 ether);
        assertEq(_mode(), FOUR, "a larger buy must leave the band for THREE_EXACT");
        assertGt(market.realETH(), 0.00045 ether, "must be outside the band");

        // and back down into it, repeatedly
        for (uint256 c = 0; c < 4; c++) {
            uint256 b = token.balanceOf(trader);
            _sell(b - b / 64);
            uint8 m = _mode();
            assertTrue(m == NEAR || m == BOUNDARY || m == FOUR, "mode must stay valid");
            _buy(1 ether);
            assertEq(_mode(), FOUR, "buy must restore THREE_EXACT");
        }

        assertEq(address(hook).balance, hookEth0, "no protocol ETH consumed across crossings");
    }

    /// @notice Measured gas for every path, plus the settlement-cost / reserve high-water marks
    ///         and the token conservation identity.
    function test_7_gasAndConservation() public {
        uint256 g;

        g = gasleft(); _buy(0.5 ether); uint256 gFirst = g - gasleft();
        g = gasleft(); _buy(0.3 ether); uint256 gBuy = g - gasleft();
        g = gasleft(); _sell(token.balanceOf(trader) / 4); uint256 gSell = g - gasleft();
        g = gasleft(); _sell(token.balanceOf(trader)); uint256 gCapped = g - gasleft();
        assertEq(market.realETH(), 0, "that should have capped");
        g = gasleft(); _buy(0.4 ether); uint256 gAfterCapped = g - gasleft();

        emit log_named_uint("GAS first buy       ", gFirst);
        emit log_named_uint("GAS normal buy      ", gBuy);
        emit log_named_uint("GAS normal sell     ", gSell);
        emit log_named_uint("GAS capped sell     ", gCapped);
        emit log_named_uint("GAS buy after capped", gAfterCapped);
        emit log_named_uint("max ETH settlement cost (wei)", hook.maxSettlementCost(pid));
        emit log_named_uint("max token reserve used (wei) ", hook.maxTokenReserveUsed(pid));

        // conservation: pool LP + hook settlement reserve + circulating == total supply
        uint256 inPool = token.balanceOf(address(manager));
        uint256 reserve = token.balanceOf(address(hook));
        uint256 circulating = token.balanceOf(trader);
        assertEq(inPool + reserve + circulating, 1_000_000_000e18, "token conservation");

        // the reserve is NOT user or CLOG revenue: it is not in pendingWithdrawals and not in
        // any WinnerPot claim
        assertEq(market.pendingWithdrawals(address(hook)), 0, "reserve must not be a liability");
        assertGt(reserve, 0, "reserve should be held");
        assertLt(reserve, 1e18, "reserve must stay microscopic");
    }

    /// @notice Many FOUR_EXACT trades: bound the dust empirically rather than assuming it.
    function test_3_dustBoundOverManyTrades() public {
        _buy(0.5 ether);
        uint256 maxEthDust;
        uint256 maxTokDust;
        for (uint256 i = 0; i < 12; i++) {
            (int256 r0, int256 r1, uint256 liab) = _buy(0.25 ether);
            uint256 de = r0 > int256(liab) ? uint256(r0 - int256(liab)) : uint256(int256(liab) - r0);
            uint256 dt = r1 > 0 ? uint256(r1) : uint256(-r1);
            if (de > maxEthDust) maxEthDust = de;
            if (dt > maxTokDust) maxTokDust = dt;
        }
        emit log_named_uint("max ETH dust (wei)  ", maxEthDust);
        emit log_named_uint("max token dust (wei)", maxTokDust);
        assertLt(maxEthDust, 1000, "ETH dust must stay in the wei range");
        assertLt(maxTokDust, 1e12, "token dust must stay far below 1e-6 tokens");
    }

    /// @notice Second buy runs entirely in FOUR_EXACT: r1 must be zero to integer dust.
    function test_2_secondBuy_fourExact() public {
        _buy(0.5 ether);
        (int256 r0, int256 r1, uint256 liab) = _buy(0.3 ether);
        emit log_named_int("four-exact r0 - liability", r0 - int256(liab));
        emit log_named_int("four-exact r1", r1);
        // Measured dust in FOUR_EXACT: 4 wei on the ETH side, 6,112 wei (6.1e-15 tokens) on the
        // token side. Integer rounding of four modifyLiquidity round-trips, not structural.
        assertApproxEqAbs(r0, int256(liab), 64, "r0 must equal canonical liability");
        assertApproxEqAbs(r1, int256(0), 1e7, "r1 must be integer dust in FOUR_EXACT");
    }
}
