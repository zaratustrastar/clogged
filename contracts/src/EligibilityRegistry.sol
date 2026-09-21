// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRealReserve {
    function realReserve() external view returns (uint256);
    function progressBps() external view returns (uint256);
}

/// @title EligibilityRegistry
/// @notice Decides which tokens are candidates for the uniform lottery draw:
///           - HWM curve progress >= minProgressBps (immutable per-deployment, 500 bps in production)
///           - real reserve continuously >= minReserveThreshold for >= requiredAbsoluteSeconds
///         There is no minimum token age: a token launched minutes ago can qualify for the
///         CURRENTLY open round the moment it satisfies the above, exactly like any older token.
///
/// @dev CANDIDATE TIMING, NO LAG: a token that satisfies eligibility while round K is still open
///      is appended directly to round K's OWN candidate array -- not round K+1's. `pendingCandidates[K]`
///      is built INCREMENTALLY, live, during round K itself, and is already complete by the time
///      round K closes -- so round K's own draw (resolved when it closes) can include tokens that
///      only launched during round K. This also means the very first round the protocol ever opens
///      can produce a winner, if at least MIN_DRAW_CANDIDATES qualify before it closes. Round close
///      therefore does zero eligibility computation: `RoundManager.closeRoundAndOpenNext` just
///      reads `candidateCount`, already populated. No watchlist, no batched/deferred finalization,
///      no per-round close-time loop -- round-close gas is O(1) regardless of how many tokens exist
///      or trade.
///
/// @dev WHY THE 30-MINUTE REQUIREMENT (quantified, not assumed): round-close is permissionless, so
///      a pure point-in-time "reserve >= X at close" check can be gamed by buying, immediately
///      closing the round yourself, then selling back -- exposure compresses to about one block,
///      and the cost to guarantee an entire round's jackpot (fake exactly MIN_DRAW_CANDIDATES
///      tokens) comes out to roughly 0.01 ETH under Config G curve params. Requiring a continuous
///      streak above threshold closes that hole: the attacker can't control wall-clock time the
///      way they control which block they close in. This is the load-bearing anti-manipulation
///      mechanism -- not token age, which is why removing the age requirement doesn't reopen it.
///
/// @dev O(1) PER-TOKEN QUALIFICATION: each token tracks a single `aboveThresholdSince` timestamp --
///      0 if not currently above threshold, else the moment its current continuous streak began.
///      Set once when reserve crosses up from below; reset to 0 the instant it dips back down.
///      This timestamp is NOT reset by a round boundary -- only by an actual dip below threshold --
///      so a streak that starts in one round and crosses into the next keeps counting continuously
///      (see `test_streakSpanningRoundBoundary_qualifiesIntoNewlyCurrentRound`). What DOES reset
///      every round is candidacy itself: `pendingCandidates` is a fresh, empty array per round id,
///      so satisfying the streak requirement only ever adds a token to whichever round is CURRENTLY
///      open at the moment of the qualifying touch -- never retroactively to a round that already
///      closed, and never automatically carried into a future round without a fresh touch there.
///      Qualification is checked and, if the bar is met, IMMEDIATELY finalized (appended once to
///      the current round's candidate array) at the moment of EITHER:
///        (a) the token's own next ordinary trade (`onTrade`), or
///        (b) a permissionless explicit call to `qualify(tokenId)` by anyone.
///      There is no other path to qualification, and deliberately no third path that guarantees it
///      happens automatically the instant 30 minutes elapses with zero further activity.
///
/// @dev ACCEPTED CAVEAT (explicitly not engineered around): if a token crosses the 30-minute bar
///      but is never traded again and nobody calls `qualify` on it before the round closes, it
///      misses that round's candidacy -- though its streak keeps counting, so a later touch (even
///      in a subsequent round) qualifies it the moment it happens, with no need to wait out another
///      30 minutes as long as it never dipped below threshold. Any interested party (the token's
///      own holders, most obviously) can trivially close this gap themselves with one
///      permissionless `qualify` call.
contract EligibilityRegistry {
    uint256 public constant MAX_TICKERS = 7_778; // 7,777 public + 1 reserved (CLOG) -- capacity, not
        // an economic parameter, so this stays a true compile-time constant across every deployment.

    /// @notice Deployment-scoped eligibility parameters, immutable once constructed -- no
    ///         governance setter, no admin setter, no path to change them after deployment, by
    ///         design (see the task this was built for: "immutable deployment parameters").
    ///         Semantics are byte-for-byte identical to what were previously hardcoded constants
    ///         of the same name (just upper-cased) -- only WHERE the value comes from changed,
    ///         from "baked into this contract's bytecode" to "chosen once at construction time".
    ///         This is what lets a canary deployment (cheap, fast qualification for full-cycle
    ///         testing) and the final public deployment (real economic gates) share the exact
    ///         same contract source, differing only in deployment-time configuration -- never a
    ///         Solidity code fork between the two.
    uint256 public immutable minProgressBps; // HWM curve progress gate, in basis points of CURVE_ALLOCATION
    uint256 public immutable minReserveThreshold; // real-reserve gate, in wei
    uint256 public immutable requiredAbsoluteSeconds; // continuous above-threshold streak required

    address public immutable deployer; // authorized to call setRoundManager exactly once
    address public roundManager; // address(0) until setRoundManager is called; permanent afterward

    mapping(uint256 => address) public tokenMarket;
    uint256 public nextTokenId = 1;

    uint256 public currentRoundId; // == RoundManager.currentRoundId, kept in sync via `openRound`
    uint256 public currentRoundOpenTime;

    // Per token: the timestamp its current continuous above-threshold streak began (0 if not
    // currently above threshold). Carries across round boundaries untouched -- only an actual dip
    // below minReserveThreshold resets it. See contract-level notes above.
    mapping(uint256 => uint256) public aboveThresholdSince;

    // Per-round (generation) dense candidate arrays -- append-only, built live during the round,
    // already complete by the time that round closes. tokenId -> index+1 (0 = not present) doubles
    // as the "already qualified this round" check.
    mapping(uint256 => uint256[]) private pendingCandidates;
    mapping(uint256 => mapping(uint256 => uint256)) private candidateIndexPlusOne;

    event TokenRegistered(uint256 indexed tokenId, address market);
    event RoundOpened(uint256 indexed roundId, uint256 openTime);
    event Qualified(uint256 indexed round, uint256 indexed tokenId);
    event RoundManagerInitialized(address indexed roundManager);

    modifier onlyRoundManager() {
        require(msg.sender == roundManager, "not round manager");
        _;
    }

    constructor(
        address deployer_,
        uint256 minProgressBps_,
        uint256 minReserveThreshold_,
        uint256 requiredAbsoluteSeconds_
    ) {
        require(deployer_ != address(0), "zero deployer");
        require(minProgressBps_ > 0 && minProgressBps_ <= 10_000, "invalid minProgressBps");
        require(minReserveThreshold_ > 0, "zero minReserveThreshold");
        require(requiredAbsoluteSeconds_ > 0, "zero requiredAbsoluteSeconds");
        deployer = deployer_;
        minProgressBps = minProgressBps_;
        minReserveThreshold = minReserveThreshold_;
        requiredAbsoluteSeconds = requiredAbsoluteSeconds_;
        currentRoundId = 1;
        currentRoundOpenTime = block.timestamp;
    }

    /// @notice One-time initialization: sets RoundManager permanently. Callable exactly once,
    ///         only by `deployer`. No path exists to call this again, by anyone -- not deployer,
    ///         not governance. Removes the CREATE-nonce address prediction previously needed to
    ///         resolve the circular EligibilityRegistry/RoundManager dependency: this contract is
    ///         now deployed first, RoundManager second (using this contract's real, already-known
    ///         address), and this setter wires the relationship back afterward.
    function setRoundManager(address roundManager_) external {
        require(msg.sender == deployer, "not deployer");
        require(roundManager == address(0), "already initialized");
        require(roundManager_ != address(0), "zero round manager");
        roundManager = roundManager_;
        emit RoundManagerInitialized(roundManager_);
    }

    function openRound(uint256 roundId, uint256 openTime) external onlyRoundManager {
        currentRoundId = roundId;
        currentRoundOpenTime = openTime;
        emit RoundOpened(roundId, openTime);
    }

    function registerToken(address market) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        require(tokenId <= MAX_TICKERS, "capacity exceeded");
        require(market != address(0), "zero market");
        tokenMarket[tokenId] = market;
        emit TokenRegistered(tokenId, market);
    }

    /// @notice Called by a token's market on every trade. Updates `aboveThresholdSince` and, if
    ///         the 30-minute bar is already met, qualifies the token for the CURRENTLY open
    ///         round's draw immediately. Never required for correctness of a token that keeps
    ///         trading normally -- see the contract-level accepted-caveat note for the one case it
    ///         doesn't cover.
    function onTrade(uint256 tokenId) external {
        _touch(tokenId);
    }

    /// @notice Permissionless explicit qualification check -- lets anyone (most naturally, a
    ///         token's own holders) force the check even if the token itself hasn't traded
    ///         recently. This is what closes the accepted caveat above in practice: a token that
    ///         has genuinely earned candidacy always has a trivial, one-transaction path for
    ///         anyone to lock it in before the round closes.
    function qualify(uint256 tokenId) external {
        require(tokenId >= 1 && tokenId < nextTokenId, "unknown token");
        _touch(tokenId);
    }

    function _touch(uint256 tokenId) internal {
        uint256 reserve = IRealReserve(tokenMarket[tokenId]).realReserve();
        bool nowAbove = reserve >= minReserveThreshold;

        if (nowAbove) {
            if (aboveThresholdSince[tokenId] == 0) {
                aboveThresholdSince[tokenId] = block.timestamp; // streak begins now
            }
            _maybeQualify(tokenId);
        } else {
            aboveThresholdSince[tokenId] = 0; // dipped below -- streak broken, must restart
        }
    }

    function _maybeQualify(uint256 tokenId) internal {
        if (candidateIndexPlusOne[currentRoundId][tokenId] != 0) return; // already qualified this round
        if (IRealReserve(tokenMarket[tokenId]).progressBps() < minProgressBps) return; // progress gate

        uint256 since = aboveThresholdSince[tokenId];
        if (since == 0) return;
        if (block.timestamp - since < requiredAbsoluteSeconds) return;

        uint256[] storage list = pendingCandidates[currentRoundId];
        list.push(tokenId);
        candidateIndexPlusOne[currentRoundId][tokenId] = list.length;
        emit Qualified(currentRoundId, tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Views for RoundManager / anyone
    // ─────────────────────────────────────────────────────────────────────────

    function candidateCount(uint256 roundId) external view returns (uint256) {
        return pendingCandidates[roundId].length;
    }

    function candidateAt(uint256 roundId, uint256 index) external view returns (uint256) {
        return pendingCandidates[roundId][index];
    }

    function isCandidate(uint256 roundId, uint256 tokenId) external view returns (bool) {
        return candidateIndexPlusOne[roundId][tokenId] != 0;
    }
}
