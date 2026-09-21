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
import {MockTickerNFT} from "../test/mocks/MockTickerNFT.sol";

/// @notice A contract with no receive()/fallback - any plain ETH send to it must revert. Used
///         to prove withdraw()'s atomicity when the recipient itself cannot accept ETH.
contract RejectsETH {}

/// @title Dynamic ticker-owner resolution (Part A) and claim-native withdrawal (Part B)
contract DynamicOwnerAndWithdrawalTest is Test, IUnlockCallback {
    PoolManager manager;
    ClogV4Hook hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    PoolKey key;

    address ownerA = makeAddr("ownerA");
    address ownerB = makeAddr("ownerB");
    address multisig = makeAddr("multisig");
    uint256 constant TICKER_TOKEN_ID = 1;

    address constant HOOK_ADDRESS = address(0x2088);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, ownerA);

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336);

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();
    }

    struct SwapRequest {
        bool zeroForOne;
        int256 amountSpecified;
    }

    function _doBuy(uint256 amount) internal returns (BalanceDelta) {
        vm.deal(address(this), amount);
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(amount)})));
        return abi.decode(result, (BalanceDelta));
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
            key,
            IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: req.amountSpecified, sqrtPriceLimitX96: 4295128740}),
            bytes("")
        );

        int128 ethOwed = -swapDelta.amount0();
        manager.sync(key.currency0);
        manager.settle{value: uint256(int256(ethOwed))}();
        int128 tokenOwed = swapDelta.amount1();
        manager.take(key.currency1, address(this), uint256(int256(tokenOwed)));

        return abi.encode(swapDelta);
    }

    receive() external payable {}

    function _conservationHolds() internal view {
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(market.ticketOwnerRecipient()) + market.pendingWithdrawals(multisig) + market.winnerPotLiability(),
            "conservation invariant must hold"
        );
    }

    // ════════════════════════════════════ Part A ════════════════════════════════════

    function test_dynamicTickerOwner_transferRedirectsFutureFees_preservesHistorical() public {
        // ── Owner A trades/accrues fees ──────────────────────────────────────────────
        _doBuy(0.02 ether);
        uint256 ownerAPendingAfterFirstBuy = market.pendingWithdrawals(ownerA);
        assertGt(ownerAPendingAfterFirstBuy, 0, "sanity: owner A must have actually accrued a fee from the first trade");
        assertEq(market.pendingWithdrawals(ownerB), 0, "sanity: owner B must have nothing yet");

        // ── NFT transfers A -> B ──────────────────────────────────────────────────────
        tickerNFT.setOwner(TICKER_TOKEN_ID, ownerB);
        assertEq(market.ticketOwnerRecipient(), ownerB, "ticketOwnerRecipient must resolve to the NEW owner immediately, with no caching or delay");

        // ── Subsequent trade credits B ───────────────────────────────────────────────
        _doBuy(0.02 ether);
        uint256 ownerBPendingAfterSecondBuy = market.pendingWithdrawals(ownerB);
        assertGt(ownerBPendingAfterSecondBuy, 0, "owner B must have been credited by the trade that happened AFTER the NFT transfer");

        // ── A's old accrued amount remains unchanged ─────────────────────────────────
        assertEq(market.pendingWithdrawals(ownerA), ownerAPendingAfterFirstBuy, "owner A's already-accrued fee must be completely untouched by the NFT transfer and by B's subsequent trade");

        // ── B does not receive A's historical fees ───────────────────────────────────
        assertEq(ownerBPendingAfterSecondBuy, market.pendingWithdrawals(ownerB), "sanity restated: B's balance is exactly what B itself earned");
        assertTrue(ownerBPendingAfterSecondBuy != ownerAPendingAfterFirstBuy + ownerBPendingAfterSecondBuy, "B's pending balance must never include A's historical amount");
        assertLt(ownerBPendingAfterSecondBuy, ownerAPendingAfterFirstBuy + ownerBPendingAfterSecondBuy, "B's own balance must be strictly less than A's-plus-B's combined - i.e. A's share was never added to B's");

        // ── A's old accrued amount remains WITHDRAWABLE despite no longer being the current owner ──
        uint256 ownerABalanceBefore = ownerA.balance;
        market.withdraw(ownerA);
        assertEq(ownerA.balance, ownerABalanceBefore + ownerAPendingAfterFirstBuy, "owner A must still be able to withdraw their own historical accrual even after losing NFT ownership");
        assertEq(market.pendingWithdrawals(ownerA), 0, "owner A's liability must be cleared after withdrawal");

        // B's own balance must be completely unaffected by A's withdrawal.
        assertEq(market.pendingWithdrawals(ownerB), ownerBPendingAfterSecondBuy, "B's own pending balance must be completely unaffected by A's separate withdrawal");
    }

    // ════════════════════════════════════ Part B ════════════════════════════════════

    function test_withdraw_permissionlessTrigger_ethGoesToRecipient_conservationHoldsThroughout() public {
        _doBuy(0.02 ether);
        _conservationHolds();

        uint256 pending = market.pendingWithdrawals(ownerA);
        assertGt(pending, 0, "sanity: must have something to withdraw");
        uint256 ownerABalanceBefore = ownerA.balance;

        // Permissionless: called by a THIRD PARTY, not ownerA and not the market itself - ETH
        // must still go to ownerA regardless of who triggers it.
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        market.withdraw(ownerA);

        assertEq(ownerA.balance, ownerABalanceBefore + pending, "ETH must go to ownerA even though a different address triggered the withdrawal");
        assertEq(randomCaller.balance, 0, "the triggering caller must receive nothing themselves");
        assertEq(market.pendingWithdrawals(ownerA), 0, "liability must be fully cleared");
        _conservationHolds();
    }

    function test_withdraw_burnsExactAmountFromMarketClaim_zeroDeltaAtUnlockEnd() public {
        _doBuy(0.02 ether);
        uint256 pending = market.pendingWithdrawals(ownerA);
        uint256 marketClaimBefore = manager.balanceOf(address(market), uint256(uint160(address(0))));
        uint256 managerEthBalanceBefore = address(manager).balance;

        market.withdraw(ownerA);

        // manager.unlock() itself would have reverted (CurrencyNotSettled) if any delta anywhere
        // remained nonzero at the end - reaching this line at all is partial proof; the checks
        // below confirm WHY it succeeded.
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(0)))), marketClaimBefore - pending, "the market's own ETH claim must fall by EXACTLY the withdrawn amount - burn and take must cancel exactly, with nothing left over or double-counted");
        assertEq(address(manager).balance, managerEthBalanceBefore - pending, "PoolManager must have physically released exactly the withdrawn amount as real ETH");
    }

    function test_withdraw_nothingToWithdraw_reverts() public {
        vm.expectRevert(bytes("nothing to withdraw"));
        market.withdraw(ownerA);
    }

    function test_withdraw_failedRecipientTransfer_revertsAtomically_liabilityAndClaimPreserved() public {
        RejectsETH badRecipient = new RejectsETH();
        tickerNFT.setOwner(TICKER_TOKEN_ID, address(badRecipient));

        _doBuy(0.02 ether);
        uint256 pendingBefore = market.pendingWithdrawals(address(badRecipient));
        assertGt(pendingBefore, 0, "sanity: the rejecting contract must have actually accrued a fee to attempt withdrawing");
        uint256 marketClaimBefore = manager.balanceOf(address(market), uint256(uint160(address(0))));

        bool reverted;
        try this.externalWithdraw(address(badRecipient)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "withdrawing to a recipient that cannot accept ETH must revert the entire call");

        // Nothing must have moved - the liability ClogMarket.withdraw would have cleared, and
        // the claim the hook would have burned, must both be exactly as they were before.
        assertEq(market.pendingWithdrawals(address(badRecipient)), pendingBefore, "the liability must be fully restored (never lost) after the atomic revert");
        assertEq(manager.balanceOf(address(market), uint256(uint160(address(0)))), marketClaimBefore, "the market's own ETH claim must be completely unchanged after the atomic revert");
        _conservationHolds();
    }

    /// @dev External wrapper so the try/catch above can call market.withdraw across a real call
    ///      boundary (try/catch only works on external calls in Solidity).
    function externalWithdraw(address to) external {
        market.withdraw(to);
    }
}
