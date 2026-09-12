// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {MockReserveMarket} from "./mocks/MockReserveMarket.sol";

contract EligibilityRegistryTest is Test {
    EligibilityRegistry engine;
    address roundManager = address(this);

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        engine.setRoundManager(roundManager);
    }

    function _makeToken(uint256 reserveWei, uint256 progressBps)
        internal
        returns (uint256 tokenId, MockReserveMarket m)
    {
        m = new MockReserveMarket();
        m.setReserve(reserveWei);
        m.setProgressBps(progressBps);
        tokenId = engine.registerToken(address(m));
    }

    function _closeAndOpen() internal {
        engine.openRound(engine.currentRoundId() + 1, this._now());
    }

    function test_freshlyLaunchedToken_canQualifyInItsOwnFirstRound() public {
        // No age requirement at all: a token can launch and qualify for the CURRENTLY open
        // round's own draw, with no need to survive into a later round first.
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now(); // still round 1 -- never closed/reopened
        engine.onTrade(id); // streak starts
        vm.warp(openT + 1800);
        engine.onTrade(id); // confirming touch after 30 minutes
        assertTrue(
            engine.isCandidate(1, id), "a freshly launched token must be able to qualify for its own round's draw"
        );
    }

    function test_progressGate_blocksLowProgressToken() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 100);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1800);
        engine.onTrade(id);
        assertFalse(engine.isCandidate(1, id));
    }

    function test_timing_29m59s_cannotQualify() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1799);
        engine.onTrade(id);
        assertFalse(engine.isCandidate(1, id), "29:59 must not satisfy the 30-minute bar");
    }

    function test_timing_30m00s_canQualify() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1800);
        engine.onTrade(id);
        assertTrue(engine.isCandidate(1, id), "30:00 exactly must satisfy the bar");
    }

    function test_timing_fallBelowThreshold_resetsTimer() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1000);
        m.setReserve(0);
        engine.onTrade(id);
        assertEq(engine.aboveThresholdSince(id), 0, "streak must reset to 0 on dipping below threshold");

        vm.warp(openT + 1800);
        engine.onTrade(id);
        assertFalse(engine.isCandidate(1, id), "a reset streak must not silently retain old progress");
    }

    function test_timing_laterRise_startsNewTimer() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1000);
        m.setReserve(0);
        engine.onTrade(id);

        vm.warp(openT + 1100);
        m.setReserve(1 ether);
        engine.onTrade(id);
        assertEq(engine.aboveThresholdSince(id), openT + 1100, "a new streak must start fresh, not resume the old one");

        vm.warp(openT + 1100 + 1800);
        engine.onTrade(id);
        assertTrue(engine.isCandidate(1, id), "the new streak alone, once it reaches 30 minutes, must qualify");
    }

    function test_nextTradeAutoQualifiesWhenConditionMet() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1800);
        assertFalse(engine.isCandidate(1, id), "must not qualify before ANY touch confirms it, even past the time bar");
        engine.onTrade(id);
        assertTrue(engine.isCandidate(1, id), "an ordinary trade after the bar is met must auto-qualify");
    }

    function test_permissionlessQualify_works() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1800);
        vm.prank(address(0xBEEF));
        engine.qualify(id);
        assertTrue(engine.isCandidate(1, id), "anyone must be able to permissionlessly lock in a qualifying token");
    }

    function test_duplicateQualification_impossible() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1800);
        engine.onTrade(id);
        assertEq(engine.candidateCount(1), 1);
        engine.qualify(id);
        engine.qualify(id);
        engine.onTrade(id);
        assertEq(
            engine.candidateCount(1), 1, "must never be added twice regardless of how many times touched afterward"
        );
    }

    function test_acceptedCaveat_neverTouchedAgain_doesNotQualify() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 3600);
        assertFalse(
            engine.isCandidate(1, id), "without a later touch or explicit qualify, a token misses the round -- accepted"
        );
    }

    function test_qualificationAfterCutoff_cannotAffectFrozenRound() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 openT = this._now();
        engine.onTrade(id);
        vm.warp(openT + 1800);
        engine.onTrade(id);
        assertTrue(engine.isCandidate(1, id));
        uint256 countBefore = engine.candidateCount(1);

        _closeAndOpen(); // round 1 closes, round 2 opens
        m.setReserve(500 ether);
        engine.onTrade(id);
        vm.warp(this._now() + 1800);
        engine.onTrade(id); // this can only ever qualify it for round 2, never round 1 again

        assertEq(engine.candidateCount(1), countBefore, "round 1's already-closed candidate list must be untouched");
        assertTrue(engine.isCandidate(1, id));
    }

    /// @notice The exact CAT example from the product spec: a token's 30-minute streak begins
    ///         while round K is open but doesn't complete before round K closes. The streak itself
    ///         is NOT reset by the round boundary (only an actual dip below threshold resets it),
    ///         so once 30 minutes elapse -- now inside round K+1 -- the very next touch qualifies
    ///         the token directly into round K+1 (the newly-current open round), with no need to
    ///         restart the 30-minute wait.
    function test_streakSpanningRoundBoundary_qualifiesIntoNewlyCurrentRound() public {
        (uint256 id, MockReserveMarket m) = _makeToken(1 ether, 1000);
        uint256 roundKOpen = this._now();
        engine.onTrade(id); // streak starts at roundKOpen, e.g. "12:45" in the spec's example

        // Round K closes 15 minutes later ("13:00"), before the streak reaches 30 minutes.
        vm.warp(roundKOpen + 900);
        _closeAndOpen(); // round K -> round K+1
        assertFalse(engine.isCandidate(1, id), "round K must close without this token ever qualifying for it");

        // Reserve never dipped, so the streak (started at roundKOpen) keeps counting uninterrupted.
        // 30 minutes after it started ("13:15") -- now inside round K+1 -- confirm with a touch.
        vm.warp(roundKOpen + 1800);
        engine.onTrade(id);

        assertTrue(engine.isCandidate(2, id), "must qualify directly into the newly-current round K+1");
        assertFalse(engine.isCandidate(1, id), "must never be retroactively added to the already-closed round K");
    }

    function test_multipleTokens_correctIndexing() public {
        uint256[] memory ids = new uint256[](4);
        MockReserveMarket[] memory ms = new MockReserveMarket[](4);
        for (uint256 i = 0; i < 4; i++) {
            (ids[i], ms[i]) = _makeToken(1 ether, 1000);
        }
        uint256 openT = this._now();
        for (uint256 i = 0; i < 4; i++) {
            engine.onTrade(ids[i]);
        }
        vm.warp(openT + 1800);
        for (uint256 i = 0; i < 4; i++) {
            engine.onTrade(ids[i]);
        }
        assertEq(engine.candidateCount(1), 4);
        bool[4] memory seen;
        for (uint256 i = 0; i < 4; i++) {
            uint256 c = engine.candidateAt(1, i);
            for (uint256 j = 0; j < 4; j++) {
                if (ids[j] == c) {
                    assertFalse(seen[j], "duplicate candidate detected");
                    seen[j] = true;
                }
            }
        }
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(seen[i], "every token must appear");
        }
    }

    /// @notice Round-close gas independent of total token count: `openRound` (the only thing
    ///         RoundManager calls on this contract at close) never iterates any per-token
    ///         structure -- confirmed by comparing its gas cost against an empty round vs. one
    ///         where 300 tokens already qualified during it.
    function test_roundCloseGas_doesNotScaleWithTokenCount() public {
        uint256 gasEmptyBefore = gasleft();
        engine.openRound(2, this._now());
        uint256 gasEmpty = gasEmptyBefore - gasleft();

        uint256 n = 300;
        MockReserveMarket[] memory pool = new MockReserveMarket[](20);
        for (uint256 i = 0; i < 20; i++) {
            pool[i] = new MockReserveMarket();
            pool[i].setProgressBps(1000);
            pool[i].setReserve(1 ether);
        }
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = engine.registerToken(address(pool[i % 20]));
        }
        engine.openRound(3, this._now());
        uint256 openT = this._now();
        for (uint256 i = 0; i < n; i++) {
            engine.onTrade(ids[i]);
        }
        vm.warp(openT + 1800);
        for (uint256 i = 0; i < n; i++) {
            engine.onTrade(ids[i]);
        }
        assertEq(engine.candidateCount(3), n);

        uint256 gasBusyBefore = gasleft();
        engine.openRound(4, this._now());
        uint256 gasBusy = gasBusyBefore - gasleft();

        assertApproxEqAbs(
            gasBusy, gasEmpty, 5_000, "closing with 300 already-qualified tokens must cost the same as an empty round"
        );
    }

    // ── setRoundManager one-time initialization ─────────────────────────────

    function test_setRoundManager_deployerCanInitializeOnce() public {
        EligibilityRegistry fresh = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        fresh.setRoundManager(address(0x9999));
        assertEq(fresh.roundManager(), address(0x9999));
    }

    function test_setRoundManager_secondInitializationReverts() public {
        EligibilityRegistry fresh = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        fresh.setRoundManager(address(0x9999));
        vm.expectRevert();
        fresh.setRoundManager(address(0x8888));
        assertEq(fresh.roundManager(), address(0x9999), "must remain permanently fixed to the first value");
    }

    function test_setRoundManager_unauthorizedCannotInitialize() public {
        EligibilityRegistry fresh = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        vm.prank(address(0xBEEF)); // not the deployer
        vm.expectRevert();
        fresh.setRoundManager(address(0x9999));
    }

    function test_setRoundManager_zeroAddressRejected() public {
        EligibilityRegistry fresh = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        vm.expectRevert();
        fresh.setRoundManager(address(0));
    }

    function test_constructor_zeroDeployerRejected() public {
        vm.expectRevert();
        new EligibilityRegistry(address(0), 500, 0.229 ether, 1_800);
    }
}
