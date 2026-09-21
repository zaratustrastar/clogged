// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";

/// @title PoolManagerCustodyTwabTest
/// @notice Proves (not merely argues) that under the v4-native custody model - the full 1B
///         supply physically resident in PoolManager from launch, decreasing on real
///         TAKE_ALL withdrawals (buys) and increasing on real SETTLE_ALL deposits (sells) -
///         MemeToken.twabOf(POOL_MANAGER, ...) is exactly the correct "protocol/non-circulating
///         inventory" term for RewardVault's circulatingTwab = totalSupplyTwab - twabOf(market)
///         formula, with ZERO changes to MemeToken.sol itself.
///
/// @dev Deliberately does NOT deploy or mock PoolManager, the hook, or any swap logic. The
///      TWAB question is entirely about how MemeToken's own existing checkpoint system (in
///      _update, unchanged) behaves given realistic transfer patterns into and out of a single
///      address that plays PoolManager's role - so a plain address (`PM`, via makeAddr) standing
///      in as the setMarket() target, with buys/sells simulated as real MemeToken.transfer()
///      calls (exactly what a real TAKE_ALL/SETTLE_ALL physically performs), is sufficient to
///      prove the property and does not smuggle in any unproven assumption about the hook
///      itself. Corrected wording throughout: PM's balance is NOT "the full 1B forever" - it
///      is "1B at launch, decreasing on buys, increasing on sells" - i.e. exactly current
///      protocol inventory at every point in time.
contract PoolManagerCustodyTwabTest is Test {
    MemeToken token;
    address launcher = address(this);
    address PM = makeAddr("poolManager"); // stands in for PoolManager's own address
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MemeToken("Cat", "CAT", launcher);
    }

    /// @dev Simulates a real v4 buy's physical effect: PoolManager.take() transfers `amount`
    ///      of MemeToken from PM (real ERC20 balance, physically resident since launch) to the
    ///      end user - a real MemeToken.transfer() call, exactly what happens on real TAKE_ALL.
    function _simulateBuy(address user, uint256 amount) internal {
        vm.prank(PM);
        token.transfer(user, amount);
    }

    /// @dev Simulates a real v4 sell's physical effect: the router's SETTLE_ALL performs a real
    ///      transferFrom(user, PoolManager, amount) - physically returning tokens to PM.
    function _simulateSell(address user, uint256 amount) internal {
        vm.prank(user);
        token.transfer(PM, amount);
    }

    function _circulatingTwab(uint256 fromT, uint256 toT) internal view returns (uint256) {
        return token.totalSupplyTwab(fromT, toT) - token.twabOf(PM, fromT, toT);
    }

    // ── A: launch, nobody buys ───────────────────────────────────────────────

    function test_A_launchNobodyBuys_circulatingIsZero() public {
        token.setMarket(PM);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 days);
        uint256 t1 = block.timestamp;

        assertEq(token.totalSupplyTwab(t0, t1), TOTAL_SUPPLY, "total supply twab must be the full supply once launched");
        assertEq(token.twabOf(PM, t0, t1), TOTAL_SUPPLY, "PM must still hold the full supply - nobody bought");
        assertEq(_circulatingTwab(t0, t1), 0, "circulating must be exactly zero when nothing ever left PM");
    }

    // ── B: Alice buys, sole genuine holder ───────────────────────────────────

    function test_B_aliceSoleHolder_circulatingEqualsAliceTwab() public {
        token.setMarket(PM);
        uint256 buyAmount = 10_000_000e18;
        _simulateBuy(alice, buyAmount);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 7 days);
        uint256 t1 = block.timestamp;

        uint256 aliceTwab = token.twabOf(alice, t0, t1);
        assertEq(aliceTwab, buyAmount, "alice's own twab must equal exactly what she holds, held constant over the window");
        assertEq(_circulatingTwab(t0, t1), aliceTwab, "circulating must equal exactly alice's own twab when she is the sole real holder");
    }

    // ── C: Alice + Bob, both genuine holders ─────────────────────────────────

    function test_C_aliceAndBob_circulatingEqualsSumOfBothTwabs() public {
        token.setMarket(PM);
        uint256 aliceAmount = 4_000_000e18;
        uint256 bobAmount = 6_500_000e18;
        _simulateBuy(alice, aliceAmount);
        _simulateBuy(bob, bobAmount);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 3 days);
        uint256 t1 = block.timestamp;

        uint256 sumTwab = token.twabOf(alice, t0, t1) + token.twabOf(bob, t0, t1);
        assertEq(_circulatingTwab(t0, t1), sumTwab, "circulating must equal the sum of every genuine holder's own twab");
    }

    // ── D: Alice sells (partial), reserve/inventory correctly grows back ────

    function test_D_aliceSellsPartial_circulatingDropsAndPMInventoryGrowsBack() public {
        token.setMarket(PM);
        uint256 bought = 8_000_000e18;
        _simulateBuy(alice, bought);

        vm.warp(block.timestamp + 1 days);
        uint256 preSellPMBalance = token.balanceOf(PM);

        uint256 sold = 3_000_000e18;
        _simulateSell(alice, sold);

        assertEq(token.balanceOf(PM), preSellPMBalance + sold, "PM's real balance must grow back by exactly what alice sold - a real transferFrom, not a no-op");
        assertEq(token.balanceOf(alice), bought - sold, "alice's own remaining real balance");

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 5 days);
        uint256 t1 = block.timestamp;

        assertEq(_circulatingTwab(t0, t1), bought - sold, "circulating must reflect only what alice still genuinely holds after the sell");
    }

    // ── E: mid-round launch interacts correctly with the exclusion ──────────

    // Storage, not stack locals, for this test's own timestamps - see the comment on
    // _assertMidWindowLaunchInvariant for why: a reproducible via_ir stack-slot issue was
    // isolated (via step-by-step console2.log tracing) to stack-local timestamp arithmetic
    // interspersed with external calls in this specific pattern, and storage variables are
    // unambiguously immune to that class of issue.
    uint256 private _testWindowOpen;
    uint256 private _testWindowClose;

    function test_E_midWindowLaunch_preLaunchPortionIsZeroCirculatingRegardlessOfExclusion() public {
        // Window opens BEFORE the token/market even exists.
        _testWindowOpen = block.timestamp;
        vm.warp(_testWindowOpen + 2 days);
        token.setMarket(PM);
        _simulateBuy(alice, 5_000_000e18);
        _testWindowClose = _testWindowOpen + 6 days;
        vm.warp(_testWindowClose);
        _assertMidWindowLaunchInvariant();
    }

    /// @dev This project compiles with via_ir=true (required - BondingCurveClog.sol itself
    ///      hits "stack too deep" without it, confirmed directly: `FOUNDRY_VIA_IR=false forge
    ///      test` fails to even compile the existing production contracts, so via_ir cannot be
    ///      disabled project-wide to work around this). A reproducible miscompilation was
    ///      isolated in an earlier version of this test - a stack-local timestamp variable
    ///      read back a LATER value than it was ever assigned, after intervening external calls
    ///      (setMarket, transfer) - confirmed step-by-step via console2.log tracing showing the
    ///      exact value change, not assumed or guessed at. Storage variables (_testWindowOpen/
    ///      _testWindowClose above) avoid it entirely, which is what this rewritten version uses.
    function _assertMidWindowLaunchInvariant() internal view {
        uint256 totalTwab = token.totalSupplyTwab(_testWindowOpen, _testWindowClose);
        uint256 pmTwab = token.twabOf(PM, _testWindowOpen, _testWindowClose);
        uint256 aliceTwab = token.twabOf(alice, _testWindowOpen, _testWindowClose);

        // Time-weighted: 2 days at supply=0, then 4 days at supply=TOTAL_SUPPLY, over a 6 day
        // window => totalTwab = TOTAL_SUPPLY * 4/6.
        uint256 expectedTotalTwab = (TOTAL_SUPPLY * 4 days) / 6 days;
        assertApproxEqRel(totalTwab, expectedTotalTwab, 1e12, "existing pre-launch-zero behavior must be preserved exactly");

        // circulating = totalTwab - pmTwab must equal alice's own twab exactly, proving the
        // exclusion composes correctly with a mid-window launch rather than only working when
        // the market already existed for the entire window (test B/C's simpler case).
        assertEq(totalTwab - pmTwab, aliceTwab, "circulating across a mid-window launch must still equal exactly the real holder's own twab");
    }

    // ── F: user voluntarily wraps ERC20 into PM (simulating an ERC6909 claim) ─

    function test_F_voluntaryWrapIntoPM_losesHolderCreditWhileWrapped() public {
        token.setMarket(PM);
        uint256 bought = 6_000_000e18;
        _simulateBuy(alice, bought);
        vm.warp(block.timestamp + 1 days);

        // Alice voluntarily sends her OWN tokens back into PM's address (e.g. to receive an
        // ERC6909 claim in a real deployment) - physically indistinguishable, at the MemeToken
        // level, from a real sell; this is the accepted, deliberate conservatism from the
        // design notes.
        uint256 wrapped = 2_000_000e18;
        vm.prank(alice);
        token.transfer(PM, wrapped);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 2 days);
        uint256 t1 = block.timestamp;

        assertEq(token.twabOf(alice, t0, t1), bought - wrapped, "alice's own twab must reflect only her un-wrapped remainder");
        assertEq(_circulatingTwab(t0, t1), bought - wrapped, "the wrapped amount must NOT count as circulating/holder supply while wrapped");
    }

    // ── G: user unwraps back to real ERC20, holder credit resumes ───────────

    function test_G_unwrapBackToErc20_holderCreditResumes() public {
        token.setMarket(PM);
        uint256 bought = 6_000_000e18;
        _simulateBuy(alice, bought);
        uint256 wrapped = 2_000_000e18;
        vm.prank(alice);
        token.transfer(PM, wrapped);
        vm.warp(block.timestamp + 1 days);

        // Alice unwraps: a real transfer of the same amount back OUT of PM to her (mirroring
        // burn(alice, tokenId, wrapped) + take(tokenCurrency, alice, wrapped) in the real design).
        vm.prank(PM);
        token.transfer(alice, wrapped);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 2 days);
        uint256 t1 = block.timestamp;

        assertEq(token.twabOf(alice, t0, t1), bought, "alice's own twab must be back to her full original holding after unwrapping");
        assertEq(_circulatingTwab(t0, t1), bought, "circulating must resume counting the unwrapped amount as genuine holder supply");
    }

    // ── H: ordinary wallet-to-wallet transfers never affect PM's own twab ────

    function test_H_ordinaryWalletToWalletTransfer_pmTwabUnaffected_circulatingInvariant() public {
        token.setMarket(PM);
        uint256 bought = 5_000_000e18;
        _simulateBuy(alice, bought);
        vm.warp(block.timestamp + 1 days);

        uint256 pmBalanceBefore = token.balanceOf(PM);

        // Alice gives some of her own tokens to Bob - a genuine wallet-to-wallet transfer,
        // nothing to do with PM at all.
        uint256 gift = 1_500_000e18;
        vm.prank(alice);
        token.transfer(bob, gift);

        assertEq(token.balanceOf(PM), pmBalanceBefore, "PM's own balance must be completely unaffected by a transfer between two ordinary holders");

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 2 days);
        uint256 t1 = block.timestamp;

        // Circulating total is invariant under redistribution among real holders - only ITS
        // OWN composition (who holds how much) changes, not the total.
        assertEq(_circulatingTwab(t0, t1), bought, "circulating total must be unchanged by a wallet-to-wallet transfer, only its holder composition shifts");
        assertEq(token.twabOf(alice, t0, t1) + token.twabOf(bob, t0, t1), bought, "the gift must correctly redistribute twab between alice and bob, summing to the same total");
    }

    // ── I: PM shared across multiple, unrelated tokens ───────────────────────

    function test_I_sharedPoolManagerAddress_perTokenTwabIsCompletelyIndependent() public {
        // A second, completely unrelated MemeToken, using the SAME PM address as its own
        // market - simulating PoolManager's real role as a singleton shared by every v4 pool
        // across every ticker, never scoped to just one.
        MemeToken tokenTwo = new MemeToken("Dog", "DOG", launcher);

        token.setMarket(PM);
        tokenTwo.setMarket(PM);

        // Very different trading activity on each token against the SAME PM address.
        _simulateBuy(alice, 1_000_000e18); // token (CAT)

        vm.prank(PM);
        tokenTwo.transfer(bob, 900_000_000e18); // tokenTwo (DOG) - a much larger buy

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 3 days);
        uint256 t1 = block.timestamp;

        // token's (CAT's) own view of PM must reflect ONLY CAT's own balance history at PM,
        // completely unaffected by DOG's entirely separate, much larger balance movement
        // through the very same PM address.
        assertEq(token.twabOf(PM, t0, t1), TOTAL_SUPPLY - 1_000_000e18, "CAT's own twabOf(PM) must reflect only CAT's own balance, ignoring DOG entirely");
        assertEq(tokenTwo.twabOf(PM, t0, t1), TOTAL_SUPPLY - 900_000_000e18, "DOG's own twabOf(PM) must reflect only DOG's own balance, ignoring CAT entirely");

        assertEq(_circulatingTwab(t0, t1), 1_000_000e18, "CAT's own circulating figure must be exactly CAT's own real holder supply");
        uint256 dogCirculating = tokenTwo.totalSupplyTwab(t0, t1) - tokenTwo.twabOf(PM, t0, t1);
        assertEq(dogCirculating, 900_000_000e18, "DOG's own circulating figure must be exactly DOG's own real holder supply, independent of CAT's");
    }
}
