// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {MockTickerNFT} from "./mocks/MockTickerNFT.sol";

/// @notice Configurable mock standing in for RewardVault: can be toggled to revert on receive, or
///         to burn gas, to prove BondingCurveClog trading survives either failure mode.
contract MockRewardVaultFailureModes {
    bool public shouldRevert;
    bool public shouldBurnGas;
    uint256 public received;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setShouldBurnGas(bool v) external {
        shouldBurnGas = v;
    }

    receive() external payable {
        if (shouldRevert) revert("RewardVault: intentionally broken");
        if (shouldBurnGas) {
            // Attempt to consume far more than BondingCurveClog's gas stipend allows.
            uint256 i = 0;
            while (true) {
                i++;
                if (i > 10_000_000) break; // safety bound so the test itself doesn't hang forever
            }
        }
        received += msg.value;
    }
}

contract WinnerPotLivenessTest is Test {
    MemeToken token;
    BondingCurveClog market;
    MockRewardVaultFailureModes vault;

    address governance = address(0x60401);
    address ticketOwner = address(0x71CE);
    address multisig = address(0xA51);
    address alice = address(0xA11CE);

    uint256 virtualEthSeed;
    uint256 constant BUFFER_BPS = 20_000;

    function setUp() public {
        vault = new MockRewardVaultFailureModes();
        uint256 virtualTokenSeed = (900_000_000e18 * BUFFER_BPS) / 10_000;
        virtualEthSeed = (5e9 * virtualTokenSeed) / 1e18;

        MockTickerNFT tickerNFT = new MockTickerNFT();
        token = new MemeToken("Cat", "CAT", address(this));
        tickerNFT.setOwner(1, ticketOwner);
        EligibilityRegistry engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        market = new BondingCurveClog(
            address(token),
            address(tickerNFT),
            1,
            multisig,
            address(vault),
            governance,
            address(engine),
            virtualEthSeed,
            BUFFER_BPS
        );
        token.setMarket(address(market));
        uint256 registeredId = engine.registerToken(address(market));
        require(registeredId == 1, "token id mismatch");

        vm.deal(alice, 100 ether);
    }

    function test_invariant_generatedEqualsDeliveredPlusPending_normalOperation() public {
        vm.prank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);
        assertEq(market.winnerPotGenerated(), market.deliveredWinnerPot() + market.pendingWinnerPot());
        assertGt(market.deliveredWinnerPot(), 0);
        assertEq(market.pendingWinnerPot(), 0, "nothing should be pending when RewardVault behaves normally");
    }

    function test_revertingRewardVault_buyStillSucceeds() public {
        vault.setShouldRevert(true);
        vm.prank(alice);
        // Must NOT revert, despite RewardVault reverting on every attempted delivery.
        market.buy{value: 1 ether}(0, block.timestamp);
    }

    function test_revertingRewardVault_ethIsNotLost_becomesExactlyPending() public {
        vault.setShouldRevert(true);
        uint256 contractBalBefore = address(market).balance;

        vm.prank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);

        uint256 generated = market.winnerPotGenerated();
        assertGt(generated, 0);
        assertEq(market.deliveredWinnerPot(), 0, "delivery must have failed");
        assertEq(market.pendingWinnerPot(), generated, "the exact generated amount must be pending");
        assertEq(
            market.winnerPotGenerated(),
            market.deliveredWinnerPot() + market.pendingWinnerPot(),
            "winnerPotGenerated == deliveredWinnerPot + pendingWinnerPot must hold"
        );
        // The ETH itself must still be sitting in the market's own balance, not vanished.
        assertEq(address(market).balance, contractBalBefore + 1 ether, "no ETH lost -- it's all still in the contract");
        assertEq(vault.received(), 0, "RewardVault never actually received anything");
    }

    function test_gasGriefingRewardVault_buyStillSucceedsWithinGasStipend() public {
        vault.setShouldBurnGas(true);
        vm.prank(alice);
        // The bounded gas stipend on the winnerPot call must prevent this from consuming the
        // whole transaction's gas -- the call fails cheaply (out of the allotted 50k gas) rather
        // than dragging the entire buy transaction toward the block gas limit.
        market.buy{value: 1 ether}(0, block.timestamp);
        assertGt(
            market.pendingWinnerPot(),
            0,
            "the gas-griefing attempt must show up as a failed delivery, not silently vanish"
        );
    }

    function test_permissionlessFlush_retrySucceedsOnceRewardVaultRecovers() public {
        vault.setShouldRevert(true);
        vm.prank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);
        uint256 pendingBefore = market.pendingWinnerPot();
        assertGt(pendingBefore, 0);

        vault.setShouldRevert(false); // RewardVault "recovers"

        // Flush is callable by ANYONE, not just governance or the original trader.
        address randomCaller = address(0xF00D);
        vm.prank(randomCaller);
        market.flushPendingWinnerPot();

        assertEq(market.pendingWinnerPot(), 0, "pending must clear on successful flush");
        assertEq(market.deliveredWinnerPot(), pendingBefore, "the full pending amount must now be delivered");
        assertEq(vault.received(), pendingBefore, "RewardVault must have actually received the ETH");
        assertEq(market.winnerPotGenerated(), market.deliveredWinnerPot() + market.pendingWinnerPot());
    }

    function test_permissionlessFlush_stillFailingLeavesItPendingAgain_notLost() public {
        vault.setShouldRevert(true);
        vm.prank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);
        uint256 pendingBefore = market.pendingWinnerPot();

        // Flush attempted while RewardVault is STILL broken.
        market.flushPendingWinnerPot();

        assertEq(
            market.pendingWinnerPot(), pendingBefore, "still-failing flush must restore the exact same pending amount"
        );
        assertEq(market.deliveredWinnerPot(), 0);
        assertEq(market.winnerPotGenerated(), market.deliveredWinnerPot() + market.pendingWinnerPot());
    }

    function test_flush_revertsWithNothingPending() public {
        vm.expectRevert();
        market.flushPendingWinnerPot();
    }

    function test_multipleFailedDeliveries_accumulateCorrectly() public {
        vault.setShouldRevert(true);
        vm.startPrank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);
        market.buy{value: 1 ether}(0, block.timestamp);
        market.buy{value: 1 ether}(0, block.timestamp);
        vm.stopPrank();

        uint256 pending = market.pendingWinnerPot();
        assertGt(pending, 0);
        assertEq(market.winnerPotGenerated(), pending);

        vault.setShouldRevert(false);
        market.flushPendingWinnerPot();
        assertEq(market.deliveredWinnerPot(), pending, "one flush must recover ALL accumulated pending revenue at once");
    }

    function test_pendingWinnerPotDoesNotBreakSolvencyInvariant() public {
        vault.setShouldRevert(true);
        vm.prank(alice);
        market.buy{value: 1 ether}(0, block.timestamp);
        // realETH accounting (curve backing) must be completely unaffected by pending winnerPot
        // revenue sitting in the same contract balance -- they are accounted separately.
        assertGe(address(market).balance, market.realETH(), "actual balance must still cover realETH");
    }
}
