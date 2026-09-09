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

/// @notice Integration tests for the atomic eligibility wiring added to BondingCurveClog: every
///         real buy/sell now calls EligibilityRegistry.onTrade synchronously, and a revert there
///         reverts the whole trade (see BondingCurveClog._touchEligibility's contract-level notes
///         for why the earlier best-effort/try-catch design was rejected). These tests exercise
///         the wiring through REAL trades on a REAL curve, not direct calls to the registry.
contract EligibilityTradeIntegrationTest is Test {
    EligibilityRegistry engine;
    RoundManager rm;
    RewardVault vault;
    MockRandomnessProvider provider;
    address governance = address(0x60401);
    address ticketOwner = address(0x71CE);
    address multisig = address(0xA51);

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    uint256 constant MIN_RESERVE = 0.229 ether;
    uint256 constant REQUIRED_SECONDS = 1_800;

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        provider = new MockRandomnessProvider();
        engine = new EligibilityRegistry(address(this));
        rm = new RoundManager(address(engine), address(provider), governance);
        engine.setRoundManager(address(rm));
        provider.setRoundManager(address(rm));

        vault = new RewardVault(address(rm));
        vm.prank(governance);
        rm.setRewardVault(address(vault));

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _closeRound() internal returns (uint256 closedRoundId) {
        closedRoundId = rm.closeRoundAndOpenNext();
    }

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

    // ── 1: buy crossing the threshold starts the timer automatically ───────────

    function test_buyCrossingThreshold_startsTimerAutomatically() public {
        (uint256 catId,, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        assertEq(engine.aboveThresholdSince(catId), 0, "no streak before any qualifying trade");

        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp); // comfortably crosses MIN_RESERVE

        assertGe(cat.realReserve(), MIN_RESERVE, "sanity: this buy must actually cross the threshold");
        assertEq(engine.aboveThresholdSince(catId), block.timestamp, "the buy that crosses threshold must start the timer, with no separate action needed");
    }

    // ── 2: a later trade above threshold preserves the original timer ──────────

    function test_tradeAboveThreshold_preservesOriginalTimer() public {
        (uint256 catId,, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp);
        uint256 originalStart = engine.aboveThresholdSince(catId);
        assertEq(originalStart, block.timestamp);

        vm.warp(block.timestamp + 600);
        vm.prank(bob);
        cat.buy{value: 1 ether}(0, block.timestamp); // still above threshold -- must not reset

        assertEq(engine.aboveThresholdSince(catId), originalStart, "a trade that stays above threshold must never move the streak start forward");
    }

    // ── 3: a sell that drops below threshold resets the timer ──────────────────

    function test_sellBelowThreshold_resetsTimer() public {
        (uint256 catId, MemeToken token, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp);
        assertGt(engine.aboveThresholdSince(catId), 0);

        uint256 aliceBal = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(cat), aliceBal);
        vm.prank(alice);
        cat.sell(aliceBal, 0, block.timestamp); // sell everything back

        assertLt(cat.realReserve(), MIN_RESERVE, "sanity: this sell must actually drop below threshold");
        assertEq(engine.aboveThresholdSince(catId), 0, "dropping below threshold must reset the streak");
    }

    // ── 4: the atomic invariant itself -- a successful sell that drops below ───
    //      threshold can NEVER leave a stale pre-dip timestamp in place. This is
    //      exactly the failure mode the best-effort/try-catch design had and the
    //      atomic design exists to eliminate.

    function test_atomicInvariant_successfulSellBelowThreshold_neverLeavesStaleStreak() public {
        (uint256 catId, MemeToken token, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp);
        uint256 staleStart = engine.aboveThresholdSince(catId);
        assertGt(staleStart, 0);

        vm.warp(block.timestamp + 600);
        uint256 aliceBal = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(cat), aliceBal);
        vm.prank(alice);
        cat.sell(aliceBal, 0, block.timestamp);

        // The sell succeeded (no revert) -- by construction, that is only possible if the
        // eligibility touch also succeeded and recorded the reset. There is no code path where
        // this sell lands but `aboveThresholdSince` keeps its pre-dip value.
        assertEq(engine.aboveThresholdSince(catId), 0, "a successful trade that drops reserve below threshold must always carry a correct, immediate reset with it");
        assertTrue(cat.realReserve() < MIN_RESERVE);
    }

    // ── 5: progress below 5% blocks qualification even with a complete reserve timer ──

    function test_progressBelowFivePercent_blocksQualification_evenWithCompleteTimer() public {
        (uint256 catId,, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        // A small buy: comfortably crosses the absolute MIN_RESERVE (0.229 ETH) via the ETH amount
        // alone, but the curve is deep enough that a small buy keeps progressBps() under 5%.
        vm.prank(alice);
        cat.buy{value: 0.25 ether}(0, block.timestamp);
        assertGe(cat.realReserve(), MIN_RESERVE, "sanity: reserve gate is met");
        assertLt(cat.progressBps(), 500, "sanity: progress gate must NOT be met yet for this to be a real test");

        vm.warp(block.timestamp + REQUIRED_SECONDS);
        // Confirm via qualify() rather than another buy -- a second buy would itself add more
        // progress and could cross 5% on its own, which would no longer isolate what this test is
        // actually checking. qualify() re-reads current state without trading anything.
        engine.qualify(catId);

        assertFalse(engine.isCandidate(rm.currentRoundId(), catId), "progress gate must independently block qualification even though the reserve timer alone is satisfied");
    }

    // ── 6: after 30 minutes with both gates met, a normal trade qualifies automatically ──

    function test_normalTradeAfterThirtyMinutes_qualifiesAutomatically() public {
        (uint256 catId,, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp); // large buy: clears both progress and reserve gates
        assertGe(cat.progressBps(), 500);
        assertGe(cat.realReserve(), MIN_RESERVE);

        vm.warp(block.timestamp + REQUIRED_SECONDS);
        vm.prank(bob);
        cat.buy{value: 0.001 ether}(0, block.timestamp); // an ordinary, otherwise-unremarkable trade

        assertTrue(engine.isCandidate(rm.currentRoundId(), catId), "an ordinary trade after the timer completes must qualify automatically, with no separate keeper/qualify() action");
    }

    // ── 7: qualify() still works without any new trade ──────────────────────────

    function test_qualifyWorksWithoutANewTrade() public {
        (uint256 catId,, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp);

        vm.warp(block.timestamp + REQUIRED_SECONDS);
        // No trade happens here -- a completely unrelated caller invokes qualify() directly.
        vm.prank(address(0xBEEF));
        engine.qualify(catId);

        assertTrue(engine.isCandidate(rm.currentRoundId(), catId));
    }

    // ── 8: a streak spanning a round boundary remains valid ─────────────────────

    function test_streakSpanningRoundBoundary_remainsValidThroughRealTrading() public {
        (uint256 catId,, BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        uint256 roundKOpen = rm.currentRoundOpenTime();
        uint256 roundDuration = rm.ROUND_DURATION();

        // Buy happens 45 minutes into round K -- only 15 minutes before it closes, matching the
        // spec's own CAT example (reaches threshold at 12:45, round closes at 13:00).
        vm.warp(roundKOpen + roundDuration - 900);
        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp);
        uint256 streakStart = engine.aboveThresholdSince(catId);
        assertEq(streakStart, block.timestamp);

        // Round K closes on schedule -- only 15 minutes of the streak have elapsed, not enough.
        vm.warp(roundKOpen + roundDuration);
        _closeRound();
        assertFalse(engine.isCandidate(1, catId));

        // Reserve never dipped, so the streak (untouched by the round boundary) keeps counting.
        // 30 minutes after it started, now inside round 2, confirm with an ordinary trade.
        vm.warp(streakStart + REQUIRED_SECONDS);
        vm.prank(bob);
        cat.buy{value: 0.001 ether}(0, block.timestamp);

        assertTrue(engine.isCandidate(2, catId), "the streak must carry across the round boundary and qualify into the newly-current round");
        assertFalse(engine.isCandidate(1, catId), "must never be retroactively added to the already-closed round");
    }

    // ── 9: duplicate candidate insertion is impossible through real trading ─────

    function test_duplicateCandidateInsertion_impossibleThroughRepeatedTrading() public {
        (, , BondingCurveClog cat) = _launchMeme("Cat", "CAT");
        vm.prank(alice);
        cat.buy{value: 5 ether}(0, block.timestamp);
        vm.warp(block.timestamp + REQUIRED_SECONDS);
        vm.prank(bob);
        cat.buy{value: 0.001 ether}(0, block.timestamp); // qualifies here
        assertEq(engine.candidateCount(rm.currentRoundId()), 1);

        // Many more ordinary trades follow in the same round -- none of them may add a second entry.
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            cat.buy{value: 0.01 ether}(0, block.timestamp);
        }
        assertEq(engine.candidateCount(rm.currentRoundId()), 1, "repeated ordinary trading must never insert the same token twice into one round's candidate list");
    }
}
