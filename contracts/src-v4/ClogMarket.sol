// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title ClogMarket (vertical-slice version, now with full trading-tax economics)
/// @notice Non-custodial per-ticker economic state engine - the intended descendant of
///         BondingCurveClog.sol, refactored to hold ZERO custody of ETH/tokens itself. All
///         actual value movement happens through PoolManager's flash accounting (ERC6909
///         claims this contract owns), driven by the universal ClogV4Hook calling into this
///         contract's pure state-transition functions from inside beforeSwap.
///
/// @dev STILL DELIBERATELY DEFERRED, explicitly (not an oversight): the separate 100M
///      CLOG-reserve/release/extraction leg (RELEASE_RATIO_BPS, targetExtractionBps,
///      safetyFloorBps, the iterative curve/CLOG budget split); ticker-owner-fee via live
///      TickerNFT.ownerOf() lookup (this slice uses a fixed immutable address instead); the
///      actual WinnerPot-share ETH routing mechanism (mint-to-RewardVault + recordWinnerPotClaim -
///      this contract computes and tracks the WinnerPot share as its own liability bucket for
///      now, exactly like owner/multisig, pending that separate integration piece).
///
/// @dev NOW PORTED, this pass, verified against the exact production BondingCurveClog.sol
///      source before implementing: the full 0.6% buy/sell trading tax, split 40% ticker-owner
///      / 10% multisig / 50% WinnerPot; the pull-payment pendingWithdrawals ledger for
///      owner/multisig (_credit's exact semantics); realETH tracked SEPARATELY from the
///      virtual pricing reserve (re = virtualEthSeed + realETH, always) - required correctly
///      to support the sell-side solvency cap below; the sell-side solvency cap itself
///      (grossPayout capped at realETH, `wasCapped` returned, matching production's own
///      "never pay out more than what is actually held" guard exactly); k re-anchoring and the
///      sold counter (both already ported in the prior pass) remain correct under the new tax
///      math, verified by this pass's own tests.
contract ClogMarket {
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 60; // 0.6%
    uint256 public constant SELL_TAX_BPS = 60; // 0.6%
    uint256 public constant TICKER_OWNER_TAX_BPS = 4_000; // 40% of the tax
    uint256 public constant MULTISIG_TAX_BPS = 1_000; // 10% of the tax
    // WinnerPot gets the remainder (BPS - TICKER_OWNER_TAX_BPS - MULTISIG_TAX_BPS = 50%),
    // computed as a residual exactly like production's own _routeTax - never re-derived from
    // its own separate BPS constant, so the three shares can never fail to sum to the tax
    // exactly regardless of rounding.

    address public immutable hook; // the universal ClogV4Hook - the only caller allowed to trigger state transitions
    address public immutable token; // this ticker's MemeToken
    address public immutable tickerOwner; // fixed for this slice - live TickerNFT.ownerOf() lookup is a deferred, separate piece (see contract-level docs)
    address public immutable multisig;

    uint256 public re; // virtualEthSeed + realETH, always - drives curve pricing
    uint256 public rt; // token-side PRICING reserve (virtual - starts far above physical supply, by design)
    uint256 public k; // re * rt, re-anchored after every trade
    uint256 public sold;
    uint256 public immutable virtualEthSeed;
    uint256 public realETH; // the REAL portion of re - never includes the virtual seed. This is
        // what actually backs withdrawals/payouts and what the sell-side solvency cap bounds
        // against, matching production's own realETH exactly.

    uint256 public physicalInventory; // see prior pass's own docs - real MemeToken units still available to deliver

    mapping(address => uint256) public pendingWithdrawals; // pull-payment ledger, mirroring production's own _credit/withdraw exactly

    /// @notice WinnerPot's own accumulated share of tax - tracked explicitly, separately from
    ///         pendingWithdrawals, because it is money owed to RewardVault, not a direct
    ///         withdrawer. This keeps this market's own ETH claim invariant fully accounted for
    ///         even before the real WinnerPot-direct-routing mechanism (mint-to-RewardVault +
    ///         recordWinnerPotClaim) exists: market's ETH claim == realETH +
    ///         pendingWithdrawals[owner] + pendingWithdrawals[multisig] + winnerPotLiability,
    ///         always, exactly - never an untracked "extra" balance sitting on the claim with
    ///         no corresponding state anywhere. See contract-level docs for what's still deferred.
    uint256 public winnerPotLiability;

    event Bought(uint256 grossInput, uint256 tax, uint256 tokensOut, uint256 newRe, uint256 newRt);
    event Sold(uint256 tokensIn, uint256 grossPayout, uint256 tax, uint256 netEthOut, bool wasCapped, uint256 newRe, uint256 newRt);
    event Credited(address indexed to, uint256 amount, uint256 newPending);

    modifier onlyHook() {
        require(msg.sender == hook, "not hook");
        _;
    }

    constructor(
        address hook_,
        address token_,
        address tickerOwner_,
        address multisig_,
        uint256 virtualEthSeed_,
        uint256 virtualTokenSeed,
        uint256 physicalTokenSupply
    ) {
        require(hook_ != address(0) && token_ != address(0) && tickerOwner_ != address(0) && multisig_ != address(0), "zero address");
        require(virtualEthSeed_ > 0 && virtualTokenSeed > 0, "zero seed");
        require(physicalTokenSupply > 0, "zero physical supply");
        require(physicalTokenSupply <= virtualTokenSeed, "physical supply must never exceed the virtual pricing reserve");
        hook = hook_;
        token = token_;
        tickerOwner = tickerOwner_;
        multisig = multisig_;
        virtualEthSeed = virtualEthSeed_;
        re = virtualEthSeed_;
        rt = virtualTokenSeed;
        k = re * rt;
        physicalInventory = physicalTokenSupply;
    }

    /// @notice Full-tax-aware buy. Called by the hook mid-beforeSwap with the FULL exact
    ///         input (grossInput) - the hook mints a claim for this same full amount, per the
    ///         conservation proof from this branch's own design discussion (every wei of
    ///         grossInput must appear exactly once across realETH + ownerLiability +
    ///         multisigLiability + winnerPotLiability).
    function applyBuy(uint256 grossInput) external onlyHook returns (uint256 tokensOut, uint256 winnerPotShare) {
        require(grossInput > 0, "zero input");

        uint256 tax = Math.mulDiv(grossInput, BUY_TAX_BPS, BPS);
        uint256 budget = grossInput - tax;

        uint256 ownerShare = Math.mulDiv(tax, TICKER_OWNER_TAX_BPS, BPS);
        uint256 multisigShare = Math.mulDiv(tax, MULTISIG_TAX_BPS, BPS);
        winnerPotShare = tax - ownerShare - multisigShare; // residual - see contract-level docs

        uint256 newRt = k / (re + budget);
        tokensOut = rt - newRt;
        require(tokensOut > 0, "zero output");
        require(tokensOut <= physicalInventory, "exceeds available token inventory");

        re += budget;
        realETH += budget;
        rt = newRt;
        sold += tokensOut;
        physicalInventory -= tokensOut;
        k = re * rt; // re-anchor - see prior pass's own docs

        _credit(tickerOwner, ownerShare);
        _credit(multisig, multisigShare);
        // winnerPotShare is tracked in its own accumulator (winnerPotLiability), not
        // pendingWithdrawals - see the state variable's own docs for why. The hook still mints
        // this same amount into the market's overall ETH claim; this accumulator is what keeps
        // that claim's own composition fully, explicitly accounted for in the meantime.
        winnerPotLiability += winnerPotShare;

        emit Bought(grossInput, tax, tokensOut, re, rt);
    }

    /// @notice Full-tax-aware, solvency-capped sell. Returns netEthOut (what the hook must
    ///         account for by burning that much of this contract's own ETH claim - burning
    ///         only netEthOut, never grossPayout, keeps
    ///         hook claim == realETH + ownerLiability + multisigLiability + winnerPotLiability
    ///         exactly balanced, per the conservation proof already established: the reserve's
    ///         decrease by grossPayout is exactly offset by the liability increase of tax).
    function applySell(uint256 tokensIn) external onlyHook returns (uint256 netEthOut, uint256 winnerPotShare, bool wasCapped) {
        require(tokensIn > 0, "zero input");

        uint256 newRt = rt + tokensIn;
        uint256 idealNewRe = k / newRt;
        uint256 idealPayout = re - idealNewRe;

        uint256 grossPayout;
        if (idealPayout > realETH) {
            // THE solvency guard, verified against production exactly: never pay out more
            // than what is actually, really held - the virtual seed is never spendable.
            grossPayout = realETH;
            wasCapped = true;
        } else {
            grossPayout = idealPayout;
        }
        require(grossPayout > 0, "zero output");

        uint256 newRe = re - grossPayout;
        realETH -= grossPayout;
        re = newRe;
        rt = newRt;
        k = re * rt; // re-anchor: if capping occurred, k now reflects the ACTUAL (re, rt), not
            // the uncapped formula's implied state - matching production's own comment exactly.
        sold = sold > tokensIn ? sold - tokensIn : 0;
        physicalInventory += tokensIn;

        uint256 tax = Math.mulDiv(grossPayout, SELL_TAX_BPS, BPS);
        netEthOut = grossPayout - tax;

        uint256 ownerShare = Math.mulDiv(tax, TICKER_OWNER_TAX_BPS, BPS);
        uint256 multisigShare = Math.mulDiv(tax, MULTISIG_TAX_BPS, BPS);
        winnerPotShare = tax - ownerShare - multisigShare;

        _credit(tickerOwner, ownerShare);
        _credit(multisig, multisigShare);
        winnerPotLiability += winnerPotShare;

        emit Sold(tokensIn, grossPayout, tax, netEthOut, wasCapped, re, rt);
    }

    /// @dev Pull-payment credit - mirrors production's own _credit exactly: no external call
    ///      happens here at all, so this can never be a reentrancy surface and can never let a
    ///      broken/malicious recipient block anyone else's trade.
    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        pendingWithdrawals[to] += amount;
        emit Credited(to, amount, pendingWithdrawals[to]);
    }
}
