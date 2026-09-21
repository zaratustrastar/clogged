// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ClogMarket (vertical-slice version, corrected)
/// @notice Non-custodial per-ticker economic state engine - the intended descendant of
///         BondingCurveClog.sol, refactored to hold ZERO custody of ETH/tokens itself. All
///         actual value movement happens through PoolManager's flash accounting (ERC6909
///         claims this contract owns), driven by the universal ClogV4Hook calling into this
///         contract's pure state-transition functions from inside beforeSwap.
///
/// @dev DELIBERATELY MINIMAL - this is the first proof that the custody/claim mechanism
///      itself works end-to-end against the real PoolManager, isolated from the full
///      production economics (buy/sell tax split, the separate 100M CLOG-reserve/release/
///      extraction leg, ticker-owner-fee-via-NFT-ownership, the sell-side solvency CAP at
///      realETH/wasCapped) - none of which are ported yet. This gap is explicit and
///      acknowledged, not an oversight - see the conversation this was built in for the full
///      remaining scope.
///
/// @dev CRITICAL, corrected this pass: virtualTokenSeed (`rt`'s starting value, 1.8B under
///      Config G) is a PRICING construct only - Math.mulDiv(CURVE_ALLOCATION, bufferMultiplierBps,
///      BPS) in the real BondingCurveClog.sol, deliberately "deeper" than the real token count
///      so the curve behaves correctly. It is NEVER how many real MemeTokens physically exist -
///      that is MemeToken.TOTAL_SUPPLY, exactly 1B (900M curve + 100M CLOG allocation),
///      confirmed directly against the real production source. `physicalInventory` here tracks
///      that separate, real 1B constraint - mirroring the real contract's own
///      `token.balanceOf(address(this)) >= totalTokensOut` safety check (that check compares
///      against actual custody; this market has none, so it tracks the equivalent quantity
///      directly as state instead, backed 1:1 by the market's own real ERC6909 token claim).
contract ClogMarket {
    address public immutable hook; // the universal ClogV4Hook - the only caller allowed to trigger state transitions
    address public immutable token; // this ticker's MemeToken

    uint256 public re; // ETH-side reserve (virtual + real, undifferentiated in this slice)
    uint256 public rt; // token-side PRICING reserve (virtual - starts far above physical supply, by design)
    uint256 public k; // re * rt, re-anchored after every trade
    uint256 public sold;

    /// @notice Real MemeToken units still available to deliver - starts at MemeToken.TOTAL_SUPPLY
    ///         (1B), NEVER at virtualTokenSeed. Decrements on every buy's tokensOut, increments
    ///         on every sell's tokensIn. This is the vertical slice's stand-in for the real
    ///         contract's own token.balanceOf(address(this)) check - see contract-level docs.
    uint256 public physicalInventory;

    event Bought(uint256 grossInput, uint256 tokensOut, uint256 newRe, uint256 newRt);
    event Sold(uint256 tokensIn, uint256 ethOut, uint256 newRe, uint256 newRt);

    modifier onlyHook() {
        require(msg.sender == hook, "not hook");
        _;
    }

    constructor(address hook_, address token_, uint256 virtualEthSeed, uint256 virtualTokenSeed, uint256 physicalTokenSupply) {
        require(hook_ != address(0) && token_ != address(0), "zero address");
        require(virtualEthSeed > 0 && virtualTokenSeed > 0, "zero seed");
        require(physicalTokenSupply > 0, "zero physical supply");
        require(physicalTokenSupply <= virtualTokenSeed, "physical supply must never exceed the virtual pricing reserve");
        hook = hook_;
        token = token_;
        re = virtualEthSeed;
        rt = virtualTokenSeed;
        k = re * rt;
        physicalInventory = physicalTokenSupply;
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
        // The exact safety property this vertical slice must preserve from production: the
        // virtual curve can imply more tokens than physically exist for a large enough input,
        // but a buy must never promise tokens that aren't actually available - it reverts
        // cleanly rather than under-delivering or lying about the market's own inventory.
        require(tokensOut <= physicalInventory, "exceeds available token inventory");

        re += grossInput;
        rt = newRt;
        sold += tokensOut;
        physicalInventory -= tokensOut;
        k = re * rt; // re-anchor: k must always reflect the CURRENT, honest (re, rt) exactly,
            // matching production's own re-anchor after every state transition - otherwise
            // integer-division rounding in `newRt` above would let k silently drift over time.

        emit Bought(grossInput, tokensOut, re, rt);
    }

    /// @notice Pure state transition for a sell - symmetric to applyBuy. Returns the full
    ///         gross ETH payout (no tax deducted, no solvency cap at realETH in this slice -
    ///         see contract-level docs) the hook must account for by burning that much of this
    ///         contract's own ETH claim.
    function applySell(uint256 tokensIn) external onlyHook returns (uint256 ethOut) {
        require(tokensIn > 0, "zero input");
        uint256 newRe = k / (rt + tokensIn);
        ethOut = re - newRe;
        require(ethOut > 0, "zero output");
        require(ethOut <= re, "exceeds reserve");

        re = newRe;
        rt += tokensIn;
        sold = sold > tokensIn ? sold - tokensIn : 0; // matches production exactly: sold tracks
            // net circulating curve-leg supply, so a sell must reverse a buy's own increment.
        physicalInventory += tokensIn; // the tokens sold back in are real inventory again
        k = re * rt; // re-anchor - same reasoning as applyBuy above.

        emit Sold(tokensIn, ethOut, re, rt);
    }
}
