// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {EligibilityRegistry} from "../../src/EligibilityRegistry.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {TickerRegistry} from "../../src/TickerRegistry.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {BondingCurveClog} from "../../src/BondingCurveClog.sol";
import {ClogV4Hook} from "../../src/ClogV4Hook.sol";

/// @notice ROBINHOOD MAINNET FORK TEST - targets the ACTUAL DEPLOYED infrastructure on Robinhood
/// Chain (4663): the real PoolManager, the real UniversalRouter, and the real, canonical Permit2 -
/// referenced directly by their live addresses, never redeployed, never modified. Only ClogV4Hook
/// and a freshly-launched test CLOG market are deployed INTO the fork (no real CLOG ticker exists
/// on Robinhood mainnet yet).
///
/// THIS TEST CANNOT RUN IN THIS SANDBOX: outbound network access here is domain-allowlisted and
/// rpc.mainnet.chain.robinhood.com is not on that list (confirmed directly - a raw curl to it
/// returns "Host not in allowlist"). It is confirmed to COMPILE in this sandbox; it has never been
/// run, and no result from it should be treated as known until it is actually executed against
/// the real fork.
///
/// EXACT COMMAND TO RUN ON THE VPS (where Robinhood RPC access works):
///
///     forge test --match-contract ClogRobinhoodForkTest --fork-url https://rpc.mainnet.chain.robinhood.com -vvv
///
/// This never broadcasts anything to the real chain: forge's --fork-url runs entirely against a
/// local, disposable, in-memory copy of chain state (an anvil-style fork) for the duration of the
/// test process only. Nothing here ever sends a real transaction.
///
/// HONESTY NOTE ON THE ExactInputSingleParams STRUCT USED BELOW: the operator independently
/// confirmed (via current Uniswap documentation/Trading API) that Robinhood Chain's deployed
/// UniversalRouter identifies as v2.1.1, and separately-found third-party ecosystem evidence
/// (Bags' own integration docs, a live protocol on this exact chain) describes the deployed
/// router's v4 swap struct as carrying an extra `minHopPriceX36` field "immediately before
/// hookData". This session cross-checked Uniswap's own official deployments manifest
/// (github.com/Uniswap/contracts/deployments/4663.md), which confirms this exact router address,
/// deployed 26 May 2026 at commit 023196a, and separately surfaces that Robinhood Chain had an
/// EARLIER, DIFFERENT UniversalRouter deployment at 0x248a454ac3584c2a48d1fcb28d3910a6b6ea00af
/// that predates this one, whose constructor parameters notably lack a permissionsAdapterFactory
/// field - consistent with an older UniversalRouter version, and consistent with Bags' own
/// warning that "two other router look-alikes exist on this chain." Commit 023196a could not be
/// resolved to browsable source in the public Uniswap/universal-router GitHub repository within
/// this session's time and tooling budget - it may live in an internal deployment-tracking
/// repository not mapped 1:1 to the public repo's own commit history. The struct below is
/// therefore constructed from the operator's direct confirmation plus the independently-found
/// Bags documentation - not from independently re-derived deployed bytecode or verified
/// Blockscout source. If this encoding is wrong, the real router will simply revert on a genuine
/// ABI mismatch (calldata will fail to decode into valid parameters) - this test's actual result,
/// run on the VPS, is what confirms or refutes it, not this comment.
struct RobinhoodExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

interface IUniversalRouterMinimal {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

contract ClogRobinhoodForkTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Exact deployed Robinhood Chain (4663) mainnet addresses - operator-supplied, cross-checked
    // this session against Uniswap's own official deployments/4663.md manifest for PoolManager
    // and V4Quoter (both matched exactly).
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    uint8 constant V4_SWAP_COMMAND = 0x10;

    IPoolManager manager;
    IUniversalRouterMinimal router;
    IAllowanceTransfer permit2;

    // Full, real CLOG stack, freshly deployed INTO the fork - identical contracts, identical
    // launch flow to ClogV4Hook.t.sol's own setUp()/_launchRealTicker(), just pointed at the
    // real, live PoolManager address instead of a locally-deployed one. Two separate markets:
    // one traded through the real router (the actual subject of this test), one traded directly,
    // for the economic-equivalence comparison.
    EligibilityRegistry engine;
    TickerNFT tickerNFT;
    TickerRegistry registry;
    ClogV4Hook hook;

