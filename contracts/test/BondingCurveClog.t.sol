// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
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

        EligibilityRegistry engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);

        market = new BondingCurveClog(
            address(token), address(tickerNFT), 1, multisig, winnerPot, governance, address(engine), virtualEthSeed, BUFFER_BPS
        );
        token.setMarket(address(market));
        uint256 registeredId = engine.registerToken(address(market));
        require(registeredId == 1, "token id mismatch");

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

        uint256 expectedTax = (1 ether * 60) / 10_000; // 0.6%
        uint256 expectedOwner = (expectedTax * 4000) / 10_000;
        uint256 expectedMultisigFromTax = (expectedTax * 1000) / 10_000;

        assertEq(market.pendingWithdrawals(ticketOwner), expectedOwner, "ticker owner tax share credited");
        assertGe(market.pendingWithdrawals(multisig), expectedMultisigFromTax, "multisig credited at least its tax share");
        assertGt(winnerPot.balance, 0, "winnerPot received something (pushed directly, not credited)");

        // Pull-payment: nothing actually moves until withdraw() is called.
        assertEq(ticketOwner.balance, 0);
        market.withdraw(ticketOwner);
        assertEq(ticketOwner.balance, expectedOwner);
    }

    function test_sell_taxRoutedCorrectly() public {
        vm.startPrank(alice);
        uint256 tokensOut = market.buy{value: 1 ether}(0, block.timestamp);
        token.approve(address(market), tokensOut);

        uint256 ownerBefore = market.pendingWithdrawals(ticketOwner);
        uint256 multisigBefore = market.pendingWithdrawals(multisig);
        uint256 winnerPotBefore = winnerPot.balance;

        (uint256 netEthOut,) = market.sell(tokensOut, 0, block.timestamp);
        vm.stopPrank();

        // grossPayout is netEthOut + the tax actually deducted from it - reconstruct via the
        // real BPS math rather than assuming a specific netEthOut, so this test still holds
        // regardless of curve slippage on this particular trade.
        uint256 grossPayout = (netEthOut * 10_000) / (10_000 - market.SELL_TAX_BPS());
        uint256 expectedTax = (grossPayout * market.SELL_TAX_BPS()) / 10_000;
        uint256 expectedOwner = (expectedTax * market.TICKER_OWNER_TAX_BPS()) / 10_000;
        uint256 expectedMultisig = (expectedTax * market.MULTISIG_TAX_BPS()) / 10_000;

        assertApproxEqAbs(
            market.pendingWithdrawals(ticketOwner) - ownerBefore, expectedOwner, 1, "ticker owner sell-tax share credited (40%)"
        );
        assertApproxEqAbs(
            market.pendingWithdrawals(multisig) - multisigBefore, expectedMultisig, 1, "multisig sell-tax share credited (10%)"
        );
        assertGt(winnerPot.balance, winnerPotBefore, "winnerPot received the remaining 50% of the sell tax, pushed directly");
    }

    /// @notice The 40/10/50 split is BPS-of-the-tax, computed via two mulDiv calls with the third
    ///         leg taken as the exact residual (taxAmount - toOwner - toMultisig, never its own
    ///         mulDiv) - so all three legs must sum to EXACTLY taxAmount, for every trade size,
    ///         including ones that don't divide evenly. No rounding dust is ever lost or created;
    ///         it always lands with the residual (WinnerPot) leg, never silently dropped.
    ///
    ///         Isolates a single buy's own tax credits from CLOG-extraction credits (a separate,
    ///         unrelated 10/90 split on CLOG revenue, unchanged by this task, that also credits
    ///         ticketOwner/multisig/winnerPot and would otherwise pollute this measurement) by
    ///         first establishing a high-water mark with a large buy, then selling most of it back
    ///         (dropping well below the hwm, which stays put - the same buy/sell/hwm pattern
    ///         test_clog_releasesOnNewTerritoryOnly already relies on), so the final, small,
    ///         precisely-sized buy stays inside already-released territory and triggers zero new
    ///         CLOG release at all.
    function test_taxSplit_roundingBehavior_exact() public {
        vm.startPrank(alice);
        uint256 hwmTokens = market.buy{value: 5 ether}(0, block.timestamp);
        token.approve(address(market), hwmTokens);
        market.sell(hwmTokens - 1, 0, block.timestamp); // keep 1 wei of tokens so the position stays open, well below hwm
        vm.stopPrank();
        uint256 clogRemainingBeforeFinalBuy = market.clogRemaining();

        // 777 wei of tax does not divide evenly by 10_000 in either the 40% or 10% leg - exactly
        // the kind of amount that would reveal a rounding-dust bug if one existed.
        uint256 grossAmount = 777 * 10_000 / market.BUY_TAX_BPS(); // sized so the resulting tax is exactly 777 wei
        vm.deal(alice, grossAmount + 1 ether);

        uint256 ownerBefore = market.pendingWithdrawals(ticketOwner);
        uint256 multisigBefore = market.pendingWithdrawals(multisig);
        uint256 winnerPotBefore = winnerPot.balance;

        vm.prank(alice);
        market.buy{value: grossAmount}(0, block.timestamp);

        assertEq(market.clogRemaining(), clogRemainingBeforeFinalBuy, "final buy stayed below the hwm - zero new CLOG release, so no CLOG-extraction noise in the deltas below");

        uint256 taxAmount = (grossAmount * market.BUY_TAX_BPS()) / 10_000;
        uint256 toOwner = market.pendingWithdrawals(ticketOwner) - ownerBefore;
        uint256 toMultisig = market.pendingWithdrawals(multisig) - multisigBefore;
        uint256 toWinnerPot = winnerPot.balance - winnerPotBefore;

        assertEq(toOwner + toMultisig + toWinnerPot, taxAmount, "the three tax legs must sum to EXACTLY the tax amount - no dust lost or created anywhere");
        assertEq(toOwner, (taxAmount * 4_000) / 10_000, "owner leg is exactly 40% of tax, rounded down");
        assertEq(toMultisig, (taxAmount * 1_000) / 10_000, "multisig leg is exactly 10% of tax, rounded down");
        // WinnerPot (the residual leg) absorbs whatever the two mulDiv roundings left over -
        // always >= the bare 50% mulDiv would give, never less, and the three legs still sum
        // exactly to taxAmount as asserted above.
        assertGe(toWinnerPot, (taxAmount * 5_000) / 10_000, "winnerPot (residual leg) must be at least the bare 50% mulDiv result");
    }

    function test_pullPaymentAccounting_remainsSolventAcrossManyTrades() public {
        // A sequence of interleaved buys/sells across two traders, none of whom ever withdraw -
        // pendingWithdrawals for ticketOwner/multisig accumulate the whole time. The contract's
        // actual ETH balance must always cover realETH (the curve's own reserve) PLUS every
        // outstanding pull-payment balance - it must never owe more than it holds, at any point
        // in the sequence, not just at the end.
        uint256[6] memory amounts = [uint256(0.3 ether), 0.7 ether, 1.1 ether, 0.05 ether, 2 ether, 0.4 ether];
        for (uint256 i = 0; i < amounts.length; i++) {
            address trader = i % 2 == 0 ? alice : bob;
            vm.prank(trader);
            uint256 tokensOut = market.buy{value: amounts[i]}(0, block.timestamp);
            _assertSolvent();

            if (i % 3 == 2 && tokensOut > 0) {
                vm.startPrank(trader);
                token.approve(address(market), tokensOut / 2);
                market.sell(tokensOut / 2, 0, block.timestamp);
                vm.stopPrank();
                _assertSolvent();
            }
        }

        // Withdrawing must not break solvency either - the balance drops by exactly what was owed.
        market.withdraw(ticketOwner);
        _assertSolvent();
        market.withdraw(multisig);
        _assertSolvent();
    }

    function _assertSolvent() internal view {
        uint256 owed = market.realETH() + market.pendingWithdrawals(ticketOwner) + market.pendingWithdrawals(multisig);
        assertGe(address(market).balance, owed, "contract's actual ETH balance must cover realETH plus every outstanding pull-payment balance");
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
        EligibilityRegistry engine2 = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        BondingCurveClog market2 = new BondingCurveClog(
            address(token2), address(tickerNFT2), 1, multisig, winnerPot, governance, address(engine2), virtualEthSeed, BUFFER_BPS
        );
        token2.setMarket(address(market2));
        uint256 registeredId2 = engine2.registerToken(address(market2));
        require(registeredId2 == 1, "token id mismatch");

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

    /// @notice Task B/A explicitly does NOT touch CLOG extraction economics - still 10%
    ///         multisig / 90% WinnerPot of whatever CLOG revenue a buy actually extracts. This
    ///         pins that split directly against a real ClogRevenueExtracted event's own
    ///         `extracted` amount, independent of the trading-tax split (a separate mechanism
    ///         entirely - see test_taxSplit_roundingBehavior_exact's own isolation of the two).
    function test_clogExtraction_stillTenNinety() public {
        uint256 ownerBefore = market.pendingWithdrawals(ticketOwner);
        uint256 multisigBefore = market.pendingWithdrawals(multisig);
        uint256 winnerPotBefore = winnerPot.balance;

        vm.recordLogs();
        vm.prank(alice);
        market.buy{value: 5 ether}(0, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 extracted;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ClogRevenueExtracted(uint256,uint256,uint256)")) {
                (extracted,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                found = true;
                break;
            }
        }
        assertTrue(found, "this buy must establish new territory and extract CLOG revenue");
        assertGt(extracted, 0);

        // Isolate the CLOG-extraction-only contribution: total delta minus the trading-tax
        // contribution (computed independently via the real BUY_TAX_BPS/TICKER_OWNER_TAX_BPS/
        // MULTISIG_TAX_BPS, exactly as test_buy_taxRoutedCorrectly does).
        uint256 taxAmount = (5 ether * market.BUY_TAX_BPS()) / 10_000;
        uint256 taxToOwner = (taxAmount * market.TICKER_OWNER_TAX_BPS()) / 10_000;
        uint256 taxToMultisig = (taxAmount * market.MULTISIG_TAX_BPS()) / 10_000;

        uint256 clogToMultisig = (market.pendingWithdrawals(multisig) - multisigBefore) - taxToMultisig;
        uint256 clogToWinnerPot = (winnerPot.balance - winnerPotBefore) - (taxAmount - taxToOwner - taxToMultisig);

        assertEq(clogToMultisig, (extracted * market.MULTISIG_CLOG_BPS()) / 10_000, "CLOG extraction's own multisig leg is still exactly 10% of extracted, unchanged by this task");
        assertEq(clogToWinnerPot, extracted - clogToMultisig, "CLOG extraction's own WinnerPot leg is still the residual (~90%), unchanged by this task");
        assertEq(market.pendingWithdrawals(ticketOwner) - ownerBefore, taxToOwner, "CLOG extraction has no ticker-owner leg at all - the owner's own pending balance changes ONLY by the trading-tax portion");
        assertEq(market.MULTISIG_CLOG_BPS(), 1_000, "CLOG extraction split constant itself is untouched: still 10%");
        assertEq(market.WINNERPOT_CLOG_BPS(), 9_000, "CLOG extraction split constant itself is untouched: still 90%");
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
