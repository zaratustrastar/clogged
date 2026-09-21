// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {MockRandomnessProvider} from "./mocks/MockRandomnessProvider.sol";
import {MockTickerNFT} from "./mocks/MockTickerNFT.sol";

/// @notice Full-stack integration test: real BondingCurveClog trading, real EligibilityRegistry
///         qualification (including the close-time retroactive finalization), real RoundManager
///         lifecycle, real MemeToken TWAB, real RewardVault claims -- no mocks except the VRF
///         provider itself (Chainlink can't run in a local test). This is the "Alice/Bob hold CAT
///         during Round N -> Round N closes -> TWAB frozen -> CAT wins -> Alice/Bob claim
///         pro-rata -> later trades cannot change it" flow, end to end.
contract EndToEndTest is Test {
    EligibilityRegistry engine;
    RoundManager rm;
    RewardVault vault;
    MockRandomnessProvider provider;
    address governance = address(0x60401);
    address ticketOwner = address(0x71CE);
    address multisig = address(0xA51);

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant BUFFER_BPS = 20_000; // 2.0x, Config G
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18; // P0 = 5e-9 ETH/token

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        provider = new MockRandomnessProvider();
        engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        rm = new RoundManager(address(engine), address(provider), governance);
        engine.setRoundManager(address(rm));
        provider.setRoundManager(address(rm));

        vault = new RewardVault(address(rm));
        vm.prank(governance);
        rm.setRewardVault(address(vault));

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    /// @dev Closing a round is now fully O(1) -- candidate qualification happens live, during the
    ///      round itself, so there is nothing left to finalize at close.
    function _closeRound() internal returns (uint256 closedRoundId) {
        closedRoundId = rm.closeRoundAndOpenNext();
    }

    /// @dev Deploys a real MemeToken + BondingCurveClog pair and registers it with the engine.
    ///      Simple explicit deployment order (MemeToken first with zero supply, BondingCurveClog
    ///      second passing MemeToken's real address, then a one-time setMarket call) -- no address
    ///      prediction needed. Uses a MockTickerNFT (this is a lower-level integration test that
    ///      predates TickerRegistry -- the full commit-reveal launch flow gets its own tests).
    function _launchMeme(string memory name, string memory symbol) internal returns (uint256 tokenId, MemeToken token, BondingCurveClog curve) {
        uint256 predictedTokenId = engine.nextTokenId();
        MockTickerNFT tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(predictedTokenId, ticketOwner);

        token = new MemeToken(name, symbol, address(this));
        curve = new BondingCurveClog(
            address(token), address(tickerNFT), predictedTokenId, multisig, address(vault), governance, address(engine), VIRTUAL_ETH_SEED, BUFFER_BPS
        );
        token.setMarket(address(curve));
        tokenId = engine.registerToken(address(curve));
        require(tokenId == predictedTokenId, "token id prediction mismatch");
    }

    function test_fullLifecycle_buyHoldWinClaim() public {
        (uint256 catId, MemeToken catToken, BondingCurveClog catMarket) = _launchMeme("Cat", "CAT");
        (uint256 dogId, MemeToken dogToken, BondingCurveClog dogMarket) = _launchMeme("Dog", "DOG");
        (uint256 fishId,, BondingCurveClog fishMarket) = _launchMeme("Fish", "FISH");

        // No age requirement: tokens launched just now can qualify directly into the currently
        // open round (round 1) -- no need to survive into a later round first.
        uint256 roundOpen = this._now();
        vm.prank(alice);
        catMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(catId); // permissionless "keeper" touch -- the ordinary-activity trigger

        vm.prank(bob);
        dogMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(dogId);

        vm.prank(alice);
        fishMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(fishId);

        // Hold for the required sustained duration.
        vm.warp(roundOpen + rm.ROUND_DURATION() / 2); // 30 minutes in, well before round 1 closes

        // A confirming touch after the 30-minute mark is what actually locks in qualification --
        // any ordinary trade or explicit `qualify` call works; using `qualify` here to demonstrate
        // the permissionless path directly.
        engine.qualify(catId);
        engine.qualify(dogId);
        engine.qualify(fishId);

        assertEq(engine.candidateCount(1), 3, "all three tokens qualify directly into round 1's own draw -- no lag");

        // Trading continues normally (proving settlement-in-progress never pauses it).
        vm.prank(bob);
        catMarket.buy{value: 1 ether}(0, block.timestamp);

        // Round 1 closes -- this is the very first round the protocol ever opened, and it draws
        // from its OWN candidates (no lag), so it can settle immediately.
        vm.warp(roundOpen + rm.ROUND_DURATION());
        uint256 closedRound = _closeRound();
        assertEq(closedRound, 1);
        RoundManager.RoundInfo memory info = rm.getRound(1);
        assertTrue(info.randomnessRequested);
        assertEq(info.candidateCount, 3);

        // VRF resolves -- force CAT to win by trying seeds until the unbiased index picks it
        // (deterministic search, not a mock override, so this exercises the real selection path).
        uint256 seed = 0;
        uint256 winner;
        do {
            seed++;
            uint256 idx = rm.exposedUnbiasedIndex(seed, 1, info.candidateCount);
            winner = engine.candidateAt(info.candidateRoundId, idx);
        } while (winner != catId && seed < 10000);
        assertEq(winner, catId, "search must find a seed that selects CAT within a reasonable bound");

        provider.fulfill(info.randomnessRequestId, seed);

        RoundManager.RoundInfo memory settled = rm.getRound(1);
        assertTrue(settled.settled);
        assertEq(settled.winnerTokenId, catId);

        // RewardVault should now have an allocation for round 1, using CAT's actual round-1 window
        // (the round that just closed and was drawn). Confirm that explicitly:
        RewardVault.RoundAllocation memory alloc = vault.getAllocation(1);
        assertEq(alloc.windowOpen, info.openTime);
        assertEq(alloc.windowClose, info.closeTime);
        assertEq(alloc.token, address(catToken));

        // Alice and Bob both hold CAT through round 1's window -- claim their pro-rata share.
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        vault.claim(1, alice);
        vault.claim(1, bob);
        assertGt(alice.balance, aliceBefore, "alice must receive a nonzero payout");
        assertGt(bob.balance, bobBefore, "bob must receive a nonzero payout");

        // DOG and FISH holders (dog/fish tokens, held by bob/alice respectively) get nothing from
        // round 1's CAT jackpot -- they simply have no allocation to claim against.
        assertGt(dogToken.balanceOf(bob), 0);
    }

    function test_laterTradesCannotChangeAnAlreadyClaimedRound() public {
        (uint256 catId,, BondingCurveClog catMarket) = _launchMeme("Cat", "CAT");
        address dummy2 = address(0xD001);
        address dummy3 = address(0xD002);
        (uint256 id2,, BondingCurveClog market2) = _launchMeme("Dog", "DOG");
        (uint256 id3,, BondingCurveClog market3) = _launchMeme("Fish", "FISH");

        uint256 roundOpen = this._now();
        vm.prank(alice);
        catMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(catId);
        vm.deal(dummy2, 10 ether);
        vm.prank(dummy2);
        market2.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(id2);
        vm.deal(dummy3, 10 ether);
        vm.prank(dummy3);
        market3.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(id3);

        vm.warp(roundOpen + rm.ROUND_DURATION() / 2);
        engine.qualify(catId);
        engine.qualify(id2);
        engine.qualify(id3);

        vm.warp(roundOpen + rm.ROUND_DURATION());
        _closeRound(); // round 1 closes and settles immediately -- no lag
        RoundManager.RoundInfo memory info = rm.getRound(1);

        uint256 seed = 0;
        uint256 winner;
        do {
            seed++;
            uint256 idx = rm.exposedUnbiasedIndex(seed, 1, info.candidateCount);
            winner = engine.candidateAt(info.candidateRoundId, idx);
        } while (winner != catId && seed < 10000);
        provider.fulfill(info.randomnessRequestId, seed);

        uint256 precomputedClaim = vault.previewClaim(1, alice);
        assertGt(precomputedClaim, 0);

        // Bob now buys MORE CAT, well after round 1 closed and CAT is known to have won. Kept
        // modest (0.5 ETH, not the originally-attempted 100 ETH) because Config G's curve is
        // deliberately steep: after Alice's earlier 5 ETH buy already consumes ~640.8M of the
        // 900M curve allocation, a 100 ETH buy mathematically demands ~1.016 BILLION tokens --
        // more than the entire curve allocation, let alone what's left -- and BondingCurveClog
        // correctly reverts with "exceeds available token inventory" rather than over-promising.
        // That revert is the inventory guard working as designed, not a bug; 0.5 ETH is still a
        // large, clearly-late buy relative to Alice's stake and fully exercises this test's point.
        vm.prank(bob);
        catMarket.buy{value: 0.5 ether}(0, block.timestamp);

        // Alice's claim must be COMPLETELY UNCHANGED by Bob's late trade.
        assertEq(vault.previewClaim(1, alice), precomputedClaim, "late trading must not alter an already-fixed round's claims");
        assertEq(vault.previewClaim(1, bob), 0, "bob's late buy earns nothing from round 1's already-closed window");
    }

    function test_lateArrivingWinnerPotRevenue_cannotRetroactivelyChangeAClosedRound() public {
        (uint256 catId,, BondingCurveClog catMarket) = _launchMeme("Cat", "CAT");
        address dummy2 = address(0xD001);
        address dummy3 = address(0xD002);
        (uint256 id2,, BondingCurveClog market2) = _launchMeme("Dog", "DOG");
        (uint256 id3,, BondingCurveClog market3) = _launchMeme("Fish", "FISH");

        uint256 roundOpen = this._now();
        vm.prank(alice);
        catMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(catId);
        vm.deal(dummy2, 10 ether);
        vm.prank(dummy2);
        market2.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(id2);
        vm.deal(dummy3, 10 ether);
        vm.prank(dummy3);
        market3.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(id3);

        vm.warp(roundOpen + rm.ROUND_DURATION() / 2);
        engine.qualify(catId);
        engine.qualify(id2);
        engine.qualify(id3);
        vm.warp(roundOpen + rm.ROUND_DURATION());
        _closeRound(); // round 1 closes and settles immediately -- no lag
        RoundManager.RoundInfo memory info = rm.getRound(1);

        uint256 seed = 0;
        uint256 winner;
        do {
            seed++;
            uint256 idx = rm.exposedUnbiasedIndex(seed, 1, info.candidateCount);
            winner = engine.candidateAt(info.candidateRoundId, idx);
        } while (winner != catId && seed < 10000);
        provider.fulfill(info.randomnessRequestId, seed);

        // Round 1 is now allocated -- its jackpot is FROZEN.
        RewardVault.RoundAllocation memory allocBefore = vault.getAllocation(1);
        uint256 frozenJackpot = allocBefore.jackpotAmount;
        assertGt(frozenJackpot, 0);

        // Simulate late-arriving winnerPot revenue reaching the SAME vault, well after round 1's
        // allocation already happened -- whether this came from a permissionless flush of
        // previously-pending revenue or from ordinary later trading on any market makes no
        // difference to the guarantee being tested: RewardVault's allocation is a one-time
        // snapshot, never revisited.
        vm.deal(address(this), 5 ether);
        (bool ok,) = address(vault).call{value: 5 ether}("");
        require(ok);

        RewardVault.RoundAllocation memory allocAfter = vault.getAllocation(1);
        assertEq(allocAfter.jackpotAmount, frozenJackpot, "an already-closed round's jackpot must never retroactively change");

        // The late revenue instead sits in the live pool, ready for whichever round allocates next.
        assertEq(vault.unallocatedPool(), 5 ether);
    }
}
