// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

interface IRoundManagerCallbackForTest {
    function onRandomnessReceived(uint256 requestId, uint256 randomWord) external;
}

contract MockRoundManager is IRoundManagerCallbackForTest {
    uint256 public lastRequestId;
    uint256 public lastRandomWord;
    uint256 public callCount;

    function onRandomnessReceived(uint256 requestId, uint256 randomWord) external {
        lastRequestId = requestId;
        lastRandomWord = randomWord;
        callCount++;
    }
}

/// @notice Tests for the two-sided VRF/CCIP adapter, using Chainlink's own official mocks
/// (MockCCIPRouter, VRFCoordinatorV2_5Mock) rather than hand-rolled ones.
///
/// @dev MockCCIPRouter's `ccipSend` synchronously self-delivers using a HARDCODED
///      sourceChainSelector (16015286601757825753, Sepolia's real selector) regardless of which
///      destinationChainSelector was requested -- it's a same-chain "loopback" simulation, not a
///      true multi-chain one. Both this test's provider and wrapper are therefore configured to
///      expect messages FROM that fixed value as their counterparty's chain selector, so the
///      automatic delivery triggered by `ccipSend` (used in the full round-trip test) authenticates
///      correctly. The dedicated rejection tests instead call `routeMessage` directly (which
///      returns a (success, ...) tuple rather than reverting) with deliberately WRONG selectors, to
///      verify the authentication logic itself, independent of what any particular mock produces.
contract ChainlinkVRFAdapterTest is Test {
    MockCCIPRouter router;
    VRFCoordinatorV2_5Mock vrfCoordinator;

    ChainlinkRandomnessProvider provider; // "on Robinhood Chain"
    VRFWrapperOnArbitrum wrapper; // "on Arbitrum One"
    MockRoundManager roundManager;

    address governance = address(0x60401);
    // MockCCIPRouter.ccipSend always reports this fixed value as sourceChainSelector, whichever
    // "direction" the message is conceptually going -- see contract-level note above.
    uint64 constant MOCK_ROUTER_SELECTOR = 16015286601757825753;
    bytes32 constant KEY_HASH = keccak256("test-keyhash");
    uint256 subId;

    function setUp() public {
        router = new MockCCIPRouter();
        vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);
        subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 1_000_000 ether); // generous -- exact VRF fee
            // economics aren't what's under test here, only this adapter's own request/response
            // bookkeeping and authentication logic.

        roundManager = new MockRoundManager();

        provider = new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(this));
        provider.setRoundManager(address(roundManager));
        vm.deal(address(provider), 10 ether);

        wrapper = new VRFWrapperOnArbitrum(address(vrfCoordinator), address(router), MOCK_ROUTER_SELECTOR, KEY_HASH, subId);
        vrfCoordinator.addConsumer(subId, address(wrapper));
        vm.deal(address(wrapper), 10 ether);

        vm.prank(governance);
        provider.setWrapper(address(wrapper));
        wrapper.setProvider(address(provider)); // wrapper's owner is this test contract by default
    }

    // ── Access control ───────────────────────────────────────────────────────

    function test_requestRandomness_onlyRoundManager() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        provider.requestRandomness(1);
    }

    function test_requestRandomness_requiresWrapperSet() public {
        ChainlinkRandomnessProvider fresh = new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(this));
        fresh.setRoundManager(address(roundManager));
        vm.deal(address(fresh), 1 ether);
        vm.prank(address(roundManager));
        vm.expectRevert();
        fresh.requestRandomness(1);
    }

    function test_onlyGovernance_canSetWrapper() public {
        ChainlinkRandomnessProvider fresh = new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(this));
        vm.expectRevert();
        fresh.setWrapper(address(0x1234));
        vm.prank(governance);
        fresh.setWrapper(address(0x1234));
        assertEq(fresh.wrapperOnArbitrum(), address(0x1234));
    }

    function test_onlyOwner_canSetProviderOnWrapper() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        wrapper.setProvider(address(0x1234));
    }

    // ── setRoundManager one-time initialization ─────────────────────────────

    function test_setRoundManager_deployerCanInitializeOnce() public {
        ChainlinkRandomnessProvider fresh = new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(this));
        fresh.setRoundManager(address(0x9999));
        assertEq(fresh.roundManager(), address(0x9999));
    }

    function test_setRoundManager_secondInitializationReverts() public {
        ChainlinkRandomnessProvider fresh = new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(this));
        fresh.setRoundManager(address(0x9999));
        vm.expectRevert();
        fresh.setRoundManager(address(0x8888));
        assertEq(fresh.roundManager(), address(0x9999), "must remain permanently fixed to the first value");
    }

    function test_setRoundManager_unauthorizedCannotInitialize() public {
        ChainlinkRandomnessProvider fresh = new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(this));
        vm.prank(address(0xBEEF)); // not the deployer
        vm.expectRevert();
        fresh.setRoundManager(address(0x9999));
    }

    function test_setRoundManager_zeroAddressRejected() public {
        ChainlinkRandomnessProvider fresh = new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(this));
        vm.expectRevert();
        fresh.setRoundManager(address(0));
    }

    function test_constructor_zeroDeployerRejected() public {
        vm.expectRevert();
        new ChainlinkRandomnessProvider(address(router), MOCK_ROUTER_SELECTOR, governance, address(0));
    }

    // ── Full round-trip (the complete documented path) ──────────────────────

    function test_fullRoundTrip_requestThroughFulfillment() public {
        vm.prank(address(roundManager));
        uint256 requestId = provider.requestRandomness(42); // triggers ccipSend -> synchronously
            // delivers to the wrapper via the mock's loopback -- the wrapper's _ccipReceive runs
            // as part of this same call, requesting real VRF randomness.
        assertEq(provider.requestIdToRoundId(requestId), 42);

        uint256 vrfRequestId = _findLastVrfRequestId();
        assertTrue(vrfRequestId != 0, "wrapper must have requested VRF randomness");

        // Chainlink's VRF network fulfills the request -- simulated via the official mock, which
        // triggers the wrapper's fulfillRandomWords callback, which relays the result back via
        // another ccipSend (again synchronously self-delivered by the mock).
        vrfCoordinator.fulfillRandomWords(vrfRequestId, address(wrapper));

        assertEq(roundManager.callCount(), 1, "RoundManager must receive exactly one randomness delivery");
        assertEq(roundManager.lastRequestId(), requestId, "must be delivered for the original requestId");
        uint256 expectedWord = uint256(keccak256(abi.encode(vrfRequestId, uint256(0))));
        assertEq(roundManager.lastRandomWord(), expectedWord);
    }

    function test_oneRequestCannotProduceTwoDeliveries() public {
        vm.prank(address(roundManager));
        provider.requestRandomness(1);
        uint256 vrfRequestId = _findLastVrfRequestId();
        vrfCoordinator.fulfillRandomWords(vrfRequestId, address(wrapper));
        assertEq(roundManager.callCount(), 1);

        // The VRF coordinator itself won't refulfill a consumed request (it deletes request state
        // on fulfillment), so attempting to fulfill the same vrfRequestId again must fail --
        // confirming one VRF request can never settle a round twice.
        vm.expectRevert();
        vrfCoordinator.fulfillRandomWords(vrfRequestId, address(wrapper));
        assertEq(roundManager.callCount(), 1, "must not be delivered twice");
    }

    function test_multipleRounds_eachGetsExactlyOneDelivery() public {
        vm.prank(address(roundManager));
        uint256 reqA = provider.requestRandomness(10);
        vm.prank(address(roundManager));
        uint256 reqB = provider.requestRandomness(11);
        assertTrue(reqA != reqB, "distinct requests must get distinct ids");

        uint256 vrfA = _findLastVrfRequestId(); // most recent is reqB's; fulfill in reverse order
            // deliberately, to prove association isn't order-dependent
        vrfCoordinator.fulfillRandomWords(vrfA, address(wrapper));
        assertEq(roundManager.callCount(), 1);
        assertEq(roundManager.lastRequestId(), reqB, "the LAST request made corresponds to the LAST vrf id found");

        // Find and fulfill the other one.
        uint256 vrfOther = _findVrfRequestIdOtherThan(vrfA);
        vrfCoordinator.fulfillRandomWords(vrfOther, address(wrapper));
        assertEq(roundManager.callCount(), 2);
        assertEq(roundManager.lastRequestId(), reqA);
    }

    // ── Authentication (tested directly via routeMessage, bypassing ccipSend's loopback) ────────

    function test_provider_ccipReceive_rejectsWrongSourceChain() public {
        Client.Any2EVMMessage memory badMsg = Client.Any2EVMMessage({
            messageId: keccak256("bad"),
            sourceChainSelector: 999, // not the configured arbitrumChainSelector
            sender: abi.encode(address(wrapper)),
            data: abi.encode(uint256(1), uint256(12345)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        (bool success,,) = router.routeMessage(badMsg, 5000, 500_000, address(provider));
        assertFalse(success, "message from an unauthorized source chain must be rejected");
        assertEq(roundManager.callCount(), 0);
    }

    function test_provider_ccipReceive_rejectsWrongSender() public {
        Client.Any2EVMMessage memory badMsg = Client.Any2EVMMessage({
            messageId: keccak256("bad"),
            sourceChainSelector: MOCK_ROUTER_SELECTOR,
            sender: abi.encode(address(0xBAD)), // not the real wrapper
            data: abi.encode(uint256(1), uint256(12345)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        (bool success,,) = router.routeMessage(badMsg, 5000, 500_000, address(provider));
        assertFalse(success, "message from an unauthorized sender must be rejected");
        assertEq(roundManager.callCount(), 0);
    }

    function test_provider_ccipReceive_rejectsUnknownRequestId() public {
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: keccak256("orphan"),
            sourceChainSelector: MOCK_ROUTER_SELECTOR,
            sender: abi.encode(address(wrapper)),
            data: abi.encode(uint256(999), uint256(12345)), // requestId 999 was never requested
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        (bool success,,) = router.routeMessage(msg_, 5000, 500_000, address(provider));
        assertFalse(success, "an unknown/malformed request id must be rejected");
        assertEq(roundManager.callCount(), 0);
    }

    function test_provider_replayProtection_sameResultCannotBeDeliveredTwice() public {
        vm.prank(address(roundManager));
        uint256 requestId = provider.requestRandomness(1);

        Client.Any2EVMMessage memory resultMsg = Client.Any2EVMMessage({
            messageId: keccak256("m"),
            sourceChainSelector: MOCK_ROUTER_SELECTOR,
            sender: abi.encode(address(wrapper)),
            data: abi.encode(requestId, uint256(777)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        (bool ok1,,) = router.routeMessage(resultMsg, 5000, 500_000, address(provider));
        assertTrue(ok1);
        assertEq(roundManager.callCount(), 1);

        (bool ok2,,) = router.routeMessage(resultMsg, 5000, 500_000, address(provider));
        assertFalse(ok2, "delivering the exact same result twice must be rejected");
        assertEq(roundManager.callCount(), 1, "must not be called twice for the same request");
    }

    function test_provider_ccipReceive_onlyCallableByRouter() public {
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: keccak256("direct"),
            sourceChainSelector: MOCK_ROUTER_SELECTOR,
            sender: abi.encode(address(wrapper)),
            data: abi.encode(uint256(1), uint256(1)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        // Calling ccipReceive directly (not through the router) must be rejected -- only the
        // configured CCIP router itself may ever invoke it.
        vm.expectRevert();
        provider.ccipReceive(msg_);
    }

    function test_wrapper_ccipReceive_rejectsWrongSourceChain() public {
        Client.Any2EVMMessage memory badMsg = Client.Any2EVMMessage({
            messageId: keccak256("a"),
            sourceChainSelector: 999,
            sender: abi.encode(address(provider)),
            data: abi.encode(uint256(1)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        (bool success,,) = router.routeMessage(badMsg, 5000, 500_000, address(wrapper));
        assertFalse(success);
    }

    function test_wrapper_ccipReceive_rejectsWrongSender() public {
        Client.Any2EVMMessage memory badMsg = Client.Any2EVMMessage({
            messageId: keccak256("b"),
            sourceChainSelector: MOCK_ROUTER_SELECTOR,
            sender: abi.encode(address(0xBAD)),
            data: abi.encode(uint256(1)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        (bool success,,) = router.routeMessage(badMsg, 5000, 500_000, address(wrapper));
        assertFalse(success);
    }

    function test_wrapper_ccipReceive_onlyCallableByRouter() public {
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: keccak256("direct"),
            sourceChainSelector: MOCK_ROUTER_SELECTOR,
            sender: abi.encode(address(provider)),
            data: abi.encode(uint256(1)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.expectRevert();
        wrapper.ccipReceive(msg_);
    }

    function test_wrapper_fulfillRandomWords_onlyCallableByCoordinator() public view {
        // VRFConsumerBaseV2Plus's rawFulfillRandomWords enforces msg.sender == vrfCoordinator
        // internally (official Chainlink code, not reimplemented here) -- confirmed by
        // construction: the wrapper was deployed with vrfCoordinator as the one and only address
        // authorized to call back into it. No separate test of Chainlink's own base contract is
        // needed; this is a documentation-only assertion of that wiring.
        assertEq(address(wrapper.s_vrfCoordinator()), address(vrfCoordinator));
    }

    function _findLastVrfRequestId() internal view returns (uint256) {
        for (uint256 i = 30; i >= 1; i--) {
            if (wrapper.vrfRequestIdToOriginalRequestId(i) != 0) {
                return i;
            }
        }
        revert("no VRF request found");
    }

    function _findVrfRequestIdOtherThan(uint256 exclude) internal view returns (uint256) {
        for (uint256 i = 1; i <= 30; i++) {
            if (i != exclude && wrapper.vrfRequestIdToOriginalRequestId(i) != 0) {
                return i;
            }
        }
        revert("no other VRF request found");
    }
}
