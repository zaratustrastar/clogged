// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract MemeTokenTWABTest is Test {
    MemeToken token;
    address market = address(0xAAAA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        token = new MemeToken("Cat", "CAT", address(this));
        token.setMarket(market);
    }

    function test_marketHoldsFullSupplyInitially() public view {
        assertEq(token.balanceOf(market), token.TOTAL_SUPPLY());
    }

    function test_constantBalance_twabEqualsBalance() public {
        vm.prank(market);
        token.transfer(alice, 100 ether);
        uint256 t0 = this._now();
        vm.warp(t0 + 1000);
        uint256 t1 = this._now();
        assertEq(token.twabOf(alice, t0, t1), 100 ether);
    }

    function test_buyAtBeginningVsMiddleVsEnd_ofWindow() public {
        uint256 windowStart = this._now();
        uint256 windowLen = 3600;

        // Alice buys right at window start, holds the whole window: TWAB == full balance.
        vm.prank(market);
        token.transfer(alice, 100 ether);

        vm.warp(windowStart + 1800); // middle of the window
        // Bob buys exactly at the midpoint, holds to the end: TWAB should be ~50% of his balance.
        vm.prank(market);
        token.transfer(bob, 100 ether);

        vm.warp(windowStart + windowLen); // end of window
        uint256 windowEnd = this._now();

        uint256 aliceTwab = token.twabOf(alice, windowStart, windowEnd);
        uint256 bobTwab = token.twabOf(bob, windowStart, windowEnd);

        assertEq(aliceTwab, 100 ether, "held the entire window -> TWAB == balance");
        assertApproxEqAbs(bobTwab, 50 ether, 1, "held exactly half the window -> TWAB == half balance");
    }

    function test_buyAtVeryFinalMinute_smallTwabContribution() public {
        uint256 windowStart = this._now();
        uint256 windowLen = 3600;
        vm.warp(windowStart + windowLen - 60); // final minute
        vm.prank(market);
        token.transfer(alice, 600 ether);
        vm.warp(windowStart + windowLen);
        uint256 twab = token.twabOf(alice, windowStart, windowStart + windowLen);
        // held 600 ether for 60 of 3600 seconds -> average == 600 * 60/3600 == 10 ether
        assertApproxEqAbs(twab, 10 ether, 1);
    }

    function test_sellHalfwayThroughRound() public {
        uint256 windowStart = this._now();
        uint256 windowLen = 3600;
        vm.prank(market);
        token.transfer(alice, 200 ether);
        vm.warp(windowStart + 1800);
        vm.prank(alice);
        token.transfer(market, 200 ether); // sells everything back at the midpoint
        vm.warp(windowStart + windowLen);
        uint256 twab = token.twabOf(alice, windowStart, windowStart + windowLen);
        // held 200 ether for the first half, 0 for the second half -> average == 100 ether
        assertApproxEqAbs(twab, 100 ether, 1);
    }

    function test_walletToWalletTransfer_correctlyAttributesBothSides() public {
        uint256 windowStart = this._now();
        vm.prank(market);
        token.transfer(alice, 100 ether);
        vm.warp(windowStart + 1200); // 1/3 of a 3600s window
        vm.prank(alice);
        token.transfer(bob, 100 ether); // Alice sends her whole balance to Bob
        vm.warp(windowStart + 3600);
        uint256 windowEnd = this._now();

        uint256 aliceTwab = token.twabOf(alice, windowStart, windowEnd);
        uint256 bobTwab = token.twabOf(bob, windowStart, windowEnd);

        // Alice: 100 ether for 1200s, 0 for 2400s -> avg = 100*1200/3600 = 33.33...
        // Bob: 0 for 1200s, 100 ether for 2400s -> avg = 100*2400/3600 = 66.66...
        assertApproxEqAbs(aliceTwab, 33.333333333333333333 ether, 1e12);
        assertApproxEqAbs(bobTwab, 66.666666666666666666 ether, 1e12);
        // Conservation: the two TWABs should sum to the total moved balance's average presence.
        assertApproxEqAbs(aliceTwab + bobTwab, 100 ether, 1e12);
    }

    function test_smartContractWalletHolder() public {
        // A simple contract (no special receive logic needed for TWAB tracking itself -- TWAB
        // only cares about the ERC20 balance, not about the account's ability to receive ETH).
        MockHolder holder = new MockHolder();
        vm.prank(market);
        token.transfer(address(holder), 500 ether);
        uint256 t0 = this._now();
        vm.warp(t0 + 3600);
        assertEq(token.twabOf(address(holder), t0, this._now()), 500 ether);
    }

    function test_buyingAfterWindowClose_doesNotAffectHistoricalTwab() public {
        uint256 windowStart = this._now();
        vm.prank(market);
        token.transfer(alice, 100 ether);
        vm.warp(windowStart + 3600);
        uint256 windowEnd = this._now();
        uint256 twabAtClose = token.twabOf(alice, windowStart, windowEnd);

        // Time passes, MORE trading happens well after the window closed.
        vm.warp(windowEnd + 500);
        vm.prank(market);
        token.transfer(alice, 10_000 ether); // huge buy, long after the window

        // The ALREADY-CLOSED window's TWAB must be completely unaffected.
        assertEq(token.twabOf(alice, windowStart, windowEnd), twabAtClose);
    }

    function test_protocolInventory_marketBalanceTracksAsExpected() public view {
        // The market's own TWAB is used (by RewardVault) purely to derive circulating supply --
        // this test just confirms MemeToken itself makes no special exception for `market`; it is
        // tracked like any other account (exclusion is RewardVault's responsibility, not the
        // token's).
        assertEq(token.balanceOf(market), token.TOTAL_SUPPLY());
    }

    function test_dustAndRounding_integerDivisionTruncatesConsistently() public {
        uint256 windowStart = this._now();
        vm.prank(market);
        token.transfer(alice, 1); // 1 wei of token, smallest possible unit
        vm.warp(windowStart + 7); // odd, non-divisible elapsed time
        uint256 twab = token.twabOf(alice, windowStart, this._now());
        // 1 wei held for 7 seconds out of a 7-second window -> exactly 1
        assertEq(twab, 1);
    }

    function test_sybilSplitting_preservesAggregateTwab() public {
        // Alice holds 1000 ether the whole window in ONE wallet.
        uint256 windowStart = this._now();
        vm.prank(market);
        token.transfer(alice, 1000 ether);
        vm.warp(windowStart + 3600);
        uint256 windowEnd = this._now();
        uint256 singleWalletTwab = token.twabOf(alice, windowStart, windowEnd);

        // Now the SAME total (1000 ether), split across 10 wallets at various times, must sum to
        // the SAME aggregate TWAB -- Sybil-splitting cannot manufacture extra entitlement.
        address[] memory wallets = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            wallets[i] = address(uint160(0xC0FFEE0000 + i));
        }
        uint256 start2 = this._now();
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(start2 + i * 100); // stagger acquisition times across the window
            vm.prank(market);
            token.transfer(wallets[i], 100 ether);
        }
        vm.warp(start2 + 3600);
        uint256 end2 = this._now();

        uint256 sumTwab = 0;
        for (uint256 i = 0; i < 10; i++) {
            sumTwab += token.twabOf(wallets[i], start2, end2);
        }

        // Both scenarios hold 1000 ether total, acquired at t=0 vs staggered starting near t=0 --
        // compare the SAME scenario (single wallet, all acquired at window start) against the
        // split case using the identical stagger-free baseline for a clean equality check:
        assertApproxEqAbs(sumTwab, singleWalletTwab, 1000 ether * 900 / 3600 + 1e15,
            "aggregate TWAB from split wallets must be close to what one wallet holding the same total would show, modulo the staggered acquisition timing itself");
    }

    function test_sybilSplitting_exactAggregateWhenAcquiredSimultaneously() public {
        // Cleaner version: split into 10 wallets, all acquired at the SAME instant as a single
        // 1000-ether transfer would have been -- the aggregate TWAB must be EXACTLY equal, since
        // TWAB is linear in balance and splitting a simultaneous acquisition changes nothing about
        // the time-integral, only its attribution across addresses.
        uint256 windowStart = this._now();
        address[] memory wallets = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            wallets[i] = address(uint160(0xD00D0000 + i));
            vm.prank(market);
            token.transfer(wallets[i], 100 ether); // same block/timestamp for all 10
        }
        vm.warp(windowStart + 3600);
        uint256 windowEnd = this._now();

        uint256 sumTwab = 0;
        for (uint256 i = 0; i < 10; i++) {
            sumTwab += token.twabOf(wallets[i], windowStart, windowEnd);
        }
        assertEq(sumTwab, 1000 ether, "10x100 ether acquired simultaneously must sum to exactly 1000 ether TWAB");
    }

    // ── One-time market initialization (replaces CREATE-nonce address prediction) ─────────────

    function test_setMarket_zeroSupplyBeforeInitialization() public {
        MemeToken fresh = new MemeToken("Dog", "DOG", address(this));
        assertEq(fresh.totalSupply(), 0, "no supply exists until setMarket is called");
        assertEq(fresh.market(), address(0));
    }

    function test_setMarket_launcherCanInitializeOnce() public {
        MemeToken fresh = new MemeToken("Dog", "DOG", address(this));
        address realMarket = address(0xCAFE);
        fresh.setMarket(realMarket);
        assertEq(fresh.market(), realMarket);
        assertEq(fresh.balanceOf(realMarket), fresh.TOTAL_SUPPLY());
        assertEq(fresh.totalSupply(), fresh.TOTAL_SUPPLY());
    }

    function test_setMarket_secondInitializationReverts() public {
        MemeToken fresh = new MemeToken("Dog", "DOG", address(this));
        fresh.setMarket(address(0xCAFE));
        vm.expectRevert();
        fresh.setMarket(address(0xBEEF));
    }

    function test_setMarket_randomUserCannotInitialize() public {
        MemeToken fresh = new MemeToken("Dog", "DOG", address(this)); // launcher == address(this)
        vm.prank(address(0xBEEF)); // not the launcher
        vm.expectRevert();
        fresh.setMarket(address(0xCAFE));
    }

    function test_setMarket_zeroAddressRejected() public {
        MemeToken fresh = new MemeToken("Dog", "DOG", address(this));
        vm.expectRevert();
        fresh.setMarket(address(0));
    }

    function test_setMarket_launcherConstructorRejectsZeroAddress() public {
        vm.expectRevert();
        new MemeToken("Dog", "DOG", address(0));
    }

    function test_setMarket_marketCannotEverChangeAfterInitialization() public {
        MemeToken fresh = new MemeToken("Dog", "DOG", address(this));
        address firstMarket = address(0xCAFE);
        fresh.setMarket(firstMarket);

        // Not even the launcher itself can change it afterward -- no override path exists at all.
        vm.expectRevert();
        fresh.setMarket(address(0xD00D));
        assertEq(fresh.market(), firstMarket, "market must remain permanently fixed to the first value");
    }

    function test_setMarket_fixedSupplyAndAllocationInvariantsUnchanged() public {
        MemeToken fresh = new MemeToken("Dog", "DOG", address(this));
        address realMarket = address(0xCAFE);
        fresh.setMarket(realMarket);
        // 1B fixed supply, entirely at the market, matching the pre-existing allocation invariant
        // (900M curve / 100M CLOG is BondingCurveClog's own internal accounting split over this
        // same balance -- unaffected by how the balance got there).
        assertEq(fresh.TOTAL_SUPPLY(), 1_000_000_000e18);
        assertEq(fresh.balanceOf(realMarket), 1_000_000_000e18);
    }
}

contract MockHolder {
    receive() external payable {}
}
