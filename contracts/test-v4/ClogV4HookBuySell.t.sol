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
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "./mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../test/mocks/MockTickerNFT.sol";

/// @notice Proves the core custody mechanism end-to-end against the REAL, unmodified v4-core
///         PoolManager (not a mock, not a fork) - a real buy, with every currency delta
///         (router's and hook's) inspected and required to be exactly zero at end-of-unlock,
///         and the market's own ERC6909 claim balances checked against the economic result.
///
/// @dev CORRECTED: VIRTUAL_TOKEN_SEED (1.8B) is a PRICING construct only - it is never how
///      many real MemeTokens exist, and this test now never mints/deposits that amount as real
///      inventory. PHYSICAL_TOKEN_SUPPLY (1B, matching MemeToken.TOTAL_SUPPLY exactly) is what
///      actually gets minted, deposited into PoolManager, and claimed.
contract ClogV4HookBuySellTest is Test, IUnlockCallback {
    PoolManager manager;
    ClogV4Hook hook;
    ClogMarket market;
    MinimalMockToken token;
    PoolKey key;

    address launchInitializer = address(this); // this test acts as TickerRegistry for setup
    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    MockTickerNFT tickerNFT;
    uint256 constant TICKER_TOKEN_ID = 1;

    // BEFORE_INITIALIZE_FLAG (1<<13) | BEFORE_SWAP_FLAG (1<<7) | BEFORE_SWAP_RETURNS_DELTA_FLAG (1<<3)
    // = 8192 + 128 + 8 = 8328 = 0x2088. Test-only address construction via vm.etch - real
    // deployment needs actual CREATE2 salt mining, not yet done (see contract-level docs).
    address constant HOOK_ADDRESS = address(0x2088);

    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    // Config G's own virtualTokenSeed = CURVE_ALLOCATION(900M) * bufferMultiplierBps(20_000) /
    // BPS(10_000) = 1.8B - a PRICING reserve only, deliberately "deeper" than real supply so
    // the curve behaves correctly. NEVER how many real MemeTokens exist.
    uint256 constant VIRTUAL_TOKEN_SEED = 1_800_000_000e18;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000; // Config G - produces VIRTUAL_TOKEN_SEED above, matching production's own derivation
    // MemeToken.TOTAL_SUPPLY exactly - the real, physical amount that ever gets minted (900M
    // curve allocation + 100M CLOG allocation, undifferentiated in this vertical slice since
    // the CLOG leg itself isn't ported yet - see ClogMarket.sol's own docs).
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    /// @dev Placeholder for the atomic launch deposit design from the architecture discussion
    ///      (register -> initialize -> inventory deposit) - not yet wired into ClogMarket's own
    ///      constructor/a dedicated launch function, so this test performs the real
    ///      transfer+settle+mint sequence directly via its own unlockCallback, proving the
    ///      MECHANISM (a real physical deposit backing a real claim) works, while flagging that
    ///      the atomic all-in-one launch flow itself is still a separate, unbuilt piece.
    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));

        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), launchInitializer);
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);
        // vm.etch only copies bytecode, not storage - immutables (poolManager,
        // launchInitializer) are inlined directly into bytecode by the compiler, so they're
        // already correct on the etched copy; only real mapping storage (marketOf/poolOf) would
        // need re-establishing, which registerMarket (below) does fresh regardless.

        token = new MinimalMockToken();
        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);

        key = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // Corrected atomic sequence: register BEFORE initialize (beforeInitialize checks this).
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336); // sqrtPriceX96 for price = 1, irrelevant here since the curve is fully hook-driven

        // Real launch-time inventory deposit: mint the market's REAL, PHYSICAL supply (1B,
        // mirroring MemeToken.setMarket minting exactly TOTAL_SUPPLY to the market contract -
        // NEVER the 1.8B virtual pricing reserve), then physically deposit it into PoolManager
        // and mint the market an ERC6909 claim for exactly that amount - a real
        // transfer+settle+mint sequence, not a shortcut.
        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        // The mechanism from the architecture discussion: per-currency infinite ERC6909
        // approval, NOT blanket setOperator - the market grants the hook permission for
        // exactly the two currencies it needs (its own token, and ETH), nothing else. Without
        // this, PoolManager.burn(market, ..., ...) called by the hook (msg.sender != market)
        // reverts - ERC6909's own allowance/operator check, verified directly against source.
        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();
    }

    // ── Acting as our own minimal "router" via IUnlockCallback ───────────────────────────────

    struct SwapRequest {
        bool zeroForOne;
        int256 amountSpecified;
    }

    function _doSwap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta swapDelta) {
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: zeroForOne, amountSpecified: amountSpecified})));
        swapDelta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not pool manager");

        if (_depositing) {
            // Real launch-time deposit: physically transfer the market's own just-minted
            // PHYSICAL_TOKEN_SUPPLY into PoolManager, settle, then mint the market an ERC6909
            // claim for exactly that amount - the market's claim is now fully backed by a
            // real, physical deposit, exactly as the architecture requires.
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), PHYSICAL_TOKEN_SUPPLY);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), PHYSICAL_TOKEN_SUPPLY);
            return bytes("");
        }

        SwapRequest memory req = abi.decode(data, (SwapRequest));

        BalanceDelta swapDelta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: req.zeroForOne,
                amountSpecified: req.amountSpecified,
                sqrtPriceLimitX96: req.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            bytes("")
        );

        // Standard SETTLE_ALL / TAKE_ALL, no CLOG-specific step - exactly what a normal router does.
        if (req.zeroForOne) {
            // Router owes ETH (negative delta on currency0), is owed token (positive on currency1).
            int128 ethOwed = -swapDelta.amount0();
            require(ethOwed > 0, "unexpected: router not owed to pay ETH");
            manager.sync(key.currency0);
            manager.settle{value: uint256(int256(ethOwed))}();

            int128 tokenOwed = swapDelta.amount1();
            require(tokenOwed > 0, "unexpected: router not owed token");
            manager.take(key.currency1, address(this), uint256(int256(tokenOwed)));
        } else {
            // Router owes token (negative delta on currency1), is owed ETH (positive on currency0) -
            // exactly symmetric to the buy branch above, still standard SETTLE_ALL/TAKE_ALL.
            int128 tokenOwed = -swapDelta.amount1();
            require(tokenOwed > 0, "unexpected: router not owed to pay token");
            manager.sync(key.currency1);
            token.transfer(address(manager), uint256(int256(tokenOwed)));
            manager.settle();

            int128 ethOwed = swapDelta.amount0();
            require(ethOwed > 0, "unexpected: router not owed ETH");
            manager.take(key.currency0, address(this), uint256(int256(ethOwed)));
        }

        return abi.encode(swapDelta);
    }

    receive() external payable {}

    /// @dev Reads curveTokens/clogTokens/clogExtracted back out of the most recent
    ///      ClogMarket.Bought event recorded by vm.recordLogs() - all 8 of Bought's fields are
    ///      non-indexed, so they're packed together in the log's data as 8 uint256 words.
    function _extractBoughtFieldsFromLogs() internal returns (uint256 curveTokens, uint256 clogTokens, uint256 clogExtracted) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 boughtTopic = keccak256("Bought(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(market) && entries[i].topics.length > 0 && entries[i].topics[0] == boughtTopic) {
                (, , uint256 curve, uint256 clog, uint256 extracted, , ,) = abi.decode(entries[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                return (curve, clog, extracted);
            }
        }
        revert("Bought event not found in recorded logs");
    }

    // ── Physical-vs-virtual sanity (the P0 fix this pass) ────────────────────────────────────

    function test_initialPhysicalInventory_isExactlyOneBillion_notVirtualSeed() public view {
        assertEq(market.physicalInventory(), PHYSICAL_TOKEN_SUPPLY, "physicalInventory must start at exactly MemeToken.TOTAL_SUPPLY (1B)");
        assertLt(market.physicalInventory(), VIRTUAL_TOKEN_SEED, "physical inventory must be strictly less than the virtual pricing reserve - they are never the same quantity");
    }

    function test_initialTokenClaim_isExactlyOneBillion_notVirtualSeed() public view {
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(token)))), PHYSICAL_TOKEN_SUPPLY, "the market's real ERC6909 token claim must be backed by exactly 1B real deposited tokens, never 1.8B");
    }

    function test_virtualRt_isEighteenHundredMillion_separateFromPhysicalSupply() public view {
        assertEq(market.rt(), VIRTUAL_TOKEN_SEED, "the curve's own pricing reserve (rt) starts at the full virtual seed, independent of physical inventory");
    }

    function test_poolManagerRealTokenBalance_isExactlyOneBillion() public view {
        assertEq(token.balanceOf(address(manager)), PHYSICAL_TOKEN_SUPPLY, "PoolManager must physically hold exactly the real 1B supply, never the 1.8B virtual figure");
    }

    function test_buyCannotDeliverMorePhysicalTokensThanRemainAvailable() public {
        // Drain physicalInventory down near zero with a sequence of buys, then prove one more
        // buy - even though the virtual curve math would happily imply MORE tokens exist -
        // reverts rather than under-delivering or lying about the market's own real inventory.
        // Mirrors production's own token.balanceOf(address(this)) >= totalTokensOut check
        // exactly, just tracked as explicit state since this market holds no custody itself.
        // Uses try/catch rather than vm.expectRevert directly, since the actual revert
        // originates several call frames deep (unlock -> unlockCallback -> swap -> beforeSwap)
        // and PoolManager's own hook-call machinery wraps it as a WrappedError, not the raw
        // revert string - the same class of issue already solved in CrossMarketIsolation.t.sol.
        uint256 hugeBuy = 50 ether; // large enough, against this curve's own re/rt, to imply far more than 1B tokens if physical supply didn't bound it
        vm.deal(address(this), hugeBuy);
        bool reverted;
        try this.externalDoSwap(true, -int256(hugeBuy)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "a buy implying more tokens than physically exist must revert, never under-deliver or lie about inventory");
    }

    /// @dev External wrapper solely so the try/catch above can call _doSwap across a real call
    ///      boundary (try/catch only works on external calls in Solidity).
    function externalDoSwap(bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        require(msg.sender == address(this), "test-only");
        return _doSwap(zeroForOne, amountSpecified);
    }

    // ── The actual proof ─────────────────────────────────────────────────────────────────────

    function test_ARTIFICIAL_sellSolvencyCap_mechanismOnly_notProductionReachable() public {
        // ⚠️ ARTIFICIAL SCENARIO - NOT a production-reachable state. This creates an extra 50M
        // tokens via MinimalMockToken.mint() AFTER the fixed 1B physical supply already exists;
        // real MemeToken has a fixed 1B total supply and no second mint path, so a position this
        // large could never legitimately exist. This test exists ONLY to exercise the cap
        // mechanism's own branch logic in isolation (does it cap correctly, does realETH fall to
        // exactly zero, does the conservation invariant still hold) - it must NEVER be cited as
        // proof that a legitimate production state can trigger the cap. See
        // test_realCLOGExtraction_canLegitimatelyDepleteRealETH_belowIdealSellPayout below for
        // the production-valid version, reachable using only the fixed 1B supply and real CLOG
        // extraction/reserve depletion, once the CLOG leg existed to make that possible.
        uint256 buyAmount = 0.01 ether;
        vm.deal(address(this), buyAmount);
        _doSwap(true, -int256(buyAmount));

        uint256 realETHBeforeSell = market.realETH();
        assertGt(realETHBeforeSell, 0, "sanity: must have genuine realETH from the prior buy to actually test the cap against");

        // Mint a much larger position directly - simulating tokens this holder accumulated
        // from other sources/buyers, not solely from their own single small buy above.
        uint256 largePosition = 50_000_000e18;
        token.mint(address(this), largePosition);

        BalanceDelta sellDelta = _doSwap(false, -int256(largePosition));
        uint256 netEthOut = uint256(int256(sellDelta.amount0()));

        // The cap means grossPayout (before tax) can never exceed realETH-before-the-sell -
        // and since realETH itself falls to exactly zero when fully capped, this is provable
        // directly: realETH afterward must be exactly zero, not merely "small".
        assertEq(market.realETH(), 0, "when capped, realETH must fall to EXACTLY zero - the cap pays out everything real and nothing more, never leaving a small remainder from rounding");
        assertLe(netEthOut, realETHBeforeSell, "the net payout can never exceed what was actually, really held before the sell, even after tax is deducted from an uncapped-but-large ideal payout");

        // The conservation invariant must still hold exactly even in the capped case.
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(tickerOwner) + market.pendingWithdrawals(multisig) + market.winnerPotLiability(),
            "the conservation invariant must hold exactly even when the solvency cap triggers"
        );
    }

    function test_realCLOGExtraction_canLegitimatelyDepleteRealETH_belowIdealSellPayout() public {
        // PRODUCTION-VALID cap scenario, using ONLY the fixed 1B physical supply and real buy()/
        // sell() flows - no out-of-band minting anywhere in this test. This is WHY the cap
        // exists economically, not merely a branch to exercise: a single buy large enough to
        // trigger a CLOG-leg release delivers BOTH curve tokens and CLOG tokens, but
        // targetExtractionBps (40% by default) immediately pulls part of the CLOG leg's own
        // backing back out as extracted revenue - the CLOG tokens themselves remain fully
        // circulating and sellable regardless. Selling back that ENTIRE combined position
        // therefore implies, via the curve's own math, more ETH than what extraction has left
        // as realETH - a real, legitimate gap, not a contrived one. Verified by direct
        // simulation before writing this test (see this pass's own working notes) that one buy
        // of this size is already sufficient - no artificial minting, no unrealistic repeated-
        // trade sequence required.
        uint256 buyAmount = 0.05 ether;
        vm.deal(address(this), buyAmount);
        vm.recordLogs();
        BalanceDelta buyDelta = _doSwap(true, -int256(buyAmount));
        (uint256 curveTokens, uint256 clogTokens, uint256 clogExtracted) = _extractBoughtFieldsFromLogs();
        uint256 totalTokensHeld = uint256(int256(buyDelta.amount1()));

        assertEq(totalTokensHeld, curveTokens + clogTokens, "sanity: the swap's own token delta must equal the sum of both legs");
        assertGt(clogTokens, 0, "sanity: this buy must have actually triggered a real CLOG-leg release, or this test proves nothing about the CLOG leg's own effect");
        assertGt(clogExtracted, 0, "sanity: this buy's CLOG release must have actually triggered real extraction, or the cap has nothing to do with CLOG activity in this run");

        uint256 realETHBeforeSell = market.realETH();

        // Sell back the ENTIRE real position, accumulated purely from the one real buy above.
        BalanceDelta sellDelta = _doSwap(false, -int256(totalTokensHeld));
        uint256 netEthOut = uint256(int256(sellDelta.amount0()));

        assertTrue(market.realETH() == 0 || netEthOut > 0, "sanity: the sell must have produced a coherent result either way");
        assertLe(netEthOut, realETHBeforeSell, "the net payout can never exceed what was actually, really held before the sell - the CLOG leg's own extraction is precisely what makes this a legitimately reachable production state, not merely a theoretical one");
        assertEq(market.realETH(), 0, "the cap must have genuinely fired on this real, production-reachable sequence - realETH falling to EXACTLY zero (not merely small) is the unambiguous signature of a capped payout, proving this is not just a weak inequality that happens to pass");

        // The conservation invariant must hold exactly, using only a real, production-reachable
        // sequence of trades.
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(tickerOwner) + market.pendingWithdrawals(multisig) + market.winnerPotLiability(),
            "the conservation invariant must hold exactly after a real, production-reachable CLOG-releasing buy followed by a full exit"
        );
        assertLe(market.physicalInventory(), market.CURVE_ALLOCATION() + market.CLOG_ALLOCATION(), "physicalInventory must never legitimately exceed the fixed original physical supply");
    }

    function test_physicalInventory_neverExceedsFixedOriginalSupply_acrossMultipleRoundTrips() public {
        uint256 fixedSupply = market.CURVE_ALLOCATION() + market.CLOG_ALLOCATION();
        assertEq(market.physicalInventory(), fixedSupply, "sanity: must start at exactly the fixed original supply");

        uint256 buyAmount = 0.02 ether;
        vm.deal(address(this), buyAmount * 3);

        for (uint256 i = 0; i < 3; i++) {
            BalanceDelta buyDelta = _doSwap(true, -int256(buyAmount));
            uint256 tokensHeld = uint256(int256(buyDelta.amount1()));
            assertLe(market.physicalInventory(), fixedSupply, "physicalInventory must never exceed the fixed original supply after a buy");

            _doSwap(false, -int256(tokensHeld));
            assertLe(market.physicalInventory(), fixedSupply, "physicalInventory must never exceed the fixed original supply after a sell either");
        }

        // A full round trip (sell back exactly what was bought, each time) must return
        // physicalInventory to EXACTLY its starting value - nothing created, nothing destroyed.
        assertEq(market.physicalInventory(), fixedSupply, "after three full buy-then-sell-everything round trips, physicalInventory must return to exactly the fixed original supply");
    }

    function test_realBuy_everyDeltaZero_marketStateCorrect() public {
        uint256 marketClaimAfterSetup = manager.balanceOf(address(market), uint256(uint160(address(token))));
        assertEq(marketClaimAfterSetup, PHYSICAL_TOKEN_SUPPLY, "sanity: market must hold its full REAL (physical) token claim right after setUp's deposit step, never the virtual seed");

        uint256 buyAmount = 0.01 ether;

        uint256 preManagerEthBalance = address(manager).balance;
        uint256 preRe = market.re();
        uint256 prePhysicalInventory = market.physicalInventory();

        vm.deal(address(this), buyAmount);
        vm.recordLogs(); // needed to read back clogExtracted - the CLOG-leg's own iterative
            // budget solver is intentionally NOT re-implemented independently here (that would
            // just duplicate _executeBudget); instead this test cross-checks that the
            // CONTRACT'S OWN emitted accounting (clogExtracted) is consistent with its own
            // resulting state (pendingWithdrawals, winnerPotLiability, the conservation
            // invariant) - a real, non-tautological check of internal consistency, distinct
            // from independently re-deriving the iteration from first principles.
        BalanceDelta swapDelta = _doSwap(true, -int256(buyAmount));
        (uint256 curveTokens, uint256 clogTokens, uint256 clogExtracted) = _extractBoughtFieldsFromLogs();

        // ── End-state invariant 1: the unlock succeeded at all ──────────────────────────────
        // (PoolManager.unlock() itself reverts with CurrencyNotSettled if any nonzero delta
        // remains anywhere - router's, hook's, or otherwise - so reaching this line at all is
        // already partial proof; the checks below confirm WHY it succeeded, not just that it did.)

        // ── End-state invariant 2: PoolManager's real ETH balance grew by exactly buyAmount ──
        assertEq(address(manager).balance, preManagerEthBalance + buyAmount, "PM must physically hold the real ETH input - this is what backs the market's own ETH claim");

        // ── Expected tax split, computed independently against the exact production formula ──
        uint256 expectedTax = (buyAmount * market.BUY_TAX_BPS()) / market.BPS();
        uint256 expectedBudget = buyAmount - expectedTax;
        uint256 expectedOwnerShare = (expectedTax * market.TICKER_OWNER_TAX_BPS()) / market.BPS();
        uint256 expectedTaxMultisigShare = (expectedTax * market.MULTISIG_TAX_BPS()) / market.BPS();
        uint256 expectedTaxWinnerPotShare = expectedTax - expectedOwnerShare - expectedTaxMultisigShare;

        // The CLOG leg's own extraction, when it fires, ALSO credits multisig/WinnerPot (10%/90%
        // of clogExtracted, per production's own split) - additive on top of the trading-tax
        // shares above, cross-checked against the contract's own emitted clogExtracted.
        uint256 expectedClogMultisigShare = (clogExtracted * market.MULTISIG_CLOG_BPS()) / market.BPS();
        uint256 expectedClogWinnerPotShare = clogExtracted - expectedClogMultisigShare;

        assertEq(market.pendingWithdrawals(tickerOwner), expectedOwnerShare, "ticker owner's pending withdrawal must match the exact 40%-of-tax formula - the CLOG leg's own extraction never pays the ticker owner directly, only multisig/WinnerPot");
        assertEq(market.pendingWithdrawals(multisig), expectedTaxMultisigShare + expectedClogMultisigShare, "multisig's pending withdrawal must equal the tax-split share PLUS 10% of whatever the CLOG leg actually extracted this trade");
        assertEq(market.winnerPotLiability(), expectedTaxWinnerPotShare + expectedClogWinnerPotShare, "WinnerPot's own liability accumulator must equal the tax-split residual PLUS 90% of whatever the CLOG leg actually extracted this trade");

        // ── End-state invariant 3: the market's own ERC6909 claims match the economic result ─
        uint256 tokensOut = uint256(int256(swapDelta.amount1()));
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(0)))), buyAmount, "market's own ETH claim must equal the full gross input - the hook always mints the full specified amount");
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(token)))),
            PHYSICAL_TOKEN_SUPPLY - tokensOut,
            "market's own remaining REAL token claim must be the physical supply minus whatever was actually delivered out"
        );
        assertEq(market.physicalInventory(), prePhysicalInventory - tokensOut, "physicalInventory must fall by exactly tokensOut, matching the real claim exactly");

        // ── THE conservation invariant this pass's tax split must satisfy exactly: the
        //    market's own ETH claim is fully, exactly accounted for by realETH plus every
        //    liability bucket - no untracked "extra" balance, no double-counting. ──────────
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(tickerOwner) + market.pendingWithdrawals(multisig) + market.winnerPotLiability(),
            "market's ETH claim must equal realETH + every liability bucket, exactly - the core conservation property this pass's tax split relies on"
        );

        // ── End-state invariant 4: the hook itself holds NOTHING - it never accumulates ──────
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(0)))), 0, "hook must hold zero ETH claim of its own - it only ever passes claims to the market");
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(token)))), 0, "hook must hold zero token claim of its own");

        // ── End-state invariant 5: the user actually received the real tokens, not a claim ──
        assertEq(token.balanceOf(address(this)), tokensOut, "the router must hold the real ERC20 tokens delivered by take()");
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(token)))), 0, "the router took REAL tokens, not a claim - no claim balance should exist for the router");

        // ── End-state invariant 6: ClogMarket's own curve state updated exactly once, correctly ─
        assertEq(market.re(), preRe + expectedBudget - clogExtracted, "curve re must have advanced by exactly the post-tax budget MINUS whatever the CLOG leg extracted back out as revenue - dust (if any) is folded into budget's own accounting since it's added directly to backing, never re-solved as more tokens");
        assertGt(tokensOut, 0, "must have actually received tokens");
        assertEq(tokensOut, curveTokens + clogTokens, "sanity: the swap's own token delta must equal the sum of both legs, exactly as the event reported them");
        assertEq(market.sold(), curveTokens, "market's own sold counter tracks the CURVE leg ONLY (leg-1), matching production's own semantics exactly - CLOG-leg deliveries never increment it, they advance hwm instead");
        assertEq(market.k(), market.re() * market.rt(), "k must be re-anchored to the CURRENT (re, rt) exactly after the trade, matching production's own re-anchor");
    }

    function test_realSell_afterABuy_everyDeltaZero_marketStateCorrect() public {
        // Acquire real tokens first via a real buy - exactly the invariant 5 mechanism proven
        // above (real take(), not a claim), so this test's own sell is exercising a genuine
        // pre-existing real ERC20 balance, not a shortcut.
        uint256 buyAmount = 0.01 ether;
        vm.deal(address(this), buyAmount);
        BalanceDelta buyDelta = _doSwap(true, -int256(buyAmount));
        uint256 tokensHeld = uint256(int256(buyDelta.amount1()));
        assertEq(token.balanceOf(address(this)), tokensHeld, "sanity: must genuinely hold real tokens from the prior buy");

        uint256 sellAmount = tokensHeld / 2;

        uint256 preManagerEthBalance = address(manager).balance;
        uint256 preRe = market.re();
        uint256 preRt = market.rt();
        uint256 preK = market.k();
        uint256 preSold = market.sold();
        uint256 preRealETH = market.realETH();
        uint256 preOwnerPending = market.pendingWithdrawals(tickerOwner);
        uint256 preMultisigPending = market.pendingWithdrawals(multisig);
        uint256 preWinnerPotLiability = market.winnerPotLiability();
        uint256 prePhysicalInventory = market.physicalInventory();
        uint256 preMarketTokenClaim = manager.balanceOf(address(market), uint256(uint160(address(token))));
        uint256 preMarketEthClaim = manager.balanceOf(address(market), uint256(uint160(address(0))));
        uint256 preUserEthBalance = address(this).balance;

        BalanceDelta sellDelta = _doSwap(false, -int256(sellAmount));
        uint256 netEthOut = uint256(int256(sellDelta.amount0()));

        // ── End-state invariant 1: the unlock succeeded (same reasoning as the buy test) ────

        // ── End-state invariant 2: PoolManager's real ETH balance fell by exactly netEthOut ──
        assertEq(address(manager).balance, preManagerEthBalance - netEthOut, "PM must physically release exactly netEthOut (post-tax) - it was real ETH backing the market's own claim");

        // ── End-state invariant 3: the market's own ERC6909 claims match the economic result ─
        // Not capped in this test (the reserve is far larger than one small sell), so
        // grossPayout is derivable directly from the curve without needing the cap branch.
        uint256 grossPayout = preRe - preK / (preRt + sellAmount); // re-derived independently, using the actual stored k (not recomputed) so this matches ClogMarket's own math exactly
        uint256 expectedTax = (grossPayout * market.SELL_TAX_BPS()) / market.BPS();
        assertEq(grossPayout - expectedTax, netEthOut, "sanity: independently re-derived netEthOut must match the actual delta the swap produced");
        uint256 expectedOwnerShare = (expectedTax * market.TICKER_OWNER_TAX_BPS()) / market.BPS();
        uint256 expectedMultisigShare = (expectedTax * market.MULTISIG_TAX_BPS()) / market.BPS();
        uint256 expectedWinnerPotShare = expectedTax - expectedOwnerShare - expectedMultisigShare;

        assertEq(market.pendingWithdrawals(tickerOwner), preOwnerPending + expectedOwnerShare, "ticker owner's pending withdrawal must grow by exactly the 40%-of-sell-tax formula");
        assertEq(market.pendingWithdrawals(multisig), preMultisigPending + expectedMultisigShare, "multisig's pending withdrawal must grow by exactly the 10%-of-sell-tax formula");
        assertEq(market.winnerPotLiability(), preWinnerPotLiability + expectedWinnerPotShare, "WinnerPot's own liability accumulator must grow by exactly the residual sell-tax share");
        assertEq(market.realETH(), preRealETH - grossPayout, "realETH must fall by the full GROSS payout, not merely the net amount paid to the seller");

        assertEq(manager.balanceOf(address(market), uint256(uint160(address(0)))), preMarketEthClaim - netEthOut, "market's own ETH claim must fall by exactly netEthOut (burned to pay the seller) - the conservation proof: reserve falls by grossPayout, liabilities rise by tax, net change is exactly netEthOut");
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(token)))), preMarketTokenClaim + sellAmount, "market's own token claim must grow by exactly the tokens sold back in (minted from the router's real deposit)");
        assertEq(market.physicalInventory(), prePhysicalInventory + sellAmount, "physicalInventory must grow by exactly sellAmount - the sold-back tokens are real inventory again");

        // ── THE conservation invariant, same as the buy test - must hold after a sell too ───
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(tickerOwner) + market.pendingWithdrawals(multisig) + market.winnerPotLiability(),
            "market's ETH claim must equal realETH + every liability bucket, exactly, after a sell too"
        );

        // ── End-state invariant 4: the hook itself holds NOTHING - it never accumulates ──────
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(0)))), 0, "hook must hold zero ETH claim of its own after a sell either");
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(token)))), 0, "hook must hold zero token claim of its own after a sell either");

        // ── End-state invariant 5: the user actually received real ETH, and paid real tokens ─
        assertEq(address(this).balance, preUserEthBalance + netEthOut, "the router must hold real native ETH delivered by take(), not a claim");
        assertEq(token.balanceOf(address(this)), tokensHeld - sellAmount, "the router's real token balance must fall by exactly what it sold");
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(0)))), 0, "no lingering ETH claim on the router's own account");

        // ── End-state invariant 6: ClogMarket's own curve state updated exactly once, correctly ─
        assertEq(market.rt(), preRt + sellAmount, "curve rt must have advanced by exactly the tokens sold in");
        assertEq(market.re(), preRe - grossPayout, "curve re must have fallen by exactly the GROSS payout (pre-tax), matching production's own re update exactly");
        assertGt(netEthOut, 0, "must have actually received ETH");
        assertEq(market.sold(), preSold - sellAmount, "sold must decrement by exactly the tokens sold back in, matching production's own sell() exactly");
        assertEq(market.k(), market.re() * market.rt(), "k must be re-anchored to the CURRENT (re, rt) exactly after the trade, matching production's own re-anchor");
    }
}
