// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IWithdrawalExecutorG {
    function executeWithdrawal(address to, uint256 amount) external;
}

interface IEligibilityG {
    function onTrade(uint256 tokenId) external;
}

interface IERC20LikeM {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC6909ClaimsG {
    function approve(address spender, uint256 id, uint256 amount) external returns (bool);
}

/// @title ClogGenuineMarket (Option B — v4-native execution)
/// @notice Every CLOG RULE is preserved verbatim from `ClogMarket.sol @ 422a61a`: the 1B/900M/100M
///         split, 0.6% buy and sell tax, 40/10/50 tax split, 10/90 extracted-CLOG split,
///         RELEASE_RATIO_BPS = 1111, HWM semantics, extraction target 40% / safety floor 50%,
///         dynamic TickerNFT owner, WinnerPot routing, pull-payment withdrawals and physical
///         solvency.
///
///   WHAT CHANGED, AND ONLY THIS: the rules now operate on the amounts a GENUINE Uniswap v4 swap
///   actually produced, instead of on a continuous bonding curve that the hook then had to top
///   the user up to match.
///
///   `ClogMarket.sol` computed `tokensOut` itself from `k / (re + ethIn)` and the hook paid the
///   difference. That top-up, and the residual/deferred-liability machinery that funded it, are
///   gone. The pool executes; `applyBuyActual` is told what it executed.
///
///   CONSEQUENCE FOR re / rt. They are no longer an independent curve that must be reconciled
///   against the pool — they are bookkeeping that MIRRORS actual execution:
///       buy : re += (curveBudget + netForClog + dust - clogExtracted),  rt -= actualTokensOut
///       sell: re -= grossPayout,                                        rt += tokensIn
///   so both structural invariants still hold by construction:
///       re - realETH           == virtualEthSeed
///       rt - physicalInventory == rt0 - inventory0
///
///   The CLOG leg is still a genuine second leg, not a proportional carve-up: `clogTokens` is
///   capped by RELEASE_RATIO_BPS on new HWM territory exactly as before, and `netForClog` is the
///   ETH the pool actually charged for that final segment — supplied by the caller, which is the
///   only party that can see the real swap. Extraction then runs on that unchanged.
contract ClogGenuineMarket {
    // ── Fixed supply split — identical constants to ClogMarket ──────────────────────────────
    uint256 public constant CURVE_ALLOCATION = 900_000_000e18;
    uint256 public constant CLOG_ALLOCATION = 100_000_000e18;

    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 60; // 0.6%
    uint256 public constant SELL_TAX_BPS = 60; // 0.6%
    uint256 public constant TICKER_OWNER_TAX_BPS = 4_000; // 40% of the tax
    uint256 public constant MULTISIG_TAX_BPS = 1_000; // 10% of the tax
    // WinnerPot takes the tax residual (50%).

    uint256 public constant RELEASE_RATIO_BPS = 1_111; // ~1/9, identical to production
    uint256 public constant MULTISIG_CLOG_BPS = 1_000; // 10% of EXTRACTED clog revenue
    uint256 public constant WINNERPOT_CLOG_BPS = 9_000; // 90% of EXTRACTED clog revenue

    address public immutable hook;
    address public immutable token;
    address public immutable tickerNFT;
    uint256 public immutable tickerTokenId;
    address public immutable multisig;
    address public immutable eligibilityRegistry;

    uint256 public re;
    uint256 public rt;
    uint256 public k;
    uint256 public sold;
    uint256 public immutable virtualEthSeed;
    uint256 public realETH;

    uint256 public hwm;
    uint256 public clogRemaining;
    uint256 public rtCeiling;

    uint256 public targetExtractionBps = 4_000;
    uint256 public safetyFloorBps = 5_000;

    uint256 public physicalInventory;

    mapping(address => uint256) public pendingWithdrawals;

    event Bought(uint256 grossInput, uint256 tax, uint256 curveTokens, uint256 clogTokens, uint256 clogExtracted, uint256 clogRetained, uint256 newRe, uint256 newRt);
    event Sold(uint256 tokensIn, uint256 grossPayout, uint256 tax, uint256 netEthOut, bool wasCapped, uint256 newRe, uint256 newRt);
    event Credited(address indexed to, uint256 amount, uint256 newPending);
    event Withdrawn(address indexed to, uint256 amount);
    event ClogTokensReleased(uint256 clogTokens, uint256 newHwm);
    event ClogRevenueExtracted(uint256 extracted, uint256 retained, uint256 effectiveBps);

    modifier onlyHook() {
        require(msg.sender == hook, "not hook");
        _;
    }

    constructor(
        address hook_,
        address token_,
        address tickerNFT_,
        uint256 tickerTokenId_,
        address multisig_,
        uint256 virtualEthSeed_,
        uint256 bufferMultiplierBps_,
        address eligibilityRegistry_
    ) {
        require(
            hook_ != address(0) && token_ != address(0) && tickerNFT_ != address(0) && multisig_ != address(0)
                && eligibilityRegistry_ != address(0),
            "zero address"
        );
        require(virtualEthSeed_ > 0 && bufferMultiplierBps_ > 0, "zero seed");
        hook = hook_;
        token = token_;
        tickerNFT = tickerNFT_;
        tickerTokenId = tickerTokenId_;
        multisig = multisig_;
        eligibilityRegistry = eligibilityRegistry_;
        virtualEthSeed = virtualEthSeed_;

        re = virtualEthSeed_;
        rt = Math.mulDiv(CURVE_ALLOCATION, bufferMultiplierBps_, BPS);
        k = re * rt;
        clogRemaining = CLOG_ALLOCATION;
        rtCeiling = rt;
        physicalInventory = CURVE_ALLOCATION + CLOG_ALLOCATION;
    }

    /// @notice Resolved fresh on every call — an NFT transfer takes effect on the next trade.
    function ticketOwnerRecipient() public view returns (address) {
        return IERC721Like(tickerNFT).ownerOf(tickerTokenId);
    }

    /// @notice Apply CLOG's rules to a buy that the v4 pool has ALREADY executed.
    /// @param grossInput      full ETH the user paid, before tax
    /// @param actualTokensOut tokens the genuine core swap actually delivered for the post-tax budget
    /// @param sqrtP0/sqrtP1   pool sqrt price before/after the genuine core swap
    /// @param liquidity       pool liquidity the swap executed against
    /// @dev The split solver of the legacy contract existed only to predict what the curve would
    ///      do. Here the pool already did it, so the CLOG leg is carved off the REAR of the
    ///      actual fill, capped by exactly the same RELEASE_RATIO_BPS / clogRemaining rule.
    function applyBuyActual(
        uint256 grossInput,
        uint256 actualTokensOut,
        uint160 sqrtP0,
        uint160 sqrtP1,
        uint128 liquidity
    )
        external
        onlyHook
        returns (uint256 tokensOut, uint256 winnerPotShare)
    {
        require(grossInput > 0, "zero input");
        require(actualTokensOut > 0, "zero output");

        uint256 tax = Math.mulDiv(grossInput, BUY_TAX_BPS, BPS);
        uint256 budget = grossInput - tax;

        uint256 ownerShare = Math.mulDiv(tax, TICKER_OWNER_TAX_BPS, BPS);
        uint256 multisigShare = Math.mulDiv(tax, MULTISIG_TAX_BPS, BPS);
        uint256 taxWinnerPotShare = tax - ownerShare - multisigShare;

        // ── provisional territory from the ACTUAL fill ──
        uint256 provisionalSold = sold + actualTokensOut;
        uint256 newTerritory = provisionalSold > hwm ? provisionalSold - hwm : 0;
        uint256 targetClogTokens = Math.min(Math.mulDiv(newTerritory, RELEASE_RATIO_BPS, BPS), clogRemaining);
        uint256 clogTokens = Math.min(targetClogTokens, actualTokensOut);
        uint256 curveTokens = actualTokensOut - clogTokens;

        // ── leg 1: the curve portion. netForClog is the ETH the POOL actually charged for
        //    the rear `clogTokens` of this fill, priced on the real swap's own geometry:
        //      amount1 moves linearly in sqrtP, so sqrtMid = sqrtP0 - curveTokens*Q96/L,
        //      and the CLOG leg's ETH is getAmount0Delta(sqrtP1, sqrtMid, L).
        uint256 netForClog = _clogLegEth(curveTokens, clogTokens, sqrtP0, sqrtP1, liquidity, budget);
        uint256 curveBudget = budget - netForClog;

        re += curveBudget;
        rt -= curveTokens;
        sold += curveTokens;
        realETH += curveBudget;

        uint256 clogExtracted;
        uint256 clogRetained;
        uint256 clogWinnerPotShare;
        if (clogTokens > 0) {
            re += netForClog;
            rt -= clogTokens;
            realETH += netForClog;
            clogRemaining -= clogTokens;
            rtCeiling += clogTokens;
            hwm = sold;
            emit ClogTokensReleased(clogTokens, hwm);

            (clogExtracted, clogRetained, clogWinnerPotShare) = _safeExtract(netForClog);
            realETH -= clogExtracted;
            re -= clogExtracted;
        }

        k = re * rt;

        tokensOut = actualTokensOut;
        require(tokensOut <= physicalInventory, "exceeds available token inventory");
        physicalInventory -= tokensOut;

        _credit(ticketOwnerRecipient(), ownerShare);
        _credit(multisig, multisigShare);
        winnerPotShare = taxWinnerPotShare + clogWinnerPotShare;

        emit Bought(grossInput, tax, curveTokens, clogTokens, clogExtracted, clogRetained, re, rt);
        _touchEligibility();
    }

    function _clogLegEth(
        uint256 curveTokens,
        uint256 clogTokens,
        uint160 sqrtP0,
        uint160 sqrtP1,
        uint128 liquidity,
        uint256 budget
    ) internal pure returns (uint256) {
        if (clogTokens == 0 || liquidity == 0 || sqrtP1 >= sqrtP0) return 0;
        uint256 drop = Math.mulDiv(curveTokens, 1 << 96, liquidity);
        if (drop >= uint256(sqrtP0)) return budget;
        uint160 sqrtMid = uint160(uint256(sqrtP0) - drop);
        if (sqrtMid <= sqrtP1) return 0;
        uint256 eth = SqrtPriceMath.getAmount0Delta(sqrtP1, sqrtMid, liquidity, true);
        return eth > budget ? budget : eth;
    }

    /// @dev Byte-for-byte the extraction rule of ClogMarket @ 422a61a.
    function _safeExtract(uint256 netForClog) internal returns (uint256 extracted, uint256 retained, uint256 winnerPotPortion) {
        uint256 circulating = rtCeiling - rt;
        uint256 price = rt == 0 ? 0 : Math.mulDiv(re, 1e18, rt);
        uint256 circulatingValue = Math.mulDiv(circulating, price, 1e18);

        uint256 targetExtraction = Math.mulDiv(netForClog, targetExtractionBps, BPS);

        if (circulatingValue == 0) {
            extracted = targetExtraction;
        } else {
            uint256 realETHAfterTargetExtraction = realETH >= targetExtraction ? realETH - targetExtraction : 0;
            uint256 ratioIfFullExtractionBps = Math.mulDiv(realETHAfterTargetExtraction, BPS, circulatingValue);

            if (ratioIfFullExtractionBps >= safetyFloorBps) {
                extracted = targetExtraction;
            } else {
                uint256 floorRequirement = Math.mulDiv(circulatingValue, safetyFloorBps, BPS);
                extracted = realETH > floorRequirement ? realETH - floorRequirement : 0;
                if (extracted > targetExtraction) extracted = targetExtraction;
            }
        }

        retained = netForClog - extracted;
        uint256 effectiveBps = netForClog == 0 ? 0 : Math.mulDiv(extracted, BPS, netForClog);
        emit ClogRevenueExtracted(extracted, retained, effectiveBps);

        if (extracted > 0) {
            uint256 toMultisig = Math.mulDiv(extracted, MULTISIG_CLOG_BPS, BPS);
            winnerPotPortion = extracted - toMultisig;
            _credit(multisig, toMultisig);
        }
    }

    /// @notice Apply CLOG's rules to a sell the pool has ALREADY executed.
    /// @param tokensIn     full token amount the user sold
    /// @param actualGross  gross ETH the genuine core swap actually paid out, before tax
    /// @dev Solvency cap semantics preserved: the payout can never exceed realETH, and a fully
    ///      capped sell lands re exactly on virtualEthSeed.
    function applySellActual(uint256 tokensIn, uint256 actualGross)
        external
        onlyHook
        returns (uint256 netEthOut, uint256 winnerPotShare, bool wasCapped)
    {
        require(tokensIn > 0, "zero input");

        uint256 grossPayout = actualGross;
        if (grossPayout > realETH) {
            grossPayout = realETH;
            wasCapped = true;
        }
        require(grossPayout > 0, "zero output");

        re -= grossPayout;
        realETH -= grossPayout;
        rt += tokensIn;
        k = re * rt;
        sold = sold > tokensIn ? sold - tokensIn : 0;
        physicalInventory += tokensIn;

        uint256 tax = Math.mulDiv(grossPayout, SELL_TAX_BPS, BPS);
        netEthOut = grossPayout - tax;

        uint256 ownerShare = Math.mulDiv(tax, TICKER_OWNER_TAX_BPS, BPS);
        uint256 multisigShare = Math.mulDiv(tax, MULTISIG_TAX_BPS, BPS);
        winnerPotShare = tax - ownerShare - multisigShare;

        _credit(ticketOwnerRecipient(), ownerShare);
        _credit(multisig, multisigShare);

        emit Sold(tokensIn, grossPayout, tax, netEthOut, wasCapped, re, rt);
        _touchEligibility();
    }

    function withdraw(address to) external {
        uint256 amount = pendingWithdrawals[to];
        require(amount > 0, "nothing to withdraw");
        pendingWithdrawals[to] = 0;
        IWithdrawalExecutorG(hook).executeWithdrawal(to, amount);
        emit Withdrawn(to, amount);
    }

    function grantHookApprovals(address poolManager_) external {
        require(poolManager_ != address(0), "zero pool manager");
        IERC6909ClaimsG(poolManager_).approve(hook, uint256(uint160(token)), type(uint256).max);
        IERC6909ClaimsG(poolManager_).approve(hook, 0, type(uint256).max);
    }

    function depositInventoryTo(address token_, address to) external onlyHook {
        require(token_ == token, "wrong token");
        uint256 balance = IERC20LikeM(token_).balanceOf(address(this));
        require(balance > 0, "nothing to deposit");
        require(IERC20LikeM(token_).transfer(to, balance), "token transfer failed");
    }

    function realReserve() external view returns (uint256) {
        return realETH;
    }

    function progressBps() external view returns (uint256) {
        return sold >= CURVE_ALLOCATION ? BPS : Math.mulDiv(sold, BPS, CURVE_ALLOCATION);
    }

    function _touchEligibility() internal {
        IEligibilityG(eligibilityRegistry).onTrade(tickerTokenId);
    }

    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 p = pendingWithdrawals[to] + amount;
        pendingWithdrawals[to] = p;
        emit Credited(to, amount, p);
    }
}
