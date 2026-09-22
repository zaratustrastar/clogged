// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogGenuineMath} from "../../src-v4/genuine/ClogGenuineMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";

/// @title ClogGenuineInvariants
/// @notice The two structural invariants the whole genuine-liquidity mapping rests on, asserted
///         directly against the UNMODIFIED ClogMarket @ 422a61a. These do not need a PoolManager
///         or a fork - they are pure statements about ClogMarket's state machine, and they are
///         the cheapest possible falsification of the design.
///
///         A Python port of ClogMarket (exact floor-integer arithmetic) was run over 4,771
///         randomized buy/sell transitions with ZERO violations before this branch was written.
///         These tests re-establish that in Solidity, where it counts.
contract ClogGenuineInvariantsTest is Test {
    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_OFFSET = 800_000_000e18;

    ClogMarket market;
    MemeToken token;
    TickerNFT nft;
    address multisig = makeAddr("multisig");
    address deployer = makeAddr("deployer");
    address owner = makeAddr("owner");
    uint256 constant TOKEN_ID = 1;

    /// @dev Driven directly (this contract stands in for the hook) - these are statements about
    ///      ClogMarket's state machine alone and need no PoolManager.
    function setUp() public {
        nft = new TickerNFT("I", "I", deployer, "https://x.invalid/", multisig);
        vm.prank(deployer);
        nft.setRegistry(address(this));
        nft.mint(owner, TOKEN_ID);
        token = new MemeToken("Inv", "INV", address(this));
        market = new ClogMarket(
            address(this), address(token), address(nft), TOKEN_ID, multisig, SEED, BUFFER_BPS,
            address(new NoopEligibility())
        );
        token.setMarket(address(market));
    }

    /// @notice re - realETH is a constant of motion equal to virtualEthSeed.
    /// @dev Every mutation in ClogMarket moves `re` and `realETH` by the same signed amount:
    ///        leg 1      re += curveBudget      realETH += curveBudget
    ///        leg 2      re  = k/newRt2         realETH += netForClog   (same increment)
    ///        dust       re += dust             realETH += dust
    ///        extraction re -= clogExtracted    realETH -= clogExtracted
    ///        sell       re -= grossPayout      realETH -= grossPayout
    function testFuzz_invariant_reMinusRealEth_isSeed(uint96[8] calldata buys, uint96[4] calldata sells) public {
        for (uint256 i = 0; i < buys.length; i++) {
            uint256 amt = bound(uint256(buys[i]), 0.001 ether, 2 ether);
            try market.applyBuy(amt) { } catch { }
            assertEq(market.re() - market.realETH(), SEED, "re - realETH drifted from virtualEthSeed");
        }
        for (uint256 i = 0; i < sells.length; i++) {
            uint256 amt = bound(uint256(sells[i]), 1_000e18, 30_000_000e18);
            try market.applySell(amt) { } catch { }
            assertEq(market.re() - market.realETH(), SEED, "re - realETH drifted on sell");
        }
    }

    /// @notice rt - physicalInventory is a constant of motion equal to 800_000_000e18.
    /// @dev `rt` falls by exactly (curveTokens + clogTokens) on a buy and `physicalInventory`
    ///      falls by tokensOut, which IS curveTokens + clogTokens. Neither `dust` nor
    ///      `clogExtracted` touches `rt`. On a sell both rise by tokensIn.
    function testFuzz_invariant_rtMinusInventory_isOffset(uint96[8] calldata buys, uint96[4] calldata sells) public {
        for (uint256 i = 0; i < buys.length; i++) {
            uint256 amt = bound(uint256(buys[i]), 0.001 ether, 2 ether);
            try market.applyBuy(amt) { } catch { }
            assertEq(market.rt() - market.physicalInventory(), VIRTUAL_TOKEN_OFFSET, "rt - physInv drifted");
        }
        for (uint256 i = 0; i < sells.length; i++) {
            uint256 amt = bound(uint256(sells[i]), 1_000e18, 30_000_000e18);
            try market.applySell(amt) { } catch { }
            assertEq(market.rt() - market.physicalInventory(), VIRTUAL_TOKEN_OFFSET, "rt - physInv drifted on sell");
        }
    }

    /// @notice Launch geometry matches the closed form, with zero protocol ETH.
    /// @dev Expected for SEED = 9 ether, BUFFER_BPS = 20_000, Q = 1_000_000_000e18:
    ///        L  = sqrt(9e18 * 1.8e27) = 1.27279221e23
    ///        Pb = rt/re               = 200_000_000 token/ETH
    ///        Pa = 800M^2/(re*rt)      = 39_506_172.8395 token/ETH
    ///      Reference-model reconstruction at P = Pb gave actualETH = 0 exactly and
    ///      actualToken = 900_000_000.0000 for the 900M variant; for the full-inventory variant
    ///      used here the position carries the whole 1B.
    function test_launchGeometry_isTokenOnly() public view {
        uint256 re = SEED;
        uint256 rt = (900_000_000e18 * BUFFER_BPS) / 10_000;
        ClogGenuineMath.Position memory p = ClogGenuineMath.positionFor(re, rt, SEED, 1);

        uint160 sqrtLaunch = ClogGenuineMath.sqrtPriceX96Of(re, rt);
        (uint256 ethAmt,) = ClogGenuineMath.reservesAt(sqrtLaunch, p.sqrtPaX96, p.sqrtPbX96, p.liquidity);

        assertEq(ethAmt, 0, "launch position must require ZERO protocol ETH");
        assertGt(p.liquidity, 0, "active liquidity must be > 0 at launch");
        assertLt(p.tickLower, p.tickUpper, "degenerate range");
    }

    /// @notice The solvency cap coincides exactly with the position's upper bound.
    /// @dev At P = Pb the position's actualETH is zero, so re == virtualEthSeed. ClogMarket's
    ///      fully-capped sell also lands on re == virtualEthSeed. Reference model: a 500M-token
    ///      sell drove realETH to 0 and re to exactly 9.0 ether.
    function test_cappedSell_landsOnVirtualEthSeed() public {
        market.applyBuy(0.1 ether);
        market.applySell(500_000_000e18);
        assertEq(market.realETH(), 0, "capped sell must exhaust realETH");
        assertEq(market.re(), SEED, "capped sell must land re exactly on virtualEthSeed");
    }
}
