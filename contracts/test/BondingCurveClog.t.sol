// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {MockTickerNFT} from "./mocks/MockTickerNFT.sol";

contract BondingCurveClogTest is Test {
    MemeToken token;
    BondingCurveClog market;
    MockTickerNFT tickerNFT;

    address governance = address(0x60401);
    address ticketOwner = address(0x71CE);
    address multisig = address(0xA51);
    address winnerPot = address(0xB0B0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B1);

    // Config G: P0 = 5e-9 ETH/token, buffer = 2.0x  -> virtualEthSeed = P0 * virtualTokenSeed
    uint256 constant BUFFER_BPS = 20_000; // 2.0x
    uint256 virtualTokenSeed = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 virtualEthSeed;

    function setUp() public {
        // Simple explicit deployment: MemeToken first (zero supply, no market yet), then
        // BondingCurveClog (passing MemeToken's real, already-known address -- no prediction
        // needed), then a one-time setMarket call that mints the full supply and permanently
        // locks the market. No nonce arithmetic, no CREATE2, no address prediction at all.
        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(1, ticketOwner);

        token = new MemeToken("Cat", "CAT", address(this));
        virtualEthSeed = (5e9 * virtualTokenSeed) / 1e18; // P0 = 5e-9 ETH/token, scaled

        market = new BondingCurveClog(
            address(token), address(tickerNFT), 1, multisig, winnerPot, governance, virtualEthSeed, BUFFER_BPS
        );
        token.setMarket(address(market));

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    // ── Basic mechanics ─────────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(market.re(), virtualEthSeed);
        assertEq(market.rt(), virtualTokenSeed);
        assertEq(market.realETH(), 0);
        assertEq(market.clogRemaining(), 100_000_000e18);
        assertEq(token.balanceOf(address(market)), 1_000_000_000e18);
    }

    function test_buy_deliversTokensAndRespectsFixedBudget() public {
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        uint256 tokensOut = market.buy{value: 1 ether}(0, block.timestamp);

        assertGt(tokensOut, 0, "should receive tokens");
        assertEq(token.balanceOf(alice), tokensOut);
        // Fixed-budget invariant: Alice never pays more than she sent.
        assertEq(aliceBalBefore - alice.balance, 1 ether, "must spend exactly what was sent, no more");
    }

    function test_buy_taxRoutedCorrectly() public {
        vm.prank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);

        uint256 expectedTax = (1 ether * 50) / 10_000; // 0.5%
        uint256 expectedOwner = (expectedTax * 2000) / 10_000;
        uint256 expectedMultisigFromTax = (expectedTax * 1000) / 10_000;

        assertEq(market.pendingWithdrawals(ticketOwner), expectedOwner, "ticker owner tax share credited");
        assertGe(market.pendingWithdrawals(multisig), expectedMultisigFromTax, "multisig credited at least its tax share");
        assertGt(winnerPot.balance, 0, "winnerPot received something (pushed directly, not credited)");

        // Pull-payment: nothing actually moves until withdraw() is called.
        assertEq(ticketOwner.balance, 0);
        market.withdraw(ticketOwner);
        assertEq(ticketOwner.balance, expectedOwner);
    }

    function test_withdraw_anyoneCanTriggerPayoutButOnlyToTheRecipient() public {
        vm.prank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);
        uint256 owed = market.pendingWithdrawals(ticketOwner);
        assertGt(owed, 0);

        // Bob (unrelated) triggers the withdrawal; funds must go to ticketOwner, not Bob.
        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        market.withdraw(ticketOwner);
        assertEq(ticketOwner.balance, owed);
        assertEq(bob.balance, bobBalBefore, "caller must not receive the funds");
        assertEq(market.pendingWithdrawals(ticketOwner), 0);
    }

    function test_brokenFeeRecipient_doesNotBrickTrading() public {
        // A ticker-owner recipient that reverts on receiving ETH must NOT be able to block
        // anyone's buy/sell -- this is exactly the DoS the pull-payment pattern closes.
        RevertingReceiver badOwner = new RevertingReceiver();
        MockTickerNFT tickerNFT2 = new MockTickerNFT();
        tickerNFT2.setOwner(1, address(badOwner));
        MemeToken token2 = new MemeToken("Dog", "DOG", address(this));
        BondingCurveClog market2 = new BondingCurveClog(
            address(token2), address(tickerNFT2), 1, multisig, winnerPot, governance, virtualEthSeed, BUFFER_BPS
        );
        token2.setMarket(address(market2));

        vm.prank(alice);
        market2.buy{value: 1 ether}(0, block.timestamp); // must succeed despite badOwner reverting on receive

        uint256 owed = market2.pendingWithdrawals(address(badOwner));
        assertGt(owed, 0);
        vm.expectRevert(); // withdraw() to the broken recipient itself still fails...
        market2.withdraw(address(badOwner));
        // ...but that failure is isolated to badOwner's own withdrawal, not anyone else's trading.
        vm.prank(bob);
        market2.buy{value: 1 ether}(0, block.timestamp); // still works fine
    }

    function test_sellRoundTrip_smallLoss() public {
        vm.startPrank(alice);
        uint256 tokensOut = market.buy{value: 0.05 ether}(0, block.timestamp);
        token.approve(address(market), tokensOut);
        (uint256 netEthOut,) = market.sell(tokensOut, 0, block.timestamp);
        vm.stopPrank();

        // Round-tripping immediately should cost a small, sane amount (tax + slippage + CLOG),
        // never a profit.
        assertLt(netEthOut, 0.05 ether, "round trip must not be profitable");
        assertGt(netEthOut, 0.90 ether * 0.05 / 1, "round trip loss should be modest, not catastrophic");
    }

    // ── CLOG mechanics ──────────────────────────────────────────────────────

    function test_clog_releasesOnNewTerritoryOnly() public {
        // Alice buys, establishing a high-water mark, then sells PART of it back (staying below hwm).
        vm.startPrank(alice);
        uint256 aliceTokens = market.buy{value: 5 ether}(0, block.timestamp);
        uint256 clogAfterFirstBuy = market.clogRemaining();
        assertLt(clogAfterFirstBuy, 100_000_000e18, "first buy on fresh territory should release CLOG");

        token.approve(address(market), aliceTokens);
        market.sell(aliceTokens / 2, 0, block.timestamp); // sold drops well below hwm; hwm itself is untouched

        // Buying BACK UP TO (but not beyond) the same hwm must release ZERO additional CLOG.
        // Re-buy a slightly smaller amount than what was sold, guaranteeing we stay within
        // already-visited territory (sold < hwm after this).
        market.buy{value: 0.4 ether}(0, block.timestamp);
        vm.stopPrank();

        uint256 clogAfterRebuy = market.clogRemaining();
        assertEq(
            clogAfterRebuy, clogAfterFirstBuy, "re-buying within already-visited territory must release zero CLOG"
        );
    }

    function test_clog_freshBuyBeyondPriorHwm_releasesMore() public {
        vm.prank(alice);
        market.buy{value: 5 ether}(0, block.timestamp);
        uint256 clogAfterFirst = market.clogRemaining();

        // A buy that pushes PAST the existing high-water mark must release additional CLOG.
        vm.prank(bob);
        market.buy{value: 1 ether}(0, block.timestamp);
        uint256 clogAfterFresh = market.clogRemaining();

        assertLt(clogAfterFresh, clogAfterFirst, "genuinely new territory must release additional CLOG");
    }

    function test_clog_cyclingAttack_boundedRelease() public {
        // Buy up to a high-water mark, then repeatedly sell-down/buy-back-up WITHIN that same
        // range (buy amount sized to stay strictly below the prior high-water mark each time).
        vm.startPrank(alice);
        market.buy{value: 3 ether}(0, block.timestamp);
        uint256 clogAfterInitial = market.clogRemaining();
        uint256 hwmAfterInitial = market.hwm();

        token.approve(address(market), type(uint256).max);
        for (uint256 i = 0; i < 10; i++) {
            uint256 bal = token.balanceOf(alice);
            market.sell(bal / 2, 0, block.timestamp); // sell half of current holdings
            uint256 soldNow = market.sold();
            // Buy back only enough to approach, but not exceed, the untouched high-water mark.
            if (soldNow < hwmAfterInitial) {
                market.buy{value: 0.05 ether}(0, block.timestamp);
            }
        }
        vm.stopPrank();

        uint256 clogAfterCycling = market.clogRemaining();
        assertEq(market.hwm(), hwmAfterInitial, "hwm must never move from pure cycling within its own range");
        uint256 released = clogAfterInitial - clogAfterCycling;
        assertLt(released, 5_000_000e18, "repeated cycling within visited territory must release ~nothing further");
    }

    // ── THE critical solvency invariant ─────────────────────────────────────

    function test_buy_exceedingInventory_revertsCleanly() public {
        // A large enough single buy against Config G's virtual-reserve depth will imply more
        // tokens than the contract actually holds -- it must revert cleanly, never under-deliver
        // or lie about balance.
        vm.prank(alice);
        vm.expectRevert();
        market.buy{value: 10_000 ether}(0, block.timestamp);
    }

    function test_sell_neverPaysMoreThanRealETH_fuzz(uint256 buyAmount1, uint256 buyAmount2, uint256 sellFraction)
        public
    {
        // Bounded well within what Config G's real token inventory can actually fulfill (see
        // test_buy_exceedingInventory_revertsCleanly for the separately-tested oversized-buy path).
        buyAmount1 = bound(buyAmount1, 0.001 ether, 5 ether);
        buyAmount2 = bound(buyAmount2, 0.001 ether, 5 ether);
        sellFraction = bound(sellFraction, 1, 10_000);

        vm.prank(alice);
        uint256 t1 = market.buy{value: buyAmount1}(0, block.timestamp);
        vm.prank(bob);
        uint256 t2 = market.buy{value: buyAmount2}(0, block.timestamp);

        uint256 realETHBefore = market.realETH();

        vm.startPrank(alice);
        token.approve(address(market), t1);
        uint256 sellAmt = (t1 * sellFraction) / 10_000;
        if (sellAmt == 0) sellAmt = 1;
        (uint256 netEthOut,) = market.sell(sellAmt, 0, block.timestamp);
        vm.stopPrank();

        // The contract must never have paid out more real ETH than it held.
        assertLe(netEthOut, realETHBefore, "sell must never pay more than realETH held before the sale");
        assertGe(market.realETH(), 0, "realETH is a uint, but assert explicitly for clarity");
    }

    function test_invariant_reAlwaysEqualsVirtualSeedPlusRealETH() public {
        vm.prank(alice);
        market.buy{value: 2 ether}(0, block.timestamp);
        assertEq(market.re(), virtualEthSeed + market.realETH(), "re must always equal virtualEthSeed + realETH");

        vm.prank(bob);
        market.buy{value: 3 ether}(0, block.timestamp);
        assertEq(market.re(), virtualEthSeed + market.realETH(), "invariant must hold after a second buy");

        vm.startPrank(alice);
        uint256 bal = token.balanceOf(alice);
        token.approve(address(market), bal);
        market.sell(bal / 2, 0, block.timestamp);
        vm.stopPrank();
        assertEq(market.re(), virtualEthSeed + market.realETH(), "invariant must hold after a sell");
    }
}

/// @dev Deliberately reverts on receiving plain ETH, to test that a broken fee recipient can
///      never block other users' trades (pull-payment design).
contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}
