// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {BondingCurveClog} from "../../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../../src/EligibilityRegistry.sol";
import {RoundManager} from "../../src/RoundManager.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";

/// @notice Drives the full production stack (real BondingCurveClog/MemeToken/EligibilityRegistry/
///         RoundManager/RewardVault) through bounded-random buy/sell/transfer/close/randomness/
///         claim sequences across a small fixed universe (3 memes, 3 holders), and records a ghost
///         snapshot of every round's claim entitlements the FIRST time each round is observed to
///         be allocated -- so the test contract's invariant can assert those snapshots never
///         change afterward, no matter what the handler does next.
///
/// @dev Simplified alongside the production redesign: eligibility finalization is now automatic
///      and synchronous inside RoundManager.closeRoundAndOpenNext, so this handler no longer needs
///      separate finalize/resolve sweep actions -- only closing rounds, fulfilling VRF requests
///      (still a genuinely separate async step), and claiming remain as distinct actions.
contract FullSystemHandler is Test {
    EligibilityRegistry public engine;
    RoundManager public rm;
    RewardVault public vault;
    MockRandomnessProvider public provider;

    uint256 constant N_MEMES = 3;
    uint256 constant N_HOLDERS = 3;

    MemeToken[N_MEMES] public tokens;
    BondingCurveClog[N_MEMES] public markets;
    uint256[N_MEMES] public tokenIds;
    address[N_HOLDERS] public holders;

    // Ghost state for the invariants.
    mapping(uint256 => bool) public roundSnapshotTaken;
    mapping(uint256 => mapping(address => uint256)) public claimSnapshot;
    mapping(uint256 => mapping(address => uint256)) public actualPaid; // recorded at claim time
    mapping(uint256 => uint256) public winnerSnapshot; // winnerTokenId, recorded once at settlement
    mapping(uint256 => uint256) public candidateCountSnapshot; // recorded once a round finalizes
    mapping(uint256 => bool) public candidateSnapshotTaken;
    mapping(uint256 => uint256) public randomnessRequestIdSnapshot; // recorded the first time a
    // round's randomness request is observed to have succeeded (0 = not yet observed --
    // MockRandomnessProvider's first real requestId is always 1, never 0)
    uint256[] public allocatedRounds; // rounds we've observed become allocated, in order

    uint256 public buyCalls;
    uint256 public sellCalls;
    uint256 public transferCalls;
    uint256 public closeCalls;
    uint256 public fulfillCalls;
    uint256 public claimCalls;

    uint256 constant FULFILL_WINDOW = 15; // bounded recent-round window for fulfillRandomness sweeps

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    constructor(
        EligibilityRegistry engine_,
        RoundManager rm_,
        RewardVault vault_,
        MockRandomnessProvider provider_,
        MemeToken[N_MEMES] memory tokens_,
        BondingCurveClog[N_MEMES] memory markets_,
        uint256[N_MEMES] memory tokenIds_,
        address[N_HOLDERS] memory holders_
    ) {
        engine = engine_;
        rm = rm_;
        vault = vault_;
        provider = provider_;
        tokens = tokens_;
        markets = markets_;
        tokenIds = tokenIds_;
        holders = holders_;
    }

    function buy(uint256 memeSeed, uint256 holderSeed, uint256 amountSeed) external {
        uint256 m = memeSeed % N_MEMES;
        uint256 h = holderSeed % N_HOLDERS;
        uint256 amount = bound(amountSeed, 0.01 ether, 0.3 ether); // stay well within curve inventory
        vm.deal(holders[h], holders[h].balance + amount);
        vm.prank(holders[h]);
        try markets[m].buy{value: amount}(0, block.timestamp) {
            buyCalls++;
            engine.onTrade(tokenIds[m]);
        } catch {}
    }

    /// @dev Buys a bounded amount of ALL THREE memes in one call. MIN_DRAW_CANDIDATES=3 requires
    ///      all three to simultaneously sustain reserve above threshold for overlapping 30-minute
    ///      windows within the same round -- pure single-token random buys essentially never
    ///      coordinate this within a bounded number of fuzzer calls (confirmed via manual trace),
    ///      so this gives the fuzzer a realistic way to reach genuine broad participation.
    function buyAllThree(uint256 holderSeed, uint256 amountSeed) external {
        uint256 h = holderSeed % N_HOLDERS;
        uint256 amount = bound(amountSeed, 0.05 ether, 0.3 ether);
        for (uint256 m = 0; m < N_MEMES; m++) {
            vm.deal(holders[h], holders[h].balance + amount);
            vm.prank(holders[h]);
            try markets[m].buy{value: amount}(0, block.timestamp) {
                buyCalls++;
                engine.onTrade(tokenIds[m]);
            } catch {}
        }
    }

    function sell(uint256 memeSeed, uint256 holderSeed, uint256 fractionSeed) external {
        uint256 m = memeSeed % N_MEMES;
        uint256 h = holderSeed % N_HOLDERS;
        uint256 bal = tokens[m].balanceOf(holders[h]);
        if (bal == 0) return;
        uint256 fraction = bound(fractionSeed, 1, 40); // partial sells only, so sustained
        // qualification stays realistically reachable for the fuzzer
        uint256 amount = (bal * fraction) / 100;
        if (amount == 0) return;
        vm.prank(holders[h]);
        try markets[m].sell(amount, 0, block.timestamp) {
            sellCalls++;
            engine.onTrade(tokenIds[m]);
        } catch {}
    }

    function transfer(uint256 memeSeed, uint256 fromSeed, uint256 toSeed, uint256 fractionSeed) external {
        uint256 m = memeSeed % N_MEMES;
        uint256 f = fromSeed % N_HOLDERS;
        uint256 t = toSeed % N_HOLDERS;
        uint256 bal = tokens[m].balanceOf(holders[f]);
        if (bal == 0 || f == t) return;
        uint256 fraction = bound(fractionSeed, 1, 100);
        uint256 amount = (bal * fraction) / 100;
        if (amount == 0) return;
        vm.prank(holders[f]);
        try tokens[m].transfer(holders[t], amount) {
            transferCalls++;
        } catch {}
    }

    /// @dev Closing now automatically finalizes the closed round's own candidate list
    ///      synchronously (no separate finalize/resolve sweep needed) -- just record the ghost
    ///      candidate-count snapshot for whichever round just finalized.
    function advanceTimeAndCloseRound(uint256 warpSeed) external {
        uint256 extra = bound(warpSeed, 0, 600);
        uint256 target = rm.currentRoundOpenTime() + rm.roundDuration() + extra;
        if (block.timestamp < target) {
            vm.warp(target);
        }
        try rm.closeRoundAndOpenNext() returns (uint256 closedRoundId) {
            closeCalls++;
            _maybeSnapshotCandidates(closedRoundId);
            _maybeSnapshotRandomnessRequest(closedRoundId);
        } catch {}
    }

    /// @dev VRF fulfillment is still a genuinely separate, asynchronous step (mirrors the real
    ///      Chainlink round trip), so this remains its own handler action. Sweeps a bounded recent
    ///      window of rounds for outstanding requests rather than the entire history, keeping cost
    ///      bounded regardless of how many rounds have accumulated over a long run.
    function fulfillRandomness(uint256 wordSeed) external {
        uint256 current = rm.currentRoundId();
        if (current <= 1) return;
        uint256 from = current > FULFILL_WINDOW ? current - FULFILL_WINDOW : 1;
        for (uint256 r = from; r < current; r++) {
            RoundManager.RoundInfo memory info = rm.getRound(r);
            if (info.randomnessRequested && !info.settled) {
                uint256 word = uint256(keccak256(abi.encode(wordSeed, r, "fulfill")));
                try provider.fulfill(info.randomnessRequestId, word) {
                    fulfillCalls++;
                    _maybeSnapshot(r);
                } catch {}
            }
        }
    }

    function claim(uint256 roundSeed, uint256 holderSeed) external {
        uint256 current = rm.currentRoundId();
        if (current <= 1) return;
        uint256 r = bound(roundSeed, 1, current - 1);
        uint256 h = holderSeed % N_HOLDERS;
        uint256 before = holders[h].balance;
        try vault.claim(r, holders[h]) {
            claimCalls++;
            actualPaid[r][holders[h]] = holders[h].balance - before;
        } catch {}
    }

    /// @dev Called right after a round is observed to have settled (randomness fulfilled,
    ///      allocation happened). Records EACH holder's `previewClaim` for that round exactly
    ///      once -- this is the ghost snapshot the invariant compares everything against.
    function _maybeSnapshot(uint256 roundId) internal {
        if (roundSnapshotTaken[roundId]) return;
        RoundManager.RoundInfo memory info = rm.getRound(roundId);
        if (!info.settled) return;
        roundSnapshotTaken[roundId] = true;
        winnerSnapshot[roundId] = info.winnerTokenId;
        allocatedRounds.push(roundId);
        for (uint256 h = 0; h < N_HOLDERS; h++) {
            claimSnapshot[roundId][holders[h]] = vault.previewClaim(roundId, holders[h]);
        }
    }

    /// @dev Records a round's candidate count exactly once, right after that round closes (which
    ///      is itself the "finalization" signal now -- once closed, EligibilityRegistry's
    ///      currentRoundId has moved past it, so nothing can add further candidates to it). Used
    ///      to verify later activity can never mutate an already-closed round's candidate set.
    function _maybeSnapshotCandidates(uint256 roundId) internal {
        if (candidateSnapshotTaken[roundId]) return;
        candidateSnapshotTaken[roundId] = true;
        candidateCountSnapshot[roundId] = engine.candidateCount(roundId);
    }

    function _maybeSnapshotRandomnessRequest(uint256 roundId) internal {
        if (randomnessRequestIdSnapshot[roundId] != 0) return;
        RoundManager.RoundInfo memory info = rm.getRound(roundId);
        if (!info.randomnessRequested) return;
        randomnessRequestIdSnapshot[roundId] = info.randomnessRequestId;
    }

    function allocatedRoundsCount() external view returns (uint256) {
        return allocatedRounds.length;
    }
}
