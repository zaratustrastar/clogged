// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ClogMarket (first vertical-slice version)
/// @notice Non-custodial per-ticker economic state engine - the intended descendant of
///         BondingCurveClog.sol, refactored to hold ZERO custody of ETH/tokens itself. All
///         actual value movement happens through PoolManager's flash accounting (ERC6909
///         claims this contract owns), driven by the universal ClogV4Hook calling into this
///         contract's pure state-transition functions from inside beforeSwap.
///
/// @dev DELIBERATELY MINIMAL - this is the first proof that the custody/claim mechanism
///      itself works end-to-end against the real PoolManager, isolated from the full
///      production economics (buy/sell tax split, the 100M CLOG-reserve/release/extraction
///      leg, ticker-owner-fee-via-NFT-ownership) - none of which are ported yet. Curve math
///      (constant product, re*rt=k) is the same shape as BondingCurveClog's own curve leg.
///      This gap is explicit and acknowledged, not an oversight - see the conversation this
///      was built in for the full remaining scope.
contract ClogMarket {
    address public immutable hook; // the universal ClogV4Hook - the only caller allowed to trigger state transitions
    address public immutable token; // this ticker's MemeToken (informational in this slice; no ERC20 calls happen here)

    uint256 public re; // ETH-side reserve (virtual + real, undifferentiated in this slice)
    uint256 public rt; // token-side reserve
    uint256 public k; // re * rt, re-anchored after every trade
    uint256 public sold;

    event Bought(uint256 grossInput, uint256 tokensOut, uint256 newRe, uint256 newRt);
    event Sold(uint256 tokensIn, uint256 ethOut, uint256 newRe, uint256 newRt);

    modifier onlyHook() {
        require(msg.sender == hook, "not hook");
        _;
    }

    constructor(address hook_, address token_, uint256 virtualEthSeed, uint256 virtualTokenSeed) {
        require(hook_ != address(0) && token_ != address(0), "zero address");
        require(virtualEthSeed > 0 && virtualTokenSeed > 0, "zero seed");
        hook = hook_;
        token = token_;
        re = virtualEthSeed;
        rt = virtualTokenSeed;
        k = re * rt;
    }

    /// @notice Pure state transition for a buy - no ETH/token ever moves through this
    ///         function or this contract at all. Called by the hook mid-beforeSwap; the
    ///         FULL gross input (no tax deducted in this slice - see contract-level docs)
    ///         is what the hook must account for via a claim it mints to this contract.
    function applyBuy(uint256 grossInput) external onlyHook returns (uint256 tokensOut) {
        require(grossInput > 0, "zero input");
        uint256 newRt = k / (re + grossInput);
        tokensOut = rt - newRt;
        require(tokensOut > 0, "zero output");

        re += grossInput;
        rt = newRt;
        sold += tokensOut;

        emit Bought(grossInput, tokensOut, re, rt);
    }

    /// @notice Pure state transition for a sell - symmetric to applyBuy. Returns the full
    ///         gross ETH payout (no tax deducted in this slice) the hook must account for by
    ///         burning that much of this contract's own ETH claim.
    function applySell(uint256 tokensIn) external onlyHook returns (uint256 ethOut) {
        require(tokensIn > 0, "zero input");
        uint256 newRe = k / (rt + tokensIn);
        ethOut = re - newRe;
        require(ethOut > 0, "zero output");
        require(ethOut <= re, "exceeds reserve");

        re = newRe;
        rt += tokensIn;

        emit Sold(tokensIn, ethOut, re, rt);
    }
}
