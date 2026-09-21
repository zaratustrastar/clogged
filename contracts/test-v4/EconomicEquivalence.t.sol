// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {MockTickerNFT} from "../test/mocks/MockTickerNFT.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";

/// @title Economic-equivalence harness: ClogMarket (v4) vs production BondingCurveClog
/// @notice Deploys BOTH systems with IDENTICAL initial parameters, drives them through the
///         EXACT SAME sequence of buy/sell trades, and asserts every piece of economic state
///         matches exactly after every single trade - not just at the end. This is deliberately
///         a comparison of the STATE MACHINE only: ClogMarket is called directly here
///         (this test contract acts as its own "hook", since ClogMarket's onlyHook check is
///         satisfied by whoever its constructor names), bypassing PoolManager entirely. The
///         custody/claim mechanism (mint/burn inside beforeSwap, per-market isolation,
///         registration validation) is proven separately and extensively elsewhere in this
///         v4 profile (ClogV4HookBuySell.t.sol, CrossMarketIsolation.t.sol,
///         MarketRegistration.t.sol) - mixing that proof into this one would only make a
///         genuine numerical mismatch harder to isolate.
///
/// @dev Compared explicitly after every trade: re, rt, k, sold, hwm, clogRemaining, rtCeiling,
///      realETH, pendingWithdrawals[ticketOwner], pendingWithdrawals[multisig], and the
///      per-trade output itself (totalTokensOut on a buy, netEthOut on a sell). WinnerPot is
///      compared as production's own winnerPotGenerated (cumulative ETH ever routed toward
///      winnerPot, delivered or not - confirmed directly against source) against ClogMarket's
///      own winnerPotLiability accumulator - the two are the correct analogs of each other even
///      though production pushes directly and ClogMarket tracks a liability pending the
///      still-deferred WinnerPot-routing integration (see ClogMarket.sol's own docs).
///
/// @dev NOT covered by this harness, explicitly: ticker-owner-fee via live
///      TickerNFT.ownerOf() (production resolves it dynamically every trade; ClogMarket uses a
///      fixed address for this slice - held constant here specifically so the comparison stays
///      apples-to-apples, not because the two are equivalent in that respect); the sell-side
///      solvency cap under conditions where the two systems' realETH has already diverged for
///      any other reason (they never should, per this harness, but the cap's OWN behavior under
///      a genuine mismatch is not what this harness is testing).
contract EconomicEquivalenceTest is Test {
    BondingCurveClog production;
    MemeToken productionToken;
    MockTickerNFT tickerNFT;
    EligibilityRegistry engine;

    ClogMarket v4Market;

    address ticketOwner = makeAddr("ticketOwner");
    address multisig = makeAddr("multisig");
    address winnerPot = makeAddr("winnerPot");
    address governance = makeAddr("governance");

    uint256 constant BUFFER_BPS = 20_000; // 2.0x, Config G - identical to production's own test fixtures
    uint256 virtualTokenSeed = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 virtualEthSeed;

    function setUp() public {
        // ── Production system - EXACT same construction pattern as BondingCurveClog.t.sol ──
        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(1, ticketOwner);

        productionToken = new MemeToken("Cat", "CAT", address(this));
        virtualEthSeed = (5e9 * virtualTokenSeed) / 1e18; // P0 = 5e-9 ETH/token, scaled - identical to production's own test fixtures

        engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);

        production = new BondingCurveClog(
            address(productionToken), address(tickerNFT), 1, multisig, winnerPot, governance, address(engine), virtualEthSeed, BUFFER_BPS
        );
        productionToken.setMarket(address(production));
        engine.registerToken(address(production));

        // ── v4 ClogMarket - IDENTICAL initial parameters, this test contract as its own hook ──
        v4Market = new ClogMarket(address(this), address(productionToken), ticketOwner, multisig, virtualEthSeed, BUFFER_BPS);

        vm.deal(address(this), 10_000 ether);
        productionToken.approve(address(production), type(uint256).max);
    }

    receive() external payable {}

    /// @dev Asserts every piece of comparable economic state matches exactly between the two
    ///      systems - the core repeated check this whole harness exists to run after every trade.
    function _assertFullEquivalence(string memory context) internal view {
        assertEq(production.re(), v4Market.re(), string.concat(context, ": re mismatch"));
        assertEq(production.rt(), v4Market.rt(), string.concat(context, ": rt mismatch"));
        assertEq(production.k(), v4Market.k(), string.concat(context, ": k mismatch"));
        assertEq(production.sold(), v4Market.sold(), string.concat(context, ": sold mismatch"));
        assertEq(production.hwm(), v4Market.hwm(), string.concat(context, ": hwm mismatch"));
        assertEq(production.clogRemaining(), v4Market.clogRemaining(), string.concat(context, ": clogRemaining mismatch"));
        assertEq(production.rtCeiling(), v4Market.rtCeiling(), string.concat(context, ": rtCeiling mismatch"));
        assertEq(production.realETH(), v4Market.realETH(), string.concat(context, ": realETH mismatch"));
        assertEq(production.pendingWithdrawals(ticketOwner), v4Market.pendingWithdrawals(ticketOwner), string.concat(context, ": ticker owner pendingWithdrawals mismatch"));
        assertEq(production.pendingWithdrawals(multisig), v4Market.pendingWithdrawals(multisig), string.concat(context, ": multisig pendingWithdrawals mismatch"));
        assertEq(production.winnerPotGenerated(), v4Market.winnerPotLiability(), string.concat(context, ": WinnerPot total (generated vs liability) mismatch"));
    }

    function test_initialState_matchesExactly() public view {
        _assertFullEquivalence("initial state");
    }

    function test_singleBuy_matchesExactly() public {
        uint256 buyAmount = 0.05 ether; // large enough to trigger a real CLOG-leg release in both systems
        uint256 productionTokensOut = production.buy{value: buyAmount}(0, block.timestamp);
        (uint256 v4TokensOut,) = v4Market.applyBuy(buyAmount);

        assertEq(productionTokensOut, v4TokensOut, "a single buy's own token output must match exactly");
        _assertFullEquivalence("after one buy");
    }

    function test_buyThenPartialSell_matchesExactly() public {
        uint256 buyAmount = 0.05 ether;
        uint256 productionTokensOut = production.buy{value: buyAmount}(0, block.timestamp);
        (uint256 v4TokensOut,) = v4Market.applyBuy(buyAmount);
        assertEq(productionTokensOut, v4TokensOut, "sanity: buy outputs must match before testing the sell");
        _assertFullEquivalence("after the buy, before the sell");

        uint256 sellAmount = productionTokensOut / 2;
        (uint256 productionNetEthOut,) = production.sell(sellAmount, 0, block.timestamp);
        (uint256 v4NetEthOut,,) = v4Market.applySell(sellAmount);

        assertEq(productionNetEthOut, v4NetEthOut, "a single sell's own net ETH output must match exactly");
        _assertFullEquivalence("after the buy and the partial sell");
    }

    /// @notice The main harness: a longer, realistic sequence of buys and sells of varying
    ///         sizes, driving BOTH systems through many rounds of CLOG-leg activity
    ///         (releases, extraction, the safety floor) and checking full equivalence after
    ///         EVERY single trade, not just at the end - a mismatch introduced by any one step
    ///         must be caught at that exact step, not averaged away by a final-state-only check.
    function test_longRealisticSequence_matchesExactlyAfterEveryTrade() public {
        uint256[10] memory buySizes = [
            uint256(0.01 ether), 0.05 ether, 0.1 ether, 0.003 ether, 0.2 ether, 0.02 ether, 0.5 ether, 0.008 ether, 0.15 ether, 0.03 ether
        ];

        uint256[] memory tokensFromEachBuy = new uint256[](buySizes.length);

        for (uint256 i = 0; i < buySizes.length; i++) {
            uint256 productionTokensOut = production.buy{value: buySizes[i]}(0, block.timestamp);
            (uint256 v4TokensOut,) = v4Market.applyBuy(buySizes[i]);
            assertEq(productionTokensOut, v4TokensOut, string.concat("buy #", vm.toString(i), ": token output mismatch"));
            tokensFromEachBuy[i] = productionTokensOut;
            _assertFullEquivalence(string.concat("after buy #", vm.toString(i)));
        }

        // Now sell back varying fractions, interleaved, exercising the solvency-cap branch
        // identically in both systems wherever it happens to trigger.
        uint256[10] memory sellFractionsBps = [uint256(3000), 5000, 10000, 2000, 7000, 4000, 10000, 1000, 6000, 10000]; // out of 10_000

        for (uint256 i = 0; i < sellFractionsBps.length; i++) {
            uint256 sellAmount = (tokensFromEachBuy[i] * sellFractionsBps[i]) / 10_000;
            if (sellAmount == 0) continue;
            (uint256 productionNetEthOut,) = production.sell(sellAmount, 0, block.timestamp);
            (uint256 v4NetEthOut,,) = v4Market.applySell(sellAmount);
            assertEq(productionNetEthOut, v4NetEthOut, string.concat("sell #", vm.toString(i), ": net ETH output mismatch"));
            _assertFullEquivalence(string.concat("after sell #", vm.toString(i)));
        }

        // Final sanity: clogRemaining should have moved from its initial value at all, or this
        // whole harness never actually exercised the CLOG leg it claims to be checking.
        assertLt(v4Market.clogRemaining(), v4Market.CLOG_ALLOCATION(), "sanity: this sequence must have actually released real CLOG tokens in both systems, or the harness proves nothing about CLOG-leg equivalence");
    }
}
