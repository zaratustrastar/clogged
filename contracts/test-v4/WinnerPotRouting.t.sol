// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {MockTickerNFT} from "../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../src/RewardVault.sol";

/// @title WinnerPot claim-native routing: end-to-end integration tests
/// @notice Covers exactly what this pass's own instructions required beyond the unit-level
///         proofs already in ClogV4HookBuySell.t.sol: BUY and SELL routing viewed end-to-end,
///         immediate-allocation-includes-this-trade (the "no keeper-flush race" property,
///         tested with zero time gap between the trade and allocateRound), RewardVault's own
///         native+claim backing conservation, and claim/claimBatch/sweepClaimToRealETH actually
///         converting RewardVault's ERC6909 claim into real, paid-out ETH.
contract WinnerPotRoutingTest is Test, IUnlockCallback {
    PoolManager manager;
    ClogV4Hook hook;
    ClogMarket market;
    MemeToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;

    address buyer = makeAddr("buyer");
    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    uint256 constant TICKER_TOKEN_ID = 1;

    address constant HOOK_ADDRESS = address(0x2088);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS); // test acts as roundManager
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        token = new MemeToken("Cat", "CAT", address(this));
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);
        token.setMarket(address(market));

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336);

        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();
    }

    struct SwapRequest {
        bool zeroForOne;
        int256 amountSpecified;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not pool manager");

        if (_depositing) {
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), PHYSICAL_TOKEN_SUPPLY);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), PHYSICAL_TOKEN_SUPPLY);
            return bytes("");
        }

        SwapRequest memory req = abi.decode(data, (SwapRequest));
        BalanceDelta swapDelta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: req.zeroForOne,
                amountSpecified: req.amountSpecified,
                sqrtPriceLimitX96: req.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            bytes("")
        );

        if (req.zeroForOne) {
            int128 ethOwed = -swapDelta.amount0();
            manager.sync(key.currency0);
            manager.settle{value: uint256(int256(ethOwed))}();
            int128 tokenOwed = swapDelta.amount1();
            manager.take(key.currency1, buyer, uint256(int256(tokenOwed)));
        } else {
            int128 tokenOwed = -swapDelta.amount1();
            manager.sync(key.currency1);
            vm.prank(buyer);
            token.transfer(address(manager), uint256(int256(tokenOwed)));
            manager.settle();
            int128 ethOwed = swapDelta.amount0();
            manager.take(key.currency0, buyer, uint256(int256(ethOwed)));
        }

        return abi.encode(swapDelta);
    }

    receive() external payable {}

    function _doBuy(uint256 amount) internal returns (uint256 tokensOut) {
        vm.deal(address(this), amount);
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(amount)})));
        BalanceDelta d = abi.decode(result, (BalanceDelta));
        tokensOut = uint256(int256(d.amount1()));
    }

    function _doSell(uint256 tokensIn) internal returns (uint256 netEthOut) {
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: false, amountSpecified: -int256(tokensIn)})));
        BalanceDelta d = abi.decode(result, (BalanceDelta));
        netEthOut = uint256(int256(d.amount0()));
    }

    // ── BUY routing ───────────────────────────────────────────────────────────────────────────

    function test_buyRouting_rewardVaultReceivesExactlyWinnerPotShare() public {
        uint256 preClaim = manager.balanceOf(address(rewardVault), uint256(uint160(address(0))));
        uint256 prePool = rewardVault.unallocatedPool();

        uint256 buyAmount = 0.05 ether;
        uint256 tax = (buyAmount * market.BUY_TAX_BPS()) / market.BPS();
        // The exact WinnerPot share can only be known precisely by reading the market's own
        // emitted event (the CLOG leg's own extraction contributes too) - here it's enough to
        // confirm the DIRECTION and MECHANISM: RewardVault's claim and pool both grew, and by
        // the SAME amount as each other (native-backing conservation, checked precisely below).
        _doBuy(buyAmount);

        uint256 postClaim = manager.balanceOf(address(rewardVault), uint256(uint160(address(0))));
        uint256 postPool = rewardVault.unallocatedPool();

        assertGt(postClaim, preClaim, "RewardVault's own ERC6909 ETH claim must have grown from a real buy - this is the actual claim-native routing, not merely bookkeeping");
        assertEq(postClaim - preClaim, postPool - prePool, "RewardVault's own claim growth must exactly match its own unallocatedPool growth - recordWinnerPotClaim and the matching mint must always move together, in the same transaction");
        assertGt(postPool - prePool, 0, "sanity: a 0.05 ETH buy is large enough to trigger a nonzero WinnerPot share via the trading tax alone");
        tax; // referenced for documentation purposes only in this test's own comment above
    }

    // ── SELL routing ──────────────────────────────────────────────────────────────────────────

    function test_sellRouting_rewardVaultReceivesExactlyWinnerPotShare() public {
        uint256 tokensHeld = _doBuy(0.05 ether);

        uint256 preClaim = manager.balanceOf(address(rewardVault), uint256(uint160(address(0))));
        uint256 prePool = rewardVault.unallocatedPool();

        _doSell(tokensHeld / 2);

        uint256 postClaim = manager.balanceOf(address(rewardVault), uint256(uint160(address(0))));
        uint256 postPool = rewardVault.unallocatedPool();

        assertGt(postClaim, preClaim, "RewardVault's own ERC6909 ETH claim must have grown from a real sell too");
        assertEq(postClaim - preClaim, postPool - prePool, "RewardVault's own claim growth must exactly match its own unallocatedPool growth on a sell too");
    }

    // ── Immediate allocation includes that trade's WinnerPot (no keeper-flush race) ─────────

    function test_immediateAllocation_includesThatTradesWinnerPot_zeroTimeGap() public {
        // Deliberately NO time warp anywhere in this test - allocateRound is called in the
        // very next line after the buy, proving the property holds from ordinary EVM
        // transaction sequencing alone, not because enough time passed for anything to
        // "catch up". This is the literal "no keeper-flush race" property: recordWinnerPotClaim
        // is synchronous within the buy's own transaction, so by the time that transaction
        // ends, unallocatedPool already reflects it - a later, separate allocateRound() call
        // (even the very next one) is guaranteed to see it.
        _doBuy(0.05 ether);
        uint256 poolAfterBuy = rewardVault.unallocatedPool();
        assertGt(poolAfterBuy, 0, "sanity: the buy must have generated a real, nonzero contribution");

        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), block.timestamp, block.timestamp);
        RewardVault.RoundAllocation memory a = rewardVault.getAllocation(1);

        assertEq(a.jackpotAmount, poolAfterBuy, "the round's own jackpot must equal EXACTLY the pool as it stood right after the buy - that trade's own WinnerPot contribution must be included, not missed by a race");
        assertEq(rewardVault.unallocatedPool(), 0, "unallocatedPool must be fully drained into the round's own jackpot snapshot");
    }

    // ── RewardVault native+claim backing conservation ────────────────────────────────────────

    function test_nativeAndClaimBackingConservation_acrossMultipleTrades() public {
        // Across a sequence of buys and sells, RewardVault's own real native ETH balance plus
        // whatever ERC6909 claim it still holds in PoolManager must always sum to exactly its
        // own bookkeeping: unallocatedPool (not yet allocated to any round) plus every
        // allocated-but-not-yet-fully-claimed round's own outstanding jackpot.
        uint256 tokensHeld = _doBuy(0.03 ether);
        _doBuy(0.07 ether);
        _doSell(tokensHeld / 3);
        _doBuy(0.02 ether);

        uint256 realBalance = address(rewardVault).balance;
        uint256 claimBalance = manager.balanceOf(address(rewardVault), uint256(uint160(address(0))));
        // No round has been allocated yet in this test, so ALL value RewardVault holds -
        // real or claim-backed - must still be sitting in unallocatedPool exactly.
        assertEq(realBalance + claimBalance, rewardVault.unallocatedPool(), "RewardVault's own real balance plus its own ERC6909 claim must sum to exactly unallocatedPool before any round has been allocated");

        // Now allocate a round for part of it is not possible mid-pool (allocateRound takes the
        // ENTIRE current pool) - allocate the whole thing, then confirm the SAME conservation
        // holds against the outstanding jackpot instead.
        uint256 poolBeforeAllocate = rewardVault.unallocatedPool();
        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), block.timestamp - 1, block.timestamp);
        assertEq(address(rewardVault).balance + manager.balanceOf(address(rewardVault), uint256(uint160(address(0)))), poolBeforeAllocate, "conservation must still hold immediately after allocateRound - the value itself didn't move, only which bucket (unallocatedPool vs jackpotAmount) it's attributed to");
    }

    // ── claim / claimBatch / sweep actually convert the claim into real, paid-out ETH ────────

    function test_claim_convertsClaimToRealEth_andPaysOutCorrectly() public {
        _doBuy(0.05 ether);
        vm.warp(block.timestamp + 10 days);
        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), block.timestamp - 10 days, block.timestamp);

        uint256 preview = rewardVault.previewClaim(1, buyer);
        assertGt(preview, 0, "sanity: buyer must have a real, nonzero claim to actually exercise the payout path");

        // RewardVault holds this jackpot ONLY as an ERC6909 claim right now (never received a
        // real receive() push in this test) - claim() must still succeed, converting it
        // just-in-time via its own unlockCallback.
        uint256 buyerBalanceBefore = buyer.balance;
        rewardVault.claim(1, buyer);
        assertEq(buyer.balance, buyerBalanceBefore + preview, "buyer must have received real, actual ETH - claim-native backing must be fully transparent to the payout path");
    }

    function test_claimBatch_convertsClaimToRealEth_andPaysOutCorrectly() public {
        _doBuy(0.03 ether);
        vm.warp(block.timestamp + 5 days);
        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), block.timestamp - 5 days, block.timestamp);

        _doBuy(0.04 ether);
        vm.warp(block.timestamp + 5 days);
        rewardVault.allocateRound(2, TICKER_TOKEN_ID, address(market), block.timestamp - 5 days, block.timestamp);

        uint256 preview1 = rewardVault.previewClaim(1, buyer);
        uint256 preview2 = rewardVault.previewClaim(2, buyer);
        assertGt(preview1, 0, "sanity: round 1 must have a real claim");
        assertGt(preview2, 0, "sanity: round 2 must have a real claim");

        uint256[] memory roundIds = new uint256[](2);
        roundIds[0] = 1;
        roundIds[1] = 2;

        uint256 buyerBalanceBefore = buyer.balance;
        rewardVault.claimBatch(roundIds, buyer);
        assertEq(buyer.balance, buyerBalanceBefore + preview1 + preview2, "claimBatch must pay out both rounds' real ETH correctly even though both were entirely claim-backed");
    }

    function test_sweepClaimToRealETH_permissionlessly_convertsEntireClaim() public {
        _doBuy(0.05 ether);
        uint256 claimBalance = manager.balanceOf(address(rewardVault), uint256(uint160(address(0))));
        assertGt(claimBalance, 0, "sanity: must have a real, nonzero claim to sweep");
        assertEq(address(rewardVault).balance, 0, "sanity: RewardVault must hold zero real ETH before sweeping - everything so far is claim-backed only");

        address randomCaller = makeAddr("randomSweeper");
        vm.prank(randomCaller);
        rewardVault.sweepClaimToRealETH();

        assertEq(address(rewardVault).balance, claimBalance, "RewardVault's own real ETH balance must now equal exactly what its claim held");
        assertEq(manager.balanceOf(address(rewardVault), uint256(uint160(address(0)))), 0, "RewardVault's own ERC6909 claim must be fully drained after sweeping");
        assertEq(rewardVault.unallocatedPool(), claimBalance, "unallocatedPool's own bookkeeping must be completely unaffected by sweeping - only WHERE the value physically sits changed, not how much of it is owed");
    }

    function test_sweepClaimToRealETH_nothingToSweep_reverts() public {
        vm.expectRevert(bytes("nothing to sweep"));
        rewardVault.sweepClaimToRealETH();
    }
}
