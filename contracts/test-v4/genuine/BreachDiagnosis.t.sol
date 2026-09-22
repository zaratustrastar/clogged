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
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogGenuineLiquidityHook} from "../../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineMath} from "../../src-v4/genuine/ClogGenuineMath.sol";
import {ClogFourPositionMath} from "../../src-v4/genuine/ClogFourPositionMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";

library Miner3 {
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

/// @title BreachDiagnosis
/// @notice Replays the EXACT randomized counterexample that breaches
///         abs(r0 - canonicalLiability) > 100 wei, trade by trade. The breaching trade reverts,
///         which rolls back its events - so everything is captured from the PRE-TRADE state,
///         which survives.
///
///   HYPOTHESIS UNDER TEST: _coreBuyInput uses ONE constant active liquidity
///   (poolManager.getLiquidity) across the whole move, which is only valid when no initialized
///   tick is crossed between sqrtP0 and the canonical target. With the 3-position HI
///   construction the bounds are neighbouring ticks, so a large or near-boundary trade can cross
///   one and active liquidity changes mid-swap.
contract BreachDiagnosisTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;
    uint256 constant VT = 800_000_000e18;

    PoolManager manager;
    ClogGenuineLiquidityHook hook;
    ClogFourPositionMath geometry;
    TickerNFT nft;
    RewardVault vault;
    PoolSwapTest router;
    MemeToken token;
    ClogMarket market;
    ClogMarket ref;
    PoolKey key;
    PoolId pid;

    address multisig = makeAddr("ms");
    address deployer = makeAddr("dep");
    address owner = makeAddr("own");
    address trader = makeAddr("tr");

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        nft = new TickerNFT("X", "X", deployer, "https://x/", multisig);
        geometry = new ClogFourPositionMath(ClogFourPositionMath.HhMode.HI);
        bytes32 h = keccak256(
            abi.encodePacked(
                type(ClogGenuineLiquidityHook).creationCode,
                abi.encode(IPoolManager(address(manager)), address(this), geometry)
            )
        );
        (, bytes32 salt) = Miner3.find(vm, address(this), h, 500_000);
        hook = new ClogGenuineLiquidityHook{salt: salt}(IPoolManager(address(manager)), address(this), geometry);
        vault = new RewardVault(makeAddr("rm"), address(manager), address(hook));
        hook.setRewardVault(address(vault));
        router = new PoolSwapTest(IPoolManager(address(manager)));

        token = new MemeToken("X", "X", address(this));
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

        ref = new ClogMarket(
            address(this), address(token), address(nft), 1, multisig, SEED, BUFFER,
            address(new NoopEligibility())
        );
    }

    function extBuy(uint256 a) external {
        vm.deal(trader, trader.balance + a);
        vm.prank(trader);
        router.swap{value: a}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(a),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function extSell(uint256 a) external {
        vm.startPrank(trader);
        token.approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(a),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _dumpPositions() internal returns (uint160 loMax, uint160 hiMin, uint256 live) {
        loMax = 0;
        hiMin = type(uint160).max;
        for (uint256 i = 0; i < 4; i++) {
            (int24 tl, int24 tu, uint128 liq) = hook.positionAt(pid, i);
            if (liq == 0) continue;
            live++;
            emit log_named_uint("  position idx", i);
            emit log_named_int("    tickLower", tl);
            emit log_named_int("    tickUpper", tu);
            emit log_named_uint("    liquidity", liq);
            uint160 a = TickMath.getSqrtPriceAtTick(tl);
            uint160 b = TickMath.getSqrtPriceAtTick(tu);
            if (a > loMax) loMax = a;
            if (b < hiMin) hiMin = b;
        }
    }

    /// @dev Piecewise currency0 across the ACTUAL live ranges, honouring liquidity changes at
    ///      each initialized bound between start and target.
    function _piecewiseCoreInput(uint160 start, uint160 target) internal view returns (uint256 amt) {
        // buy => price falls => walk down from start to target
        uint160 cursor = start;
        while (cursor > target) {
            // active liquidity at `cursor` and the next bound below it
            uint128 activeL;
            uint160 nextBound = target;
            for (uint256 i = 0; i < 4; i++) {
                (int24 tl, int24 tu, uint128 liq) = hook.positionAt(pid, i);
                if (liq == 0) continue;
                uint160 a = TickMath.getSqrtPriceAtTick(tl);
                uint160 b = TickMath.getSqrtPriceAtTick(tu);
                if (cursor <= b && cursor > a) activeL += liq;
                if (a < cursor && a > nextBound) nextBound = a;
                if (b < cursor && b > nextBound) nextBound = b;
            }
            if (activeL == 0) { cursor = nextBound; continue; }
            amt += SqrtPriceMath.getAmount0Delta(nextBound, cursor, activeL, true);
            cursor = nextBound;
        }
    }

    function test_diagnoseFirstBreach() public {
        uint96[12] memory a = [
            uint96(963), uint96(7289), uint96(9810), uint96(16555), uint96(490545329),
            uint96(11056), uint96(12660), uint96(7667), uint96(1298), uint96(2646),
            uint96(16234), uint96(16713012901999045244597275949)
        ];
        uint16 pat = 16;

        this.extBuy(0.5 ether); // leave SINGLE_BOUNDARY
        ref.applyBuy(0.5 ether);

        for (uint256 i = 0; i < a.length; i++) {
            bool doBuy = (pat >> (i % 16)) & 1 == 1 || token.balanceOf(trader) < 1e18;
            uint256 amt;
            if (doBuy) {
                if (market.clogRemaining() == 0 || market.physicalInventory() < 50_000_000e18) continue;
                amt = bound(uint256(a[i]), 0.0001 ether, 0.3 ether);
            } else {
                if (market.realETH() == 0) continue;
                amt = bound(uint256(a[i]), 1e18, token.balanceOf(trader) / 2);
            }

            // ---- capture PRE-TRADE state (survives the revert) ----
            (uint160 sqrtP0,,,) = IPoolManager(address(manager)).getSlot0(pid);
            uint128 activeL = IPoolManager(address(manager)).getLiquidity(pid);
            uint256 re0 = market.re();
            uint256 rt0 = market.rt();
            uint256 realEth0 = market.realETH();
            uint256 physInv0 = market.physicalInventory();

            bool ok;
            if (doBuy) { try this.extBuy(amt) { ok = true; } catch { } }
            else { try this.extSell(amt) { ok = true; } catch { } }

            if (ok) {
                if (doBuy) ref.applyBuy(amt); else ref.applySell(amt);
                continue;
            }

            // ---- BREACH: decompose ----
            emit log_string("=== FIRST BREACHING TRADE ===");
            emit log_named_string("  trade type", doBuy ? "BUY" : "SELL");
            emit log_named_uint("  amount specified", amt);
            emit log_named_uint("  geometry mode before", uint256(uint8(hook.geometryMode(pid))));
            emit log_named_uint("  realETH before", realEth0);
            emit log_named_uint("  physicalInventory before", physInv0);
            emit log_named_uint("  sqrtP0", sqrtP0);
            emit log_named_uint("  pool active liquidity", activeL);

            (uint160 loMax, uint160 hiMin, uint256 live) = _dumpPositions();
            emit log_named_uint("  live positions", live);

            // canonical target from the reference market stepped identically
            uint256 snap = vm.snapshotState();
            if (doBuy) ref.applyBuy(amt); else ref.applySell(amt);
            uint160 target = ClogGenuineMath.sqrtPriceX96Of(ref.re(), ref.rt());
            uint256 liab;
            if (doBuy) {
                uint256 gained = ref.realETH() - realEth0;
                liab = amt > gained ? amt - gained : 0;
            }
            vm.revertToState(snap);

            emit log_named_uint("  canonical sqrt target", target);
            emit log_named_uint("  canonicalLiability", liab);

            emit log_string("  -- in-range band check at PRE-trade price --");
            emit log_named_uint("    max live lower bound", loMax);
            emit log_named_uint("    min live upper bound", hiMin);
            emit log_named_string("    sqrtP0 inside band?", (sqrtP0 > loMax && sqrtP0 < hiMin) ? "YES" : "NO");
            emit log_named_string("    target inside band?", (target > loMax && target < hiMin) ? "YES" : "NO");

            if (doBuy) {
                uint256 constL = SqrtPriceMath.getAmount0Delta(target, sqrtP0, activeL, true);
                uint256 piece = _piecewiseCoreInput(sqrtP0, target);
                emit log_named_uint("  _coreBuyInput (constant L)", constL);
                emit log_named_uint("  piecewise core input      ", piece);
                emit log_named_int("  piecewise - constant      ", int256(piece) - int256(constL));
            }
            return;
        }
        emit log_string("no breach reproduced with this seed");
    }
}
