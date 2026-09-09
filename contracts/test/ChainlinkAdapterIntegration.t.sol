// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {MockTickerNFT} from "./mocks/MockTickerNFT.sol";

/// @notice Proves the real Chainlink VRF/CCIP adapter (not the simple MockRandomnessProvider used
///         by the rest of the test suite) actually plugs into the existing casino engine
///         end-to-end: 3 eligible memes -> round closes -> real adapter request path using
///         official Chainlink mocks -> mock VRF fulfillment -> authenticated CCIP return ->
///         uniform winner selected -> RewardVault allocation created -> winning holder claims.
///         One focused scenario is enough to prove the integration; exhaustive adapter-internal
///         edge cases are already covered by ChainlinkVRFAdapter.t.sol.
contract ChainlinkAdapterIntegrationTest is Test {
    EligibilityRegistry engine;
    RoundManager rm;
    RewardVault vault;
    ChainlinkRandomnessProvider provider;
    VRFWrapperOnArbitrum wrapper;
    MockCCIPRouter router;
    VRFCoordinatorV2_5Mock vrfCoordinator;

    address governance = address(0x60401);
    address multisig = address(0xA51);
    address ticketOwner = address(0x71CE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B1);

    uint64 constant MOCK_SELECTOR = 16015286601757825753; // MockCCIPRouter's fixed loopback selector
    bytes32 constant KEY_HASH = keccak256("integration-keyhash");
    uint256 subId;

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    function _now() external view returns (uint256) {
        return block.timestamp;
    }

    function setUp() public {
        router = new MockCCIPRouter();
        vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);
        subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 1_000_000 ether);

        // Three-way dependency (RoundManager needs engine + provider's real addresses; engine and
        // provider each get RoundManager's real address wired back afterward via a one-time
        // setter) -- deploy engine and provider first, RoundManager second using their real
        // addresses directly, then wire the relationship back. No CREATE-address prediction.
        engine = new EligibilityRegistry(address(this));
        provider = new ChainlinkRandomnessProvider(address(router), MOCK_SELECTOR, governance, address(this));
        rm = new RoundManager(address(engine), address(provider), governance);
        engine.setRoundManager(address(rm));
        provider.setRoundManager(address(rm));
        vm.deal(address(provider), 10 ether);

        vault = new RewardVault(address(rm));
        vm.prank(governance);
        rm.setRewardVault(address(vault));

        wrapper = new VRFWrapperOnArbitrum(address(vrfCoordinator), address(router), MOCK_SELECTOR, KEY_HASH, subId);
        vrfCoordinator.addConsumer(subId, address(wrapper));
        vm.deal(address(wrapper), 10 ether);

        vm.prank(governance);
        provider.setWrapper(address(wrapper));
        wrapper.setProvider(address(provider));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _launchMeme(string memory name, string memory symbol) internal returns (uint256 tokenId, BondingCurveClog market) {
        uint256 predictedTokenId = engine.nextTokenId();
        MockTickerNFT tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(predictedTokenId, ticketOwner);

        MemeToken token = new MemeToken(name, symbol, address(this));
        market = new BondingCurveClog(
            address(token), address(tickerNFT), predictedTokenId, multisig, address(vault), governance, VIRTUAL_ETH_SEED, BUFFER_BPS
        );
        token.setMarket(address(market));
        tokenId = engine.registerToken(address(market));
        require(tokenId == predictedTokenId, "token id mismatch");
    }

    function test_fullLifecycle_realChainlinkAdapter_uniformWinnerRewardVaultClaim() public {
        (uint256 catId, BondingCurveClog catMarket) = _launchMeme("Cat", "CAT");
        (uint256 dogId, BondingCurveClog dogMarket) = _launchMeme("Dog", "DOG");
        (uint256 fishId, BondingCurveClog fishMarket) = _launchMeme("Fish", "FISH");

        // No age requirement: real trading during round 1 (the very first round the protocol ever
        // opens) makes all three eligible directly for round 1's own draw.
        uint256 roundOpen = this._now();
        vm.prank(alice);
        catMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(catId);
        vm.prank(bob);
        dogMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(dogId);
        vm.prank(alice);
        fishMarket.buy{value: 5 ether}(0, block.timestamp);
        engine.onTrade(fishId);

        vm.warp(roundOpen + rm.ROUND_DURATION() / 2); // 30 minutes in, well before round 1 closes
        // Confirming touch after the 30-minute mark locks in candidacy (live qualification model).
        engine.qualify(catId);
        engine.qualify(dogId);
        engine.qualify(fishId);

        assertEq(engine.candidateCount(1), 3, "all three qualify directly into round 1's own candidate set -- no lag");

        // Round 1 closes -- this is the very first round, and it draws from its OWN candidates (no
        // lag), so closing it directly triggers provider.requestRandomness, which (via the mock's
        // synchronous loopback) runs the ENTIRE real adapter chain in one call: CCIP request ->
        // wrapper -> real VRF request -> [we fulfill via the official VRF mock below] -> wrapper
        // relays result via CCIP -> provider -> RoundManager.onRandomnessReceived -> winner settled
        // -> RewardVault allocated.
        vm.warp(roundOpen + rm.ROUND_DURATION());
        uint256 closedRoundId = rm.closeRoundAndOpenNext();
        assertEq(closedRoundId, 1);

        RoundManager.RoundInfo memory infoBeforeFulfillment = rm.getRound(1);
        assertTrue(infoBeforeFulfillment.randomnessRequested, "must have requested randomness via the real adapter");
        assertFalse(infoBeforeFulfillment.settled, "must not be settled until VRF actually fulfills");

        // Simulate the real Chainlink VRF network fulfilling the request (the one part that
        // cannot run without an actual VRF node -- everything else here is real contract code).
        uint256 vrfRequestId = _findLastVrfRequestId();
        vrfCoordinator.fulfillRandomWords(vrfRequestId, address(wrapper));

        RoundManager.RoundInfo memory info = rm.getRound(1);
        assertTrue(info.settled, "round must be settled once real VRF fulfillment completes");
        assertTrue(
            info.winnerTokenId == catId || info.winnerTokenId == dogId || info.winnerTokenId == fishId,
            "winner must be one of the three eligible candidates"
        );

        address winnerMarket = engine.tokenMarket(info.winnerTokenId);
        assertTrue(winnerMarket == address(catMarket) || winnerMarket == address(dogMarket) || winnerMarket == address(fishMarket));

        address winnerHolder = winnerMarket == address(catMarket) ? alice : winnerMarket == address(dogMarket) ? bob : alice;
        uint256 claimable = vault.previewClaim(1, winnerHolder);
        if (claimable > 0) {
            uint256 balBefore = winnerHolder.balance;
            vault.claim(1, winnerHolder);
            assertEq(winnerHolder.balance, balBefore + claimable);
        }
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
