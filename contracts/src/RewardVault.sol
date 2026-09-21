// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

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
/// @dev V4 CLAIM-NATIVE INTEGRATION (this pass): WinnerPot's own share of a v4 trade's tax/CLOG
///      extraction is no longer pushed here as real ETH via `receive()` - it is minted directly
///      as an ERC6909 native-ETH claim to THIS contract's own address inside the same
///      PoolManager.unlock() the trade itself runs in, and the CLOG hook synchronously calls
///      `recordWinnerPotClaim` in that same transaction to update `unallocatedPool` - so every
///      contribution generated before a later `allocateRound()` call is guaranteed to be
///      reflected in `unallocatedPool` by the time that later, separate transaction runs
///      (ordinary EVM transaction sequencing, not a best-effort flush a keeper could skip or
///      delay). Payouts (`claim`/`claimBatch`) transparently convert whatever ERC6909 claim this
///      contract holds back into real ETH just-in-time via its own `unlockCallback`, before the
///      existing real-ETH push logic runs unchanged - v2 markets' plain `receive()` pushes and
///      v4 markets' claim-native contributions land in the exact same `unallocatedPool` and are
///      paid out identically. `poolManager`/`clogHook` are optional (zero disables the v4 path
///      entirely, exactly preserving pre-v4 behavior) so existing v2-only deployments and tests
///      need no changes beyond passing address(0) for these two new constructor parameters.
contract RewardVault is ReentrancyGuard, IUnlockCallback {
    uint256 public constant CLAIM_WINDOW = 5 days;
    uint256 public constant BPS = 10_000;

    address public immutable roundManager;
    IPoolManager public immutable poolManager; // address(0) if this deployment never wires up a v4 market
    address public immutable clogHook; // the only caller authorized to call recordWinnerPotClaim

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
    event WinnerPotClaimRecorded(uint256 amount, uint256 newPoolBalance);
    event ClaimSweptToRealEth(uint256 amount);
    event RoundAllocated(uint256 indexed roundId, uint256 indexed winnerTokenId, address market, uint256 jackpotAmount);
    event Claimed(uint256 indexed roundId, address indexed holder, uint256 amount);
    event Swept(uint256 indexed roundId, uint256 amount, uint256 newPoolBalance);

    modifier onlyRoundManager() {
        require(msg.sender == roundManager, "not round manager");
        _;
    }

    constructor(address roundManager_, address poolManager_, address clogHook_) {
        require(roundManager_ != address(0), "zero round manager");
        require((poolManager_ == address(0)) == (clogHook_ == address(0)), "poolManager and clogHook must be set together or not at all");
        roundManager = roundManager_;
        poolManager = IPoolManager(poolManager_);
        clogHook = clogHook_;
    }

    /// @dev CRITICAL, caught by this pass's own integration testing (WinnerPotRouting.t.sol):
    ///      PoolManager.take()'s own native-ETH transfer (used by _ensureRealEthAvailable and
    ///      sweepClaimToRealETH to convert this contract's ERC6909 claim back into real ETH) is
    ///      a plain, no-calldata ETH send, which triggers this SAME receive() function. Without
    ///      this guard, converting a claim into real ETH would double-count it into
    ///      unallocatedPool - once when the claim was originally minted and recordWinnerPotClaim
    ///      was called, and AGAIN here when that same value later arrives as real ETH from
    ///      take(). ETH arriving from PoolManager itself is therefore never treated as a new
    ///      contribution; only genuine external pushes (the legacy v2 BondingCurveClog path) are.
    receive() external payable {
        if (msg.sender == address(poolManager)) return;
        unallocatedPool += msg.value;
        emit Received(msg.sender, msg.value, unallocatedPool);
    }

    /// @notice Authenticated, synchronous accounting update for a v4 trade's WinnerPot share -
    ///         called by the CLOG hook in the SAME transaction it mints this contract's own
    ///         ERC6909 ETH claim, so `unallocatedPool` reflects the contribution before that
    ///         transaction ends, with no separate "flush" step a keeper could skip, delay, or
    ///         race against a later `allocateRound()` call.
    function recordWinnerPotClaim(uint256 amount) external {
        require(msg.sender == clogHook && clogHook != address(0), "not authorized");
        if (amount == 0) return;
        unallocatedPool += amount;
        emit WinnerPotClaimRecorded(amount, unallocatedPool);
    }

    /// @dev Converts up to `needed` of this contract's own ERC6909 native-ETH claim (held in
    ///      PoolManager) into real ETH, only if the real balance on hand is currently
    ///      insufficient - a no-op for v2-only deployments (poolManager == address(0)) and a
    ///      no-op whenever this contract already holds enough real ETH directly, so ordinary
    ///      v2-funded claims never pay the extra unlock() gas cost.
    function _ensureRealEthAvailable(uint256 needed) internal {
        if (address(poolManager) == address(0)) return;
        if (address(this).balance >= needed) return;
        uint256 claimBalance = poolManager.balanceOf(address(this), 0);
        if (claimBalance == 0) return;
        poolManager.unlock(abi.encode(claimBalance));
    }

    /// @notice Permissionless: converts this contract's ENTIRE currently-held ERC6909
    ///         native-ETH claim into real ETH up front, ahead of any specific claim needing it -
    ///         purely a convenience/gas-timing tool; claim()/claimBatch() already do this
    ///         automatically, just-in-time, on their own.
    function sweepClaimToRealETH() external {
        require(address(poolManager) != address(0), "v4 not wired for this deployment");
        uint256 claimBalance = poolManager.balanceOf(address(this), 0);
        require(claimBalance > 0, "nothing to sweep");
        poolManager.unlock(abi.encode(claimBalance));
    }

    /// @notice IUnlockCallback - exclusively reached via _ensureRealEthAvailable/
    ///         sweepClaimToRealETH above. Burns exactly `amount` of this contract's OWN ERC6909
    ///         native-ETH claim and takes the same amount out as real ETH, to itself - burn
    ///         (+amount delta) and take (-amount delta) cancel exactly, leaving a net-zero delta
    ///         with no separate sync/settle step needed (verified directly against v4-core's own
    ///         PoolManager.burn/take source - see ClogV4Hook.sol's own withdrawal path, which
    ///         uses the identical pattern).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        emit ClaimSweptToRealEth(amount);
        return "";
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
        _ensureRealEthAvailable(amount);
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
            _ensureRealEthAvailable(total);
            (bool ok,) = holder.call{value: total}("");
            require(ok, "transfer failed");
        }
    }

    /// @dev The address whose own TWAB represents unsold protocol inventory for this round's
    ///      token - excluded from circulatingTwab and from claiming. In legacy v2 mode
    ///      (poolManager == address(0)) this is the market itself, exactly as before: a
    ///      BondingCurveClog physically holds its own unsold supply. In v4 mode, the market is
    ///      fully non-custodial and holds none of the physical supply at all - PoolManager does,
    ///      via the ERC6909 claims minted to each per-ticker ClogMarket - so the inventory holder
    ///      is PoolManager itself, never the market. `a.market` is UNCHANGED either way and must
    ///      remain the per-ticker ClogMarket: RewardVault still needs IHasToken(a.market).token()
    ///      to resolve which MemeToken this round's TWAB queries even run against.
    function _inventoryHolder(RoundAllocation storage a) internal view returns (address) {
        return address(poolManager) != address(0) ? address(poolManager) : a.market;
    }

    function _computeAndMarkClaim(uint256 roundId, address holder) internal returns (uint256 amount) {
        RoundAllocation storage a = allocations[roundId];
        require(a.allocatedAt != 0, "round not allocated");
        require(!a.swept, "round swept");
        require(block.timestamp <= a.allocatedAt + CLAIM_WINDOW, "claim window expired");
        require(!claimed[roundId][holder], "already claimed");
        require(holder != a.market, "protocol inventory cannot claim");
        require(holder != _inventoryHolder(a), "protocol inventory cannot claim");

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
    ///      onward) minus the PROTOCOL INVENTORY HOLDER's own TWAB over that same window - NEVER
    ///      the bare, fixed TOTAL_SUPPLY constant, and never unconditionally the market (see
    ///      _inventoryHolder's own docs: in v4 mode the physical inventory sits at PoolManager,
    ///      not the market). A token launched after a round's window has already opened did not
    ///      have its full 1B supply in existence for the pre-launch portion of that window; using
    ///      the fixed constant there silently inflates this denominator with phantom supply that
    ///      was never real, shrinking every genuine holder's payout below their true pro-rata
    ///      share (see test/RewardVault.t.sol's own "P0 regression" tests, which reproduce and
    ///      pin this exact failure mode before this fix).
    function _circulatingTwab(RoundAllocation storage a) internal view returns (uint256) {
        uint256 totalSupplyTwab = IMemeTokenTWAB(a.token).totalSupplyTwab(a.windowOpen, a.windowClose);
        uint256 inventoryTwab = IMemeTokenTWAB(a.token).twabOf(_inventoryHolder(a), a.windowOpen, a.windowClose);
        return totalSupplyTwab > inventoryTwab ? totalSupplyTwab - inventoryTwab : 0;
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
        if (a.allocatedAt == 0 || a.swept || claimed[roundId][holder] || holder == a.market || holder == _inventoryHolder(a)) return 0;
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