    MemeToken tokenV4;
    BondingCurveClog marketV4;
    PoolKey poolKey;

    MemeToken tokenDirect;
    BondingCurveClog marketDirect;

    address multisig = makeAddr("multisig");
    address winnerPot = makeAddr("winnerPot");
    address governance = makeAddr("governance");
    address user = makeAddr("user");
    address userDirect = makeAddr("userDirect");

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    function setUp() public {
        // Confirms this test is actually running against the real fork, not silently no-op-ing
        // against an empty local chain - PoolManager must already have real code at this address.
        require(
            POOL_MANAGER.code.length > 0,
            "fork not active: no code at the real PoolManager address - run with --fork-url"
        );
        require(UNIVERSAL_ROUTER.code.length > 0, "fork not active: no code at the real UniversalRouter address");
        require(PERMIT2.code.length > 0, "fork not active: no code at the real Permit2 address");

        manager = IPoolManager(POOL_MANAGER);
        router = IUniversalRouterMinimal(UNIVERSAL_ROUTER);
        permit2 = IAllowanceTransfer(PERMIT2);

        // Full, real CLOG stack - identical to ClogV4Hook.t.sol's own setUp(), pointed at the
        // real PoolManager address instead of a freshly-deployed local one.
        engine = new EligibilityRegistry(address(this));
        engine.setRoundManager(makeAddr("roundManager"));
        tickerNFT =
            new TickerNFT("PMFI Casino Tickers", "TICKER", address(this), "https://clog.run/api/ticker-metadata/");
        registry = new TickerRegistry(
            address(engine), address(tickerNFT), multisig, winnerPot, governance, VIRTUAL_ETH_SEED, BUFFER_BPS
        );
        tickerNFT.setRegistry(address(registry));

        ClogV4Hook impl = new ClogV4Hook(manager, registry);

        // Real production CREATE2/HookMiner deployment - NOT vm.etch to an arbitrary computed
        // address. getHookPermissions() is ClogV4Hook's own single declared source of truth for
        // which callbacks it implements; flagsFromPermissions() mechanically derives the exact
        // bits HookMiner mines for from that declaration, so there is no separately-maintained
        // flag constant that could drift from what the hook actually implements. `deployer` is
        // address(this) (this test contract), since that is the actual CREATE2 sender for the
        // `new ClogV4Hook{salt: salt}(...)` call below - HookMiner must predict the address
        // exactly as the EVM's own CREATE2 formula will compute it for that real sender, not for
        // the standard 0x4e59b44... deployer proxy DeployClogV4Hook.s.sol uses when broadcasting
        // a real deployment.
        uint160 requiredFlags = impl.flagsFromPermissions();
        bytes memory constructorArgs = abi.encode(manager, registry);
        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(address(this), requiredFlags, type(ClogV4Hook).creationCode, constructorArgs);
        hook = new ClogV4Hook{salt: salt}(manager, registry);
        require(address(hook) == minedHookAddress, "deployed hook address does not match the mined address");

        // Explicit assertion: the deployed address's actual permission bits match exactly what
        // ClogV4Hook.getHookPermissions() declares - Hooks.validateHookPermissions is the same
        // official check PoolManager-adjacent tooling uses, called directly here rather than
        // reimplemented.
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());

