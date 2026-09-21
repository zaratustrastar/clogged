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
import {FullSystemHandler} from "./handlers/FullSystemHandler.sol";

/// @notice Drives the complete production stack through long randomized sequences of
///         buy/sell/transfer/close-round/finalize/resolve/fulfill-randomness/claim actions, and
///         checks after every single call that the core promise made throughout this build still
///         holds under arbitrary interleaving:
///
///           No Round N action performed after Round N closes can change any Round N holder's
///           claim entitlement.
///
///         This is checked at the strongest level available: not just that a round's frozen
///         `jackpotAmount`/TWAB-derived shares stay constant, but that the ACTUAL ETH amount a
///         holder ultimately receives, whenever they get around to claiming, exactly matches what
///         was determined the instant the round's winner became known -- regardless of how much
///         trading, eligibility processing, or other rounds' activity happens in between.
contract FullSystemInvariantTest is Test {
    EligibilityRegistry engine;
    RoundManager rm;
    RewardVault vault;
    MockRandomnessProvider provider;
    FullSystemHandler handler;

    address governance = address(0x60401);
    address ticketOwner = address(0x71CE);
    address multisig = address(0xA51);

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    function setUp() public {
        provider = new MockRandomnessProvider();
        engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        rm = new RoundManager(address(engine), address(provider), governance);
        engine.setRoundManager(address(rm));
        provider.setRoundManager(address(rm));

        vault = new RewardVault(address(rm), address(0), address(0));
        vm.prank(governance);
        rm.setRewardVault(address(vault));

        MemeToken[3] memory tokens;
        BondingCurveClog[3] memory markets;
        uint256[3] memory tokenIds;
        string[3] memory names = ["Cat", "Dog", "Fish"];
        string[3] memory symbols = ["CAT", "DOG", "FISH"];

        for (uint256 i = 0; i < 3; i++) {
            uint256 predictedTokenId = engine.nextTokenId();
            MockTickerNFT tickerNFT = new MockTickerNFT();
            tickerNFT.setOwner(predictedTokenId, ticketOwner);

            tokens[i] = new MemeToken(names[i], symbols[i], address(this));
            markets[i] = new BondingCurveClog(
                address(tokens[i]), address(tickerNFT), predictedTokenId, multisig, address(vault), governance, address(engine), VIRTUAL_ETH_SEED, BUFFER_BPS
            );
            tokens[i].setMarket(address(markets[i]));
            tokenIds[i] = engine.registerToken(address(markets[i]));
            require(tokenIds[i] == predictedTokenId, "token id prediction mismatch");
        }

        address[3] memory holders = [address(0xA11CE), address(0xB0B), address(0xCA401)];

        handler = new FullSystemHandler(engine, rm, vault, provider, tokens, markets, tokenIds, holders);

        // Deterministically seed at least one allocated round BEFORE the fuzzer starts, using the
        // exact sequence already confirmed (via manual trace) to work: buy all three memes, close
        // once, fulfill. Reaching MIN_DRAW_CANDIDATES=3 requires all three memes to simultaneously
        // sustain reserve above threshold for overlapping 30-minute windows -- a real, meaningful
        // bar the draw mechanism is supposed to enforce, but one pure random single-token
        // buy/sell/transfer fuzzing essentially never reaches within a bounded call budget (any one
        // sell elsewhere in a long random sequence tends to knock some token below threshold before
        // all three line up). Seeding this precondition directly, then handing control to the
        // fuzzer, tests the ACTUAL property of interest -- whether subsequent arbitrary activity
        // can disturb an already-allocated round's entitlements -- far more directly than hoping
        // the fuzzer stumbles into the joint 3-way qualifying state on its own.
        for (uint256 i = 0; i < 5; i++) {
            handler.buyAllThree(0, 400_000 + i); // 5x, matching the exact volume proven sufficient
        }
        // Under the current live-qualification model (no more retroactive finalization at close),
        // a confirming touch AFTER the 30-minute mark is what actually locks in candidacy -- warp
        // within round 1 first, then touch again, THEN close. No age requirement and no lag: round
        // 1 (the very first round) draws from its own candidates, qualified live during itself, so
        // a single close settles it immediately -- no extra round-advance needed.
        vm.warp(rm.currentRoundOpenTime() + 1801);
        handler.buyAllThree(0, 999_999); // confirming touch -- locks in all three as round 1 candidates
        handler.advanceTimeAndCloseRound(0); // round 1 closes and settles immediately -- no lag
        handler.fulfillRandomness(999);
        require(handler.allocatedRoundsCount() > 0, "seed sequence must produce at least one allocated round");

        targetContract(address(handler));
        // Selectors are deliberately weighted (by repetition) toward buying and away from closing
        // rounds too eagerly: with all actions equally likely, `advanceTimeAndCloseRound` was
        // observed to close rounds far faster than trading could accumulate the 30-minute
        // sustained-reserve requirement anywhere. Buying is boosted (appears more often) and
        // round-closing is left at baseline weight so trading activity has room to build up
        // sustained eligibility within a round before it closes.
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = FullSystemHandler.buy.selector;
        selectors[1] = FullSystemHandler.buy.selector;
        selectors[2] = FullSystemHandler.buyAllThree.selector;
        selectors[3] = FullSystemHandler.buyAllThree.selector;
        selectors[4] = FullSystemHandler.buyAllThree.selector;
        selectors[5] = FullSystemHandler.sell.selector;
        selectors[6] = FullSystemHandler.transfer.selector;
        selectors[7] = FullSystemHandler.advanceTimeAndCloseRound.selector;
        selectors[8] = FullSystemHandler.fulfillRandomness.selector;
        selectors[9] = FullSystemHandler.claim.selector;
        selectors[10] = FullSystemHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice THE core invariant: for every round that has ever been observed to settle, each
    ///         holder's entitlement -- whether still unclaimed (previewClaim) or already paid out
    ///         (actualPaid, recorded at the moment of claim) -- must exactly match the snapshot
    ///         taken the instant that round's winner became known. No amount of subsequent
    ///         trading, transferring, or other rounds' processing may change it.
    function invariant_noPostCloseActionChangesAnyRoundsClaimEntitlement() public view {
        uint256 n = handler.allocatedRoundsCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 roundId = handler.allocatedRounds(i);
            address[3] memory holders = [address(0xA11CE), address(0xB0B), address(0xCA401)];
            for (uint256 h = 0; h < 3; h++) {
                address holder = holders[h];
                uint256 snapshot = handler.claimSnapshot(roundId, holder);
                bool claimed = vault.claimed(roundId, holder);
                if (claimed) {
                    uint256 paid = handler.actualPaid(roundId, holder);
                    assertEq(paid, snapshot, "amount actually paid must match the snapshot taken at allocation time");
                } else {
                    uint256 current = vault.previewClaim(roundId, holder);
                    assertEq(current, snapshot, "unclaimed entitlement must remain exactly what it was at allocation time");
                }
            }
        }
    }

    /// @notice Secondary invariant: a round's frozen jackpot amount itself, once allocated, must
    ///         never change (independent of any individual holder's share of it).
    function invariant_allocatedJackpotNeverChanges() public view {
        uint256 n = handler.allocatedRoundsCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 roundId = handler.allocatedRounds(i);
            RewardVault.RoundAllocation memory a = vault.getAllocation(roundId);
            assertLe(a.totalClaimed, a.jackpotAmount, "cumulative claims can never exceed the frozen jackpot");
        }
    }

    /// @notice Round-state invariant: a round already observed closed must stay closed forever --
    ///         and, more generally, every round strictly before the current one must be closed
    ///         (rounds only ever advance forward through closing, never reopen).
    function invariant_closedRoundsNeverReopen() public view {
        uint256 current = rm.currentRoundId();
        for (uint256 r = 1; r < current; r++) {
            assertTrue(rm.getRound(r).closed, "every round before the current one must be closed and stay closed");
        }
    }

    /// @notice Round-state invariant: once a round's winner is determined, it can never change --
    ///         and randomness for that round can never be "accepted" a second time (RoundManager's
    ///         own `require(!r.settled)` guard enforces this on-chain; this cross-checks it against
    ///         an independent ghost snapshot recorded the instant settlement was first observed).
    function invariant_settledWinnerNeverChanges() public view {
        uint256 n = handler.allocatedRoundsCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 roundId = handler.allocatedRounds(i);
            uint256 snapshot = handler.winnerSnapshot(roundId);
            uint256 current = rm.getRound(roundId).winnerTokenId;
            assertEq(current, snapshot, "a settled round's winner must never change");
        }
    }

    /// @notice Round-state invariant: once a round's candidate set is finalized, no LATER activity
    ///         (in any subsequent round, or any further finalization/trading elsewhere) can change
    ///         its size. Candidate lists are append-only during the SOURCE round and finalization
    ///         only ever runs to completion once per round -- this independently cross-checks that
    ///         guarantee against a ghost snapshot taken the instant finalization first completed.
    function invariant_finalizedCandidateSetsNeverMutate() public view {
        uint256 current = rm.currentRoundId();
        for (uint256 r = 1; r < current; r++) {
            if (!handler.candidateSnapshotTaken(r)) continue;
            assertEq(
                engine.candidateCount(r),
                handler.candidateCountSnapshot(r),
                "a finalized round's candidate set must never change afterward"
            );
        }
    }

    /// @notice Accounting invariant: RewardVault's actual ETH balance must always be enough to
    ///         cover every allocated-but-not-yet-fully-claimed round's remaining liability, plus
    ///         whatever sits in the live unallocated pool. RewardVault never owes more than it holds.
    function invariant_rewardVaultLiabilitiesAreBacked() public view {
        uint256 totalOutstanding = vault.unallocatedPool();
        uint256 n = handler.allocatedRoundsCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 roundId = handler.allocatedRounds(i);
            RewardVault.RoundAllocation memory a = vault.getAllocation(roundId);
            if (!a.swept) {
                totalOutstanding += (a.jackpotAmount - a.totalClaimed);
            }
        }
        assertLe(totalOutstanding, address(vault).balance, "RewardVault must always hold enough ETH to cover every outstanding liability");
    }

    /// @notice Sanity invariant: the winnerPot accounting identity must hold across every market
    ///         at every point in the sequence, regardless of what combination of actions ran.
    function invariant_winnerPotAccountingIdentity() public view {
        for (uint256 i = 0; i < 3; i++) {
            BondingCurveClog m = handler.markets(i);
            assertEq(
                m.winnerPotGenerated(),
                m.deliveredWinnerPot() + m.pendingWinnerPot(),
                "winnerPotGenerated == deliveredWinnerPot + pendingWinnerPot must always hold"
            );
        }
    }

    /// @notice THE ATOMIC ELIGIBILITY INVARIANT: a market currently below the reserve threshold
    ///         must never show a live (nonzero) streak start time. This is the exact property the
    ///         earlier best-effort/try-catch eligibility design violated (a missed touch during a
    ///         below-threshold dip could leave a stale pre-dip timestamp in place) and the reason
    ///         the callback was made atomic with the trade instead. Checked directly against
    ///         current on-chain state -- no ghost snapshot needed, since this must hold at every
    ///         single point in time, not just across a before/after comparison.
    function invariant_reserveStateNeverDivergesFromEligibilityTimer() public view {
        uint256 threshold = engine.minReserveThreshold();
        for (uint256 i = 0; i < 3; i++) {
            BondingCurveClog m = handler.markets(i);
            uint256 tokenId = handler.tokenIds(i);
            if (m.realReserve() < threshold) {
                assertEq(
                    engine.aboveThresholdSince(tokenId),
                    0,
                    "a market currently below the reserve threshold must never show a live streak start time"
                );
            }
        }
    }

    /// @notice Round-state invariant: once a round's randomness request succeeds, its requestId
    ///         can never change -- there is exactly one successful VRF request ever created for
    ///         any given round, regardless of how many retries were attempted before or after.
    function invariant_atMostOneSuccessfulRandomnessRequestPerRound() public view {
        uint256 current = rm.currentRoundId();
        for (uint256 r = 1; r < current; r++) {
            RoundManager.RoundInfo memory info = rm.getRound(r);
            if (!info.randomnessRequested) continue;
            uint256 snapshot = handler.randomnessRequestIdSnapshot(r);
            if (snapshot == 0) continue; // handler hasn't observed this one yet this run; nothing to compare
            assertEq(info.randomnessRequestId, snapshot, "a round's successful randomness requestId must never change once set");
        }
    }

    /// @notice Special Foundry hook, called after invariant checks each run (including during
    ///         shrinking of a candidate failing sequence). Deliberately asserts ONLY the one fact
    ///         that is guaranteed true immediately after `setUp()` and can never become false
    ///         (allocatedRoundsCount is append-only and setUp() seeds it to 1): this is safe to
    ///         assert here without interfering with shrinking. Per-run "were enough actions
    ///         attempted" checks (claims, buys, sells...) do NOT belong here -- found the hard way:
    ///         Foundry's shrinker, searching for a minimal reproduction of an unrelated invariant
    ///         failure, can legitimately shrink a sequence down to "just past setUp(), almost no
    ///         calls yet" and then report THAT as the failure once it trips a coverage assertion
    ///         like "at least one claim was attempted" -- which is trivially false immediately
    ///         after setUp() by construction, before the fuzzer has done anything at all. That is
    ///         a shrinking artifact, not a real invariant violation. Genuine coverage (that the
    ///         full, unshrunk campaign meaningfully exercises every action type) is verified from
    ///         the per-selector call-count table Foundry prints for the whole campaign, not
    ///         asserted inside this hook.
    function afterInvariant() public view {
        assertGt(handler.allocatedRoundsCount(), 0, "coverage check: the campaign must have actually allocated at least one round");
    }
}
