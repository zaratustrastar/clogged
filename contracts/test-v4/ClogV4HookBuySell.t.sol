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
    uint256 constant VIRTUAL_TOKEN_SEED = 1_800_000_000e18;

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
        // already correct on the etched copy; only real mapping storage (marketOf) would need
        // re-establishing, which registerMarket (below) does fresh regardless.

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), VIRTUAL_ETH_SEED, VIRTUAL_TOKEN_SEED);

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

        // Real launch-time inventory deposit: mint the market's full curve allocation as real
        // ERC20 (mirroring MemeToken.setMarket minting the full 1B to the market contract),
        // then physically deposit it into PoolManager and mint the market an ERC6909 claim for
        // exactly that amount - a real transfer+settle+mint sequence, not a shortcut.
        token.mint(address(market), VIRTUAL_TOKEN_SEED);
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
            // Real launch-time deposit: physically transfer the market's own just-minted 1B
            // (this slice: VIRTUAL_TOKEN_SEED) into PoolManager, settle, then mint the market
            // an ERC6909 claim for exactly that amount - the market's claim is now fully
            // backed by a real, physical deposit, exactly as the architecture requires.
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), VIRTUAL_TOKEN_SEED);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), VIRTUAL_TOKEN_SEED);
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

    // ── The actual proof ─────────────────────────────────────────────────────────────────────

    function test_realBuy_everyDeltaZero_marketStateCorrect() public {
        uint256 marketClaimAfterSetup = manager.balanceOf(address(market), uint256(uint160(address(token))));
        assertEq(marketClaimAfterSetup, VIRTUAL_TOKEN_SEED, "sanity: market must hold its full token claim right after setUp's deposit step");

        uint256 buyAmount = 0.01 ether;

        uint256 preManagerEthBalance = address(manager).balance;
        uint256 preRe = market.re();

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
            VIRTUAL_TOKEN_SEED - tokensOut,
            "market's own remaining token claim must be the original seed minus whatever was delivered out"
        );

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
    }
}