        (uint256 tokenIdV4, MemeToken t1, BondingCurveClog m1) = _launchRealTicker("RHFORK", user);
        (, MemeToken t2, BondingCurveClog m2) = _launchRealTicker("RHFORKD", userDirect);
        tokenV4 = t1;
        marketV4 = m1;
        tokenDirect = t2;
        marketDirect = m2;
        hook.registerMarket(tokenIdV4);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenV4)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        // Deliberately no modifyLiquidity call anywhere in this file - zero PoolManager-resident
        // liquidity for this pool, by construction.

        // Explicit checks requested for this review, all asserted directly rather than only
        // implied by the absence of a revert above:
        // 1. hook address permission bits match the declared permissions
        assertTrue(
            uint160(address(hook)) & HookMiner.FLAG_MASK == requiredFlags,
            "deployed hook address bits must match getHookPermissions()"
        );
        // 2. the PoolKey actually used for every trade in this file carries that exact mined address
        assertEq(address(poolKey.hooks), address(hook), "PoolKey must use the exact mined hook address");
        assertEq(
            address(poolKey.hooks), minedHookAddress, "PoolKey's hook address must equal HookMiner's own prediction"
        );
        // 3. pool initialization succeeded against the REAL deployed PoolManager (not a revert
        // that was silently swallowed) - a real slot0 now exists for this pool id on the real
        // contract at POOL_MANAGER.
        (uint160 sqrtPriceX96After,,,) = manager.getSlot0(poolKey.toId());
        assertGt(sqrtPriceX96After, 0, "pool initialization must have succeeded against the real deployed PoolManager");

        vm.deal(user, 10 ether);
        vm.deal(userDirect, 10 ether);
    }

    /// @dev Launches a real ticker through TickerRegistry's actual commit/reveal flow - identical
    /// to ClogV4Hook.t.sol's own _launchRealTicker(), duplicated here since fork tests live in a
    /// separate file/contract and Solidity has no cross-file internal-function sharing without a
    /// shared library or base contract.
    function _launchRealTicker(string memory ticker, address launcher)
        internal
        returns (uint256 tokenId, MemeToken token, BondingCurveClog market)
    {
        bytes32 salt = keccak256(abi.encode(ticker, block.timestamp, launcher));
        bytes32 tickerKey = keccak256(bytes(ticker));
        bytes32 commitHash = keccak256(abi.encode(launcher, tickerKey, salt));

        vm.prank(launcher);
        registry.commit(commitHash);
        vm.warp(block.timestamp + registry.MIN_REVEAL_DELAY());

        uint256 launchPrice = registry.LAUNCH_PRICE();
        vm.deal(launcher, launcher.balance + launchPrice);
        vm.prank(launcher);
        tokenId = registry.reveal{value: launchPrice}(ticker, salt);

        token = MemeToken(registry.tokenOf(tokenId));
        market = BondingCurveClog(registry.marketOf(tokenId));
    }

    function _buyInputs(uint256 ethIn) internal view returns (bytes[] memory inputs) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(Currency.wrap(address(0)), ethIn, true);
        params[1] = abi.encode(
            RobinhoodExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: uint128(ethIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[2] = abi.encode(poolKey.currency1, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _sellInputs(uint256 tokenIn) internal view returns (bytes[] memory inputs) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(poolKey.currency1, tokenIn, true);
        params[1] = abi.encode(
            RobinhoodExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false,
                amountIn: uint128(tokenIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[2] = abi.encode(Currency.wrap(address(0)), uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _allDeltasZero() internal view returns (bool) {
        return manager.currencyDelta(address(router), Currency.wrap(address(0))) == 0
            && manager.currencyDelta(address(router), Currency.wrap(address(tokenV4))) == 0
            && manager.currencyDelta(address(hook), Currency.wrap(address(0))) == 0
            && manager.currencyDelta(address(hook), Currency.wrap(address(tokenV4))) == 0
            && manager.currencyDelta(user, Currency.wrap(address(0))) == 0
            && manager.currencyDelta(user, Currency.wrap(address(tokenV4))) == 0;
    }

    /// 1. ETH -> real Robinhood UniversalRouter -> real deployed PoolManager -> ClogV4Hook ->
    /// BondingCurveClog -> meme
    function test_fork_buy_ethToMeme_viaRealUniversalRouterAndPoolManager() public {
        uint256 ethIn = 0.01 ether;

        vm.prank(userDirect);
        uint256 directOut = marketDirect.buy{value: ethIn}(0, block.timestamp);

        bytes memory commands = abi.encodePacked(V4_SWAP_COMMAND);
        vm.prank(user);
        router.execute{value: ethIn}(commands, _buyInputs(ethIn));
        uint256 forkOut = tokenV4.balanceOf(user);

        // 7. exact economic equivalence with the direct trade
        assertEq(forkOut, directOut, "fork UniversalRouter buy must exactly match direct buy() output");
        assertEq(marketV4.realReserve(), marketDirect.realReserve(), "realReserve must match");
        assertEq(marketV4.progressBps(), marketDirect.progressBps(), "progressBps must match");
        assertEq(marketV4.clogRemaining(), marketDirect.clogRemaining(), "HWM/CLOG release must match");

        address nftOwnerV4 = marketV4.ticketOwnerRecipient();
        address nftOwnerDirect = marketDirect.ticketOwnerRecipient();
        assertEq(
            marketV4.pendingWithdrawals(nftOwnerV4),
            marketDirect.pendingWithdrawals(nftOwnerDirect),
            "NFT-owner fee credit must match"
        );
        assertEq(
            marketV4.pendingWithdrawals(multisig),
            marketDirect.pendingWithdrawals(multisig),
            "protocol fee credit must match"
        );
        assertEq(marketV4.winnerPotGenerated(), marketDirect.winnerPotGenerated(), "WinnerPot generated must match");
        assertEq(marketV4.deliveredWinnerPot(), marketDirect.deliveredWinnerPot(), "WinnerPot delivered must match");

        assertEq(tokenV4.checkpointCount(user), tokenDirect.checkpointCount(userDirect), "checkpoint count must match");
        assertEq(
            tokenV4.cumulativeAt(user, block.timestamp),
            tokenDirect.cumulativeAt(userDirect, block.timestamp),
            "cumulative TWAB value must match"
        );

        // 8. zero liquidity, zero hook inventory, zero PoolManager deltas
        (uint128 liquidity) = manager.getLiquidity(poolKey.toId());
        assertEq(liquidity, 0, "pool must have zero concentrated liquidity");
        assertEq(address(hook).balance, 0, "hook must hold zero ETH after the real fork trade");
        assertEq(tokenV4.balanceOf(address(hook)), 0, "hook must hold zero token after the real fork trade");
        assertTrue(_allDeltasZero(), "every PoolManager transient delta must net to zero");

        console2.log("FORK BUY: direct tokensOut =", directOut);
        console2.log("FORK BUY: router tokensOut =", forkOut);
    }

    /// 2. meme -> real Permit2 -> real Robinhood UniversalRouter -> real deployed PoolManager ->
    /// ClogV4Hook -> BondingCurveClog -> ETH
    function test_fork_sell_memeToEth_viaRealUniversalRouterAndPermit2() public {
        uint256 ethIn = 0.01 ether;
        vm.prank(userDirect);
        marketDirect.buy{value: ethIn}(0, block.timestamp);
        uint256 directBalance = tokenDirect.balanceOf(userDirect);

        bytes memory commands = abi.encodePacked(V4_SWAP_COMMAND);
        vm.prank(user);
        router.execute{value: ethIn}(commands, _buyInputs(ethIn));
        uint256 forkBalance = tokenV4.balanceOf(user);
        assertEq(forkBalance, directBalance, "pre-sell balances must match to make the sell comparison valid");

        vm.startPrank(userDirect);
        tokenDirect.approve(address(marketDirect), directBalance);
        (uint256 directEthOut,) = marketDirect.sell(directBalance, 0, block.timestamp);
        vm.stopPrank();

        // Real Permit2 approval architecture: ERC20 approve to Permit2 itself, then a Permit2-
        // level allowance to the real UniversalRouter - never a direct approval to the router.
        vm.startPrank(user);
        tokenV4.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tokenV4), address(router), uint160(forkBalance), uint48(block.timestamp + 3600));
        vm.stopPrank();

        uint256 ethBefore = user.balance;
        vm.prank(user);
        router.execute(commands, _sellInputs(forkBalance));
        uint256 forkEthOut = user.balance - ethBefore;

        assertEq(forkEthOut, directEthOut, "fork UniversalRouter sell must exactly match direct sell() output");
        assertEq(marketV4.realReserve(), marketDirect.realReserve(), "realReserve must match after sell");
        assertEq(marketV4.progressBps(), marketDirect.progressBps(), "progressBps must match after sell");

        assertEq(tokenV4.allowance(user, address(router)), 0, "user must never approve the router directly");
        assertEq(tokenV4.allowance(user, address(hook)), 0, "user must never approve the hook directly");
        assertEq(
            tokenV4.allowance(address(hook), address(marketV4)),
            0,
            "hook's allowance to the market must be zero after the trade"
        );

        (uint128 liquidity) = manager.getLiquidity(poolKey.toId());
        assertEq(liquidity, 0, "pool must still have zero concentrated liquidity");
        assertEq(address(hook).balance, 0, "hook must hold zero ETH after the real fork sell");
        assertEq(tokenV4.balanceOf(address(hook)), 0, "hook must hold zero token after the real fork sell");
        assertTrue(_allDeltasZero(), "every PoolManager transient delta must net to zero after sell");

        console2.log("FORK SELL: direct ethOut  =", directEthOut);
        console2.log("FORK SELL: router ethOut =", forkEthOut);
    }
}
