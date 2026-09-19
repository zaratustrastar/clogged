// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MemeToken
/// @notice Fixed-supply (1,000,000,000e18) ERC20 for a single launched meme, with built-in
///         TWAB (time-weighted average balance) tracking for casino reward eligibility.
/// @dev The ENTIRE supply is minted to `market` (the BondingCurveClog instance) the moment
///      `setMarket` is called -- not at construction, see the deployment note below.
///      900,000,000e18 is conceptually "curve inventory" and 100,000,000e18 is conceptually
///      "CLOG inventory" -- both actually just sit as one balance on `market`; the split is
///      tracked in BondingCurveClog's own accounting (rt / clogRemaining), not by this token.
///      No further minting is possible after that: there is no other mint() path anywhere.
///
/// @dev TWAB DESIGN: every account gets its own append-only checkpoint history of
///      (timestamp, cumulativeBalanceSeconds, balanceAfterThisPoint), written on every mint,
///      burn, or transfer via OZ's single `_update` hook. Between checkpoints, balance is
///      piecewise-constant (an ERC20 balance cannot change without a transaction), so
///      `cumulativeAt(T)` for any T is computable in O(log n) via binary search over that
///      account's own checkpoints, and is PROVABLY unaffected by any checkpoint written after T --
///      the same property proven for the (now-removed) TimeProjectedFenwick tree, here applied
///      per-account instead of per-token-candidate. This is what makes "Round N's holder TWAB is
///      historical and immutable the instant Round N closes" true regardless of what anyone buys,
///      sells, or transfers afterward: a later checkpoint's timestamp is later, full stop, and
///      every query here only ever looks at the last checkpoint AT OR BEFORE the requested time.
/// @dev DEPLOYMENT: MemeToken and BondingCurveClog each need to reference the other's address,
///      which naively creates a circular deployment dependency (solved elsewhere in this codebase
///      via CREATE-nonce address prediction -- fragile in practice, especially with larger
///      contracts and internal Foundry deployment mechanics that don't always consume nonces the
///      way plain `CREATE` arithmetic predicts). Solved here instead with a tiny one-time
///      initialization step: MemeToken is deployed first with ZERO supply and no market; the real,
///      already-known BondingCurveClog address is then set exactly once via `setMarket`, which is
///      also when the entire fixed supply is minted. No nonce arithmetic, no CREATE2, no
///      prediction -- just an explicit, narrowly-scoped setter, permanently locked after first use.
///      This is emphatically NOT an upgradeability/proxy pattern: there is no way to call
///      `setMarket` a second time, by anyone, ever, including governance.
contract MemeToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice The address authorized to call `setMarket` -- exactly once. In production this is
    ///         TickerRegistry (the launch orchestrator); in tests, whichever contract deploys this
    ///         token directly. Immutable, set at construction, never reassignable.
    address public immutable launcher;

    /// @notice The bonding-curve market this token belongs to. address(0) until `setMarket` is
    ///         called; permanently fixed forever after.
    address public market;

    /// @notice block.timestamp of `setMarket` - the instant the token's entire fixed supply was
    ///         minted into existence. 0 until then, permanently fixed after. Because this token
    ///         has exactly one mint event and no subsequent mint/burn path anywhere, this single
    ///         timestamp is sufficient to reconstruct the token's ACTUAL total-supply TWAB over
    ///         any window via `totalSupplyTwab` below: zero before this moment (the token simply
    ///         did not exist yet), TOTAL_SUPPLY at and after it.
    uint256 public marketInitializedAt;

    event MarketInitialized(address indexed market);

    struct Checkpoint {
        uint256 timestamp;
        uint256 cumulative; // integral of balance over time, in balance-seconds, up to `timestamp`
        uint256 balance; // account's balance from `timestamp` onward, until the next checkpoint
    }

    mapping(address => Checkpoint[]) private _checkpoints;

    constructor(string memory name_, string memory symbol_, address launcher_) ERC20(name_, symbol_) {
        require(launcher_ != address(0), "MemeToken: zero launcher");
        launcher = launcher_;
    }

    /// @notice One-time initialization: mints the entire fixed supply to `market_` and permanently
    ///         locks it as this token's market. Callable exactly once, only by `launcher`. There is
    ///         no path to call this again -- not by launcher, not by governance, not by anyone --
    ///         and no separate mint() function exists anywhere in this contract.
    function setMarket(address market_) external {
        require(msg.sender == launcher, "MemeToken: not launcher");
        require(market == address(0), "MemeToken: already initialized");
        require(market_ != address(0), "MemeToken: zero market");
        market = market_;
        marketInitializedAt = block.timestamp;
        _mint(market_, TOTAL_SUPPLY);
        emit MarketInitialized(market_);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        uint256 t = block.timestamp;
        if (from != address(0)) _writeCheckpoint(from, t, balanceOf(from));
        if (to != address(0)) _writeCheckpoint(to, t, balanceOf(to));
    }

    function _writeCheckpoint(address account, uint256 t, uint256 newBalance) internal {
        Checkpoint[] storage cps = _checkpoints[account];
        uint256 n = cps.length;

        if (n > 0 && cps[n - 1].timestamp == t) {
            // Multiple balance changes for this account in the same block/tx (e.g. two transfers
            // in one transaction) -- overwrite rather than push a second same-timestamp entry, so
            // binary search over the array never has to disambiguate ties.
            cps[n - 1].balance = newBalance;
            return;
        }

        uint256 prevCumulative = 0;
        uint256 prevBalance = 0;
        uint256 prevTime = t;
        if (n > 0) {
            Checkpoint storage last = cps[n - 1];
            prevCumulative = last.cumulative;
            prevBalance = last.balance;
            prevTime = last.timestamp;
        }
        uint256 elapsed = t > prevTime ? t - prevTime : 0;
        uint256 newCumulative = prevCumulative + prevBalance * elapsed;
        cps.push(Checkpoint({timestamp: t, cumulative: newCumulative, balance: newBalance}));
    }

    /// @notice The time-integral of `account`'s balance, in balance-seconds, up to and including
    ///         time `T`. 0 if the account never held a balance at or before `T`.
    function cumulativeAt(address account, uint256 T) public view returns (uint256) {
        Checkpoint[] storage cps = _checkpoints[account];
        uint256 idx = _upperBound(cps, T);
        if (idx == 0) return 0;
        Checkpoint storage cp = cps[idx - 1];
        uint256 elapsed = T > cp.timestamp ? T - cp.timestamp : 0;
        return cp.cumulative + cp.balance * elapsed;
    }

    /// @notice Time-weighted average balance of `account` over [fromT, toT]. This is what
    ///         RewardVault uses (per winning-round window) to determine each holder's exact
    ///         pro-rata jackpot share -- computed here, on the token itself, using only
    ///         checkpoints that existed at the time; nothing that happens after `toT` can change
    ///         the result of a query with that `toT`, no matter when the query itself is run.
    function twabOf(address account, uint256 fromT, uint256 toT) external view returns (uint256) {
        require(toT >= fromT, "MemeToken: bad window");
        if (toT == fromT) return balanceOf(account);
        return (cumulativeAt(account, toT) - cumulativeAt(account, fromT)) / (toT - fromT);
    }

    /// @notice The time-weighted average of this token's ACTUAL total supply over [fromT, toT] -
    ///         NOT the bare TOTAL_SUPPLY constant. Zero before `marketInitializedAt` (the token
    ///         did not exist yet - a round window that opened before this token launched must not
    ///         count that pre-launch time as though 1B tokens already existed), TOTAL_SUPPLY once
    ///         the window is entirely at or after `marketInitializedAt`. For a window straddling
    ///         the launch moment, this is the correct linear blend: zero for the pre-launch
    ///         portion, TOTAL_SUPPLY for the rest, averaged over the whole window - exactly the
    ///         same step-function TWAB math `twabOf` already applies per-account, applied here to
    ///         the token's own total supply (which is itself just as valid a "balance" as any
    ///         account's: zero, then a single step up to TOTAL_SUPPLY, then constant forever,
    ///         since no further mint/burn path exists anywhere in this contract).
    ///
    ///         This is what RewardVault._circulatingTwab must subtract a holder's/the market's own
    ///         twabOf from - using the bare TOTAL_SUPPLY constant instead silently inflates the
    ///         denominator with phantom pre-launch supply for any round whose window opened before
    ///         this specific token launched, shrinking every real holder's payout below their true
    ///         pro-rata share.
    function totalSupplyTwab(uint256 fromT, uint256 toT) external view returns (uint256) {
        require(toT >= fromT, "MemeToken: bad window");
        bool existsThroughout = market != address(0) && marketInitializedAt <= fromT;
        if (toT == fromT) return existsThroughout ? TOTAL_SUPPLY : 0;
        if (market == address(0) || toT <= marketInitializedAt) return 0;
        uint256 supplyStart = fromT > marketInitializedAt ? fromT : marketInitializedAt;
        uint256 activeSeconds = toT - supplyStart;
        return (TOTAL_SUPPLY * activeSeconds) / (toT - fromT);
    }

    function checkpointCount(address account) external view returns (uint256) {
        return _checkpoints[account].length;
    }

    function _upperBound(Checkpoint[] storage cps, uint256 T) internal view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = cps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].timestamp <= T) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
}
