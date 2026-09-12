// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EligibilityRegistry} from "./EligibilityRegistry.sol";
import {IRandomnessProvider} from "./IRandomnessProvider.sol";

interface IRewardVault {
    function allocateRound(
        uint256 roundId,
        uint256 winnerTokenId,
        address market,
        uint256 windowOpen,
        uint256 windowClose
    ) external;
}

/// @title RoundManager
/// @notice Owns the hourly round lifecycle. Winner selection is UNIFORM among eligible candidates.
///
/// @dev Candidate timing: the candidates drawn when round R closes are exactly the ones that
///      qualified DURING round R itself -- no lag, no candidates carried over from a prior round
///      (see EligibilityRegistry's own developer notes). The candidate set for round R is
///      therefore only fully fixed the moment round R closes, not before.
///
/// @dev SIMPLICITY: `closeRoundAndOpenNext` closes the round, opens the next, and ATTEMPTS to
///      request VRF if enough candidates exist -- all O(1). EligibilityRegistry builds each
///      round's candidate list live, incrementally, during the round itself, so by the time a
///      round closes there is nothing left to compute: no watchlist scan, no batching, no cursor,
///      no deferred "awaiting finalization" round state.
///
/// @dev LIVENESS: the randomness request is attempted via try/catch and can never revert the
///      close itself -- see `closeRoundAndOpenNext`'s own notes below. Any number of historical
///      rounds may be simultaneously closed-and-awaiting-randomness; each settles independently,
///      whenever its own randomness eventually arrives, with zero effect on any other round's
///      trading, qualification, closing, or settlement.
contract RoundManager {
    EligibilityRegistry public immutable engine;
    IRandomnessProvider public randomnessProvider;
    IRewardVault public rewardVault;
    address public governance;

    uint256 public immutable roundDuration; // seconds; deployment-configured, no setter -- e.g.
    // a short value for a canary rehearsal, 3600 in production; the round-close/candidate/
    // draw algorithm itself is identical bit-for-bit regardless of this value.
    uint256 public constant MIN_DRAW_CANDIDATES = 3; // below this, a round is skipped (no VRF
    // requested) and the pot simply keeps accumulating into whichever future round first
    // clears the bar.

    uint256 public currentRoundId;
    uint256 public currentRoundOpenTime;

    struct RoundInfo {
        uint256 openTime;
        uint256 closeTime;
        uint256 candidateRoundId; // which EligibilityRegistry generation this round draws from
        // (== roundId itself now -- no lag: a round draws from candidates that qualified while
        // it was open, not the round before it; see EligibilityRegistry's contract-level notes)
        uint256 candidateCount;
        bool closed;
        bool drawSkipped; // true if candidateCount < MIN_DRAW_CANDIDATES -- no VRF requested
        bool randomnessRequested;
        uint256 randomnessRequestId;
        bool settled;
        uint256 winnerTokenId;
    }

    mapping(uint256 => RoundInfo) public rounds;
    mapping(uint256 => uint256) public requestIdToRoundId;

    event RoundClosed(uint256 indexed roundId, uint256 closeTime, uint256 candidateCount, bool drawSkipped);
    event RandomnessRequested(uint256 indexed roundId, uint256 requestId);
    event RandomnessRequestFailed(uint256 indexed roundId);
    event RoundSettled(uint256 indexed roundId, uint256 indexed winnerTokenId, uint256 randomWord);
    event RandomnessProviderUpdated(address indexed newProvider);
    event RewardVaultUpdated(address indexed newVault);

    modifier onlyGovernance() {
        require(msg.sender == governance, "not governance");
        _;
    }

    constructor(address engine_, address randomnessProvider_, address governance_, uint256 roundDuration_) {
        require(engine_ != address(0) && randomnessProvider_ != address(0) && governance_ != address(0), "zero address");
        require(roundDuration_ > 0, "invalid roundDuration");
        engine = EligibilityRegistry(engine_);
        randomnessProvider = IRandomnessProvider(randomnessProvider_);
        governance = governance_;
        roundDuration = roundDuration_;

        currentRoundId = 1;
        currentRoundOpenTime = block.timestamp;
        rounds[1].openTime = block.timestamp;
    }

    function setRandomnessProvider(address newProvider) external onlyGovernance {
        require(newProvider != address(0), "zero address");
        randomnessProvider = IRandomnessProvider(newProvider);
        emit RandomnessProviderUpdated(newProvider);
    }

    /// @notice RewardVault must be deployed AFTER RoundManager (it needs RoundManager's own
    ///         address in its constructor), so it can't be wired in at construction -- set once here.
    function setRewardVault(address newVault) external onlyGovernance {
        require(newVault != address(0), "zero address");
        rewardVault = IRewardVault(newVault);
        emit RewardVaultUpdated(newVault);
    }

    /// @notice Permissionless. Closes the current round, opens the next one immediately, and
    ///         ATTEMPTS to request randomness for it if enough candidates exist. Candidate
    ///         finalization requires nothing here -- EligibilityRegistry builds each round's
    ///         candidate list live, incrementally, during the round itself, so by the time it
    ///         closes the list is already complete. This function is O(1): it never loops over
    ///         tokens.
    ///
    /// @dev LIVENESS: closing the round and opening the next one NEVER depends on the randomness
    ///      request succeeding. The request is attempted via try/catch -- if the provider is
    ///      temporarily underfunded, reverting, or CCIP is unavailable, THIS FUNCTION STILL
    ///      SUCCEEDS: the round still closes, the next round still opens on schedule, trading and
    ///      qualification continue completely unaffected. A failed attempt leaves
    ///      `randomnessRequested == false`, which is exactly the condition
    ///      `requestRandomnessForRound` checks to allow a later permissionless retry. Multiple
    ///      historical rounds can be simultaneously closed-but-unsettled at once; each one's
    ///      eventual randomness/settlement timing is entirely independent of every other round's,
    ///      and independent of however many NEWER rounds have since opened and closed.
    function closeRoundAndOpenNext() external returns (uint256 closedRoundId) {
        require(block.timestamp >= currentRoundOpenTime + roundDuration, "round not over yet");

        closedRoundId = currentRoundId;
        RoundInfo storage r = rounds[closedRoundId];
        r.closeTime = block.timestamp;
        r.closed = true;
        r.candidateRoundId = closedRoundId; // no lag: draws from candidates that qualified into
        // this same round while it was open (see EligibilityRegistry's contract-level notes) --
        // this is what lets the very first round the protocol ever opens produce a winner

        currentRoundId += 1;
        currentRoundOpenTime = block.timestamp;
        rounds[currentRoundId].openTime = block.timestamp;
        engine.openRound(currentRoundId, block.timestamp);

        r.candidateCount = engine.candidateCount(r.candidateRoundId);

        if (r.candidateCount >= MIN_DRAW_CANDIDATES) {
            _attemptRandomnessRequest(closedRoundId, r);
        } else {
            r.drawSkipped = true;
        }

        emit RoundClosed(closedRoundId, block.timestamp, r.candidateCount, r.drawSkipped);
    }

    /// @notice Permissionless retry: if the randomness request attempt made at close time failed
    ///         (the provider reverted -- e.g. temporarily underfunded, CCIP unavailable, anything),
    ///         anyone can retry it later, as many times as needed, for as long as it keeps failing.
    ///         Once a request has SUCCEEDED for a round (`randomnessRequested == true`), this can
    ///         never fire again for that round -- exactly one successful randomness request per
    ///         round, no rerolls, no re-requesting a round that's already awaiting or has already
    ///         received its result.
    function requestRandomnessForRound(uint256 roundId) external {
        RoundInfo storage r = rounds[roundId];
        require(r.closed, "round not closed");
        require(!r.drawSkipped, "round has no draw");
        require(!r.randomnessRequested, "already requested");
        require(!r.settled, "already settled");
        _attemptRandomnessRequest(roundId, r);
    }

    function _attemptRandomnessRequest(uint256 roundId, RoundInfo storage r) internal {
        try randomnessProvider.requestRandomness(roundId) returns (uint256 requestId) {
            r.randomnessRequested = true;
            r.randomnessRequestId = requestId;
            requestIdToRoundId[requestId] = roundId;
            emit RandomnessRequested(roundId, requestId);
        } catch {
            emit RandomnessRequestFailed(roundId);
        }
    }

    /// @notice Called by the randomness provider once VRF/CCIP delivers the word. Selects the
    ///         winner via an unbiased index into the round's frozen candidate list.
    function onRandomnessReceived(uint256 requestId, uint256 randomWord) external {
        require(msg.sender == address(randomnessProvider), "not randomness provider");
        uint256 roundId = requestIdToRoundId[requestId];
        require(roundId != 0, "unknown request");
        RoundInfo storage r = rounds[roundId];
        require(r.closed, "round not closed");
        require(!r.settled, "already settled");
        require(r.candidateCount > 0, "no candidates");

        uint256 index = _unbiasedIndex(randomWord, roundId, r.candidateCount);
        uint256 winner = engine.candidateAt(r.candidateRoundId, index);

        r.settled = true;
        r.winnerTokenId = winner;
        emit RoundSettled(roundId, winner, randomWord);

        if (address(rewardVault) != address(0)) {
            address market = engine.tokenMarket(winner);
            rewardVault.allocateRound(roundId, winner, market, r.openTime, r.closeTime);
        }
    }

    /// @dev Standard rejection-sampling technique for an unbiased random index in [0, n).
    function _unbiasedIndex(uint256 randomWord, uint256 roundId, uint256 n) internal pure returns (uint256) {
        uint256 limit = type(uint256).max - (type(uint256).max % n);
        uint256 r = randomWord;
        uint256 attempt = 0;
        while (r >= limit) {
            attempt++;
            r = uint256(keccak256(abi.encode(randomWord, roundId, "unbias", attempt)));
        }
        return r % n;
    }

    function getRound(uint256 roundId) external view returns (RoundInfo memory) {
        return rounds[roundId];
    }

    /// @dev Test-only exposure of the internal unbiased-index derivation.
    function exposedUnbiasedIndex(uint256 randomWord, uint256 roundId, uint256 n) external pure returns (uint256) {
        return _unbiasedIndex(randomWord, roundId, n);
    }
}
