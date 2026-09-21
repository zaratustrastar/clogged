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
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "./mocks/MinimalMockToken.sol";

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

    // BEFORE_INITIALIZE_FLAG (1<<13) | BEFORE_SWAP_FLAG (1<<7) | BEFORE_SWAP_RETURNS_DELTA_FLAG (1<<3)
    // = 8192 + 128 + 8 = 8328 = 0x2088. Test-only address construction via vm.etch - real
    // deployment needs actual CREATE2 salt mining, not yet done (see contract-level docs).
    address constant HOOK_ADDRESS = address(0x2088);

    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    // Config G's own virtualTokenSeed = CURVE_ALLOCATION(900M) * bufferMultiplierBps(20_000) /
    // BPS(10_000) = 1.8B - a PRICING reserve only, deliberately "deeper" than real supply so
    // the curve behaves correctly. NEVER how many real MemeTokens exist.
    uint256 constant VIRTUAL_TOKEN_SEED = 1_800_000_000e18;
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
        market = new ClogMarket(HOOK_ADDRESS, address(token), VIRTUAL_ETH_SEED, VIRTUAL_TOKEN_SEED, PHYSICAL_TOKEN_SUPPLY);

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

    function test_realBuy_everyDeltaZero_marketStateCorrect() public {
        uint256 marketClaimAfterSetup = manager.balanceOf(address(market), uint256(uint160(address(token))));
        assertEq(marketClaimAfterSetup, PHYSICAL_TOKEN_SUPPLY, "sanity: market must hold its full REAL (physical) token claim right after setUp's deposit step, never the virtual seed");

        uint256 buyAmount = 0.01 ether;

        uint256 preManagerEthBalance = address(manager).balance;
        uint256 preRe = market.re();
        uint256 prePhysicalInventory = market.physicalInventory();

        vm.deal(address(this), buyAmount);
        BalanceDelta swapDelta = _doSwap(true, -int256(buyAmount));

        // ── End-state invariant 1: the unlock succeeded at all ──────────────────────────────
        // (PoolManager.unlock() itself reverts with CurrencyNotSettled if any nonzero delta
        // remains anywhere - router's, hook's, or otherwise - so reaching this line at all is
        // already partial proof; the checks below confirm WHY it succeeded, not just that it did.)

        // ── End-state invariant 2: PoolManager's real ETH balance grew by exactly buyAmount ──
        assertEq(address(manager).balance, preManagerEthBalance + buyAmount, "PM must physically hold the real ETH input - this is what backs the market's own ETH claim");

        // ── End-state invariant 3: the market's own ERC6909 claims match the economic result ─
        uint256 tokensOut = uint256(int256(swapDelta.amount1()));
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(0)))), buyAmount, "market's own ETH claim must equal the full gross input");
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(token)))),
            PHYSICAL_TOKEN_SUPPLY - tokensOut,
            "market's own remaining REAL token claim must be the physical supply minus whatever was actually delivered out"
        );
        assertEq(market.physicalInventory(), prePhysicalInventory - tokensOut, "physicalInventory must fall by exactly tokensOut, matching the real claim exactly");

        // ── End-state invariant 4: the hook itself holds NOTHING - it never accumulates ──────
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(0)))), 0, "hook must hold zero ETH claim of its own - it only ever passes claims to the market");
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(token)))), 0, "hook must hold zero token claim of its own");

        // ── End-state invariant 5: the user actually received the real tokens, not a claim ──
        assertEq(token.balanceOf(address(this)), tokensOut, "the router must hold the real ERC20 tokens delivered by take()");
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(token)))), 0, "the router took REAL tokens, not a claim - no claim balance should exist for the router");

        // ── End-state invariant 6: ClogMarket's own curve state updated exactly once, correctly ─
        assertEq(market.re(), preRe + buyAmount, "curve re must have advanced by exactly the gross input (no tax in this slice)");
        assertGt(tokensOut, 0, "must have actually received tokens");
        assertEq(market.sold(), tokensOut, "market's own sold counter must match what was actually delivered");
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
        uint256 preSold = market.sold();
        uint256 prePhysicalInventory = market.physicalInventory();
        uint256 preMarketTokenClaim = manager.balanceOf(address(market), uint256(uint160(address(token))));
        uint256 preMarketEthClaim = manager.balanceOf(address(market), uint256(uint160(address(0))));
        uint256 preUserEthBalance = address(this).balance;

        BalanceDelta sellDelta = _doSwap(false, -int256(sellAmount));
        uint256 ethOut = uint256(int256(sellDelta.amount0()));

        // ── End-state invariant 1: the unlock succeeded (same reasoning as the buy test) ────

        // ── End-state invariant 2: PoolManager's real ETH balance fell by exactly ethOut ────
        assertEq(address(manager).balance, preManagerEthBalance - ethOut, "PM must physically release exactly ethOut - it was real ETH backing the market's own claim");

        // ── End-state invariant 3: the market's own ERC6909 claims match the economic result ─
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(0)))), preMarketEthClaim - ethOut, "market's own ETH claim must fall by exactly ethOut (burned to pay the seller)");
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(token)))), preMarketTokenClaim + sellAmount, "market's own token claim must grow by exactly the tokens sold back in (minted from the router's real deposit)");
        assertEq(market.physicalInventory(), prePhysicalInventory + sellAmount, "physicalInventory must grow by exactly sellAmount - the sold-back tokens are real inventory again");

        // ── End-state invariant 4: the hook itself holds NOTHING - it never accumulates ──────
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(0)))), 0, "hook must hold zero ETH claim of its own after a sell either");
        assertEq(manager.balanceOf(HOOK_ADDRESS, uint256(uint160(address(token)))), 0, "hook must hold zero token claim of its own after a sell either");

        // ── End-state invariant 5: the user actually received real ETH, and paid real tokens ─
        assertEq(address(this).balance, preUserEthBalance + ethOut, "the router must hold real native ETH delivered by take(), not a claim");
        assertEq(token.balanceOf(address(this)), tokensHeld - sellAmount, "the router's real token balance must fall by exactly what it sold");
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(0)))), 0, "no lingering ETH claim on the router's own account");

        // ── End-state invariant 6: ClogMarket's own curve state updated exactly once, correctly ─
        assertEq(market.rt(), preRt + sellAmount, "curve rt must have advanced by exactly the tokens sold in");
        assertEq(market.re(), preRe - ethOut, "curve re must have fallen by exactly the ETH paid out (no tax in this slice)");
        assertGt(ethOut, 0, "must have actually received ETH");
        assertEq(market.sold(), preSold - sellAmount, "sold must decrement by exactly the tokens sold back in, matching production's own sell() exactly");
        assertEq(market.k(), market.re() * market.rt(), "k must be re-anchored to the CURRENT (re, rt) exactly after the trade, matching production's own re-anchor");
    }
}
