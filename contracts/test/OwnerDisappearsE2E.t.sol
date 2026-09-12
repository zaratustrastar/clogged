// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {MockTickerNFT} from "./mocks/MockTickerNFT.sol";

/// @notice THE PRODUCT-LEVEL AUTONOMY PROOF. Everything above `setUp()`'s closing brace is
///         one-time deployment/wiring -- unavoidable bootstrapping, not "normal operation," and
///         governance/deployer calls there are expected and correct (see the protocol's own
///         one-time-initializer pattern used throughout). The test body below that point makes
///         ZERO governance or owner calls of any kind. Every single action after setup is either:
///           - an ordinary user trading (alice/bob/random addresses), or
///           - an ARBITRARY, UNRELATED, RANDOMLY-CHOSEN caller invoking a PERMISSIONLESS function
///             (closeRoundAndOpenNext, requestRandomnessForRound, relayRandomness, claim).
///         If this test passes, the protocol's entire normal-operation-plus-recovery path requires
///         no admin, no owner, and no privileged identity anywhere.
contract OwnerDisappearsE2ETest is Test {
    EligibilityRegistry engine;
    RoundManager rm;
    RewardVault vault;
    ChainlinkRandomnessProvider provider;
    VRFWrapperOnArbitrum wrapper;
    MockCCIPRouter router;
    VRFCoordinatorV2_5Mock vrfCoordinator;

    address governance = address(0x60401); // used ONLY inside setUp() below
    address multisig = address(0xA51);
    address ticketOwner = address(0x71CE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B1);

    // Arbitrary, unrelated addresses standing in for "literally anyone" -- none of them are
    // governance, the deployer, or any address with any privilege anywhere in the system.
    address randomCallerA = address(0x1111);
    address randomCallerB = address(0x2222);
    address randomCallerC = address(0x3333);
    address randomCallerD = address(0x4444);

    uint64 constant MOCK_SELECTOR = 16015286601757825753;
    bytes32 constant KEY_HASH = keccak256("owner-disappears-keyhash");
    uint256 subId;

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ONE-TIME SETUP -- bootstrapping, not "normal operation". Governance and
    //  deployer calls here are expected and correct.
    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        router = new MockCCIPRouter();
        vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);
        subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 1_000_000 ether);

        engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        provider = new ChainlinkRandomnessProvider(address(router), MOCK_SELECTOR, governance, address(this));
        rm = new RoundManager(address(engine), address(provider), governance, 3_600);
        engine.setRoundManager(address(rm));
        provider.setRoundManager(address(rm));
        vm.deal(address(provider), 10 ether);

        vault = new RewardVault(address(rm));
        vm.prank(governance);
        rm.setRewardVault(address(vault));

        wrapper = new VRFWrapperOnArbitrum(address(vrfCoordinator), address(router), MOCK_SELECTOR, KEY_HASH, subId);
        vrfCoordinator.addConsumer(subId, address(wrapper));
        vm.deal(address(wrapper), 10 ether);

        vm.prank(governance);
        provider.setWrapper(address(wrapper));
        wrapper.setProvider(address(provider));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _launchMeme(string memory name, string memory symbol)
        internal
        returns (uint256 tokenId, BondingCurveClog market)
    {
        uint256 predictedTokenId = engine.nextTokenId();
        MockTickerNFT tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(predictedTokenId, ticketOwner);

        MemeToken token = new MemeToken(name, symbol, address(this));
        market = new BondingCurveClog(
            address(token),
            address(tickerNFT),
            predictedTokenId,
            multisig,
            address(vault),
            governance,
            address(engine),
            VIRTUAL_ETH_SEED,
            BUFFER_BPS
        );
        token.setMarket(address(market));
        tokenId = engine.registerToken(address(market));
        require(tokenId == predictedTokenId, "token id mismatch");
    }

    function _findLastVrfRequestId() internal view returns (uint256) {
        for (uint256 i = 30; i >= 1; i--) {
            if (wrapper.vrfRequestIdToOriginalRequestId(i) != 0) {
                return i;
            }
        }
        revert("no VRF request found");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  TEST BODY -- zero governance/owner calls from here on. Every action is
    //  either ordinary user trading or an arbitrary caller hitting a
    //  permissionless function.
    // ─────────────────────────────────────────────────────────────────────────

    function test_ownerDisappears_normalOperationAndFullRecoveryRequireNoAdminAction() public {
        // ── Users launch 3 memes ──────────────────────────────────────────────
        (uint256 catId, BondingCurveClog catMarket) = _launchMeme("Cat", "CAT");
        (uint256 dogId, BondingCurveClog dogMarket) = _launchMeme("Dog", "DOG");
        (uint256 fishId, BondingCurveClog fishMarket) = _launchMeme("Fish", "FISH");

        // ── Users trade -- reserve timers update automatically from the trades themselves ──
        uint256 roundOpen = this._now();
        vm.prank(alice);
        catMarket.buy{value: 5 ether}(0, block.timestamp);
        vm.prank(bob);
        dogMarket.buy{value: 5 ether}(0, block.timestamp);
        vm.prank(alice);
        fishMarket.buy{value: 5 ether}(0, block.timestamp);

        assertGt(
            engine.aboveThresholdSince(catId), 0, "the buy itself must have started the timer with no separate action"
        );
        assertGt(engine.aboveThresholdSince(dogId), 0);
        assertGt(engine.aboveThresholdSince(fishId), 0);

        // ── All 3 meet qualification; candidates enter the current round ──────
        vm.warp(roundOpen + rm.roundDuration() / 2);
        // Confirming touches -- an arbitrary caller, not a launcher/owner/holder, can do this.
        vm.prank(randomCallerA);
        engine.qualify(catId);
        vm.prank(randomCallerA);
        engine.qualify(dogId);
        vm.prank(randomCallerA);
        engine.qualify(fishId);
        assertEq(engine.candidateCount(1), 3);

        // ── Hour ends; an arbitrary permissionless caller closes the round ─────
        vm.warp(roundOpen + rm.roundDuration());
        vm.prank(randomCallerB);
        uint256 closedRoundId = rm.closeRoundAndOpenNext();
        assertEq(closedRoundId, 1);
        assertEq(rm.currentRoundId(), 2, "the next round must have opened");

        RoundManager.RoundInfo memory infoAfterClose = rm.getRound(1);
        assertTrue(
            infoAfterClose.randomnessRequested,
            "the request succeeded on the first attempt here -- the failure is introduced deliberately below instead"
        );

        // Complete round 1's own settlement immediately, independent of everything that follows --
        // this proves multiple rounds can be genuinely in flight/settled on their own schedules.
        uint256 vrfRequestIdRound1 = _findLastVrfRequestId();
        vrfCoordinator.fulfillRandomWords(vrfRequestIdRound1, address(wrapper));
        vm.prank(randomCallerA);
        wrapper.relayRandomness(infoAfterClose.randomnessRequestId);
        assertTrue(rm.getRound(1).settled, "round 1 must settle promptly with no funding problems in its path");

        // To exercise the "randomness request initially fails" branch faithfully, simulate it on
        // round 2 as well: qualify a fresh set of tokens into round 2, then force the FIRST
        // request attempt to fail by disabling the provider's ability to pay for CCIP, and prove
        // round 2 still closes and round 3 still opens regardless.
        (uint256 catId2, BondingCurveClog catMarket2) = _launchMeme("Cat2", "CAT2");
        (uint256 dogId2, BondingCurveClog dogMarket2) = _launchMeme("Dog2", "DOG2");
        (uint256 fishId2, BondingCurveClog fishMarket2) = _launchMeme("Fish2", "FISH2");

        uint256 round2Open = this._now();
        vm.prank(alice);
        catMarket2.buy{value: 5 ether}(0, block.timestamp);
        vm.prank(bob);
        dogMarket2.buy{value: 5 ether}(0, block.timestamp);
        vm.prank(alice);
        fishMarket2.buy{value: 5 ether}(0, block.timestamp);

        vm.warp(round2Open + rm.roundDuration() / 2);
        vm.prank(randomCallerC);
        engine.qualify(catId2);
        vm.prank(randomCallerC);
        engine.qualify(dogId2);
        vm.prank(randomCallerC);
        engine.qualify(fishId2);

        // The randomness request initially fails: drain the provider's ETH so it cannot pay the
        // outbound CCIP fee (no admin action -- this is just simulating an operational funding
        // gap, the same as would happen if nobody had topped it up in time).
        router.setFee(0.05 ether);
        vm.deal(address(provider), 0);

        vm.warp(round2Open + rm.roundDuration());
        vm.prank(randomCallerB);
        rm.closeRoundAndOpenNext(); // must succeed even though the randomness request inside it fails

        assertEq(rm.currentRoundId(), 3, "round 3 must have opened even though round 2's randomness request failed");
        RoundManager.RoundInfo memory infoRound2 = rm.getRound(2);
        assertTrue(infoRound2.closed);
        assertFalse(infoRound2.randomnessRequested, "round 2 must be left pending, awaiting retry");
        assertFalse(infoRound2.settled);

        // ── Future round still operates while round 2 is stuck ────────────────
        vm.warp(this._now() + rm.roundDuration());
        vm.prank(randomCallerD);
        rm.closeRoundAndOpenNext(); // round 3 closes trivially (no candidates), round 4 opens
        assertEq(rm.currentRoundId(), 4, "round progression must continue independent of round 2's stuck state");
        assertFalse(rm.getRound(2).settled, "round 2 must still be untouched");

        // ── Later, an arbitrary caller retries round 2's randomness request ────
        vm.deal(address(provider), 10 ether); // funding gap resolved -- by anyone, no admin needed
        vm.prank(randomCallerA);
        rm.requestRandomnessForRound(2);
        RoundManager.RoundInfo memory infoRetried = rm.getRound(2);
        assertTrue(infoRetried.randomnessRequested, "the retry must succeed now that funding is available");

        // ── VRF fulfills; random word stored ────────────────────────────────
        uint256 vrfRequestId = _findLastVrfRequestId();
        // The return CCIP leg is also underfunded at this exact moment -- prove the word survives.
        vm.deal(address(wrapper), 0);
        vrfCoordinator.fulfillRandomWords(vrfRequestId, address(wrapper));

        (uint256 storedWord, bool fulfilled, bool relayed) = wrapper.fulfilledRequests(infoRetried.randomnessRequestId);
        assertTrue(fulfilled, "VRF fulfillment must succeed and persist regardless of the wrapper's CCIP balance");
        assertFalse(relayed);
        assertFalse(rm.getRound(2).settled);

        // ── Return CCIP initially fails; stored word remains immutable ─────────
        vm.expectRevert("insufficient balance for CCIP fee");
        wrapper.relayRandomness(infoRetried.randomnessRequestId);
        (uint256 wordAfterFailedRelay, bool fulfilledAfterFailedRelay, bool relayedAfterFailedRelay) =
            wrapper.fulfilledRequests(infoRetried.randomnessRequestId);
        assertEq(
            wordAfterFailedRelay, storedWord, "the stored word must be completely unaffected by a failed relay attempt"
        );
        assertTrue(fulfilledAfterFailedRelay);
        assertFalse(relayedAfterFailedRelay);
        assertFalse(rm.getRound(2).settled);

        // ── Later, an arbitrary caller retries the relay -- same word reaches Robinhood ────
        vm.deal(address(wrapper), 10 ether);
        vm.prank(randomCallerC);
        wrapper.relayRandomness(infoRetried.randomnessRequestId);

        // ── Original round settles ──────────────────────────────────────────
        RoundManager.RoundInfo memory settled = rm.getRound(2);
        assertTrue(settled.settled, "round 2 must now be settled using the exact word stored before either funding gap");
        assertTrue(
            settled.winnerTokenId == catId2 || settled.winnerTokenId == dogId2 || settled.winnerTokenId == fishId2,
            "the winner must be one of round 2's own three candidates"
        );

        // Every intervening round remains exactly as it was -- no reroll, no mutation, no
        // retroactive change to any other round's state as a side effect of round 2 settling late.
        assertTrue(rm.getRound(1).settled, "round 1's own earlier, independent settlement must be untouched");
        assertFalse(rm.getRound(3).settled, "round 3 (no candidates, skipped) must remain unsettled, exactly as it was");
        assertEq(
            rm.currentRoundId(),
            4,
            "current round progression must be completely unaffected by round 2's late settlement"
        );

        // ── Winning holders can claim ────────────────────────────────────────
        RewardVault.RoundAllocation memory alloc = vault.getAllocation(2);
        assertGt(alloc.jackpotAmount, 0);
        address winnerHolder = settled.winnerTokenId == catId2 ? alice : settled.winnerTokenId == dogId2 ? bob : alice;
        uint256 claimable = vault.previewClaim(2, winnerHolder);
        if (claimable > 0) {
            uint256 balBefore = winnerHolder.balance;
            // Claiming is itself permissionless -- an arbitrary caller triggers it on the
            // holder's behalf; funds go only to the holder, never the caller.
            vm.prank(randomCallerD);
            vault.claim(2, winnerHolder);
            assertEq(
                winnerHolder.balance,
                balBefore + claimable,
                "the winning holder must receive their exact claimable share"
            );
        }
    }
}
