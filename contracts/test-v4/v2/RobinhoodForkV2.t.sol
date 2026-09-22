// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogV4HookV2} from "../../src-v4/ClogV4HookV2.sol";
import {TickerRegistryV4} from "../../src-v4/TickerRegistryV4.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {EligibilityRegistry} from "../../src/EligibilityRegistry.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {HookMinerV2} from "../utils/HookMinerV2.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IV4QuoterLike {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice G. Runs ONLY against a Robinhood Chain fork (set ROBINHOOD_RPC). Deploys a fresh
///         fork-local V2 stack against the REAL deployed PoolManager / Universal Router /
///         V4Quoter / Permit2. Nothing is broadcast. Skipped (not passed) when ROBINHOOD_RPC is
///         unset, so local suite counts never include it.
contract RobinhoodForkV2Test is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniversalRouter constant UR = IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    IV4QuoterLike constant QUOTER = IV4QuoterLike(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant CHAIN_ID = 4663;

    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    ClogV4HookV2 hook;
    TickerRegistryV4 registry;
    EligibilityRegistry eligibility;
    TickerNFT tickerNFT;
    ClogMarket market;
    MemeToken token;
    ClogMarket ref;
    PoolKey key;
    uint256 tokenId;
    uint8 public acceptedParamsLayout; // 6 = with minHopPriceX36, 5 = legacy

    address deployer = makeAddr("deployer");
    address multisig = 0x29DEf4F5429CAC1e364263C449A7aE791657d48F;
    address launcher = makeAddr("launcher");
    address ops = makeAddr("sentinelManager");
    address alice = makeAddr("alice");

    function setUp() public {
        if (!vm.envExists("ROBINHOOD_RPC")) {
            vm.skip(true, "ROBINHOOD_RPC not set - fork test not run");
            return;
        }
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC"));
        require(block.chainid == CHAIN_ID, "not Robinhood Chain");
        require(address(PM).code.length > 0 && address(UR).code.length > 0 && address(QUOTER).code.length > 0 && PERMIT2.code.length > 0, "missing deployed contract");

        eligibility = new EligibilityRegistry(address(this), 4, 0.03 ether, 600);
        tickerNFT = new TickerNFT("Clog V4 Tickers", "CLOGV4", deployer, "https://example.invalid/", multisig);
        registry = new TickerRegistryV4(address(eligibility), address(tickerNFT), multisig, 9 ether, 20_000);
        bytes32 h = HookMinerV2.hashInitCode(abi.encodePacked(type(ClogV4HookV2).creationCode, abi.encode(PM, address(registry), ops)));
        (, bytes32 salt) = HookMinerV2.find(vm, address(this), h, 400_000);
        hook = new ClogV4HookV2{salt: salt}(PM, address(registry), ops);
        RewardVault rv = new RewardVault(makeAddr("roundManager"), address(PM), address(hook));
        registry.setV4Infrastructure(address(PM), address(hook), address(rv));
        vm.prank(deployer);
        tickerNFT.setRegistry(address(registry));

        bytes32 s = keccak256("fork-entropy");
        vm.prank(launcher);
        registry.commit(keccak256(abi.encode(launcher, keccak256(bytes("FORKV")), s)));
        vm.warp(vm.getBlockTimestamp() + registry.MIN_REVEAL_DELAY());
        uint256 price = registry.LAUNCH_PRICE();
        assertEq(price, 0.002 ether, "launch price must be exactly 0.002 ETH");
        require(multisig.code.length > 0, "real Safe has no code on Robinhood");

        uint256 safeBalanceBefore = multisig.balance;
        uint256 registryBalanceBefore = address(registry).balance;
        uint256 rewardVaultBalanceBefore = address(rv).balance;

        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        tokenId = registry.reveal{value: price}("FORKV", s);

        assertEq(multisig.balance, safeBalanceBefore + price, "100% launch fee must reach real Safe");
        assertEq(address(registry).balance, registryBalanceBefore, "Registry must retain zero launch fee");
        assertEq(address(rv).balance, rewardVaultBalanceBefore, "RewardVault must receive zero launch fee");
        market = ClogMarket(registry.marketOf(tokenId));
        token = MemeToken(registry.tokenOf(tokenId));
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        ref = new ClogMarket(address(this), address(token), address(tickerNFT), tokenId, multisig, 9 ether, 20_000, address(new NoopEligibility()));
    }

    function _slot0() internal view returns (uint160 px) {
        (px,,,) = PM.getSlot0(key.toId());
    }

    function _params(bool z, uint128 amt, uint8 layout) internal view returns (bytes memory) {
        if (layout == 6) return abi.encode(key, z, amt, uint128(0), uint256(0), bytes(""));
        return abi.encode(key, z, amt, uint128(0), bytes(""));
    }

    function _urInputs(bool z, uint128 amt, uint8 layout) internal view returns (bytes[] memory inputs) {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory p = new bytes[](3);
        p[0] = _params(z, amt, layout);
        p[1] = abi.encode(z ? key.currency0 : key.currency1, uint256(amt));
        p[2] = abi.encode(z ? key.currency1 : key.currency0, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, p);
    }

    function _execute(address who, bool z, uint128 amt, uint8 layout) external {
        require(msg.sender == address(this), "internal");
        vm.prank(who);
        uint256 gasBefore = gasleft();
        UR.execute{value: z ? amt : 0}(abi.encodePacked(V4_SWAP), _urInputs(z, amt, layout), vm.getBlockTimestamp() + 60);
        uint256 gasUsed = gasBefore - gasleft();

        if (z) {
            emit log_named_uint("UR BUY gas", gasUsed);
        } else {
            emit log_named_uint("UR SELL gas", gasUsed);
        }
    }

    /// @dev Real Universal Router exact-input swap; auto-detects the deployed params layout.
    function _urSwap(address who, bool z, uint256 amt) internal returns (uint256 out) {
        if (z) vm.deal(who, who.balance + amt);
        uint256 e0 = who.balance;
        uint256 t0 = token.balanceOf(who);
        if (acceptedParamsLayout == 0) {
            try this._execute(who, z, uint128(amt), 6) {
                acceptedParamsLayout = 6;
            } catch {
                this._execute(who, z, uint128(amt), 5);
                acceptedParamsLayout = 5;
            }
        } else {
            this._execute(who, z, uint128(amt), acceptedParamsLayout);
        }
        out = z ? token.balanceOf(who) - t0 : who.balance - e0;
    }

    function _quote(bool z, uint256 amt) internal returns (uint256 q) {
        (q,) = QUOTER.quoteExactInputSingle(IV4QuoterLike.QuoteExactSingleParams({poolKey: key, zeroForOne: z, exactAmount: uint128(amt), hookData: ""}));
    }

    function _approvePermit2(address who) internal {
        vm.startPrank(who);
        token.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(token), address(UR), type(uint160).max, uint48(vm.getBlockTimestamp() + 1 days));
        vm.stopPrank();
    }

    function _assertCanonical() internal view {
        assertEq(_slot0(), hook.canonicalSqrtPriceX96(address(market)), "slot0 == canonical");
        assertEq(market.re(), ref.re(), "re");
        assertEq(market.rt(), ref.rt(), "rt");
        assertEq(market.sold(), ref.sold(), "sold");
        assertEq(market.hwm(), ref.hwm(), "hwm");
        assertEq(market.clogRemaining(), ref.clogRemaining(), "clogRemaining");
        assertEq(market.rtCeiling(), ref.rtCeiling(), "rtCeiling");
        assertEq(market.realETH(), ref.realETH(), "realETH");
        address owner = tickerNFT.ownerOf(tokenId);
        assertEq(market.pendingWithdrawals(owner), ref.pendingWithdrawals(owner), "owner credit");
        assertEq(market.pendingWithdrawals(multisig), ref.pendingWithdrawals(multisig), "multisig credit");
        assertEq(PM.balanceOf(address(market), 0), market.realETH() + market.pendingWithdrawals(owner) + market.pendingWithdrawals(multisig), "ERC6909 ETH conservation");
        assertEq(PM.balanceOf(address(market), uint256(uint160(address(token)))), market.physicalInventory(), "ERC6909 token conservation");
        assertGe(address(hook).balance, hook.totalOperatingFundEth(), "ETH ledger backed");
        assertGe(token.balanceOf(address(hook)), hook.operatingFundToken(key.toId()), "token ledger backed");
    }

    function _buy(address who, uint256 amt) internal returns (uint256 out) {
        uint256 q = _quote(true, amt);
        out = _urSwap(who, true, amt);
        (uint256 r,) = ref.applyBuy(amt);
        assertEq(out, r, "UR buy == canonical CLOG");
        assertEq(q, out, "V4Quoter == actual (buy)");
        _assertCanonical();
    }

    function _sell(address who, uint256 amt) internal returns (uint256 out) {
        uint256 q = _quote(false, amt);
        out = _urSwap(who, false, amt);
        (uint256 r,,) = ref.applySell(amt);
        assertEq(out, r, "UR sell == canonical CLOG");
        assertEq(q, out, "V4Quoter == actual (sell)");
        _assertCanonical();
    }

    function test_fork_fullLifecycle() public {
        // 1. mask
        uint160 mask = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(uint160(address(hook)) & uint160((1 << 14) - 1), mask, "hook satisfies 0x2AC8");
        // 2. canonical initial price
        assertEq(_slot0(), hook.canonicalSqrtPriceX96(address(market)), "canonical initial slot0");
        // bootstrap through the real UR (L = 0), then 3. install sentinel
        _buy(ops, 0.01 ether);
        vm.startPrank(ops);
        token.approve(address(hook), type(uint256).max);
        vm.deal(ops, ops.balance + 1 ether);
        hook.modifySentinel{value: 1 ether}(key, int256(1e15));
        hook.depositOperatingFund{value: 0.001 ether}(key, 1_000e18);
        vm.stopPrank();
        assertEq(PM.getLiquidity(key.toId()), 1e15, "sentinel installed on the real PoolManager");
        // 5-8. real quoter + real UR buy + calibration + canonical slot0
        uint256 got = _buy(alice, 0.05 ether);
        assertGt(eligibility.aboveThresholdSince(tokenId), 0, "14. eligibility touched with real MemeToken");
        // 9-10. real UR + Permit2 sell
        _approvePermit2(alice);
        _sell(alice, got / 2);
        // multiple sequential router swaps
        for (uint256 i = 0; i < 5; i++) {
            uint256 g = _buy(alice, 0.01 ether + i * 1e15);
            _sell(alice, g / 3);
        }
        emit log_named_uint("Universal Router ExactInputSingleParams layout accepted", acceptedParamsLayout);
    }

    function test_fork_unauthorizedLiquidityRejected() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        PM.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e15, salt: 0}), "");
        vm.prank(attacker);
        vm.expectRevert(bytes("not sentinel manager"));
        hook.modifySentinel(key, int256(1e15));
    }

    function test_fork_ledgerShort_buyRevertsAtomically() public {
        _buy(ops, 0.01 ether);
        vm.startPrank(ops);
        token.approve(address(hook), type(uint256).max);
        vm.deal(ops, ops.balance + 1 ether);
        hook.modifySentinel{value: 1 ether}(key, int256(1e15));
        vm.stopPrank(); // ETH ledger stays 0: a buy calibration needs ETH
        uint256 reBefore = market.re();
        uint256 streakBefore = eligibility.aboveThresholdSince(tokenId);
        uint160 pxBefore = _slot0();
        uint8 layout = acceptedParamsLayout;
        require(layout != 0, "layout detected by bootstrap buy");
        vm.deal(alice, 1 ether);
        vm.expectRevert();
        this._execute(alice, true, uint128(0.05 ether), layout);
        assertEq(market.re(), reBefore, "CLOG state rolled back");
        assertEq(eligibility.aboveThresholdSince(tokenId), streakBefore, "eligibility rolled back");
        assertEq(_slot0(), pxBefore, "slot0 rolled back");
        // causality: the SAME call succeeds once (and only because) the ledger is funded
        vm.prank(ops);
        hook.depositOperatingFund{value: 0.001 ether}(key, 0);
        this._execute(alice, true, uint128(0.05 ether), layout);
        assertEq(_slot0(), hook.canonicalSqrtPriceX96(address(market)), "succeeds and calibrates once funded");
    }
}
