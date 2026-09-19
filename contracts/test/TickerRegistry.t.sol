// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickerRegistry} from "../src/TickerRegistry.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";

contract TickerRegistryTest is Test {
    TickerRegistry registry;
    TickerNFT nft;
    EligibilityRegistry engine;

    address governance = address(0x60401);
    address multisig = address(0xA51);
    address winnerPot = address(0xB0B0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B1);

    uint256 constant BUFFER_BPS = 20_000;
    uint256 virtualTokenSeed = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 virtualEthSeed;

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        virtualEthSeed = (5e9 * virtualTokenSeed) / 1e18;

        engine = new EligibilityRegistry(address(this));
        engine.setRoundManager(address(0xD00D));

        nft = new TickerNFT("Ticker", "TICK", address(this), "https://example.com/metadata/");
        registry = new TickerRegistry(
            address(engine), address(nft), multisig, winnerPot, governance, virtualEthSeed, BUFFER_BPS
        );
        nft.setRegistry(address(registry));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _commitAndReveal(address user, string memory ticker, bytes32 salt) internal returns (uint256 tokenId) {
        bytes32 hash = keccak256(abi.encode(user, registry.tickerKeyOf(ticker), salt));
        vm.prank(user);
        registry.commit(hash);
        vm.warp(this._now() + registry.MIN_REVEAL_DELAY());
        uint256 price = registry.LAUNCH_PRICE(); // capture BEFORE the prank, so evaluating it here
            // doesn't consume the prank meant for reveal() itself (vm.prank only affects the very
            // next call, and `registry.LAUNCH_PRICE()` inside the {value: ...} expression below
            // would otherwise be that call).
        vm.prank(user);
        tokenId = registry.reveal{value: price}(ticker, salt);
    }

    /// @dev Does commit + the reveal-delay warp, but stops short of actually calling reveal --
    ///      lets callers wrap ONLY the reveal() call itself in vm.expectRevert(), rather than the
    ///      whole multi-step helper (wrapping a helper that itself makes an earlier external call,
    ///      e.g. tickerKeyOf(), would have expectRevert catch THAT call instead of reveal()).
    function _commitAndWarp(address user, string memory ticker, bytes32 salt) internal returns (uint256 price) {
        bytes32 hash = keccak256(abi.encode(user, registry.tickerKeyOf(ticker), salt));
        vm.prank(user);
        registry.commit(hash);
        vm.warp(this._now() + registry.MIN_REVEAL_DELAY());
        price = registry.LAUNCH_PRICE();
    }

    function test_fullLaunchFlow_mintsNFTAndDeploysMeme() public {
        uint256 tokenId = _commitAndReveal(alice, "cat", bytes32("salt1"));
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(registry.tickerOf(1), "CAT");

        MemeToken token = MemeToken(registry.tokenOf(1));
        BondingCurveClog market = BondingCurveClog(registry.marketOf(1));
        assertEq(token.market(), address(market));
        assertEq(token.balanceOf(address(market)), token.TOTAL_SUPPLY());
        assertEq(market.ticketOwnerRecipient(), alice, "ticker owner resolves via TickerNFT.ownerOf");
        assertEq(engine.tokenMarket(1), address(market), "registered with EligibilityRegistry");
    }

    function test_launchPayment_routedCorrectly() public {
        uint256 multisigBefore = multisig.balance;
        uint256 winnerPotBefore = winnerPot.balance;
        _commitAndReveal(alice, "cat", bytes32("salt1"));
        uint256 expectedMultisig = (0.002 ether * 10000) / 10000;
        assertEq(multisig.balance - multisigBefore, expectedMultisig);
        assertEq(winnerPot.balance - winnerPotBefore, 0.002 ether - expectedMultisig);
    }

    function test_creatorProvidesZeroLiquidity() public {
        _commitAndReveal(alice, "cat", bytes32("salt1"));
        BondingCurveClog market = BondingCurveClog(registry.marketOf(1));
        assertEq(market.realETH(), 0, "creator provides zero curve liquidity at launch");
    }

    function test_ownershipTransferRedirectsFutureFees() public {
        _commitAndReveal(alice, "cat", bytes32("salt1"));
        BondingCurveClog market = BondingCurveClog(registry.marketOf(1));
        assertEq(market.ticketOwnerRecipient(), alice);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertEq(market.ticketOwnerRecipient(), bob, "fee recipient must update immediately, no migration step");

        // Task D: the redirect must carry the real 40% owner share, not just the address - a
        // subsequent trade's own tax must credit bob (the new owner), never alice, at exactly
        // TICKER_OWNER_TAX_BPS (40% of the tax).
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        market.buy{value: 1 ether}(0, block.timestamp);
        uint256 expectedTax = (1 ether * market.BUY_TAX_BPS()) / 10_000;
        uint256 expectedOwnerShare = (expectedTax * market.TICKER_OWNER_TAX_BPS()) / 10_000;
        assertEq(market.pendingWithdrawals(bob), expectedOwnerShare, "new owner (bob) receives exactly 40% of the tax on the very next trade");
        assertEq(market.pendingWithdrawals(alice), 0, "old owner (alice) receives nothing from any trade after the transfer");
    }

    function test_publicTickerCap_enforced() public {
        // publicTickerCount is a plain (non-immutable) uint256 storage variable; find its slot
        // empirically rather than assuming a specific index, since immutables/constants don't
        // consume storage and the exact slot layout is an implementation detail worth verifying,
        // not assuming.
        bool foundSlot = false;
        for (uint256 slot = 0; slot < 20; slot++) {
            bytes32 original = vm.load(address(registry), bytes32(slot));
            vm.store(address(registry), bytes32(slot), bytes32(registry.MAX_PUBLIC_TICKERS()));
            if (registry.publicTickerCount() == registry.MAX_PUBLIC_TICKERS()) {
                foundSlot = true;
                break;
            }
            vm.store(address(registry), bytes32(slot), original); // restore and keep searching
        }
        require(foundSlot, "could not locate publicTickerCount storage slot");
        assertEq(registry.publicTickerCount(), registry.MAX_PUBLIC_TICKERS());

        uint256 price = _commitAndWarp(alice, "cat", bytes32("salt1"));
        vm.prank(alice);
        vm.expectRevert();
        registry.reveal{value: price}("cat", bytes32("salt1"));
    }

    function test_clogReserved_allCaseVariants() public {
        string[4] memory variants = ["CLOG", "clog", "Clog", "ClOg"];
        bytes32[4] memory salts = [bytes32("salt1"), bytes32("salt2"), bytes32("salt3"), bytes32("salt4")];
        for (uint256 i = 0; i < 4; i++) {
            uint256 price = _commitAndWarp(alice, variants[i], salts[i]);
            vm.prank(alice);
            vm.expectRevert();
            registry.reveal{value: price}(variants[i], salts[i]);
        }
    }

    function test_normalization_lowercaseUppercasedConsistently() public {
        uint256 tokenId = _commitAndReveal(alice, "dog", bytes32("salt1"));
        assertEq(registry.tickerOf(tokenId), "DOG");
    }

    function test_normalization_mixedCase() public {
        uint256 tokenId = _commitAndReveal(alice, "DoG", bytes32("salt1"));
        assertEq(registry.tickerOf(tokenId), "DOG");
    }

    function test_normalization_rejectsDigits() public {
        vm.expectRevert();
        registry.normalize("cat1");
    }

    function test_normalization_rejectsSymbols() public {
        vm.expectRevert();
        registry.normalize("ca-t");
    }

    function test_normalization_rejectsUnicode() public {
        vm.expectRevert();
        registry.normalize(unicode"caté");
    }

    function test_normalization_rejectsTooShort() public {
        vm.expectRevert();
        registry.normalize("a");
    }

    function test_normalization_rejectsTooLong() public {
        vm.expectRevert();
        registry.normalize("abcdefghijk");
    }

    function test_normalization_maxLengthBoundaryAccepted() public {
        uint256 tokenId = _commitAndReveal(alice, "abcdefghij", bytes32("salt1"));
        assertEq(registry.tickerOf(tokenId), "ABCDEFGHIJ");
    }

    function test_uniqueness_secondLaunchOfSameTickerReverts() public {
        _commitAndReveal(alice, "cat", bytes32("salt1"));
        uint256 price = _commitAndWarp(bob, "cat", bytes32("salt2"));
        vm.prank(bob);
        vm.expectRevert();
        registry.reveal{value: price}("cat", bytes32("salt2"));
    }

    function test_uniqueness_caseInsensitiveCollision() public {
        _commitAndReveal(alice, "cat", bytes32("salt1"));
        uint256 price = _commitAndWarp(bob, "CAT", bytes32("salt2"));
        vm.prank(bob);
        vm.expectRevert();
        registry.reveal{value: price}("CAT", bytes32("salt2"));
    }

    function test_reveal_tooEarly_reverts() public {
        bytes32 hash = keccak256(abi.encode(alice, registry.tickerKeyOf("cat"), bytes32("salt1")));
        vm.prank(alice);
        registry.commit(hash);
        vm.prank(alice);
        vm.expectRevert();
        registry.reveal{value: 0.002 ether}("cat", bytes32("salt1"));
    }

    function test_reveal_afterExpiry_reverts() public {
        bytes32 hash = keccak256(abi.encode(alice, registry.tickerKeyOf("cat"), bytes32("salt1")));
        vm.prank(alice);
        registry.commit(hash);
        vm.warp(this._now() + registry.MIN_REVEAL_DELAY() + registry.REVEAL_WINDOW() + 1);
        vm.prank(alice);
        vm.expectRevert();
        registry.reveal{value: 0.002 ether}("cat", bytes32("salt1"));
    }

    function test_reveal_withoutCommitment_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.reveal{value: 0.002 ether}("cat", bytes32("salt1"));
    }

    function test_reveal_senderBinding_onlyCommitterCanReveal() public {
        bytes32 hash = keccak256(abi.encode(alice, registry.tickerKeyOf("cat"), bytes32("salt1")));
        vm.prank(alice);
        registry.commit(hash);
        vm.warp(this._now() + registry.MIN_REVEAL_DELAY());

        vm.prank(bob);
        vm.expectRevert();
        registry.reveal{value: 0.002 ether}("cat", bytes32("salt1"));
    }

    function test_reveal_tickerBinding_cannotSwapTickerAtReveal() public {
        bytes32 hash = keccak256(abi.encode(alice, registry.tickerKeyOf("cat"), bytes32("salt1")));
        vm.prank(alice);
        registry.commit(hash);
        vm.warp(this._now() + registry.MIN_REVEAL_DELAY());
        vm.prank(alice);
        vm.expectRevert();
        registry.reveal{value: 0.002 ether}("dog", bytes32("salt1"));
    }

    function test_reveal_replayProtection_cannotRevealTwice() public {
        _commitAndReveal(alice, "cat", bytes32("salt1"));
        bytes32 hash = keccak256(abi.encode(alice, registry.tickerKeyOf("cat"), bytes32("salt1")));
        assertEq(registry.commitTimestamp(hash), 0, "commitment must be consumed after use");
    }

    function test_commit_duplicateCommitReverts() public {
        bytes32 hash = keccak256(abi.encode(alice, registry.tickerKeyOf("cat"), bytes32("salt1")));
        vm.prank(alice);
        registry.commit(hash);
        vm.prank(bob);
        vm.expectRevert();
        registry.commit(hash);
    }

    function test_wrongPayment_reverts() public {
        bytes32 hash = keccak256(abi.encode(alice, registry.tickerKeyOf("cat"), bytes32("salt1")));
        vm.prank(alice);
        registry.commit(hash);
        vm.warp(this._now() + registry.MIN_REVEAL_DELAY());
        vm.prank(alice);
        vm.expectRevert();
        registry.reveal{value: 0.001 ether}("cat", bytes32("salt1"));
    }
}
