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

/// @title RewardVault's v4-mode inventory-holder logic (correction 3)
/// @notice In v4 mode the per-ticker ClogMarket is fully non-custodial - the real MemeToken
///         supply physically lives at PoolManager, not at the market - so RewardVault's
///         circulatingTwab (and the claim-exclusion check) must exclude PoolManager's own TWAB,
///         never the market's, once poolManager is configured. `a.market` itself must remain
///         the per-ticker ClogMarket regardless, since IHasToken(a.market).token() is still how
///         RewardVault resolves which MemeToken a round's TWAB queries run against.
contract RewardVaultV4ModeTest is Test, IUnlockCallback {
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
    uint256 windowOpen;
    uint256 windowClose;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS); // test acts as roundManager
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        // A real MemeToken, exactly as production uses - needed for its own real twabOf/
        // totalSupplyTwab, which MinimalMockToken (used elsewhere in this profile) doesn't
        // implement.
        token = new MemeToken("Cat", "CAT", address(this));
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);
        token.setMarket(address(market)); // mints the full 1B to the market, sets marketInitializedAt = now

        windowOpen = block.timestamp;

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336);

        // Real launch-time deposit: the market's own just-minted 1B moves into PoolManager -
        // this is the crux of what this test file exists to check: from this point on, the
        // unsold portion of the real 1B supply lives at PoolManager, not at the market.
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
            IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: req.amountSpecified, sqrtPriceLimitX96: 4295128740}),
            bytes("")
        );
        int128 ethOwed = -swapDelta.amount0();
        manager.sync(key.currency0);
        manager.settle{value: uint256(int256(ethOwed))}();
        int128 tokenOwed = swapDelta.amount1();
        manager.take(key.currency1, buyer, uint256(int256(tokenOwed)));
        return abi.encode(swapDelta);
    }

    receive() external payable {}

    function _doBuyAsBuyer(uint256 amount) internal {
        vm.deal(address(this), amount);
        manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(amount)})));
    }

    // ── per-token ClogMarket identity still resolves token() correctly ──────────────────────

    function test_perTokenClogMarketIdentity_stillResolvesTokenCorrectly() public view {
        assertEq(market.token(), address(token), "ClogMarket's own token() must still resolve to the real MemeToken - a.market's role as the IHasToken source is unchanged by v4 mode");
    }

    // ── sole genuine holder ≈ 100% ────────────────────────────────────────────────────────────

    function test_soleGenuineHolder_receivesApproximatelyFullJackpot() public {
        // Fund unallocatedPool the real way: a real buy whose WinnerPot share routes to
        // RewardVault via recordWinnerPotClaim, exactly as ClogV4Hook.beforeSwap performs it.
        _doBuyAsBuyer(0.05 ether);
        assertGt(rewardVault.unallocatedPool(), 0, "sanity: the buy above must have actually generated a nonzero WinnerPot contribution");

        // Advance time so the buy sits fully inside the round's own TWAB window with room to
        // spare (a long window makes the buyer's own post-buy holding period dominate the
        // window's average, so "approximately 100%" is a meaningful, non-trivial check here,
        // not just "nonzero").
        vm.warp(block.timestamp + 10 days);
        windowClose = block.timestamp;

        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), windowOpen, windowClose);

        uint256 preview = rewardVault.previewClaim(1, buyer);
        RewardVault.RoundAllocation memory a = rewardVault.getAllocation(1);
        assertGt(preview, 0, "the sole genuine holder must receive a real, nonzero share");
        // "Approximately 100%" - within a small tolerance of the full jackpot, since the buyer
        // held their tokens for essentially the entire window and PoolManager's own (unsold
        // inventory) TWAB is excluded from the denominator entirely.
        assertApproxEqRel(preview, a.jackpotAmount, 0.02e18, "the sole genuine holder must receive approximately the FULL jackpot once PoolManager's own inventory TWAB is correctly excluded from the denominator");
    }

    // ── previewClaim(round, poolManager) == 0 ────────────────────────────────────────────────

    function test_previewClaim_forPoolManager_isZero() public {
        _doBuyAsBuyer(0.05 ether);
        vm.warp(block.timestamp + 10 days);
        windowClose = block.timestamp;
        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), windowOpen, windowClose);

        assertEq(rewardVault.previewClaim(1, address(manager)), 0, "PoolManager itself, the v4 protocol inventory holder, must never preview a nonzero claim");
    }

    // ── claim(round, poolManager) cannot receive jackpot ─────────────────────────────────────

    function test_claim_forPoolManager_reverts() public {
        _doBuyAsBuyer(0.05 ether);
        vm.warp(block.timestamp + 10 days);
        windowClose = block.timestamp;
        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), windowOpen, windowClose);

        vm.expectRevert(bytes("protocol inventory cannot claim"));
        rewardVault.claim(1, address(manager));
    }

    // ── the market itself still cannot claim either, in v4 mode ─────────────────────────────

    function test_claim_forMarket_stillRevertsInV4Mode() public {
        _doBuyAsBuyer(0.05 ether);
        vm.warp(block.timestamp + 10 days);
        windowClose = block.timestamp;
        rewardVault.allocateRound(1, TICKER_TOKEN_ID, address(market), windowOpen, windowClose);

        vm.expectRevert(bytes("protocol inventory cannot claim"));
        rewardVault.claim(1, address(market));
    }
}
