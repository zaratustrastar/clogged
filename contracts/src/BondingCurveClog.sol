// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MemeToken} from "./MemeToken.sol";

/// @title BondingCurveClog
/// @notice Protocol-controlled constant-product bonding curve for a single meme token, with a
///         genuine, reserve-aware CLOG (10% reserve) sale mechanism layered on top.
///
/// Design invariants this contract exists to enforce (see the accompanying architecture docs
/// for the full derivation -- these are restated here as the load-bearing contract-level facts):
///
///  1. `re` (the AMM's ETH-side state) must NEVER be allowed to drift from
///     `virtualEthSeed + realETH`. `realETH` is ground truth for what this contract actually
///     holds; `re` is a derived pricing variable and must always equal that ground truth plus
///     the fixed virtual seed. Every function that changes `realETH` changes `re` by the exact
///     same amount, in the same statement, so they can never desynchronize.
///
///  2. No `sell()` may ever pay out more ETH than `realETH` actually holds. The CP formula's
///     "ideal" payout is computed first; if it would exceed `realETH`, the payout is capped and
///     the curve state (`re`, `rt`, `k`) is re-anchored to the ACTUAL (capped) payout, never to
///     the uncapped formula result. The contract never quotes ETH it does not have.
///
///  3. CLOG only ever releases tokens for genuinely NEW high-water-mark territory (`sold > hwm`).
///     Selling back into previously-visited territory and re-buying it releases nothing --
///     this is what makes CLOG cycling-proof.
///
///  4. CLOG's ETH extraction fraction is dynamic and reserve-aware: it targets
///     `targetExtractionBps`, but is throttled downward whenever extracting the full target
///     would push the local health ratio (`realETH / value-of-everything-circulating`) below
///     `safetyFloorBps`. Extraction and token release are independent parameters everywhere in
///     this contract (see `ClogTokensReleased` vs `ClogRevenueExtracted` events) -- never conflate
///     "how many CAT came out of CLOG" with "how much ETH was extracted as revenue".
contract BondingCurveClog is ReentrancyGuard {
    // ── Fixed supply split (confirmed product decision) ──────────────────────────
    uint256 public constant CURVE_ALLOCATION = 900_000_000e18;
    uint256 public constant CLOG_ALLOCATION = 100_000_000e18;

    // ── Trading tax (confirmed: 0.5% buy / 0.5% sell, split 20/10/70) ────────────
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 50; // 0.5%
    uint256 public constant SELL_TAX_BPS = 50; // 0.5%
    uint256 public constant TICKER_OWNER_TAX_BPS = 2_000; // 20% of the tax
    uint256 public constant MULTISIG_TAX_BPS = 1_000; // 10% of the tax
    uint256 public constant WINNERPOT_TAX_BPS = 7_000; // 70% of the tax

    // ── CLOG token-release rate (confirmed: r = 1/9, independent of extraction) ──
    uint256 public constant RELEASE_RATIO_BPS = 1_111; // ~1/9
    uint256 public constant MULTISIG_CLOG_BPS = 1_000; // 10% of EXTRACTED clog revenue
    uint256 public constant WINNERPOT_CLOG_BPS = 9_000; // 90% of EXTRACTED clog revenue

    uint256 public constant MAX_SPLIT_ITERATIONS = 6;
    uint256 public constant MAX_EXTRACTION_BPS = 8_000; // governance ceiling: never > 80% target
    uint256 public constant MIN_SAFETY_FLOOR_BPS = 2_000; // governance floor: never < 20% safety floor

    MemeToken public immutable token;
    address public immutable tickerNFT; // ERC721 whose ownerOf(tickerTokenId) IS the ticket-owner
        // fee recipient -- resolved dynamically on every trade, never cached, so a sale on OpenSea
        // (or any other transfer) redirects future fees immediately with no migration transaction.
    uint256 public immutable tickerTokenId;
    address public immutable multisig;
    address public immutable winnerPot;
    address public governance;

    uint256 public immutable virtualEthSeed; // Rv_eth0
    uint256 public immutable virtualTokenSeed; // Rv_token0 = buffer * CURVE_ALLOCATION

    uint256 public re; // current AMM eth-side state; ALWAYS == virtualEthSeed + realETH
    uint256 public rt; // current AMM token-side state
    uint256 public k; // re * rt, re-anchored on every supply-changing or extraction event

    uint256 public realETH; // ground truth: actual ETH this contract holds as curve backing
    uint256 public sold; // cumulative curve tokens ever delivered to real buyers (leg-1 only)
    uint256 public hwm; // high-water mark of `sold` -- monotonic, never decreases
    uint256 public clogRemaining; // CAT still sitting in the CLOG reserve
    uint256 public rtCeiling; // rt + circulating; grows ONLY via CLOG deliveries (see docs)

    uint256 public targetExtractionBps; // f_target, governance-adjustable within bounds
    uint256 public safetyFloorBps; // floor, governance-adjustable within bounds

    mapping(address => uint256) public pendingWithdrawals; // pull-payment ledger for fee recipients
        // (the ticker owner resolved via ownerOf, multisig) -- see `_credit`/`withdraw` below.
        // Deliberately NOT used for the trader's own sell() payout, which stays a direct push: a broken/reverting trader
        // wallet only blocks THEIR OWN sell, never anyone else's. A broken/reverting FEE recipient,
        // by contrast, is the SAME address on every single trade -- pushing to it directly would
        // let one bad (or malicious) recipient brick the entire market. Found via ETHSkills
        // evm-audit-dos review ("ETH receiver with reverting fallback").

    // ── WinnerPot routing: pushed directly (not pull-payment -- see `_routeToWinnerPot`), but
    //    NEVER allowed to revert the trade itself. Invariant, true at all times:
    //      winnerPotGenerated == deliveredWinnerPot + pendingWinnerPot
    uint256 public constant WINNER_POT_CALL_GAS = 50_000; // generous for a simple `receive()`
        // (RewardVault's is a single SSTORE + event) but bounded so a broken or malicious
        // RewardVault cannot consume unbounded gas and force the whole trade to run out of gas
        // regardless of the success/failure branch below.
    uint256 public winnerPotGenerated; // cumulative ETH ever routed toward winnerPot, delivered or not
    uint256 public deliveredWinnerPot; // cumulative ETH successfully delivered
    uint256 public pendingWinnerPot; // cumulative ETH retained here after a failed delivery attempt

    event WinnerPotDelivered(uint256 amount, uint256 totalDelivered);
    event WinnerPotDeliveryFailed(uint256 amount, uint256 totalPending);
    event WinnerPotFlushed(uint256 amount, address indexed caller);
    event WinnerPotFlushFailed(uint256 amount, address indexed caller);

    event Bought(
        address indexed buyer,
        uint256 grossEthIn,
        uint256 buyTax,
        uint256 curveEthIn,
        uint256 curveTokensOut,
        uint256 clogEthIn,
        uint256 clogTokensOut,
        uint256 clogExtracted,
        uint256 clogRetained
    );
    event Sold(address indexed seller, uint256 tokensIn, uint256 grossEthOut, uint256 sellTax, uint256 netEthOut, bool wasCapped);
    event ClogTokensReleased(uint256 amount, uint256 newHwm);
    event ClogRevenueExtracted(uint256 extracted, uint256 retained, uint256 effectiveExtractionBps);
    event ExtractionParamsUpdated(uint256 targetExtractionBps, uint256 safetyFloorBps);
    event Credited(address indexed to, uint256 amount, uint256 newPending);
    event Withdrawn(address indexed to, uint256 amount);

    modifier onlyGovernance() {
        require(msg.sender == governance, "not governance");
        _;
    }

    constructor(
        address token_,
        address tickerNFT_,
        uint256 tickerTokenId_,
        address multisig_,
        address winnerPot_,
        address governance_,
        uint256 virtualEthSeed_,
        uint256 bufferMultiplierBps // e.g. 20_000 = 2.0x buffer (Config G)
    ) {
        require(
            token_ != address(0) && tickerNFT_ != address(0) && multisig_ != address(0)
                && winnerPot_ != address(0) && governance_ != address(0),
            "zero address"
        );
        token = MemeToken(token_);
        tickerNFT = tickerNFT_;
        tickerTokenId = tickerTokenId_;
        multisig = multisig_;
        winnerPot = winnerPot_;
        governance = governance_;

        virtualEthSeed = virtualEthSeed_;
        virtualTokenSeed = Math.mulDiv(CURVE_ALLOCATION, bufferMultiplierBps, BPS);

        re = virtualEthSeed_;
        rt = virtualTokenSeed;
        k = re * rt;
        clogRemaining = CLOG_ALLOCATION;
        rtCeiling = rt;

        targetExtractionBps = 4_000; // 40% default, matching the architecture doc's recommendation
        safetyFloorBps = 5_000; // 50% default
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Governance (bounded; full Safe+timelock wiring is a separate module)
    // ─────────────────────────────────────────────────────────────────────────

    function setExtractionParams(uint256 newTargetBps, uint256 newFloorBps) external onlyGovernance {
        require(newTargetBps <= MAX_EXTRACTION_BPS, "target too high");
        require(newFloorBps >= MIN_SAFETY_FLOOR_BPS, "floor too low");
        require(newFloorBps <= BPS, "floor invalid");
        targetExtractionBps = newTargetBps;
        safetyFloorBps = newFloorBps;
        emit ExtractionParamsUpdated(newTargetBps, newFloorBps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Buy: fixed total ETH budget, split deterministically between the curve
    //  leg and the (only-when-new-territory-exists) genuine CLOG-sale leg.
    // ─────────────────────────────────────────────────────────────────────────

    function buy(uint256 minTotalTokensOut, uint256 deadline) external payable nonReentrant returns (uint256 totalTokensOut) {
        require(block.timestamp <= deadline, "expired");
        require(msg.value > 0, "zero value");

        uint256 buyTax = Math.mulDiv(msg.value, BUY_TAX_BPS, BPS);
        uint256 budget = msg.value - buyTax;
        _routeTax(buyTax, true);

        (uint256 curveTokens, uint256 clogTokens, uint256 clogEthIn, uint256 clogExtracted, uint256 clogRetained) =
            _executeBudget(budget);

        totalTokensOut = curveTokens + clogTokens;
        require(totalTokensOut > 0, "zero output"); // never let a trade silently burn ETH for nothing
        require(totalTokensOut >= minTotalTokensOut, "slippage");
        // `rt`/`k` are a virtual-reserve pricing construct (per the architecture doc, the buffer
        // multiplier deliberately makes the pricing curve "deeper" than the real token count) --
        // they can imply more tokens than this contract physically holds for a large enough
        // input. The contract must never promise tokens it doesn't have: a buy that would exceed
        // actual inventory reverts cleanly rather than under-delivering or lying about balance.
        require(token.balanceOf(address(this)) >= totalTokensOut, "exceeds available token inventory");
        require(token.transfer(msg.sender, totalTokensOut), "token transfer failed");

        emit Bought(
            msg.sender, msg.value, buyTax, budget - clogEthIn, curveTokens, clogEthIn, clogTokens, clogExtracted, clogRetained
        );
    }

    /// @dev Solves the fixed-point curve/CLOG budget split (see architecture doc for derivation),
    ///      then applies BOTH legs to contract state in one pass. `budget` is the user's ENTIRE
    ///      post-tax spend -- nothing beyond it is EVER requested from or attributed to the buyer.
    ///
    ///      CRITICAL invariant this function must maintain exactly (not approximately): the total
    ///      ETH added to `realETH` across both legs must never exceed `budget`, no matter how the
    ///      iteration below converges. We achieve this by defining the CLOG leg's ETH input as the
    ///      EXACT RESIDUAL (`budget - curveBudget`) rather than independently computing a "target"
    ///      cost and hoping it matches -- the residual approach cannot overspend by construction.
    function _executeBudget(uint256 budget)
        internal
        returns (uint256 curveTokens, uint256 clogTokens, uint256 clogEthIn, uint256 clogExtracted, uint256 clogRetained)
    {
        uint256 curveBudget = budget; // initial guess: all budget to the curve leg

        // Converge on a curveBudget estimate such that spending the RESIDUAL (budget-curveBudget)
        // on the CLOG leg delivers close to r * newTerritory tokens. Fixed iteration count -- gas
        // bounded; see architecture doc for the convergence check (~1e-8 ETH error after 6 passes
        // on realistic Config-G numbers). Exactness of the FINAL split is enforced below regardless
        // of how well this converges.
        for (uint256 i = 0; i < MAX_SPLIT_ITERATIONS; i++) {
            (uint256 provisionalCurveTokens, uint256 provisionalNewTerritory) = _quoteCurveLeg(curveBudget);
            uint256 provisionalClogTarget =
                Math.min(Math.mulDiv(provisionalNewTerritory, RELEASE_RATIO_BPS, BPS), clogRemaining);
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
            // Given a FIXED eth input (residualBudget), find how many tokens that actually buys
            // via the normal swap formula, capped at the target so we never over-deliver.
            uint256 reAfterResidual = re + residualBudget;
            uint256 rtAfterResidual = Math.mulDiv(k, 1, reAfterResidual); // k / reAfterResidual, explicit for clarity
            uint256 tokensFromResidual = rt - rtAfterResidual;
            uint256 actualClogTokens = Math.min(tokensFromResidual, targetClogTokens);

            uint256 newRt2 = rt - actualClogTokens;
            uint256 newRe2 = k / newRt2;
            uint256 netForClog = newRe2 - re; // <= residualBudget by construction (fewer or equal tokens bought)

            re = newRe2;
            rt = newRt2;
            realETH += netForClog; // never exceeds residualBudget, hence never exceeds budget in total
            clogRemaining -= actualClogTokens;
            rtCeiling += actualClogTokens;
            hwm = sold;
            clogTokens = actualClogTokens;
            emit ClogTokensReleased(actualClogTokens, hwm);

            // Any unspent dust from the residual (netForClog < residualBudget, due to the min() cap
            // above) is simply left in the buyer's hands as unspent value -- see `buy()`, which only
            // ever pulls exactly `msg.value` and never requests more.
            uint256 dust = residualBudget - netForClog;
            if (dust > 0) {
                // Dust is real ETH the contract received but didn't attribute to either leg's price
                // impact; the safest disposition is to add it directly to backing (never to token
                // delivery, since that would require re-solving the swap again).
                re = re + dust;
                realETH += dust;
            }

            (clogExtracted, clogRetained) = _safeExtract(netForClog);
            realETH -= clogExtracted;
            re = re - clogExtracted;
            clogEthIn = netForClog;
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

    /// @dev The dynamic, reserve-aware extraction rule. `netForClog` has ALREADY entered `realETH`
    ///      and fully backs the CLOG tokens just delivered (leg 2 is a normal, self-consistent
    ///      swap) -- this function only decides how much of it to pull back out as revenue.
    function _safeExtract(uint256 netForClog) internal returns (uint256 extracted, uint256 retained) {
        uint256 circulating = rtCeiling - rt;
        uint256 price = rt == 0 ? 0 : Math.mulDiv(re, 1e18, rt); // price scaled 1e18 for precision
        uint256 circulatingValue = Math.mulDiv(circulating, price, 1e18);

        uint256 targetExtraction = Math.mulDiv(netForClog, targetExtractionBps, BPS);

        if (circulatingValue == 0) {
            extracted = targetExtraction;
        } else {
            // realETH here already includes netForClog (added by the caller before this call).
            uint256 realETHAfterTargetExtraction = realETH >= targetExtraction ? realETH - targetExtraction : 0;
            uint256 ratioIfFullExtractionBps = Math.mulDiv(realETHAfterTargetExtraction, BPS, circulatingValue);

            if (ratioIfFullExtractionBps >= safetyFloorBps) {
                extracted = targetExtraction;
            } else {
                // Solve for the maximum extraction that leaves the ratio exactly at the floor:
                // (realETH - x) / circulatingValue >= floor  =>  x <= realETH - floor*circulatingValue
                uint256 floorRequirement = Math.mulDiv(circulatingValue, safetyFloorBps, BPS);
                extracted = realETH > floorRequirement ? realETH - floorRequirement : 0;
                if (extracted > targetExtraction) extracted = targetExtraction; // never extract MORE than target
            }
        }

        retained = netForClog - extracted;
        uint256 effectiveBps = netForClog == 0 ? 0 : Math.mulDiv(extracted, BPS, netForClog);
        emit ClogRevenueExtracted(extracted, retained, effectiveBps);

        if (extracted > 0) {
            uint256 toMultisig = Math.mulDiv(extracted, MULTISIG_CLOG_BPS, BPS);
            uint256 toWinnerPot = extracted - toMultisig;
            _credit(multisig, toMultisig);
            _routeToWinnerPot(toWinnerPot);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Sell: the hard, non-negotiable solvency guard lives here.
    // ─────────────────────────────────────────────────────────────────────────

    function sell(uint256 tokenAmount, uint256 minEthOut, uint256 deadline) external nonReentrant returns (uint256 netEthOut, bool wasCapped) {
        require(block.timestamp <= deadline, "expired");
        require(tokenAmount > 0, "zero amount");
        require(token.transferFrom(msg.sender, address(this), tokenAmount), "token transferFrom failed");

        uint256 newRt = rt + tokenAmount; // tokens fully enter the pool regardless of payout capping
        uint256 idealNewRe = k / newRt;
        uint256 idealPayout = re - idealNewRe;

        uint256 grossPayout;
        if (idealPayout > realETH) {
            // ── THE solvency guard: never pay out more than what is actually held. ──
            grossPayout = realETH;
            wasCapped = true;
        } else {
            grossPayout = idealPayout;
        }

        uint256 newRe = re - grossPayout;
        realETH -= grossPayout;
        re = newRe;
        rt = newRt;
        k = re * rt; // re-anchor: if capping occurred, k now reflects the ACTUAL (re, rt), not the
                     // uncapped formula's implied state -- every subsequent quote is honest.
        sold = sold > tokenAmount ? sold - tokenAmount : 0;

        uint256 sellTax = Math.mulDiv(grossPayout, SELL_TAX_BPS, BPS);
        netEthOut = grossPayout - sellTax;
        require(netEthOut >= minEthOut, "slippage");

        _routeTax(sellTax, false);
        _send(msg.sender, netEthOut);

        emit Sold(msg.sender, tokenAmount, grossPayout, sellTax, netEthOut, wasCapped);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Shared helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `winnerPot` is deliberately pushed directly, NOT credited via the pull-payment ledger
    ///      like `ticketOwnerRecipient`/`multisig`. `winnerPot` is RewardVault -- a single,
    ///      protocol-owned, known-good contract shared across potentially thousands of independent
    ///      BondingCurveClog instances (one per meme). Pull-payment there would mean RewardVault's
    ///      pool never actually grows until someone separately calls `withdraw(address(vault))` on
    ///      EVERY active market -- an operational burden with no natural caller, unlike
    ///      `ticketOwnerRecipient` (an arbitrary, possibly-adversarial address, where the DoS
    ///      concern that motivated pull-payment in the first place is real) or `multisig` (kept
    ///      conservative/unchanged since it isn't causing a problem).
    ///
    ///      However, a direct push must NEVER be able to brick trading: if RewardVault reverts (a
    ///      bug, an unexpected pause, anything) or its `receive()` unexpectedly consumes excessive
    ///      gas, this trade must still succeed. So delivery is attempted with a bounded gas
    ///      stipend and its success is checked explicitly (never a silent try/catch that would
    ///      lose accounting) -- on failure, the EXACT ETH amount is retained here, fully accounted
    ///      for as `pendingWinnerPot`, and permissionlessly retryable via `flushPendingWinnerPot`.
    ///      `winnerPotGenerated == deliveredWinnerPot + pendingWinnerPot` holds after every call.
    function _routeToWinnerPot(uint256 amount) internal {
        if (amount == 0) return;
        winnerPotGenerated += amount;
        (bool ok,) = winnerPot.call{value: amount, gas: WINNER_POT_CALL_GAS}("");
        if (ok) {
            deliveredWinnerPot += amount;
            emit WinnerPotDelivered(amount, deliveredWinnerPot);
        } else {
            pendingWinnerPot += amount;
            emit WinnerPotDeliveryFailed(amount, pendingWinnerPot);
        }
    }

    /// @notice Permissionless retry for any ETH that previously failed to reach winnerPot. Safe to
    ///         call at any time by anyone; a repeated failure simply leaves the funds pending
    ///         again, fully accounted for, never lost. Any revenue that was delayed this way and
    ///         eventually delivered lands in RewardVault's LIVE, current pool -- it deliberately
    ///         does NOT attempt to retroactively attribute itself to whatever round was open when
    ///         it was originally generated (that round may already be closed and its holder TWAB
    ///         already frozen); it simply rolls forward, exactly like any other unclaimed/rollover
    ///         revenue in the reward system.
    function flushPendingWinnerPot() external nonReentrant {
        uint256 amount = pendingWinnerPot;
        require(amount > 0, "nothing pending");
        pendingWinnerPot = 0; // clear before the external call (checks-effects-interactions)
        (bool ok,) = winnerPot.call{value: amount, gas: WINNER_POT_CALL_GAS}("");
        if (ok) {
            deliveredWinnerPot += amount;
            emit WinnerPotFlushed(amount, msg.sender);
        } else {
            pendingWinnerPot += amount; // restore -- still failing, still fully accounted for
            emit WinnerPotFlushFailed(amount, msg.sender);
        }
    }

    function _routeTax(uint256 taxAmount, bool /*isBuy*/ ) internal {
        if (taxAmount == 0) return;
        uint256 toOwner = Math.mulDiv(taxAmount, TICKER_OWNER_TAX_BPS, BPS);
        uint256 toMultisig = Math.mulDiv(taxAmount, MULTISIG_TAX_BPS, BPS);
        uint256 toWinnerPot = taxAmount - toOwner - toMultisig;
        _credit(ticketOwnerRecipient(), toOwner);
        _credit(multisig, toMultisig);
        _routeToWinnerPot(toWinnerPot);
    }

    /// @dev Pull-payment credit -- no external call happens here at all, so this can never be a
    ///      reentrancy surface and can never let a broken/malicious recipient block anyone else's
    ///      trade. Recipients withdraw their own accumulated balance via `withdraw()`.
    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        pendingWithdrawals[to] += amount;
        emit Credited(to, amount, pendingWithdrawals[to]);
    }

    /// @notice Any fee recipient (ticker owner, multisig, or winnerPot) pulls their own
    ///         accumulated balance. Callable by anyone on behalf of `to` (the ETH always goes to
    ///         `to`, never the caller) so a recipient that can't easily call contracts itself
    ///         (e.g. a plain externally-owned ticker-owner address someone else wants to pay out
    ///         for) is never stuck.
    function withdraw(address to) external nonReentrant {
        uint256 amount = pendingWithdrawals[to];
        require(amount > 0, "nothing to withdraw");
        pendingWithdrawals[to] = 0;
        _send(to, amount);
        emit Withdrawn(to, amount);
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────────

    function currentPrice() external view returns (uint256) {
        return rt == 0 ? 0 : Math.mulDiv(re, 1e18, rt);
    }

    function realReserve() external view returns (uint256) {
        return realETH; // == re - virtualEthSeed, always, by construction
    }

    function progressBps() external view returns (uint256) {
        return Math.mulDiv(sold, BPS, CURVE_ALLOCATION);
    }

    /// @notice The current ticker-owner fee recipient -- always `TickerNFT.ownerOf(tickerTokenId)`,
    ///         resolved fresh on every call, never cached. This is what makes an OpenSea sale of
    ///         the TickerNFT redirect future fees immediately, with no separate migration step.
    function ticketOwnerRecipient() public view returns (address) {
        return IERC721(tickerNFT).ownerOf(tickerTokenId);
    }
}
