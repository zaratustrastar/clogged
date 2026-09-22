// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ClogV4Hook} from "../../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {SentinelLiquidityHelper as SentinelLiquidityHelperForTest} from "./fixtures/SentinelLiquidityHelperV1.sol";

/// @notice IMPORTANT LIMITATION, stated plainly: this is a LOCAL SIMULATION standing in for the
///         real Robinhood-fork test, not the fork test itself. This sandbox has no network path
///         to any Robinhood Chain RPC endpoint (chainId 4663) at all - it cannot fork the real
///         chain, cannot see the real live canary pool's actual current state, and cannot
///         confirm the real deployed hook/token bytecode matches what's in this repo. What this
///         DOES prove: given a pool and hook built to the exact same specification as the live
///         canary (same flag bits 0x2088, same non-custodial ClogMarket accounting, same
///         SentinelLiquidityHelper contract file used verbatim - not a rewritten copy), the
///         proposed sentinel-liquidity probe sequence behaves exactly as intended, step by
///         step. This test imports the frozen V1 SentinelLiquidityHelper fixture directly,
///         preserving the exact historical helper logic while keeping obsolete V1 operational
///         tooling out of the live script-v4 directory. The actual fork run against the real RPC is something only an environment
///         with that network access can perform - see this response's own accompanying
///         instructions for the exact commands to run it there.
contract SentinelProbeForkSimulation is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    ClogV4Hook hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;
    SentinelLiquidityHelperForTest helper;

    address deployer = makeAddr("deployer");
    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    uint256 constant TICKER_TOKEN_ID = 1;
    address constant HOOK_ADDRESS = address(0x2088);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;
    int256 constant SENTINEL_LIQUIDITY = 1_000;
    bytes32 constant SENTINEL_SALT = keccak256("CLOG_SENTINEL_LIQUIDITY_PROBE_V1");

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));

        // Deliberately reproduces the canary's own reported condition: legacy 1:1 price,
        // tick 0, zero liquidity - this simulation does NOT attempt to fix that (no
        // calibration anywhere in this file, matching the explicit instruction).
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336); // price = 1, tick = 0

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();

        helper = new SentinelLiquidityHelperForTest(IPoolManager(address(manager)), deployer);
        vm.deal(deployer, 100 ether);
        token.mint(deployer, 1_000_000e18);
    }

    struct SwapRequest {
        bool zeroForOne;
        int256 amountSpecified;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not pool manager");
        if (_depositing) {
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), PHYSICAL_TOKEN_SUPPLY);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), PHYSICAL_TOKEN_SUPPLY);
            return bytes("");
        }
        SwapRequest memory req = abi.decode(data, (SwapRequest));
        BalanceDelta swapDelta = manager.swap(
            key, IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: req.amountSpecified, sqrtPriceLimitX96: 4295128740}), bytes("")
        );
        int128 ethOwed = -swapDelta.amount0();
        manager.sync(key.currency0);
        manager.settle{value: uint256(int256(ethOwed))}();
        int128 tokenOwed = swapDelta.amount1();
        manager.take(key.currency1, address(this), uint256(int256(tokenOwed)));
        return abi.encode(swapDelta);
    }

    receive() external payable {}

    function _slot0AndLiquidity() internal view returns (uint160 price, int24 tick, uint128 liquidity) {
        (price, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        liquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
    }

    /// @dev A real quote via the standard V4Quoter-style revert pattern (same as
    ///      StandardRouterIntegration.t.sol's own StandardV4QuoterMirror) - runs the real swap
    ///      inside unlock(), then reverts the entire call so nothing is ever committed.
    function _quoteBuy(uint256 ethAmount) internal returns (uint256 tokensOut) {
        try this.externalQuoteBuy(ethAmount) {
            revert("quote unexpectedly succeeded without reverting");
        } catch (bytes memory reason) {
            require(reason.length == 36, "unexpected revert shape");
            bytes memory inner = new bytes(32);
            for (uint256 i = 0; i < 32; i++) inner[i] = reason[i + 4];
            tokensOut = abi.decode(inner, (uint256));
        }
    }

    error QuoteResult(uint256 tokensOut);

    function externalQuoteBuy(uint256 ethAmount) external {
        require(msg.sender == address(this), "test-only");
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(ethAmount)})));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        revert QuoteResult(uint256(int256(delta.amount1())));
    }

    /// @notice The full 10-step sequence, run in order, each step's own assertion checked
    ///         explicitly before moving to the next.
    function test_fullTenStepSequence() public {
        // ── Step 1: snapshot slot0, active liquidity, deployer balances ─────────────────────
        (uint160 priceStep1, int24 tickStep1, uint128 liquidityStep1) = _slot0AndLiquidity();
        uint256 deployerEthStep1 = deployer.balance;
        uint256 deployerTokenStep1 = token.balanceOf(deployer);
        emit log_string("=== STEP 1: initial snapshot ===");
        emit log_named_uint("  sqrtPriceX96", priceStep1);
        emit log_named_int("  tick", tickStep1);
        emit log_named_uint("  active liquidity", liquidityStep1);
        emit log_named_uint("  deployer ETH (wei)", deployerEthStep1);
        emit log_named_uint("  deployer CANARY (wei)", deployerTokenStep1);
        assertEq(liquidityStep1, 0, "sanity: must genuinely start at zero liquidity, matching the canary's own reported state");

        // ── Step 2: quote a 0.001 ETH CLOG buy BEFORE sentinel liquidity ────────────────────
        uint256 buyAmount = 0.001 ether;
        uint256 quoteBefore = _quoteBuy(buyAmount);
        emit log_string("=== STEP 2: quote BEFORE sentinel ===");
        emit log_named_uint("  quoted tokens out", quoteBefore);
        assertGt(quoteBefore, 0, "sanity: the quote must be genuinely nonzero");

        // ── Step 3: add ONLY L = 1,000 ────────────────────────────────────────────────────────
        vm.startPrank(deployer);
        token.approve(address(helper), type(uint256).max);
        (int256 addAmount0, int256 addAmount1) = helper.addLiquidity{value: 1e12}(
            SentinelLiquidityHelperForTest.AddParams({key: key, tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: SENTINEL_LIQUIDITY, salt: SENTINEL_SALT, payer: deployer})
        );
        vm.stopPrank();
        emit log_string("=== STEP 3: sentinel liquidity added ===");
        emit log_named_int("  exact ETH contributed (wei)", -addAmount0);
        emit log_named_int("  exact CANARY contributed (wei)", -addAmount1);

        // ── Step 4: confirm active liquidity changes from 0 -> 1,000 ────────────────────────
        (, , uint128 liquidityStep4) = _slot0AndLiquidity();
        emit log_string("=== STEP 4: liquidity after add ===");
        emit log_named_uint("  active liquidity", liquidityStep4);
        assertEq(liquidityStep4, uint256(SENTINEL_LIQUIDITY), "active liquidity must be EXACTLY 1,000 after adding the sentinel - neither more nor less");

        // ── Step 5: confirm sqrtPriceX96 and tick do NOT change merely from adding liquidity ──
        (uint160 priceStep5, int24 tickStep5,) = _slot0AndLiquidity();
        emit log_string("=== STEP 5: price/tick after add (must be unchanged) ===");
        emit log_named_uint("  sqrtPriceX96", priceStep5);
        emit log_named_int("  tick", tickStep5);
        assertEq(priceStep5, priceStep1, "adding liquidity alone must never move sqrtPriceX96");
        assertEq(tickStep5, tickStep1, "adding liquidity alone must never move tick");

        // ── Step 6: quote the SAME 0.001 ETH buy again - byte-for-byte identical output ─────
        uint256 quoteAfter = _quoteBuy(buyAmount);
        emit log_string("=== STEP 6: quote AFTER sentinel ===");
        emit log_named_uint("  quoted tokens out", quoteAfter);
        assertEq(quoteAfter, quoteBefore, "CONFIRMED: the quote must be BYTE-FOR-BYTE IDENTICAL before and after sentinel liquidity - the sentinel changes nothing about CLOG's own real output");

        // ── Step 7: execute the CLOG buy, prove sentinel LP principal is unchanged ──────────
        uint256 helperTokenClaimBefore = manager.balanceOf(address(helper), uint256(uint160(address(token))));
        uint256 helperEthClaimBefore = manager.balanceOf(address(helper), uint256(uint160(address(0))));
        vm.deal(address(this), buyAmount);
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(buyAmount)})));
        BalanceDelta actualDelta = abi.decode(result, (BalanceDelta));
        uint256 actualTokensOut = uint256(int256(actualDelta.amount1()));
        uint256 helperTokenClaimAfter = manager.balanceOf(address(helper), uint256(uint160(address(token))));
        uint256 helperEthClaimAfter = manager.balanceOf(address(helper), uint256(uint160(address(0))));
        emit log_string("=== STEP 7: real CLOG buy executed ===");
        emit log_named_uint("  actual tokens out", actualTokensOut);
        assertEq(actualTokensOut, quoteBefore, "the REAL executed buy's output must match the quote exactly");
        assertEq(helperTokenClaimAfter, helperTokenClaimBefore, "sentinel LP's own token claim must be completely unchanged by the real CLOG buy");
        assertEq(helperEthClaimAfter, helperEthClaimBefore, "sentinel LP's own ETH claim must be completely unchanged by the real CLOG buy");

        // ── Step 8: remove the entire sentinel position ─────────────────────────────────────
        vm.prank(deployer);
        (int256 removeAmount0, int256 removeAmount1) = helper.removeLiquidity(
            SentinelLiquidityHelperForTest.RemoveParams({key: key, tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -SENTINEL_LIQUIDITY, salt: SENTINEL_SALT, recipient: deployer})
        );
        emit log_string("=== STEP 8: sentinel liquidity removed ===");
        emit log_named_int("  exact ETH returned (wei)", removeAmount0);
        emit log_named_int("  exact CANARY returned (wei)", removeAmount1);

        // ── Step 9: confirm active liquidity returns exactly to 0 ───────────────────────────
        (, , uint128 liquidityStep9) = _slot0AndLiquidity();
        emit log_string("=== STEP 9: liquidity after removal ===");
        emit log_named_uint("  active liquidity", liquidityStep9);
        assertEq(liquidityStep9, 0, "active liquidity must return to EXACTLY zero after full removal");

        // ── Step 10: confirm recovered probe assets and any rounding dust ──────────────────
        uint256 deployerEthStep10 = deployer.balance;
        uint256 deployerTokenStep10 = token.balanceOf(deployer);
        int256 ethRoundTrip = int256(deployerEthStep10) - int256(deployerEthStep1);
        int256 tokenRoundTrip = int256(deployerTokenStep10) - int256(deployerTokenStep1);
        emit log_string("=== STEP 10: full round-trip accounting ===");
        emit log_named_uint("  deployer ETH after (wei)", deployerEthStep10);
        emit log_named_uint("  deployer CANARY after (wei)", deployerTokenStep10);
        emit log_named_int("  net ETH change across the whole probe (wei) - should be <=0, dust/rounding only", ethRoundTrip);
        emit log_named_int("  net CANARY change across the whole probe (wei) - should be <=0, dust/rounding only", tokenRoundTrip);
        // The deployer must never end up with MORE than they started with (that would mean
        // value was created from nothing, a bug) - any shortfall is legitimate rounding dust
        // from the add/remove liquidity math, expected to be at most a few wei.
        assertLe(ethRoundTrip, 0, "deployer must never gain ETH from a pure add-then-remove round trip");
        assertLe(tokenRoundTrip, 0, "deployer must never gain CANARY from a pure add-then-remove round trip");
        assertGe(ethRoundTrip, -10, "any ETH rounding dust should be a handful of wei at most, not a meaningful loss");
        assertGe(tokenRoundTrip, -10, "any CANARY rounding dust should be a handful of wei at most, not a meaningful loss");
    }
}
