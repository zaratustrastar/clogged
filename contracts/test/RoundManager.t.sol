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
        engine = new EligibilityRegistry(address(this));
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

    function test_setRandomnessProvider_onlyGovernance() public {
        vm.expectRevert();
        rm.setRandomnessProvider(address(0x1234));
        vm.prank(governance);
        rm.setRandomnessProvider(address(0x1234));
        assertEq(address(rm.randomnessProvider()), address(0x1234));
    }
}
