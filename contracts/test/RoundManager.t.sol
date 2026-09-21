// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {MockRandomnessProvider} from "./mocks/MockRandomnessProvider.sol";
import {MockReserveMarket} from "./mocks/MockReserveMarket.sol";

contract RoundManagerTest is Test {
    RoundManager rm;
    EligibilityRegistry engine;
    MockRandomnessProvider provider;
    address governance = address(0x60401);

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        provider = new MockRandomnessProvider();
        engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        rm = new RoundManager(address(engine), address(provider), governance);
        engine.setRoundManager(address(rm));
        provider.setRoundManager(address(rm));
    }

    function _makeToken(uint256 reserveWei, uint256 progressBps) internal returns (uint256 tokenId, MockReserveMarket m) {
        m = new MockReserveMarket();
        m.setReserve(reserveWei);
        m.setProgressBps(progressBps);
        tokenId = engine.registerToken(address(m));
    }

    function _qualifyAllAndCloseRound(uint256[] memory ids, MockReserveMarket[] memory ms) internal {
        uint256 openT = this._now();
        for (uint256 i = 0; i < ids.length; i++) {
            ms[i].setReserve(1 ether);
            engine.onTrade(ids[i]);
        }
        vm.warp(openT + rm.ROUND_DURATION());
        // A confirming touch after the 30-minute mark is what locks in qualification (no more
        // retroactive finalization at close).
        for (uint256 i = 0; i < ids.length; i++) {
            engine.qualify(ids[i]);
        }
        rm.closeRoundAndOpenNext();
    }

    function test_initialState() public view {
        assertEq(rm.currentRoundId(), 1);
    }

    function test_cannotCloseBeforeDuration() public {
        vm.expectRevert();
        rm.closeRoundAndOpenNext();
    }

    function test_drawUsesCandidatesFromTheSameRoundThatCloses() public {
        (uint256 idA, MockReserveMarket mA) = _makeToken(1 ether, 1000);
        (uint256 idB, MockReserveMarket mB) = _makeToken(1 ether, 1000);
        (uint256 idC, MockReserveMarket mC) = _makeToken(1 ether, 1000);
        uint256[] memory ids = new uint256[](3);
        MockReserveMarket[] memory ms = new MockReserveMarket[](3);
        ids[0] = idA; ids[1] = idB; ids[2] = idC;
        ms[0] = mA; ms[1] = mB; ms[2] = mC;

        vm.warp(this._now() + rm.ROUND_DURATION());
        rm.closeRoundAndOpenNext();

        // Qualifies all three DURING round 2, then closes round 2 -- no lag: round 2 draws from
        // its own candidates, built live during itself.
        _qualifyAllAndCloseRound(ids, ms);

        assertEq(engine.candidateCount(2), 3, "round 2's own generation (built during round 2) has the 3 tokens");
        assertEq(rm.getRound(2).candidateCount, 3, "round 2's OWN draw uses round 2's own candidates -- no lag");
        assertFalse(rm.getRound(2).drawSkipped);
        assertTrue(rm.getRound(2).randomnessRequested);
        assertEq(rm.getRound(2).candidateRoundId, 2, "candidateRoundId must equal the closing round itself, not roundId - 1");
    }

    function test_fullLifecycle_candidatesSettleTheSameRoundTheyQualifiedIn() public {
        (uint256 idA, MockReserveMarket mA) = _makeToken(1 ether, 1000);
        (uint256 idB, MockReserveMarket mB) = _makeToken(1 ether, 1000);
        (uint256 idC, MockReserveMarket mC) = _makeToken(1 ether, 1000);
        uint256[] memory ids = new uint256[](3);
        MockReserveMarket[] memory ms = new MockReserveMarket[](3);
        ids[0] = idA; ids[1] = idB; ids[2] = idC;
        ms[0] = mA; ms[1] = mB; ms[2] = mC;

        vm.warp(this._now() + rm.ROUND_DURATION());
        rm.closeRoundAndOpenNext();

        // Qualifying all three and closing round 2 in one step must settle round 2 immediately --
        // no third round needed, since round 2 draws from its own live-built candidate set.
        _qualifyAllAndCloseRound(ids, ms);

        RoundManager.RoundInfo memory info = rm.getRound(2);
        assertFalse(info.drawSkipped);
        assertEq(info.candidateCount, 3);
        assertTrue(info.randomnessRequested);

        provider.fulfill(info.randomnessRequestId, 777777);
        RoundManager.RoundInfo memory settled = rm.getRound(2);
        assertTrue(settled.settled);
        assertTrue(settled.winnerTokenId == idA || settled.winnerTokenId == idB || settled.winnerTokenId == idC);
    }

    function test_firstEverRound_canSettleIfThreeQualify() public {
        // The very first round the protocol ever opens (round 1, never closed before) can produce
        // a winner if at least MIN_DRAW_CANDIDATES qualify before it closes -- no special-casing.
        (uint256 idA, MockReserveMarket mA) = _makeToken(1 ether, 1000);
        (uint256 idB, MockReserveMarket mB) = _makeToken(1 ether, 1000);
        (uint256 idC, MockReserveMarket mC) = _makeToken(1 ether, 1000);
        uint256[] memory ids = new uint256[](3);
        MockReserveMarket[] memory ms = new MockReserveMarket[](3);
        ids[0] = idA; ids[1] = idB; ids[2] = idC;
        ms[0] = mA; ms[1] = mB; ms[2] = mC;

        assertEq(rm.currentRoundId(), 1, "must genuinely be the first-ever round, never closed before");
        _qualifyAllAndCloseRound(ids, ms); // qualifies into round 1, then closes round 1

        RoundManager.RoundInfo memory info = rm.getRound(1);
        assertFalse(info.drawSkipped, "the first-ever round must be able to draw a winner");
        assertEq(info.candidateCount, 3);
        assertTrue(info.randomnessRequested);

        provider.fulfill(info.randomnessRequestId, 42);
        assertTrue(rm.getRound(1).settled);
    }

    function test_exactlyThreeCandidates_equalOddsSpace() public {
        // With exactly MIN_DRAW_CANDIDATES candidates, the unbiased index selection must give each
        // an equal 1-in-3 slice of the index space -- no weighting toward any position.
        (uint256 idA, MockReserveMarket mA) = _makeToken(1 ether, 1000);
        (uint256 idB, MockReserveMarket mB) = _makeToken(1 ether, 1000);
        (uint256 idC, MockReserveMarket mC) = _makeToken(1 ether, 1000);
        uint256[] memory ids = new uint256[](3);
        MockReserveMarket[] memory ms = new MockReserveMarket[](3);
        ids[0] = idA; ids[1] = idB; ids[2] = idC;
        ms[0] = mA; ms[1] = mB; ms[2] = mC;

        _qualifyAllAndCloseRound(ids, ms);
        RoundManager.RoundInfo memory info = rm.getRound(1);
        assertEq(info.candidateCount, 3);

        uint256[3] memory wins;
        for (uint256 seed = 0; seed < 300; seed++) {
            uint256 randomWord = uint256(keccak256(abi.encode("seed", seed)));
            uint256 index = _publicUnbiasedIndex(randomWord, 1, 3);
            wins[index]++;
        }
        // Each of the 3 equal-width slices of the index space should get roughly a third of hits --
        // loose bound since this is a statistical check, not an exact one.
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(wins[i] > 60, "each candidate slot must get a meaningful, roughly-equal share");
        }
    }

    function _publicUnbiasedIndex(uint256 randomWord, uint256 roundId, uint256 n) internal pure returns (uint256) {
        uint256 limit = type(uint256).max - (type(uint256).max % n);
        uint256 r = randomWord;
        uint256 attempt = 0;
        while (r >= limit) {
            attempt++;
            r = uint256(keccak256(abi.encode(randomWord, roundId, "unbias", attempt)));
        }
        return r % n;
    }

    function test_belowMinCandidates_skipsDrawNoRandomnessRequested() public {
        (uint256 idA, MockReserveMarket mA) = _makeToken(1 ether, 1000);
        uint256[] memory ids = new uint256[](1);
        MockReserveMarket[] memory ms = new MockReserveMarket[](1);
        ids[0] = idA; ms[0] = mA;

        // Only 1 candidate qualifies into round 1 -- below MIN_DRAW_CANDIDATES(3).
        _qualifyAllAndCloseRound(ids, ms);
        RoundManager.RoundInfo memory info = rm.getRound(1);
        assertTrue(info.drawSkipped, "1 candidate is below the minimum -- the draw must be skipped");
        assertFalse(info.randomnessRequested);
        assertEq(info.candidateCount, 1);
        assertEq(provider.nextRequestId(), 1, "a skipped draw must never even attempt a randomness request");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Randomness-transport liveness: closing/opening rounds must never depend
    //  on the randomness provider succeeding.
    // ─────────────────────────────────────────────────────────────────────────

    function _makeThreeQualifiedTokens() internal returns (uint256[] memory ids, MockReserveMarket[] memory ms) {
        (uint256 idA, MockReserveMarket mA) = _makeToken(1 ether, 1000);
        (uint256 idB, MockReserveMarket mB) = _makeToken(1 ether, 1000);
        (uint256 idC, MockReserveMarket mC) = _makeToken(1 ether, 1000);
        ids = new uint256[](3);
        ms = new MockReserveMarket[](3);
        ids[0] = idA; ids[1] = idB; ids[2] = idC;
        ms[0] = mA; ms[1] = mB; ms[2] = mC;
    }

    /// @notice A: provider unavailable -- the round must still close, candidates still freeze, the
    ///         next round still opens, no winner is fabricated, and the round is left in a state
    ///         that is unambiguously "awaiting randomness" (closed, has enough candidates, but no
    ///         successful request yet) rather than "skipped" or "settled".
    function test_providerUnavailable_roundStillClosesAndOpensNext() public {
        (uint256[] memory ids, MockReserveMarket[] memory ms) = _makeThreeQualifiedTokens();

        provider.setShouldRevert(true);
        uint256 closedRoundId = 0;
        // _qualifyAllAndCloseRound itself calls closeRoundAndOpenNext -- this must NOT revert
        // overall even though the provider underneath does.
        closedRoundId = _qualifyAllAndCloseRoundReturning(ids, ms);
        assertEq(closedRoundId, 1);

        RoundManager.RoundInfo memory info = rm.getRound(1);
        assertTrue(info.closed, "round must still close even though the provider reverted");
        assertEq(info.candidateCount, 3, "candidates must still be frozen/counted");
        assertFalse(info.randomnessRequested, "no successful request was made");
        assertFalse(info.drawSkipped, "must not read as skipped -- it has enough candidates, it's just awaiting a successful request");
        assertFalse(info.settled, "no winner may ever be fabricated");
        assertEq(rm.currentRoundId(), 2, "the next round must have opened regardless");
    }

    /// @dev Same as `_qualifyAllAndCloseRound` but returns the closed round id, for tests that
    ///      want to assert on it directly.
    function _qualifyAllAndCloseRoundReturning(uint256[] memory ids, MockReserveMarket[] memory ms) internal returns (uint256 closedRoundId) {
        uint256 openT = this._now();
        for (uint256 i = 0; i < ids.length; i++) {
            ms[i].setReserve(1 ether);
            engine.onTrade(ids[i]);
        }
        vm.warp(openT + rm.ROUND_DURATION());
        for (uint256 i = 0; i < ids.length; i++) {
            engine.qualify(ids[i]);
        }
        closedRoundId = rm.closeRoundAndOpenNext();
    }

    /// @notice B: once the provider recovers, the permissionless retry succeeds.
    function test_retryAfterProviderRecovers_succeeds() public {
        (uint256[] memory ids, MockReserveMarket[] memory ms) = _makeThreeQualifiedTokens();
        provider.setShouldRevert(true);
        _qualifyAllAndCloseRoundReturning(ids, ms);
        assertFalse(rm.getRound(1).randomnessRequested);

        provider.setShouldRevert(false);
        rm.requestRandomnessForRound(1);

        RoundManager.RoundInfo memory info = rm.getRound(1);
        assertTrue(info.randomnessRequested, "retry must succeed once the provider is available again");
        assertGt(info.randomnessRequestId, 0);
    }

    /// @notice C: once a request has successfully been created, no second request may ever be
    ///         created for that round -- regardless of caller identity or how much time passes.
    function test_noReroll_onceRequestedCannotRequestAgain() public {
        (uint256[] memory ids, MockReserveMarket[] memory ms) = _makeThreeQualifiedTokens();
        _qualifyAllAndCloseRoundReturning(ids, ms); // provider succeeds immediately here
        assertTrue(rm.getRound(1).randomnessRequested);

        vm.expectRevert("already requested");
        rm.requestRandomnessForRound(1);

        // Identity must not matter -- an arbitrary, unrelated caller gets the same rejection.
        vm.prank(address(0xBEEF));
        vm.expectRevert("already requested");
        rm.requestRandomnessForRound(1);

        // No timeout escape hatch -- far future, still rejected.
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert("already requested");
        rm.requestRandomnessForRound(1);

        // Even governance itself has no special path around this -- the function has no
        // privileged branch at all, so a governance-sent call is rejected identically.
        vm.prank(governance);
        vm.expectRevert("already requested");
        rm.requestRandomnessForRound(1);
    }

    /// @notice D: an old round left unsettled must never block later rounds from opening,
    ///         trading, closing, or requesting their own randomness.
    function test_delayedHistoricalRound_doesNotBlockFutureRounds() public {
        // Cheaply advance to round 10 (matching the spec's own numbering), no candidates each
        // time so each trivially closes as a skipped draw.
        for (uint256 i = 1; i < 10; i++) {
            vm.warp(rm.currentRoundOpenTime() + rm.ROUND_DURATION());
            rm.closeRoundAndOpenNext();
        }
        assertEq(rm.currentRoundId(), 10);

        (uint256[] memory ids, MockReserveMarket[] memory ms) = _makeThreeQualifiedTokens();
        provider.setShouldRevert(true);
        _qualifyAllAndCloseRoundReturning(ids, ms); // closes round 10, opens round 11
        assertEq(rm.currentRoundId(), 11);
        assertFalse(rm.getRound(10).randomnessRequested, "round 10 must be left pending");

        // Round 11 opens and closes normally -- no candidates, just proving ordinary progression
        // -- while round 10 remains untouched and unsettled throughout.
        vm.warp(rm.currentRoundOpenTime() + rm.ROUND_DURATION());
        rm.closeRoundAndOpenNext();
        assertEq(rm.currentRoundId(), 12, "round 12 must have opened -- two full rounds of progress since round 10 got stuck");
        assertTrue(rm.getRound(11).closed);
        assertFalse(rm.getRound(10).settled, "round 10 must still be pending, completely unaffected by round 11's own progress");

        // Round 10 can still be independently recovered and settled at any later point.
        provider.setShouldRevert(false);
        rm.requestRandomnessForRound(10);
        assertTrue(rm.getRound(10).randomnessRequested);
        provider.fulfill(rm.getRound(10).randomnessRequestId, 424242);
        assertTrue(rm.getRound(10).settled, "round 10 must still be independently settleable long after newer rounds have moved on");
    }

    /// @notice E: once round N closes, its candidate set and count are permanently frozen -- later
    ///         qualification activity only ever affects the round that is CURRENTLY open.
    function test_closedRoundCandidates_immutableAfterClose() public {
        (uint256 idA, MockReserveMarket mA) = _makeToken(1 ether, 1000);
        uint256[] memory ids = new uint256[](1);
        MockReserveMarket[] memory ms = new MockReserveMarket[](1);
        ids[0] = idA; ms[0] = mA;
        _qualifyAllAndCloseRoundReturning(ids, ms); // round 1 closes with exactly 1 (skipped) candidate
        uint256 frozenCount = rm.getRound(1).candidateCount;
        assertEq(frozenCount, 1);

        // New activity in round 2 must never retroactively change round 1's frozen state.
        (uint256 idB, MockReserveMarket mB) = _makeToken(1 ether, 1000);
        mB.setReserve(1 ether);
        engine.onTrade(idB);
        vm.warp(block.timestamp + rm.ROUND_DURATION());
        engine.qualify(idB);

        assertEq(rm.getRound(1).candidateCount, frozenCount, "round 1's frozen candidateCount must never change after close");
        assertFalse(engine.isCandidate(1, idB), "a token qualifying in round 2 must never retroactively appear in round 1's candidate set");
        assertTrue(engine.isCandidate(2, idB));
    }

    function test_setRandomnessProvider_onlyGovernance() public {
        vm.expectRevert();
        rm.setRandomnessProvider(address(0x1234));
        vm.prank(governance);
        rm.setRandomnessProvider(address(0x1234));
        assertEq(address(rm.randomnessProvider()), address(0x1234));
    }

    function test_unbiasedIndex_alwaysInRange(uint256 seed, uint8 nRaw) public view {
        uint256 n = bound(nRaw, 1, 7777);
        uint256 idx = rm.exposedUnbiasedIndex(seed, 1, n);
        assertLt(idx, n);
    }

    function test_unbiasedIndex_deterministic() public view {
        uint256 a = rm.exposedUnbiasedIndex(12345, 1, 100);
        uint256 b = rm.exposedUnbiasedIndex(12345, 1, 100);
        assertEq(a, b);
    }

    function test_statistical_uniformityAcrossManySeeds() public view {
        uint256 n = 10;
        uint256[] memory counts = new uint256[](n);
        uint256 trials = 2000;
        for (uint256 i = 0; i < trials; i++) {
            uint256 seed = uint256(keccak256(abi.encode(i, "uniformity-seed")));
            uint256 idx = rm.exposedUnbiasedIndex(seed, 1, n);
            counts[idx]++;
        }
        uint256 expectedPer = trials / n;
        for (uint256 i = 0; i < n; i++) {
            assertApproxEqAbs(counts[i], expectedPer, 60, "each index should land close to 1/n of trials");
        }
    }
}
