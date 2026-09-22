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

library Miner2 {
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

/// @title DustMeasurement
/// @notice MEASUREMENT ONLY - not an acceptance test. The hook is pre-funded with tokens so a
///         negative dust step cannot revert the run; that is instrumentation, NOT a fix. The
///         point is to record the CUMULATIVE SIGNED dust series, not just per-trade maxima, and
///         decide whether a one-time reserve is even valid.
contract DustMeasurementTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;
    bytes32 constant SETTLE_TOPIC = keccak256("SettleCheck(bool,int256,int256,uint256)");

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

    int256 maxPosEth;
    int256 maxNegEth;
    int256 cumEth;
    int256 minCumEth;
    int256 maxCumEth;
    int256 maxPosTok;
    int256 maxNegTok;
    int256 cumTok;
    int256 minCumTok;
    int256 maxCumTok;
    uint256 trades;
    bool bootstrapSeen;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        nft = new TickerNFT("D", "D", deployer, "https://x/", multisig);
        geometry = new ClogFourPositionMath();
        bytes32 h = keccak256(
            abi.encodePacked(
                type(ClogGenuineLiquidityHook).creationCode,
                abi.encode(IPoolManager(address(manager)), address(this), geometry)
            )
        );
        (, bytes32 salt) = Miner2.find(vm, address(this), h, 500_000);
        hook = new ClogGenuineLiquidityHook{salt: salt}(IPoolManager(address(manager)), address(this), geometry);
        vault = new RewardVault(makeAddr("rm"), address(manager), address(hook));
        hook.setRewardVault(address(vault));
        router = new PoolSwapTest(IPoolManager(address(manager)));

        token = new MemeToken("D", "D", address(this));
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

    uint8 modeBefore;

    function _markMode() internal { modeBefore = uint8(hook.geometryMode(pid)); }

    function _record() internal {
        bool fourExact = modeBefore == 2 && uint8(hook.geometryMode(pid)) == 2;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != SETTLE_TOPIC) continue;
            (, int256 r0, int256 r1, uint256 liab) = abi.decode(logs[i].data, (bool, int256, int256, uint256));
            // FOUR_EXACT only. Boundary re-anchors (launch, capped sells) are a different
            // regime and are measured separately by the mode-transition tests.
            if (!fourExact) continue;
            int256 de = r0 - int256(liab);
            trades++;
            if (de > maxPosEth) maxPosEth = de;
            if (de < maxNegEth) maxNegEth = de;
            cumEth += de;
            if (cumEth < minCumEth) minCumEth = cumEth;
            if (cumEth > maxCumEth) maxCumEth = cumEth;
            if (r1 > maxPosTok) maxPosTok = r1;
            if (r1 < maxNegTok) maxNegTok = r1;
            cumTok += r1;
            if (cumTok < minCumTok) minCumTok = cumTok;
            if (cumTok > maxCumTok) maxCumTok = cumTok;
        }
    }

    function _buy(uint256 amt) internal {
        _markMode();
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
        _record();
    }

    function _sell(uint256 amt) internal {
        _markMode();
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
        _record();
    }

    function _report(string memory label) internal {
        emit log_string(label);
        emit log_named_uint("  trades measured        ", trades);
        emit log_named_int("  max +ve ETH dust (wei) ", maxPosEth);
        emit log_named_int("  max -ve ETH dust (wei) ", maxNegEth);
        emit log_named_int("  min cumulative ETH     ", minCumEth);
        emit log_named_int("  max cumulative ETH     ", maxCumEth);
        emit log_named_int("  max +ve token dust     ", maxPosTok);
        emit log_named_int("  max -ve token dust     ", maxNegTok);
        emit log_named_int("  min cumulative token   ", minCumTok);
        emit log_named_int("  max cumulative token   ", maxCumTok);
    }

    /// @dev instrumentation only: lets a negative dust step proceed so the series is observable
    /// @dev No pre-funding any more. The boundary clamp that previously forced it is handled by
    ///      SINGLE_BOUNDARY, so any revert here is a genuine accounting failure.
    function _prefund() internal {}

    function test_A1_repeatedBuys() public {
        _prefund();
        _buy(1 ether);
        for (uint256 i = 0; i < 40; i++) {
            if (market.physicalInventory() < 100_000_000e18) break;
            _buy(0.2 ether);
        }
        _report("A1 repeated same-direction buys");
    }

    function test_A2_longAlternating() public {
        _prefund();
        _buy(1 ether);
        for (uint256 i = 0; i < 60; i++) {
            _buy(0.3 ether);
            uint256 b = token.balanceOf(trader);
            if (b > 2e18) _sell(b / 3);
        }
        _report("A2 long alternating");
    }

    function test_A3_repeatedSells() public {
        _prefund();
        _buy(3 ether);
        for (uint256 i = 0; i < 40; i++) {
            uint256 b = token.balanceOf(trader);
            if (b < 2e18 || market.realETH() == 0) break;
            _sell(b / 10);
        }
        _report("A3 repeated sells");
    }

    function test_A4_cappedCycles() public {
        _prefund();
        for (uint256 c = 0; c < 12; c++) {
            _buy(0.2 ether);
            uint256 b = token.balanceOf(trader);
            if (b > 0) _sell(b); // drives realETH to 0
        }
        _report("A4 capped-sell -> buy -> capped-sell cycles");
    }

    /// @notice Accounting failures are UNCAUGHT: any revert fails the run.
    function testFuzz_A5_randomized(uint96[12] calldata a, uint16 pat) public {
        _prefund();
        _buy(0.5 ether); // leave SINGLE_BOUNDARY so the body measures FOUR_EXACT
        for (uint256 i = 0; i < a.length; i++) {
            if ((pat >> (i % 16)) & 1 == 1 || token.balanceOf(trader) < 1e18) {
                if (market.clogRemaining() == 0 || market.physicalInventory() < 50_000_000e18) continue;
                _buy(bound(uint256(a[i]), 0.0001 ether, 0.3 ether));
            } else {
                if (market.realETH() == 0) continue;
                _sell(bound(uint256(a[i]), 1e18, token.balanceOf(trader) / 2));
            }
        }
        assertLe(minCumEth, maxCumEth);
        assertLe(minCumTok, maxCumTok);
    }
}
