// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMemeTokenTWAB {
    function twabOf(address account, uint256 fromT, uint256 toT) external view returns (uint256);
    function totalSupplyTwab(uint256 fromT, uint256 toT) external view returns (uint256);
}

interface IHasToken {
    function token() external view returns (address);
}

/// @title RewardVault
/// @notice The protocol's WinnerPot: continuously accumulates ETH (from BondingCurveClog's trade
///         tax and CLOG revenue routing, via `_credit`/`withdraw` on THOSE contracts, or a direct
///         `receive()` here), and pays it out to a winning round's holders in exact proportion to
///         their TWAB during that round.
///
/// @dev Flow: Alice/Bob hold CAT during round N -> round N closes -> CAT's holder TWAB for round
///      N's window is now historical and immutable (see MemeToken) -> Chainlink/RoundManager
///      selects CAT as round N's winner -> `allocateRound` snapshots the CURRENT pool balance as
///      round N's jackpot and records the (market, tokenWindow) needed to compute shares ->
///      Alice/Bob call `claim`, each receiving `jackpot * theirTwab / circulatingTwab`, where
///      circulatingTwab EXCLUDES the market's own (unsold-inventory) balance -> any subsequent CAT
///      buy/sell/transfer creates checkpoints with LATER timestamps, which `twabOf` for round N's
///      OWN (already-fixed) window simply never looks at, so it cannot change what's already been
///      allocated or what remains claimable.
contract RewardVault is ReentrancyGuard {
    uint256 public constant CLAIM_WINDOW = 5 days;
    uint256 public constant BPS = 10_000;

    address public immutable roundManager;

    uint256 public unallocatedPool;

    struct RoundAllocation {
        uint256 winnerTokenId;
        address market;
        address token;
        uint256 windowOpen;
        uint256 windowClose;
        uint256 jackpotAmount;
        uint256 totalClaimed;
        uint256 allocatedAt;
        bool swept;
    }

    mapping(uint256 => RoundAllocation) public allocations;
    mapping(uint256 => mapping(address => bool)) public claimed;

    event Received(address indexed from, uint256 amount, uint256 newPoolBalance);
    event RoundAllocated(uint256 indexed roundId, uint256 indexed winnerTokenId, address market, uint256 jackpotAmount);
    event Claimed(uint256 indexed roundId, address indexed holder, uint256 amount);
    event Swept(uint256 indexed roundId, uint256 amount, uint256 newPoolBalance);

    modifier onlyRoundManager() {
        require(msg.sender == roundManager, "not round manager");
        _;
    }

    constructor(address roundManager_) {
        require(roundManager_ != address(0), "zero round manager");
        roundManager = roundManager_;
    }

    receive() external payable {
        unallocatedPool += msg.value;
        emit Received(msg.sender, msg.value, unallocatedPool);
    }

    /// @notice Called once by RoundManager the instant a round's winner is determined. Snapshots
    ///         the ENTIRE current pool as that round's jackpot -- everything accumulated since the
    ///         last allocation, whether this round drew a winner or not (rounds that were skipped
    ///         for having <MIN_DRAW_CANDIDATES never call this, so their contribution simply
    ///         stays in the pool and rolls forward naturally into whichever round next allocates).
    function allocateRound(
        uint256 roundId,
        uint256 winnerTokenId,
        address market,
        uint256 windowOpen,
        uint256 windowClose
    ) external onlyRoundManager {
        require(allocations[roundId].allocatedAt == 0, "already allocated");
        uint256 jackpot = unallocatedPool;
        unallocatedPool = 0;

        address tokenAddr = IHasToken(market).token();

        allocations[roundId] = RoundAllocation({
            winnerTokenId: winnerTokenId,
            market: market,
            token: tokenAddr,
            windowOpen: windowOpen,
            windowClose: windowClose,
            jackpotAmount: jackpot,
            totalClaimed: 0,
            allocatedAt: block.timestamp,
            swept: false
        });

        emit RoundAllocated(roundId, winnerTokenId, market, jackpot);
    }

    /// @notice Claims `holder`'s exact pro-rata share of round `roundId`'s jackpot. Callable by
    ///         ANYONE on behalf of `holder` (funds always go to `holder`, never the caller) --
    ///         same permissionless-trigger pattern used throughout this protocol.
    function claim(uint256 roundId, address holder) external nonReentrant {
        uint256 amount = _computeAndMarkClaim(roundId, holder);
        (bool ok,) = holder.call{value: amount}("");
        require(ok, "transfer failed");
        emit Claimed(roundId, holder, amount);
    }

    /// @notice Claims the same holder's share across several rounds in one transaction.
    function claimBatch(uint256[] calldata roundIds, address holder) external nonReentrant {
        uint256 total = 0;
        for (uint256 i = 0; i < roundIds.length; i++) {
            uint256 amount = _computeAndMarkClaim(roundIds[i], holder);
            total += amount;
            emit Claimed(roundIds[i], holder, amount);
        }
        if (total > 0) {
            (bool ok,) = holder.call{value: total}("");
            require(ok, "transfer failed");
        }
    }

    function _computeAndMarkClaim(uint256 roundId, address holder) internal returns (uint256 amount) {
        RoundAllocation storage a = allocations[roundId];
        require(a.allocatedAt != 0, "round not allocated");
        require(!a.swept, "round swept");
        require(block.timestamp <= a.allocatedAt + CLAIM_WINDOW, "claim window expired");
        require(!claimed[roundId][holder], "already claimed");
        require(holder != a.market, "protocol inventory cannot claim");

        claimed[roundId][holder] = true;

        uint256 holderTwab = IMemeTokenTWAB(a.token).twabOf(holder, a.windowOpen, a.windowClose);
        if (holderTwab == 0) return 0; // valid no-op: e.g. a holder who bought only after close

        uint256 circulatingTwab = _circulatingTwab(a);
        if (circulatingTwab == 0) return 0; // defensive; should not occur for a real winner

        amount = Math.mulDiv(a.jackpotAmount, holderTwab, circulatingTwab);
        a.totalClaimed += amount;
    }

    /// @dev P0 fix: circulatingTwab is the token's ACTUAL total-supply TWAB over the round's own
    ///      window (totalSupplyTwab - zero before the token's own launch, TOTAL_SUPPLY from launch
    ///      onward) minus the market's own (unsold-inventory) TWAB over that same window - NEVER
    ///      the bare, fixed TOTAL_SUPPLY constant. A token launched after a round's window has
    ///      already opened did not have its full 1B supply in existence for the pre-launch portion
    ///      of that window; using the fixed constant there silently inflates this denominator with
    ///      phantom supply that was never real, shrinking every genuine holder's payout below their
    ///      true pro-rata share (see test/RewardVault.t.sol's own "P0 regression" tests, which
    ///      reproduce and pin this exact failure mode before this fix).
    function _circulatingTwab(RoundAllocation storage a) internal view returns (uint256) {
        uint256 totalSupplyTwab = IMemeTokenTWAB(a.token).totalSupplyTwab(a.windowOpen, a.windowClose);
        uint256 marketTwab = IMemeTokenTWAB(a.token).twabOf(a.market, a.windowOpen, a.windowClose);
        return totalSupplyTwab > marketTwab ? totalSupplyTwab - marketTwab : 0;
    }

    /// @notice After the 5-day claim window, anyone may sweep whatever was never claimed (never-
    ///         claimed holders' shares AND integer-division dust from partial claims alike) back
    ///         into the live pool, where it rolls forward into whichever round next allocates.
    function sweepExpired(uint256 roundId) external {
        RoundAllocation storage a = allocations[roundId];
        require(a.allocatedAt != 0, "round not allocated");
        require(block.timestamp > a.allocatedAt + CLAIM_WINDOW, "claim window not yet expired");
        require(!a.swept, "already swept");
        a.swept = true;
        uint256 remaining = a.jackpotAmount - a.totalClaimed;
        if (remaining > 0) {
            unallocatedPool += remaining;
        }
        emit Swept(roundId, remaining, unallocatedPool);
    }

    /// @notice Read-only preview of what `holder` would receive from `roundId` -- does not mark
    ///         the claim. Useful for frontends and for tests.
    function previewClaim(uint256 roundId, address holder) external view returns (uint256) {
        RoundAllocation storage a = allocations[roundId];
        if (a.allocatedAt == 0 || a.swept || claimed[roundId][holder] || holder == a.market) return 0;
        uint256 holderTwab = IMemeTokenTWAB(a.token).twabOf(holder, a.windowOpen, a.windowClose);
        if (holderTwab == 0) return 0;
        uint256 circulatingTwab = _circulatingTwab(a);
        if (circulatingTwab == 0) return 0;
        return Math.mulDiv(a.jackpotAmount, holderTwab, circulatingTwab);
    }

    function getAllocation(uint256 roundId) external view returns (RoundAllocation memory) {
        return allocations[roundId];
    }
}
