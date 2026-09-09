// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract MockHolder {
    receive() external payable {}
}

contract RevertingHolder {
    receive() external payable {
        revert("nope");
    }
}

contract RewardVaultTest is Test {
    RewardVault vault;
    MockMarket market;
    MemeToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        vault = new RewardVault(address(this)); // test contract acts as RoundManager
        market = new MockMarket("Cat", "CAT");
        token = market.token();
    }

    function _fund(uint256 amount) internal {
        (bool ok,) = address(vault).call{value: amount}("");
        require(ok);
    }

    // ── Basic allocation + claim flow ────────────────────────────────────

    function test_fullFlow_allocateAndClaim() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 500 ether);
        market.distribute(bob, 500 ether);
        vm.warp(windowStart + 3600);
        uint256 windowEnd = this._now();

        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, windowEnd);

        uint256 aliceBalBefore = alice.balance;
        vault.claim(1, alice);
        assertApproxEqAbs(alice.balance - aliceBalBefore, 5 ether, 1e12);
    }

    function test_protocolInventoryExclusion_marketCannotClaim() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vm.expectRevert();
        vault.claim(1, address(market));
    }

    function test_smartContractWalletHolder_canClaim() public {
        MockHolder holder = new MockHolder();
        uint256 windowStart = this._now();
        market.distribute(address(holder), 1000 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vault.claim(1, address(holder));
        assertApproxEqAbs(address(holder).balance, 10 ether, 1e12);
    }

    function test_brokenHolderWallet_doesNotBlockOthersClaims() public {
        RevertingHolder bad = new RevertingHolder();
        uint256 windowStart = this._now();
        market.distribute(address(bad), 500 ether);
        market.distribute(alice, 500 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vm.expectRevert();
        vault.claim(1, address(bad));

        vault.claim(1, alice);
        assertApproxEqAbs(alice.balance, 5 ether, 1e12);
    }

    // ── Timing scenarios ──────────────────────────────────────────────────

    function test_buyAtBeginningVsMiddleVsFinalMinute() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 3600 ether);
        vm.warp(windowStart + 1800);
        market.distribute(bob, 3600 ether);
        address carol = address(0xCA401);
        vm.warp(windowStart + 3600 - 60);
        market.distribute(carol, 3600 ether);
        vm.warp(windowStart + 3600);
        uint256 windowEnd = this._now();

        _fund(3600 ether);
        vault.allocateRound(1, 7, address(market), windowStart, windowEnd);

        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore = bob.balance;
        uint256 carolBalBefore = carol.balance;
        vault.claim(1, alice);
        vault.claim(1, bob);
        vault.claim(1, carol);

        uint256 aliceGot = alice.balance - aliceBalBefore;
        uint256 bobGot = bob.balance - bobBalBefore;
        uint256 carolGot = carol.balance - carolBalBefore;
        assertGt(aliceGot, bobGot, "held longest -> got the most");
        assertGt(bobGot, carolGot, "held longer than carol -> got more");
        assertApproxEqRel(aliceGot, bobGot * 2, 0.02e18, "alice's window was exactly 2x bob's");
    }

    function test_sellHalfwayThroughRound_reducesShareProportionally() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 1000 ether);
        vm.warp(windowStart + 1800);
        vm.prank(alice);
        token.transfer(address(market), 1000 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vault.claim(1, alice);
        uint256 twab = token.twabOf(alice, windowStart, windowStart + 3600);
        assertApproxEqAbs(twab, 500 ether, 1);
    }

    function test_walletToWalletTransfer_recipientCanClaimForPostTransferPortion() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 1000 ether);
        vm.warp(windowStart + 1200);
        vm.prank(alice);
        token.transfer(bob, 1000 ether);
        vm.warp(windowStart + 3600);
        _fund(30 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        vault.claim(1, alice);
        vault.claim(1, bob);
        uint256 aliceGot = alice.balance - aliceBefore;
        uint256 bobGot = bob.balance - bobBefore;
        assertApproxEqRel(bobGot, aliceGot * 2, 0.02e18);
    }

    function test_buyingAfterClose_doesNotEarnAnyShareOfThatRound() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 1000 ether);
        vm.warp(windowStart + 3600);
        uint256 windowEnd = this._now();
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, windowEnd);

        market.distribute(bob, 1000 ether);

        assertEq(vault.previewClaim(1, bob), 0, "buying after close must not earn any share of that round");
    }

    function test_buyingAfterWinnerKnown_doesNotEarnAnyShareOfThatRound() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 1000 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        market.distribute(bob, 5000 ether);
        assertEq(vault.previewClaim(1, bob), 0);
    }

    // ── Double claim / batch claim ────────────────────────────────────────

    function test_doubleClaim_reverts() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vault.claim(1, alice);
        vm.expectRevert();
        vault.claim(1, alice);
    }

    function test_batchClaim_multipleRounds() public {
        uint256 s1 = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(s1 + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), s1, this._now());

        uint256 s2 = this._now();
        vm.warp(s2 + 3600);
        _fund(20 ether);
        vault.allocateRound(2, 7, address(market), s2, this._now());

        uint256[] memory roundIds = new uint256[](2);
        roundIds[0] = 1;
        roundIds[1] = 2;
        uint256 before = alice.balance;
        vault.claimBatch(roundIds, alice);
        uint256 got = alice.balance - before;

        assertApproxEqAbs(got, 30 ether, 1e12);
        assertTrue(vault.claimed(1, alice));
        assertTrue(vault.claimed(2, alice));
    }

    function test_batchClaim_cannotDoubleClaimWithinBatch() public {
        uint256 s1 = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(s1 + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), s1, this._now());

        uint256[] memory roundIds = new uint256[](2);
        roundIds[0] = 1;
        roundIds[1] = 1;
        vm.expectRevert();
        vault.claimBatch(roundIds, alice);
    }

    // ── 90-day expiration + rollover ──────────────────────────────────────

    function test_claimAfter90Days_reverts() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vm.warp(this._now() + 90 days + 1);
        vm.expectRevert();
        vault.claim(1, alice);
    }

    function test_claimJustBefore90Days_succeeds() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vm.warp(this._now() + 90 days - 1);
        vault.claim(1, alice);
        assertTrue(vault.claimed(1, alice));
    }

    function test_sweepExpired_rollsUnclaimedIntoLivePool() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 50 ether);
        market.distribute(bob, 50 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vault.claim(1, alice);
        vm.warp(this._now() + 90 days + 1);

        uint256 poolBefore = vault.unallocatedPool();
        vault.sweepExpired(1);
        uint256 poolAfter = vault.unallocatedPool();
        assertApproxEqAbs(poolAfter - poolBefore, 5 ether, 1e12, "bob's unclaimed ~5 ether rolls into the live pool");

        uint256 s2 = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(s2 + 3600);
        vault.allocateRound(2, 7, address(market), s2, this._now());
        RewardVault.RoundAllocation memory alloc2 = vault.getAllocation(2);
        assertApproxEqAbs(alloc2.jackpotAmount, 5 ether, 1e12, "round 2's jackpot includes round 1's rolled-over dust");
    }

    function test_sweepExpired_cannotSweepTwice() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());
        vm.warp(this._now() + 90 days + 1);
        vault.sweepExpired(1);
        vm.expectRevert();
        vault.sweepExpired(1);
    }

    function test_sweepExpired_cannotSweepBeforeExpiry() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 100 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());
        vm.expectRevert();
        vault.sweepExpired(1);
    }

    function test_claimAfterSweep_reverts() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 50 ether);
        market.distribute(bob, 50 ether);
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());
        vm.warp(this._now() + 90 days + 1);
        vault.sweepExpired(1);
        vm.expectRevert();
        vault.claim(1, bob);
    }

    // ── Dust / rounding ────────────────────────────────────────────────────

    function test_dustFromRoundingIsCapturedByTotalClaimedAccounting() public {
        uint256 windowStart = this._now();
        address carol = address(0xCA401);
        market.distribute(alice, 1 ether);
        market.distribute(bob, 1 ether);
        market.distribute(carol, 1 ether);
        vm.warp(windowStart + 3600);
        _fund(10);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        vault.claim(1, alice);
        vault.claim(1, bob);
        vault.claim(1, carol);

        RewardVault.RoundAllocation memory a = vault.getAllocation(1);
        assertLe(a.totalClaimed, a.jackpotAmount, "sum of claims can never exceed the jackpot");
        vm.warp(this._now() + 90 days + 1);
        uint256 poolBefore = vault.unallocatedPool();
        vault.sweepExpired(1);
        assertEq(vault.unallocatedPool() - poolBefore, a.jackpotAmount - a.totalClaimed);
    }

    // ── Sybil wallet splitting ─────────────────────────────────────────────

    function test_sybilSplitting_preservesAggregateClaimEntitlement() public {
        uint256 windowStart = this._now();
        market.distribute(alice, 1000 ether);

        address[] memory sybils = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            sybils[i] = address(uint160(0xF00D0000 + i));
            market.distribute(sybils[i], 100 ether);
        }

        vm.warp(windowStart + 3600);
        _fund(20 ether);
        vault.allocateRound(1, 7, address(market), windowStart, this._now());

        uint256 aliceBefore = alice.balance;
        vault.claim(1, alice);
        uint256 aliceGot = alice.balance - aliceBefore;

        uint256 sybilTotal = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 before = sybils[i].balance;
            vault.claim(1, sybils[i]);
            sybilTotal += sybils[i].balance - before;
        }

        assertApproxEqAbs(sybilTotal, aliceGot, 1e12, "splitting into 10 wallets must not change aggregate entitlement");
    }

    // ── Access control ─────────────────────────────────────────────────────

    function test_allocateRound_onlyRoundManager() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        vault.allocateRound(1, 7, address(market), 0, 100);
    }

    function test_allocateRound_cannotAllocateTwice() public {
        uint256 windowStart = this._now();
        vm.warp(windowStart + 3600);
        _fund(10 ether);
        uint256 windowEnd = this._now();
        vault.allocateRound(1, 7, address(market), windowStart, windowEnd);
        vm.expectRevert();
        vault.allocateRound(1, 7, address(market), windowStart, windowEnd);
    }
}
