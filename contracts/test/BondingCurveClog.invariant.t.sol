// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {MockTickerNFT} from "./mocks/MockTickerNFT.sol";

/// @notice Handler that performs random, bounded buy/sell actions against the market, tracking
///         whether any action ever violated the two core solvency invariants directly (as a
///         belt-and-suspenders check in addition to the invariant assertions in the test contract
///         itself, which re-check state after every call in the sequence).
contract Handler is Test {
    BondingCurveClog public market;
    MemeToken public token;
    address[] public actors;

    uint256 public ghost_totalEthIn;
    uint256 public ghost_totalEthOutToActors;
    bool public ghost_everSawUnderflowRisk;

    constructor(BondingCurveClog market_, MemeToken token_) {
        market = market_;
        token = token_;
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(0x1000 + i));
            actors.push(a);
            vm.deal(a, 10_000 ether);
        }
    }

    function buy(uint256 actorSeed, uint256 ethAmount) external {
        address actor = actors[actorSeed % actors.length];
        ethAmount = bound(ethAmount, 0.0001 ether, 3 ether);

        vm.prank(actor);
        try market.buy{value: ethAmount}(0, block.timestamp) returns (uint256) {
            ghost_totalEthIn += ethAmount;
        } catch {
            // Oversized/edge-case buys reverting cleanly is acceptable and expected sometimes
            // (see test_buy_exceedingInventory_revertsCleanly) -- not a failure of this handler.
        }
    }

    function sell(uint256 actorSeed, uint256 fractionBps) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = token.balanceOf(actor);
        if (bal == 0) return;
        fractionBps = bound(fractionBps, 1, 10_000);
        uint256 amount = (bal * fractionBps) / 10_000;
        if (amount == 0) return;

        vm.startPrank(actor);
        token.approve(address(market), amount);
        uint256 balBefore = actor.balance;
        try market.sell(amount, 0, block.timestamp) returns (uint256 netEthOut, bool) {
            ghost_totalEthOutToActors += netEthOut;
            // Direct, redundant check: the actor's balance must have increased by exactly netEthOut.
            if (actor.balance != balBefore + netEthOut) {
                ghost_everSawUnderflowRisk = true;
            }
        } catch {
            // reverts are fine (e.g. dust amounts); just not a solvency violation
        }
        vm.stopPrank();
    }
}

contract BondingCurveClogInvariantTest is Test {
    MemeToken token;
    BondingCurveClog market;
    Handler handler;

    address governance = address(0x60401);
    address ticketOwner = address(0x71CE);
    address multisig = address(0xA51);
    address winnerPot = address(0xB0B0);

    uint256 constant BUFFER_BPS = 20_000;
    uint256 virtualTokenSeed = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 virtualEthSeed;

    function setUp() public {
        MockTickerNFT tickerNFT = new MockTickerNFT();
        token = new MemeToken("Cat", "CAT", address(this));
        virtualEthSeed = (5e9 * virtualTokenSeed) / 1e18;
        tickerNFT.setOwner(1, ticketOwner);
        EligibilityRegistry engine = new EligibilityRegistry(address(this));
        market = new BondingCurveClog(
            address(token), address(tickerNFT), 1, multisig, winnerPot, governance, address(engine), virtualEthSeed, BUFFER_BPS
        );
        token.setMarket(address(market));
        uint256 registeredId = engine.registerToken(address(market));
        require(registeredId == 1, "token id mismatch");

        handler = new Handler(market, token);
        targetContract(address(handler));
    }

    /// @notice The load-bearing bookkeeping invariant: `re` must always equal
    ///         `virtualEthSeed + realETH`, after ANY sequence of buys and sells.
    function invariant_reAlwaysMatchesVirtualSeedPlusRealETH() public view {
        assertEq(
            market.re(),
            virtualEthSeed + market.realETH(),
            "re drifted from virtualEthSeed + realETH -- ledger is no longer honest"
        );
    }

    /// @notice The contract's ACTUAL ETH balance must always be >= realETH (it can hold dust it
    ///         hasn't attributed yet, e.g. from rounding, but must never owe more than it holds).
    function invariant_actualBalanceCoversRealETH() public view {
        assertGe(
            address(market).balance,
            market.realETH(),
            "contract's actual ETH balance fell below its own honest ledger of real reserve"
        );
    }

    /// @notice CLOG inventory can only shrink, never exceed its starting allocation.
    function invariant_clogNeverExceedsAllocation() public view {
        assertLe(market.clogRemaining(), 100_000_000e18, "CLOG remaining exceeds its original allocation");
    }

    /// @notice High-water mark is monotonic non-decreasing.
    uint256 internal lastSeenHwm;

    function invariant_hwmMonotonic() public {
        uint256 current = market.hwm();
        assertGe(current, lastSeenHwm, "hwm decreased -- cycling protection is broken");
        lastSeenHwm = current;
    }

    /// @notice The handler's own direct bookkeeping check never flagged a discrepancy.
    function invariant_handlerNeverSawUnderflowRisk() public view {
        assertFalse(handler.ghost_everSawUnderflowRisk(), "a sell paid the actor a different amount than recorded");
    }
}
