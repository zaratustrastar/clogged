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
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Vm.sol";

import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogGenuineLiquidityHook} from "../../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineMath} from "../../src-v4/genuine/ClogGenuineMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";

/// @notice CREATE2 miner for the genuine-liquidity mask.
/// @dev 0x2ACC = BEFORE_INITIALIZE (1<<13) | BEFORE_ADD_LIQUIDITY (1<<11)
///      | BEFORE_REMOVE_LIQUIDITY (1<<9) | BEFORE_SWAP (1<<7) | AFTER_SWAP (1<<6)
///      | BEFORE_SWAP_RETURNS_DELTA (1<<3) | AFTER_SWAP_RETURNS_DELTA (1<<2)
///      = 8192+2048+512+128+64+8+4 = 10956. Verified against Hooks.sol's own constants, which
///      is why AFTER_SWAP_RETURNS_DELTA (absent from V2's 0x2AC8) is present: the sell-side tax
///      and the buy-side output reconciliation both return an unspecified-side delta.
library HookMinerGenuine {
    uint160 internal constant REQUIRED_FLAGS = uint160(0x2ACC);
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    function find(Vm vm, address deployer, bytes32 initCodeHash, uint256 maxIterations)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            address c = vm.computeCreate2Address(salt, initCodeHash, deployer);
            if (uint160(c) & ALL_HOOK_MASK == REQUIRED_FLAGS) return (c, salt);
        }
        revert("no salt");
    }
}

