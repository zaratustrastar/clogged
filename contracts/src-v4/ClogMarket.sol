// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Minimal interface into the hook this market trusts for its own withdrawal
///         plumbing - kept separate from importing ClogV4Hook.sol directly to avoid a circular
///         import (ClogV4Hook.sol itself imports ClogMarket.sol).
interface IClogV4HookWithdrawal {
    function executeWithdrawal(address to, uint256 amount) external;
}

/// @title ClogMarket (vertical-slice version, now with the full 100M CLOG leg)
/// @notice Non-custodial per-ticker economic state engine - the intended descendant of
///         BondingCurveClog.sol, refactored to hold ZERO custody of ETH/tokens itself. All
///         actual value movement happens through PoolManager's flash accounting (ERC6909
///         claims this contract owns), driven by the universal ClogV4Hook calling into this
///         contract's pure state-transition functions from inside beforeSwap.
///
/// @dev STILL DELIBERATELY DEFERRED, explicitly (not an oversight, and NOT to be described as
///      "finished" until built): the real WinnerPot-share ETH routing mechanism (mint-to-
///      RewardVault + recordWinnerPotClaim - both the trading-tax WinnerPot share and the
///      CLOG-extraction WinnerPot share are still tracked as this contract's own
///      winnerPotLiability accumulator for now, pending that separate integration piece);
///      governance-adjustable targetExtractionBps/safetyFloorBps (this slice hardcodes the
///      production defaults, 4_000/5_000, with no setter yet).
///
/// @dev NOW PORTED, this pass, verified against the exact production BondingCurveClog.sol
///      source (read directly before implementing, not from memory): dynamic ticker-owner
///      resolution via IERC721(tickerNFT).ownerOf(tickerTokenId), resolved fresh on every
///      trade rather than cached - an NFT transfer redirects all FUTURE fees immediately, while
///      already-credited pendingWithdrawals for the previous owner remain exactly as they were
///      (pendingWithdrawals is keyed by address, so a later resolution simply credits a
///      different key - it can never rewrite or move what was already credited to the old one);
///      the full claim-native withdraw(to) path (see below).
///
/// @dev NOW PORTED, this pass, verified against the exact production BondingCurveClog.sol
///      source (read directly before implementing, not from memory): the full 900M curve /
///      100M CLOG allocation split; clogRemaining, hwm, rtCeiling; the fixed-point curve/CLOG
///      budget-split solver (_executeBudget, MAX_SPLIT_ITERATIONS = 6, RELEASE_RATIO_BPS =
///      1_111); the exact-residual-budget discipline (the CLOG leg's ETH input is
///      `budget - curveBudget`, never an independently re-derived amount, so the two legs can
///      never together overspend the buyer's budget); dust handling (unspent residual added
///      directly to backing, never re-solved as more token delivery); the reserve-aware
///      _safeExtract (target extraction 4_000bps, safety floor 5_000bps, the ratio-preserving
///      cap when full target extraction would breach the floor); the 10%/90% multisig/WinnerPot
///      split of extracted CLOG revenue; k re-anchoring after every state change, now including
///      the CLOG leg and extraction, not just the plain curve leg.
///
/// @dev physicalInventory is now a FIXED, HARDCODED sum of the two real allocations
///      (CURVE_ALLOCATION + CLOG_ALLOCATION = exactly MemeToken.TOTAL_SUPPLY) - there is no
///      constructor parameter for it anymore, so it can never legitimately be set to anything
///      else, structurally, not merely by convention.
contract ClogMarket {
    // ── Fixed supply split - identical constants to production ──────────────────────────────
    uint256 public constant CURVE_ALLOCATION = 900_000_000e18;
    uint256 public constant CLOG_ALLOCATION = 100_000_000e18;

    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 60; // 0.6%
    uint256 public constant SELL_TAX_BPS = 60; // 0.6%
    uint256 public constant TICKER_OWNER_TAX_BPS = 4_000; // 40% of the tax
    uint256 public constant MULTISIG_TAX_BPS = 1_000; // 10% of the tax
    // WinnerPot gets the tax residual (50%) - see contract-level docs, same reasoning as the prior pass.

    uint256 public constant RELEASE_RATIO_BPS = 1_111; // ~1/9, identical to production
    uint256 public constant MULTISIG_CLOG_BPS = 1_000; // 10% of EXTRACTED clog revenue
    uint256 public constant WINNERPOT_CLOG_BPS = 9_000; // 90% of EXTRACTED clog revenue

    uint256 public constant MAX_SPLIT_ITERATIONS = 6;
    uint256 public constant MAX_EXTRACTION_BPS = 8_000; // governance ceiling, not yet enforced by a setter in this slice (no setter exists yet)
    uint256 public constant MIN_SAFETY_FLOOR_BPS = 2_000; // governance floor, same status as above

    address public immutable hook; // the universal ClogV4Hook - the only caller allowed to trigger state transitions
    address public immutable token; // this ticker's MemeToken
    address public immutable tickerNFT; // ERC721 whose ownerOf(tickerTokenId) IS the ticker-owner fee recipient - resolved dynamically on every trade, never cached, matching production exactly
    uint256 public immutable tickerTokenId;
    address public immutable multisig;

    uint256 public re; // virtualEthSeed + realETH, always - drives curve pricing
    uint256 public rt; // token-side PRICING reserve (virtual - starts far above physical supply, by design)
    uint256 public k; // re * rt, re-anchored after every trade
    uint256 public sold; // cumulative curve tokens ever delivered to real buyers (leg-1 only) - identical semantics to production
    uint256 public immutable virtualEthSeed;
    uint256 public realETH; // the REAL portion of re - never includes the virtual seed

    uint256 public hwm; // high-water mark of `sold` - monotonic, never decreases
    uint256 public clogRemaining; // CAT still sitting in the CLOG reserve
    uint256 public rtCeiling; // rt + circulating; grows ONLY via CLOG deliveries (see production's own docs)

    uint256 public targetExtractionBps = 4_000; // f_target - hardcoded to production's own default; no governance setter in this slice yet
    uint256 public safetyFloorBps = 5_000; // floor - same status as above

    /// @notice Real MemeToken units still available to deliver - FIXED at exactly
    ///         CURVE_ALLOCATION + CLOG_ALLOCATION (MemeToken.TOTAL_SUPPLY), by construction -
    ///         there is no constructor parameter for this anymore (see contract-level docs), so
    ///         it can never legitimately be set to, or exceed, anything else.
    uint256 public physicalInventory;

    mapping(address => uint256) public pendingWithdrawals; // pull-payment ledger, mirroring production's own _credit/withdraw exactly
    uint256 public winnerPotLiability; // see contract-level docs on what's still deferred here

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

    constructor(address hook_, address token_, address tickerNFT_, uint256 tickerTokenId_, address multisig_, uint256 virtualEthSeed_, uint256 bufferMultiplierBps_) {
        require(hook_ != address(0) && token_ != address(0) && tickerNFT_ != address(0) && multisig_ != address(0), "zero address");
        require(virtualEthSeed_ > 0 && bufferMultiplierBps_ > 0, "zero seed");
        hook = hook_;
        token = token_;
        tickerNFT = tickerNFT_;
        tickerTokenId = tickerTokenId_;
        multisig = multisig_;
        virtualEthSeed = virtualEthSeed_;

        uint256 virtualTokenSeed = Math.mulDiv(CURVE_ALLOCATION, bufferMultiplierBps_, BPS);
        re = virtualEthSeed_;
        rt = virtualTokenSeed;
        k = re * rt;
        clogRemaining = CLOG_ALLOCATION;
        rtCeiling = rt;
        physicalInventory = CURVE_ALLOCATION + CLOG_ALLOCATION; // fixed, exactly MemeToken.TOTAL_SUPPLY
    }

    /// @notice The current ticker-owner fee recipient - resolved fresh on every call, exactly
    ///         like production's own ticketOwnerRecipient(). Never cached anywhere: an NFT
    ///         transfer takes effect on the very next trade.
    function ticketOwnerRecipient() public view returns (address) {
        return IERC721(tickerNFT).ownerOf(tickerTokenId);
    }

    /// @notice Full-tax-aware, CLOG-leg-aware buy. Called by the hook mid-beforeSwap with the
    ///         FULL exact input (grossInput) - the hook mints a claim for this same full amount.
    function applyBuy(uint256 grossInput) external onlyHook returns (uint256 tokensOut, uint256 winnerPotShare) {
        require(grossInput > 0, "zero input");

        uint256 tax = Math.mulDiv(grossInput, BUY_TAX_BPS, BPS);
        uint256 budget = grossInput - tax;

        uint256 ownerShare = Math.mulDiv(tax, TICKER_OWNER_TAX_BPS, BPS);
        uint256 multisigShare = Math.mulDiv(tax, MULTISIG_TAX_BPS, BPS);
        uint256 taxWinnerPotShare = tax - ownerShare - multisigShare; // residual - see contract-level docs

        (uint256 curveTokens, uint256 clogTokens, uint256 clogExtracted, uint256 clogRetained, uint256 clogWinnerPotShare) = _executeBudget(budget);

        tokensOut = curveTokens + clogTokens;
        require(tokensOut > 0, "zero output");
        // Exactly production's own inventory guard, checked AFTER _executeBudget has already
        // mutated state - if this reverts, the whole external call (and everything
        // _executeBudget did) rolls back atomically, exactly matching production's own
        // buy()-checks-after-_executeBudget ordering.
        require(tokensOut <= physicalInventory, "exceeds available token inventory");
        physicalInventory -= tokensOut;

        _credit(ticketOwnerRecipient(), ownerShare);
        _credit(multisig, multisigShare);
        winnerPotShare = taxWinnerPotShare + clogWinnerPotShare;
        winnerPotLiability += winnerPotShare;

        emit Bought(grossInput, tax, curveTokens, clogTokens, clogExtracted, clogRetained, re, rt);
    }

    /// @dev Solves the fixed-point curve/CLOG budget split, then applies BOTH legs to state in
    ///      one pass - ported line-for-line against production's own _executeBudget. `budget`
    ///      is the buyer's entire post-tax spend; nothing beyond it is ever attributed to
    ///      either leg. The CLOG leg's ETH input is the EXACT RESIDUAL (budget - curveBudget),
    ///      never an independently re-derived "target" cost, so the two legs can never together
    ///      overspend budget by construction, regardless of how well the iteration converges.
    function _executeBudget(uint256 budget)
        internal
        returns (uint256 curveTokens, uint256 clogTokens, uint256 clogExtracted, uint256 clogRetained, uint256 clogWinnerPotShare)
    {
        uint256 curveBudget = budget; // initial guess: all budget to the curve leg

        for (uint256 i = 0; i < MAX_SPLIT_ITERATIONS; i++) {
            (uint256 provisionalCurveTokens, uint256 provisionalNewTerritory) = _quoteCurveLeg(curveBudget);
            uint256 provisionalClogTarget = Math.min(Math.mulDiv(provisionalNewTerritory, RELEASE_RATIO_BPS, BPS), clogRemaining);
            if (provisionalClogTarget == 0) break;
            uint256 provisionalClogCost = _quoteClogLeg(curveBudget, provisionalCurveTokens, provisionalClogTarget);
            if (provisionalClogCost >= budget) {
                curveBudget = 0;
                break;
            }
            uint256 newCurveBudget = budget - provisionalClogCost;
            if (newCurveBudget == curveBudget) break;
            curveBudget = newCurveBudget;
        }

        // ── Apply leg 1 (curve) for real, using the converged estimate ─────────
        uint256 newRt1 = k / (re + curveBudget);
        curveTokens = rt - newRt1;
        re = re + curveBudget;
        rt = newRt1;
        sold += curveTokens;
        realETH += curveBudget;

        uint256 newTerritory = sold > hwm ? sold - hwm : 0;
        uint256 targetClogTokens = Math.min(Math.mulDiv(newTerritory, RELEASE_RATIO_BPS, BPS), clogRemaining);

        // ── Apply leg 2 with the EXACT residual budget, never a re-derived amount ──
        uint256 residualBudget = budget - curveBudget;
        if (targetClogTokens > 0 && residualBudget > 0) {
            uint256 reAfterResidual = re + residualBudget;
            uint256 rtAfterResidual = Math.mulDiv(k, 1, reAfterResidual);
            uint256 tokensFromResidual = rt - rtAfterResidual;
            uint256 actualClogTokens = Math.min(tokensFromResidual, targetClogTokens);

            uint256 newRt2 = rt - actualClogTokens;
            uint256 newRe2 = k / newRt2;
            uint256 netForClog = newRe2 - re; // <= residualBudget by construction

            re = newRe2;
            rt = newRt2;
            realETH += netForClog;
            clogRemaining -= actualClogTokens;
            rtCeiling += actualClogTokens;
            hwm = sold;
            clogTokens = actualClogTokens;
            emit ClogTokensReleased(actualClogTokens, hwm);

            uint256 dust = residualBudget - netForClog;
            if (dust > 0) {
                re = re + dust;
                realETH += dust;
            }

            (clogExtracted, clogRetained, clogWinnerPotShare) = _safeExtract(netForClog);
            realETH -= clogExtracted;
            re = re - clogExtracted;
        }

        k = re * rt; // re-anchor: k always reflects the CURRENT, honest (re, rt)
    }

    /// @dev Pure quote of what leg 1 (curve-only) would deliver for a given ETH input, WITHOUT
    ///      mutating state. Used only inside the split-solving iteration above.
    function _quoteCurveLeg(uint256 ethIn) internal view returns (uint256 tokensOut, uint256 newTerritory) {
        uint256 newRt = k / (re + ethIn);
        tokensOut = rt - newRt;
        uint256 newSold = sold + tokensOut;
        newTerritory = newSold > hwm ? newSold - hwm : 0;
    }

    /// @dev Pure quote of the self-consistent ETH cost of a CLOG-leg delivering `clogTokens`,
    ///      given the state AFTER leg 1 has hypothetically executed with `curveBudget`.
    function _quoteClogLeg(uint256 curveBudget, uint256 curveTokensOut, uint256 clogTokens) internal view returns (uint256 ethCost) {
        uint256 reAfterLeg1 = re + curveBudget;
        uint256 rtAfterLeg1 = rt - curveTokensOut;
        uint256 rtTarget = rtAfterLeg1 - clogTokens;
        uint256 reTarget = k / rtTarget;
        ethCost = reTarget - reAfterLeg1;
    }

    /// @dev The dynamic, reserve-aware extraction rule - ported line-for-line against
    ///      production's own _safeExtract. `netForClog` has ALREADY entered realETH and fully
    ///      backs the CLOG tokens just delivered - this function only decides how much of it to
    ///      pull back out as revenue, never more than the target, and never so much that the
    ///      remaining real backing per unit of circulating supply would fall below the safety floor.
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
            // winnerPotPortion is returned, added to winnerPotLiability by the caller (applyBuy) -
            // see contract-level docs on why this stays a tracked liability, not a real route, for now.
        }
    }

    /// @notice Pure state transition for a sell - symmetric to applyBuy's curve leg (the CLOG
    ///         leg has no sell-side counterpart - CLOG tokens, once delivered, trade on the
    ///         curve like any other circulating token; there is no separate "sell into CLOG").
    ///         Returns the full gross ETH payout, tax-split, and solvency-capped exactly as the
    ///         prior pass - unchanged by this pass's CLOG-leg work, since production's own
    ///         sell() never touches hwm/clogRemaining/rtCeiling either (confirmed directly
    ///         against source before this port).
    function applySell(uint256 tokensIn) external onlyHook returns (uint256 netEthOut, uint256 winnerPotShare, bool wasCapped) {
        require(tokensIn > 0, "zero input");

        uint256 newRt = rt + tokensIn;
        uint256 idealNewRe = k / newRt;
        uint256 idealPayout = re - idealNewRe;

        uint256 grossPayout;
        if (idealPayout > realETH) {
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
        winnerPotLiability += winnerPotShare;

        emit Sold(tokensIn, grossPayout, tax, netEthOut, wasCapped, re, rt);
    }

    /// @notice Permissionless trigger for pulling `to`'s accumulated pendingWithdrawals out as
    ///         real native ETH - the v4 equivalent of production's own withdraw(to). ETH always
    ///         goes to `to`, regardless of who calls this (same permissionless-trigger pattern
    ///         production uses throughout). Liability is cleared BEFORE any external call or
    ///         value movement (checks-effects-interactions, matching production exactly) - if
    ///         the hook's own PoolManager unlock/burn/take sequence fails for any reason
    ///         (including `to` itself being unable to receive ETH), the ENTIRE call reverts
    ///         atomically, so the just-cleared liability is restored along with everything
    ///         else - it is never silently lost.
    function withdraw(address to) external {
        uint256 amount = pendingWithdrawals[to];
        require(amount > 0, "nothing to withdraw");
        pendingWithdrawals[to] = 0;
        IClogV4HookWithdrawal(hook).executeWithdrawal(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @dev Pull-payment credit - mirrors production's own _credit exactly.
    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        pendingWithdrawals[to] += amount;
        emit Credited(to, amount, pendingWithdrawals[to]);
    }
}
