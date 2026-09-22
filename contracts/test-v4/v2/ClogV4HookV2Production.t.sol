// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogV4HookV2} from "../../src-v4/ClogV4HookV2.sol";
import {TickerRegistryV4} from "../../src-v4/TickerRegistryV4.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {EligibilityRegistry} from "../../src/EligibilityRegistry.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {HookMinerV2} from "../utils/HookMinerV2.sol";

contract ClogV4HookV2ProductionTest is Test {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    ClogV4HookV2 hook;
    TickerRegistryV4 registry;
    EligibilityRegistry eligibility;
    TickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    ClogMarket market;
    MemeToken token;
    ClogMarket ref;
    PoolKey key;
    uint256 tokenId;

    address deployer = makeAddr("deployer");
    address multisig = makeAddr("multisig");
    address launcher = makeAddr("launcher");
    address ops = makeAddr("sentinelManager");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    uint256 constant SENTINEL_L = 1e15;
    int24 constant LO = -887220;
    int24 constant HI = 887220;
    bytes32 constant CAL_TOPIC = keccak256("Calibrated(bytes32,int128,int128,uint160)");

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        eligibility = new EligibilityRegistry(address(this), 4, 0.03 ether, 600);
        tickerNFT = new TickerNFT("Clog V4 Tickers", "CLOGV4", deployer, "https://example.invalid/", multisig);
        registry = new TickerRegistryV4(address(eligibility), address(tickerNFT), multisig, 9 ether, 20_000);

        bytes32 initHash = HookMinerV2.hashInitCode(
            abi.encodePacked(type(ClogV4HookV2).creationCode, abi.encode(IPoolManager(address(manager)), address(registry), ops))
        );
        (, bytes32 salt) = HookMinerV2.find(vm, address(this), initHash, 400_000);
        hook = new ClogV4HookV2{salt: salt}(IPoolManager(address(manager)), address(registry), ops);

        rewardVault = new RewardVault(makeAddr("roundManager"), address(manager), address(hook));
        registry.setV4Infrastructure(address(manager), address(hook), address(rewardVault));
        vm.prank(deployer);
        tickerNFT.setRegistry(address(registry));

        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        (tokenId, market, token, key) = _launch("SIGMAX");
        ref = new ClogMarket(address(this), address(token), address(tickerNFT), tokenId, multisig, 9 ether, 20_000, address(new NoopEligibility()));
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────

    function _launch(string memory ticker) internal returns (uint256 id, ClogMarket m, MemeToken t, PoolKey memory k) {
        bytes32 s = keccak256(abi.encode("entropy", ticker));
        vm.prank(launcher);
        registry.commit(keccak256(abi.encode(launcher, keccak256(bytes(ticker)), s)));
        vm.warp(vm.getBlockTimestamp() + registry.MIN_REVEAL_DELAY());
        uint256 price = registry.LAUNCH_PRICE();
        vm.deal(launcher, launcher.balance + price);
        vm.prank(launcher);
        id = registry.reveal{value: price}(ticker, s);
        m = ClogMarket(registry.marketOf(id));
        t = MemeToken(registry.tokenOf(id));
        k = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
    }

    function _slot0(PoolKey memory k) internal view returns (uint160 px) {
        (px,,,) = IPoolManager(address(manager)).getSlot0(k.toId());
    }

    function _calFromLogs(Vm.Log[] memory logs) internal view returns (int128 a0, int128 a1) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length == 2 && logs[i].topics[0] == CAL_TOPIC) {
                (a0, a1,) = abi.decode(logs[i].data, (int128, int128, uint160));
            }
        }
    }

    function _swap(address who, PoolKey memory k, bool zeroForOne, uint256 amt) internal returns (BalanceDelta d) {
        if (zeroForOne) vm.deal(who, who.balance + amt);
        vm.startPrank(who);
        if (!zeroForOne) MemeToken(Currency.unwrap(k.currency1)).approve(address(swapRouter), type(uint256).max);
        d = swapRouter.swap{value: zeroForOne ? amt : 0}(
            k,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amt), sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev One outer trade on the main pool through the standard router, checked against the
    ///      canonical reference and every invariant.
    function _trade(address who, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        uint256 le0 = hook.operatingFundEth(key.toId());
        uint256 lt0 = hook.operatingFundToken(key.toId());
        vm.recordLogs();
        BalanceDelta d = _swap(who, key, zeroForOne, amt);
        (int128 a0, int128 a1) = _calFromLogs(vm.getRecordedLogs());
        if (zeroForOne) {
            (uint256 r,) = ref.applyBuy(amt);
            out = uint256(int256(d.amount1()));
            assertEq(out, r, "user tokens == canonical");
            assertEq(d.amount0(), -int128(int256(amt)), "user pays exactly the input");
        } else {
            (uint256 r,,) = ref.applySell(amt);
            out = uint256(int256(d.amount0()));
            assertEq(out, r, "user ETH == canonical");
        }
        _assertCanonical();
        assertEq(int256(hook.operatingFundEth(key.toId())) - int256(le0), int256(a0), "ledger ETH == calibration amount0");
        assertEq(int256(hook.operatingFundToken(key.toId())) - int256(lt0), int256(a1), "ledger token == calibration amount1");
    }

    function _assertCanonical() internal view {
        assertEq(_slot0(key), hook.canonicalSqrtPriceX96(address(market)), "slot0 == canonical");
        assertEq(market.re(), ref.re(), "re");
        assertEq(market.rt(), ref.rt(), "rt");
        assertEq(market.k(), ref.k(), "k");
        assertEq(market.sold(), ref.sold(), "sold");
        assertEq(market.hwm(), ref.hwm(), "hwm");
        assertEq(market.clogRemaining(), ref.clogRemaining(), "clogRemaining");
        assertEq(market.rtCeiling(), ref.rtCeiling(), "rtCeiling");
        assertEq(market.realETH(), ref.realETH(), "realETH");
        assertEq(market.physicalInventory(), ref.physicalInventory(), "physicalInventory");
        address owner = tickerNFT.ownerOf(tokenId);
        assertEq(market.pendingWithdrawals(owner), ref.pendingWithdrawals(owner), "owner credit");
        assertEq(market.pendingWithdrawals(multisig), ref.pendingWithdrawals(multisig), "multisig credit");
        assertEq(manager.balanceOf(address(market), 0), market.realETH() + market.pendingWithdrawals(owner) + market.pendingWithdrawals(multisig), "ETH claim conservation");
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(token)))), market.physicalInventory(), "token claim conservation");
        assertGe(address(hook).balance, hook.totalOperatingFundEth(), "raw ETH >= ledger");
        assertGe(token.balanceOf(address(hook)), hook.operatingFundToken(key.toId()), "raw token >= ledger");
    }

    /// @dev ops bootstraps tokens THROUGH the taxed curve (L=0 -> free calibration), installs
    ///      the sentinel, and funds the operating fund explicitly.
    function _bootstrap() internal {
        _trade(ops, true, 0.01 ether);
        vm.startPrank(ops);
        token.approve(address(hook), type(uint256).max);
        vm.deal(ops, ops.balance + 1 ether);
        hook.modifySentinel{value: 1 ether}(key, int256(SENTINEL_L));
        hook.depositOperatingFund{value: 0.001 ether}(key, 1_000e18);
        vm.stopPrank();
    }

    function _wrapped(bytes4 cb, string memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, address(hook), cb, abi.encodeWithSignature("Error(string)", reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ── launch / mask / initial price ───────────────────────────────────────────────────────

    function test_launch_maskVerified_initialSlot0Canonical_noLiquidity() public view {
        uint160 mask = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        assertEq(mask, 0x2AC8, "mask from Hooks.sol constants");
        assertEq(uint160(address(hook)) & uint160((1 << 14) - 1), mask, "mined hook address carries exactly the mask");
        assertEq(_slot0(key), hook.canonicalSqrtPriceX96(address(market)), "launch initializes at canonical price");
        assertEq(_slot0(key), 1120455419495722798374638764549163, "= sqrt(1.8e27/9e18)*2^96, NOT Q96");
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0, "no liquidity until ops installs the sentinel");
        assertEq(eligibility.tokenMarket(tokenId), address(market), "eligibility association");
    }

    // ── sentinel lifecycle / funding interface ──────────────────────────────────────────────

    function test_sentinelInstall_exactAmounts_excessRefunded_noSilentDonation() public {
        _trade(ops, true, 0.01 ether);
        vm.startPrank(ops);
        token.approve(address(hook), type(uint256).max);
        vm.deal(ops, ops.balance + 1 ether);
        uint256 ethBefore = ops.balance;
        uint256 tokBefore = token.balanceOf(ops);
        uint160 p = _slot0(key);
        (int128 a0, int128 a1) = hook.modifySentinel{value: 1 ether}(key, int256(SENTINEL_L));
        vm.stopPrank();
        uint256 expEth = SqrtPriceMath.getAmount0Delta(p, TickMath.getSqrtPriceAtTick(HI), uint128(SENTINEL_L), true);
        uint256 expTok = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(LO), p, uint128(SENTINEL_L), true);
        assertEq(uint256(int256(-a0)), expEth, "ETH == v4 full-range composition at canonical price");
        assertEq(uint256(int256(-a1)), expTok, "token == v4 full-range composition at canonical price");
        assertEq(ethBefore - ops.balance, expEth, "only the exact ETH cost left ops (excess refunded)");
        assertEq(tokBefore - token.balanceOf(ops), expTok, "only the exact token cost left ops");
        assertEq(hook.operatingFundEth(key.toId()), 0, "overpayment did NOT become an operating-fund donation");
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), SENTINEL_L, "active liquidity == L");
        emit log_named_uint("sentinel ETH (wei) at L=1e15, canonical start", expEth);
        emit log_named_uint("sentinel token (wei) at L=1e15, canonical start", expTok);
    }

    function test_sentinelAdd_msgValueTooLow_revertsEvenWithLedgerEth() public {
        _bootstrap();
        vm.startPrank(ops);
        vm.expectRevert(bytes("msg.value below sentinel ETH cost"));
        hook.modifySentinel{value: 1}(key, int256(SENTINEL_L));
        vm.stopPrank();
    }

    function test_sentinel_partialRemove_fullRemove_noDuplicate_overRemoveReverts() public {
        _bootstrap();
        vm.startPrank(ops);
        vm.deal(ops, ops.balance + 1 ether);
        hook.modifySentinel{value: 1 ether}(key, int256(SENTINEL_L)); // second add
        vm.stopPrank();
        (uint128 posL,,) = IPoolManager(address(manager)).getPositionInfo(key.toId(), address(hook), LO, HI, hook.SENTINEL_SALT());
        assertEq(posL, 2 * SENTINEL_L, "two adds accumulate in ONE position (no duplicate)");
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 2 * SENTINEL_L, "active liquidity == sum");

        uint256 opsEth = ops.balance;
        uint256 opsTok = token.balanceOf(ops);
        vm.prank(ops);
        (int128 r0, int128 r1) = hook.modifySentinel(key, -int256(SENTINEL_L));
        assertEq(ops.balance - opsEth, uint256(int256(r0)), "partial removal ETH -> sentinelManager");
        assertEq(token.balanceOf(ops) - opsTok, uint256(int256(r1)), "partial removal token -> sentinelManager");
        assertEq(hook.sentinelLiquidity(key.toId()), uint128(SENTINEL_L), "half remains");

        vm.prank(ops);
        vm.expectRevert(bytes("exceeds sentinel liquidity"));
        hook.modifySentinel(key, -int256(SENTINEL_L + 1));

        vm.prank(ops);
        hook.modifySentinel(key, -int256(SENTINEL_L));
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0, "fully removed");
        _trade(alice, true, 0.01 ether); // still trades & calibrates exactly at L = 0
    }

    // ── F: liquidity gating / attacks ───────────────────────────────────────────────────────

    function test_F_eoaCannotCallModifyLiquidityDirectly() public {
        vm.prank(attacker);
        vm.expectRevert(); // ManagerLocked - an EOA can never hold an unlock session
        manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: 1e15, salt: 0}), "");
    }

    function test_F_routerCannotAddLiquidity_senderIsRouter() public {
        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, "liquidity is protocol-managed"));
        lpRouter.modifyLiquidity{value: 1 ether}(key, IPoolManager.ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: 1e15, salt: 0}), "");
    }

    function test_F_arbitraryContractCannotAddLiquidity() public {
        AttackerLP a = new AttackerLP(IPoolManager(address(manager)));
        vm.deal(address(a), 10 ether);
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, "liquidity is protocol-managed"));
        a.add(key, 1e15, bytes32(0));
        // even claiming the sentinel's own salt changes nothing: positions are keyed by the
        // caller (owner), so this would be the attacker's position, and the gate rejects it first
        bytes32 sentinelSalt = hook.SENTINEL_SALT();
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, "liquidity is protocol-managed"));
        a.add(key, 1e15, sentinelSalt);
    }

    function test_F_attackerCannotRemoveSentinel() public {
        _bootstrap();
        bytes32 sentinelSalt = hook.SENTINEL_SALT();
        vm.prank(attacker);
        vm.expectRevert(_wrapped(IHooks.beforeRemoveLiquidity.selector, "liquidity is protocol-managed"));
        lpRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: -int256(SENTINEL_L), salt: sentinelSalt}), "");
        AttackerLP a = new AttackerLP(IPoolManager(address(manager)));
        vm.expectRevert(_wrapped(IHooks.beforeRemoveLiquidity.selector, "liquidity is protocol-managed"));
        a.remove(key, SENTINEL_L, sentinelSalt);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), SENTINEL_L, "sentinel intact");
    }

    function test_F_directCallbacksAndSpoofedSender_rejected() public {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: 1, salt: 0});
        vm.startPrank(attacker);
        vm.expectRevert(bytes("not pool manager"));
        hook.beforeAddLiquidity(address(hook), key, p, ""); // spoofed sender = hook
        vm.expectRevert(bytes("not pool manager"));
        hook.beforeRemoveLiquidity(address(hook), key, p, "");
        vm.expectRevert(bytes("not pool manager"));
        hook.beforeSwap(attacker, key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}), "");
        vm.expectRevert(bytes("not pool manager"));
        hook.afterSwap(attacker, key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}), BalanceDelta.wrap(0), "");
        vm.expectRevert(bytes("not pool manager"));
        hook.beforeInitialize(address(registry), key, 1);
        vm.expectRevert(bytes("not pool manager"));
        hook.unlockCallback(abi.encode(uint8(3), abi.encode(key, int256(1), attacker)));
        vm.stopPrank();
    }

    function test_F_noAccessToHookSelfCallPrivilege() public {
        _bootstrap();
        vm.startPrank(attacker);
        vm.deal(attacker, 10 ether);
        vm.expectRevert(bytes("not sentinel manager"));
        hook.modifySentinel{value: 1 ether}(key, int256(1e20)); // the old DoS-by-inflating-L path
        vm.expectRevert(bytes("not sentinel manager"));
        hook.withdrawOperatingFund(key, 1, 0, attacker);
        vm.expectRevert(bytes("not a registered market"));
        hook.executeWithdrawal(attacker, 1);
        vm.expectRevert(bytes("not launch initializer"));
        hook.depositMarketInventory(address(market), address(token), key);
        vm.expectRevert(bytes("not launch initializer"));
        hook.registerMarket(key, address(market));
        vm.stopPrank();
    }

    function test_F_frontrunInstall_and_sandwich_extractNothingBeyondCanonical() public {
        // attacker trades right before the install: install still happens at canonical price
        _trade(ops, true, 0.01 ether);
        _trade(attacker, true, 0.2 ether);
        uint160 p = _slot0(key);
        assertEq(p, hook.canonicalSqrtPriceX96(address(market)), "slot0 canonical before install, whatever was traded");
        vm.startPrank(ops);
        token.approve(address(hook), type(uint256).max);
        vm.deal(ops, ops.balance + 1 ether);
        (int128 a0, int128 a1) = hook.modifySentinel{value: 1 ether}(key, int256(SENTINEL_L));
        hook.depositOperatingFund{value: 0.001 ether}(key, 1_000e18);
        vm.stopPrank();
        assertEq(uint256(int256(-a0)), SqrtPriceMath.getAmount0Delta(p, TickMath.getSqrtPriceAtTick(HI), uint128(SENTINEL_L), true), "install ETH deterministic");
        assertEq(uint256(int256(-a1)), SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(LO), p, uint128(SENTINEL_L), true), "install token deterministic");

        // sandwich: attacker buy -> victim buy -> attacker sell; each leg == canonical CLOG
        uint256 aTok = _trade(attacker, true, 0.3 ether);
        _trade(alice, true, 0.1 ether);
        _trade(attacker, false, aTok);
        (uint128 posL,,) = IPoolManager(address(manager)).getPositionInfo(key.toId(), address(hook), LO, HI, hook.SENTINEL_SALT());
        assertEq(posL, SENTINEL_L, "sentinel liquidity untouched by user trades");
    }

    // ── standard-router multi-trade on the production hook ──────────────────────────────────

    function test_standardRouter_manySequentialTrades_exact() public {
        _bootstrap();
        uint256 bought;
        for (uint256 i = 0; i < 8; i++) bought += _trade(alice, true, 0.02 ether + i * 1e15);
        for (uint256 i = 0; i < 8; i++) _trade(alice, false, bought / 10);
        for (uint256 i = 0; i < 6; i++) {
            uint256 got = _trade(attacker, true, 0.05 ether);
            _trade(attacker, false, got / 2);
        }
    }

    // ── ledger-governed atomic failure on the production hook ───────────────────────────────

    struct ESnap {
        uint256 streak;
        bool cand;
        uint256 cpUser;
        uint256 balUser;
        uint256 re;
        uint256 realETH;
        uint160 px;
        uint256 ledEth;
        uint256 ledTok;
    }

    function _esnap(address who) internal view returns (ESnap memory s) {
        s.streak = eligibility.aboveThresholdSince(tokenId);
        s.cand = eligibility.isCandidate(eligibility.currentRoundId(), tokenId);
        s.cpUser = token.checkpointCount(who);
        s.balUser = token.balanceOf(who);
        s.re = market.re();
        s.realETH = market.realETH();
        s.px = _slot0(key);
        s.ledEth = hook.operatingFundEth(key.toId());
        s.ledTok = hook.operatingFundToken(key.toId());
    }

    function _esnapEq(ESnap memory a, ESnap memory b) internal pure {
        assertEq(a.streak, b.streak, "eligibility streak");
        assertEq(a.cand, b.cand, "candidate");
        assertEq(a.cpUser, b.cpUser, "checkpoints");
        assertEq(a.balUser, b.balUser, "token balance");
        assertEq(a.re, b.re, "re");
        assertEq(a.realETH, b.realETH, "realETH");
        assertEq(a.px, b.px, "slot0");
        assertEq(a.ledEth, b.ledEth, "ledger ETH");
        assertEq(a.ledTok, b.ledTok, "ledger token");
    }

    function _dryCal(address who, bool z, uint256 amt) internal returns (int128 a0, int128 a1) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _swap(who, key, z, amt);
        (a0, a1) = _calFromLogs(vm.getRecordedLogs());
        vm.revertToState(snap);
    }

    function test_ledgerShort_buy_revertsAtomically_strayRawEthDoesNotHelp() public {
        _bootstrap();
        (int128 a0,) = _dryCal(alice, true, 0.05 ether);
        uint256 needed = uint256(int256(-a0));
        uint256 wEth = hook.operatingFundEth(key.toId()) - (needed - 1);
        vm.prank(ops);
        hook.withdrawOperatingFund(key, wEth, 0, ops);
        vm.deal(address(hook), address(hook).balance + 10 ether); // stray, un-ledgered raw ETH
        vm.deal(alice, alice.balance + 0.05 ether);
        ESnap memory before = _esnap(alice);
        vm.prank(alice);
        vm.expectRevert(_wrapped(IHooks.afterSwap.selector, "operating fund ETH insufficient"));
        swapRouter.swap{value: 0.05 ether}(
            key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -0.05 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        _esnapEq(before, _esnap(alice));
    }

    function test_ledgerShort_sell_revertsAtomically_strayRawTokenDoesNotHelp() public {
        _bootstrap();
        uint256 got = _trade(alice, true, 0.05 ether);
        (, int128 a1) = _dryCal(alice, false, got);
        uint256 needed = uint256(int256(-a1));
        uint256 wTok = hook.operatingFundToken(key.toId()) - (needed - 1);
        vm.prank(ops);
        hook.withdrawOperatingFund(key, 0, wTok, ops);
        vm.prank(ops);
        token.transfer(address(hook), 1_000e18); // stray, un-ledgered raw token
        ESnap memory before = _esnap(alice);
        vm.startPrank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert(_wrapped(IHooks.afterSwap.selector, "operating fund token insufficient"));
        swapRouter.swap(
            key, IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(got), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        vm.stopPrank();
        _esnapEq(before, _esnap(alice));
    }

    // ── cross-market isolation ──────────────────────────────────────────────────────────────

    function test_crossMarket_ledgersIsolated() public {
        _bootstrap();
        (, ClogMarket mB, MemeToken tB, PoolKey memory kB) = _launch("SIGMAY");
        assertEq(_slot0(kB), hook.canonicalSqrtPriceX96(address(mB)), "B launches canonical");
        _swap(ops, kB, true, 0.01 ether);
        vm.startPrank(ops);
        tB.approve(address(hook), type(uint256).max);
        vm.deal(ops, ops.balance + 20 ether);
        hook.modifySentinel{value: 1 ether}(kB, int256(SENTINEL_L));
        hook.depositOperatingFund{value: 10 ether}(kB, 1_000e18);
        vm.stopPrank();

        (int128 a0,) = _dryCal(alice, true, 0.05 ether);
        uint256 wEthA = hook.operatingFundEth(key.toId()) - (uint256(int256(-a0)) - 1);
        vm.prank(ops);
        hook.withdrawOperatingFund(key, wEthA, 0, ops);
        assertGt(hook.totalOperatingFundEth(), 10 ether, "plenty of ETH in the hook - but it is B's");
        uint256 bLedger = hook.operatingFundEth(kB.toId());

        vm.deal(alice, alice.balance + 0.05 ether);
        vm.prank(alice);
        vm.expectRevert(_wrapped(IHooks.afterSwap.selector, "operating fund ETH insufficient"));
        swapRouter.swap{value: 0.05 ether}(
            key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -0.05 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        assertEq(hook.operatingFundEth(kB.toId()), bLedger, "A could not draw on B's ledger");

        _swap(alice, kB, true, 0.05 ether);
        assertEq(_slot0(kB), hook.canonicalSqrtPriceX96(address(mB)), "B still trades & calibrates exactly");
    }

    // ── market pull-withdrawal still works through the V2 hook ──────────────────────────────

    function test_marketWithdraw_viaV2Hook() public {
        _bootstrap();
        _trade(alice, true, 0.05 ether);
        address owner = tickerNFT.ownerOf(tokenId);
        uint256 pending = market.pendingWithdrawals(owner);
        uint256 before = owner.balance;
        market.withdraw(owner);
        assertEq(owner.balance - before, pending, "owner receives exactly the pending credit");
        assertEq(manager.balanceOf(address(market), 0), market.realETH() + market.pendingWithdrawals(multisig), "claim conservation after withdraw");
    }
}

/// @dev Arbitrary third-party contract holding its own unlock session.
contract AttackerLP is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function add(PoolKey memory k, uint256 l, bytes32 salt) external {
        pm.unlock(abi.encode(k, int256(l), salt));
    }

    function remove(PoolKey memory k, uint256 l, bytes32 salt) external {
        pm.unlock(abi.encode(k, -int256(l), salt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory k, int256 l, bytes32 salt) = abi.decode(data, (PoolKey, int256, bytes32));
        pm.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: l, salt: salt}), "");
        return "";
    }

    receive() external payable {}
}
