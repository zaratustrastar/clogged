// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {TickerRegistry} from "../src/TickerRegistry.sol";
import {ClogV4Hook} from "../src/ClogV4Hook.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {TestRouter} from "./v4/TestRouter.sol";

/// @notice CANARY END-TO-END TEST. Proves the exact same contracts, the exact real qualification
/// algorithm, and the exact real v4 trading path work correctly under CANARY-SCALE deployment
/// configuration (small thresholds, chosen for a fast, cheap real-mainnet rehearsal) - not a
/// weakened or bypassed version of the real logic. Every threshold crossed below is crossed for
/// real, by a real trade through the real v4 hook into the real, unmodified BondingCurveClog -
/// there is no test-mode branch, privileged qualification function, or special canary code path
/// anywhere in src/.
contract CanaryE2ETest is Test {
    EligibilityRegistry engine;
    RoundManager rm;
    RewardVault vault;
    ChainlinkRandomnessProvider provider;
    VRFWrapperOnArbitrum wrapper;
    MockCCIPRouter ccipRouter;
    VRFCoordinatorV2_5Mock vrfCoordinator;
    TickerNFT tickerNFT;
    TickerRegistry registry;
    PoolManager manager;
    ClogV4Hook hook;
    TestRouter v4Router;

    address governance = address(0x60401);
    address multisig = address(0xA51);
    address winnerPotAddr; // set in setUp() to address(vault) - see the note there
    address alice = address(0xA11CE);
    address bob = address(0xB0B1);
    address carol = address(0xCA501);

    uint64 constant MOCK_SELECTOR = 16015286601757825753; // MockCCIPRouter's fixed loopback selector
    bytes32 constant KEY_HASH = keccak256("canary-integration-keyhash");
    uint256 subId;

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    // Exact canary configuration values, per the operator's spec.
    uint256 constant CANARY_MIN_PROGRESS_BPS = 1;
    uint256 constant CANARY_MIN_RESERVE_THRESHOLD_WEI = 500_000_000_000_000; // 0.0005 ether
    uint256 constant CANARY_REQUIRED_ABSOLUTE_SECONDS = 60;
    uint256 constant CANARY_ROUND_DURATION_SECONDS = 300;
    uint256 constant CANARY_BUY_AMOUNT = 0.00075 ether;

    function setUp() public {
        ccipRouter = new MockCCIPRouter();
        vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);
        subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 1_000_000 ether);

        // Fresh canary stack, canary-scale thresholds - same contracts, same algorithm as
        // production, different deployment-time configuration only.
        engine = new EligibilityRegistry(
            address(this), CANARY_MIN_PROGRESS_BPS, CANARY_MIN_RESERVE_THRESHOLD_WEI, CANARY_REQUIRED_ABSOLUTE_SECONDS
        );
        provider = new ChainlinkRandomnessProvider(address(ccipRouter), MOCK_SELECTOR, governance, address(this));
        rm = new RoundManager(address(engine), address(provider), governance, CANARY_ROUND_DURATION_SECONDS);
        engine.setRoundManager(address(rm));
        provider.setRoundManager(address(rm));
        vm.deal(address(provider), 10 ether);

        vault = new RewardVault(address(rm));
        vm.prank(governance);
        rm.setRewardVault(address(vault));

        wrapper = new VRFWrapperOnArbitrum(address(vrfCoordinator), address(ccipRouter), MOCK_SELECTOR, KEY_HASH, subId);
        vrfCoordinator.addConsumer(subId, address(wrapper));
        vm.deal(address(wrapper), 10 ether);

        vm.prank(governance);
        provider.setWrapper(address(wrapper));
        wrapper.setProvider(address(provider));

        // Real TickerRegistry/TickerNFT, since ClogV4Hook.registerMarket() only ever trusts what
        // TickerRegistry itself reports - a direct-constructed BondingCurveClog (bypassing
        // TickerRegistry) could never be validated by the hook.
        //
        // winnerPot_ is address(vault) itself - NOT a separate stub address. Each market's
        // "clogExtracted" winner-pot cut of trading fees is paid directly to whatever address is
        // passed as winnerPot_ at construction, and that flow is exactly how RewardVault
        // accumulates the ETH it later allocates to a winning round (confirmed against
        // ChainlinkAdapterIntegration.t.sol's own proven working pattern, which passes
        // address(vault) as the winnerPot_ argument for the identical reason) - a stub address
        // would silently strand every round's jackpot outside RewardVault entirely.
        winnerPotAddr = address(vault);
        tickerNFT =
            new TickerNFT("PMFI Casino Tickers", "TICKER", address(this), "https://clog.run/api/ticker-metadata/");
        registry = new TickerRegistry(
            address(engine), address(tickerNFT), multisig, winnerPotAddr, governance, VIRTUAL_ETH_SEED, BUFFER_BPS
        );
        tickerNFT.setRegistry(address(registry));

        // Real v4 stack: local PoolManager (this is a unit/integration test, not the Robinhood
        // fork test - see test/v4/ClogRobinhoodForkTest.t.sol for the real-infrastructure
        // version), the universal ClogV4Hook deployed via real CREATE2/HookMiner (not vm.etch),
        // and a router built on the real, official V4Router/BaseActionsRouter framework.
        manager = new PoolManager(address(this));
        v4Router = new TestRouter(manager);

        ClogV4Hook impl = new ClogV4Hook(manager, registry);
        uint160 requiredFlags = impl.flagsFromPermissions();
        bytes memory constructorArgs = abi.encode(manager, registry);
        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(address(this), requiredFlags, type(ClogV4Hook).creationCode, constructorArgs);
        hook = new ClogV4Hook{salt: salt}(manager, registry);
        require(address(hook) == minedHookAddress, "deployed hook address does not match the mined address");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _launchRealTicker(string memory ticker, address launcher)
        internal
        returns (uint256 tokenId, MemeToken token, BondingCurveClog market)
    {
        bytes32 salt = keccak256(abi.encode(ticker, block.timestamp, launcher, tokenId));
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

    function _initializeAndRegister(uint256 tokenId, MemeToken token) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        hook.registerMarket(tokenId);
    }

    function _buyThroughV4(PoolKey memory key, address buyer, uint256 ethIn) internal {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(Currency.wrap(address(0)), ethIn, true);
        params[1] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(ethIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[2] = abi.encode(key.currency1, uint256(0));
        vm.prank(buyer);
        v4Router.execute{value: ethIn}(actions, params);
    }

    /// The full canary rehearsal: three freshly launched Config-G markets, a real v4 exact-input
    /// buy into each crossing both canary thresholds, qualification after the real 60-second
    /// streak requirement, all three becoming candidates, round close at exactly the real
    /// 300-second canary duration with a real draw (not skipped), and real entry into the normal
    /// randomness request path - proven by exercising the actual deployed contracts and the
    /// actual qualification algorithm, never a shortcut.
    function test_canary_threeMarkets_v4Buys_qualifyAndCloseWithRealDraw() public {
        uint256 roundOpen = rm.currentRoundOpenTime();

        (uint256 catId, MemeToken catToken, BondingCurveClog catMarket) = _launchRealTicker("CANCAT", alice);
        (uint256 dogId, MemeToken dogToken, BondingCurveClog dogMarket) = _launchRealTicker("CANDOG", bob);
        (uint256 fishId, MemeToken fishToken, BondingCurveClog fishMarket) = _launchRealTicker("CANFISH", carol);

        PoolKey memory catKey = _initializeAndRegister(catId, catToken);
        PoolKey memory dogKey = _initializeAndRegister(dogId, dogToken);
        PoolKey memory fishKey = _initializeAndRegister(fishId, fishToken);

        // 1. a 0.00075 ether exact-input buy into each market, through the real v4 path
        _buyThroughV4(catKey, alice, CANARY_BUY_AMOUNT);
        _buyThroughV4(dogKey, bob, CANARY_BUY_AMOUNT);
        _buyThroughV4(fishKey, carol, CANARY_BUY_AMOUNT);

        // 2. each exceeds the canary reserve threshold (real state, read from the real market)
        assertGt(
            catMarket.realReserve(), CANARY_MIN_RESERVE_THRESHOLD_WEI, "cat must exceed the canary reserve threshold"
        );
        assertGt(
            dogMarket.realReserve(), CANARY_MIN_RESERVE_THRESHOLD_WEI, "dog must exceed the canary reserve threshold"
        );
        assertGt(
            fishMarket.realReserve(), CANARY_MIN_RESERVE_THRESHOLD_WEI, "fish must exceed the canary reserve threshold"
        );

        // 3. each exceeds the 1-bps canary progress threshold
        assertGe(catMarket.progressBps(), CANARY_MIN_PROGRESS_BPS, "cat must exceed the canary progress threshold");
        assertGe(dogMarket.progressBps(), CANARY_MIN_PROGRESS_BPS, "dog must exceed the canary progress threshold");
        assertGe(fishMarket.progressBps(), CANARY_MIN_PROGRESS_BPS, "fish must exceed the canary progress threshold");

        // Real, unavoidable timing: the v4 trades above already advanced block.timestamp (each
        // real ticker launch waits the real MIN_REVEAL_DELAY), so aboveThresholdSince was set at
        // varying real timestamps per market - wait the full canary streak length from the LAST
        // one, so every market has genuinely held its streak for at least the required window.
        vm.warp(block.timestamp + CANARY_REQUIRED_ABSOLUTE_SECONDS);

        // 4. after 60 real seconds, each can qualify - via the real, permissionless qualify()
        // path, the actual qualification algorithm, unmodified.
        engine.qualify(catId);
        engine.qualify(dogId);
        engine.qualify(fishId);

        // 5. candidate count becomes exactly 3 - EligibilityRegistry's own live count (RoundManager's
        // own RoundInfo.candidateCount is only a snapshot copied from this at close time, per
        // closeRoundAndOpenNext's own logic: `r.candidateCount = engine.candidateCount(...)`).
        assertEq(engine.candidateCount(engine.currentRoundId()), 3, "candidate count must be exactly 3 before close");

        // 6. after 300 real seconds (from round open), the round closes with drawSkipped=false
        vm.warp(roundOpen + CANARY_ROUND_DURATION_SECONDS);
        uint256 closedRoundId = rm.closeRoundAndOpenNext();
        RoundManager.RoundInfo memory infoAtClose = rm.getRound(closedRoundId);
        assertTrue(infoAtClose.closed, "round must be closed");
        assertEq(infoAtClose.candidateCount, 3, "closed round must show exactly 3 candidates");
        assertFalse(infoAtClose.drawSkipped, "draw must not be skipped with exactly 3 candidates");

        // 7. the normal randomness request path is entered - real CCIP mock, real VRF mock, the
        // actual cross-chain adapter, not a shortcut.
        assertTrue(infoAtClose.randomnessRequested, "the normal randomness request path must have been entered");
        assertFalse(infoAtClose.settled, "must not be settled until VRF actually fulfills");

        // 4. (VRF fulfillment) simulate the real Chainlink VRF network fulfilling the request -
        // the one part that cannot run without an actual VRF node; everything else here is real
        // contract code, exactly as in ChainlinkAdapterIntegration.t.sol's own proven pattern.
        uint256 vrfRequestId = _findLastVrfRequestId();
        vrfCoordinator.fulfillRandomWords(vrfRequestId, address(wrapper));

        RoundManager.RoundInfo memory infoAfterFulfillment = rm.getRound(closedRoundId);
        assertFalse(
            infoAfterFulfillment.settled, "must not be settled until the word is actually relayed back via CCIP"
        );

        // 5. relay randomness back via the real, permissionless relayRandomness call.
        wrapper.relayRandomness(infoAtClose.randomnessRequestId);

        // 6. round settles
        RoundManager.RoundInfo memory settledInfo = rm.getRound(closedRoundId);
        assertTrue(settledInfo.settled, "round must be settled once real VRF fulfillment completes and is relayed");

        // 7. winnerTokenId is one of the 3 candidates
        assertTrue(
            settledInfo.winnerTokenId == catId || settledInfo.winnerTokenId == dogId
                || settledInfo.winnerTokenId == fishId,
            "winner must be one of the three real candidates"
        );

        // 8. RewardVault receives/allocates the frozen winning-round ETH correctly
        RewardVault.RoundAllocation memory allocation = vault.getAllocation(closedRoundId);
        assertEq(
            allocation.winnerTokenId,
            settledInfo.winnerTokenId,
            "RewardVault's own allocation must record the same winner RoundManager settled"
        );
        assertGt(allocation.jackpotAmount, 0, "RewardVault must have frozen a nonzero jackpot for the winning round");
        BondingCurveClog winnerMarket = settledInfo.winnerTokenId == catId
            ? catMarket
            : settledInfo.winnerTokenId == dogId ? dogMarket : fishMarket;
        assertEq(
            allocation.market,
            address(winnerMarket),
            "RewardVault's recorded market must match the winning token's real market"
        );

        // 9. an actual holder claims
        address winnerHolder =
            settledInfo.winnerTokenId == catId ? alice : settledInfo.winnerTokenId == dogId ? bob : carol;
        uint256 claimable = vault.previewClaim(closedRoundId, winnerHolder);
        assertGt(claimable, 0, "the real buyer of the winning token must have a nonzero claimable amount");

        // 10. holder receives ETH
        uint256 holderBalBefore = winnerHolder.balance;
        vault.claim(closedRoundId, winnerHolder);
        assertEq(
            winnerHolder.balance,
            holderBalBefore + claimable,
            "holder must receive exactly the previewed claimable amount"
        );

        // 11. double-claim fails
        vm.expectRevert();
        vault.claim(closedRoundId, winnerHolder);

        // 12. trading still works after settlement - a real v4 sell through the exact same hook
        // and pool, on the (non-winning, still-live) market, proving settlement never freezes
        // ordinary trading.
        MemeToken stillTradableToken = winnerMarket == catMarket ? dogToken : catToken;
        PoolKey memory stillTradableKey = winnerMarket == catMarket ? dogKey : catKey;
        address stillTradingUser = winnerMarket == catMarket ? bob : alice;

        uint256 tokenBalance = stillTradableToken.balanceOf(stillTradingUser);
        assertGt(tokenBalance, 0, "the still-tradable market's buyer must hold real tokens to sell");
        vm.prank(stillTradingUser);
        stillTradableToken.approve(address(v4Router), tokenBalance);

        bytes memory sellActions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory sellParams = new bytes[](3);
        sellParams[0] = abi.encode(stillTradableKey.currency1, tokenBalance, true);
        sellParams[1] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: stillTradableKey,
                zeroForOne: false,
                amountIn: uint128(tokenBalance),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        sellParams[2] = abi.encode(Currency.wrap(address(0)), uint256(0));

        uint256 ethBeforeSell = stillTradingUser.balance;
        vm.prank(stillTradingUser);
        v4Router.execute(sellActions, sellParams);
        assertGt(
            stillTradingUser.balance, ethBeforeSell, "the real v4 sell after settlement must have returned real ETH"
        );
        assertEq(stillTradableToken.balanceOf(stillTradingUser), 0, "all tokens must have been sold");

        console2.log(
            "Canary E2E: full lifecycle proven - qualify, close, VRF fulfill, relay, settle, claim, post-settlement sell."
        );
    }

    function _findLastVrfRequestId() internal view returns (uint256) {
        for (uint256 i = 30; i >= 1; i--) {
            if (wrapper.vrfRequestIdToOriginalRequestId(i) != 0) {
                return i;
            }
        }
        revert("no VRF request found");
    }
}
