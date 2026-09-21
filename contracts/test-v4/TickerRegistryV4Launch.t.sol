// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {TickerRegistryV4} from "../src-v4/TickerRegistryV4.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @title End-to-end atomic v4 launch: full deployment sequence + real commit/reveal + immediate trading
/// @notice Proves the ENTIRE v4 launch flow, not just its individual pieces: a real, CREATE2-
///         mined hook (via HookMiner, no vm.etch anywhere in this file), the deployment order
///         that breaks both circular dependencies (hook<->RewardVault, TickerRegistryV4<->hook)
///         documented in TickerRegistryV4.sol's own header, a real commit/reveal cycle, and -
///         critically - a REAL trade executed immediately after launch through the market
///         reveal() itself just deployed, proving the atomic launch didn't merely create
///         inert contracts but a fully wired, tradeable market in one transaction.
contract TickerRegistryV4LaunchTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    PoolManager manager;
    ClogV4Hook hook;
    RewardVault rewardVault;
    TickerRegistryV4 registry;
    TickerNFT tickerNFT;
    EligibilityRegistry eligibility;

    address deployer = address(this);
    address multisig = makeAddr("multisig");
    address roundManager = makeAddr("roundManager");
    address launcher = makeAddr("launcher");

    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_BPS = 20_000;

    function setUp() public {
        manager = new PoolManager(address(this));

        // ── TickerRegistryV4 first - its constructor needs no v4 infrastructure at all ──────
        eligibility = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        // TickerNFT needs a real base URI/multisig too, mirroring production's own usage.
        tickerNFT = new TickerNFT("Clog V4 Tickers", "CLOGV4", deployer, "https://example.invalid/", multisig);

        registry = new TickerRegistryV4(address(eligibility), address(tickerNFT), multisig, VIRTUAL_ETH_SEED, BUFFER_BPS);

        // ── Mine and deploy the REAL hook, launchInitializer = the registry's own address ──
        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(ClogV4Hook).creationCode, abi.encode(IPoolManager(address(manager)), address(registry)));
        bytes32 initCodeHash = HookMiner.hashInitCode(creationCodeWithArgs);
        (, bytes32 salt) = HookMiner.find(vm, address(this), initCodeHash, 200_000);
        hook = new ClogV4Hook{salt: salt}(IPoolManager(address(manager)), address(registry));
        assertEq(uint160(address(hook)) & HookMiner.ALL_HOOK_MASK, HookMiner.REQUIRED_FLAGS, "sanity: the real mined-and-deployed hook must have the exact required permission bits");

        // ── RewardVault, now that the hook's real address is known ─────────────────────────
        rewardVault = new RewardVault(roundManager, address(manager), address(hook));

        // ── Break both circular dependencies in the documented order ───────────────────────
        registry.setV4Infrastructure(address(manager), address(hook), address(rewardVault));
        tickerNFT.setRegistry(address(registry));

        vm.deal(launcher, 10 ether);
    }

    // ── Everything past this point is what a real router does, needed only to prove the
    //    freshly-launched market is genuinely tradeable, not the launch flow itself ──────────

    struct SwapRequest {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not pool manager");
        SwapRequest memory req = abi.decode(data, (SwapRequest));
        BalanceDelta swapDelta = manager.swap(
            req.key,
            IPoolManager.SwapParams({
                zeroForOne: req.zeroForOne,
                amountSpecified: req.amountSpecified,
                sqrtPriceLimitX96: req.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            bytes("")
        );

        if (req.zeroForOne) {
            int128 ethOwed = -swapDelta.amount0();
            manager.sync(req.key.currency0);
            manager.settle{value: uint256(int256(ethOwed))}();
            int128 tokenOwed = swapDelta.amount1();
            manager.take(req.key.currency1, address(this), uint256(int256(tokenOwed)));
        } else {
            int128 tokenOwed = -swapDelta.amount1();
            manager.sync(req.key.currency1);
            IERC20Like(Currency.unwrap(req.key.currency1)).transfer(address(manager), uint256(int256(tokenOwed)));
            manager.settle();
            int128 ethOwed = swapDelta.amount0();
            manager.take(req.key.currency0, address(this), uint256(int256(ethOwed)));
        }

        return abi.encode(swapDelta);
    }

    receive() external payable {}

    function _commitAndReveal(string memory ticker) internal returns (uint256 tokenId, address market, address token) {
        bytes32 tickerSalt = keccak256("some entropy");
        bytes32 tickerKey = keccak256(bytes(ticker));
        bytes32 commitHash = keccak256(abi.encode(launcher, tickerKey, tickerSalt));

        vm.prank(launcher);
        registry.commit(commitHash);

        vm.warp(block.timestamp + registry.MIN_REVEAL_DELAY());

        // Read LAUNCH_PRICE() into a local BEFORE pranking - registry.LAUNCH_PRICE() is itself
        // an external call, and vm.prank only affects the very NEXT call regardless of what it
        // is, so evaluating it inline inside reveal{value: registry.LAUNCH_PRICE()}(...) would
        // consume the prank on that read instead of on reveal() itself (caught by this test
        // failing with "no matching commitment" - msg.sender inside reveal() was silently the
        // test contract, not launcher, until this fix).
        uint256 launchPrice = registry.LAUNCH_PRICE();
        vm.prank(launcher);
        tokenId = registry.reveal{value: launchPrice}(ticker, tickerSalt);

        market = registry.marketOf(tokenId);
        token = registry.tokenOf(tokenId);
    }

    // ── The full atomic launch, proven end-to-end ────────────────────────────────────────────

    function test_atomicLaunch_fullSequence_producesARealTradeableMarket() public {
        uint256 multisigBalanceBefore = multisig.balance;
        uint256 rewardVaultBalanceBefore = address(rewardVault).balance;

        (uint256 tokenId, address marketAddr, address tokenAddr) = _commitAndReveal("CAT");

        // ── TickerNFT actually minted, to the real launcher ─────────────────────────────────
        assertEq(tickerNFT.ownerOf(tokenId), launcher, "the launcher must own the newly-minted TickerNFT");

        // ── EligibilityRegistry actually registered the new market ─────────────────────────
        // (registerToken's own return value was already asserted to match tokenId inside
        // _launchMeme itself - require(registeredId == tokenId) - so reaching this point at all
        // is already partial proof; nothing further to check here beyond that this didn't revert.)

        // ── Launch payment actually routed (100% multisig at MULTISIG_LAUNCH_BPS, matching v2) ──
        assertEq(multisig.balance, multisigBalanceBefore + registry.LAUNCH_PRICE(), "the full launch price must have gone to multisig, matching v2's own 100% split");
        assertEq(address(rewardVault).balance, rewardVaultBalanceBefore, "at 100% multisig, RewardVault must receive nothing from the launch fee itself - unrelated to per-trade WinnerPot routing");

        // ── The market's inventory actually landed in PoolManager, not stranded at the market ──
        ClogMarket market = ClogMarket(marketAddr);
        assertEq(manager.balanceOf(marketAddr, uint256(uint160(tokenAddr))), market.CURVE_ALLOCATION() + market.CLOG_ALLOCATION(), "the market's own ERC6909 token claim must equal the full physical supply - the atomic deposit must have actually happened, not merely been attempted");
        assertEq(IERC20Like(tokenAddr).balanceOf(marketAddr), 0, "the market's own REAL token balance must be exactly zero after the atomic deposit - nothing left stranded outside PoolManager");
        assertEq(IERC20Like(tokenAddr).balanceOf(address(manager)), market.CURVE_ALLOCATION() + market.CLOG_ALLOCATION(), "PoolManager itself must physically hold exactly the full 1B real supply - the claim above is backed by a real, physical transfer, not merely an accounting entry");

        // ── MemeToken.market() must resolve to the real ClogMarket ──────────────────────────
        assertEq(IMemeTokenLike(tokenAddr).market(), marketAddr, "MemeToken's own market() pointer must resolve to the real, deployed ClogMarket");

        // ── PoolKey <-> market mappings on the hook must be correct, both directions ────────
        PoolKey memory keyForChecks = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddr),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        assertEq(hook.marketOf(keyForChecks.toId()), marketAddr, "hook.marketOf must resolve this exact PoolKey to the real market");
        assertEq(PoolId.unwrap(hook.poolOf(marketAddr)), PoolId.unwrap(keyForChecks.toId()), "hook.poolOf must resolve the market back to the exact same pool - the reverse relationship must hold");

        // ── EligibilityRegistry's own market registration must be correct ──────────────────
        assertEq(eligibility.tokenMarket(tokenId), marketAddr, "EligibilityRegistry's own tokenMarket mapping must point at the real, deployed market");

        // ── The hook approvals actually got granted (a real trade below proves this implicitly,
        //    but check it directly too, since a missing approval would otherwise only surface as
        //    a confusing revert deep inside the swap itself) ──────────────────────────────────
        assertEq(manager.allowance(marketAddr, address(hook), uint256(uint160(tokenAddr))), type(uint256).max, "the hook must hold max ERC6909 allowance over the market's own token claim");
        assertEq(manager.allowance(marketAddr, address(hook), 0), type(uint256).max, "the hook must hold max ERC6909 allowance over the market's own ETH claim");

        // ── The real proof: a REAL trade, through the market this exact atomic launch just
        //    produced, in a LATER, SEPARATE transaction from the launch itself - proving the
        //    launched system is genuinely left in a working, tradeable state, not merely
        //    internally consistent immediately after its own constructor calls returned ────────
        PoolKey memory key = keyForChecks;

        uint256 buyAmount = 0.05 ether;
        vm.deal(address(this), buyAmount);
        bytes memory result = manager.unlock(abi.encode(SwapRequest({key: key, zeroForOne: true, amountSpecified: -int256(buyAmount)})));
        BalanceDelta swapDelta = abi.decode(result, (BalanceDelta));
        uint256 tokensOut = uint256(int256(swapDelta.amount1()));

        assertGt(tokensOut, 0, "a real buy through the freshly, atomically launched market must deliver real tokens");
        assertEq(IERC20Like(tokenAddr).balanceOf(address(this)), tokensOut, "the buyer must hold real ERC20 tokens from the freshly launched market");
        assertEq(
            manager.balanceOf(marketAddr, uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(market.ticketOwnerRecipient()) + market.pendingWithdrawals(multisig),
            "the conservation invariant must hold for a trade on a market produced by the atomic launch, exactly as it does everywhere else in this profile"
        );

        // ── A real SELL, immediately after that buy, still through the atomically launched
        //    market - proving both trade directions work, not just the buy side ──────────────
        uint256 sellAmount = tokensOut / 2;
        bytes memory sellResult = manager.unlock(abi.encode(SwapRequest({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)})));
        BalanceDelta sellDelta = abi.decode(sellResult, (BalanceDelta));
        uint256 netEthOut = uint256(int256(sellDelta.amount0()));

        assertGt(netEthOut, 0, "a real sell, immediately after the buy, through the same atomically launched market, must deliver real ETH");
        assertEq(IERC20Like(tokenAddr).balanceOf(address(this)), tokensOut - sellAmount, "the seller's real token balance must fall by exactly what was sold");
        assertEq(
            manager.balanceOf(marketAddr, uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(market.ticketOwnerRecipient()) + market.pendingWithdrawals(multisig),
            "the conservation invariant must still hold after the sell too"
        );
    }

    function test_secondTicker_sameHookAndRewardVault_isolatedFromFirst() public {
        (, address marketA, address tokenA) = _commitAndReveal("CAT");

        vm.warp(block.timestamp + registry.MIN_REVEAL_DELAY() + 1);
        vm.deal(launcher, 10 ether);
        (, address marketB, address tokenB) = _commitAndReveal("DOG");

        assertTrue(marketA != marketB, "two separate launches must produce two separate markets");
        assertTrue(tokenA != tokenB, "two separate launches must produce two separate MemeTokens");
        assertEq(ClogMarket(marketA).hook(), address(hook), "both markets must share the SAME universal hook");
        assertEq(ClogMarket(marketB).hook(), address(hook), "both markets must share the SAME universal hook");

        // ── No claim/state collision: each market's own inventory landed correctly and
        //    independently, with no cross-contamination from the other's launch ────────────
        assertEq(manager.balanceOf(marketA, uint256(uint160(tokenA))), 900_000_000e18 + 100_000_000e18, "market A's own claim must be the full physical supply of TOKEN A only");
        assertEq(manager.balanceOf(marketB, uint256(uint160(tokenB))), 900_000_000e18 + 100_000_000e18, "market B's own claim must be the full physical supply of TOKEN B only");
        assertEq(manager.balanceOf(marketA, uint256(uint160(tokenB))), 0, "market A must hold ZERO claim over token B - no cross-contamination between independently launched tickers");
        assertEq(manager.balanceOf(marketB, uint256(uint160(tokenA))), 0, "market B must hold ZERO claim over token A - no cross-contamination between independently launched tickers");

        // ── A real trade on A must not alter B's claims at all, and vice versa - the same P0
        //    isolation property already proven exhaustively in CrossMarketIsolation.t.sol, now
        //    re-confirmed specifically for markets produced by the real atomic launch flow ────
        PoolKey memory keyA = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(tokenA), fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        uint256 marketBEthClaimBefore = manager.balanceOf(marketB, uint256(uint160(address(0))));
        uint256 marketBTokenClaimBefore = manager.balanceOf(marketB, uint256(uint160(tokenB)));

        vm.deal(address(this), 0.05 ether);
        manager.unlock(abi.encode(SwapRequest({key: keyA, zeroForOne: true, amountSpecified: -int256(0.05 ether)})));

        assertEq(manager.balanceOf(marketB, uint256(uint160(address(0)))), marketBEthClaimBefore, "a trade on market A must not alter market B's own ETH claim at all");
        assertEq(manager.balanceOf(marketB, uint256(uint160(tokenB))), marketBTokenClaimBefore, "a trade on market A must not alter market B's own token claim at all");
    }

    // ── Inventory deposit cannot be replayed ─────────────────────────────────────────────────

    function test_inventoryDeposit_cannotBeReplayed() public {
        (, address marketAddr, address tokenAddr) = _commitAndReveal("CAT");

        // The market's real token balance is exactly zero after the atomic launch's own
        // deposit - a second, separate attempt to deposit again must find nothing left to move
        // and revert cleanly, never silently minting a second, unbacked claim.
        assertEq(IERC20Like(tokenAddr).balanceOf(marketAddr), 0, "sanity: nothing must remain at the market to replay-deposit in the first place");

        PoolKey memory key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(tokenAddr), fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        uint256 claimBefore = manager.balanceOf(marketAddr, uint256(uint160(tokenAddr)));

        vm.expectRevert(bytes("nothing to deposit"));
        vm.prank(address(registry));
        hook.depositMarketInventory(marketAddr, tokenAddr, key);

        assertEq(manager.balanceOf(marketAddr, uint256(uint160(tokenAddr))), claimBefore, "the market's own claim must be completely unchanged after the reverted replay attempt - never double-minted");
    }

    // ── setV4Infrastructure is one-time and cannot be changed afterward ─────────────────────

    function test_setV4Infrastructure_onlyOnce_secondCallReverts() public {
        // `registry` (this test contract's own field) already had setV4Infrastructure called
        // once in setUp() - a second call, even with otherwise-valid, different addresses, must
        // revert: this is one-time deployment initialization, never ongoing upgradeability.
        RewardVault anotherVault = new RewardVault(roundManager, address(manager), address(hook));
        vm.expectRevert(bytes("already configured"));
        registry.setV4Infrastructure(address(manager), address(hook), address(anotherVault));

        assertEq(address(registry.poolManager()), address(manager), "poolManager must remain exactly what setUp() originally configured");
        assertEq(address(registry.hook()), address(hook), "hook must remain exactly what setUp() originally configured");
        assertEq(registry.rewardVault(), address(rewardVault), "rewardVault must remain exactly what setUp() originally configured, not the second attempt's address");
    }

    function test_setV4Infrastructure_onlyDeployer_reverts() public {
        TickerRegistryV4 freshRegistry = new TickerRegistryV4(address(eligibility), address(tickerNFT), multisig, VIRTUAL_ETH_SEED, BUFFER_BPS);
        address notDeployer = makeAddr("notDeployer");
        vm.prank(notDeployer);
        vm.expectRevert(bytes("not deployer"));
        freshRegistry.setV4Infrastructure(address(manager), address(hook), address(rewardVault));
    }

    function test_reveal_beforeInfrastructureConfigured_reverts() public {
        TickerRegistryV4 freshRegistry = new TickerRegistryV4(address(eligibility), address(tickerNFT), multisig, VIRTUAL_ETH_SEED, BUFFER_BPS);
        bytes32 tickerSalt = keccak256("x");
        bytes32 commitHash = keccak256(abi.encode(launcher, keccak256(bytes("NEW")), tickerSalt));
        vm.prank(launcher);
        freshRegistry.commit(commitHash);
        vm.warp(block.timestamp + freshRegistry.MIN_REVEAL_DELAY());

        // Cache LAUNCH_PRICE() BEFORE pranking/expecting-revert - see _commitAndReveal's own
        // docs above for why evaluating it inline would consume both vm.prank and
        // vm.expectRevert on that harmless view call instead of on reveal() itself.
        uint256 launchPrice = freshRegistry.LAUNCH_PRICE();
        vm.deal(launcher, launchPrice);
        vm.prank(launcher);
        vm.expectRevert(bytes("TickerRegistryV4: v4 infrastructure not configured"));
        freshRegistry.reveal{value: launchPrice}("NEW", tickerSalt);
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IMemeTokenLike {
    function market() external view returns (address);
}
