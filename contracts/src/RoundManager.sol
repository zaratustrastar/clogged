// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EligibilityRegistry} from "./EligibilityRegistry.sol";
import {IRandomnessProvider} from "./IRandomnessProvider.sol";

interface IRewardVault {
    function allocateRound(uint256 roundId, uint256 winnerTokenId, address market, uint256 windowOpen, uint256 windowClose)
        external;
}

/// @title RoundManager
/// @notice Owns the hourly round lifecycle. Winner selection is UNIFORM among eligible candidates.
///
/// @dev Candidate timing: the token candidates DRAWN when round R closes were built during round
///      R-1, and have been fully fixed since round R opened. VRF for round R's draw is still only
///      requested AT round R's close, even though the candidate set was known at its open -- NOT
///      because of candidacy, but because round R's own HOLDER TWAB window (which determines
///      payout shares if a token wins) only closes then. Requesting VRF early would let someone
///      who learns the winning token mid-round rush to buy it and inflate their payout share
///      before that window shuts.
///
/// @dev SIMPLICITY: `closeRoundAndOpenNext` closes the round, opens the next, and immediately
///      requests VRF if enough candidates exist -- all O(1). EligibilityRegistry builds each
///      round's candidate list live, incrementally, during the round itself (see its own
///      developer notes), so by the time a round closes there is nothing left to compute: no
///      watchlist scan, no batching, no cursor, no deferred "awaiting finalization" round state.
contract RoundManager {
    EligibilityRegistry public immutable engine;
    IRandomnessProvider public randomnessProvider;
    IRewardVault public rewardVault;
    address public governance;

    uint256 public constant ROUND_DURATION = 3600; // seconds
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
    event RoundSettled(uint256 indexed roundId, uint256 indexed winnerTokenId, uint256 randomWord);
    event RandomnessProviderUpdated(address indexed newProvider);
    event RewardVaultUpdated(address indexed newVault);

    modifier onlyGovernance() {
        require(msg.sender == governance, "not governance");
        _;
    }

    constructor(address engine_, address randomnessProvider_, address governance_) {
        require(engine_ != address(0) && randomnessProvider_ != address(0) && governance_ != address(0), "zero address");
        engine = EligibilityRegistry(engine_);
        randomnessProvider = IRandomnessProvider(randomnessProvider_);
        governance = governance_;

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
    ///         requests randomness for it if enough candidates exist. Candidate finalization
    ///         requires nothing here -- EligibilityRegistry builds each round's candidate list
    ///         live, incrementally, during the round itself, so by the time it closes the list is
    ///         already complete. This function is O(1): it never loops over tokens.
    function closeRoundAndOpenNext() external returns (uint256 closedRoundId) {
        require(block.timestamp >= currentRoundOpenTime + ROUND_DURATION, "round not over yet");

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
            uint256 requestId = randomnessProvider.requestRandomness(closedRoundId);
            r.randomnessRequested = true;
            r.randomnessRequestId = requestId;
            requestIdToRoundId[requestId] = closedRoundId;
            emit RandomnessRequested(closedRoundId, requestId);
        } else {
            r.drawSkipped = true;
        }

        emit RoundClosed(closedRoundId, block.timestamp, r.candidateCount, r.drawSkipped);
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