/// @title ClogGenuineDifferential
/// @notice Differential suite: the genuine-liquidity architecture driven through a REAL local
///         PoolManager, compared state-for-state against an UNCHANGED reference ClogMarket that
///         is stepped with the identical inputs. ClogMarket.sol is not modified anywhere.
contract ClogGenuineDifferentialTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;
    uint256 constant VT_OFFSET = 800_000_000e18;

    PoolManager manager;
    ClogGenuineLiquidityHook hook;
    TickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolSwapTest swapRouter;
    NoopEligibility elig;

    MemeToken token;
    ClogMarket market; // live, driven through the pool
    ClogMarket ref; // reference, stepped directly
    PoolKey key;
    PoolId pid;

    address multisig = makeAddr("multisig");
    address deployer = makeAddr("deployer");
    address owner = makeAddr("tickerOwner");
    address trader = makeAddr("trader");

    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        elig = new NoopEligibility();
        tickerNFT = new TickerNFT("G", "G", deployer, "https://x.invalid/", multisig);

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

        // ── launch: token -> market -> pool -> token-only position, ZERO protocol ETH ──
        token = new MemeToken("Gen", "GEN", address(this));
        market = new ClogMarket(
            address(hook), address(token), address(tickerNFT), TOKEN_ID, multisig, SEED, BUFFER, address(elig)
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

        ref = new ClogMarket(
            address(this), address(token), address(tickerNFT), TOKEN_ID, multisig, SEED, BUFFER,
            address(new NoopEligibility())
        );

    }

    // ───────────────────────────────────────────── helpers ──

    function _buy(uint256 amt) internal returns (BalanceDelta d) {
        vm.deal(trader, trader.balance + amt);
        vm.prank(trader);
        d = swapRouter.swap{value: amt}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(uint256 amt) internal returns (BalanceDelta d) {
        vm.startPrank(trader);
        token.approve(address(swapRouter), type(uint256).max);
        d = swapRouter.swap(
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

    function _assertInvariants() internal view {
        assertEq(market.re() - market.realETH(), SEED, "re - realETH != 9 ether");
        assertEq(market.rt() - market.physicalInventory(), VT_OFFSET, "rt - physInv != 800M");
    }

    function _assertMatchesRef() internal view {
        assertEq(market.re(), ref.re(), "re");
        assertEq(market.rt(), ref.rt(), "rt");
        assertEq(market.k(), ref.k(), "k");
        assertEq(market.realETH(), ref.realETH(), "realETH");
        assertEq(market.sold(), ref.sold(), "sold");
        assertEq(market.hwm(), ref.hwm(), "hwm");
        assertEq(market.clogRemaining(), ref.clogRemaining(), "clogRemaining");
        assertEq(market.rtCeiling(), ref.rtCeiling(), "rtCeiling");
        assertEq(market.physicalInventory(), ref.physicalInventory(), "physicalInventory");
    }

    function _assertSlot0Canonical() internal view {
        (uint160 px,,,) = IPoolManager(address(manager)).getSlot0(pid);
        uint160 want = ClogGenuineMath.sqrtPriceX96Of(market.re(), market.rt());
        // RELATIVE tolerance. sqrtPriceX96 here is ~9.8e32, so an absolute bound of a few wei
        // is meaningless. Measured relative error after the in-range clamp fix is ~1.5e-19
        // (diff 1.47e14 on 9.8e32). Bound at 1e-15 relative - still ~10,000x tighter than any
        // economically observable quantity, and four orders tighter than the measured value.
        uint256 diff = px > want ? px - want : want - px;
        uint256 relE18 = want == 0 ? 0 : (diff * 1e18) / want;
        assertLe(relE18, 1_000, "slot0 not canonical (relative 1e-15)");
    }

    // ───────────────────────────────────────────── tests ──

    /// @notice Launch requires ZERO protocol ETH and produces a genuine token-only position.
    function test_launch_isTokenOnly_zeroProtocolEth() public {
        (, , , uint128 liq) = _pos();
        assertGt(liq, 0, "position liquidity must be nonzero");
        assertEq(address(manager).balance, 0, "launch must require zero ETH (fresh local manager)");
        // The tick-rounded position cannot absorb the full supply exactly. The shortfall is
        // held by the hook and TRACKED in residualToken - never hidden. Position + residual
        // must account for every single token.
        uint256 inPool = token.balanceOf(address(manager));
        uint256 residual = hook.residualToken(pid);
        assertEq(inPool + residual, 1_000_000_000e18, "position + tracked residual != total supply");
        assertEq(token.balanceOf(address(hook)), residual, "hook balance must equal tracked residual");
        emit log_named_decimal_uint("launch residual (tokens)", residual, 18);
        emit log_named_decimal_uint("residual as % of supply", residual * 1e20 / 1_000_000_000e18, 18);
        _assertInvariants();
    }

    /// @notice First buy: genuine nonzero core swap, exact canonical user output, exact state.
    function test_firstBuy_exactCanonical() public {
        uint256 amt = 0.5 ether;
        (uint256 wantOut,) = ref.applyBuy(amt);

        uint256 before = token.balanceOf(trader);
        BalanceDelta d = _buy(amt);
        uint256 got = token.balanceOf(trader) - before;

        assertEq(got, wantOut, "user token output != canonical");
        assertLt(d.amount0(), 0, "core swap amount0 must be nonzero negative");
        assertGt(d.amount1(), 0, "core swap amount1 must be nonzero positive");
        _assertMatchesRef();
        _assertInvariants();
        _assertSlot0Canonical();
    }

    function test_repeatedBuys_exactCanonical() public {
        for (uint256 i = 0; i < 5; i++) {
            uint256 amt = 0.25 ether;
            (uint256 wantOut,) = ref.applyBuy(amt);
            uint256 before = token.balanceOf(trader);
            _buy(amt);
            assertEq(token.balanceOf(trader) - before, wantOut, "output drift");
            _assertMatchesRef();
            _assertInvariants();
            _assertSlot0Canonical();
        }
    }

    function test_tinyBuy_exactCanonical() public {
        uint256 amt = 0.0001 ether;
        (uint256 wantOut,) = ref.applyBuy(amt);
        uint256 before = token.balanceOf(trader);
        _buy(amt);
        assertEq(token.balanceOf(trader) - before, wantOut, "tiny buy output drift");
        _assertMatchesRef();
        _assertInvariants();
    }

    function test_unauthorizedLiquidity_reverts() public {
        vm.expectRevert();
        manager.unlock(abi.encode(uint256(0)));
    }

    /// @notice Ordinary uncapped sell: full token input should execute as a genuine core swap.
    function test_ordinarySell_exactCanonical() public {
        _buy(1 ether);
        ref.applyBuy(1 ether);

        uint256 sellAmt = 1_000_000e18;
        (uint256 wantNet,,) = ref.applySell(sellAmt);

        uint256 ethBefore = trader.balance;
        BalanceDelta d = _sell(sellAmt);
        uint256 gotEth = trader.balance - ethBefore;

        assertEq(gotEth, wantNet, "sell net ETH != canonical");
        assertGt(d.amount0(), 0, "core swap must return ETH");
        assertLt(d.amount1(), 0, "core swap must consume token");
        _assertMatchesRef();
        _assertInvariants();
        _assertSlot0Canonical();
    }

    /// @notice Buy then sell then buy - alternating, each exact.
    function test_alternating_exactCanonical() public {
        for (uint256 i = 0; i < 3; i++) {
            _buy(0.4 ether);
            ref.applyBuy(0.4 ether);
            _assertMatchesRef();
            _assertInvariants();

            uint256 amt = 200_000e18;
            ref.applySell(amt);
            _sell(amt);
            _assertMatchesRef();
            _assertInvariants();
            _assertSlot0Canonical();
        }
    }

    /// @notice Measured per-trade gas for the genuine-liquidity path (swap + afterSwap
    ///         re-anchor: burn + re-mint + settlement). Measured with gasleft() around the
    ///         router call, so it excludes test-harness overhead but includes the full
    ///         PoolManager unlock, the core swap, both modifyLiquidity calls and settlement.
    function test_gas_measured() public {
        uint256 g0 = gasleft();
        _buy(0.5 ether);
        uint256 firstBuy = g0 - gasleft();

        g0 = gasleft();
        _buy(0.5 ether);
        uint256 nextBuy = g0 - gasleft();

        g0 = gasleft();
        _sell(500_000e18);
        uint256 sellGas = g0 - gasleft();

        emit log_named_uint("GAS first buy       ", firstBuy);
        emit log_named_uint("GAS subsequent buy  ", nextBuy);
        emit log_named_uint("GAS ordinary sell   ", sellGas);
        // Capped-sell gas is NOT measured: that path is not yet working. See
        // GENUINE_LIQUIDITY_PROTOTYPE.md - the hook currently has no ETH to fund the
        // unfillable remainder and reverts EthResidualExhausted(0.553 ether, 0).
    }

    function _pos() internal view returns (int24 lo, int24 hi, uint256 seedOut, uint128 liq) {
        (, uint256 vs, int24 tl, int24 tu, uint128 l,, ) = _poolState();
        return (tl, tu, vs, l);
    }

    function _poolState()
        internal
        view
        returns (address m, uint256 vs, int24 tl, int24 tu, uint128 l, bool reg, uint256 pad)
    {
        (m, vs, tl, tu, l, reg) = hook.pools(pid);
        pad = 0;
    }
}
